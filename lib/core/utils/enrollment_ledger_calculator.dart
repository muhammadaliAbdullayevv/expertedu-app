/// FIFO extension of the shop app's `ledger_balance_calculator.dart`: walks
/// charges oldest-first, applies payments oldest-first against them, and
/// annotates each charge paid/partial/unpaid -- while still returning the
/// same overall running balance. Two read sites use this: a group roster
/// row wants [EnrollmentLedger.balance]; a transaction-history screen wants
/// [EnrollmentLedger.charges]' per-charge status.
library;

class LedgerTransaction {
  const LedgerTransaction({required this.kind, required this.amount, required this.occurredAt});

  /// 'charge' | 'payment'.
  final String kind;
  final int amount;
  final DateTime occurredAt;
}

enum ChargeStatus { paid, partial, unpaid }

class AnnotatedCharge {
  const AnnotatedCharge({required this.transaction, required this.status, required this.amountPaid});

  final LedgerTransaction transaction;
  final ChargeStatus status;

  /// How much of this charge's amount has been covered by FIFO-allocated
  /// payments -- always <= transaction.amount.
  final int amountPaid;
}

class EnrollmentLedger {
  const EnrollmentLedger({required this.charges, required this.balance});

  /// In the same order as the input's charges, oldest first.
  final List<AnnotatedCharge> charges;

  /// Total charges minus total payments -- positive means still owed.
  final int balance;
}

EnrollmentLedger calculateEnrollmentLedger(Iterable<LedgerTransaction> transactions) {
  final sorted = transactions.toList()..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
  final charges = sorted.where((t) => t.kind == 'charge').toList();
  final payments = sorted.where((t) => t.kind == 'payment').toList();

  var paymentPool = payments.fold<int>(0, (sum, t) => sum + t.amount);
  final annotated = <AnnotatedCharge>[];
  for (final charge in charges) {
    final applied = paymentPool < charge.amount ? paymentPool : charge.amount;
    paymentPool -= applied;
    final status = applied == 0
        ? ChargeStatus.unpaid
        : applied < charge.amount
        ? ChargeStatus.partial
        : ChargeStatus.paid;
    annotated.add(AnnotatedCharge(transaction: charge, status: status, amountPaid: applied));
  }

  final totalCharges = charges.fold<int>(0, (sum, t) => sum + t.amount);
  final totalPayments = payments.fold<int>(0, (sum, t) => sum + t.amount);

  return EnrollmentLedger(charges: annotated, balance: totalCharges - totalPayments);
}
