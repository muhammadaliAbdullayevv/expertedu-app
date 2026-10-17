import 'package:intl/intl.dart';

class CurrencyFormatter {
  CurrencyFormatter._();

  static final NumberFormat _numberFormat = NumberFormat.decimalPattern('uz');
  static final NumberFormat _oneDecimal = NumberFormat('0.#', 'uz');

  static String format(int amount) {
    return '${_numberFormat.format(amount)} so\'m';
  }

  /// "18,4 mln" / "450 ming" / "900" -- for chart labels and axis ticks,
  /// where a full "18 400 000 so'm" doesn't fit. Always pair it with the
  /// exact [format] somewhere (a tooltip, a table) -- it rounds.
  static String compact(int amount) {
    final abs = amount.abs();
    if (abs >= 1000000) return '${_oneDecimal.format(amount / 1000000)} mln';
    if (abs >= 1000) return '${_oneDecimal.format(amount / 1000)} ming';
    return _numberFormat.format(amount);
  }
}
