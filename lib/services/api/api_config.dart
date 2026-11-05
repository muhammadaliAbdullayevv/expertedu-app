import 'package:flutter/foundation.dart';

class ApiConfig {
  const ApiConfig._();

  static const String _defaultUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://expertedu-api.ai-student-helper.site',
  );

  static String get baseUrl {
    if (kIsWeb) {
      const fromEnv = String.fromEnvironment('API_BASE_URL');
      if (fromEnv.isNotEmpty) return fromEnv;
      final origin = Uri.base.origin;
      if (origin.isNotEmpty && origin != 'null') {
        return origin;
      }
    }
    return _defaultUrl;
  }

  /// True for a server on this computer -- the app is then running on local
  /// test data, never the real center's.
  static bool isLocal([String? url]) {
    final host = Uri.tryParse(url ?? baseUrl)?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  static String? resolveUrl(String? path) =>
      path == null ? null : '$baseUrl$path';
}
