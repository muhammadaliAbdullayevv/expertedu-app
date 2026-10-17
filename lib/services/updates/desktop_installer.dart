import 'dart:io';

import 'package:flutter/foundation.dart';

/// Installs a downloaded desktop release and restarts into it.
///
/// - Windows: the setup (windows/installer/expert_edu_center.iss) runs with
///   /SILENT; it closes this app, replaces the files and starts the new
///   version itself. Per-user install, so no administrator prompt.
/// - Linux: `pkexec dnf install` -- the system's own password prompt --
///   then a fresh start. Only for the RPM install under /opt; a build run
///   from anywhere else isn't the installed app and isn't replaced.
class DesktopInstaller {
  const DesktopInstaller();

  static const String _rpmInstallDir = '/opt/expert-edu-center/';

  /// Whether this running copy is one the installer can replace.
  static bool get canSelfUpdate {
    if (!kReleaseMode) return false;
    if (Platform.isWindows) return true;
    if (Platform.isLinux) {
      return Platform.resolvedExecutable.startsWith(_rpmInstallDir);
    }
    return false;
  }

  /// Returns only if installing failed; on success the app exits.
  Future<void> install(String path) async {
    if (Platform.isWindows) {
      await Process.start(path, <String>[
        '/SILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
      ], mode: ProcessStartMode.detached);
      // The setup closes us anyway; leaving first saves it the wait.
      await Future<void>.delayed(const Duration(seconds: 1));
      exit(0);
    }

    final ProcessResult result;
    try {
      result = await Process.run('pkexec', <String>[
        'dnf',
        'install',
        '-y',
        path,
      ]);
    } on ProcessException {
      throw DesktopInstallException.manual(path);
    }
    if (result.exitCode == 126 || result.exitCode == 127) {
      // 126: the password prompt was dismissed; 127: not authorised.
      throw const DesktopInstallException('O\'rnatish bekor qilindi.');
    }
    if (result.exitCode != 0) throw DesktopInstallException.manual(path);

    // The app allows one running copy, so the new one may only start once
    // this one has gone -- hence the short delay in a detached shell.
    await Process.start('sh', <String>[
      '-c',
      'sleep 1; exec "${Platform.resolvedExecutable}"',
    ], mode: ProcessStartMode.detached);
    exit(0);
  }
}

class DesktopInstallException implements Exception {
  const DesktopInstallException(this.message);

  factory DesktopInstallException.manual(String path) =>
      DesktopInstallException(
        'Avtomatik o\'rnatib bo\'lmadi. Terminalda bajaring: '
        'sudo dnf install $path',
      );

  final String message;

  @override
  String toString() => message;
}
