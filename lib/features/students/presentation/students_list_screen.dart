import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/shell_counts.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/person_avatar.dart';
import '../../../core/widgets/status_chip.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../branches/application/branch_view.dart';
import '../data/student_models.dart';
import '../data/students_repository.dart';
import 'add_student_dialog.dart';
import 'open_student.dart';
import 'student_panel.dart';
import 'student_text.dart';

/// One table row's height, to scroll a student into view.
const _rowExtent = 66.0;

/// O'quvchilar (desktop): the students in a table -- group and teacher,
/// attendance of the last lessons, balance, status -- with the selected
/// student's profile on the right.
class StudentsListScreen extends ConsumerStatefulWidget {
  const StudentsListScreen({super.key});

  @override
  ConsumerState<StudentsListScreen> createState() => StudentsListScreenState();
}

class StudentsListScreenState extends ConsumerState<StudentsListScreen> {
  final _search = TextEditingController();
  late Future<List<StudentRow>> _rows = _load();
  late final ValueNotifier<int?> _open = ref.read(openStudentRequestProvider);

  StudentTab _tab = StudentTab.all;
  int? _subjectId;
  int? _groupId;
  int? _teacherId;
  final _scroll = ScrollController();
  int? _selected;
  bool _searchVisible = false;

  Future<List<StudentRow>> _load() =>
      ref.read(studentsRepositoryProvider).rows();

  @override
  void initState() {
    super.initState();
    _open.addListener(_onOpenRequest);
    // Asked for before this page existed (the shell builds pages lazily).
    if (_open.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onOpenRequest());
    }
  }

  @override
  void dispose() {
    _open.removeListener(_onOpenRequest);
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // --- Things the shell calls ----------------------------------------------

  void reload() {
    final next = _load();
    setState(() {
      _rows = next;
    });
    ref.invalidate(shellCountsProvider);
    ref.invalidate(studentSummaryProvider);
  }

  /// Called from HomeShell's shared search icon.
  void toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) _search.clear();
    });
  }

  /// Shows the search box with [query] already typed -- the command bar
  /// jumps here when a student is picked.
  void applySearch(String query) {
    setState(() {
      _searchVisible = true;
      _search.text = query;
      _tab = StudentTab.all;
    });
  }

  bool clearSearchIfActive() {
    if (_search.text.isEmpty) return false;
    setState(() {
      _search.clear();
    });
    return true;
  }

  /// Called from HomeShell's "Yangi o'quvchi".
  Future<void> showCreateSheet() async {
    final saved = await showAddStudentDialog(context);
    if (saved == true) {
      reload();
      if (mounted) showSnack(context, 'O\'quvchi saqlandi');
    }
  }

  /// Opens one student's profile: clears the filters that would hide them.
  Future<void> _onOpenRequest() async {
    final id = _open.value;
    if (id == null || !mounted) return;
    // Cleared after the other listeners (the shell) have seen it.
    scheduleMicrotask(() => _open.value = null);
    final rows = await _rows;
    if (!mounted) return;
    final student = rows.where((s) => s.id == id).firstOrNull;
    setState(() {
      _selected = id;
      _search.clear();
      _subjectId = _groupId = _teacherId = null;
      _tab = student != null && student.isArchived
          ? StudentTab.archive
          : StudentTab.all;
      final list = filterStudents(rows, tab: _tab);
      final at = list.indexWhere((s) => s.id == id);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (at >= 0 && _scroll.hasClients) {
          _scroll.jumpTo(
            (at * _rowExtent).clamp(0.0, _scroll.position.maxScrollExtent),
          );
        }
      });
    });
  }

  // --- Data -----------------------------------------------------------------

  List<StudentRow> _visible(List<StudentRow> rows) {
    final q = _search.text.trim().toLowerCase();
    final digits = q.replaceAll(RegExp(r'\D'), '');
    return [
      for (final s in filterStudents(
        rows,
        tab: _tab,
        subjectId: _subjectId,
        groupId: _groupId,
        teacherId: _teacherId,
      ))
        if (q.isEmpty ||
            s.fullName.toLowerCase().contains(q) ||
            (digits.isNotEmpty && s.phone.contains(digits)) ||
            s.groups.any((g) => g.name.toLowerCase().contains(q)))
          s,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<StudentRow>>(
      future: _rows,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadFailed(error: snapshot.error!, onRetry: reload);
        }
        final rows = snapshot.data;
        if (rows == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final counts = tabCounts(rows);
        final list = _visible(rows);
        final shown = list;
        // The profile follows the selection; with nothing chosen, the first row.
        final selected = list.any((s) => s.id == _selected)
            ? _selected
            : (shown.isEmpty ? null : shown.first.id);
        return Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _tabs(counts),
              const SizedBox(height: 14),
              _filters(rows),
              const SizedBox(height: 14),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: _table(shown, selected)),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 440,
                      child: selected == null
                          ? const _NothingSelected()
                          : StudentPanel(
                              key: ValueKey('panel-$selected'),
                              studentId: selected,
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

  Widget _tabs(Map<StudentTab, int> counts) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: <Widget>[
          for (final tab in StudentTab.values)
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
                    if (tab != StudentTab.archive) ...<Widget>[
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
              key: const ValueKey('new-student'),
              onPressed: showCreateSheet,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Yangi o\'quvchi'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filters(List<StudentRow> rows) {
    final groups = <int, StudentGroupRef>{};
    for (final s in rows) {
      for (final g in s.groups) {
        groups[g.groupId] = g;
      }
    }
    final subjects = <int, String>{
      for (final g in groups.values)
        if (g.subjectId != null) g.subjectId!: g.subjectName ?? '',
    };
    final teachers = <int, String>{
      for (final g in groups.values)
        if (g.teacherId != null) g.teacherId!: g.teacherName ?? '',
    };
    final any = _subjectId != null || _groupId != null || _teacherId != null;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 280,
          child: TextField(
            key: const ValueKey('students-search'),
            controller: _search,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: 'Ism, telefon yoki guruh',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        const SizedBox(width: 10),
        _FilterMenu(
          keyName: 'filter-subject',
          label: 'Fan',
          value: _subjectId == null ? null : subjects[_subjectId],
          options: subjects,
          onPick: (id) => setState(() {
            _subjectId = id;
          }),
        ),
        const SizedBox(width: 8),
        _FilterMenu(
          keyName: 'filter-group',
          label: 'Guruh',
          value: _groupId == null ? null : groups[_groupId]?.name,
          options: {for (final g in groups.values) g.groupId: g.name},
          onPick: (id) => setState(() {
            _groupId = id;
          }),
        ),
        const SizedBox(width: 8),
        _FilterMenu(
          keyName: 'filter-teacher',
          label: 'O\'qituvchi',
          value: _teacherId == null ? null : teachers[_teacherId],
          options: teachers,
          onPick: (id) => setState(() {
            _teacherId = id;
          }),
        ),
        if (any)
          TextButton(
            key: const ValueKey('filters-clear'),
            onPressed: () => setState(() {
              _subjectId = _groupId = _teacherId = null;
            }),
            child: const Text('Tozalash'),
          ),
      ],
    );
  }

  Widget _table(List<StudentRow> shown, int? selected) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          _TableHeader(showBranch: ref.watch(showBranchLabelsProvider)),
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
                    key: const ValueKey('students-list'),
                    controller: _scroll,
                    itemCount: shown.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, color: AppColors.divider),
                    itemBuilder: (context, i) => _StudentRowView(
                      key: ValueKey('student-${shown[i].id}'),
                      row: shown[i],
                      showBranch: ref.watch(showBranchLabelsProvider),
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
        'Profilni ko\'rish uchun o\'quvchini tanlang.',
        style: TextStyle(color: AppColors.inkMuted),
      ),
    );
  }
}

/// Fan / Guruh / O'qituvchi: "Fan  Hammasi" until one is picked.
class _FilterMenu extends StatelessWidget {
  const _FilterMenu({
    required this.keyName,
    required this.label,
    required this.value,
    required this.options,
    required this.onPick,
  });

  final String keyName;
  final String label;
  final String? value;
  final Map<int, String> options;
  final ValueChanged<int?> onPick;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      key: ValueKey(keyName),
      tooltip: label,
      onSelected: (id) => onPick(id == 0 ? null : id),
      itemBuilder: (_) => <PopupMenuEntry<int>>[
        const PopupMenuItem(value: 0, child: Text('Hammasi')),
        for (final e in options.entries)
          PopupMenuItem(value: e.key, child: Text(e.value)),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: value == null ? AppColors.surface : AppColors.accentSoft,
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(
            color: value == null ? AppColors.border : AppColors.accent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text(
              value ?? 'Hammasi',
              style: const TextStyle(color: AppColors.inkSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

const _head = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w600,
  color: AppColors.inkMuted,
);

/// The column weights: with every branch in view a "Filial" column is added
/// and the others give up a little room.
({int name, int group, int branch, int marks, int balance, int status}) _widths(
  bool showBranch,
) => showBranch
    ? (name: 28, group: 22, branch: 12, marks: 21, balance: 12, status: 16)
    : (name: 32, group: 27, branch: 0, marks: 21, balance: 12, status: 18);

class _TableHeader extends StatelessWidget {
  const _TableHeader({this.showBranch = false});

  final bool showBranch;

  @override
  Widget build(BuildContext context) {
    final w = _widths(showBranch);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: w.name,
            child: const Text('O\'quvchi', style: _head),
          ),
          Expanded(
            flex: w.group,
            child: const Text('Guruh va o\'qituvchi', style: _head),
          ),
          if (showBranch)
            Expanded(
              flex: w.branch,
              child: const Text('Filial', style: _head),
            ),
          Expanded(
            flex: w.marks,
            child: const Text('Davomat (10 dars)', style: _head),
          ),
          Expanded(
            flex: w.balance,
            child: const Text(
              'Balans',
              textAlign: TextAlign.right,
              style: _head,
            ),
          ),
          Expanded(
            flex: w.status,
            child: const Padding(
              padding: EdgeInsets.only(left: 14),
              child: Text('Holat', style: _head),
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentRowView extends StatelessWidget {
  const _StudentRowView({
    super.key,
    required this.row,
    required this.selected,
    required this.onTap,
    this.showBranch = false,
  });

  /// Say which branch(es) the student is in (every branch in view).
  final bool showBranch;
  final StudentRow row;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final w = _widths(showBranch);
    final status = statusOf(row);
    final first = row.groups.isEmpty ? null : row.groups.first;
    final balanceColor = row.balance > 0
        ? AppColors.dangerText
        : row.balance < 0
        ? AppColors.okText
        : AppColors.inkMuted;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? AppColors.accentSoft : null,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: w.name,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: <Widget>[
                    PersonAvatar(name: row.fullName, photo: row.photo),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  row.fullName,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (row.isNew) ...<Widget>[
                                const SizedBox(width: 6),
                                const StatusChip(
                                  'Yangi',
                                  tone: StatusTone.info,
                                ),
                              ],
                            ],
                          ),
                          Text(
                            PhoneFormatter.display(row.phone),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
            ),
            Expanded(
              flex: w.group,
              child: first == null
                  ? const Text(
                      'Guruhsiz',
                      style: TextStyle(color: AppColors.inkMuted),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          row.groups.length > 1
                              ? '${first.name} +${row.groups.length - 1}'
                              : first.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          groupSubtitle(first),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
            ),
            if (showBranch)
              Expanded(
                flex: w.branch,
                child: Text(
                  row.branches.join(', '),
                  key: ValueKey('student-branch-${row.id}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkSecondary,
                  ),
                ),
              ),
            Expanded(
              flex: w.marks,
              child: Row(
                children: <Widget>[
                  AttendanceBars(row.attendanceRecent),
                  const SizedBox(width: 8),
                  Text(
                    ratePercent(row.attendanceRate),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: w.balance,
              child: Text(
                signedBalance(row.balance),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: balanceColor,
                ),
              ),
            ),
            Expanded(
              flex: w.status,
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: status.hint,
                    child: StatusChip(status.text, tone: status.tone),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
