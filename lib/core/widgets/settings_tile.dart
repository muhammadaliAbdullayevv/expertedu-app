import 'package:flutter/material.dart';

import '../extensions/build_context_x.dart';
import 'section_card.dart';

/// A single icon+title+subtitle row inside a [SectionCard] -- the shared
/// look for a tappable settings row, used by both the staff Settings
/// screen (its own private copy, predating this one) and the customer
/// portal's Settings tab.
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
    return SectionCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: context.colors.primary.withValues(alpha: 0.09),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Icon(icon, color: context.colors.primary),
        ),
        title: Text(title, style: context.textTheme.titleSmall),
        subtitle: Text(subtitle),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}
