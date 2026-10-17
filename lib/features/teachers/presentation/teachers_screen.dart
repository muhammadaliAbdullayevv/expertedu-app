import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/table_card.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/data/groups_repository.dart';
import '../../timetable/data/timetable_models.dart';
import '../data/teachers_repository.dart';
import 'teacher_form_dialog.dart';

enum _TeacherStatusFilter { active, inactive, all }

enum _TeacherAction { profile, edit, toggleActive }

enum _ProfileAction { edit, toggleActive, finance }

typedef _TeacherDirectory = ({List<Teacher> teachers, List<Group> groups});

/// Desktop directory for the center's teaching team.
class TeachersScreen extends ConsumerStatefulWidget {
  const TeachersScreen({super.key, this.onOpenFinance});

  final VoidCallback? onOpenFinance;

  @override
  ConsumerState<TeachersScreen> createState() => TeachersScreenState();
}

class TeachersScreenState extends ConsumerState<TeachersScreen> {
  final _searchController = TextEditingController();
  late Future<_TeacherDirectory> _future = _load();
  String _query = '';
  int? _subjectId;
  _TeacherStatusFilter _status = _TeacherStatusFilter.active;

  Future<_TeacherDirectory> _load() async {
    final results = await Future.wait<Object>(<Future<Object>>[
      ref.read(teachersRepositoryProvider).list(includeInactive: true),
      ref.read(groupsRepositoryProvider).list(includeInactive: true),
    ]);
    return (
      teachers: results[0] as List<Teacher>,
      groups: results[1] as List<Group>,
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void reload() {
    setState(() => _future = _load());
  }

  Future<void> _openForm([Teacher? teacher]) async {
    final saved = await showTeacherFormDialog(context, teacher: teacher);
    if (saved == true && mounted) reload();
  }

  List<Group> _assignedGroups(Teacher teacher, List<Group> groups) =>
      groups.where((group) => group.teacherId == teacher.id).toList()
        ..sort((a, b) {
          if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

  List<Teacher> _filterTeachers(_TeacherDirectory directory) {
    final query = _query.trim().toLowerCase();
    return directory.teachers.where((teacher) {
      if (_status == _TeacherStatusFilter.active && !teacher.isActive) {
        return false;
      }
      if (_status == _TeacherStatusFilter.inactive && teacher.isActive) {
        return false;
      }

      final assigned = _assignedGroups(teacher, directory.groups);
      if (_subjectId != null &&
          !assigned.any((group) => group.subjectId == _subjectId)) {
        return false;
      }
      if (query.isEmpty) return true;
      final fields = <String>[
        teacher.fullName,
        teacher.phone ?? '',
        teacher.note ?? '',
        for (final group in assigned) ...<String>[
          group.name,
          group.subjectName ?? '',
        ],
      ];
      return fields.any((field) => field.toLowerCase().contains(query));
    }).toList();
  }

  Future<void> _openProfile(Teacher teacher, List<Group> groups) async {
    final assigned = _assignedGroups(teacher, groups);
    final isOwner = ref.read(sessionControllerProvider).isOwner;
    final action = await showDialog<_ProfileAction>(
      context: context,
      builder: (dialogContext) => _TeacherProfileDialog(
        teacher: teacher,
        groups: assigned,
        canOpenFinance: isOwner && widget.onOpenFinance != null,
        onEdit: () => Navigator.of(dialogContext).pop(_ProfileAction.edit),
        onToggleActive: () =>
            Navigator.of(dialogContext).pop(_ProfileAction.toggleActive),
        onOpenFinance: () =>
            Navigator.of(dialogContext).pop(_ProfileAction.finance),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _ProfileAction.edit:
        await _openForm(teacher);
      case _ProfileAction.toggleActive:
        await _changeStatus(teacher, groups);
      case _ProfileAction.finance:
        widget.onOpenFinance?.call();
      case null:
        break;
    }
  }

  Future<void> _changeStatus(Teacher teacher, List<Group> allGroups) async {
    final activeGroups = allGroups
        .where((group) => group.isActive && group.teacherId == teacher.id)
        .toList();
    if (teacher.isActive && activeGroups.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.groups_2_outlined),
          title: const Text('Guruhlarni avval qayta biriktiring'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${teacher.fullName} quyidagi faol guruhlarga biriktirilgan. '
                  'O\'qituvchini faolsizlantirishdan oldin har bir guruhni '
                  'boshqa o\'qituvchiga o\'tkazing.',
                ),
                const SizedBox(height: 12),
                for (final group in activeGroups.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.groups_outlined, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            group.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (group.subjectName != null)
                          Text(
                            group.subjectName!,
                            style: Theme.of(dialogContext).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    dialogContext,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                if (activeGroups.length > 6)
                  Text('Yana ${activeGroups.length - 6} ta guruh'),
              ],
            ),
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Tushunarli'),
            ),
          ],
        ),
      );
      return;
    }

    final nextActive = !teacher.isActive;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          nextActive
              ? 'O\'qituvchini faollashtirasizmi?'
              : 'O\'qituvchini faolsizlantirasizmi?',
        ),
        content: Text(
          nextActive
              ? '${teacher.fullName} yana faol o\'qituvchilar ro\'yxatiga '
                    'qo\'shiladi.'
              : '${teacher.fullName} ro\'yxatdan yashiriladi. Oldingi '
                    'guruh va dars tarixi saqlanib qoladi.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Bekor qilish'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(nextActive ? 'Faollashtirish' : 'Faolsizlantirish'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;

    try {
      await ref
          .read(teachersRepositoryProvider)
          .setActive(teacher.id, nextActive);
      if (!mounted) return;
      reload();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nextActive
                ? 'O\'qituvchi faollashtirildi'
                : 'O\'qituvchi faolsizlantirildi',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Holatni saqlab bo\'lmadi: $error')),
      );
    }
  }

  void _onAction(_TeacherAction action, Teacher teacher, List<Group> groups) {
    switch (action) {
      case _TeacherAction.profile:
        _openProfile(teacher, groups);
      case _TeacherAction.edit:
        _openForm(teacher);
      case _TeacherAction.toggleActive:
        _changeStatus(teacher, groups);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_TeacherDirectory>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _TeachersLoadFailed(error: snapshot.error!, onRetry: reload);
        }

        final directory = snapshot.data!;
        final teachers = _filterTeachers(directory);
        final activeTeachers = directory.teachers
            .where((teacher) => teacher.isActive)
            .toList();
        final activeGroups = directory.groups
            .where((group) => group.isActive)
            .toList();
        final activeTeacherIds = activeTeachers
            .map((teacher) => teacher.id)
            .toSet();
        final groupsNeedingTeacher = activeGroups.where((group) {
          final teacherId = group.teacherId;
          return teacherId == null || !activeTeacherIds.contains(teacherId);
        }).length;
        final missingPhones = activeTeachers
            .where((teacher) => teacher.phone?.trim().isNotEmpty != true)
            .length;
        final subjects = <int, String>{};
        for (final group in directory.groups) {
          final id = group.subjectId;
          final name = group.subjectName;
          if (id != null && name != null && name.trim().isNotEmpty) {
            subjects[id] = name;
          }
        }
        final subjectOptions = subjects.entries.toList()
          ..sort(
            (a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()),
          );
        final selectedSubject = subjects.containsKey(_subjectId)
            ? _subjectId
            : null;

        return LayoutBuilder(
          builder: (context, constraints) {
            final side = math.max(24.0, (constraints.maxWidth - 1440) / 2);
            final metricWidth = math.min(
              320.0,
              math.max(210.0, (constraints.maxWidth - 36) / 4),
            );
            final searchWidth = math.min(380.0, constraints.maxWidth * .42);
            return Padding(
              padding: EdgeInsets.fromLTRB(side, 22, side, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'O\'qituvchilar',
                              style: context.textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Jamoa, guruh taqsimoti va aloqa ma\'lumotlari',
                              style: context.textTheme.bodyMedium?.copyWith(
                                color: context.colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      FilledButton.icon(
                        onPressed: () => _openForm(),
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: const Text('O\'qituvchi qo\'shish'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      SizedBox(
                        width: metricWidth,
                        child: _TeacherMetric(
                          icon: Icons.co_present_rounded,
                          label: 'Faol o\'qituvchilar',
                          value: '${activeTeachers.length}',
                          tint: AppColors.accent,
                        ),
                      ),
                      SizedBox(
                        width: metricWidth,
                        child: _TeacherMetric(
                          icon: Icons.groups_rounded,
                          label: 'Faol guruhlar',
                          value: '${activeGroups.length}',
                          tint: const Color(0xFF0F766E),
                        ),
                      ),
                      SizedBox(
                        width: metricWidth,
                        child: _TeacherMetric(
                          icon: Icons.person_off_outlined,
                          label: 'O\'qituvchini tekshirish kerak',
                          value: '$groupsNeedingTeacher',
                          tooltip:
                              'O\'qituvchisiz yoki nofaol o\'qituvchiga '
                              'biriktirilgan faol guruhlar',
                          tint: groupsNeedingTeacher == 0
                              ? const Color(0xFF0F766E)
                              : const Color(0xFFD97706),
                        ),
                      ),
                      SizedBox(
                        width: metricWidth,
                        child: _TeacherMetric(
                          icon: Icons.phone_missed_outlined,
                          label: 'Telefon kiritilmagan',
                          value: '$missingPhones',
                          tint: missingPhones == 0
                              ? const Color(0xFF0F766E)
                              : const Color(0xFFD97706),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      SizedBox(
                        width: searchWidth,
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) => setState(() => _query = value),
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: const Icon(Icons.search_rounded),
                            hintText: 'Ism, telefon, fan yoki guruh',
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Qidiruvni tozalash',
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _query = '');
                                    },
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: math.min(250.0, constraints.maxWidth * .28),
                        child: DropdownButtonFormField<int?>(
                          initialValue: selectedSubject,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            labelText: 'Fan',
                            prefixIcon: Icon(Icons.menu_book_outlined),
                          ),
                          items: <DropdownMenuItem<int?>>[
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('Barcha fanlar'),
                            ),
                            for (final subject in subjectOptions)
                              DropdownMenuItem<int?>(
                                value: subject.key,
                                child: Text(
                                  subject.value,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) =>
                              setState(() => _subjectId = value),
                        ),
                      ),
                      SegmentedButton<_TeacherStatusFilter>(
                        showSelectedIcon: false,
                        segments: const <ButtonSegment<_TeacherStatusFilter>>[
                          ButtonSegment(
                            value: _TeacherStatusFilter.active,
                            label: Text('Faol'),
                          ),
                          ButtonSegment(
                            value: _TeacherStatusFilter.inactive,
                            label: Text('Nofaol'),
                          ),
                          ButtonSegment(
                            value: _TeacherStatusFilter.all,
                            label: Text('Barchasi'),
                          ),
                        ],
                        selected: <_TeacherStatusFilter>{_status},
                        onSelectionChanged: (selection) =>
                            setState(() => _status = selection.first),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Text(
                        '${teachers.length} ta ko\'rsatilmoqda',
                        style: context.textTheme.labelLarge?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      if (directory.teachers.any(
                        (teacher) => !teacher.isActive,
                      ))
                        Text(
                          '${directory.teachers.where((teacher) => !teacher.isActive).length} ta nofaol',
                          style: context.textTheme.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TableCard(
                      columns: const <TableColumn>[
                        TableColumn('O\'qituvchi', flex: 3),
                        TableColumn('Fanlar', flex: 2),
                        TableColumn('Biriktirilgan guruhlar', flex: 4),
                        TableColumn('Telefon', flex: 2),
                        TableColumn('Holat', flex: 1),
                        TableColumn('', width: 52),
                      ],
                      rowCount: teachers.length,
                      emptyText: directory.teachers.isEmpty
                          ? 'Hali o\'qituvchilar yo\'q. Jamoaga o\'qituvchi qo\'shing.'
                          : 'Bu qidiruv va filtrlarga mos o\'qituvchi topilmadi.',
                      onRowTap: (row) =>
                          _openProfile(teachers[row], directory.groups),
                      cell: (context, row, column) {
                        final teacher = teachers[row];
                        final assigned = _assignedGroups(
                          teacher,
                          directory.groups,
                        );
                        return switch (column) {
                          0 => _TeacherNameCell(teacher: teacher),
                          1 => _SubjectCell(groups: assigned),
                          2 => _GroupCell(teacher: teacher, groups: assigned),
                          3 => _TeacherPhoneCell(teacher: teacher),
                          4 => _TeacherStatusBadge(isActive: teacher.isActive),
                          _ => PopupMenuButton<_TeacherAction>(
                            tooltip: 'O\'qituvchi amallari',
                            onSelected: (action) =>
                                _onAction(action, teacher, directory.groups),
                            itemBuilder: (context) =>
                                <PopupMenuEntry<_TeacherAction>>[
                                  const PopupMenuItem<_TeacherAction>(
                                    value: _TeacherAction.profile,
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(
                                        Icons.person_outline_rounded,
                                      ),
                                      title: Text('Profilni ochish'),
                                    ),
                                  ),
                                  const PopupMenuItem<_TeacherAction>(
                                    value: _TeacherAction.edit,
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(Icons.edit_outlined),
                                      title: Text('Tahrirlash'),
                                    ),
                                  ),
                                  PopupMenuItem<_TeacherAction>(
                                    value: _TeacherAction.toggleActive,
                                    child: ListTile(
                                      dense: true,
                                      leading: Icon(
                                        teacher.isActive
                                            ? Icons.person_off_outlined
                                            : Icons.person_add_alt_1_outlined,
                                      ),
                                      title: Text(
                                        teacher.isActive
                                            ? 'Faolsizlantirish'
                                            : 'Faollashtirish',
                                      ),
                                    ),
                                  ),
                                ],
                            child: const Icon(Icons.more_horiz_rounded),
                          ),
                        };
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _TeacherMetric extends StatelessWidget {
  const _TeacherMetric({
    required this.icon,
    required this.label,
    required this.value,
    required this.tint,
    this.tooltip,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color tint;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.colors.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 19,
            backgroundColor: tint.withValues(alpha: .1),
            foregroundColor: tint,
            child: Icon(icon, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  value,
                  style: context.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return tooltip == null ? card : Tooltip(message: tooltip!, child: card);
  }
}

class _TeacherNameCell extends StatelessWidget {
  const _TeacherNameCell({required this.teacher});

  final Teacher teacher;

  @override
  Widget build(BuildContext context) {
    final initial = teacher.fullName.trim().isEmpty
        ? '?'
        : teacher.fullName.trim()[0].toUpperCase();
    return Row(
      children: <Widget>[
        CircleAvatar(
          radius: 18,
          backgroundColor: context.colors.primaryContainer,
          foregroundColor: context.colors.primary,
          child: Text(
            initial,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            teacher.fullName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: teacher.isActive
                  ? context.colors.onSurface
                  : context.colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _SubjectCell extends StatelessWidget {
  const _SubjectCell({required this.groups});

  final List<Group> groups;

  @override
  Widget build(BuildContext context) {
    final names = <String>{
      for (final group in groups)
        if (group.subjectName != null) group.subjectName!,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (names.isEmpty) {
      return Text(
        'Fan biriktirilmagan',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      );
    }
    return Tooltip(
      message: names.join('\n'),
      child: Text(
        names.join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _GroupCell extends StatelessWidget {
  const _GroupCell({required this.teacher, required this.groups});

  final Teacher teacher;
  final List<Group> groups;

  @override
  Widget build(BuildContext context) {
    final visible = teacher.isActive
        ? groups.where((group) => group.isActive).toList()
        : groups;
    if (visible.isEmpty) {
      return Text(
        'Guruh biriktirilmagan',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.textTheme.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      );
    }
    final activeCount = groups.where((group) => group.isActive).length;
    final reportedCount = teacher.groupCount;
    final countMismatch = reportedCount != null && reportedCount != activeCount;
    final names = visible.map((group) => group.name).toList();
    return Tooltip(
      message: <String>[
        for (final group in visible)
          '${group.name}${group.isActive ? '' : ' · nofaol'}',
      ].join('\n'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            names.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          if (countMismatch)
            Row(
              children: <Widget>[
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: Color(0xFFB45309),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Guruhlar: $activeCount · hisob: $reportedCount',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFB45309),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            )
          else
            Text(
              teacher.isActive
                  ? '$activeCount ta faol guruh'
                  : '${groups.length} ta guruh tarixi',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

class _TeacherPhoneCell extends StatelessWidget {
  const _TeacherPhoneCell({required this.teacher});

  final Teacher teacher;

  @override
  Widget build(BuildContext context) {
    final phone = teacher.phone?.trim();
    if (phone == null || phone.isEmpty) {
      return Row(
        children: <Widget>[
          Icon(
            Icons.warning_amber_rounded,
            size: 17,
            color: const Color(0xFFD97706),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Kiritilmagan',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(
                color: const Color(0xFFB45309),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );
    }
    return Text(
      PhoneFormatter.display(phone),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: context.textTheme.bodyMedium,
    );
  }
}

class _TeacherStatusBadge extends StatelessWidget {
  const _TeacherStatusBadge({required this.isActive});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.success : AppColors.inkMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Text(
        isActive ? 'Faol' : 'Nofaol',
        maxLines: 1,
        style: context.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TeachersLoadFailed extends StatelessWidget {
  const _TeachersLoadFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: context.colors.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'O\'qituvchilar ma\'lumotini yuklab bo\'lmadi',
              style: context.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Qayta urinish'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TeacherProfileDialog extends StatelessWidget {
  const _TeacherProfileDialog({
    required this.teacher,
    required this.groups,
    required this.canOpenFinance,
    required this.onEdit,
    required this.onToggleActive,
    required this.onOpenFinance,
  });

  final Teacher teacher;
  final List<Group> groups;
  final bool canOpenFinance;
  final VoidCallback onEdit;
  final VoidCallback onToggleActive;
  final VoidCallback onOpenFinance;

  @override
  Widget build(BuildContext context) {
    final activeGroups = groups.where((group) => group.isActive).length;
    final subjects = <String>{
      for (final group in groups)
        if (group.subjectName != null) group.subjectName!,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final phone = teacher.phone?.trim();
    final note = teacher.note?.trim();

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: context.colors.primaryContainer,
                    foregroundColor: context.colors.primary,
                    child: Text(
                      teacher.fullName.trim().isEmpty
                          ? '?'
                          : teacher.fullName.trim()[0].toUpperCase(),
                      style: context.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          teacher.fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 5),
                        _TeacherStatusBadge(isActive: teacher.isActive),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Yopish',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: _ProfileFact(
                            icon: Icons.phone_outlined,
                            label: 'Telefon',
                            value: phone == null || phone.isEmpty
                                ? 'Kiritilmagan'
                                : PhoneFormatter.display(phone),
                            attention: phone == null || phone.isEmpty,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _ProfileFact(
                            icon: Icons.groups_outlined,
                            label: 'Faol guruhlar',
                            value: '$activeGroups',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _ProfileFact(
                      icon: Icons.menu_book_outlined,
                      label: 'Fanlar',
                      value: subjects.isEmpty
                          ? 'Hali biriktirilmagan'
                          : subjects.join(' · '),
                    ),
                    if (note != null && note.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 18),
                      Text('Izoh', style: context.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      Text(note, style: context.textTheme.bodyMedium),
                    ],
                    const SizedBox(height: 22),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            'Guruhlar va dars jadvali',
                            style: context.textTheme.titleMedium,
                          ),
                        ),
                        Text(
                          '${groups.length} ta',
                          style: context.textTheme.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (groups.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: context.colors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: context.colors.outlineVariant,
                          ),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              Icons.group_add_outlined,
                              color: context.colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Bu o\'qituvchiga hozircha guruh biriktirilmagan.',
                                style: context.textTheme.bodyMedium?.copyWith(
                                  color: context.colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      for (final group in groups) ...<Widget>[
                        _ProfileGroupCard(group: group),
                        const SizedBox(height: 8),
                      ],
                  ],
                ),
              ),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (canOpenFinance)
                    TextButton.icon(
                      onPressed: onOpenFinance,
                      icon: const Icon(Icons.account_balance_wallet_outlined),
                      label: const Text('Oyliklar'),
                    ),
                  OutlinedButton.icon(
                    onPressed: onToggleActive,
                    icon: Icon(
                      teacher.isActive
                          ? Icons.person_off_outlined
                          : Icons.person_add_alt_1_outlined,
                    ),
                    label: Text(
                      teacher.isActive ? 'Faolsizlantirish' : 'Faollashtirish',
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Tahrirlash'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileFact extends StatelessWidget {
  const _ProfileFact({
    required this.icon,
    required this.label,
    required this.value,
    this.attention = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool attention;

  @override
  Widget build(BuildContext context) {
    final tint = attention ? const Color(0xFFB45309) : context.colors.primary;
    return Container(
      constraints: const BoxConstraints(minHeight: 78),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.colors.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: tint, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  label,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: attention ? tint : context.colors.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileGroupCard extends StatelessWidget {
  const _ProfileGroupCard({required this.group});

  final Group group;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.colors.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 17,
            backgroundColor: context.colors.primaryContainer,
            foregroundColor: context.colors.primary,
            child: const Icon(Icons.groups_2_outlined, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (!group.isActive) ...<Widget>[
                      const SizedBox(width: 8),
                      const _TeacherStatusBadge(isActive: false),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  <String>[
                    if (group.subjectName != null) group.subjectName!,
                    group.schedule.isEmpty
                        ? 'Jadval yo\'q'
                        : scheduleSummary(group.schedule),
                    if (group.studentCount != null)
                      '${group.studentCount} o\'quvchi',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
