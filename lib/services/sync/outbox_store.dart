import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

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
    required this.idempotencyKey,
    required this.description,
  });

  final int seq;

  /// The record this write is about: the client-generated id of something
  /// made offline, or a real server id as text.
  final String localId;
  final String
  entity; // 'lead' | 'lead_interaction' | 'follow_up_task' | 'trial_booking'
  final String op; // 'create'

  /// What to send -- see `SyncEngine` for the shape.
  final Map<String, dynamic> payload;
  final int? dependsOnSeq;

  /// 'pending' | 'in_flight' | 'failed' | 'discarded' | 'done'.
  final String status;
  final int attemptCount;
  final String? lastError;

  /// When this write was first queued -- not when it was last attempted.
  final DateTime createdAt;

  /// Sent with every attempt, so the server does it once however many
  /// times it arrives.
  final String? idempotencyKey;

  /// What staff see in the pending-changes list.
  final String? description;

  bool get isFailed => status == 'failed';

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
      idempotencyKey: row['idempotency_key'] as String?,
      description: row['description'] as String?,
    );
  }
}

const _openStatuses = "('pending', 'in_flight', 'failed')";

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
    required String idempotencyKey,
    required String description,
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
      'idempotency_key': idempotencyKey,
      'description': description,
    });
  }

  /// Finds a still-unsynced `create` for [entity]/[targetId], if any -- used
  /// to make a later op against that same (still-local) id wait for its own
  /// create to land first.
  Future<int?> findOpenCreateSeq({
    required String entity,
    required String targetId,
  }) async {
    final db = await _localDb.outboxDb();
    final rows = await db.query(
      'outbox',
      where:
          "entity = ? and op = 'create' and local_id = ? and status in $_openStatuses",
      whereArgs: [entity, targetId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['seq'] as int;
  }

  /// The oldest pending row whose dependency (if any) has finished. A row
  /// waiting on a failed one stays put until that's retried or discarded.
  /// Failed rows aren't retried automatically: the server said no, and
  /// sending the same thing again would get the same answer.
  Future<OutboxItem?> nextRunnable() async {
    final db = await _localDb.outboxDb();
    final rows = await db.rawQuery('''
      select o.* from outbox o
      where o.status = 'pending'
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

  /// Recovers any row left stuck at `in_flight` by a previous app process
  /// that got killed mid-write -- `nextRunnable` never revisits `in_flight`
  /// rows on its own, so two passes can't both send one. Called once per
  /// app start, before anything else touches the outbox. Resending is safe:
  /// the row's idempotency key makes the server answer, not redo, a write
  /// that did land.
  Future<void> resetStaleInFlight() async {
    final db = await _localDb.outboxDb();
    await db.update('outbox', {
      'status': 'pending',
    }, where: "status = 'in_flight'");
  }

  Future<void> markInFlight(int seq) => _setStatus(seq, 'in_flight');

  Future<void> markDone(int seq) => _setStatus(seq, 'done');

  /// Couldn't reach the server -- try again later, as is.
  Future<void> markPendingRetry(int seq) async {
    final db = await _localDb.outboxDb();
    await db.rawUpdate(
      "update outbox set status = 'pending', attempt_count = attempt_count + 1 where seq = ?",
      [seq],
    );
  }

  /// The server refused it (full trial, duplicate, ...): parked with the
  /// reason until someone retries or discards it.
  Future<void> markFailed(int seq, String error) async {
    final db = await _localDb.outboxDb();
    await db.rawUpdate(
      "update outbox set status = 'failed', last_error = ?, attempt_count = attempt_count + 1 where seq = ?",
      [error, seq],
    );
  }

  /// Staff asked to send a failed row again.
  Future<void> retry(int seq) => _setStatus(seq, 'pending');

  /// Staff decided a row should never be sent. Everything queued on top of
  /// it (a trial booked for a lead that'll never exist) goes too. Kept,
  /// not deleted, as a record of what was dropped.
  Future<void> discard(int seq) async {
    final db = await _localDb.outboxDb();
    await db.rawUpdate(
      '''
      with recursive doomed(seq) as (
        select ?
        union
        select o.seq from outbox o join doomed d on o.depends_on_seq = d.seq
      )
      update outbox set status = 'discarded'
      where seq in (select seq from doomed) and status in $_openStatuses
      ''',
      [seq],
    );
  }

  /// The queued create for [entity]/[localId], whatever its status now.
  Future<OutboxItem?> findCreate({
    required String entity,
    required String localId,
  }) async {
    final db = await _localDb.outboxDb();
    final rows = await db.query(
      'outbox',
      where: "entity = ? and op = 'create' and local_id = ?",
      whereArgs: [entity, localId],
      orderBy: 'seq desc',
      limit: 1,
    );
    return rows.isEmpty ? null : OutboxItem.fromRow(rows.first);
  }

  /// Drops a create that hasn't been sent (still waiting, or parked after a
  /// refusal). False if it is on its way or already there -- the server has
  /// to undo it then. Kept, marked discarded, not deleted.
  Future<bool> discardUnsentCreate({
    required String entity,
    required String localId,
  }) async {
    final db = await _localDb.outboxDb();
    final changed = await db.rawUpdate(
      "update outbox set status = 'discarded' "
      "where entity = ? and op = 'create' and local_id = ? "
      "and status in ('pending', 'failed')",
      [entity, localId],
    );
    return changed > 0;
  }

  Future<void> _setStatus(int seq, String status) async {
    final db = await _localDb.outboxDb();
    await db.update(
      'outbox',
      {'status': status},
      where: 'seq = ?',
      whereArgs: [seq],
    );
  }

  Future<void> saveServerId({
    required String entity,
    required String localId,
    required int serverId,
  }) async {
    final db = await _localDb.outboxDb();
    await db.insert('id_map', {
      'entity': entity,
      'local_id': localId,
      'server_id': serverId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int?> serverIdFor({
    required String entity,
    required String localId,
  }) async {
    final db = await _localDb.outboxDb();
    final rows = await db.query(
      'id_map',
      columns: ['server_id'],
      where: 'entity = ? and local_id = ?',
      whereArgs: [entity, localId],
    );
    return rows.isEmpty ? null : rows.first['server_id'] as int;
  }

  Future<int> countPending() async {
    final db = await _localDb.outboxDb();
    final rows = await db.rawQuery(
      'select count(*) as n from outbox where status in $_openStatuses',
    );
    return rows.first['n'] as int;
  }

  Future<List<OutboxItem>> listPending({String? entity}) async {
    final db = await _localDb.outboxDb();
    final rows = await db.query(
      'outbox',
      where: entity == null
          ? 'status in $_openStatuses'
          : 'status in $_openStatuses and entity = ?',
      whereArgs: entity == null ? null : [entity],
      orderBy: 'seq asc',
    );
    return rows.map(OutboxItem.fromRow).toList();
  }
}
