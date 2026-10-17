import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_client.dart';
import 'connectivity_service.dart';
import 'outbox_store.dart';

/// Sends one queued write: POST [path] with [body] and the extra [headers].
typedef SyncSend =
    Future<dynamic> Function(
      String path,
      Map<String, dynamic> body,
      Map<String, String> headers,
    );

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final api = ref.watch(apiClientProvider);
  final engine = SyncEngine(
    outbox: ref.watch(outboxStoreProvider),
    send: (path, body, headers) => api.post(path, body: body, headers: headers),
    linkChanges: ref.watch(connectivityServiceProvider).onLinkChanged,
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// Drains the outbox: every write queued while offline, oldest first, once
/// the API answers again.
///
/// A queued write's payload is a request template:
///
///     {"path": "/leads/{lead}/interactions",
///      "body": {"kind": "note", "body": "...", "lead_id": "{lead}"},
///      "refs": {"lead": "<local id of a lead made offline>"}}
///
/// Each `{name}` -- in the path, or as a whole body value -- becomes the
/// server id the referenced record got once its own create went through
/// (the row `depends_on_seq` that create, so it always goes first). A
/// create's response `id` is remembered for its local id the same way.
///
/// Every send carries the row's own Idempotency-Key, so a write whose
/// response was lost is answered, not redone, when it's sent again.
class SyncEngine {
  SyncEngine({
    required this._outbox,
    required this._send,
    Stream<bool>? linkChanges,
    this._retryInterval = const Duration(seconds: 30),
  }) {
    _linkSubscription = linkChanges?.listen((up) {
      if (up) unawaited(drain());
    });
  }

  final OutboxStore _outbox;
  final SyncSend _send;
  final Duration _retryInterval;
  StreamSubscription<bool>? _linkSubscription;
  Timer? _timer;
  bool _started = false;
  Future<void>? _draining;

  /// Writes not yet accepted by the server (pending or failed).
  final ValueNotifier<int> pendingCount = ValueNotifier<int>(0);

  /// False after a send couldn't reach the server; true again on the next
  /// answer. Screens use it for their "offline" banner.
  final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  /// Bumped whenever a queued write reaches the server, so screens showing
  /// queued records know to reload.
  final ValueNotifier<int> syncedRevision = ValueNotifier<int>(0);

  /// Once per signed-in session: recover rows a killed process left in
  /// flight, then send whatever is waiting, and keep retrying while
  /// anything is.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    await _outbox.resetStaleInFlight();
    _timer = Timer.periodic(_retryInterval, (_) {
      if (pendingCount.value > 0) unawaited(drain());
    });
    await drain();
  }

  void reportOffline() => online.value = false;
  void reportOnline() => online.value = true;

  /// Called right after something is queued.
  Future<void> nudge() => drain();

  /// Sends runnable rows one at a time until the queue is empty or the
  /// server can't be reached. Concurrent calls share one pass.
  Future<void> drain() => _draining ??= _drain().whenComplete(() {
    _draining = null;
  });

  Future<void> _drain() async {
    try {
      while (true) {
        final item = await _outbox.nextRunnable();
        if (item == null) break;
        final keepGoing = await _sendOne(item);
        if (!keepGoing) break;
      }
    } finally {
      pendingCount.value = await _outbox.countPending();
    }
  }

  /// False when the pass should stop (offline, signed out, server trouble).
  Future<bool> _sendOne(OutboxItem item) async {
    final Map<String, int> ids;
    try {
      ids = await _resolveRefs(item);
    } on _UnresolvedRef catch (e) {
      await _outbox.markFailed(item.seq, e.message);
      return true;
    }

    await _outbox.markInFlight(item.seq);
    try {
      final response = await _send(
        _fillPath(item.payload['path'] as String, ids),
        _fillBody(item.payload['body'], ids) as Map<String, dynamic>,
        <String, String>{
          if (item.idempotencyKey != null)
            'Idempotency-Key': item.idempotencyKey!,
        },
      );
      if (item.op == 'create' && response is Map && response['id'] is int) {
        await _outbox.saveServerId(
          entity: item.entity,
          localId: item.localId,
          serverId: response['id'] as int,
        );
      }
      await _outbox.markDone(item.seq);
      reportOnline();
      syncedRevision.value++;
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 0) {
        await _outbox.markPendingRetry(item.seq);
        reportOffline();
        return false;
      }
      reportOnline();
      // Signed out, rate-limited or a server fault: nothing wrong with the
      // write itself -- leave it queued for later.
      if (e.statusCode == 401 || e.statusCode == 429 || e.statusCode >= 500) {
        await _outbox.markPendingRetry(item.seq);
        return false;
      }
      await _outbox.markFailed(item.seq, e.message);
      return true;
    }
  }

  Future<Map<String, int>> _resolveRefs(OutboxItem item) async {
    final refs = (item.payload['refs'] as Map<String, dynamic>?) ?? const {};
    final ids = <String, int>{};
    for (final entry in refs.entries) {
      final ref = entry.value as Map<String, dynamic>;
      final serverId = await _outbox.serverIdFor(
        entity: ref['entity'] as String,
        localId: ref['local_id'] as String,
      );
      if (serverId == null) {
        throw const _UnresolvedRef('Bog\'liq yozuv serverga yetib bormagan.');
      }
      ids[entry.key] = serverId;
    }
    return ids;
  }

  static String _fillPath(String path, Map<String, int> ids) =>
      path.replaceAllMapped(
        RegExp(r'\{(\w+)\}'),
        (m) => ids.containsKey(m[1]) ? '${ids[m[1]]}' : m[0]!,
      );

  /// Only a value that is exactly "{name}" is a placeholder -- never part
  /// of text someone typed.
  static Object? _fillBody(Object? value, Map<String, int> ids) {
    if (value is String) {
      final whole = RegExp(r'^\{(\w+)\}$').firstMatch(value);
      return whole != null && ids.containsKey(whole[1]) ? ids[whole[1]] : value;
    }
    if (value is Map) {
      return <String, dynamic>{
        for (final entry in value.entries)
          entry.key as String: _fillBody(entry.value, ids),
      };
    }
    if (value is List) return value.map((v) => _fillBody(v, ids)).toList();
    return value;
  }

  Future<void> refreshCount() async {
    pendingCount.value = await _outbox.countPending();
  }

  void dispose() {
    _timer?.cancel();
    _linkSubscription?.cancel();
    pendingCount.dispose();
    online.dispose();
    syncedRevision.dispose();
  }
}

class _UnresolvedRef implements Exception {
  const _UnresolvedRef(this.message);

  final String message;
}
