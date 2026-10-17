import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/table_card.dart';
import '../../admissions/data/admissions_models.dart';
import '../../admissions/data/admissions_repository.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../groups/data/groups_repository.dart';
import '../../teachers/data/teachers_repository.dart';
import '../data/timetable_models.dart';
import '../data/timetable_repository.dart';
import 'attendance_sheet_dialog.dart';

/// "Jadval" (desktop): the week's lessons -- regular group lessons from
/// each group's weekly schedule, plus trial lessons -- with attendance
/// marked from here, and the attendance report.
class TimetableScreen extends ConsumerStatefulWidget {
  const TimetableScreen({super.key});

  @override
  ConsumerState<TimetableScreen> createState() => TimetableScreenState();
}

class TimetableScreenState extends ConsumerState<TimetableScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final _week = GlobalKey<_WeekViewState>();
  final _report = GlobalKey<_AttendanceReportViewState>();

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void reload() {
    _week.currentState?.reload();
    _report.currentState?.reload();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): reload,
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              decoration: BoxDecoration(
                color: context.colors.surface,
                border: Border(
                  bottom: BorderSide(color: context.colors.outlineVariant),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerHeight: 0,
                indicatorColor: AppColors.accent,
                indicatorWeight: 3,
                labelColor: context.colors.onSurface,
                unselectedLabelColor: context.colors.onSurfaceVariant,
                labelStyle: context.textTheme.labelLarge,
                tabs: const <Tab>[
                  Tab(text: 'Hafta'),
                  Tab(text: 'Davomat'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  _WeekView(key: _week),
                  _AttendanceReportView(key: _report),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

DateTime _mondayOf(DateTime day) {
  final date = DateUtils.dateOnly(day);
  return date.subtract(Duration(days: date.weekday - 1));
}

/// A week's lessons and trials, together.
typedef _Week = ({List<TimetableLesson> lessons, List<TrialSession> trials});

class _WeekView extends ConsumerStatefulWidget {
  const _WeekView({super.key});

  @override
  ConsumerState<_WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends ConsumerState<_WeekView> {
  DateTime _weekStart = _mondayOf(DateTime.now());
  int? _teacherId;
  int? _groupId;
  late Future<_Week> _data = _load();
  late final Future<List<Teacher>> _teachers = ref
      .read(teachersRepositoryProvider)
      .list();
  late final Future<List<Group>> _groups = ref
      .read(groupsRepositoryProvider)
      .list();

  void reload() {
    if (mounted) setState(() => _data = _load());
  }

  Future<_Week> _load() async {
    final end = _weekStart.add(const Duration(days: 6));
    final lessons = ref
        .read(timetableRepositoryProvider)
        .lessons(_weekStart, end, groupId: _groupId, teacherId: _teacherId);
    final trials = ref
        .read(admissionsRepositoryProvider)
        .listSessions(_weekStart, end);
    final allTrials = await trials;
    return (
      lessons: await lessons,
      // A group filter shows only that group's lessons; a teacher filter
      // shows that teacher's trials too.
      trials: _groupId != null
          ? allTrials.where((t) => t.groupId == _groupId).toList()
          : _teacherId != null
          ? allTrials.where((t) => t.teacherId == _teacherId).toList()
          : allTrials,
    );
  }

  void _shift(int weeks) {
    _weekStart = DateUtils.dateOnly(_weekStart.add(Duration(days: 7 * weeks)));
    reload();
  }

  Future<void> _open(TimetableLesson lesson) async {
    final changed = await showAttendanceSheet(context, lesson);
    if (changed == true) reload();
  }

  Future<void> _addExtra() async {
    final groups = await _groups;
    if (!mounted) return;
    final added = await _showExtraLessonDialog(context, ref, groups);
    if (added == true) reload();
  }

  @override
  Widget build(BuildContext context) {
    final weekEnd = _weekStart.add(const Duration(days: 6));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              IconButton.outlined(
                tooltip: 'Oldingi hafta',
                onPressed: () => _shift(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton.outlined(
                tooltip: 'Keyingi hafta',
                onPressed: () => _shift(1),
                icon: const Icon(Icons.chevron_right),
              ),
              OutlinedButton(
                onPressed: () {
                  _weekStart = _mondayOf(DateTime.now());
                  reload();
                },
                child: const Text('Bu hafta'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  DateFormatters.dateRangeLabel(_weekStart, weekEnd),
                  style: context.textTheme.titleMedium,
                ),
              ),
              SizedBox(
                width: 220,
                child: FutureBuilder<List<Teacher>>(
                  future: _teachers,
                  builder: (context, snapshot) => DropdownButtonFormField<int?>(
                    initialValue: _teacherId,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'O\'qituvchi',
                    ),
                    items: <DropdownMenuItem<int?>>[
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Hammasi'),
                      ),
                      for (final teacher in snapshot.data ?? const <Teacher>[])
                        if (teacher.isActive)
                          DropdownMenuItem(
                            value: teacher.id,
                            child: Text(teacher.fullName),
                          ),
                    ],
                    onChanged: (v) {
                      _teacherId = v;
                      reload();
                    },
                  ),
                ),
              ),
              SizedBox(
                width: 220,
                child: FutureBuilder<List<Group>>(
                  future: _groups,
                  builder: (context, snapshot) => DropdownButtonFormField<int?>(
                    initialValue: _groupId,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Guruh',
                    ),
                    items: <DropdownMenuItem<int?>>[
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Hammasi'),
                      ),
                      for (final group in snapshot.data ?? const <Group>[])
                        DropdownMenuItem(
                          value: group.id,
                          child: Text(group.name),
                        ),
                    ],
                    onChanged: (v) {
                      _groupId = v;
                      reload();
                    },
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _addExtra,
                icon: const Icon(Icons.add),
                label: const Text('Qo\'shimcha dars'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<_Week>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoadFailed(error: snapshot.error!, onRetry: reload);
                }
                final week = snapshot.data;
                if (week == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return _grid(week);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(_Week week) {
    final today = DateUtils.dateOnly(DateTime.now());
    final noSchedule = week.lessons.isEmpty && week.trials.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (noSchedule)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Bu haftada dars yo\'q. Guruhlarning dars jadvali Sozlamalar → '
              'Guruhlar bo\'limida kiritiladi.',
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: _DayColumn(
                    day: _weekStart.add(Duration(days: i)),
                    isToday: DateUtils.isSameDay(
                      _weekStart.add(Duration(days: i)),
                      today,
                    ),
                    lessons: week.lessons
                        .where(
                          (l) => DateUtils.isSameDay(
                            l.startsAt.toLocal(),
                            _weekStart.add(Duration(days: i)),
                          ),
                        )
                        .toList(),
                    trials: week.trials
                        .where(
                          (t) => DateUtils.isSameDay(
                            t.startsAt.toLocal(),
                            _weekStart.add(Duration(days: i)),
                          ),
                        )
                        .toList(),
                    last: i == 6,
                    onOpen: _open,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.isToday,
    required this.lessons,
    required this.trials,
    required this.last,
    required this.onOpen,
  });

  final DateTime day;
  final bool isToday;
  final List<TimetableLesson> lessons;
  final List<TrialSession> trials;
  final bool last;
  final ValueChanged<TimetableLesson> onOpen;

  @override
  Widget build(BuildContext context) {
    // Lessons and trials, in time order.
    final items = <(DateTime, Widget)>[
      for (final lesson in lessons)
        (
          lesson.startsAt,
          _LessonCard(lesson: lesson, onTap: () => onOpen(lesson)),
        ),
      for (final trial in trials) (trial.startsAt, _TrialCard(trial: trial)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return Container(
      margin: EdgeInsets.only(right: last ? 0 : 8),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isToday ? AppColors.accent : context.colors.outlineVariant,
          width: isToday ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              '${weekdayNames[day.weekday]}\n${day.day} ${DateFormatters.monthName(day).toLowerCase()}',
              style: context.textTheme.labelLarge?.copyWith(
                color: isToday ? AppColors.accent : null,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              primary: false,
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              children: <Widget>[for (final item in items) item.$2],
            ),
          ),
        ],
      ),
    );
  }
}

class _LessonCard extends StatelessWidget {
  const _LessonCard({required this.lesson, required this.onTap});

  final TimetableLesson lesson;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (String state, Color color) = lesson.isCancelled
        ? ('Bekor qilingan', AppColors.inkMuted)
        : lesson.isMarked
        ? (
            'Keldi: ${lesson.presentCount}/${lesson.markedCount}',
            AppColors.success,
          )
        : lesson.hasStarted
        ? ('Davomat belgilanmagan', AppColors.danger)
        : ('${lesson.studentCount} o\'quvchi', AppColors.inkMuted);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: lesson.isCancelled ? 0.55 : 1,
          child: Container(
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: color, width: 3)),
            ),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${DateFormatters.time(lesson.startsAt)}–${DateFormatters.time(lesson.endsAt)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  lesson.groupName + (lesson.isExtra ? ' (qo\'shimcha)' : ''),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  <String>[?lesson.teacherName, ?lesson.room].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  state,
                  style: context.textTheme.labelSmall?.copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A trial lesson, shown so rooms and teachers read true; it's managed in
/// Qabul.
class _TrialCard extends StatelessWidget {
  const _TrialCard({required this.trial});

  final TrialSession trial;

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFD97706);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: amber.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${DateFormatters.time(trial.startsAt)}–${DateFormatters.time(trial.endsAt)}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            'Sinov: ${trial.title}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.textTheme.bodySmall?.copyWith(color: amber),
          ),
          Text(
            <String>[
              ?trial.teacherName,
              ?trial.room,
              '${trial.booked}/${trial.capacity}',
            ].join(' · '),
            maxLines: 2,
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

Future<bool?> _showExtraLessonDialog(
  BuildContext context,
  WidgetRef ref,
  List<Group> groups,
) {
  int? groupId;
  var date = DateUtils.dateOnly(DateTime.now());
  var start = const TimeOfDay(hour: 14, minute: 0);
  var minutes = 90;
  final room = TextEditingController();
  final note = TextEditingController();
  String? error;
  var saving = false;
  return showAdaptiveFormDialog<bool>(
    context,
    child: StatefulBuilder(
      builder: (context, setState) {
        Future<void> save() async {
          if (saving) return;
          if (groupId == null) {
            setState(() => error = 'Guruhni tanlang.');
            return;
          }
          final startsAt = DateTime(
            date.year,
            date.month,
            date.day,
            start.hour,
            start.minute,
          );
          setState(() {
            saving = true;
            error = null;
          });
          try {
            await ref
                .read(timetableRepositoryProvider)
                .addExtra(
                  groupId: groupId!,
                  startsAt: startsAt,
                  endsAt: startsAt.add(Duration(minutes: minutes)),
                  room: room.text.trim().isEmpty ? null : room.text.trim(),
                  note: note.text.trim().isEmpty ? null : note.text.trim(),
                );
            if (context.mounted) Navigator.of(context).pop(true);
          } catch (e) {
            setState(() {
              error = e.toString();
              saving = false;
            });
          }
        }

        return SubmitShortcut(
          onSubmit: save,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const DialogHeader(
                title: 'Qo\'shimcha dars',
                subtitle:
                    'Jadvaldan tashqari: qoldirilgan dars o\'rniga, imtihon...',
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    DropdownButtonFormField<int>(
                      initialValue: groupId,
                      decoration: const InputDecoration(labelText: 'Guruh'),
                      items: <DropdownMenuItem<int>>[
                        for (final group in groups)
                          DropdownMenuItem(
                            value: group.id,
                            child: Text(group.name),
                          ),
                      ],
                      onChanged: (v) => setState(() => groupId = v),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: date,
                                firstDate: date.subtract(
                                  const Duration(days: 60),
                                ),
                                lastDate: date.add(const Duration(days: 120)),
                              );
                              if (picked != null) setState(() => date = picked);
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Sana',
                              ),
                              child: Text(DateFormatters.date(date)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: start,
                                builder: (context, child) => MediaQuery(
                                  data: MediaQuery.of(
                                    context,
                                  ).copyWith(alwaysUse24HourFormat: true),
                                  child: child!,
                                ),
                              );
                              if (picked != null) {
                                setState(() => start = picked);
                              }
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Boshlanishi',
                              ),
                              child: Text(hhmm(start)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: minutes,
                            decoration: const InputDecoration(
                              labelText: 'Davomiyligi',
                            ),
                            items: const <DropdownMenuItem<int>>[
                              DropdownMenuItem(
                                value: 45,
                                child: Text('45 daq'),
                              ),
                              DropdownMenuItem(
                                value: 60,
                                child: Text('60 daq'),
                              ),
                              DropdownMenuItem(
                                value: 90,
                                child: Text('90 daq'),
                              ),
                              DropdownMenuItem(
                                value: 120,
                                child: Text('120 daq'),
                              ),
                            ],
                            onChanged: (v) => setState(() => minutes = v ?? 90),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: room,
                      decoration: const InputDecoration(
                        labelText: 'Xona (ixtiyoriy)',
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: note,
                      decoration: const InputDecoration(
                        labelText: 'Izoh (ixtiyoriy)',
                      ),
                    ),
                    if (error != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        error!,
                        style: TextStyle(color: context.colors.error),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Bekor qilish'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: saving ? null : save,
                      child: const Text('Qo\'shish'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

enum _Period { thisWeek, thisMonth, lastMonth }

class _AttendanceReportView extends ConsumerStatefulWidget {
  const _AttendanceReportView({super.key});

  @override
  ConsumerState<_AttendanceReportView> createState() =>
      _AttendanceReportViewState();
}

class _AttendanceReportViewState extends ConsumerState<_AttendanceReportView> {
  _Period _period = _Period.thisMonth;
  int? _groupId;
  late Future<List<AttendanceReportRow>> _rows = _load();
  late final Future<List<Group>> _groups = ref
      .read(groupsRepositoryProvider)
      .list();

  DateTimeRange get _range {
    final today = DateUtils.dateOnly(DateTime.now());
    return switch (_period) {
      _Period.thisWeek => DateTimeRange(start: _mondayOf(today), end: today),
      _Period.lastMonth => DateTimeRange(
        start: DateTime(today.year, today.month - 1, 1),
        end: DateTime(today.year, today.month, 0),
      ),
      _Period.thisMonth => DateTimeRange(
        start: DateTime(today.year, today.month, 1),
        end: today,
      ),
    };
  }

  void reload() {
    if (mounted) setState(() => _rows = _load());
  }

  Future<List<AttendanceReportRow>> _load() => ref
      .read(timetableRepositoryProvider)
      .report(_range.start, _range.end, groupId: _groupId);

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodyMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (final (period, label) in <(_Period, String)>[
                (_Period.thisWeek, 'Bu hafta'),
                (_Period.thisMonth, 'Bu oy'),
                (_Period.lastMonth, 'O\'tgan oy'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _period == period,
                  onSelected: (_) {
                    _period = period;
                    reload();
                  },
                ),
              const SizedBox(width: 8),
              SizedBox(
                width: 240,
                child: FutureBuilder<List<Group>>(
                  future: _groups,
                  builder: (context, snapshot) => DropdownButtonFormField<int?>(
                    initialValue: _groupId,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Guruh',
                    ),
                    items: <DropdownMenuItem<int?>>[
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Hammasi'),
                      ),
                      for (final group in snapshot.data ?? const <Group>[])
                        DropdownMenuItem(
                          value: group.id,
                          child: Text(group.name),
                        ),
                    ],
                    onChanged: (v) {
                      _groupId = v;
                      reload();
                    },
                  ),
                ),
              ),
              Text(
                DateFormatters.dateRangeLabel(_range.start, _range.end),
                style: muted,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<List<AttendanceReportRow>>(
              future: _rows,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoadFailed(error: snapshot.error!, onRetry: reload);
                }
                final rows = snapshot.data;
                if (rows == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return TableCard(
                  emptyText: 'Bu davrda davomat belgilanmagan',
                  columns: const <TableColumn>[
                    TableColumn('O\'quvchi', flex: 3),
                    TableColumn('Guruh', flex: 2),
                    TableColumn('Darslar', alignEnd: true),
                    TableColumn('Keldi', alignEnd: true),
                    TableColumn('Kechikdi', alignEnd: true),
                    TableColumn('Kelmadi', alignEnd: true),
                    TableColumn('Sababli', alignEnd: true),
                    TableColumn('Davomat', alignEnd: true),
                  ],
                  rowCount: rows.length,
                  cell: (context, i, column) {
                    final row = rows[i];
                    final low = (row.rate ?? 1) < 0.7;
                    return switch (column) {
                      0 => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            row.fullName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            PhoneFormatter.display(row.phone),
                            style: context.textTheme.bodySmall,
                          ),
                        ],
                      ),
                      1 => Text(row.groupName, overflow: TextOverflow.ellipsis),
                      2 => Text('${row.lessons}'),
                      3 => Text('${row.present}'),
                      4 => Text('${row.late}'),
                      5 => Text(
                        '${row.absent}',
                        style: TextStyle(
                          color: row.absent > 0 ? AppColors.danger : null,
                          fontWeight: row.absent > 0 ? FontWeight.w600 : null,
                        ),
                      ),
                      6 => Text('${row.excused}'),
                      _ => Text(
                        percent(row.rate),
                        style: TextStyle(
                          color: low ? AppColors.danger : null,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    };
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
