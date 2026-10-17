import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final financeRepositoryProvider = Provider<FinanceRepository>((ref) {
  return FinanceRepository(ref.watch(apiClientProvider));
});

/// Expense categories, as stored and as shown.
const Map<String, String> expenseCategoryLabels = <String, String>{
  'salary': 'Oylik',
  'rent': 'Ijara',
  'utilities': 'Kommunal',
  'marketing': 'Reklama',
  'supplies': 'Jihozlar',
  'tax': 'Soliq',
  'other': 'Boshqa',
};

String expenseCategoryLabel(String key) => expenseCategoryLabels[key] ?? key;

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime _date(Object? value) => DateTime.parse(value as String);

class Expense {
  const Expense({
    required this.id,
    required this.category,
    required this.amount,
    required this.spentOn,
    this.note,
    this.method,
    this.teacherId,
    this.teacherName,
    this.salaryMonth,
    this.createdByName,
    this.voidedAt,
    this.voidReason,
  });

  final int id;
  final String category;
  final int amount;
  final DateTime spentOn;
  final String? note;
  final String? method;
  final int? teacherId;
  final String? teacherName;
  final DateTime? salaryMonth;
  final String? createdByName;
  final DateTime? voidedAt;
  final String? voidReason;

  bool get isVoided => voidedAt != null;

  factory Expense.fromJson(Map<String, dynamic> json) => Expense(
    id: json['id'] as int,
    category: json['category'] as String,
    amount: json['amount'] as int,
    spentOn: _date(json['spent_on']),
    note: json['note'] as String?,
    method: json['method'] as String?,
    teacherId: json['teacher_id'] as int?,
    teacherName: json['teacher_name'] as String?,
    salaryMonth: json['salary_month'] == null
        ? null
        : _date(json['salary_month']),
    createdByName: json['created_by_name'] as String?,
    voidedAt: json['voided_at'] == null ? null : _date(json['voided_at']),
    voidReason: json['void_reason'] as String?,
  );
}

class TeacherSalary {
  const TeacherSalary({
    required this.teacherId,
    required this.fullName,
    required this.isActive,
    this.salaryMethod,
    this.salaryPercent,
    this.salaryFixed,
    required this.collected,
    required this.earned,
    required this.paid,
    required this.remaining,
  });

  final int teacherId;
  final String fullName;
  final bool isActive;
  /// How they are paid: 'percent', 'fixed' or null (no rule).
  final String? salaryMethod;
  final double? salaryPercent;
  final int? salaryFixed;

  /// What their groups' students paid in the month.
  final int collected;

  /// Their share of [collected].
  final int earned;

  /// Paid out to them for this month.
  final int paid;
  final int remaining;

  factory TeacherSalary.fromJson(Map<String, dynamic> json) => TeacherSalary(
    teacherId: json['teacher_id'] as int,
    fullName: json['full_name'] as String,
    isActive: json['is_active'] as bool,
    salaryMethod: json['salary_method'] as String?,
    salaryPercent: (json['salary_percent'] as num?)?.toDouble(),
    salaryFixed: json['salary_fixed'] as int?,
    collected: json['collected'] as int,
    earned: json['earned'] as int,
    paid: json['paid'] as int,
    remaining: json['remaining'] as int,
  );
}

class SalaryMonth {
  const SalaryMonth({
    required this.month,
    required this.teachers,
    required this.totalEarned,
    required this.totalPaid,
    required this.totalRemaining,
  });

  final DateTime month;
  final List<TeacherSalary> teachers;
  final int totalEarned;
  final int totalPaid;
  final int totalRemaining;

  factory SalaryMonth.fromJson(Map<String, dynamic> json) => SalaryMonth(
    month: _date(json['month']),
    teachers: (json['teachers'] as List<dynamic>)
        .map((e) => TeacherSalary.fromJson(e as Map<String, dynamic>))
        .toList(),
    totalEarned: json['total_earned'] as int,
    totalPaid: json['total_paid'] as int,
    totalRemaining: json['total_remaining'] as int,
  );
}

class FinanceMonth {
  const FinanceMonth({
    required this.month,
    required this.income,
    required this.expenses,
    required this.profit,
    required this.byCategory,
  });

  final DateTime month;
  final int income;
  final int expenses;
  final int profit;
  final Map<String, int> byCategory;

  factory FinanceMonth.fromJson(Map<String, dynamic> json) => FinanceMonth(
    month: _date(json['month']),
    income: json['income'] as int,
    expenses: json['expenses'] as int,
    profit: json['profit'] as int,
    byCategory: (json['by_category'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(key, value as int),
    ),
  );
}

class FinanceSummary {
  const FinanceSummary({
    required this.months,
    required this.salariesUnpaidThisMonth,
  });

  /// Oldest first, ending with the current month.
  final List<FinanceMonth> months;
  final int salariesUnpaidThisMonth;

  factory FinanceSummary.fromJson(Map<String, dynamic> json) => FinanceSummary(
    months: (json['months'] as List<dynamic>)
        .map((e) => FinanceMonth.fromJson(e as Map<String, dynamic>))
        .toList(),
    salariesUnpaidThisMonth: json['salaries_unpaid_this_month'] as int,
  );
}

/// The center's finances -- owner only (server/app/routes/finance.py).
class FinanceRepository {
  FinanceRepository(this._api);

  final ApiClient _api;

  Future<FinanceSummary> summary({int months = 6}) async {
    final json = await _api.get(
      '/finance/summary',
      query: {'months': '$months'},
    );
    return FinanceSummary.fromJson(json as Map<String, dynamic>);
  }

  Future<SalaryMonth> salaries(DateTime month) async {
    final json = await _api.get(
      '/finance/salaries',
      query: {'month': _day(month)},
    );
    return SalaryMonth.fromJson(json as Map<String, dynamic>);
  }

  /// OWNER ONLY (the server refuses anyone else): [method] is 'percent'
  /// (with [percent]), 'fixed' (with [fixed] so'm a month) or null.
  Future<void> setSalaryRule(
    int teacherId, {
    String? method,
    double? percent,
    int? fixed,
  }) => _api.put(
    '/finance/teachers/$teacherId/salary',
    body: <String, dynamic>{
      'method': method,
      'percent': percent,
      'fixed': fixed,
    },
  );

  Future<List<Expense>> expenses(
    DateTime from,
    DateTime to, {
    String? category,
    bool includeVoided = false,
  }) async {
    final json =
        await _api.get(
              '/expenses',
              query: <String, String>{
                'date_from': _day(from),
                'date_to': _day(to),
                'include_voided': '$includeVoided',
                'category': ?category,
              },
            )
            as List<dynamic>;
    return json
        .map((e) => Expense.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addExpense({
    required String category,
    required int amount,
    required DateTime spentOn,
    String? note,
    String? method,
    int? teacherId,
    DateTime? salaryMonth,
  }) => _api.post(
    '/expenses',
    body: <String, dynamic>{
      'category': category,
      'amount': amount,
      'spent_on': _day(spentOn),
      'note': note,
      'method': method,
      'teacher_id': teacherId,
      'salary_month': salaryMonth == null ? null : _day(salaryMonth),
    },
  );

  Future<void> voidExpense(int id, String reason) =>
      _api.post('/expenses/$id/void', body: {'reason': reason});
}
