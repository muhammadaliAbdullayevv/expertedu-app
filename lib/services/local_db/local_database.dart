import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactorySqflitePlugin;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final localDatabaseProvider = Provider<LocalDatabase>((ref) => LocalDatabase());

/// Thin on-device cache (for reading stale-but-real data while offline) plus
/// an outbox of writes queued while offline (drained by `SyncEngine` once
/// connectivity returns). Every cached value is stored as the raw server
/// JSON, so reading it back through the same `fromJson` factories used for a
/// live fetch, rather than a second, separate serialization format.
class LocalDatabase {
  /// [factory] and [path] are for tests (an in-memory database); the app
  /// uses the platform's default.
  LocalDatabase({this._factory, this._path});

  final DatabaseFactory? _factory;
  final String? _path;
  Database? _db;
  Future<Database>? _opening;

  static const int _version = 2;

  /// sqflite itself only runs on Android/iOS/macOS; Windows and Linux use
  /// the FFI implementation over the SQLite the `sqlite3` package bundles.
  static DatabaseFactory _platformFactory() {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      return databaseFactoryFfi;
    }
    return databaseFactorySqflitePlugin;
  }

  Future<Database> _open() {
    final existing = _db;
    if (existing != null) return Future.value(existing);
    return _opening ??= _doOpen();
  }

  Future<Database> _doOpen() async {
    final path =
        _path ??
        p.join(
          (await getApplicationSupportDirectory()).path,
          'expertedu_cache.db',
        );
    final db = await (_factory ?? _platformFactory()).openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: (db, version) async {
          await db.execute('''
            create table cache_blobs (
              key text primary key,
              json text not null,
              updated_at text not null
            )
          ''');
          await _createOutbox(db);
          await _createIdMap(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute(
              'alter table outbox add column idempotency_key text',
            );
            await db.execute('alter table outbox add column description text');
            await _createIdMap(db);
          }
        },
      ),
    );
    _db = db;
    return db;
  }

  static Future<void> _createOutbox(Database db) async {
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
        created_at text not null,
        idempotency_key text,
        description text
      )
    ''');
    await db.execute('create index idx_outbox_status on outbox(status, seq)');
  }

  /// Which server id a record made offline (by its local id) got once its
  /// create went through -- so writes queued against it can follow.
  static Future<void> _createIdMap(Database db) async {
    await db.execute('''
      create table id_map (
        entity text not null,
        local_id text not null,
        server_id integer not null,
        primary key (entity, local_id)
      )
    ''');
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
    final rows = await db.query(
      'cache_blobs',
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['json'] as String);
  }

  Future<Database> outboxDb() => _open();

  Future<void> close() async {
    await _db?.close();
    _db = null;
    _opening = null;
  }
}
