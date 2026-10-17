import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../services/api/api_client.dart';
import '../../groups/data/groups_repository.dart';
import '../../timetable/data/timetable_models.dart';
import '../../timetable/data/timetable_repository.dart';
import 'admissions_ui.dart';
import 'qabul_text.dart';
import 'qabul_widgets.dart';

/// "Guruh jadvallari": every active group on one screen -- its days, its
/// start and end time and its seat limit -- so a center that starts with empty
/// schedules can fill them all in at once.
Future<void> showGroupSchedulesDialog(BuildContext context) =>
    showAdaptiveFormDialog<void>(
      context,
      maxWidth: 980,
      child: const GroupSchedulesDialog(),
    );

/// "09:00", "9:00" or "0900" -> 09:00; null when it is not a time.
TimeOfDay? parseClock(String text) {
  final t = text.trim();
  final m = RegExp(r'^(\d{1,2})[:.]?(\d{2})$').firstMatch(t);
  if (m == null) return null;
  final h = int.parse(m[1]!);
  final min = int.parse(m[2]!);
  if (h > 23 || min > 59) return null;
  return TimeOfDay(hour: h, minute: min);
}

class _Row {
  _Row(this.group)
    : days = {for (final s in group.schedule) s.weekday},
      start = TextEditingController(),
      end = TextEditingController(),
      capacity = TextEditingController(text: '${group.capacity ?? ''}') {
    final times = {for (final s in group.schedule) hhmm(s.startsAt)};
    final ends = {for (final s in group.schedule) hhmm(s.endsAt)};
    // Mixed times per day are edited in Guruhlar; here only one time for all days.
    mixed = times.length > 1 || ends.length > 1;
    if (!mixed && group.schedule.isNotEmpty) {
      start.text = times.single;
      end.text = ends.single;
    }
    initialDays = {...days};
    initialStart = start.text;
    initialEnd = end.text;
    initialCapacity = capacity.text;
  }

  final Group group;
  final Set<int> days;
  final TextEditingController start;
  final TextEditingController end;
  final TextEditingController capacity;
  bool mixed = false;
  late final Set<int> initialDays;
  late final String initialStart;
  late final String initialEnd;
  late final String initialCapacity;
  String? error;
  bool saved = false;

  bool get scheduleChanged =>
      !mixed &&
      (days.length != initialDays.length ||
          !days.containsAll(initialDays) ||
          start.text != initialStart ||
          end.text != initialEnd);

  bool get capacityChanged => capacity.text.trim() != initialCapacity;

  bool get changed => scheduleChanged || capacityChanged;

  void dispose() {
    start.dispose();
    end.dispose();
    capacity.dispose();
  }
}

class GroupSchedulesDialog extends ConsumerStatefulWidget {
  const GroupSchedulesDialog({super.key});

  @override
  ConsumerState<GroupSchedulesDialog> createState() =>
      _GroupSchedulesDialogState();
}

class _GroupSchedulesDialogState extends ConsumerState<GroupSchedulesDialog> {
  late final Future<List<_Row>> _rows = ref
      .read(groupsRepositoryProvider)
      .list()
      .then((groups) => [for (final g in groups) _Row(g)]);
  List<_Row> _loaded = const [];
  bool _saving = false;
  String? _message;

  @override
  void dispose() {
    for (final r in _loaded) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _saveAll(List<_Row> rows) async {
    setState(() {
      _saving = true;
      _message = null;
    });
    final groups = ref.read(groupsRepositoryProvider);
    final timetable = ref.read(timetableRepositoryProvider);
    var done = 0;
    for (final row in rows.where((r) => r.changed)) {
      row.error = null;
      try {
        if (row.scheduleChanged) {
          final start = parseClock(row.start.text);
          final end = parseClock(row.end.text);
          if (row.days.isNotEmpty && (start == null || end == null)) {
            throw ApiException(400, 'Vaqtni 09:00 ko\'rinishida kiriting.');
          }
          await timetable.setSchedule(row.group.id, [
            if (start != null && end != null)
              for (final d in (row.days.toList()..sort()))
                ScheduleSlot(weekday: d, startsAt: start, endsAt: end),
          ]);
        }
        if (row.capacityChanged) {
          final text = row.capacity.text.trim();
          final value = text.isEmpty ? null : int.tryParse(text);
          if (text.isNotEmpty && (value == null || value < 1)) {
            throw ApiException(400, 'O\'rinlar soni butun son bo\'lsin.');
          }
          final g = row.group;
          await groups.update(
            g.id,
            subjectId: g.subjectId ?? 0,
            name: g.name,
            teacherId: g.teacherId,
            feeAmount: g.feeAmount,
            billingMode: g.billingMode,
            billingDay: g.billingDay,
            prorateFirstPeriod: g.prorateFirstPeriod,
            capacity: value,
            note: g.note,
          );
        }
        row.saved = true;
        done++;
      } on ApiException catch (e) {
        row.error = e.message;
      }
    }
    if (!mounted) return;
    final failed = rows.where((r) => r.error != null).length;
    setState(() {
      _saving = false;
      _message = failed == 0
          ? '$done ta guruh saqlandi.'
          : '$done ta saqlandi, $failed tasida xato bor.';
    });
    if (failed == 0 && done > 0 && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_Row>>(
      future: _rows,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const DialogHeader(title: 'Guruh jadvallari'),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snapshot.error}'),
              ),
            ],
          );
        }
        final rows = snapshot.data;
        if (rows == null) {
          return const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DialogHeader(title: 'Guruh jadvallari'),
              Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              ),
            ],
          );
        }
        _loaded = rows;
        final changed = rows.where((r) => r.changed).length;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const DialogHeader(
              title: 'Guruh jadvallari',
              subtitle:
                  'Kunlar, boshlanish va tugash vaqti, o\'rinlar soni. '
                  'Bo\'sh qoldirilgan o\'rinlar soni — cheklanmagan.',
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                itemCount: rows.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: AppColors.divider),
                itemBuilder: (context, i) => _GroupEditor(
                  key: ValueKey('schedule-${rows[i].group.id}'),
                  row: rows[i],
                  onChanged: () => setState(() {}),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      _message ?? '',
                      style: const TextStyle(color: AppColors.inkMuted),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Yopish'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    key: const ValueKey('save-schedules'),
                    onPressed: _saving || changed == 0
                        ? null
                        : () => _saveAll(rows),
                    child: Text(
                      changed == 0
                          ? 'Hammasini saqlash'
                          : 'Hammasini saqlash ($changed)',
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _GroupEditor extends StatelessWidget {
  const _GroupEditor({super.key, required this.row, required this.onChanged});

  final _Row row;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final g = row.group;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 210,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  g.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  g.teacherName ?? 'O\'qituvchi yo\'q',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkMuted,
                  ),
                ),
                if (row.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      row.error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.dangerText,
                      ),
                    ),
                  ),
                if (row.saved && row.error == null && !row.changed)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Saqlandi',
                      style: TextStyle(fontSize: 12, color: AppColors.okText),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: row.mixed
                ? const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text(
                      'Kunlari turli vaqtda — Guruhlar bo\'limida o\'zgartiring.',
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  )
                : Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (var d = 1; d <= 7; d++)
                        OptionPill(
                          weekdayAbbr[d],
                          key: ValueKey('day-${g.id}-$d'),
                          focusable: false,
                          selected: row.days.contains(d),
                          onTap: () {
                            if (!row.days.remove(d)) row.days.add(d);
                            onChanged();
                          },
                        ),
                    ],
                  ),
          ),
          const SizedBox(width: 12),
          _timeField('start-${g.id}', row.start, 'Boshlanishi', row),
          const SizedBox(width: 8),
          _timeField('end-${g.id}', row.end, 'Tugashi', row),
          const SizedBox(width: 8),
          SizedBox(
            width: 92,
            child: TextField(
              key: ValueKey('capacity-${g.id}'),
              controller: row.capacity,
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'O\'rinlar',
              ),
              onChanged: (_) => onChanged(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeField(
    String key,
    TextEditingController controller,
    String label,
    _Row row,
  ) {
    return SizedBox(
      width: 100,
      child: TextField(
        key: ValueKey(key),
        controller: controller,
        enabled: !row.mixed,
        keyboardType: TextInputType.datetime,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9:.]')),
          LengthLimitingTextInputFormatter(5),
        ],
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          hintText: '09:00',
        ),
        onChanged: (_) => onChanged(),
      ),
    );
  }
}
