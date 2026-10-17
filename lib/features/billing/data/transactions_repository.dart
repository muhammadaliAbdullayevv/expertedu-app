import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final transactionsRepositoryProvider = Provider<TransactionsRepository>((ref) {
  return TransactionsRepository(ref.watch(apiClientProvider));
});

class Transaction {
  const Transaction({
    required this.id,
    required this.enrollmentId,
    required this.kind,
    required this.amount,
    this.periodStart,
    this.dueDate,
    required this.isProrated,
    required this.source,
    this.note,
    this.method,
    required this.occurredAt,
  });

  final int id;
  final int enrollmentId;

  /// 'charge' | 'payment'.
  final String kind;
  final int amount;
  final DateTime? periodStart;
  final DateTime? dueDate;
  final bool isProrated;
  final String source;
  final String? note;

  /// Payments only: 'cash' | 'card' | 'click_payme', or null -- every
  /// payment recorded before methods existed has none.
  final String? method;
  final DateTime occurredAt;

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
    id: json['id'] as int,
    enrollmentId: json['enrollment_id'] as int,
    kind: json['kind'] as String,
    amount: json['amount'] as int,
    periodStart: json['period_start'] == null
        ? null
        : DateTime.parse(json['period_start'] as String),
    dueDate: json['due_date'] == null
        ? null
        : DateTime.parse(json['due_date'] as String),
    isProrated: json['is_prorated'] as bool,
    source: json['source'] as String,
    note: json['note'] as String?,
    method: json['method'] as String?,
    occurredAt: DateTime.parse(json['occurred_at'] as String),
  );
}

class TransactionsRepository {
  TransactionsRepository(this._api);

  final ApiClient _api;

  Future<List<Transaction>> listForEnrollment(int enrollmentId) async {
    final json =
        await _api.get('/enrollments/$enrollmentId/transactions')
            as List<dynamic>;
    return json
        .map((e) => Transaction.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> recordPayment({
    required int enrollmentId,
    required int amount,
    String? note,
  }) {
    return _api.post(
      '/enrollments/$enrollmentId/payments',
      body: <String, dynamic>{'amount': amount, 'note': note},
    );
  }
}
