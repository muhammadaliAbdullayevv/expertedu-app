import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';
import 'pressable.dart';

/// A [ListTile] wrapped in a bordered, rounded card -- the shared look for
/// every browsable list in this app (subjects, groups, students), instead
/// of a flat unstyled row. Tapping it scales down slightly via [Pressable]
/// rather than relying on the ripple alone.
class BorderedListTile extends StatelessWidget {
  const BorderedListTile({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final Widget leading;
  final Widget title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Pressable(
        onTap: onTap,
        child: Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          color: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            leading: leading,
            title: title,
            subtitle: subtitle,
            trailing: trailing,
          ),
        ),
      ),
    );
  }
}
