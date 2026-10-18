import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../auth/application/session_controller.dart';
import '../application/branch_view.dart';
import '../data/branches_repository.dart';

/// Right under the logo. The OWNER picks which branch the whole app shows
/// ("Hammasi" or one filial); an ADMIN just sees the name of the branch they
/// work in -- the server fixes it, there is nothing to choose.
class BranchSwitcher extends ConsumerWidget {
  const BranchSwitcher({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    if (!session.isOwner) {
      final name = session.user?.branchName;
      if (name == null) return const SizedBox.shrink();
      return _Label(
        key: const ValueKey('branch-label'),
        text: name,
        compact: compact,
        tooltip: 'Siz $name filialida ishlaysiz',
      );
    }
    final viewing = ref.watch(branchViewProvider);
    final branches = ref.watch(branchListProvider).value ?? const <Branch>[];
    // One branch only (nothing added yet): nothing to switch between.
    if (branches.length < 2) return const SizedBox.shrink();
    final current = branches.where((b) => b.id == viewing).firstOrNull;
    final text = current?.name ?? 'Hammasi';
    return PopupMenuButton<int>(
      key: const ValueKey('branch-switcher'),
      tooltip: 'Filialni tanlang',
      offset: const Offset(0, 44),
      onSelected: (id) =>
          ref.read(branchViewProvider.notifier).select(id == 0 ? null : id),
      itemBuilder: (_) => <PopupMenuEntry<int>>[
        PopupMenuItem(
          key: const ValueKey('branch-option-all'),
          value: 0,
          child: _Option('Hammasi', selected: current == null),
        ),
        const PopupMenuDivider(),
        for (final b in branches)
          PopupMenuItem(
            key: ValueKey('branch-option-${b.id}'),
            value: b.id,
            child: _Option(b.name, selected: current?.id == b.id),
          ),
      ],
      child: _Label(
        text: text,
        compact: compact,
        tooltip: 'Filial: $text',
        caret: true,
        highlighted: current != null,
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option(this.name, {required this.selected});

  final String name;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 22,
          child: selected
              ? const Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: AppColors.accent,
                )
              : null,
        ),
        Text(
          name,
          style: TextStyle(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label({
    super.key,
    required this.text,
    required this.compact,
    required this.tooltip,
    this.caret = false,
    this.highlighted = false,
  });

  final String text;
  final bool compact;
  final String tooltip;
  final bool caret;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        height: 38,
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
        alignment: compact ? Alignment.center : Alignment.centerLeft,
        decoration: BoxDecoration(
          color: highlighted ? AppColors.accentSoft : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(
            color: highlighted ? AppColors.accent : AppColors.border,
          ),
        ),
        child: compact
            ? const Icon(Icons.apartment_rounded, size: 20)
            : Row(
                children: <Widget>[
                  const Icon(Icons.apartment_rounded, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (caret) const Icon(Icons.unfold_more_rounded, size: 18),
                ],
              ),
      ),
    );
  }
}
