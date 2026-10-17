import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a token is kept per server, so one server\'s login never reaches another',
    () {
      final demo = TokenStorage.serverKey(
        'auth_token',
        'http://127.0.0.1:8765',
      );
      final prod = TokenStorage.serverKey(
        'auth_token',
        'https://expertedu-api.ai-student-helper.site',
      );
      expect(demo, isNot(prod));
      expect(
        TokenStorage.serverKey('saved_accounts', 'http://a'),
        isNot(TokenStorage.serverKey('saved_accounts', 'http://b')),
      );
      expect(
        TokenStorage.serverKey('auth_token', 'http://a'),
        TokenStorage.serverKey('auth_token', 'http://a'),
      );
    },
  );
}
