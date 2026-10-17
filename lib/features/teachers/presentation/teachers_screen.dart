import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/shell_counts.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/person_avatar.dart';
import '../../../core/widgets/status_chip.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../data/teachers_repository.dart';
import 'teacher_form_dialog.dart';
import 'teacher_panel.dart';
import 'teacher_text.dart';

/// O'qituvchilar (desktop): the teachers in a table -- groups, students and
/// this month's pay -- with the chosen teacher's page on the right.
class TeachersScreen extends ConsumerStatefulWidget {
  const TeachersScreen({super.key});

  @override
  ConsumerState<TeachersScreen> createState() => TeachersScreenState();
}

class TeachersScreenState extends ConsumerState<TeachersScreen> {
  final _search = TextEditingController();
  late Future<List<Teacher>> _teachers = _load();
  TeacherTab _tab = TeacherTab.active;
  int? _selected;

  Future<List<Teacher>> _load() =>
      ref.read(teachersRepositoryProvider).list(includeInactive: true);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Called by the shell.
  void reload() {
    final next = _load();
    setState(() {
      _teachers = next;
    });
    ref.invalidate(shellCountsProvider);
  }

  bool clearSearchIfActive() {
    if (_search.text.isEmpty) return false;
    setState(() {
      _search.clear();
    });
    return true;
  }

  Future<void> _create() async {
    final saved = await showTeacherFormDialog(context);
    if (saved == true) reload();
  }

  List<Teacher> _visible(List<Teacher> all) {
    final q = _search.text.trim().toLowerCase();
    final digits = q.replaceAll(RegExp(r'\D'), '');
    return [
      for (final t in filterTeachers(all, tab: _tab))
        if (q.isEmpty ||
            t.fullName.toLowerCase().contains(q) ||
            (digits.isNotEmpty && (t.phone ?? '').contains(digits)))
          t,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Teacher>>(
      future: _teachers,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadFailed(error: snapshot.error!, onRetry: reload);
        }
        final all = snapshot.data;
        if (all == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final shown = _visible(all);
        final selected = shown.any((t) => t.id == _selected)
            ? _selected
            : (shown.isEmpty ? null : shown.first.id);
        return Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _tabs(teacherTabCounts(all)),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 280,
                  child: TextField(
                    key: const ValueKey('teachers-search'),
                    controller: _search,
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 20),
                      hintText: 'Ism yoki telefon',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: _table(shown, selected)),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 460,
                      child: selected == null
                          ? const _NothingSelected()
                          : TeacherPanel(
                              key: ValueKey('teacher-panel-$selected'),
                              teacherId: selected,
                              onChanged: reload,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tabs(Map<TeacherTab, int> counts) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: <Widget>[
          for (final tab in TeacherTab.values)
            InkWell(
              key: ValueKey('tab-${tab.name}'),
              onTap: () => setState(() {
                _tab = tab;
              }),
              child: Container(
                height: 44,
                margin: const EdgeInsets.only(right: 24),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: tab == _tab
                          ? AppColors.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      tab.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: tab == _tab ? AppColors.ink : AppColors.inkMuted,
                      ),
                    ),
                    if (tab != TeacherTab.archive) ...<Widget>[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.divider,
                          borderRadius: BorderRadius.circular(AppRadius.chip),
                        ),
                        child: Text(
                          '${counts[tab]}',
                          key: ValueKey('count-${tab.name}'),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: AppColors.inkSecondary,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: FilledButton.icon(
              key: const ValueKey('new-teacher'),
              onPressed: _create,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Yangi o\'qituvchi'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(List<Teacher> shown, int? selected) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          const _TableHeader(),
          const Divider(height: 1, color: AppColors.divider),
          Expanded(
            child: shown.isEmpty
                ? const Center(
                    child: Text(
                      'Hech kim topilmadi.',
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  )
                : ListView.separated(
                    key: const ValueKey('teachers-list'),
                    itemCount: shown.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.divider),
                    itemBuilder: (context, i) => _TeacherRow(
                      key: ValueKey('teacher-${shown[i].id}'),
                      teacher: shown[i],
                      selected: shown[i].id == selected,
                      onTap: () => setState(() => _selected = shown[i].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _NothingSelected extends StatelessWidget {
  const _NothingSelected();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      alignment: Alignment.center,
      child: const Text(
        'Sahifasini ko\'rish uchun o\'qituvchini tanlang.',
        style: TextStyle(color: AppColors.inkMuted),
      ),
    );
  }
}

const _head = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w600,
  color: AppColors.inkMuted,
);

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: <Widget>[
          Expanded(flex: 50, child: Text('O\'qituvchi', style: _head)),
          Expanded(flex: 25, child: Text('Guruhlar', style: _head)),
          Expanded(
            flex: 25,
            child: Text(
              'O\'quvchilar',
              textAlign: TextAlign.right,
              style: _head,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeacherRow extends StatelessWidget {
  const _TeacherRow({
    super.key,
    required this.teacher,
    required this.selected,
    required this.onTap,
  });

  final Teacher teacher;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = teacher;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? AppColors.accentSoft : null,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 50,
              child: Row(
                children: <Widget>[
                  PersonAvatar(name: t.fullName, photo: t.photo),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                t.fullName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (!t.isActive) ...<Widget>[
                              const SizedBox(width: 6),
                              const StatusChip('Arxiv'),
                            ],
                          ],
                        ),
                        Text(
                          t.phone == null
                              ? '—'
                              : PhoneFormatter.display(t.phone!),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 25,
              child: Text(
                '${t.groupCount ?? 0}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              flex: 25,
              child: Text(
                '${t.studentCount ?? 0}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
