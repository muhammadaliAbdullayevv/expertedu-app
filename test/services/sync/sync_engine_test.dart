import 'package:expert_edu_center/features/admissions/data/admissions_models.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_repository.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:expert_edu_center/services/local_db/local_database.dart';
import 'package:expert_edu_center/services/sync/outbox_store.dart';
import 'package:expert_edu_center/services/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A stand-in for the API that behaves like server/app/idempotency.py: a
/// key it has seen gets the stored answer, not a second write.
class FakeServer {
  bool offline = false;

  /// Do the write, then lose the response -- the classic double-submit.
  bool loseNextResponse = false;

  /// Answer the next write to [path] with this status and message instead.
  ({String path, int status, String message})? refuseNext;

  final List<({String path, Map<String, dynamic> body, String? key})> sent = [];
  final Map<String, dynamic> _byKey = {};
  final Map<String, int> leadsByClientId = {};
  final List<Map<String, dynamic>> bookings = [];
  int _nextId = 100;

  Future<dynamic> post(
    String path,
    Map<String, dynamic> body,
    Map<String, String> headers,
  ) async {
    if (offline) throw ApiException(0, 'offline');
    final key = headers['Idempotency-Key'];
    if (key != null && _byKey.containsKey(key)) return _byKey[key];
    final refusal = refuseNext;
    if (refusal != null && refusal.path == path) {
      refuseNext = null;
      throw ApiException(refusal.status, refusal.message);
    }

    sent.add((path: path, body: body, key: key));
    final Map<String, dynamic> response;
    if (path == '/leads') {
      final clientId = body['client_id'] as String;
      final id = leadsByClientId[clientId] ??= _nextId++;
      response = _leadJson(id, body);
    } else if (path == '/trial-bookings') {
      final booking = <String, dynamic>{
        'id': _nextId++,
        'lead_id': body['lead_id'],
        'session_id': 1,
        'status': 'scheduled',
        'version': 1,
      };
      bookings.add(booking);
      response = booking;
    } else {
      response = <String, dynamic>{'id': _nextId++, ...body};
    }
    if (key != null) _byKey[key] = response;
    if (loseNextResponse) {
      loseNextResponse = false;
      throw ApiException(0, 'timeout');
    }
    return response;
  }

  static Map<String, dynamic> _leadJson(int id, Map<String, dynamic> body) =>
      <String, dynamic>{
        'id': id,
        'client_id': body['client_id'],
        'full_name': body['full_name'],
        'phone': body['phone'],
        'stage': 'new',
        'version': 1,
        'created_at': '2026-10-17T10:00:00Z',
      };
}

/// ApiClient whose network goes to [FakeServer].
class FakeApiClient extends ApiClient {
  FakeApiClient(this.server) : super(TokenStorage());

  final FakeServer server;

  @override
  Future<dynamic> post(
    String path, {
    Object? body,
    bool withAuth = true,
    Duration? timeout,
    Map<String, String>? headers,
  }) => server.post(
    path,
    (body as Map<String, dynamic>?) ?? const {},
    headers ?? const {},
  );
}

void main() {
  sqfliteFfiInit();

  late LocalDatabase localDb;
  late OutboxStore outbox;
  late FakeServer server;
  late SyncEngine engine;
  late AdmissionsRepository repo;

  setUp(() {
    localDb = LocalDatabase(
      factory: databaseFactoryFfiNoIsolate,
      path: inMemoryDatabasePath,
    );
    outbox = OutboxStore(localDb);
    server = FakeServer();
    engine = SyncEngine(outbox: outbox, send: server.post);
    repo = AdmissionsRepository(
      api: FakeApiClient(server),
      localDb: localDb,
      outbox: outbox,
      sync: engine,
    );
  });

  tearDown(() async {
    engine.dispose();
    await localDb.close();
  });

  NewTrialSession session() => NewTrialSession(
    teacherId: 7,
    startsAt: DateTime.utc(2026, 10, 20, 10),
    endsAt: DateTime.utc(2026, 10, 20, 11),
    capacity: 5,
  );

  Future<Lead> queueLeadOffline() async {
    server.offline = true;
    final outcome = await repo.createLead(
      fullName: 'Aziza',
      phone: '998901234567',
      subjectId: 3,
      subjectName: 'Ingliz tili',
    );
    expect(outcome.queued, isTrue);
    final pending = await repo.pendingLeads();
    expect(pending, hasLength(1));
    return pending.single;
  }

  test('an offline lead and its trial sync in order, exactly once', () async {
    final lead = await queueLeadOffline();
    expect(lead.isPending, isTrue);
    expect(lead.subjectName, 'Ingliz tili');

    final booking = await repo.bookTrial(lead, session: session());
    final note = await repo.addInteraction(
      lead,
      kind: 'call_in',
      body: 'Kechqurun qulay {lead}',
    );
    expect(booking.queued && note.queued, isTrue);
    expect(server.sent, isEmpty);

    // Still offline: nothing goes, nothing is lost.
    await engine.drain();
    expect(engine.online.value, isFalse);
    expect(await outbox.countPending(), 3);

    server.offline = false;
    await engine.drain();

    expect(server.sent.map((s) => s.path), <String>[
      '/leads',
      '/trial-bookings',
      '/leads/100/interactions',
    ]);
    final leadBody = server.sent[0].body;
    expect(leadBody['on_duplicate'], 'merge');
    expect(leadBody['client_id'], lead.clientId);
    // The booking was queued against the local lead; it went out with the
    // real id the server gave that lead.
    expect(server.sent[1].body['lead_id'], 100);
    expect(server.sent[1].body['session']['teacher_id'], 7);
    // Text someone typed is never treated as a placeholder.
    expect(server.sent[2].body['body'], 'Kechqurun qulay {lead}');
    expect(server.bookings, hasLength(1));
    expect(await outbox.countPending(), 0);
    expect(await repo.pendingLeads(), isEmpty);
    expect(engine.pendingCount.value, 0);
    expect(engine.online.value, isTrue);
  });

  test('a write whose response was lost is answered, not redone', () async {
    await queueLeadOffline();
    server.offline = false;
    server.loseNextResponse = true;

    await engine.drain();
    // The server has it; the app doesn't know yet.
    expect(server.leadsByClientId, hasLength(1));
    expect(await outbox.countPending(), 1);

    await engine.drain();
    expect(server.sent, hasLength(1));
    expect(server.leadsByClientId, hasLength(1));
    expect(await outbox.countPending(), 0);
  });

  test('a lost online response is safe to queue and resend', () async {
    // Online, the booking lands but the answer never arrives: the queued
    // copy reuses the same key, so the server replays its first answer.
    server.offline = false;
    final lead = Lead(
      id: 55,
      clientId: 'c',
      fullName: 'Ali',
      phone: '998901111111',
      stage: LeadStage.contacted,
      version: 2,
      createdAt: DateTime(2026),
    );
    server.loseNextResponse = true;
    final outcome = await repo.bookTrial(lead, session: session());
    expect(outcome.queued, isTrue);

    await engine.drain();
    expect(server.bookings, hasLength(1));
    expect(server.sent, hasLength(1));
    expect(await outbox.countPending(), 0);
  });

  test(
    'a refused write is parked with its reason; its dependents wait',
    () async {
      final lead = await queueLeadOffline();
      await repo.bookTrial(lead, session: session());
      server.offline = false;
      server.refuseNext = (
        path: '/trial-bookings',
        status: 409,
        message: 'Sinov darsida joy yo\'q (5/5).',
      );

      // The lead goes; the booking is refused.
      await engine.drain();
      var pending = await outbox.listPending();
      expect(pending, hasLength(1));
      expect(pending.single.isFailed, isTrue);
      expect(pending.single.lastError, 'Sinov darsida joy yo\'q (5/5).');

      // Not retried by itself -- the same request would get the same answer.
      await engine.drain();
      expect(server.bookings, isEmpty);

      // Someone frees a seat and retries it.
      await repo.retryPending(pending.single.seq);
      expect(server.bookings, hasLength(1));
      pending = await outbox.listPending();
      expect(pending, isEmpty);
    },
  );

  test('discarding a queued lead discards what was queued for it', () async {
    final lead = await queueLeadOffline();
    await repo.bookTrial(lead, session: session());
    await repo.addTask(
      lead,
      title: 'Qo\'ng\'iroq',
      dueAt: DateTime(2026, 10, 21),
    );
    final leadRow = (await outbox.listPending()).first;

    await repo.discardPending(leadRow.seq);

    expect(await outbox.countPending(), 0);
    server.offline = false;
    await engine.drain();
    expect(server.sent, isEmpty);
  });

  test(
    'a write left in flight by a killed app is sent again on start',
    () async {
      await queueLeadOffline();
      final row = (await outbox.listPending()).single;
      await outbox.markInFlight(row.seq);
      server.offline = false;

      // In flight rows are never picked up within one process...
      await engine.drain();
      expect(server.sent, isEmpty);

      // ...but the next app start recovers them.
      await engine.start();
      expect(server.sent, hasLength(1));
      expect(await outbox.countPending(), 0);
    },
  );
}
