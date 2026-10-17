import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../../groups/data/groups_repository.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import '../data/qabul_repository.dart';
import 'admissions_ui.dart';
import 'qabul_text.dart';
import 'qabul_widgets.dart';

/// "O'quvchi qilish": the one step that makes a saved person a student --
/// a seat in the group, the first bill and (if asked) the first payment.
/// Returns a message to show once done, or null if cancelled.
Future<String?> showStudentDialog(
  BuildContext context, {
  required Lead lead,
  int? groupId,
}) {
  return showAdaptiveFormDialog<String>(
    context,
    maxWidth: 560,
    child: StudentDialog(lead: lead, groupId: groupId ?? lead.groupId),
  );
}

const _methods = <(String, String)>[
  ('cash', 'Naqd'),
  ('card', 'Karta'),
  ('click_payme', 'Click / Payme'),
];

class StudentDialog extends ConsumerStatefulWidget {
  const StudentDialog({super.key, required this.lead, this.groupId});

  final Lead lead;
  final int? groupId;

  @override
  ConsumerState<StudentDialog> createState() => _StudentDialogState();
}

class _StudentDialogState extends ConsumerState<StudentDialog> {
  /// One key per dialog: pressing twice, or resending after a lost answer,
  /// gives the first enrollment back instead of a second.
  final String _key = const Uuid().v4();
  late final AdmissionsRepository _repo = ref.read(
    admissionsRepositoryProvider,
  );
  late final Future<List<Group>> _groups = _repo.groups().then((groups) {
    final pick = widget.groupId;
    if (pick != null && groups.any((g) => g.id == pick)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickGroup(pick));
    }
    return groups;
  });

  int? _groupId;
  // 'today' | 'next' | 'custom'
  String _start = 'today';
  DateTime _customDate = DateTime.now();
  DateTime? _nextLesson;
  Future<FirstChargePreview>? _preview;
  bool _payNow = false;
  String _method = 'cash';
  bool _saving = false;
  String? _error;

  DateTime get _joinDate {
    final today = DateTime.now();
    return switch (_start) {
      'next' => _nextLesson ?? today,
      'custom' => _customDate,
      _ => today,
    };
  }

  void _pickGroup(int id) {
    if (!mounted) return;
    setState(() {
      _groupId = id;
      _start = 'today';
      _nextLesson = null;
    });
    _loadPreview();
    ref
        .read(qabulRepositoryProvider)
        .trialDates(id, count: 1)
        .then((dates) {
          if (mounted && _groupId == id && dates.isNotEmpty) {
            setState(() => _nextLesson = dates.first.startsAt);
          }
        })
        .catchError((_) {});
  }

  void _loadPreview() {
    final id = _groupId;
    if (id == null) return;
    setState(() {
      _preview = ref
          .read(enrollmentsRepositoryProvider)
          .previewFirstCharge(groupId: id, joinedAt: _joinDate);
    });
  }

  int _due(Group group, FirstChargePreview p) =>
      group.prorateFirstPeriod ? p.proratedAmount : p.fullAmount;

  Future<void> _confirm(Group group, FirstChargePreview preview) async {
    final lead = widget.lead;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final due = _due(group, preview);
      final result = await _repo.enrollLead(
        lead.id,
        idempotencyKey: _key,
        body: <String, dynamic>{
          'full_name': lead.fullName,
          'phone': lead.phone,
          'parent_phone': lead.parentPhone,
          'heard_from': lead.source,
          'note': lead.note,
          'group_id': group.id,
          'joined_at': apiDate(_joinDate),
          // The group's own rule decides how the first month is charged.
          if (_payNow && due > 0) ...<String, dynamic>{
            'first_payment_amount': due,
            'first_payment_method': _method,
          },
        },
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        '${result.studentName} guruhga yozildi · birinchi hisob ${CurrencyFormatter.format(result.firstCharge)}'
        '${result.reusedStudent ? ' (mavjud o\'quvchi)' : ''}',
      );
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Group>>(
      future: _groups,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const DialogHeader(title: 'O\'quvchi qilish'),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snapshot.error}'),
              ),
            ],
          );
        }
        final groups = snapshot.data;
        if (groups == null) {
          return const Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DialogHeader(title: 'O\'quvchi qilish'),
              Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              ),
            ],
          );
        }
        final group = groups.where((g) => g.id == _groupId).firstOrNull;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DialogHeader(
                title: 'O\'quvchi qilish',
                subtitle: [
                  widget.lead.fullName,
                  if (group != null) _title(group),
                ].join(' · '),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (group == null || widget.groupId == null)
                      _groupPicker(groups, group),
                    if (group != null) ...<Widget>[
                      _facts(group),
                      if (_isFull(group)) _fullNote(group),
                      const SizedBox(height: 18),
                      _startDate(group),
                      const SizedBox(height: 16),
                      _firstBill(group),
                      const SizedBox(height: 12),
                      _payNowRow(),
                    ],
                    const SizedBox(height: 14),
                    const InfoBox(
                      'Tasdiqlansa: o\'quvchi yaratiladi, guruhga qo\'shiladi, '
                      'birinchi hisob yaratiladi va ro\'yxatdan olib tashlanadi. '
                      'Hisob guruhning to\'lov qoidasi bo\'yicha avtomatik chiqadi.',
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: AppColors.dangerText),
                        ),
                      ),
                    const SizedBox(height: 16),
                    _buttons(group),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _title(Group g) => g.name;

  Widget _groupPicker(List<Group> groups, Group? group) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<int>(
        key: const ValueKey('student-group'),
        initialValue: group?.id,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Guruh'),
        items: <DropdownMenuItem<int>>[
          // The groups of the subject they asked for come first.
          for (final g in [
            ...groups.where((g) => g.subjectId == widget.lead.subjectId),
            ...groups.where((g) => g.subjectId != widget.lead.subjectId),
          ])
            DropdownMenuItem(
              value: g.id,
              child: Text(
                '${g.name}  ·  ${slotsLabel(g.schedule)}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) {
          if (v != null) _pickGroup(v);
        },
      ),
    );
  }

  Widget _facts(Group group) {
    Widget fact(String caption, String value, String? sub) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FieldCaption(caption),
        Text(
          value,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        if (sub != null)
          Text(
            sub,
            style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
          ),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(child: fact('Guruh', group.name, slotsLabel(group.schedule))),
        Expanded(
          child: fact(
            'Oylik narx',
            CurrencyFormatter.format(group.feeAmount),
            null,
          ),
        ),
      ],
    );
  }

  bool _isFull(Group g) =>
      g.capacity != null && (g.studentCount ?? 0) >= g.capacity!;

  /// A full group still takes the student: the count goes past the limit and
  /// the group stays full.
  Widget _fullNote(Group g) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Text(
      'Guruh to\'lgan (${g.studentCount}/${g.capacity}). Baribir qo\'shish mumkin: '
      'o\'quvchilar soni oshadi, guruh to\'lgan qoladi.',
      key: const ValueKey('student-full-note'),
      style: const TextStyle(color: AppColors.warnText),
    ),
  );

  Widget _startDate(Group group) {
    final today = DateTime.now();
    final next = _nextLesson;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FieldCaption('Boshlanish sanasi'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            OptionPill(
              'Bugun, ${today.day}-${dayMonth(today).split('-').last.substring(0, 3)}',
              selected: _start == 'today',
              onTap: () {
                setState(() => _start = 'today');
                _loadPreview();
              },
            ),
            if (next != null)
              OptionPill(
                'Keyingi dars, ${next.day}-${dayMonth(next).split('-').last.substring(0, 3)}',
                selected: _start == 'next',
                onTap: () {
                  setState(() => _start = 'next');
                  _loadPreview();
                },
              ),
            OptionPill(
              _start == 'custom'
                  ? '${_customDate.day}-${dayMonth(_customDate).split('-').last}'
                  : 'Sanani tanlash',
              selected: _start == 'custom',
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _customDate,
                  firstDate: DateTime.now().subtract(const Duration(days: 60)),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked == null || !mounted) return;
                setState(() {
                  _customDate = picked;
                  _start = 'custom';
                });
                _loadPreview();
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _firstBill(Group group) {
    return FutureBuilder<FirstChargePreview>(
      future: _preview,
      builder: (context, snapshot) {
        final p = snapshot.data;
        Widget body;
        if (snapshot.hasError) {
          body = Text(
            '${snapshot.error}',
            style: const TextStyle(color: AppColors.dangerText),
          );
        } else if (p == null) {
          body = const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        } else {
          final prorated = group.prorateFirstPeriod && p.isMidCycle;
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                prorated
                    ? '${dayMonth(_joinDate)}dan ${dayMonth(p.periodEnd)}gacha: '
                          '${p.daysLeft} / ${p.daysInPeriod} kun'
                    : group.isAnniversary
                    ? 'Har bir o\'quvchi guruhga qo\'shilgan kunida to\'laydi.'
                    : 'Birinchi oy to\'liq narxda.',
                style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
              ),
              const Divider(height: 22, color: AppColors.divider),
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'To\'lanishi kerak',
                      style: TextStyle(color: AppColors.inkSecondary),
                    ),
                  ),
                  Text(
                    CurrencyFormatter.format(_due(group, p)),
                    key: const ValueKey('student-due'),
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          );
        }
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Birinchi hisob',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.divider,
                      borderRadius: BorderRadius.circular(AppRadius.chip),
                    ),
                    child: Text(
                      'Guruh qoidasi: ${group.billingLabel.toLowerCase()}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.inkSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              body,
            ],
          ),
        );
      },
    );
  }

  Widget _payNowRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _payNow = !_payNow),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Checkbox(
                  key: const ValueKey('student-pay-now'),
                  value: _payNow,
                  onChanged: (v) => setState(() => _payNow = v ?? false),
                ),
                const Text('Birinchi to\'lovni hozir qabul qilish'),
              ],
            ),
          ),
        ),
        if (_payNow)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (value, label) in _methods)
                  OptionPill(
                    label,
                    selected: _method == value,
                    onTap: () => setState(() => _method = value),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buttons(Group? group) {
    return FutureBuilder<FirstChargePreview>(
      future: _preview,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            OutlinedButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Bekor qilish'),
            ),
            const SizedBox(width: 10),
            FilledButton(
              key: const ValueKey('student-confirm'),
              onPressed: _saving || group == null || preview == null
                  ? null
                  : () => _confirm(group, preview),
              child: const Text('O\'quvchi qilish'),
            ),
          ],
        );
      },
    );
  }
}
