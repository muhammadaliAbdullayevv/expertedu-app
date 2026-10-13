import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../api/api_config.dart';

final updateCheckerProvider = Provider<UpdateChecker>((ref) {
  return UpdateChecker(http.Client());
});

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.notes,
    required this.apkUrl,
    required this.force,
  });

  final int versionCode;
  final String versionName;
  final String? notes;
  final String apkUrl;

  /// When true, the app blocks all use until this update is installed
  /// (see ForceUpdateScreen) instead of just showing an optional nudge in
  /// Settings. Absent/false in version.json means optional, matching every
  /// release before this field existed.
  final bool force;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json, String baseUrl) {
    final apkPath = json['apk_path'] as String;
    return AppUpdateInfo(
      versionCode: json['version_code'] as int,
      versionName: json['version_name'] as String,
      notes: json['notes'] as String?,
      apkUrl: apkPath.startsWith('http') ? apkPath : '$baseUrl$apkPath',
      force: json['force'] as bool? ?? false,
    );
  }
}

/// Reads a small static `version.json` the server exposes alongside the
/// latest release APK (both just files under /uploads/app/ -- no dedicated
/// backend endpoint needed) and can download that APK for the native
/// installer to pick up. No app store involved, matching everything else
/// about this private, self-hosted app.
class UpdateChecker {
  UpdateChecker(this._http);

  final http.Client _http;

  /// Throws on any failure (network error, timeout, bad response) instead of
  /// swallowing it, so the caller can tell "confirmed no update" apart from
  /// "the check itself failed" rather than silently reporting the latter as
  /// the former.
  Future<AppUpdateInfo> checkForUpdate() async {
    // The "clone" build flavor (a second, independently-installable copy
    // for testing the owner/customer sides side by side, its own distinct
    // applicationId ending in ".dev" -- see android/app/build.gradle.kts)
    // has its own separate release artifact and can't self-update from the
    // real app's version.json: that one's apk_path is signed/packaged
    // under the real applicationId, which Android's installer won't accept
    // as an update to a *different* installed package.
    final packageInfo = await PackageInfo.fromPlatform();
    final versionFile = packageInfo.packageName.endsWith('.dev')
        ? 'version-dev.json'
        : 'version.json';
    final response = await _http
        .get(Uri.parse('${ApiConfig.baseUrl}/uploads/app/$versionFile'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception(
        'Versiyani tekshirish muvaffaqiyatsiz: ${response.statusCode}',
      );
    }
    final json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return AppUpdateInfo.fromJson(json, ApiConfig.baseUrl);
  }

  /// Downloads [update]'s APK to a cache file and returns its path.
  Future<String> download(
    AppUpdateInfo update, {
    void Function(double)? onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(update.apkUrl));
    final response = await _http.send(request);
    if (response.statusCode != 200) {
      throw Exception('Yuklab olish muvaffaqiyatsiz: ${response.statusCode}');
    }

    final total = response.contentLength ?? 0;
    final directory = await getTemporaryDirectory();
    final file = File('${directory.path}/expertedu-update.apk');
    final sink = file.openWrite();
    var received = 0;

    await response.stream
        .map((chunk) {
          received += chunk.length;
          if (total > 0) {
            onProgress?.call(received / total);
          }
          return chunk;
        })
        .pipe(sink);

    return file.path;
  }
}
