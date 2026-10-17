import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../platform/android_file_bridge.dart';
import 'desktop_installer.dart';
import 'update_checker.dart';

final appUpdateControllerProvider = Provider<AppUpdateController>((ref) {
  final controller = AppUpdateController(
    ref.watch(updateCheckerProvider),
    ref.watch(androidFileBridgeProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

bool get _isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux;

class AppUpdateController extends ChangeNotifier {
  AppUpdateController(this._checker, this._bridge) {
    unawaited(_init());
  }

  final UpdateChecker _checker;
  final AndroidFileBridge _bridge;
  final DesktopInstaller _desktop = const DesktopInstaller();

  /// The desktop stays open all day in the office -- check again now and
  /// then, not only at start.
  static const Duration _desktopRecheck = Duration(hours: 4);
  Timer? _recheck;

  /// Desktop only: the downloaded release is being installed.
  bool installing = false;

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
    if (_isDesktop && DesktopInstaller.canSelfUpdate) {
      _recheck = Timer.periodic(_desktopRecheck, (_) => checkNow());
    }
  }

  Future<void> checkNow() async {
    // Android reads /uploads/app/version.json (an APK); Windows and the
    // Fedora RPM read /uploads/desktop/version.json. Anything else -- and a
    // desktop build that isn't the installed copy -- has nothing to update.
    final desktop = _isDesktop;
    if (desktop && !DesktopInstaller.canSelfUpdate) return;
    if (!desktop && defaultTargetPlatform != TargetPlatform.android) return;
    if (downloadProgress != null || installing) return;

    checking = true;
    error = null;
    notifyListeners();

    try {
      final update = desktop
          ? await _checker.checkForDesktopUpdate()
          : await _checker.checkForUpdate();
      available = update != null && update.versionCode > _currentVersionCode
          ? update
          : null;
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

      if (_isDesktop) {
        installing = true;
        notifyListeners();
        await _desktop.install(path);
      } else {
        await _bridge.installApk(path);
      }
    } catch (e) {
      downloadProgress = null;
      installing = false;
      error = e.toString();
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _recheck?.cancel();
    super.dispose();
  }
}
