import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../admissions/presentation/lead_action_dialogs.dart';
import '../../admissions/presentation/lead_details_panel.dart';
import '../data/timetable_models.dart';
import '../data/timetable_repository.dart';

/// One lesson's attendance. Keyboard: Tab / ↓ to move between students,
/// 1 Keldi · 2 Kechikdi · 3 Kelmadi · 4 Sababli (and on to the next),
/// Ctrl+Enter saves. Returns true if anything changed.
Future<bool?> showAttendanceSheet(
  BuildContext context,
  TimetableLesson lesson,
) {
  return showAdaptiveFormDialog<bool>(
    context,
    maxWidth: 720,
    child: _AttendanceSheet(lesson: lesson),
  );
}

Color attendanceColor(String status) => switch (status) {
  AttendanceStatus.present => AppColors.success,
  AttendanceStatus.late => const Color(0xFFD97706),
  AttendanceStatus.absent => AppColors.danger,
  _ => AppColors.inkMuted,
};

class _AttendanceSheet extends ConsumerStatefulWidget {
  const _AttendanceSheet({required this.lesson});

  final TimetableLesson lesson;

  @override
  ConsumerState<_AttendanceSheet> createState() => _AttendanceSheetState();
}

class _AttendanceSheetState extends ConsumerState<_AttendanceSheet> {
  static final _keys = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.digit1: AttendanceStatus.present,
    LogicalKeyboardKey.digit2: AttendanceStatus.late,
    LogicalKeyboardKey.digit3: AttendanceStatus.absent,
    LogicalKeyboardKey.digit4: AttendanceStatus.excused,
    LogicalKeyboardKey.numpad1: AttendanceStatus.present,
    LogicalKeyboardKey.numpad2: AttendanceStatus.late,
    LogicalKeyboardKey.numpad3: AttendanceStatus.absent,
    LogicalKeyboardKey.numpad4: AttendanceStatus.excused,
  };

  AttendanceSheet? _sheet;
  Object? _loadError;

  /// What's on screen, including unsaved changes.
  final Map<int, String> _status = <int, String>{};

  /// As last saved, to send only what changed.
  final Map<int, String> _saved = <int, String>{};
  bool _busy = false;
  bool _changed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sheet = await ref
          .read(timetableRepositoryProvider)
          .sheet(widget.lesson.groupId, widget.lesson.startsAt);
      if (!mounted) return;
      setState(() {
        _apply(sheet);
        _loadError = null;
      });
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  void _apply(AttendanceSheet sheet) {
    _sheet = sheet;
    _status.clear();
    _saved.clear();
    for (final student in sheet.students) {
      if (student.status != null) {
        _status[student.enrollmentId] = student.status!;
        _saved[student.enrollmentId] = student.status!;
      }
    }
  }

  Map<int, String> get _unsaved => <int, String>{
    for (final entry in _status.entries)
      if (_saved[entry.key] != entry.value) entry.key: entry.value,
  };

  void _allPresent() {
    setState(() {
      for (final student in _sheet!.students) {
        _status.putIfAbsent(
          student.enrollmentId,
          () => AttendanceStatus.present,
        );
      }
    });
  }

  Future<void> _save() async {
    final changes = _unsaved;
    if (_busy || changes.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sheet = await ref
          .read(timetableRepositoryProvider)
          .mark(widget.lesson.groupId, widget.lesson.startsAt, changes);
      if (!mounted) return;
      setState(() {
        _apply(sheet);
        _changed = true;
      });
      showSnack(context, 'Davomat saqlandi');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelOrRestore() async {
    final lesson = _sheet!.lesson;
    final repo = ref.read(timetableRepositoryProvider);
    if (lesson.isCancelled) {
      await repo.restore(lesson.groupId, lesson.startsAt);
    } else {
      final done = await showReasonDialog(
        context,
        title: 'Darsni bekor qilish',
        subtitle: '${lesson.groupName} · ${shortDateTime(lesson.startsAt)}',
        action: 'Bekor qilish',
        onConfirm: (reason) =>
            repo.cancel(lesson.groupId, lesson.startsAt, reason: reason),
      );
      if (done != true) return;
    }
    _changed = true;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    final lesson = sheet?.lesson ?? widget.lesson;
    final canMark = lesson.hasStarted && !lesson.isCancelled;
    return SubmitShortcut(
      onSubmit: _save,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.of(context).pop(_changed);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DialogHeader(
              title:
                  '${lesson.groupName} · ${shortDateTime(lesson.startsAt)}–${DateFormatters.time(lesson.endsAt)}',
              subtitle: <String>[
                lesson.teacherName ?? 'O\'qituvchi tanlanmagan',
                ?lesson.room,
                if (lesson.isExtra) 'qo\'shimcha dars',
              ].join(' · '),
              onClose: () => Navigator.of(context).pop(_changed),
            ),
            if (lesson.isCancelled)
              _Notice(
                color: context.colors.error,
                text:
                    'Dars bekor qilingan${lesson.cancelReason == null ? '' : ': ${lesson.cancelReason}'}',
              )
            else if (!lesson.hasStarted)
              _Notice(
                color: context.colors.onSurfaceVariant,
                text: 'Davomat dars boshlangandan keyin belgilanadi.',
              ),
            Flexible(child: _body(sheet, canMark)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.colors.error),
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 24, 16),
              child: Row(
                children: <Widget>[
                  if (sheet != null && !lesson.isMarked)
                    TextButton.icon(
                      onPressed: _busy ? null : _cancelOrRestore,
                      icon: Icon(
                        lesson.isCancelled
                            ? Icons.event_available_rounded
                            : Icons.event_busy_rounded,
                      ),
                      label: Text(
                        lesson.isCancelled
                            ? 'Darsni tiklash'
                            : 'Darsni bekor qilish',
                      ),
                    ),
                  const Spacer(),
                  if (canMark && sheet != null) ...<Widget>[
                    Text(
                      '1 Keldi · 2 Kechikdi · 3 Kelmadi · 4 Sababli',
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed: _busy ? null : _allPresent,
                      child: const Text('Qolganlar keldi'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _busy || _unsaved.isEmpty ? null : _save,
                      child: Text(
                        _unsaved.isEmpty
                            ? 'Saqlangan'
                            : 'Saqlash (${_unsaved.length})',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(AttendanceSheet? sheet, bool canMark) {
    if (_loadError != null) {
      return LoadFailed(error: _loadError!, onRetry: _load);
    }
    if (sheet == null) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      children: <Widget>[
        if (sheet.students.isEmpty)
          const EmptyNote('Bu kuni guruhda o\'quvchi yo\'q'),
        for (final (i, student) in sheet.students.indexed)
          _StudentRow(
            student: student,
            status: _status[student.enrollmentId],
            enabled: canMark && !_busy,
            autofocus: i == 0 && canMark,
            onChanged: (status) =>
                setState(() => _status[student.enrollmentId] = status),
            keys: _keys,
          ),
        if (sheet.trialGuests.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
            child: Text(
              'Sinov darsiga kelganlar (davomati sinovda belgilanadi)',
              style: context.textTheme.titleSmall,
            ),
          ),
          for (final guest in sheet.trialGuests)
            ListTile(
              dense: true,
              title: Text(guest.fullName),
              trailing: TrialStatusChip(guest.status),
              onTap: () => showLeadDetails(context, leadId: guest.leadId),
            ),
        ],
      ],
    );
  }
}

class _StudentRow extends StatelessWidget {
  const _StudentRow({
    required this.student,
    required this.status,
    required this.enabled,
    required this.autofocus,
    required this.onChanged,
    required this.keys,
  });

  final SheetStudent student;
  final String? status;
  final bool enabled;
  final bool autofocus;
  final ValueChanged<String> onChanged;
  final Map<LogicalKeyboardKey, String> keys;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: autofocus,
      canRequestFocus: enabled,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final picked = keys[event.logicalKey];
        if (picked != null) {
          onChanged(picked);
          node.nextFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          node.nextFocus();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          node.previousFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: focused ? context.colors.primaryContainer : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 6,
                  height: 32,
                  decoration: BoxDecoration(
                    color: status == null
                        ? context.colors.outlineVariant
                        : attendanceColor(status!),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        student.fullName,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        PhoneFormatter.display(student.phone),
                        style: context.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SegmentedButton<String>(
                  emptySelectionAllowed: true,
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: <ButtonSegment<String>>[
                    for (final value in AttendanceStatus.all)
                      ButtonSegment(
                        value: value,
                        label: Text(AttendanceStatus.labels[value]!),
                      ),
                  ],
                  selected: <String>{?status},
                  onSelectionChanged: enabled
                      ? (selection) {
                          if (selection.isNotEmpty) onChanged(selection.first);
                        }
                      : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Text(
        text,
        style: context.textTheme.bodyMedium?.copyWith(color: color),
      ),
    );
  }
}
