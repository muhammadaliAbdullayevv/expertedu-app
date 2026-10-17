import 'package:flutter/material.dart';

import '../../app/theme/app_theme.dart';

/// Which status colours a chip uses. Chips always carry a text label --
/// the colour only reinforces it, never replaces it.
enum StatusTone {
  ok(AppColors.okBg, AppColors.okText),
  warning(AppColors.warnBg, AppColors.warnText),
  danger(AppColors.dangerBg, AppColors.dangerText),
  info(AppColors.accentSoft, AppColors.accentText),
  neutral(AppColors.neutralBg, AppColors.neutralText);

  const StatusTone(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

/// A small pill: "Davomat olingan", "Qarz", "Sinov"... Pass [width] to line
/// a column of chips up (the Bugun lists do).
class StatusChip extends StatelessWidget {
  const StatusChip(
    this.label, {
    super.key,
    this.tone = StatusTone.neutral,
    this.width,
  });

  final String label;
  final StatusTone tone;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: tone.background,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      // Centred in the 24 px pill; the width still hugs the text.
      child: Center(
        widthFactor: 1,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: tone.foreground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}
