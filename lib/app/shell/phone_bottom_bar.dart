import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../navigation/destinations.dart';
import '../theme/app_theme.dart';

/// The phone's bottom navigation (V2): destinations only -- payments are
/// taken on a student's profile, not from here. Touch targets are at least 56 high.
class PhoneBottomBar extends StatelessWidget {
  const PhoneBottomBar({
    super.key,
    required this.layout,
    required this.selected,
    required this.onSelect,
  });

  final PhoneBarLayout layout;
  final Destination selected;
  final ValueChanged<Destination> onSelect;

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    return Semantics(
      container: true,
      label: s.navMainMenu,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          8,
          4,
          8,
          10 + MediaQuery.paddingOf(context).bottom,
        ),
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            for (final d in layout.left)
              _BarItem(d, selected: d == selected, onTap: () => onSelect(d)),
            for (final d in layout.right)
              _BarItem(d, selected: d == selected, onTap: () => onSelect(d)),
          ],
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem(
    this.destination, {
    required this.selected,
    required this.onTap,
  });

  final Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    final color = selected ? AppColors.accent : AppColors.inkMuted;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: destination.label(s),
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(destination.icon, size: 22, color: color),
                const SizedBox(height: 3),
                Text(
                  destination.shortLabel(s),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
