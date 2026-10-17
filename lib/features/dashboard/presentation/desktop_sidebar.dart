import 'package:flutter/material.dart';

import '../../../app/theme/app_theme.dart';

typedef SidebarItem = ({IconData icon, IconData selectedIcon, String label});

/// The wide layout's navigation: a white sidebar with the logo, one main
/// action, and the destinations. Replaces Material's NavigationRail, whose
/// selection pill hugs only the icon -- each item here highlights as one
/// piece, icon and label together, so they clearly belong to each other.
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.extended,
    required this.actionLabel,
    required this.actionIcon,
    required this.onAction,
    this.accountName,
    this.accountRole,
  });

  final List<SidebarItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  /// Labels beside the icons (wide windows) rather than under them.
  final bool extended;

  final String actionLabel;
  final IconData actionIcon;
  final VoidCallback onAction;
  final String? accountName;
  final String? accountRole;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: extended ? 240 : 88,
      decoration: const BoxDecoration(
        color: AppColors.sidebar,
        border: Border(right: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Logo(extended: extended),
            Padding(
              padding: EdgeInsets.fromLTRB(
                extended ? 16 : 14,
                8,
                extended ? 16 : 14,
                20,
              ),
              child: _ActionButton(
                label: actionLabel,
                icon: actionIcon,
                extended: extended,
                onPressed: onAction,
              ),
            ),
            Expanded(
              child: ListView(
                primary: false,
                padding: EdgeInsets.zero,
                children: <Widget>[
                  for (var i = 0; i < items.length; i++)
                    _SidebarTile(
                      item: items[i],
                      selected: i == selectedIndex,
                      extended: extended,
                      onTap: () => onSelect(i),
                    ),
                ],
              ),
            ),
            _AccountFooter(
              name: accountName,
              role: accountRole,
              extended: extended,
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountFooter extends StatelessWidget {
  const _AccountFooter({
    required this.name,
    required this.role,
    required this.extended,
  });

  final String? name;
  final String? role;
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final displayName = name?.trim().isNotEmpty == true
        ? name!.trim()
        : 'Hisob';
    final initial = displayName.isEmpty ? '?' : displayName[0].toUpperCase();
    return Tooltip(
      message: <String>[displayName, if (role != null) role!].join(' · '),
      child: Container(
        margin: EdgeInsets.fromLTRB(12, 8, 12, extended ? 12 : 10),
        padding: EdgeInsets.all(extended ? 10 : 7),
        decoration: BoxDecoration(
          color: AppColors.canvas,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: extended
              ? MainAxisAlignment.start
              : MainAxisAlignment.center,
          children: <Widget>[
            CircleAvatar(
              radius: 17,
              backgroundColor: AppColors.accentSoft,
              foregroundColor: AppColors.accent,
              child: Text(
                initial,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            if (extended) ...<Widget>[
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (role != null)
                      Text(
                        role!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.inkMuted,
                          fontSize: 11,
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

class _Logo extends StatelessWidget {
  const _Logo({required this.extended});

  final bool extended;

  @override
  Widget build(BuildContext context) {
    final mark = Image.asset(
      'assets/branding/logo_mark.png',
      height: 24,
      filterQuality: FilterQuality.medium,
    );
    return SizedBox(
      height: 72,
      child: extended
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: <Widget>[
                  mark,
                  const SizedBox(width: 12),
                  const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'EXPERT',
                        style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2.4,
                          height: 1.1,
                        ),
                      ),
                      Text(
                        'LEARNING CENTER',
                        style: TextStyle(
                          color: AppColors.inkMuted,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.6,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            )
          : Center(child: mark),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.extended,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool extended;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: AppColors.accent,
      foregroundColor: Colors.white,
      minimumSize: const Size.fromHeight(44),
      padding: EdgeInsets.zero,
      // Built on the theme's style -- a bare TextStyle here would replace
      // it and drop the app's font.
      textStyle: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    );
    if (!extended) {
      return Tooltip(
        message: label,
        child: FilledButton(
          style: style,
          onPressed: onPressed,
          child: Icon(icon),
        ),
      );
    }
    return FilledButton.icon(
      style: style,
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
    );
  }
}

class _SidebarTile extends StatefulWidget {
  const _SidebarTile({
    required this.item,
    required this.selected,
    required this.extended,
    required this.onTap,
  });

  final SidebarItem item;
  final bool selected;
  final bool extended;
  final VoidCallback onTap;

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  static const _duration = Duration(milliseconds: 160);

  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final background = selected
        ? AppColors.accentSoft
        : _hovered
        ? AppColors.sidebarHover
        : Colors.transparent;
    final foreground = selected
        ? AppColors.accent
        : _hovered
        ? AppColors.ink
        : AppColors.sidebarText;
    final icon = Icon(
      selected ? widget.item.selectedIcon : widget.item.icon,
      size: 22,
      color: foreground,
    );
    // AnimatedDefaultTextStyle replaces the inherited style rather than
    // merging into it, so start from the ambient one to keep the app font.
    final label = AnimatedDefaultTextStyle(
      duration: _duration,
      style: DefaultTextStyle.of(context).style.copyWith(
        color: foreground,
        fontSize: widget.extended ? 14 : 11,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
      child: Text(
        widget.item.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: widget.extended ? TextAlign.start : TextAlign.center,
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      label: widget.item.label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: widget.extended ? 12 : 8,
              vertical: 2,
            ),
            child: AnimatedScale(
              scale: _pressed ? 0.97 : 1,
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: _duration,
                curve: Curves.easeOut,
                padding: widget.extended
                    ? const EdgeInsets.symmetric(horizontal: 14, vertical: 11)
                    : const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(AppRadius.button),
                ),
                child: widget.extended
                    ? Row(
                        children: <Widget>[
                          icon,
                          const SizedBox(width: 14),
                          Expanded(child: label),
                        ],
                      )
                    : Column(
                        children: <Widget>[
                          icon,
                          const SizedBox(height: 4),
                          label,
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
