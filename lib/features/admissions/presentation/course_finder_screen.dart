import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../core/widgets/uz_phone_field.dart';
import '../../../services/api/api_client.dart';
import '../../students/presentation/heard_from.dart';
import '../../subjects/data/subjects_repository.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import '../data/qabul_models.dart';
import '../data/qabul_repository.dart';
import 'admissions_ui.dart';
import 'after_trial_dialog.dart';
import 'qabul_text.dart';
import 'qabul_widgets.dart';
import 'trial_booking_dialog.dart';

/// "Kurs qidirish": a new client is on the phone -- find the group that fits
/// their subject, level, days and time, then book a trial or enroll them.
/// The client's details on the right are saved with what they asked for.
class CourseFinderScreen extends ConsumerStatefulWidget {
  const CourseFinderScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<CourseFinderScreen> createState() => _CourseFinderScreenState();
}

class _CourseFinderScreenState extends ConsumerState<CourseFinderScreen> {
  static const _quickPicks = <(String, Set<int>)>[
    ('Du · Chor · Ju', {1, 3, 5}),
    ('Se · Pay · Sha', {2, 4, 6}),
    ('Hafta oxiri', {6, 7}),
  ];
  static const _times = <(String?, String)>[
    (null, 'Farqi yo\'q'),
    ('morning', 'Ertalab'),
    ('afternoon', 'Kunduzi'),
    ('evening', 'Kechqurun'),
  ];

  late final QabulRepository _qabul = ref.read(qabulRepositoryProvider);
  late final Future<List<Subject>> _subjects = ref
      .read(admissionsRepositoryProvider)
      .subjects();

  int? _subjectId;
  String? _level;
  final Set<int> _days = {};
  String? _time;
  List<String> _levels = const [];

  Future<GroupSearchResult>? _results;

  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();
  String? _source;
  bool _busy = false;
  Lead? _lead;

  @override
  void initState() {
    super.initState();
    _subjects.then((subjects) {
      if (mounted && subjects.isNotEmpty && _subjectId == null) {
        _pickSubject(subjects.first.id);
      }
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  void _search() {
    setState(() {
      _results = _qabul.searchGroups(
        subjectId: _subjectId,
        level: _level,
        weekdays: _days,
        timeOfDay: _time,
      );
    });
    _results!.ignore();
  }

  Future<void> _pickSubject(int? id) async {
    setState(() {
      _subjectId = id;
      _level = null;
    });
    _search();
    final levels = await _qabul
        .levels(subjectId: id)
        .catchError((_) => <String>[]);
    if (mounted && _subjectId == id) setState(() => _levels = levels);
  }

  /// The inquiry for the client in the panel: made now, or the one already made.
  Future<Lead?> _ensureLead({bool silent = false}) async {
    if (_lead != null) return _lead;
    final name = _name.text.trim();
    final phone = UzPhoneField.toE164(_phone.text);
    if (name.isEmpty || _phone.text.trim().length < 9) {
      if (!silent) {
        showSnack(context, 'Avval mijoz ismi va telefonini kiriting.');
      }
      return null;
    }
    setState(() => _busy = true);
    try {
      final lead = await _qabul.saveInquiry(
        fullName: name,
        phone: phone,
        subjectId: _subjectId,
        source: _source,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        level: _level,
        weekdays: _days,
        timeOfDay: _time,
      );
      refreshAdmissions(ref);
      if (mounted) setState(() => _lead = lead);
      return lead;
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final lead = await _ensureLead();
    if (lead == null || !mounted) return;
    showSnack(
      context,
      lead.merged
          ? 'Bu raqamdagi ochiq so\'rovga qo\'shildi.'
          : 'So\'rov saqlandi.',
    );
    widget.onBack();
  }

  Future<void> _trial(GroupMatch group) async {
    final lead = await _ensureLead();
    if (lead == null || !mounted) return;
    final booked = await showTrialBookingDialog(
      context,
      lead: lead,
      groupId: group.groupId,
    );
    if (booked == true && mounted) {
      refreshAdmissions(ref);
      showSnack(context, '${lead.fullName} sinov darsiga yozildi.');
      widget.onBack();
    }
  }

  Future<void> _join(GroupMatch group) async {
    final lead = await _ensureLead();
    if (lead == null || !mounted) return;
    final message = await showAfterTrialDialog(
      context,
      lead: lead,
      groupId: group.groupId,
      afterTrial: false,
    );
    if (message != null && mounted) {
      refreshAdmissions(ref);
      showSnack(context, message);
      widget.onBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Kurs qidirish',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Yangi mijoz so\'raganda: fan, daraja va kunlar bo\'yicha mos guruhni toping',
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  ],
                ),
              ),
              OutlinedButton(
                onPressed: widget.onBack,
                child: const Text('Qabulga qaytish'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _filters(),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: _resultsList()),
              const SizedBox(width: 20),
              SizedBox(width: 340, child: _clientPanel()),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filters() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 40,
            runSpacing: 16,
            children: <Widget>[
              _labelled(
                'Fan',
                FutureBuilder<List<Subject>>(
                  future: _subjects,
                  builder: (context, snapshot) => Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final s in snapshot.data ?? const <Subject>[])
                        _Pill(
                          s.name,
                          selected: s.id == _subjectId,
                          onTap: () => _pickSubject(s.id),
                        ),
                    ],
                  ),
                ),
              ),
              if (_levels.isNotEmpty)
                _labelled(
                  'Daraja',
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final level in _levels)
                        _Pill(
                          level,
                          selected: level == _level,
                          onTap: () {
                            setState(
                              () => _level = _level == level ? null : level,
                            );
                            _search();
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 40,
            runSpacing: 16,
            children: <Widget>[
              _labelled(
                'Qaysi kunlari kela oladi',
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (var day = 1; day <= 7; day++)
                      _Pill(
                        weekdayAbbr[day],
                        selected: _days.contains(day),
                        onTap: () {
                          setState(
                            () => _days.contains(day)
                                ? _days.remove(day)
                                : _days.add(day),
                          );
                          _search();
                        },
                      ),
                  ],
                ),
              ),
              _labelled(
                'Tezkor tanlov',
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final (label, days) in _quickPicks)
                      _Pill(
                        label,
                        selected:
                            _days.length == days.length &&
                            _days.containsAll(days),
                        onTap: () {
                          setState(() {
                            _days
                              ..clear()
                              ..addAll(days);
                          });
                          _search();
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _labelled(
            'Vaqt',
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (key, label) in _times)
                  _Pill(
                    label,
                    selected: _time == key,
                    onTap: () {
                      setState(() => _time = key);
                      _search();
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _labelled(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[FieldCaption(label), child],
  );

  Widget _resultsList() {
    final future = _results;
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<GroupSearchResult>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) return Text('${snapshot.error}');
        final result = snapshot.data!;
        final now = DateTime.now();
        final all = [
          ...result.exact.map((g) => (g, true)),
          ...result.near.map((g) => (g, false)),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              all.isEmpty
                  ? 'Mos guruh topilmadi'
                  : 'Natija: ${result.exact.length} ta aniq moslik, ${result.near.length} ta yaqin variant',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            for (final (i, (group, exact)) in all.indexed) ...<Widget>[
              GroupResultCard(
                group: group,
                exact: exact,
                now: now,
                highlight: _days,
                primaryTrial: i == 0,
                onTrial: _busy ? null : () => _trial(group),
                onJoin: _busy || group.isFull ? null : () => _join(group),
              ),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }

  Widget _clientPanel() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Mijoz',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Ism'),
          ),
          const SizedBox(height: 12),
          UzPhoneField(controller: _phone, labelText: 'Telefon'),
          const SizedBox(height: 14),
          const FieldCaption('Manba'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final e in heardFromLabels.entries)
                _Pill(
                  e.value,
                  selected: _source == e.key,
                  onTap: () =>
                      setState(() => _source = _source == e.key ? null : e.key),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'Izoh',
              hintText: _days.isEmpty
                  ? null
                  : '${daysLabel(_days)} kunlari qulay',
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
            ),
            child: const Text('So\'rovni saqlash'),
          ),
          const SizedBox(height: 8),
          const Text(
            'Qidiruv shartlari so\'rov bilan birga saqlanadi.',
            style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.borderStrong,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.ink,
          ),
        ),
      ),
    );
  }
}

/// One group in the finder's results.
class GroupResultCard extends StatelessWidget {
  const GroupResultCard({
    super.key,
    required this.group,
    required this.exact,
    required this.now,
    required this.highlight,
    required this.primaryTrial,
    required this.onTrial,
    required this.onJoin,
  });

  final GroupMatch group;
  final bool exact;
  final DateTime now;

  /// The days the client can come -- the ones that match are drawn solid.
  final Set<int> highlight;
  final bool primaryTrial;
  final VoidCallback? onTrial;
  final VoidCallback? onJoin;

  @override
  Widget build(BuildContext context) {
    final fill = group.capacity == null || group.capacity == 0
        ? 0.0
        : group.enrolled / group.capacity!;
    final room = group.slots.map((s) => s.room).whereType<String>().firstOrNull;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      [?group.subjectName, group.name].join(', '),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      [?group.teacherName, ?room].join(' · '),
                      style: const TextStyle(color: AppColors.inkMuted),
                    ),
                  ],
                ),
              ),
              StatusChip(
                exact
                    ? 'Aniq mos: ${group.matchedDays} / ${group.totalDays} kun'
                    : 'Kunlari farq qiladi: ${group.matchedDays} / ${group.totalDays} kun',
                tone: exact ? StatusTone.ok : StatusTone.warning,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              for (var day = 1; day <= 7; day++) ...<Widget>[
                _DayChip(
                  weekdayAbbr[day],
                  inGroup: group.weekdays.contains(day),
                  wanted: highlight.contains(day),
                ),
                const SizedBox(width: 4),
              ],
              const SizedBox(width: 12),
              Text(
                firstTimeRange(group.slots),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          group.freeSeats == null
                              ? 'Joylar cheklanmagan'
                              : 'Bo\'sh o\'rin: ${group.freeSeats}',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: group.isFull
                                ? AppColors.dangerText
                                : AppColors.ink,
                          ),
                        ),
                        const Spacer(),
                        if (group.capacity != null)
                          Text(
                            '${group.enrolled} / ${group.capacity}',
                            style: const TextStyle(color: AppColors.inkMuted),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: fill.clamp(0, 1),
                        minHeight: 6,
                        backgroundColor: AppColors.divider,
                        color: group.isFull
                            ? AppColors.danger
                            : AppColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              Text(
                '${CurrencyFormatter.format(group.feeAmount)} / oy',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            billingNote(group, now),
            style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              primaryTrial
                  ? FilledButton(
                      onPressed: onTrial,
                      child: const Text('Sinov darsiga yozish'),
                    )
                  : OutlinedButton(
                      onPressed: onTrial,
                      child: const Text('Sinov darsiga yozish'),
                    ),
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: onJoin,
                child: Text(
                  group.isFull ? 'Guruh to\'lgan' : 'Guruhga qo\'shish',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip(this.label, {required this.inGroup, required this.wanted});

  final String label;
  final bool inGroup;

  /// A day the client can come.
  final bool wanted;

  @override
  Widget build(BuildContext context) {
    // Solid when the group meets that day (accent if the client can come
    // too); faint otherwise.
    final color = !inGroup
        ? AppColors.divider
        : (wanted ? AppColors.accent : AppColors.warnBg);
    final text = !inGroup
        ? AppColors.inkMuted
        : (wanted ? Colors.white : AppColors.warnText);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: text,
        ),
      ),
    );
  }
}
