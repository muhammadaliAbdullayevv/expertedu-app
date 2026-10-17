import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:uuid/uuid.dart';

import '../../../services/api/api_client.dart';
import 'admissions_models.dart';
import 'qabul_models.dart';

final qabulRepositoryProvider = Provider<QabulRepository>((ref) {
  return QabulRepository(ref.watch(apiClientProvider));
});

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Online-only reads for the Qabul board, the course finder and the shared
/// counts. Every number comes from the server's one definition
/// (server/app/funnel.py); nothing here counts anything.
class QabulRepository {
  QabulRepository(this._api);

  final ApiClient _api;

  Future<AdmissionsBoard> board({DateTime? from, DateTime? to}) async {
    final json = await _api.get(
      '/admissions/board',
      query: {
        if (from != null) 'date_from': _day(from),
        if (to != null) 'date_to': _day(to),
      },
    );
    return AdmissionsBoard.fromJson(json as Map<String, dynamic>);
  }

  Future<GroupSearchResult> searchGroups({
    int? subjectId,
    String? level,
    Set<int> weekdays = const {},
    String? timeOfDay,
  }) async {
    final json = await _api.get(
      '/groups/search',
      query: {
        'subject_id': ?(subjectId == null ? null : '$subjectId'),
        'level': ?level,
        if (weekdays.isNotEmpty)
          'weekdays': (weekdays.toList()..sort()).join(','),
        'time_of_day': ?timeOfDay,
      },
    );
    return GroupSearchResult.fromJson(json as Map<String, dynamic>);
  }

  Future<List<String>> levels({int? subjectId}) async {
    final json = await _api.get(
      '/groups/levels',
      query: {'subject_id': ?(subjectId == null ? null : '$subjectId')},
    );
    return (json as List<dynamic>).cast<String>();
  }

  Future<List<TrialDate>> trialDates(int groupId, {int count = 3}) async {
    final json = await _api.get(
      '/groups/$groupId/trial-dates',
      query: {'count': '$count'},
    );
    return (json as List<dynamic>)
        .map((e) => TrialDate.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Saves what a client asked for as an inquiry -- or, if their phone
  /// already has an open one for the course, adds to that one (the server
  /// folds it into the timeline). Online only: the next steps (a trial, a
  /// group) need the server anyway.
  Future<Lead> saveInquiry({
    required String fullName,
    required String phone,
    int? subjectId,
    String? source,
    String? note,
    String? level,
    Set<int> weekdays = const {},
    String? timeOfDay,
  }) async {
    final json = await _api.post(
      '/leads',
      body: <String, dynamic>{
        'client_id': const Uuid().v4(),
        'full_name': fullName,
        'phone': phone,
        'subject_id': subjectId,
        'source': source,
        'note': note,
        'level': level,
        'desired_weekdays': weekdays.isEmpty
            ? null
            : (weekdays.toList()..sort()),
        'desired_time_of_day': timeOfDay,
        'on_duplicate': 'merge',
      },
      headers: {'Idempotency-Key': const Uuid().v4()},
    );
    return Lead.fromJson(json as Map<String, dynamic>);
  }

  Future<ShellCounts> shellCounts() async =>
      ShellCounts.fromJson(await _api.get('/counts') as Map<String, dynamic>);

  Future<StudentSummary> studentSummary() async => StudentSummary.fromJson(
    await _api.get('/students/summary') as Map<String, dynamic>,
  );
}
