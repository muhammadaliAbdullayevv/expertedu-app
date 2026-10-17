import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../groups/data/groups_repository.dart';
import '../data/timetable_models.dart';
import '../data/timetable_repository.dart';

/// Edits a group's weekly lesson slots. The server refuses a teacher or
/// room that another group has at the same time. Returns true once saved.
Future<bool?> showGroupScheduleDialog(BuildContext context, Group group) {
  return showAdaptiveFormDialog<bool>(
    context,
    maxWidth: 640,
    child: _GroupScheduleForm(group: group),
  );
}

class _Row {
  _Row({
    required this.weekday,
    required this.start,
    required this.end,
    String? room,
  }) : room = TextEditingController(text: room ?? '');

  int weekday;
  TimeOfDay start;
  TimeOfDay end;
  final TextEditingController room;
}

class _GroupScheduleForm extends ConsumerStatefulWidget {
  const _GroupScheduleForm({required this.group});

  final Group group;

  @override
  ConsumerState<_GroupScheduleForm> createState() => _GroupScheduleFormState();
}

class _GroupScheduleFormState extends ConsumerState<_GroupScheduleForm> {
  late final List<_Row> _rows = <_Row>[
    for (final slot in widget.group.schedule)
      _Row(
        weekday: slot.weekday,
        start: slot.startsAt,
        end: slot.endsAt,
        room: slot.room,
      ),
  ];
  bool _saving = false;
  String? _error;

  static const _presets = <String, List<int>>{
    'Du, Cho, Ju': <int>[1, 3, 5],
    'Se, Pa, Sha': <int>[2, 4, 6],
    'Har kuni (Du-Ju)': <int>[1, 2, 3, 4, 5],
  };

  @override
  void dispose() {
    for (final row in _rows) {
      row.room.dispose();
    }
    super.dispose();
  }

  _Row get _template => _rows.isNotEmpty
      ? _rows.last
      : _Row(
          weekday: 1,
          start: const TimeOfDay(hour: 14, minute: 0),
          end: const TimeOfDay(hour: 15, minute: 30),
        );

  void _add() {
    final last = _template;
    setState(
      () => _rows.add(
        _Row(
          weekday: _rows.isEmpty ? 1 : (last.weekday % 7) + 1,
          start: last.start,
          end: last.end,
          room: last.room.text,
        ),
      ),
    );
  }

  /// Replaces the rows with the preset days at the current time and room.
  void _applyPreset(List<int> days) {
    final template = _template;
    final room = template.room.text;
    setState(() {
      for (final row in _rows) {
        row.room.dispose();
      }
      _rows
        ..clear()
        ..addAll(<_Row>[
          for (final day in days)
            _Row(
              weekday: day,
              start: template.start,
              end: template.end,
              room: room,
            ),
        ]);
    });
  }

  Future<TimeOfDay?> _pickTime(TimeOfDay initial) => showTimePicker(
    context: context,
    initialTime: initial,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(timetableRepositoryProvider).setSchedule(
        widget.group.id,
        <ScheduleSlot>[
          for (final row in _rows)
            ScheduleSlot(
              weekday: row.weekday,
              startsAt: row.start,
              endsAt: row.end,
              room: row.room.text.trim().isEmpty ? null : row.room.text.trim(),
            ),
        ],
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SubmitShortcut(
      onSubmit: _save,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DialogHeader(
            title: 'Dars jadvali · ${widget.group.name}',
            subtitle:
                'O\'qituvchi: ${widget.group.teacherName ?? 'tanlanmagan'} · '
                'o\'zgarish faqat kelgusi darslarga ta\'sir qiladi',
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final entry in _presets.entries)
                        ActionChip(
                          label: Text(entry.key),
                          onPressed: () => _applyPreset(entry.value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_rows.isEmpty) const EmptyNote('Hali dars kunlari yo\'q'),
                  for (final (i, row) in _rows.indexed)
                    Padding(
                      // Keeps each row's dropdown with its row when one
                      // above it is removed.
                      key: ObjectKey(row),
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            flex: 3,
                            child: DropdownButtonFormField<int>(
                              initialValue: row.weekday,
                              decoration: const InputDecoration(
                                labelText: 'Kun',
                                isDense: true,
                              ),
                              items: <DropdownMenuItem<int>>[
                                for (var d = 1; d <= 7; d++)
                                  DropdownMenuItem(
                                    value: d,
                                    child: Text(weekdayNames[d]),
                                  ),
                              ],
                              onChanged: (v) => setState(
                                () => row.weekday = v ?? row.weekday,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: _TimeField(
                              label: 'Boshlanishi',
                              value: row.start,
                              onTap: () async {
                                final t = await _pickTime(row.start);
                                if (t != null) setState(() => row.start = t);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: _TimeField(
                              label: 'Tugashi',
                              value: row.end,
                              onTap: () async {
                                final t = await _pickTime(row.end);
                                if (t != null) setState(() => row.end = t);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: row.room,
                              decoration: const InputDecoration(
                                labelText: 'Xona',
                                isDense: true,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Olib tashlash',
                            onPressed: () => setState(() {
                              _rows.removeAt(i).room.dispose();
                            }),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _add,
                      icon: const Icon(Icons.add),
                      label: const Text('Dars kuni qo\'shish'),
                    ),
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: TextStyle(color: context.colors.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Bekor qilish'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: const Text('Saqlash'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final TimeOfDay value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, isDense: true),
        child: Text(hhmm(value)),
      ),
    );
  }
}
