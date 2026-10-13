import 'package:expert_edu_center/core/utils/enrollment_ledger_calculator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('single unpaid charge', () {
    final ledger = calculateEnrollmentLedger([
      LedgerTransaction(
        kind: 'charge',
        amount: 300000,
        occurredAt: DateTime(2026, 10, 5),
      ),
    ]);
    expect(ledger.balance, 300000);
    expect(ledger.charges, hasLength(1));
    expect(ledger.charges.single.status, ChargeStatus.unpaid);
    expect(ledger.charges.single.amountPaid, 0);
  });

  test('fully paid charge', () {
    final ledger = calculateEnrollmentLedger([
      LedgerTransaction(
        kind: 'charge',
        amount: 300000,
        occurredAt: DateTime(2026, 10, 5),
      ),
      LedgerTransaction(
        kind: 'payment',
        amount: 300000,
        occurredAt: DateTime(2026, 10, 6),
      ),
    ]);
    expect(ledger.balance, 0);
    expect(ledger.charges.single.status, ChargeStatus.paid);
    expect(ledger.charges.single.amountPaid, 300000);
  });

  test('partially paid charge', () {
    final ledger = calculateEnrollmentLedger([
      LedgerTransaction(
        kind: 'charge',
        amount: 300000,
        occurredAt: DateTime(2026, 10, 5),
      ),
      LedgerTransaction(
        kind: 'payment',
        amount: 100000,
        occurredAt: DateTime(2026, 10, 6),
      ),
    ]);
    expect(ledger.balance, 200000);
    expect(ledger.charges.single.status, ChargeStatus.partial);
    expect(ledger.charges.single.amountPaid, 100000);
  });

  test('FIFO: a payment covers the oldest unpaid charge first', () {
    final ledger = calculateEnrollmentLedger([
      LedgerTransaction(
        kind: 'charge',
        amount: 300000,
        occurredAt: DateTime(2026, 9, 5),
      ),
      LedgerTransaction(
        kind: 'charge',
        amount: 300000,
        occurredAt: DateTime(2026, 10, 5),
      ),
      LedgerTransaction(
        kind: 'payment',
        amount: 300000,
        occurredAt: DateTime(2026, 10, 6),
      ),
    ]);
    expect(ledger.balance, 300000);
    expect(ledger.charges[0].status, ChargeStatus.paid); // September charge
    expect(ledger.charges[1].status, ChargeStatus.unpaid); // October charge
  });

  test('FIFO: overpayment spills into the next charge as partial', () {
    final ledger = calculateEnrollmentLedger([
      LedgerTransaction(
        kind: 'charge',
        amount: 200000,
        occurredAt: DateTime(2026, 9, 5),
      ),
      LedgerTransaction(
        kind: 'charge',
        amount: 200000,
        occurredAt: DateTime(2026, 10, 5),
      ),
      LedgerTransaction(
        kind: 'payment',
        amount: 300000,
        occurredAt: DateTime(2026, 10, 6),
      ),
    ]);
    expect(ledger.balance, 100000);
    expect(ledger.charges[0].status, ChargeStatus.paid);
    expect(ledger.charges[1].status, ChargeStatus.partial);
    expect(ledger.charges[1].amountPaid, 100000);
  });

  test('input order does not matter -- sorted by occurredAt internally', () {
    final ledger = calculateEnrollmentLedger([
      LedgerTransaction(
        kind: 'payment',
        amount: 300000,
        occurredAt: DateTime(2026, 10, 6),
      ),
      LedgerTransaction(
        kind: 'charge',
        amount: 300000,
        occurredAt: DateTime(2026, 9, 5),
      ),
    ]);
    expect(ledger.balance, 0);
    expect(ledger.charges.single.status, ChargeStatus.paid);
  });

  test('no transactions at all', () {
    final ledger = calculateEnrollmentLedger(const <LedgerTransaction>[]);
    expect(ledger.balance, 0);
    expect(ledger.charges, isEmpty);
  });
}
