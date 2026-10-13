import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/updates/app_update_controller.dart';
import '../extensions/build_context_x.dart';

/// A thin strip shown app-wide whenever an update is available -- shrinks
/// away once the download starts installing.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appUpdateControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final update = controller.available;
        if (update == null) return const SizedBox.shrink();

        final progress = controller.downloadProgress;
        final busy = progress != null;

        return Material(
          color: context.colors.primary,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.system_update_rounded, size: 16, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      busy
                          ? '${context.strings.downloadingUpdate} ${(progress * 100).toStringAsFixed(0)}%'
                          : '${context.strings.updateAvailable}: v${update.versionName}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!busy)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: controller.downloadAndInstall,
                      child: Text(context.strings.update, style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
