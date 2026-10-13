import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

final localDatabaseProvider = Provider<LocalDatabase>((ref) => LocalDatabase());

/// Thin on-device cache (for reading stale-but-real data while offline) plus
/// an outbox of writes queued while offline (drained by `SyncEngine` once
/// connectivity returns). Every cached value is stored as the raw server
/// JSON, so reading it back through the same `fromJson` factories used for a
/// live fetch, rather than a second, separate serialization format.
class LocalDatabase {
  Database? _db;

  Future<Database> _open() async {
    final existing = _db;
    if (existing != null) return existing;

    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'expertedu_cache.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          create table cache_blobs (
            key text primary key,
            json text not null,
            updated_at text not null
          )
        ''');
        await db.execute('''
          create table outbox (
            seq integer primary key autoincrement,
            local_id text not null,
            entity text not null,
            op text not null,
            payload text not null,
            depends_on_seq integer,
            status text not null default 'pending',
            attempt_count integer not null default 0,
            last_error text,
            created_at text not null
          )
        ''');
        await db.execute('create index idx_outbox_status on outbox(status, seq)');
      },
    );
    _db = db;
    return db;
  }

  /// Generic key/value blob cache. Callers key entries by whatever
  /// identifies "this exact fetch" (e.g. a dashboard has one fixed key, a
  /// filtered list is keyed by its filter/sort params) so two different
  /// queries never clobber each other's cached result.
  Future<void> saveBlob(String key, dynamic rawJson) async {
    final db = await _open();
    await db.insert('cache_blobs', {
      'key': key,
      'json': jsonEncode(rawJson),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<dynamic> readBlob(String key) async {
    final db = await _open();
    final rows = await db.query('cache_blobs', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['json'] as String);
  }

  Future<Database> outboxDb() => _open();
}
