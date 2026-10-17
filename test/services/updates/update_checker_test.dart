import 'package:expert_edu_center/services/updates/update_checker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const base = 'https://api.example';
  final release = <String, dynamic>{
    'version_code': 10,
    'version_name': '1.8.0',
    'notes': 'Jadval va davomat',
    'windows': {
      'url': '/uploads/desktop/expert-edu-center-setup-1.8.0.exe',
      'sha256': 'ab' * 32,
    },
    'linux_rpm': {
      'url': '/uploads/desktop/expert-edu-center-1.8.0-10.fc44.x86_64.rpm',
      'sha256': 'cd' * 32,
    },
  };

  test('each desktop platform gets its own file', () {
    final windows = AppUpdateInfo.desktopFromJson(release, 'windows', base)!;
    expect(windows.versionCode, 10);
    expect(windows.versionName, '1.8.0');
    expect(
      windows.apkUrl,
      '$base/uploads/desktop/expert-edu-center-setup-1.8.0.exe',
    );
    expect(windows.sha256, 'ab' * 32);
    expect(windows.force, isFalse);

    final linux = AppUpdateInfo.desktopFromJson(release, 'linux_rpm', base)!;
    expect(linux.apkUrl, endsWith('.rpm'));
    expect(linux.sha256, 'cd' * 32);
  });

  test('a release without this platform is no update', () {
    final windowsOnly = Map<String, dynamic>.of(release)..remove('linux_rpm');
    expect(
      AppUpdateInfo.desktopFromJson(windowsOnly, 'linux_rpm', base),
      isNull,
    );
  });
}
