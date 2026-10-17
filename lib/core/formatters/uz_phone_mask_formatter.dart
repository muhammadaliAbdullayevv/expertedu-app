import 'package:flutter/services.dart';

/// Formats the 9 local digits of an Uzbek number as "90 123 45 67" while
/// typing -- the field shows "+998 " as a fixed prefix. Digits only, at
/// most 9; pasting "+998 90 123 45 67" or "998901234567" keeps just the
/// local part.
class UzPhoneMaskFormatter extends TextInputFormatter {
  /// The 9 local digits in [text], whatever formatting it carries.
  static String digitsOf(String text) {
    var digits = text.replaceAll(RegExp(r'\D'), '');
    // Only a whole pasted international number loses its 998 -- a local
    // number can itself start with 99 8.
    if (digits.length >= 12 && digits.startsWith('998')) {
      digits = digits.substring(3);
    }
    return digits.length > 9 ? digits.substring(0, 9) : digits;
  }

  static String format(String digits) {
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i == 2 || i == 5 || i == 7) buffer.write(' ');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }

  /// "998901234567" for the API from what's in the field, or '' if empty.
  static String toApi(String text) {
    final digits = digitsOf(text);
    return digits.isEmpty ? '' : '998$digits';
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = format(digitsOf(newValue.text));
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
