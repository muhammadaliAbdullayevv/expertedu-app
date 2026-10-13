import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Live-groups a plain integer amount as digits are typed -- "1500" reads
/// as "1 500" and "15000" as "15 000" while still typing, not just once
/// saved -- using the same space-grouped style CurrencyFormatter already
/// shows everywhere else (balances, ledger amounts, SMS text), so an
/// amount looks identical from typing through to being saved and displayed.
class ThousandsInputFormatter extends TextInputFormatter {
  static final NumberFormat _numberFormat = NumberFormat.decimalPattern('uz');
  static final RegExp _nonDigits = RegExp(r'[^0-9]');
  static final RegExp _digit = RegExp(r'[0-9]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digitsOnly = newValue.text.replaceAll(_nonDigits, '');
    if (digitsOnly.isEmpty) {
      return const TextEditingValue(text: '');
    }

    final formatted = _numberFormat.format(int.parse(digitsOnly));

    // Track the cursor by "how many digits precede it", not a fixed
    // character offset, since inserted separators shift positions around.
    final cursorIndex = newValue.selection.end.clamp(0, newValue.text.length);
    final digitsBeforeCursor = newValue.text
        .substring(0, cursorIndex)
        .replaceAll(_nonDigits, '')
        .length;

    var seen = 0;
    var cursorOffset = formatted.length;
    for (var i = 0; i < formatted.length; i++) {
      if (_digit.hasMatch(formatted[i])) {
        seen++;
        if (seen == digitsBeforeCursor) {
          cursorOffset = i + 1;
          break;
        }
      }
    }
    if (digitsBeforeCursor == 0) {
      cursorOffset = 0;
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: cursorOffset),
    );
  }

  /// Strips the grouping back out for parsing/saving. Null if nothing but
  /// separators/whitespace was entered.
  static int? unformat(String text) {
    final digitsOnly = text.replaceAll(_nonDigits, '');
    return digitsOnly.isEmpty ? null : int.parse(digitsOnly);
  }

  /// The formatted display string for an already-known amount, e.g. to
  /// seed a controller when opening the edit form.
  static String format(int amount) => _numberFormat.format(amount);
}
