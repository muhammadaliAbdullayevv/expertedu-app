import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/formatters/phone_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../../services/sync/outbox_store.dart';
import '../../../services/sync/sync_engine.dart';

final quickSaveProvider = Provider<QuickSaveRepository>((ref) {
  return QuickSaveRepository(
    api: ref.watch(apiClientProvider),
    outbox: ref.watch(outboxStoreProvider),
    sync: ref.watch(syncEngineProvider),
  );
});

/// How a save ended up, once the first try to send it has finished.
enum SaveState {
  /// The server has it.
  sent,

  /// Waiting in the queue; it is sent as soon as the internet allows.
  queued,

  /// The server said no (a full trial, a second trial...). Kept in the queue
  /// with the reason, so nothing typed is lost.
  refused,
}

class QuickSaveResult {
  const QuickSaveResult(this.state, [this.message]);

  final SaveState state;
  final String? message;
}

/// One save of the fast form.
class QuickSave {
  const QuickSave({required this.clientId, required this.settled});

  /// The person's identity from the first keystroke on: the server finds the
  /// same person again however many times the save is sent.
  final String clientId;

  /// Completes after the first try to send it: sent, queued or refused.
  final Future<QuickSaveResult> settled;
}

enum UndoOutcome {
  /// It had not been sent yet and is dropped.
  removed,

  /// The server archived what the save created (its trial cancelled).
  archived,

  /// The save was added to an older request, so there was nothing new to undo.
  unchanged,

  /// No internet: could not undo right now.
  offline,
}

/// The Qabul form's save: the typed values go into the local queue first (a
/// few milliseconds, no network), the form is free again at once, and the
/// queue sends them in the background -- again later if the internet fails.
/// Every send carries the same Idempotency-Key and client id, so a save is
/// never doubled.
class QuickSaveRepository {
  QuickSaveRepository({
    required this._api,
    required this._outbox,
    required this._sync,
  });

  static const _entity = 'lead';

  final ApiClient _api;
  final OutboxStore _outbox;
  final SyncEngine _sync;

  Future<QuickSave> save({
    required String fullName,
    required String phone,
    int? groupId,
    String? groupName,
    DateTime? trialStartsAt,
    String? note,
  }) async {
    final clientId = const Uuid().v4();
    await _outbox.enqueue(
      entity: _entity,
      op: 'create',
      localId: clientId,
      idempotencyKey: const Uuid().v4(),
      description: 'Qabul: $fullName, ${PhoneFormatter.display(phone)}',
      payload: <String, dynamic>{
        'path': '/leads',
        'body': <String, dynamic>{
          'client_id': clientId,
          'full_name': fullName,
          'phone': phone,
          'group_id': groupId,
          'trial_starts_at': trialStartsAt?.toUtc().toIso8601String(),
          'note': note,
          // Nobody is there to decide when it is finally sent: a number that
          // already has an open request is added to it.
          'on_duplicate': 'merge',
        },
        // Display only, for the waiting row in the list.
        'group_name': groupName,
      },
    );
    await _sync.refreshCount();
    return QuickSave(clientId: clientId, settled: _send(clientId));
  }

  Future<QuickSaveResult> _send(String clientId) async {
    try {
      await _sync.nudge();
    } catch (_) {
      // The queue keeps it; the next pass tries again.
    }
    final item = await _outbox.findCreate(entity: _entity, localId: clientId);
    if (item == null || item.status == 'done') {
      return const QuickSaveResult(SaveState.sent);
    }
    if (item.status == 'failed') {
      return QuickSaveResult(SaveState.refused, item.lastError);
    }
    return const QuickSaveResult(SaveState.queued);
  }

  Future<UndoOutcome> undo(String clientId) async {
    Future<bool> dropped() =>
        _outbox.discardUnsentCreate(entity: _entity, localId: clientId);

    if (await dropped()) {
      await _sync.refreshCount();
      return UndoOutcome.removed;
    }
    // On its way: let that finish, then it is either sent or still waiting.
    await _sync.drain();
    if (await dropped()) {
      await _sync.refreshCount();
      return UndoOutcome.removed;
    }
    try {
      final json = await _api.post(
        '/leads/undo',
        body: <String, dynamic>{'client_id': clientId},
      );
      return (json as Map<String, dynamic>)['undone'] == true
          ? UndoOutcome.archived
          : UndoOutcome.unchanged;
    } on ApiException catch (e) {
      if (e.statusCode == 0) return UndoOutcome.offline;
      rethrow;
    }
  }
}
