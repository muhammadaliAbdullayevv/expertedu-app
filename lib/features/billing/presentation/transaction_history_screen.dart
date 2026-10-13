import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/utils/enrollment_ledger_calculator.dart';
import '../data/transactions_repository.dart';
import 'record_payment_sheet.dart';

class TransactionHistoryScreen extends ConsumerStatefulWidget {
  const TransactionHistoryScreen({
    super.key,
    required this.enrollmentId,
    required this.studentName,
  });

  final int enrollmentId;
  final String studentName;

  @override
  ConsumerState<TransactionHistoryScreen> createState() =>
      _TransactionHistoryScreenState();
}

class _TransactionHistoryScreenState
    extends ConsumerState<TransactionHistoryScreen> {
  late Future<List<Transaction>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref
        .read(transactionsRepositoryProvider)
        .listForEnrollment(widget.enrollmentId);
  }

  void _reload() {
    setState(
      () => _future = ref
          .read(transactionsRepositoryProvider)
          .listForEnrollment(widget.enrollmentId),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.studentName)),
      body: FutureBuilder<List<Transaction>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Xatolik: ${snapshot.error}'));
          }
          final transactions = snapshot.data ?? const <Transaction>[];
          final ledger = calculateEnrollmentLedger(
            transactions.map(
              (t) => LedgerTransaction(
                kind: t.kind,
                amount: t.amount,
                occurredAt: t.occurredAt,
              ),
            ),
          );
          final payments =
              transactions.where((t) => t.kind == 'payment').toList()
                ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

          return Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        ledger.balance > 0
                            ? 'Qarz: ${CurrencyFormatter.format(ledger.balance)}'
                            : 'Qarzi yo\'q',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: ledger.balance > 0
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () async {
                        final paid = await showRecordPaymentSheet(
                          context,
                          enrollmentId: widget.enrollmentId,
                          balance: ledger.balance,
                        );
                        if (paid == true) _reload();
                      },
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('To\'lov'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    ...ledger.charges.reversed.map(
                      (charge) => ListTile(
                        leading: Icon(
                          switch (charge.status) {
                            ChargeStatus.paid => Icons.check_circle,
                            ChargeStatus.partial => Icons.incomplete_circle,
                            ChargeStatus.unpaid => Icons.radio_button_unchecked,
                          },
                          color: switch (charge.status) {
                            ChargeStatus.paid => Colors.green,
                            ChargeStatus.partial => Colors.orange,
                            ChargeStatus.unpaid => Theme.of(
                              context,
                            ).colorScheme.error,
                          },
                        ),
                        title: Text(
                          CurrencyFormatter.format(charge.transaction.amount) +
                              (charge.transaction.amount != charge.amountPaid &&
                                      charge.status != ChargeStatus.unpaid
                                  ? ' (${CurrencyFormatter.format(charge.amountPaid)} to\'landi)'
                                  : ''),
                        ),
                        subtitle: Text(
                          DateFormatters.date(charge.transaction.occurredAt),
                        ),
                      ),
                    ),
                    if (payments.isNotEmpty) const Divider(),
                    ...payments.map(
                      (payment) => ListTile(
                        leading: const Icon(
                          Icons.arrow_downward,
                          color: Colors.green,
                        ),
                        title: Text(
                          '+ ${CurrencyFormatter.format(payment.amount)}',
                        ),
                        subtitle: Text(
                          [
                            DateFormatters.date(payment.occurredAt),
                            if (payment.note != null) payment.note!,
                          ].join(' • '),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
