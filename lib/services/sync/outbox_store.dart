import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_db/local_database.dart';

final outboxStoreProvider = Provider<OutboxStore>((ref) {
  return OutboxStore(ref.watch(localDatabaseProvider));
});

class OutboxItem {
  const OutboxItem({
    required this.seq,
    required this.localId,
    required this.entity,
    required this.op,
    required this.payload,
    required this.dependsOnSeq,
    required this.status,
    required this.attemptCount,
    required this.lastError,
    required this.createdAt,
  });

  final int seq;
  final String localId;
  final String entity; // 'customer' | 'transaction'
  final String op; // 'create' | 'update' | 'delete' | 'archive' | 'unarchive' | 'clear_debt'
  final Map<String, dynamic> payload;
  final int? dependsOnSeq;
  final String status; // 'pending' | 'in_flight' | 'failed' | 'held' | 'discarded' | 'done'
  final int attemptCount;
  final String? lastError;

  /// When this write was first queued -- not when it was last attempted.
  /// Lets SyncEngine notice a write that's been sitting unsent for an
  /// abnormally long time (see `held`) and lets the pending-actions sheet
  /// show staff how long something's actually been waiting.
  final DateTime createdAt;

  factory OutboxItem.fromRow(Map<String, dynamic> row) {
    return OutboxItem(
      seq: row['seq'] as int,
      localId: row['local_id'] as String,
      entity: row['entity'] as String,
      op: row['op'] as String,
      payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
      dependsOnSeq: row['depends_on_seq'] as int?,
      status: row['status'] as String,
      attemptCount: row['attempt_count'] as int,
      lastError: row['last_error'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }
}

/// The offline write queue. Every write made while there's no connectivity
/// lands here first; `SyncEngine` drains it once the API is reachable again.
class OutboxStore {
  OutboxStore(this._localDb);

  final LocalDatabase _localDb;

  Future<int> enqueue({
    required String entity,
    required String op,
    required String localId,
    required Map<String, dynamic> payload,
    int? dependsOnSeq,
  }) async {
    final db = await _localDb.outboxDb();
    return db.insert('outbox', {
      'local_id': localId,
      'entity': entity,
      'op': op,
      'payload': jsonEncode(payload),
      'depends_on_seq': dependsOnSeq,
      'status': 'pending',
      'attempt_count': 0,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// Finds a still-unsynced `create` for [entity]/[targetId], if any -- used
  /// to make a later op against that same (still-local) id wait for its own
  /// create to land first.
  Future<int?> findOpenCreateSeq({required String entity, required String targetId}) async {
    final db = await _localDb.outboxDb();
    final rows = await db.query(
      'outbox',
      where:
          "entity = ? and op = 'create' and local_id = ? and status in ('pending', 'in_flight', 'failed', 'held')",
      whereArgs: [entity, targetId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['seq'] as int;
  }

  /// The oldest pending/failed row whose dependency (if any) has finished.
  Future<OutboxItem?> nextRunnable() async {
    final db = await _localDb.outboxDb();
    final rows = await db.rawQuery('''
      select o.* from outbox o
      where o.status in ('pending', 'failed')
        and (
          o.depends_on_seq is null
          or exists (select 1 from outbox d where d.seq = o.depends_on_seq and d.status = 'done')
        )
      order by o.seq asc
      limit 1
    ''');
    if (rows.isEmpty) return null;
    return OutboxItem.fromRow(rows.first);
  }

  /// Parks a risky op (customer archive, transaction delete/clear-debt)
  /// that's been sitting unsent for an abnormally long time, instead of
  /// letting it fire the moment connectivity returns -- see SyncEngine's
  /// staleness check for why. `nextRunnable` excludes `held` rows, so this
  /// takes it out of the normal auto-retry loop entirely; it only moves
  /// again via [confirmSend] or [discard], both driven by a human looking
  /// at the pending-actions sheet.
  Future<void> markHeld(int seq) async {
    final db = await _localDb.outboxDb();
    await db.update('outbox', {'status': 'held'}, where: 'seq = ?', whereArgs: [seq]);
  }

  /// Staff reviewed a held row and confirmed it should still go out --
  /// puts it back in the normal queue so the very next sync pass picks it
  /// up like any other pending write. Resets `created_at` to now: without
  /// that, SyncEngine's staleness check would see the exact same age that
  /// got it held in the first place and park it right back again the
  /// instant it's picked up -- confirming is explicit, fresh intent,
  /// so it should behave like a write made right now, not a stale one.
  Future<void> confirmSend(int seq) async {
    final db = await _localDb.outboxDb();
    await db.update(
      'outbox',
      {'status': 'pending', 'created_at': DateTime.now().toIso8601String()},
      where: 'seq = ?',
      whereArgs: [seq],
    );
  }

  /// Staff reviewed a row (held or not) and decided it should never be
  /// sent -- a terminal state, kept (not deleted) so there's still a
  /// record of what was queued and discarded, same spirit as `failed`.
  Future<void> discard(int seq) async {
    final db = await _localDb.outboxDb();
    await db.update('outbox', {'status': 'discarded'}, where: 'seq = ?', whereArgs: [seq]);
  }

  /// Recovers any row left stuck at `in_flight` by a previous app process
  /// that got killed mid-write (an OS background kill, a crash, or just
  /// swiping the app away while a request was in the air) -- `nextRunnable`
  /// deliberately never revisits `in_flight` rows on its own, since two
  /// concurrent sync passes both picking up the same row would double-submit
  /// it. That's correct *within* one process, but across a restart nothing
  /// else is ever going to finish what that dead process started: the row
  /// stays `in_flight` forever, `countPending` keeps counting it (so the
  /// "N o'zgarish kutilmoqda" banner never clears), yet no retry fires
  /// again no matter how good the connection is. Called once per app
  /// start, before anything else touches the outbox, so it's the only
  /// process ever looking at that row at the time.
  Future<void> resetStaleInFlight() async {
    final db = await _localDb.outboxDb();
    await db.update('outbox', {'status': 'pending'}, where: "status = 'in_flight'");
  }

  Future<void> markInFlight(int seq) async {
    final db = await _localDb.outboxDb();
    await db.update('outbox', {'status': 'in_flight'}, where: 'seq = ?', whereArgs: [seq]);
  }

  Future<void> markDone(int seq) async {
    final db = await _localDb.outboxDb();
    await db.update('outbox', {'status': 'done'}, where: 'seq = ?', whereArgs: [seq]);
  }

  Future<void> markPendingRetry(int seq) async {
    final db = await _localDb.outboxDb();
    await db.rawUpdate(
      "update outbox set status = 'pending', attempt_count = attempt_count + 1 where seq = ?",
      [seq],
    );
  }

  Future<void> markFailed(int seq, String error) async {
    final db = await _localDb.outboxDb();
    await db.update(
      'outbox',
      {'status': 'failed', 'last_error': error, 'attempt_count': 1 + await _attemptCount(seq)},
      where: 'seq = ?',
      whereArgs: [seq],
    );
  }

  Future<int> _attemptCount(int seq) async {
    final db = await _localDb.outboxDb();
    final rows = await db.query('outbox', columns: ['attempt_count'], where: 'seq = ?', whereArgs: [seq]);
    return rows.isEmpty ? 0 : rows.first['attempt_count'] as int;
  }

  /// After a `create` for [entity] resolves from [oldId] (the client-generated
  /// id) to [newId] (the real server id), point any other still-open row
  /// targeting [oldId] at the real id instead.
  Future<void> rewriteLocalId({required String entity, required String oldId, required String newId}) async {
    final db = await _localDb.outboxDb();
    await db.update(
      'outbox',
      {'local_id': newId},
      where: "entity = ? and local_id = ? and op != 'create' and status in ('pending', 'failed', 'held')",
      whereArgs: [entity, oldId],
    );
  }

  Future<int> countPending() async {
    final db = await _localDb.outboxDb();
    final rows = await db.rawQuery(
      "select count(*) as n from outbox where status in ('pending', 'in_flight', 'failed', 'held')",
    );
    return rows.first['n'] as int;
  }

  Future<List<OutboxItem>> listPending() async {
    final db = await _localDb.outboxDb();
    final rows = await db.query(
      'outbox',
      where: "status in ('pending', 'in_flight', 'failed', 'held')",
      orderBy: 'seq asc',
    );
    return rows.map(OutboxItem.fromRow).toList();
  }

  /// Whether [entity]/[targetId] has any not-yet-synced write queued against
  /// it (used to decide whether a write just returned "queued" rather than
  /// confirmed).
  Future<bool> hasOpenWriteFor({required String entity, required String targetId}) async {
    final db = await _localDb.outboxDb();
    final rows = await db.query(
      'outbox',
      where: "entity = ? and local_id = ? and status in ('pending', 'in_flight', 'failed', 'held')",
      whereArgs: [entity, targetId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
