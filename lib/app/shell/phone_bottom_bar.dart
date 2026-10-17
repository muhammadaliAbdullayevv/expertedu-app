import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../navigation/destinations.dart';
import '../theme/app_theme.dart';

/// The phone's bottom navigation (V2): two destinations, the round "+"
/// that takes a payment, and two more. Touch targets are at least 56 high.
class PhoneBottomBar extends StatelessWidget {
  const PhoneBottomBar({
    super.key,
    required this.layout,
    required this.selected,
    required this.onSelect,
    required this.onPayment,
  });

  final PhoneBarLayout layout;
  final Destination selected;
  final ValueChanged<Destination> onSelect;
  final VoidCallback onPayment;

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
            if (layout.showPaymentButton) _PaymentButton(onPressed: onPayment),
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

class _PaymentButton extends StatelessWidget {
  const _PaymentButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Transform.translate(
        offset: const Offset(0, -14),
        child: Semantics(
          button: true,
          label: s.receivePayment,
          child: GestureDetector(
            onTap: onPressed,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 28,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
