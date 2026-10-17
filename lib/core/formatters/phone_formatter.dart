class PhoneFormatter {
  PhoneFormatter._();

  /// "998901112233" -> "+998 90 111 22 33". Anything that isn't a full
  /// Uzbek number comes back as-is rather than half-formatted.
  static String display(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 12 || !digits.startsWith('998')) return phone;
    return '+998 ${digits.substring(3, 5)} ${digits.substring(5, 8)} '
        '${digits.substring(8, 10)} ${digits.substring(10)}';
  }
}
