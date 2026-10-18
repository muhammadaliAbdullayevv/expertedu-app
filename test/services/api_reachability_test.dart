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

  test('a read that fails once is asked again quietly', () async {
    var calls = 0;
    final api = ApiClient(
      _NoTokens(),
      MockClient((_) async {
        calls++;
        if (calls == 1) throw http.ClientException('Connection closed');
        return http.Response('{"ok":true}', 200);
      }),
    );
    final told = <bool>[];
    api.onReachability = told.add;
    expect(await api.get('/groups'), {'ok': true});
    expect(calls, 2);
    expect(told, [true]);
  });

  test('a read that fails twice says so, naming what failed', () async {
    var calls = 0;
    final api = ApiClient(
      _NoTokens(),
      MockClient((_) async {
        calls++;
        throw const SocketException('Connection reset by peer');
      }),
    );
    final error = await api
        .get('/groups')
        .then<Object?>((_) => null)
        .catchError((e) => e);
    expect(calls, 2);
    final e = error as ApiException;
    expect(e.statusCode, 0);
    expect(e.message, contains('Serverga ulanib bo\'lmadi'));
    expect(e.message, contains('Connection reset by peer'));
  });

  test(
    'a write is never sent again on its own: it may have been saved',
    () async {
      var calls = 0;
      final api = ApiClient(
        _NoTokens(),
        MockClient((_) async {
          calls++;
          throw TimeoutException('slow');
        }),
      );
      final error = await api
          .post('/groups', body: {'name': 'IELTS'})
          .then<Object?>((_) => null)
          .catchError((e) => e);
      expect(calls, 1);
      final e = error as ApiException;
      expect(e.statusCode, 0);
      expect(e.message, contains('Saqlangan bo\'lishi mumkin'));
      expect(e.message, contains('TimeoutException'));
    },
  );
}
