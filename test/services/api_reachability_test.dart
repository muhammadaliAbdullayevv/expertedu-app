import 'dart:async';
import 'dart:io';

import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _NoTokens extends TokenStorage {
  @override
  Future<String?> readToken() async => null;
}

void main() {
  Future<({List<bool> told, Object? error})> call(
    Future<http.Response> Function(http.Request) handler,
  ) async {
    final api = ApiClient(_NoTokens(), MockClient(handler));
    final told = <bool>[];
    api.onReachability = told.add;
    Object? error;
    try {
      await api.get('/health');
    } catch (e) {
      error = e;
    }
    return (told: told, error: error);
  }

  test('an answer, even an error, means the server is reachable', () async {
    expect((await call((_) async => http.Response('{}', 200))).told, [true]);
    final refused = await call(
      (_) async => http.Response('{"detail":"x"}', 409),
    );
    expect(refused.told, [true]);
    expect((refused.error as ApiException).statusCode, 409);
    expect((await call((_) async => http.Response('', 500))).told, [true]);
  });

  test('only a real network failure means offline', () async {
    for (final failure in <Object>[
      const SocketException('no route'),
      TimeoutException('slow'),
      http.ClientException('closed'),
    ]) {
      final r = await call((_) async => throw failure);
      expect(r.told, [false], reason: '$failure');
      expect((r.error as ApiException).statusCode, 0);
    }
  });

  test('an answer we cannot read is not "offline"', () async {
    final r = await call(
      (_) async => http.Response('<html>not json</html>', 200),
    );
    expect(r.told, [true]);
    expect((r.error as ApiException).statusCode, isNot(0));
  });
}
