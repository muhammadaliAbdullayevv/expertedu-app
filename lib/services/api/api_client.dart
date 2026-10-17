import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'api_config.dart';
import 'token_storage.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(ref.watch(tokenStorageProvider));
});

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

/// Thin JSON/JWT wrapper around [http.Client]. Set [onUnauthorized] once a
/// session controller exists so a 401 from any call can force a sign-out.
class ApiClient {
  ApiClient(this._tokenStorage);

  final TokenStorage _tokenStorage;
  final http.Client _http = http.Client();

  void Function()? onUnauthorized;

  // Set the instant any single call gets a 401. Without this, every
  // other poller already in flight at that moment -- dashboard, search,
  // notifications, sync, the home-screen widget, all kept alive across a
  // forced sign-out by design, with no other way to learn the session is
  // gone -- kept re-sending the exact same dead token and getting the
  // exact same 401, forever, every few seconds. Confirmed in production
  // logs: a burst of 401s across every single endpoint at once, then
  // repeating every 5s for over a minute straight, which is what a
  // "stuck" screen (search included) actually was. Blocking every
  // further call locally -- an instant synthetic 401, no network round
  // trip -- until [resetAuthBlock] is called stops that outright.
  bool _blockedUntilReauth = false;

  /// Called by SessionController once a session is actually established
  /// again (restore-on-launch, login, switch-account) -- safe to call
  /// even when nothing was blocked.
  void resetAuthBlock() {
    _blockedUntilReauth = false;
  }

  static const Duration _timeout = Duration(seconds: 15);

  Future<dynamic> get(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) {
    return _guarded(() async {
      final response = await _http
          .get(_uri(path, query), headers: await _headers())
          .timeout(timeout ?? _timeout);
      return _decode(response);
    });
  }

  /// [headers] are added to the usual ones -- e.g. an `Idempotency-Key`
  /// for a write that may be resent (see server/app/idempotency.py).
  Future<dynamic> post(
    String path, {
    Object? body,
    bool withAuth = true,
    Duration? timeout,
    Map<String, String>? headers,
  }) {
    return _guarded(() async {
      final response = await _http
          .post(
            _uri(path),
            headers: <String, String>{
              ...await _headers(withAuth: withAuth),
              ...?headers,
            },
            body: body == null ? null : jsonEncode(body),
          )
          .timeout(timeout ?? _timeout);
      return _decode(response);
    });
  }

  Future<dynamic> put(String path, {Object? body}) {
    return _guarded(() async {
      final response = await _http
          .put(
            _uri(path),
            headers: await _headers(),
            body: body == null ? null : jsonEncode(body),
          )
          .timeout(_timeout);
      return _decode(response);
    });
  }

  Future<dynamic> patch(String path, {Object? body}) {
    return _guarded(() async {
      final response = await _http
          .patch(
            _uri(path),
            headers: await _headers(),
            body: body == null ? null : jsonEncode(body),
          )
          .timeout(_timeout);
      return _decode(response);
    });
  }

  Future<void> delete(String path, {Map<String, String>? query}) {
    return _guarded(() async {
      final response = await _http
          .delete(_uri(path, query), headers: await _headers())
          .timeout(_timeout);
      _decode(response);
    });
  }

  /// Uploads a file as multipart/form-data (field name "file").
  Future<dynamic> uploadFile(
    String path, {
    required List<int> bytes,
    required String filename,
  }) {
    return _guarded(() async {
      final headers = await _headers();
      headers.remove('Content-Type');
      final request = http.MultipartRequest('POST', _uri(path))
        ..headers.addAll(headers)
        ..files.add(
          http.MultipartFile.fromBytes('file', bytes, filename: filename),
        );
      final streamedResponse = await _http
          .send(request)
          .timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamedResponse);
      return _decode(response);
    });
  }

  /// Runs an HTTP call and converts any failure (timeout, DNS, TLS, socket
  /// errors) into an [ApiException] so every call site can rely on catching
  /// just that one type instead of silently hanging or crashing unhandled.
  Future<T> _guarded<T>(Future<T> Function() action) async {
    if (_blockedUntilReauth) {
      throw ApiException(401, 'Sessiya tugadi, qayta kiring.');
    }
    try {
      return await action();
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException(
        0,
        'Serverga ulanib bo\'lmadi. Internetni tekshiring.',
      );
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.parse(
      '${ApiConfig.baseUrl}$path',
    ).replace(queryParameters: query);
  }

  Future<Map<String, String>> _headers({bool withAuth = true}) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (withAuth) {
      final token = await _tokenStorage.readToken();
      if (token != null) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  dynamic _decode(http.Response response) {
    if (response.statusCode == 401) {
      _blockedUntilReauth = true;
      onUnauthorized?.call();
      throw ApiException(401, 'Sessiya tugadi, qayta kiring.');
    }

    if (response.statusCode >= 400) {
      var message = 'Xatolik yuz berdi';
      try {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map && decoded['detail'] != null) {
          message = decoded['detail'].toString();
        }
      } catch (_) {
        // Ignore malformed error bodies and keep the generic message.
      }
      throw ApiException(response.statusCode, message);
    }

    if (response.bodyBytes.isEmpty) {
      return null;
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }
}
