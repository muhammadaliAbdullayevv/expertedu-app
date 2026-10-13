import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final androidFileBridgeProvider = Provider<AndroidFileBridge>((ref) {
  return const AndroidFileBridge();
});

class AndroidFileBridge {
  const AndroidFileBridge();

  static const MethodChannel _channel = MethodChannel('uz.expertedu.expert_edu_center/files');

  /// Hands a downloaded update APK to the system installer.
  Future<void> installApk(String path) {
    return _channel.invokeMethod<void>('installApk', <String, Object?>{'path': path});
  }
}
