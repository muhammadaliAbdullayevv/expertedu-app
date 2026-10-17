import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/data/qabul_models.dart';
import '../../admissions/data/qabul_repository.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../admissions/presentation/qabul_form.dart'
    show GroupRow, groupPageSize, qabulGroupsProvider, searchGroups;
import '../../admissions/presentation/qabul_text.dart';
import '../../admissions/presentation/qabul_widgets.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../data/student_models.dart';
import '../data/students_repository.dart';

const _methods = <(String, String)>[
  ('cash', 'Naqd'),
  ('card', 'Karta'),
  ('click_payme', 'Click / Payme'),
];

/// "Boshqa guruhga qo'shish": the student wants another subject too. Search
/// the course, pick the group, choose the start day, see the first bill by
/// that group's rule, and add -- the seat, the bill and the optional first
/// payment in one step. A full group still takes the student.
/// Returns what was made, or null if closed.
Future<AddedToGroup?> showAddToGroupDialog(
  BuildContext context, {
  required StudentProfileData profile,
  int? activateGroupId,
}) {
  return showAdaptiveFormDialog<AddedToGroup>(
    context,
    maxWidth: 680,
    child: AddToGroupDialog(profile: profile, activateGroupId: activateGroupId),
  );
}

class AddToGroupDialog extends ConsumerStatefulWidget {
  const AddToGroupDialog({
    super.key,
    required this.profile,
    this.activateGroupId,
  });

  final StudentProfileData profile;

  /// "Guruhni faollashtirish": a group he left, already chosen when the list
  /// loads -- only the start day and the first bill are left to confirm.
  final int? activateGroupId;

  @override
  ConsumerState<AddToGroupDialog> createState() => _AddToGroupDialogState();
}

class _AddToGroupDialogState extends ConsumerState<AddToGroupDialog> {
  final _search = TextEditingController();
  int _shown = groupPageSize;
  GroupMatch? _group;
  // 'today' | 'next' | 'custom'
  String _start = 'today';
  DateTime _custom = DateTime.now();
  DateTime? _nextLesson;
  Future<FirstChargePreview>? _preview;
  bool _payNow = false;
  String _method = 'cash';
  bool _saving = false;
  String? _error;

  bool _autoPicked = false;

  late final Set<int> _already = {
    for (final g in widget.profile.activeGroups) g.groupId,
  };

  DateTime get _joinDate => switch (_start) {
    'next' => _nextLesson ?? DateTime.now(),
    'custom' => _custom,
    _ => DateTime.now(),
  };

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(GroupMatch g) {
    setState(() {
      _group = g;
      _start = 'today';
      _nextLesson = null;
      _error = null;
    });
    _loadPreview();
    ref
        .read(qabulRepositoryProvider)
        .trialDates(g.groupId, count: 1)
        .then((dates) {
          if (mounted && _group?.groupId == g.groupId && dates.isNotEmpty) {
            setState(() => _nextLesson = dates.first.startsAt);
          }
        })
        .catchError((_) {});
  }

  void _loadPreview() {
    final g = _group;
    if (g == null) return;
    setState(() {
      _preview = ref
          .read(enrollmentsRepositoryProvider)
          .previewFirstCharge(groupId: g.groupId, joinedAt: _joinDate);
    });
  }

  int _due(GroupMatch g, FirstChargePreview p) =>
      g.prorateFirstPeriod ? p.proratedAmount : p.fullAmount;

  Future<void> _confirm(GroupMatch g, FirstChargePreview p) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final due = _due(g, p);
      final added = await ref
          .read(studentsRepositoryProvider)
          .addToGroup(
            widget.profile.student.id,
            groupId: g.groupId,
            joinedAt: _joinDate,
            firstPaymentAmount: _payNow && due > 0 ? due : null,
            firstPaymentMethod: _payNow && due > 0 ? _method : null,
          );
      if (mounted) Navigator.of(context).pop(added);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(qabulGroupsProvider);
    final all = (groups.value ?? const <GroupMatch>[])
        .where((g) => !_already.contains(g.groupId))
        .toList();
    final matches = searchGroups(all, _search.text);
    final shown = matches.take(_shown).toList();
    final g = _group;
    final wanted = widget.activateGroupId;
    if (!_autoPicked && wanted != null && groups.hasValue) {
      _autoPicked = true;
      final match = all.where((m) => m.groupId == wanted).firstOrNull;
      if (match != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _pick(match);
        });
      }
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DialogHeader(
            title: widget.activateGroupId == null
                ? 'Boshqa guruhga qo\'shish'
                : 'Guruhni faollashtirish',
            subtitle: widget.profile.student.fullName,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const FieldCaption('Kurs'),
                TextField(
                  key: const ValueKey('add-group-search'),
                  controller: _search,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 20),
                    hintText: 'Kurs nomini, tilni yoki o\'qituvchini kiriting',
                  ),
                  onChanged: (_) => setState(() => _shown = groupPageSize),
                ),
                const SizedBox(height: 12),
                if (groups.isLoading)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (groups.hasError)
                  const Text(
                    'Guruhlar yuklanmadi.',
                    style: TextStyle(color: AppColors.dangerText),
                  ),
                if (groups.hasValue &&
                    _search.text.trim().isNotEmpty &&
                    matches.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Mos guruh topilmadi.',
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  ),
                for (final m in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GroupRow(
                      key: ValueKey('add-group-${m.groupId}'),
                      group: m,
                      selected: g?.groupId == m.groupId,
                      onTap: () => _pick(m),
                    ),
                  ),
                if (matches.length > shown.length)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: () => setState(() => _shown += groupPageSize),
                      child: const Text('Ko\'proq'),
                    ),
                  ),
                if (g != null) ...<Widget>[
                  if (g.isFull)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Guruh to\'lgan (${g.enrolled}'
                        '${g.capacity == null ? '' : '/${g.capacity}'}). '
                        'Baribir qo\'shish mumkin: o\'quvchilar soni oshadi.',
                        key: const ValueKey('add-full-note'),
                        style: const TextStyle(color: AppColors.warnText),
                      ),
                    ),
                  const SizedBox(height: 16),
                  _startDate(),
                  const SizedBox(height: 14),
                  _firstBill(g),
                  const SizedBox(height: 10),
                  _payNowRow(),
                ],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: AppColors.dangerText),
                    ),
                  ),
                const SizedBox(height: 16),
                _buttons(g),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _short(DateTime d) =>
      '${d.day}-${dayMonth(d).split('-').last.substring(0, 3)}';

  Widget _startDate() {
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
              'Bugun, ${_short(DateTime.now())}',
              selected: _start == 'today',
              onTap: () {
                setState(() => _start = 'today');
                _loadPreview();
              },
            ),
            if (next != null)
              OptionPill(
                'Keyingi dars, ${_short(next)}',
                selected: _start == 'next',
                onTap: () {
                  setState(() => _start = 'next');
                  _loadPreview();
                },
              ),
            OptionPill(
              _start == 'custom' ? _short(_custom) : 'Sanani tanlash',
              selected: _start == 'custom',
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _custom,
                  firstDate: DateTime.now().subtract(const Duration(days: 60)),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                );
                if (picked == null || !mounted) return;
                setState(() {
                  _custom = picked;
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

  Widget _firstBill(GroupMatch g) {
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
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        } else {
          final prorated = g.prorateFirstPeriod && p.isMidCycle;
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                prorated
                    ? '${dayMonth(_joinDate)}dan ${dayMonth(p.periodEnd)}gacha: '
                          '${p.daysLeft} / ${p.daysInPeriod} kun'
                    : g.isAnniversary
                    ? 'Har bir o\'quvchi guruhga qo\'shilgan kunida to\'laydi.'
                    : 'Birinchi oy to\'liq narxda.',
                style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
              ),
              const Divider(height: 20, color: AppColors.divider),
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'To\'lanishi kerak',
                      style: TextStyle(color: AppColors.inkSecondary),
                    ),
                  ),
                  Text(
                    CurrencyFormatter.format(_due(g, p)),
                    key: const ValueKey('add-due'),
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
              const Text(
                'Birinchi hisob',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
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
          child: Row(
            children: <Widget>[
              Checkbox(
                key: const ValueKey('add-pay-now'),
                value: _payNow,
                onChanged: (v) => setState(() => _payNow = v ?? false),
              ),
              const Text('Birinchi to\'lovni hozir qabul qilish'),
            ],
          ),
        ),
        if (_payNow)
          Padding(
            padding: const EdgeInsets.only(left: 12),
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

  Widget _buttons(GroupMatch? g) {
    return FutureBuilder<FirstChargePreview>(
      future: _preview,
      builder: (context, snapshot) {
        final p = snapshot.data;
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            OutlinedButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Bekor qilish'),
            ),
            const SizedBox(width: 10),
            FilledButton(
              key: const ValueKey('add-confirm'),
              onPressed: _saving || g == null || p == null
                  ? null
                  : () => _confirm(g, p),
              child: const Text('Guruhga qo\'shish'),
            ),
          ],
        );
      },
    );
  }
}
