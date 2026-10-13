import 'package:intl/intl.dart';

class CurrencyFormatter {
  CurrencyFormatter._();

  static final NumberFormat _numberFormat = NumberFormat.decimalPattern('uz');

  static String format(int amount) {
    return '${_numberFormat.format(amount)} so\'m';
  }
}
