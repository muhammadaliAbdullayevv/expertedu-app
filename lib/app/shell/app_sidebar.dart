import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../navigation/destinations.dart';
import '../../core/widgets/status_chip.dart';
import '../theme/app_theme.dart';

/// The wide layout's navigation (V2): the logo, the "Ish stoli" and
/// "Boshqaruv" groups, Sozlamalar and the signed-in user at the bottom.
/// Items highlight as one piece, icon and label together. In a narrow
/// desktop window it shrinks to an icon rail with tooltips.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.role,
    required this.selected,
    required this.onSelect,
    required this.userName,
    required this.onUserTap,
    this.counts = const {},
    this.compact = false,
    this.localMode = false,
  });

  static const double width = 244;
  static const double compactWidth = 76;

  final AppRole role;
  final Destination selected;
  final ValueChanged<Destination> onSelect;

  /// Small counts beside a label (open leads, active students...). Missing
  /// = no badge, e.g. while offline.
  final Map<Destination, int> counts;
  final String userName;
  final VoidCallback onUserTap;
  final bool compact;

  /// The app is on this computer's own test data, not the real server.
  final bool localMode;

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    final sections = <(String?, List<Destination>)>[
      (s.navSectionWork, sectionFor(role, NavSection.work)),
      (s.navSectionManage, sectionFor(role, NavSection.manage)),
    ];
    final hasSettings = Destination.settings.allowedFor(role);
    return Container(
      width: compact ? compactWidth : width,
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: 16,
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Brand(compact: compact),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: <Widget>[
                  for (final (title, items) in sections)
                    if (items.isNotEmpty) ...<Widget>[
                      if (compact)
                        const SizedBox(height: 10)
                      else
                        _SectionLabel(title!),
                      for (final d in items)
                        _NavItem(
                          destination: d,
                          selected: d == selected,
                          // Qabul is deliberately number-free: no badge, whatever
                          // is passed in.
                          count: d == Destination.admissions ? null : counts[d],
                          compact: compact,
                          onTap: () => onSelect(d),
                        ),
                    ],
                ],
              ),
            ),
            if (hasSettings)
              _NavItem(
                destination: Destination.settings,
                selected: selected == Destination.settings,
                compact: compact,
                onTap: () => onSelect(Destination.settings),
              ),
            if (localMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Tooltip(
                  message:
                      'Ma\'lumotlar shu kompyuterda: haqiqiy serverga ulanmagan.',
                  child: StatusChip(
                    compact ? 'Lokal' : 'Mahalliy rejim',
                    tone: StatusTone.warning,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            const Divider(height: 1, color: AppColors.divider),
            _UserCard(
              name: userName,
              roleLabel: role.label(s),
              compact: compact,
              onTap: onUserTap,
            ),
          ],
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 14),
      child: Row(
        mainAxisAlignment: compact
            ? MainAxisAlignment.center
            : MainAxisAlignment.start,
        children: <Widget>[
          const LogoMark(),
          if (!compact) ...<Widget>[
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  s.brandName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    height: 1.15,
                    color: AppColors.ink,
                  ),
                ),
                Text(
                  s.brandSubtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.15,
                    color: AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The two yellow chevrons on a dark tile.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 34});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(10),
      ),
      child: CustomPaint(painter: _ChevronPainter()),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on the design's 34-unit grid.
    final k = size.width / 34;
    final paint = Paint()
      ..color = AppColors.brandYellow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path()
      ..moveTo(7 * k, 7 * k)
      ..lineTo(17 * k, 17 * k)
      ..lineTo(7 * k, 27 * k)
      ..moveTo(27 * k, 7 * k)
      ..lineTo(17 * k, 17 * k)
      ..lineTo(27 * k, 27 * k);
    canvas.save();
    canvas.translate(size.width * 0.18, size.height * 0.18);
    canvas.scale(0.64);
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) => false;
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.88,
          color: AppColors.inkMuted,
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.compact,
    required this.onTap,
    this.count,
  });

  final Destination destination;
  final bool selected;
  final bool compact;
  final int? count;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    final d = widget.destination;
    final selected = widget.selected;
    final label = d.label(s);
    final color = selected ? AppColors.accentText : AppColors.sidebarText;
    final background = selected
        ? AppColors.accentSoft
        : (_hover ? AppColors.sidebarHover : Colors.transparent);
    final item = Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            height: 40,
            margin: const EdgeInsets.only(bottom: 2),
            padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 12),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisAlignment: widget.compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: <Widget>[
                Icon(d.icon, size: 20, color: color),
                if (!widget.compact) ...<Widget>[
                  const SizedBox(width: 11),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: color,
                      ),
                    ),
                  ),
                  if (widget.count != null) _Badge(widget.count!, selected),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    return widget.compact ? Tooltip(message: label, child: item) : item;
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.count, this.selected);

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: selected ? Colors.white : AppColors.border,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: selected ? AppColors.accentText : AppColors.neutralText,
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.name,
    required this.roleLabel,
    required this.compact,
    required this.onTap,
  });

  final String name;
  final String roleLabel;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
        child: Row(
          mainAxisAlignment: compact
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: <Widget>[
            Avatar(name: name),
            if (!compact) ...<Widget>[
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        height: 1.2,
                      ),
                    ),
                    Text(
                      roleLabel,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.2,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A round avatar with the person's initials.
class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.size = 36});

  final String name;
  final double size;

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final letters = parts.take(2).map((p) => p.characters.first.toUpperCase());
    final joined = letters.join();
    return joined.isEmpty ? '?' : joined;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: AppColors.accentSoft,
        shape: BoxShape.circle,
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          color: AppColors.accentText,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
        ),
      ),
    );
  }
}
