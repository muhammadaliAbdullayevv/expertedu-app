import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import '../extensions/build_context_x.dart';
import 'pressable.dart';

/// A single icon+title+subtitle row inside a bordered card -- the shared
/// look for a tappable settings row.
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: context.colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: context.colors.outlineVariant),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 18,
            vertical: 10,
          ),
          leading: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: context.colors.primary.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(AppRadius.field),
            ),
            child: Icon(icon, color: context.colors.primary),
          ),
          title: Text(title, style: context.textTheme.titleSmall),
          subtitle: Text(subtitle),
          trailing: trailing,
        ),
      ),
    );
  }
}
