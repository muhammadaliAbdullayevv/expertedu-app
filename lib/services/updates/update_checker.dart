import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
    this.sha256,
  });

  final int versionCode;
  final String versionName;
  final String? notes;

  /// Where the installable file is: the APK on Android, the setup .exe on
  /// Windows, the .rpm on Linux.
  final String apkUrl;

  /// The file's SHA-256 (desktop releases): a download that doesn't match
  /// is never installed.
  final String? sha256;

  /// When true, the app blocks all use until this update is installed
  /// (see ForceUpdateScreen) instead of just showing an optional nudge in
  /// Settings. Absent/false in version.json means optional, matching every
  /// release before this field existed.
  final bool force;

  /// One platform's entry in /uploads/desktop/version.json, written by
  /// tools/publish-desktop.sh:
  ///
  ///     {"version_code": 10, "version_name": "1.8.0", "notes": "...",
  ///      "windows": {"url": "/uploads/desktop/...exe", "sha256": "..."},
  ///      "linux_rpm": {"url": "/uploads/desktop/...rpm", "sha256": "..."}}
  ///
  /// Null when this release has nothing for [platformKey].
  static AppUpdateInfo? desktopFromJson(
    Map<String, dynamic> json,
    String platformKey,
    String baseUrl,
  ) {
    final entry = json[platformKey] as Map<String, dynamic>?;
    if (entry == null) return null;
    final url = entry['url'] as String;
    return AppUpdateInfo(
      versionCode: json['version_code'] as int,
      versionName: json['version_name'] as String,
      notes: json['notes'] as String?,
      apkUrl: url.startsWith('http') ? url : '$baseUrl$url',
      force: false,
      sha256: entry['sha256'] as String?,
    );
  }

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

  /// The desktop release for this platform, or null if the latest release
  /// has none for it. Throws if the check itself fails.
  Future<AppUpdateInfo?> checkForDesktopUpdate() async {
    final response = await _http
        .get(Uri.parse('${ApiConfig.baseUrl}/uploads/desktop/version.json'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) {
      throw Exception(
        'Versiyani tekshirish muvaffaqiyatsiz: ${response.statusCode}',
      );
    }
    final json =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    return AppUpdateInfo.desktopFromJson(
      json,
      Platform.isWindows ? 'windows' : 'linux_rpm',
      ApiConfig.baseUrl,
    );
  }

  /// Downloads [update]'s file to a temporary file and returns its path,
  /// after checking its SHA-256 when the release lists one.
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
    final name = Uri.parse(update.apkUrl).pathSegments.last;
    final file = File('${directory.path}/$name');
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

    final expected = update.sha256;
    if (expected != null) {
      final actual = sha256.convert(await file.readAsBytes()).toString();
      if (actual != expected.toLowerCase()) {
        await file.delete();
        throw Exception('Yuklangan fayl buzilgan. Qaytadan urinib ko\'ring.');
      }
    }
    return file.path;
  }
}
