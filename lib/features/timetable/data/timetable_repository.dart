import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import 'timetable_models.dart';

final timetableRepositoryProvider = Provider<TimetableRepository>((ref) {
  return TimetableRepository(ref.watch(apiClientProvider));
});

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Group schedules, the timetable and attendance
/// (server/app/routes/timetable.py). A lesson is identified by its group
/// and start time.
class TimetableRepository {
  TimetableRepository(this._api);

  final ApiClient _api;

  Future<List<ScheduleSlot>> schedule(int groupId) async {
    final json =
        await _api.get('/groups/$groupId/schedule') as Map<String, dynamic>;
    return (json['slots'] as List<dynamic>)
        .map((e) => ScheduleSlot.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> setSchedule(int groupId, List<ScheduleSlot> slots) => _api.put(
    '/groups/$groupId/schedule',
    body: <String, dynamic>{
      'slots': [for (final slot in slots) slot.toJson()],
    },
  );

  Future<List<TimetableLesson>> lessons(
    DateTime from,
    DateTime to, {
    int? groupId,
    int? teacherId,
  }) async {
    final json =
        await _api.get(
              '/timetable',
              query: <String, String>{
                'date_from': _day(from),
                'date_to': _day(to),
                if (groupId != null) 'group_id': '$groupId',
                if (teacherId != null) 'teacher_id': '$teacherId',
              },
            )
            as List<dynamic>;
    return json
        .map((e) => TimetableLesson.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<AttendanceSheet> sheet(int groupId, DateTime startsAt) async {
    final json = await _api.get(
      '/lessons/sheet',
      query: <String, String>{
        'group_id': '$groupId',
        'starts_at': startsAt.toUtc().toIso8601String(),
      },
    );
    return AttendanceSheet.fromJson(json as Map<String, dynamic>);
  }

  Future<AttendanceSheet> mark(
    int groupId,
    DateTime startsAt,
    Map<int, String> statuses,
  ) async {
    final json = await _api.put(
      '/lessons/attendance',
      body: <String, dynamic>{
        'group_id': groupId,
        'starts_at': startsAt.toUtc().toIso8601String(),
        'marks': [
          for (final entry in statuses.entries)
            {'enrollment_id': entry.key, 'status': entry.value},
        ],
      },
    );
    return AttendanceSheet.fromJson(json as Map<String, dynamic>);
  }

  Future<void> cancel(int groupId, DateTime startsAt, {String? reason}) =>
      _api.post(
        '/lessons/cancel',
        body: <String, dynamic>{
          'group_id': groupId,
          'starts_at': startsAt.toUtc().toIso8601String(),
          'reason': reason,
        },
      );

  Future<void> restore(int groupId, DateTime startsAt) => _api.post(
    '/lessons/restore',
    body: <String, dynamic>{
      'group_id': groupId,
      'starts_at': startsAt.toUtc().toIso8601String(),
    },
  );

  Future<void> addExtra({
    required int groupId,
    required DateTime startsAt,
    required DateTime endsAt,
    String? room,
    String? note,
  }) => _api.post(
    '/lessons',
    body: <String, dynamic>{
      'group_id': groupId,
      'starts_at': startsAt.toUtc().toIso8601String(),
      'ends_at': endsAt.toUtc().toIso8601String(),
      'room': room,
      'note': note,
    },
  );

  Future<List<AttendanceReportRow>> report(
    DateTime from,
    DateTime to, {
    int? groupId,
  }) async {
    final json =
        await _api.get(
              '/attendance/report',
              query: <String, String>{
                'date_from': _day(from),
                'date_to': _day(to),
                if (groupId != null) 'group_id': '$groupId',
              },
            )
            as List<dynamic>;
    return json
        .map((e) => AttendanceReportRow.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
