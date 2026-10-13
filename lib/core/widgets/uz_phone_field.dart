import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A phone input pre-fixed with "+998" so staff only ever type the 9-digit
/// local number -- almost every customer/seller phone is Uzbek, and typing
/// the country code every time is slow when the shop is busy.
class UzPhoneField extends StatelessWidget {
  const UzPhoneField({
    super.key,
    required this.controller,
    required this.labelText,
    this.validator,
  });

  final TextEditingController controller;
  final String labelText;
  final String? Function(String?)? validator;

  /// Builds the full phone value to send to the API from what the user
  /// typed into a field using this widget (just the 9-digit local part).
  static String toE164(String digits) {
    final trimmed = digits.trim();
    return trimmed.isEmpty ? '' : '+998$trimmed';
  }

  /// Strips a leading "+998"/"998" from a stored phone so it can prefill a
  /// field using this widget (which only shows the local 9-digit part).
  static String stripPrefix(String? phone) {
    if (phone == null) {
      return '';
    }
    var digits = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('998')) {
      digits = digits.substring(3);
    }
    return digits;
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.phone,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(9),
      ],
      decoration: InputDecoration(labelText: labelText, prefixText: '+998 '),
      validator: validator,
    );
  }
}
