class ApiConfig {
  const ApiConfig._();

  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://expertedu-api.ai-student-helper.site',
  );

  static String? resolveUrl(String? path) => path == null ? null : '$baseUrl$path';
}
