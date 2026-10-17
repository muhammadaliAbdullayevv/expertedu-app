import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/formatters/phone_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../../services/local_db/local_database.dart';
import '../../../services/sync/outbox_store.dart';
import '../../../services/sync/sync_engine.dart';
import '../../groups/data/groups_repository.dart';
import '../../subjects/data/subjects_repository.dart';
import '../../teachers/data/teachers_repository.dart';
import 'admissions_models.dart';

final admissionsRepositoryProvider = Provider<AdmissionsRepository>((ref) {
  return AdmissionsRepository(
    api: ref.watch(apiClientProvider),
    localDb: ref.watch(localDatabaseProvider),
    outbox: ref.watch(outboxStoreProvider),
    sync: ref.watch(syncEngineProvider),
  );
});

const _uuid = Uuid();

/// A write that may have been queued instead of sent: [value] is the
/// server's answer, or null when it's waiting in the offline outbox.
class WriteOutcome<T> {
  const WriteOutcome.sent(T this.value) : queued = false;
  const WriteOutcome.queued() : value = null, queued = true;

  final T? value;
  final bool queued;
}

/// A new trial session, entered together with a booking.
class NewTrialSession {
  const NewTrialSession({
    this.kind = 'dedicated',
    this.subjectId,
    this.groupId,
    this.teacherId,
    this.room,
    required this.startsAt,
    required this.endsAt,
    required this.capacity,
    this.note,
  });

  final String kind;
  final int? subjectId;
  final int? groupId;
  final int? teacherId;
  final String? room;
  final DateTime startsAt;
  final DateTime endsAt;
  final int capacity;
  final String? note;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'subject_id': subjectId,
    'group_id': groupId,
    'teacher_id': teacherId,
    'room': room,
    'starts_at': startsAt.toUtc().toIso8601String(),
    'ends_at': endsAt.toUtc().toIso8601String(),
    'capacity': capacity,
    'note': note,
  };
}

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Admissions: leads, their timeline, follow-ups and trials.
///
/// Creating a lead, logging a note or call, adding a follow-up and booking
/// a trial work offline: when the server can't be reached they're queued
/// in the outbox (with their own Idempotency-Key) and sent by SyncEngine
/// later. Everything else -- stage changes, attendance, and above all
/// enrollment, which creates charges -- needs the server there and then.
class AdmissionsRepository {
  AdmissionsRepository({
    required this._api,
    required this._localDb,
    required this._outbox,
    required this._sync,
  });

  final ApiClient _api;
  final LocalDatabase _localDb;
  final OutboxStore _outbox;
  final SyncEngine _sync;

  static bool _isOffline(Object error) =>
      error is ApiException && error.statusCode == 0;

  /// A read that falls back to its last good answer while offline.
  Future<dynamic> _cachedGet(
    String cacheKey,
    String path, {
    Map<String, String>? query,
  }) async {
    try {
      final json = await _api.get(path, query: query);
      _sync.reportOnline();
      try {
        await _localDb.saveBlob(cacheKey, json);
      } catch (_) {
        // The cache is a convenience; a fresh answer is still an answer.
      }
      return json;
    } catch (e) {
      if (!_isOffline(e)) rethrow;
      _sync.reportOffline();
      final cached = await _localDb.readBlob(cacheKey).catchError((_) => null);
      if (cached == null) rethrow;
      return cached;
    }
  }

  // --- Reads ----------------------------------------------------------------

  Future<LeadPage> listLeads({
    String scope = 'open',
    String? query,
    int? assignedTo,
    int? groupId,
    bool groupless = false,
    bool withTrial = false,
    bool archive = false,
    int limit = 500,
  }) async {
    final params = <String, String>{
      'scope': scope,
      'limit': '$limit',
      if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
      if (assignedTo != null) 'assigned_to': '$assignedTo',
      if (groupId != null) 'group_id': '$groupId',
      if (groupless) 'groupless': 'true',
      if (withTrial) 'with_trial': 'true',
      if (archive) 'archive': 'true',
    };
    // Only the unfiltered lists are worth keeping for offline use.
    final cacheable = params.length == 2;
    final json = cacheable
        ? await _cachedGet('leads:$scope', '/leads', query: params)
        : await _api.get('/leads', query: params);
    return LeadPage.fromJson(json as Map<String, dynamic>);
  }

  /// Leads made offline and still waiting to be sent, newest first.
  Future<List<Lead>> pendingLeads() async {
    final items = await _outbox.listPending(entity: 'lead');
    return <Lead>[
      for (final item in items.reversed)
        if (item.op == 'create') _pendingLead(item),
    ];
  }

  static Lead _pendingLead(OutboxItem item) {
    final body = item.payload['body'] as Map<String, dynamic>;
    return Lead(
      id: 0,
      clientId: item.localId,
      fullName: body['full_name'] as String,
      phone: body['phone'] as String,
      parentPhone: body['parent_phone'] as String?,
      note: body['note'] as String?,
      subjectId: body['subject_id'] as int?,
      subjectName: item.payload['subject_name'] as String?,
      source: body['source'] as String?,
      groupId: body['group_id'] as int?,
      groupName: item.payload['group_name'] as String?,
      stage: LeadStage.newLead,
      assignedTo: body['assigned_to'] as int?,
      version: 0,
      createdAt: item.createdAt,
      pendingLocalId: item.localId,
    );
  }

  Future<PhoneLookup> lookupPhone(String phone) async {
    final json = await _api.get('/leads/lookup', query: {'phone': phone});
    return PhoneLookup.fromJson(json as Map<String, dynamic>);
  }

  Future<LeadDetail> getLead(int id) async {
    final json = await _api.get('/leads/$id');
    return LeadDetail.fromJson(json as Map<String, dynamic>);
  }

  Future<List<TrialSession>> listSessions(
    DateTime from,
    DateTime to, {
    bool includeCancelled = false,
  }) async {
    final query = <String, String>{
      'date_from': _dateStr(from),
      'date_to': _dateStr(to),
      'include_cancelled': '$includeCancelled',
    };
    final json = await _cachedGet(
      'trial-sessions:${query.values.join(':')}',
      '/trial-sessions',
      query: query,
    );
    return (json as List<dynamic>)
        .map((e) => TrialSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<FollowUpTask>> listTasks({
    String status = 'open',
    int? assignedTo,
  }) async {
    final query = <String, String>{
      'status_filter': status,
      if (assignedTo != null) 'assigned_to': '$assignedTo',
    };
    final json = await _cachedGet(
      'tasks:${query.values.join(':')}',
      '/follow-up-tasks',
      query: query,
    );
    return (json as List<dynamic>)
        .map((e) => FollowUpTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AdmissionsReport> report(DateTime from, DateTime to) async {
    final json = await _api.get(
      '/admissions/report',
      query: {'date_from': _dateStr(from), 'date_to': _dateStr(to)},
    );
    return AdmissionsReport.fromJson(json as Map<String, dynamic>);
  }

  // The pickers' lists, cached so the offline dialogs still have them.

  Future<List<StaffUser>> users() async {
    final json = await _cachedGet('users', '/users') as List<dynamic>;
    return json
        .map((e) => StaffUser.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Subject>> subjects() async {
    final json = await _cachedGet('subjects', '/subjects') as List<dynamic>;
    return json
        .map((e) => Subject.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Teacher>> teachers() async {
    final json = await _cachedGet('teachers', '/teachers') as List<dynamic>;
    return json
        .map((e) => Teacher.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Group>> groups() async {
    final json = await _cachedGet(
      'groups',
      '/groups',
      query: {'include_inactive': 'false'},
    );
    return (json as List<dynamic>)
        .map((e) => Group.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // --- Writes that work offline -----------------------------------------------

  /// Creates a lead. Online, a phone that already has an open lead for the
  /// course is a 409 the dialog shows. Offline, the lead is queued with
  /// on_duplicate=merge -- nobody's there to decide when it's finally
  /// sent, so a duplicate is folded into the existing lead's timeline.
  Future<WriteOutcome<Lead>> createLead({
    required String fullName,
    required String phone,
    String? parentPhone,
    int? subjectId,
    String? subjectName,
    String? source,
    String? note,
    int? assignedTo,
  }) async {
    final clientId = _uuid.v4();
    final body = <String, dynamic>{
      'client_id': clientId,
      'full_name': fullName,
      'phone': phone,
      'parent_phone': parentPhone,
      'subject_id': subjectId,
      'source': source,
      'note': note,
      'assigned_to': assignedTo,
    };
    try {
      final json = await _api.post(
        '/leads',
        body: <String, dynamic>{...body, 'on_duplicate': 'reject'},
        headers: {'Idempotency-Key': _uuid.v4()},
      );
      _sync.reportOnline();
      return WriteOutcome.sent(Lead.fromJson(json as Map<String, dynamic>));
    } catch (e) {
      if (!_isOffline(e)) rethrow;
      _sync.reportOffline();
    }
    // The online attempt may still have landed; if it did, the server
    // finds it by client_id and answers with it. (A new key: the queued
    // request isn't the same request -- it merges duplicates.)
    await _outbox.enqueue(
      entity: 'lead',
      op: 'create',
      localId: clientId,
      idempotencyKey: _uuid.v4(),
      description: 'Yangi so\'rov: $fullName, ${PhoneFormatter.display(phone)}',
      payload: <String, dynamic>{
        'path': '/leads',
        'body': <String, dynamic>{...body, 'on_duplicate': 'merge'},
        // Display only, for the pending row in the list.
        'subject_name': subjectName,
      },
    );
    await _sync.refreshCount();
    return const WriteOutcome.queued();
  }

  Future<WriteOutcome<LeadInteraction>> addInteraction(
    Lead lead, {
    required String kind,
    required String body,
  }) async {
    final payload = <String, dynamic>{'kind': kind, 'body': body};
    final label = LeadInteraction.kindLabels[kind] ?? kind;
    final outcome = await _offlineCapablePost(
      lead: lead,
      entity: 'lead_interaction',
      path: (id) => '/leads/$id/interactions',
      body: payload,
      description: '$label: ${lead.fullName}',
    );
    return outcome == null
        ? const WriteOutcome.queued()
        : WriteOutcome.sent(LeadInteraction.fromJson(outcome));
  }

  Future<WriteOutcome<FollowUpTask>> addTask(
    Lead lead, {
    required String title,
    required DateTime dueAt,
    int? assignedTo,
  }) async {
    final outcome = await _offlineCapablePost(
      lead: lead,
      entity: 'follow_up_task',
      path: (_) => '/follow-up-tasks',
      body: <String, dynamic>{
        'title': title,
        'due_at': dueAt.toUtc().toIso8601String(),
        'assigned_to': assignedTo,
      },
      leadIdField: 'lead_id',
      description: 'Vazifa: $title (${lead.fullName})',
    );
    return outcome == null
        ? const WriteOutcome.queued()
        : WriteOutcome.sent(FollowUpTask.fromJson(outcome));
  }

  /// Books a trial in an existing session ([sessionId]) or a new one
  /// ([session]). Never enrolls anyone. Offline, the server checks seats
  /// and clashes when it's sent -- a refusal then shows up in the
  /// pending-changes list with the reason.
  Future<WriteOutcome<TrialBooking>> bookTrial(
    Lead lead, {
    int? sessionId,
    NewTrialSession? session,
    bool remind = false,
  }) async {
    final outcome = await _offlineCapablePost(
      lead: lead,
      entity: 'trial_booking',
      path: (_) => '/trial-bookings',
      body: <String, dynamic>{
        'session_id': sessionId,
        'session': session?.toJson(),
        'remind': remind,
      },
      leadIdField: 'lead_id',
      description: 'Sinov darsi: ${lead.fullName}',
    );
    return outcome == null
        ? const WriteOutcome.queued()
        : WriteOutcome.sent(TrialBooking.fromJson(outcome));
  }

  /// POSTs a write about [lead] -- or queues it, when offline or when the
  /// lead itself is still queued (it waits for that lead's create). Null
  /// means queued.
  Future<Map<String, dynamic>?> _offlineCapablePost({
    required Lead lead,
    required String entity,
    required String Function(Object leadId) path,
    required Map<String, dynamic> body,
    required String description,
    String? leadIdField,
  }) async {
    final key = _uuid.v4();
    if (!lead.isPending) {
      try {
        final json = await _api.post(
          path(lead.id),
          body: <String, dynamic>{...body, ?leadIdField: lead.id},
          headers: {'Idempotency-Key': key},
        );
        _sync.reportOnline();
        return json as Map<String, dynamic>;
      } catch (e) {
        if (!_isOffline(e)) rethrow;
        _sync.reportOffline();
      }
    }

    // The same key as the attempt above: if that one landed after all,
    // this is a replay the server answers without doing it twice.
    final waitFor = lead.isPending
        ? await _outbox.findOpenCreateSeq(
            entity: 'lead',
            targetId: lead.pendingLocalId!,
          )
        : null;
    final leadValue = lead.isPending ? '{lead}' : lead.id;
    await _outbox.enqueue(
      entity: entity,
      op: 'create',
      localId: _uuid.v4(),
      idempotencyKey: key,
      description: description,
      dependsOnSeq: waitFor,
      payload: <String, dynamic>{
        'path': path(lead.isPending ? '{lead}' : lead.id),
        'body': <String, dynamic>{...body, ?leadIdField: leadValue},
        if (lead.isPending)
          'refs': <String, dynamic>{
            'lead': <String, dynamic>{
              'entity': 'lead',
              'local_id': lead.pendingLocalId,
            },
          },
      },
    );
    await _sync.refreshCount();
    return null;
  }

  // --- Online-only writes -------------------------------------------------------

  Future<Lead> updateLead(Lead lead, Map<String, dynamic> changes) async {
    final json = await _api.patch(
      '/leads/${lead.id}',
      body: <String, dynamic>{'version': lead.version, ...changes},
    );
    return Lead.fromJson(json as Map<String, dynamic>);
  }

  Future<Lead> changeStage(
    Lead lead,
    String stage, {
    String? reason,
    DateTime? followUpAt,
  }) async {
    final json = await _api.post(
      '/leads/${lead.id}/stage',
      body: <String, dynamic>{
        'version': lead.version,
        'stage': stage,
        'reason': reason,
        'follow_up_at': followUpAt?.toUtc().toIso8601String(),
      },
    );
    return Lead.fromJson(json as Map<String, dynamic>);
  }

  Future<TrialBooking> markAttendance(int bookingId, String status) async {
    final json = await _api.post(
      '/trial-bookings/$bookingId/attendance',
      body: <String, dynamic>{'status': status},
    );
    return TrialBooking.fromJson(json as Map<String, dynamic>);
  }

  Future<TrialBooking> recordFeedback(
    int bookingId, {
    required String feedback,
    String? recommendedLevel,
  }) async {
    final json = await _api.post(
      '/trial-bookings/$bookingId/feedback',
      body: <String, dynamic>{
        'feedback': feedback,
        'recommended_level': recommendedLevel,
      },
    );
    return TrialBooking.fromJson(json as Map<String, dynamic>);
  }

  Future<void> cancelBooking(int bookingId, {String? reason}) => _api.post(
    '/trial-bookings/$bookingId/cancel',
    body: <String, dynamic>{'reason': reason},
  );

  Future<TrialBooking> reschedule(
    int bookingId, {
    int? sessionId,
    NewTrialSession? session,
    String? reason,
  }) async {
    final json = await _api.post(
      '/trial-bookings/$bookingId/reschedule',
      body: <String, dynamic>{
        'session_id': sessionId,
        'session': session?.toJson(),
        'reason': reason,
      },
      headers: {'Idempotency-Key': _uuid.v4()},
    );
    return TrialBooking.fromJson(json as Map<String, dynamic>);
  }

  Future<void> cancelSession(int sessionId, {String? reason}) => _api.post(
    '/trial-sessions/$sessionId/cancel',
    body: <String, dynamic>{'reason': reason},
  );

  Future<FollowUpTask> completeTask(int taskId, {String? note}) async {
    final json = await _api.post(
      '/follow-up-tasks/$taskId/complete',
      body: <String, dynamic>{'reason': note},
    );
    return FollowUpTask.fromJson(json as Map<String, dynamic>);
  }

  Future<FollowUpTask> cancelTask(int taskId) async {
    final json = await _api.post(
      '/follow-up-tasks/$taskId/cancel',
      body: const <String, dynamic>{},
    );
    return FollowUpTask.fromJson(json as Map<String, dynamic>);
  }

  Future<FollowUpTask> rescheduleTask(FollowUpTask task, DateTime dueAt) async {
    final json = await _api.patch(
      '/follow-up-tasks/${task.id}',
      body: <String, dynamic>{
        'version': task.version,
        'due_at': dueAt.toUtc().toIso8601String(),
      },
    );
    return FollowUpTask.fromJson(json as Map<String, dynamic>);
  }

  /// The explicit enrollment step. [idempotencyKey] is made once per
  /// wizard, so resending after a lost response returns the first result
  /// instead of enrolling twice.
  Future<LeadEnrolled> enrollLead(
    int leadId, {
    required String idempotencyKey,
    required Map<String, dynamic> body,
  }) async {
    final json = await _api.post(
      '/leads/$leadId/enroll',
      body: body,
      headers: {'Idempotency-Key': idempotencyKey},
      timeout: const Duration(seconds: 30),
    );
    return LeadEnrolled.fromJson(json as Map<String, dynamic>);
  }

  // --- Outbox -----------------------------------------------------------------

  Future<List<OutboxItem>> pendingChanges() => _outbox.listPending();

  Future<void> retryPending(int seq) async {
    await _outbox.retry(seq);
    await _sync.drain();
  }

  Future<void> discardPending(int seq) async {
    await _outbox.discard(seq);
    await _sync.refreshCount();
  }
}
