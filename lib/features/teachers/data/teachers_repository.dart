import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../../timetable/data/timetable_models.dart';

final teachersRepositoryProvider = Provider<TeachersRepository>((ref) {
  return TeachersRepository(ref.watch(apiClientProvider));
});

class Teacher {
  const Teacher({
    required this.id,
    required this.fullName,
    this.phone,
    this.note,
    required this.isActive,
    this.groupCount,
    this.studentCount,
    this.photo,
    this.telegramUserId,
    this.branchIds = const [],
    this.branchNames = const [],
  });

  final int id;
  final String fullName;
  final String? phone;
  final String? note;
  final bool isActive;

  /// Stored name of the profile photo; null = none.
  final String? photo;

  /// Their Telegram user id: how the bot knows them in the course groups.
  final int? telegramUserId;

  /// The branches they work in (within the branch in view).
  final List<int> branchIds;
  final List<String> branchNames;

  /// Active groups taught -- only populated by [TeachersRepository.list].
  final int? groupCount;

  /// Only from [TeachersRepository.list]: active students in their active groups.
  final int? studentCount;

  factory Teacher.fromJson(Map<String, dynamic> json) => Teacher(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String?,
    note: json['note'] as String?,
    isActive: json['is_active'] as bool,
    groupCount: json['group_count'] as int?,
    studentCount: json['student_count'] as int?,
    photo: json['photo'] as String?,
    telegramUserId: json['telegram_user_id'] as int?,
    branchIds: (json['branch_ids'] as List<dynamic>? ?? const []).cast<int>(),
    branchNames: (json['branch_names'] as List<dynamic>? ?? const [])
        .cast<String>(),
  );
}

DateTime _day(Object? v) => DateTime.parse(v as String);

/// One of a teacher's groups: only what identifies it -- name, students,
/// days and times. Its numbers live on the group's own page.
class TeacherGroupCard {
  const TeacherGroupCard({
    required this.groupId,
    required this.name,
    this.subjectName,
    this.level,
    required this.studentCount,
    this.capacity,
    this.schedule = const [],
    this.branchName,
  });

  final int groupId;
  final String name;
  final String? subjectName;
  final String? level;
  final int studentCount;
  final int? capacity;
  final List<ScheduleSlot> schedule;

  /// Which branch it is in (shown while looking at every branch).
  final String? branchName;

  factory TeacherGroupCard.fromJson(Map<String, dynamic> json) =>
      TeacherGroupCard(
        groupId: json['group_id'] as int,
        name: json['name'] as String,
        subjectName: json['subject_name'] as String?,
        level: json['level'] as String?,
        studentCount: json['student_count'] as int,
        capacity: json['capacity'] as int?,
        branchName: json['branch_name'] as String?,
        schedule: [
          for (final s in json['schedule'] as List<dynamic>? ?? const [])
            ScheduleSlot.fromJson(s as Map<String, dynamic>),
        ],
      );
}

class TeacherMonthPoint {
  const TeacherMonthPoint({
    required this.month,
    required this.collected,
    required this.earned,
    required this.paid,
    required this.closed,
  });

  final DateTime month;
  final int collected;
  final int earned;
  final int paid;
  final bool closed;

  factory TeacherMonthPoint.fromJson(Map<String, dynamic> json) =>
      TeacherMonthPoint(
        month: _day(json['month']),
        collected: json['collected'] as int,
        earned: json['earned'] as int,
        paid: json['paid'] as int,
        closed: json['closed'] as bool? ?? false,
      );
}

/// A teacher's page in one answer.
class TeacherProfileData {
  const TeacherProfileData({
    required this.teacher,
    this.salaryVisible = true,
    this.salaryMethod,
    this.salaryPercent,
    this.salaryFixed,
    this.groups = const [],
    this.studentTotal = 0,
    required this.month,
    this.monthClosed = false,
    this.collected = 0,
    this.earned = 0,
    this.paid = 0,
    this.remaining = 0,
    this.lessons = const [],
    this.history = const [],
  });

  final Teacher teacher;

  /// False for an admin: pay is the owner's alone, the server sends none of it.
  final bool salaryVisible;

  /// The teacher's own pay rule (a group's own rule wins for that group).
  final String? salaryMethod;
  final double? salaryPercent;
  final int? salaryFixed;
  final List<TeacherGroupCard> groups;
  final int studentTotal;

  /// The salary month shown, and its figures -- the same ones Finance shows.
  final DateTime month;
  final bool monthClosed;
  final int collected;
  final int earned;
  final int paid;
  final int remaining;

  /// Today's and tomorrow's lessons.
  final List<TimetableLesson> lessons;

  /// The last six months, oldest first.
  final List<TeacherMonthPoint> history;

  factory TeacherProfileData.fromJson(Map<String, dynamic> json) =>
      TeacherProfileData(
        teacher: Teacher.fromJson(json['teacher'] as Map<String, dynamic>),
        salaryVisible: json['salary_visible'] as bool? ?? true,
        salaryMethod: json['salary_method'] as String?,
        salaryPercent: (json['salary_percent'] as num?)?.toDouble(),
        salaryFixed: json['salary_fixed'] as int?,
        groups: [
          for (final g in json['groups'] as List<dynamic>? ?? const [])
            TeacherGroupCard.fromJson(g as Map<String, dynamic>),
        ],
        studentTotal: json['student_total'] as int? ?? 0,
        month: _day(json['month']),
        monthClosed: json['month_closed'] as bool? ?? false,
        collected: json['collected'] as int? ?? 0,
        earned: json['earned'] as int? ?? 0,
        paid: json['paid'] as int? ?? 0,
        remaining: json['remaining'] as int? ?? 0,
        lessons: [
          for (final l in json['lessons'] as List<dynamic>? ?? const [])
            TimetableLesson.fromJson(l as Map<String, dynamic>),
        ],
        history: [
          for (final h in json['history'] as List<dynamic>? ?? const [])
            TeacherMonthPoint.fromJson(h as Map<String, dynamic>),
        ],
      );
}

/// A teacher who might be the person being added.
class TeacherMatch {
  const TeacherMatch({
    required this.teacherId,
    required this.fullName,
    required this.branchNames,
    required this.inScope,
    required this.samePhone,
  });

  final int teacherId;
  final String fullName;
  final List<String> branchNames;

  /// Already works in this branch.
  final bool inScope;
  final bool samePhone;

  factory TeacherMatch.fromJson(Map<String, dynamic> json) => TeacherMatch(
    teacherId: json['teacher_id'] as int,
    fullName: json['full_name'] as String,
    branchNames: (json['branch_names'] as List<dynamic>).cast<String>(),
    inScope: json['in_scope'] as bool,
    samePhone: json['same_phone'] as bool,
  );
}

class TeachersRepository {
  TeachersRepository(this._api);

  final ApiClient _api;

  /// Archived teachers too, when asked: they are the Arxiv tab.
  Future<List<Teacher>> list({bool includeInactive = false}) async {
    final json =
        await _api.get(
              '/teachers',
              query: includeInactive ? {'include_inactive': 'true'} : null,
            )
            as List<dynamic>;
    return json
        .map((e) => Teacher.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<TeacherProfileData> profile(int id, {DateTime? month}) async {
    final json =
        await _api.get(
              '/teachers/$id/profile',
              query: month == null
                  ? null
                  : {
                      'month':
                          '${month.year}-${month.month.toString().padLeft(2, '0')}-01',
                    },
            )
            as Map<String, dynamic>;
    return TeacherProfileData.fromJson(json);
  }

  /// OWNER ONLY: the branches this teacher works in (at least one).
  Future<Teacher> setBranches(int id, List<int> branchIds) async {
    final json =
        await _api.put(
              '/teachers/$id/branches',
              body: {'branch_ids': branchIds},
            )
            as Map<String, dynamic>;
    return Teacher.fromJson(json);
  }

  /// OWNER ONLY: every active teacher of every branch, whatever branch is in
  /// view (to pick the real record of a duplicate).
  Future<List<Teacher>> listEverywhere() async {
    final json =
        await _api.get('/teachers', headers: {'X-Branch': 'all'})
            as List<dynamic>;
    return json
        .map((e) => Teacher.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Who this might be: teachers with the same number or the same name, in any
  /// branch (shown while a teacher is being added).
  Future<List<TeacherMatch>> lookup({String? phone, String? name}) async {
    final json =
        await _api.get(
              '/teachers/lookup',
              query: {
                if (phone != null && phone.isNotEmpty) 'phone': phone,
                if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
              },
            )
            as List<dynamic>;
    return [
      for (final m in json) TeacherMatch.fromJson(m as Map<String, dynamic>),
    ];
  }

  /// "Shu o'qituvchini mening filialimga qo'shish". An admin must give the
  /// teacher's number; the owner need not.
  Future<Teacher> joinBranch(int id, {String? phone}) async {
    final json =
        await _api.post(
              '/teachers/$id/join-branch',
              body: <String, dynamic>{'phone': phone},
            )
            as Map<String, dynamic>;
    return Teacher.fromJson(json);
  }

  /// OWNER ONLY: folds the duplicate [id] into [intoId].
  Future<Teacher> merge(int id, {required int intoId}) async {
    final json =
        await _api.post(
              '/teachers/$id/merge',
              body: <String, dynamic>{'into_id': intoId},
            )
            as Map<String, dynamic>;
    return Teacher.fromJson(json);
  }

  /// Archive (false) or bring back (true).
  Future<void> setActive(int id, bool active) =>
      _api.patch('/teachers/$id', body: <String, dynamic>{'is_active': active});

  Future<Teacher> create({
    required String fullName,
    String? phone,
    String? note,
    int? telegramUserId,
  }) async {
    final json =
        await _api.post(
              '/teachers',
              body: <String, dynamic>{
                'full_name': fullName,
                'phone': phone,
                'note': note,
                'telegram_user_id': telegramUserId,
              },
            )
            as Map<String, dynamic>;
    return Teacher.fromJson(json);
  }

  /// Sends every field, so an emptied phone or note is cleared rather than
  /// left as it was.
  Future<Teacher> update(
    int id, {
    required String fullName,
    String? phone,
    String? note,
    int? telegramUserId,
  }) async {
    final json =
        await _api.patch(
              '/teachers/$id',
              body: <String, dynamic>{
                'full_name': fullName,
                'phone': phone,
                'note': note,
                'telegram_user_id': telegramUserId,
              },
            )
            as Map<String, dynamic>;
    return Teacher.fromJson(json);
  }
}
