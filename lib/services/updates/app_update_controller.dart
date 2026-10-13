import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../platform/android_file_bridge.dart';
import 'update_checker.dart';

final appUpdateControllerProvider = Provider<AppUpdateController>((ref) {
  final controller = AppUpdateController(
    ref.watch(updateCheckerProvider),
    ref.watch(androidFileBridgeProvider),
  );
  return controller;
});

class AppUpdateController extends ChangeNotifier {
  AppUpdateController(this._checker, this._bridge) {
    unawaited(_init());
  }

  final UpdateChecker _checker;
  final AndroidFileBridge _bridge;

  String currentVersionName = '';
  int _currentVersionCode = 0;

  /// Shown alongside the version name in Settings purely as a diagnostic --
  /// the update check compares this raw integer against version.json's
  /// `version_code`, and the two can drift apart from the version *name*
  /// in ways that are otherwise invisible (e.g. a build shipped once with
  /// an unusually large build number keeps requiring every future release
  /// to clear that same high number, no matter how the version name reads).
  int get currentVersionCode => _currentVersionCode;

  AppUpdateInfo? available;
  bool checking = false;
  double? downloadProgress;
  String? error;

  Future<void> _init() async {
    final info = await PackageInfo.fromPlatform();
    currentVersionName = info.version;
    _currentVersionCode = int.tryParse(info.buildNumber) ?? 0;
    notifyListeners();
    await checkNow();
  }

  Future<void> checkNow() async {
    checking = true;
    error = null;
    notifyListeners();

    try {
      final update = await _checker.checkForUpdate();
      available = update.versionCode > _currentVersionCode ? update : null;
    } catch (e) {
      available = null;
      error = e.toString();
    }
    checking = false;
    notifyListeners();
  }

  Future<void> downloadAndInstall() async {
    final update = available;
    if (update == null) {
      return;
    }

    try {
      downloadProgress = 0;
      error = null;
      notifyListeners();

      final path = await _checker.download(
        update,
        onProgress: (progress) {
          downloadProgress = progress;
          notifyListeners();
        },
      );

      downloadProgress = null;
      notifyListeners();

      await _bridge.installApk(path);
    } catch (e) {
      downloadProgress = null;
      error = e.toString();
      notifyListeners();
    }
  }
}
