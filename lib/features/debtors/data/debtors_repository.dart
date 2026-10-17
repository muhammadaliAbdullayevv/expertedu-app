import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final debtorsRepositoryProvider = Provider<DebtorsRepository>((ref) {
  return DebtorsRepository(ref.watch(apiClientProvider));
});

/// One enrollment that owes money -- per enrollment rather than per
/// student, since a payment is always recorded against one enrollment.
class Debtor {
  const Debtor({
    required this.enrollmentId,
    required this.studentId,
    required this.studentFullName,
    required this.studentPhone,
    required this.groupId,
    required this.groupName,
    required this.status,
    required this.balance,
    this.oldestUnpaidDue,
  });

  final int enrollmentId;
  final int studentId;
  final String studentFullName;
  final String studentPhone;
  final int groupId;
  final String groupName;

  /// 'active' | 'withdrawn' -- a student who left still owes what they owe.
  final String status;
  final int balance;

  /// Due date of the oldest charge payments haven't covered yet.
  final DateTime? oldestUnpaidDue;

  bool get isWithdrawn => status == 'withdrawn';

  factory Debtor.fromJson(Map<String, dynamic> json) => Debtor(
    enrollmentId: json['enrollment_id'] as int,
    studentId: json['student_id'] as int,
    studentFullName: json['student_full_name'] as String,
    studentPhone: json['student_phone'] as String,
    groupId: json['group_id'] as int,
    groupName: json['group_name'] as String,
    status: json['status'] as String,
    balance: json['balance'] as int,
    oldestUnpaidDue: json['oldest_unpaid_due'] == null
        ? null
        : DateTime.parse(json['oldest_unpaid_due'] as String),
  );
}

class DebtorsRepository {
  DebtorsRepository(this._api);

  final ApiClient _api;

  /// Biggest debt first.
  Future<List<Debtor>> list() async {
    final json = await _api.get('/debtors') as List<dynamic>;
    return json.map((e) => Debtor.fromJson(e as Map<String, dynamic>)).toList();
  }
}
