// The app's admissions code against a real, running API -- every request it
// makes and every response it parses. Opt-in: needs a throwaway server
// with a seeded database, e.g.
//
//   flutter test test/integration \
//     --dart-define=API_BASE_URL=http://127.0.0.1:8765 \
//     --dart-define=E2E_PHONE=901112233 --dart-define=E2E_PASSWORD=secret123
//
// It creates leads, trials and an enrollment, so never point it at real data.

import 'package:expert_edu_center/features/admissions/data/admissions_models.dart';
import 'package:expert_edu_center/features/admissions/data/admissions_repository.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:expert_edu_center/services/local_db/local_database.dart';
import 'package:expert_edu_center/services/sync/outbox_store.dart';
import 'package:expert_edu_center/services/sync/sync_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

const _phone = String.fromEnvironment('E2E_PHONE');
const _password = String.fromEnvironment('E2E_PASSWORD');

class _MemoryTokens extends TokenStorage {
  String? token;

  @override
  Future<String?> readToken() async => token;
}

/// Sends nothing while [offline] -- the network is "down".
class _SwitchableApi extends ApiClient {
  _SwitchableApi(super.tokens);

  bool offline = false;

  @override
  Future<dynamic> post(
    String path, {
    Object? body,
    bool withAuth = true,
    Duration? timeout,
    Map<String, String>? headers,
  }) {
    if (offline) throw ApiException(0, 'offline');
    return super.post(
      path,
      body: body,
      withAuth: withAuth,
      timeout: timeout,
      headers: headers,
    );
  }
}

void main() {
  final skip = _phone.isEmpty ? 'set E2E_PHONE/E2E_PASSWORD to run' : null;
  sqfliteFfiInit();

  late _SwitchableApi api;
  late LocalDatabase localDb;
  late SyncEngine engine;
  late AdmissionsRepository repo;
  // Its own teacher per run: the server refuses a second trial for the
  // same teacher at the same time, which a rerun would otherwise ask for.
  late int teacherId;
  // A number nobody has, so reruns don't collide.
  final phone =
      '9989${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';

  setUpAll(() async {
    if (skip != null) return;
    final tokens = _MemoryTokens();
    api = _SwitchableApi(tokens);
    final login =
        await api.post(
              '/auth/login',
              body: {'phone': _phone, 'password': _password},
              withAuth: false,
            )
            as Map<String, dynamic>;
    tokens.token = login['token'] as String;
    final teacher =
        await api.post(
              '/teachers',
              body: {
                'full_name': 'E2E ${DateTime.now().microsecondsSinceEpoch}',
              },
            )
            as Map<String, dynamic>;
    teacherId = teacher['id'] as int;
    localDb = LocalDatabase(
      factory: databaseFactoryFfiNoIsolate,
      path: inMemoryDatabasePath,
    );
    final outbox = OutboxStore(localDb);
    engine = SyncEngine(
      outbox: outbox,
      send: (path, body, headers) =>
          api.post(path, body: body, headers: headers),
    );
    repo = AdmissionsRepository(
      api: api,
      localDb: localDb,
      outbox: outbox,
      sync: engine,
    );
  });

  test('a lead from first call to enrollment', skip: skip, () async {
    final subjects = await repo.subjects();
    final groups = await repo.groups();
    final users = await repo.users();
    expect(subjects, isNotEmpty);
    expect(users, isNotEmpty);

    final lookup = await repo.lookupPhone(phone);
    expect(lookup.student, isNull);
    expect(lookup.leads, isEmpty);

    final created = await repo.createLead(
      fullName: 'E2E Aziza',
      phone: phone,
      subjectId: subjects.first.id,
      source: 'instagram',
      note: 'Kechqurun qulay',
    );
    final lead = created.value!;
    expect(lead.stage, LeadStage.newLead);
    expect(lead.subjectName, subjects.first.name);

    final call = await repo.addInteraction(
      lead,
      kind: 'call_out',
      body: 'Narxlarni aytdim',
    );
    expect(call.value!.kind, 'call_out');

    final start = DateTime.now().add(const Duration(days: 2));
    final booked = await repo.bookTrial(
      lead,
      session: NewTrialSession(
        subjectId: subjects.first.id,
        teacherId: teacherId,
        room: 'E2E-${const Uuid().v4().substring(0, 6)}',
        startsAt: start,
        endsAt: start.add(const Duration(hours: 1)),
        capacity: 3,
      ),
    );
    final booking = booked.value!;
    expect(booking.status, TrialStatus.scheduled);
    expect(booking.session!.teacherId, teacherId);

    final sessions = await repo.listSessions(start, start);
    expect(sessions.map((s) => s.id), contains(booking.sessionId));

    final task = await repo.addTask(
      lead,
      title: 'Qaror so\'rash',
      dueAt: DateTime.now().add(const Duration(days: 3)),
    );
    expect(task.value!.leadFullName, 'E2E Aziza');
    expect(await repo.listTasks(), isNotEmpty);

    var detail = await repo.getLead(lead.id);
    expect(detail.lead.stage, LeadStage.trialScheduled);
    expect(detail.bookings.single.session, isNotNull);
    expect(detail.interactions.length, greaterThanOrEqualTo(4));

    final pipeline = await repo.listLeads();
    expect(pipeline.items.map((l) => l.id), contains(lead.id));
    final search = await repo.listLeads(query: phone.substring(6));
    expect(search.items.single.id, lead.id);

    final report = await repo.report(
      DateTime.now().subtract(const Duration(days: 1)),
      DateTime.now(),
    );
    expect(report.newInquiries, greaterThanOrEqualTo(1));
    expect(report.openByStage.map((r) => r.key), contains('trial_scheduled'));

    final group = groups.firstWhere((g) => g.subjectId == subjects.first.id);
    final key = const Uuid().v4();
    final body = <String, dynamic>{
      'full_name': 'E2E Aziza',
      'phone': phone,
      'group_id': group.id,
      'joined_at': DateTime.now().toIso8601String().substring(0, 10),
      'first_month': 'full',
    };
    final enrolled = await repo.enrollLead(
      lead.id,
      idempotencyKey: key,
      body: body,
    );
    final again = await repo.enrollLead(
      lead.id,
      idempotencyKey: key,
      body: body,
    );
    expect(again.enrollmentId, enrolled.enrollmentId);
    expect(enrolled.reusedStudent, isFalse);

    detail = await repo.getLead(lead.id);
    expect(detail.lead.stage, LeadStage.enrolled);
    expect(detail.lead.enrollmentId, enrolled.enrollmentId);
    // The booked trial and open task were closed, and kept.
    expect(detail.bookings.single.status, TrialStatus.cancelled);
    expect(detail.tasks.single.status, 'cancelled');
    expect(detail.interactions.first.body, startsWith('Guruhga yozildi'));
  });

  test(
    'a lead and trial made offline reach the server once',
    skip: skip,
    () async {
      final offlinePhone =
          '${phone.substring(0, 11)}${(int.parse(phone[11]) + 1) % 10}';
      api.offline = true;

      final created = await repo.createLead(
        fullName: 'E2E Oflayn',
        phone: offlinePhone,
      );
      expect(created.queued, isTrue);
      final pending = (await repo.pendingLeads()).single;
      final start = DateTime.now().add(const Duration(days: 4));
      final booked = await repo.bookTrial(
        pending,
        session: NewTrialSession(
          teacherId: teacherId,
          startsAt: start,
          endsAt: start.add(const Duration(minutes: 45)),
          capacity: 2,
        ),
      );
      expect(booked.queued, isTrue);

      api.offline = false;
      await engine.drain();
      expect(engine.pendingCount.value, 0);
      expect(await repo.pendingLeads(), isEmpty);

      final lookup = await repo.lookupPhone(offlinePhone);
      final lead = lookup.leads.single;
      expect(lead.clientId, pending.clientId);
      expect(lead.stage, LeadStage.trialScheduled);

      // Sending the same queue again changes nothing.
      await engine.drain();
      expect((await repo.lookupPhone(offlinePhone)).leads, hasLength(1));
    },
  );
}
