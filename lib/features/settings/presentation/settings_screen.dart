import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/widgets/settings_tile.dart';
import '../../../services/updates/app_update_controller.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/data/auth_repository.dart';
import 'desktop_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    if (isWideLayout(context)) {
      return const DesktopSettings(account: _AccountSettings());
    }
    return const _AccountSettings();
  }
}

/// The phone's whole Settings screen, and the desktop's "Hisob" tab.
class _AccountSettings extends ConsumerWidget {
  const _AccountSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final user = session.user;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: <Widget>[
        SettingsTile(
          icon: Icons.person,
          title: user?.fullName ?? '',
          subtitle: user?.role == 'owner' ? 'Egasi' : 'Admin',
        ),
        const SizedBox(height: 12),
        const _AppVersionTile(),
        const SizedBox(height: 12),
        SettingsTile(
          icon: Icons.lock_reset,
          title: 'Sessiyalarni bekor qilish',
          subtitle: 'Barcha qurilmalarda qaytadan kirishni talab qiladi',
          onTap: () async {
            await ref.read(authRepositoryProvider).revokeMySessions();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Barcha sessiyalar bekor qilindi'),
                ),
              );
            }
          },
        ),
        const SizedBox(height: 12),
        SettingsTile(
          icon: Icons.logout,
          title: context.strings.logout,
          subtitle: 'Joriy hisobdan chiqish',
          onTap: () => ref.read(sessionControllerProvider).signOut(),
        ),
      ],
    );
  }
}

class _AppVersionTile extends ConsumerWidget {
  const _AppVersionTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appUpdateControllerProvider);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final progress = controller.downloadProgress;
        final subtitle = progress != null
            ? '${context.strings.downloadingUpdate} ${(progress * 100).toStringAsFixed(0)}%'
            : controller.available != null
            ? '${context.strings.updateAvailable}: v${controller.available!.versionName}'
            : 'v${controller.currentVersionName} (${controller.currentVersionCode})';
        final busy = controller.checking || progress != null;

        return SettingsTile(
          icon: Icons.system_update_rounded,
          title: 'Ilova versiyasi',
          subtitle: subtitle,
          trailing: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right_rounded),
          onTap: busy
              ? null
              : () => controller.available != null
                    ? controller.downloadAndInstall()
                    : controller.checkNow(),
        );
      },
    );
  }
}
