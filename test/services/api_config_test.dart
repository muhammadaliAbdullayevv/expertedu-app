import 'package:expert_edu_center/services/api/api_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a server on this computer is local; the real one is not', () {
    expect(ApiConfig.isLocal('http://127.0.0.1:8765'), isTrue);
    expect(ApiConfig.isLocal('http://localhost:8765'), isTrue);
    expect(
      ApiConfig.isLocal('https://expertedu-api.ai-student-helper.site'),
      isFalse,
    );
    expect(ApiConfig.isLocal('http://192.168.1.20:8765'), isFalse);
    expect(ApiConfig.isLocal('not a url'), isFalse);
  });

  test('this test build points at the real server unless told otherwise', () {
    expect(ApiConfig.isLocal(), isFalse);
  });
}
