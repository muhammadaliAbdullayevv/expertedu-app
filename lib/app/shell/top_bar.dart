import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// The wide layout's top bar: the command bar (Ctrl K) on the left and the
/// "+ Yangi" button on the right.
class AppTopBar extends StatelessWidget {
  const AppTopBar({
    super.key,
    required this.onOpenCommandBar,
    required this.newMenuItems,
  });

  final VoidCallback onOpenCommandBar;

  /// What "+ Yangi" offers; empty hides the button.
  final List<NewMenuItem> newMenuItems;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: CommandBarButton(onPressed: onOpenCommandBar),
            ),
          ),
          const Spacer(),
          if (newMenuItems.isNotEmpty) NewMenuButton(items: newMenuItems),
        ],
      ),
    );
  }
}

/// The search-looking button that opens the command palette.
class CommandBarButton extends StatelessWidget {
  const CommandBarButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  static String get shortcutLabel {
    const s = AppStrings.current;
    return defaultTargetPlatform == TargetPlatform.macOS
        ? s.commandBarShortcutMac
        : s.commandBarShortcut;
  }

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    return Semantics(
      button: true,
      label: s.commandBarHint,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadius.button),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppColors.canvas,
            borderRadius: BorderRadius.circular(AppRadius.button),
            border: Border.all(color: AppColors.borderStrong),
          ),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.search_rounded,
                size: 17,
                color: AppColors.inkMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.commandBarHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.inkMuted,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppColors.borderStrong),
                ),
                child: Text(
                  shortcutLabel,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NewMenuItem {
  const NewMenuItem(this.label, this.icon, this.onSelected);

  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

/// "+ Yangi": the accent button with the quick actions under it.
class NewMenuButton extends StatelessWidget {
  const NewMenuButton({super.key, required this.items, this.compact = false});

  final List<NewMenuItem> items;

  /// Icon only (phone app bar).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    return PopupMenuButton<NewMenuItem>(
      tooltip: s.newItem,
      offset: const Offset(0, 46),
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: const BorderSide(color: AppColors.border),
      ),
      color: AppColors.surface,
      onSelected: (item) => item.onSelected(),
      itemBuilder: (context) => <PopupMenuEntry<NewMenuItem>>[
        for (final item in items)
          PopupMenuItem<NewMenuItem>(
            value: item,
            child: Row(
              children: <Widget>[
                Icon(item.icon, size: 18, color: AppColors.inkSecondary),
                const SizedBox(width: 10),
                Text(
                  item.label,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 40,
        padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
        decoration: BoxDecoration(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.add_rounded, size: 18, color: Colors.white),
            if (!compact) ...<Widget>[
              const SizedBox(width: 8),
              Text(
                s.newItem,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
