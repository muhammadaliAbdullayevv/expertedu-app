import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final enrollmentsRepositoryProvider = Provider<EnrollmentsRepository>((ref) {
  return EnrollmentsRepository(ref.watch(apiClientProvider));
});

class StudentEnrollment {
  const StudentEnrollment({
    required this.enrollmentId,
    required this.groupId,
    required this.groupName,
    required this.joinedAt,
    required this.status,
    this.balance = 0,
  });

  final int enrollmentId;
  final int groupId;
  final String groupName;
  final DateTime joinedAt;
  final String status;

  /// Positive means this enrollment still owes money.
  final int balance;

  factory StudentEnrollment.fromJson(Map<String, dynamic> json) =>
      StudentEnrollment(
        enrollmentId: json['enrollment_id'] as int,
        groupId: json['group_id'] as int,
        groupName: json['group_name'] as String,
        joinedAt: DateTime.parse(json['joined_at'] as String),
        status: json['status'] as String,
        balance: json['balance'] as int? ?? 0,
      );
}

/// "2026-10-15" -- how dates go to the API (a plain calendar date, no time
/// or timezone attached).
String apiDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class FirstChargePreview {
  const FirstChargePreview({
    required this.monthlyFee,
    required this.discountedFee,
    required this.periodStart,
    required this.periodEnd,
    required this.daysLeft,
    required this.daysInPeriod,
    required this.proratedAmount,
    required this.fullAmount,
    required this.isMidCycle,
  });

  final int monthlyFee;
  final int discountedFee;
  final DateTime periodStart;

  /// The group's next due day -- where the first full-fee charge lands.
  final DateTime periodEnd;
  final int daysLeft;
  final int daysInPeriod;
  final int proratedAmount;
  final int fullAmount;

  /// False when starting on the due day itself: both options are the same.
  final bool isMidCycle;

  factory FirstChargePreview.fromJson(Map<String, dynamic> json) =>
      FirstChargePreview(
        monthlyFee: json['monthly_fee'] as int,
        discountedFee: json['discounted_fee'] as int,
        periodStart: DateTime.parse(json['period_start'] as String),
        periodEnd: DateTime.parse(json['period_end'] as String),
        daysLeft: json['days_left'] as int,
        daysInPeriod: json['days_in_period'] as int,
        proratedAmount: json['prorated_amount'] as int,
        fullAmount: json['full_amount'] as int,
        isMidCycle: json['is_mid_cycle'] as bool,
      );
}

class EnrollmentsRepository {
  EnrollmentsRepository(this._api);

  final ApiClient _api;

  Future<void> create({
    required int studentId,
    required int groupId,
    required DateTime joinedAt,
  }) {
    final dateStr =
        '${joinedAt.year.toString().padLeft(4, '0')}-${joinedAt.month.toString().padLeft(2, '0')}-${joinedAt.day.toString().padLeft(2, '0')}';
    return _api.post(
      '/enrollments',
      body: <String, dynamic>{
        'student_id': studentId,
        'group_id': groupId,
        'joined_at': dateStr,
      },
    );
  }

  Future<void> withdraw(int enrollmentId) {
    return _api.post('/enrollments/$enrollmentId/withdraw');
  }

  /// Both possible first charges for starting in [groupId] on [joinedAt],
  /// computed server-side with the same code that will charge them.
  Future<FirstChargePreview> previewFirstCharge({
    required int groupId,
    required DateTime joinedAt,
    String? discountKind,
    int? discountValue,
  }) async {
    final json =
        await _api.get(
              '/enrollments/first-charge-preview',
              query: <String, String>{
                'group_id': '$groupId',
                'joined_at': apiDate(joinedAt),
                if (discountKind != null && discountValue != null) ...{
                  'discount_kind': discountKind,
                  'discount_value': '$discountValue',
                },
              },
            )
            as Map<String, dynamic>;
    return FirstChargePreview.fromJson(json);
  }

  Future<List<StudentEnrollment>> listForStudent(int studentId) async {
    final json =
        await _api.get('/enrollments/by-student/$studentId') as List<dynamic>;
    return json
        .map((e) => StudentEnrollment.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
