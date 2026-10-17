import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

/// "Guruhlar › Ingliz tili › Beginner A": where you are inside Guruhlar. The
/// course is a button -- click it to go back to the course's groups -- so a
/// group never feels like a different screen; the sidebar stays as it is.
class GroupsBreadcrumb extends StatelessWidget {
  const GroupsBreadcrumb({super.key, this.course, this.group});

  final String? course;
  final String? group;

  @override
  Widget build(BuildContext context) {
    final nav = Navigator.of(context);
    Widget link(String label, VoidCallback onTap, {Key? key}) => InkWell(
      key: key,
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.accentSoft,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.accentText,
          ),
        ),
      ),
    );
    const sep = Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: Icon(Icons.chevron_right, size: 18, color: AppColors.inkMuted),
    );
    return Row(
      children: <Widget>[
        link(
          'Guruhlar',
          () => nav.popUntil((r) => r.isFirst),
          key: const ValueKey('crumb-root'),
        ),
        if (course != null) ...<Widget>[
          sep,
          if (group == null)
            Text(
              course!,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            )
          else
            link(course!, () => nav.pop(), key: const ValueKey('crumb-course')),
        ],
        if (group != null) ...<Widget>[
          sep,
          Flexible(
            child: Text(
              group!,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ],
    );
  }
}
