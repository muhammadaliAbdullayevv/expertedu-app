import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../groups/data/groups_repository.dart';
import '../../subjects/data/subjects_repository.dart';
import '../../teachers/data/teachers_repository.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';

/// Books [lead] into a trial lesson -- or, with [rescheduling], moves that
/// booking to another time (the old one is kept as "Ko'chirildi"). Either
/// an existing session with a free seat, or a new one: a dedicated trial
/// lesson, or guest seats at a regular group's lesson. Nobody is enrolled
/// or charged. Returns true once saved (or queued offline).
Future<bool?> showScheduleTrialDialog(
  BuildContext context, {
  required Lead lead,
  TrialBooking? rescheduling,
}) {
  return showAdaptiveFormDialog<bool>(
    context,
    maxWidth: 620,
    child: _ScheduleTrialForm(lead: lead, rescheduling: rescheduling),
  );
}

class _ScheduleTrialForm extends ConsumerStatefulWidget {
  const _ScheduleTrialForm({required this.lead, this.rescheduling});

  final Lead lead;
  final TrialBooking? rescheduling;

  @override
  ConsumerState<_ScheduleTrialForm> createState() => _ScheduleTrialFormState();
}

enum _Mode { existing, create }

class _ScheduleTrialFormState extends ConsumerState<_ScheduleTrialForm> {
  static const List<int> _durations = <int>[45, 60, 90, 120];

  late final AdmissionsRepository _repo = ref.read(
    admissionsRepositoryProvider,
  );
  late final Future<List<TrialSession>> _sessions = _repo.listSessions(
    DateTime.now(),
    DateTime.now().add(const Duration(days: 21)),
  );
  late final Future<List<Teacher>> _teachers = _repo.teachers();
  late final Future<List<Group>> _groups = _repo.groups();
  late final Future<List<Subject>> _subjects = _repo.subjects();

  _Mode _mode = _Mode.existing;
  int? _sessionId;
  bool _allSubjects = false;

  String _kind = 'dedicated';
  int? _subjectId;
  Group? _group;
  int? _teacherId;
  DateTime _date = DateUtils.dateOnly(
    DateTime.now().add(const Duration(days: 1)),
  );
  TimeOfDay _time = const TimeOfDay(hour: 10, minute: 0);
  int _duration = 60;
  final _room = TextEditingController();
  final _capacity = TextEditingController(text: '5');
  final _reason = TextEditingController();

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subjectId = widget.lead.subjectId;
    // A lead made offline can't have sessions looked up for it reliably;
    // a new time always works.
    if (widget.lead.isPending) _mode = _Mode.create;
  }

  @override
  void dispose() {
    _room.dispose();
    _capacity.dispose();
    _reason.dispose();
    super.dispose();
  }

  DateTime get _startsAt =>
      DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);

  List<TrialSession> _bookable(List<TrialSession> sessions) {
    return sessions.where((s) {
      if (s.status != 'scheduled' || s.hasStarted || s.isFull) return false;
      if (s.id == widget.rescheduling?.sessionId) return false;
      if (s.bookings.any(
        (b) => b.leadId == widget.lead.id && b.status == TrialStatus.scheduled,
      )) {
        return false;
      }
      return _allSubjects ||
          widget.lead.subjectId == null ||
          s.subjectId == widget.lead.subjectId;
    }).toList();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _error = null);

    NewTrialSession? session;
    int? sessionId;
    if (_mode == _Mode.existing) {
      sessionId = _sessionId;
      if (sessionId == null) {
        setState(() => _error = 'Darsni tanlang yoki yangi vaqt kiriting.');
        return;
      }
    } else {
      final capacity = int.tryParse(_capacity.text.trim());
      if (capacity == null || capacity < 1 || capacity > 100) {
        setState(() => _error = 'Joylar soni 1 dan 100 gacha bo\'lsin.');
        return;
      }
      if (_kind == 'group_lesson' && _group == null) {
        setState(() => _error = 'Guruhni tanlang.');
        return;
      }
      if (!_startsAt.isAfter(DateTime.now())) {
        setState(() => _error = 'Bu vaqt o\'tib ketgan.');
        return;
      }
      final room = _room.text.trim();
      session = NewTrialSession(
        kind: _kind,
        subjectId: _kind == 'group_lesson' ? _group!.subjectId : _subjectId,
        groupId: _kind == 'group_lesson' ? _group!.id : null,
        teacherId: _teacherId,
        room: room.isEmpty ? null : room,
        startsAt: _startsAt,
        endsAt: _startsAt.add(Duration(minutes: _duration)),
        capacity: capacity,
      );
    }

    setState(() => _saving = true);
    try {
      final booking = widget.rescheduling;
      var queued = false;
      if (booking != null) {
        await _repo.reschedule(
          booking.id,
          sessionId: sessionId,
          session: session,
          reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
        );
      } else {
        final outcome = await _repo.bookTrial(
          widget.lead,
          sessionId: sessionId,
          session: session,
        );
        queued = outcome.queued;
      }
      if (!mounted) return;
      refreshAdmissions(ref);
      if (queued) {
        showSnack(context, 'Oflayn saqlandi — internet qaytganda yuboriladi.');
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rescheduling = widget.rescheduling != null;
    return SubmitShortcut(
      onSubmit: _save,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DialogHeader(
            title: rescheduling
                ? 'Sinovni ko\'chirish'
                : 'Sinov darsiga yozish',
            subtitle:
                '${widget.lead.fullName} · guruhga qo\'shilmaydi, to\'lov olinmaydi',
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SegmentedButton<_Mode>(
                    segments: const <ButtonSegment<_Mode>>[
                      ButtonSegment(
                        value: _Mode.existing,
                        icon: Icon(Icons.event_available_rounded),
                        label: Text('Mavjud dars'),
                      ),
                      ButtonSegment(
                        value: _Mode.create,
                        icon: Icon(Icons.add_rounded),
                        label: Text('Yangi vaqt'),
                      ),
                    ],
                    selected: <_Mode>{_mode},
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                  ),
                  const SizedBox(height: 16),
                  if (_mode == _Mode.existing)
                    _existingSessions()
                  else
                    _newSessionFields(),
                  if (rescheduling) ...<Widget>[
                    const SizedBox(height: 14),
                    TextField(
                      controller: _reason,
                      decoration: const InputDecoration(
                        labelText: 'Sabab (ixtiyoriy)',
                      ),
                    ),
                  ],
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 14),
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
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(rescheduling ? 'Ko\'chirish' : 'Yozish'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _existingSessions() {
    return FutureBuilder<List<TrialSession>>(
      future: _sessions,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Text('Darslarni yuklab bo\'lmadi: ${snapshot.error}');
        }
        final sessions = _bookable(snapshot.data!);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.lead.subjectId != null)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _allSubjects,
                onChanged: (v) => setState(() => _allSubjects = v ?? false),
                title: const Text('Boshqa fanlar darslarini ham ko\'rsatish'),
              ),
            if (sessions.isEmpty)
              EmptyNote(
                'Keyingi 3 haftada bo\'sh joyli sinov darsi yo\'q.\n'
                '"Yangi vaqt" orqali qo\'shing.',
              )
            else
              RadioGroup<int>(
                groupValue: _sessionId,
                onChanged: (id) => setState(() => _sessionId = id),
                child: Column(
                  children: <Widget>[
                    for (final session in sessions)
                      RadioListTile<int>(
                        value: session.id,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${shortDateTime(session.startsAt)}–'
                          '${DateFormatters.time(session.endsAt)} · ${session.title}',
                        ),
                        subtitle: Text(
                          <String>[
                            session.teacherName ?? 'O\'qituvchi tanlanmagan',
                            if (session.room != null) session.room!,
                            'joy: ${session.booked}/${session.capacity}',
                          ].join(' · '),
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

  Widget _newSessionFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment(
              value: 'dedicated',
              label: Text('Alohida sinov darsi'),
            ),
            ButtonSegment(
              value: 'group_lesson',
              label: Text('Guruh darsiga mehmon'),
            ),
          ],
          selected: <String>{_kind},
          onSelectionChanged: (s) => setState(() {
            _kind = s.first;
            _capacity.text = _kind == 'group_lesson' ? '2' : '5';
          }),
        ),
        const SizedBox(height: 14),
        if (_kind == 'group_lesson') _groupPicker() else _subjectPicker(),
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            Expanded(
              child: _pickerField(
                label: 'Sana',
                icon: Icons.calendar_today_outlined,
                text: DateFormatters.date(_date),
                onTap: () async {
                  final today = DateUtils.dateOnly(DateTime.now());
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _date.isBefore(today) ? today : _date,
                    firstDate: today,
                    lastDate: today.add(const Duration(days: 120)),
                  );
                  if (picked != null) setState(() => _date = picked);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _pickerField(
                label: 'Boshlanishi',
                icon: Icons.schedule_rounded,
                text:
                    '${_time.hour.toString().padLeft(2, '0')}:${_time.minute.toString().padLeft(2, '0')}',
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: _time,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(alwaysUse24HourFormat: true),
                      child: child!,
                    ),
                  );
                  if (picked != null) setState(() => _time = picked);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: _duration,
                decoration: const InputDecoration(labelText: 'Davomiyligi'),
                items: <DropdownMenuItem<int>>[
                  for (final minutes in _durations)
                    DropdownMenuItem(
                      value: minutes,
                      child: Text('$minutes daq'),
                    ),
                ],
                onChanged: (v) => setState(() => _duration = v ?? 60),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            Expanded(flex: 2, child: _teacherPicker()),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _room,
                decoration: const InputDecoration(labelText: 'Xona'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _capacity,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                decoration: const InputDecoration(labelText: 'Joylar'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Server o\'qituvchi, xona va guruh bandligini tekshiradi.',
          style: context.textTheme.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _pickerField({
    required String label,
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          suffixIcon: Icon(icon, size: 20),
        ),
        child: Text(text),
      ),
    );
  }

  Widget _subjectPicker() {
    return FutureBuilder<List<Subject>>(
      future: _subjects,
      builder: (context, snapshot) {
        final subjects = snapshot.data ?? const <Subject>[];
        return DropdownButtonFormField<int?>(
          initialValue: subjects.any((s) => s.id == _subjectId)
              ? _subjectId
              : null,
          decoration: const InputDecoration(labelText: 'Fan'),
          items: <DropdownMenuItem<int?>>[
            const DropdownMenuItem(value: null, child: Text('Tanlanmagan')),
            for (final subject in subjects)
              DropdownMenuItem(value: subject.id, child: Text(subject.name)),
          ],
          onChanged: (v) => setState(() => _subjectId = v),
        );
      },
    );
  }

  Widget _groupPicker() {
    return FutureBuilder<List<Group>>(
      future: _groups,
      builder: (context, snapshot) {
        final groups = [...?snapshot.data]
          ..sort((a, b) => a.name.compareTo(b.name));
        return DropdownButtonFormField<int?>(
          initialValue: _group?.id,
          decoration: const InputDecoration(
            labelText: 'Guruh',
            helperText: 'Mehmon sifatida darsga keladi — guruhga yozilmaydi',
          ),
          items: <DropdownMenuItem<int?>>[
            for (final group in groups)
              DropdownMenuItem(
                value: group.id,
                child: Text(
                  '${group.name} · ${group.teacherName ?? 'o\'qituvchisiz'}',
                ),
              ),
          ],
          onChanged: (id) => setState(() {
            _group = groups.firstWhere((g) => g.id == id);
            _teacherId = _group!.teacherId;
          }),
        );
      },
    );
  }

  Widget _teacherPicker() {
    return FutureBuilder<List<Teacher>>(
      future: _teachers,
      builder: (context, snapshot) {
        final teachers = (snapshot.data ?? const <Teacher>[])
            .where((t) => t.isActive)
            .toList();
        return DropdownButtonFormField<int?>(
          // Rebuilt when a group fills it in.
          key: ValueKey<int?>(_teacherId),
          initialValue: teachers.any((t) => t.id == _teacherId)
              ? _teacherId
              : null,
          decoration: const InputDecoration(labelText: 'O\'qituvchi'),
          items: <DropdownMenuItem<int?>>[
            const DropdownMenuItem(value: null, child: Text('Tanlanmagan')),
            for (final teacher in teachers)
              DropdownMenuItem(
                value: teacher.id,
                child: Text(teacher.fullName),
              ),
          ],
          onChanged: (v) => setState(() => _teacherId = v),
        );
      },
    );
  }
}
