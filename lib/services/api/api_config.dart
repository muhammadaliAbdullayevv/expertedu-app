class ApiConfig {
  const ApiConfig._();

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://expertedu-api.ai-student-helper.site',
  );

  /// True for a server on this computer -- the app is then running on local
  /// test data, never the real center's.
  static bool isLocal([String? url]) {
    final host = Uri.tryParse(url ?? baseUrl)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  static String? resolveUrl(String? path) =>
      path == null ? null : '$baseUrl$path';
}
