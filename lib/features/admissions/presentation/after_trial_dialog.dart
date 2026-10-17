import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../services/api/api_client.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../../groups/data/groups_repository.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';
import 'qabul_text.dart';
import 'qabul_widgets.dart';

enum AfterTrialOutcome { enroll, later, reject }

/// "Sinovdan keyin" -- what happened after the trial: join a group (the one
/// step that makes the client a student and starts the monthly charge),
/// call back later, or turn it down. With [afterTrial] false it is the same
/// dialog reduced to "Guruhga qo'shish" for a client who skipped the trial.
///
/// Returns a message to show once done, or null if cancelled.
Future<String?> showAfterTrialDialog(
  BuildContext context, {
  required Lead lead,
  int? groupId,
  bool afterTrial = true,
  AfterTrialOutcome initialOutcome = AfterTrialOutcome.enroll,
}) {
  return showAdaptiveFormDialog<String>(
    context,
    maxWidth: 560,
    child: AfterTrialForm(
      lead: lead,
      groupId: groupId,
      afterTrial: afterTrial,
      initialOutcome: initialOutcome,
    ),
  );
}

class AfterTrialForm extends ConsumerStatefulWidget {
  const AfterTrialForm({
    super.key,
    required this.lead,
    this.groupId,
    this.afterTrial = true,
    this.initialOutcome = AfterTrialOutcome.enroll,
  });

  final Lead lead;
  final int? groupId;
  final bool afterTrial;
  final AfterTrialOutcome initialOutcome;

  @override
  ConsumerState<AfterTrialForm> createState() => _AfterTrialFormState();
}

class _AfterTrialFormState extends ConsumerState<AfterTrialForm> {
  /// One key per dialog: resending after a lost response returns the first
  /// enrollment instead of making a second.
  final String _key = const Uuid().v4();
  late final AdmissionsRepository _repo = ref.read(
    admissionsRepositoryProvider,
  );
  late final Future<({LeadDetail detail, List<Group> groups})> _data = _load();

  late AfterTrialOutcome _outcome = widget.initialOutcome;
  int? _groupId;
  String _firstMonth = 'prorated';
  Future<FirstChargePreview>? _preview;
  late DateTime _callBack = DateTime.now().add(const Duration(days: 3));
  final _reason = TextEditingController();
  bool _saving = false;
  String? _error;

  Future<({LeadDetail detail, List<Group> groups})> _load() async {
    final detail = await _repo.getLead(widget.lead.id);
    final groups = await _repo.groups();
    // The group they tried (latest booking that isn't cancelled), if any.
    final tried = detail.bookings
        .where(
          (b) =>
              b.status == TrialStatus.attended ||
              b.status == TrialStatus.scheduled,
        )
        .map((b) => b.session?.groupId)
        .whereType<int>()
        .lastOrNull;
    final bySubject = groups.where((g) => g.subjectId == detail.lead.subjectId);
    final pick =
        widget.groupId ??
        tried ??
        bySubject.firstOrNull?.id ??
        groups.firstOrNull?.id;
    if (pick != null)
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickGroup(pick));
    return (detail: detail, groups: groups);
  }

  void _pickGroup(int id) {
    if (!mounted) return;
    setState(() {
      _groupId = id;
      _preview = ref
          .read(enrollmentsRepositoryProvider)
          .previewFirstCharge(groupId: id, joinedAt: DateTime.now())
          .then((p) {
            if (mounted)
              setState(() => _firstMonth = p.isMidCycle ? 'prorated' : 'full');
            return p;
          });
    });
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _confirm(
    Lead lead,
    Group? group,
    FirstChargePreview? preview,
  ) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      switch (_outcome) {
        case AfterTrialOutcome.enroll:
          if (group == null) return;
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
              'joined_at': apiDate(DateTime.now()),
              'first_month': _firstMonth,
            },
          );
          if (!mounted) return;
          Navigator.of(context).pop(
            '${result.studentName} guruhga yozildi · birinchi oy ${CurrencyFormatter.format(result.firstCharge)}'
            '${result.reusedStudent ? ' (mavjud o\'quvchi)' : ''}',
          );
        case AfterTrialOutcome.later:
          final at = DateTime(
            _callBack.year,
            _callBack.month,
            _callBack.day,
            10,
          );
          await _repo.changeStage(
            lead,
            LeadStage.followUpLater,
            followUpAt: at,
          );
          if (mounted)
            Navigator.of(
              context,
            ).pop('Keyinroq bog\'lanish belgilandi: ${dayMonth(at)}');
        case AfterTrialOutcome.reject:
          final reason = _reason.text.trim();
          if (reason.isEmpty) {
            setState(() => _error = 'Sababini yozing.');
            return;
          }
          await _repo.changeStage(
            lead,
            LeadStage.notInterested,
            reason: reason,
          );
          if (mounted) Navigator.of(context).pop('So\'rov rad etildi');
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<({LeadDetail detail, List<Group> groups})>(
      future: _data,
      builder: (context, snapshot) {
        final title = widget.afterTrial
            ? 'Sinov darsidan keyin'
            : 'Guruhga qo\'shish';
        if (snapshot.connectionState != ConnectionState.done) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DialogHeader(title: title),
              const Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(),
              ),
            ],
          );
        }
        if (snapshot.hasError) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DialogHeader(title: title),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snapshot.error}'),
              ),
            ],
          );
        }
        final lead = snapshot.data!.detail.lead;
        final detail = snapshot.data!.detail;
        final groups = snapshot.data!.groups;
        final group = groups.where((g) => g.id == _groupId).firstOrNull;
        final attended = detail.bookings.any(
          (b) => b.status == TrialStatus.attended,
        );
        final enrolling = _outcome == AfterTrialOutcome.enroll;
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DialogHeader(
                title: title,
                subtitle: [lead.fullName, ?group?.name].join(' · '),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (widget.afterTrial) ...<Widget>[
                      Wrap(
                        spacing: 8,
                        children: <Widget>[
                          StatusChip(
                            attended
                                ? 'Sinov darsiga keldi'
                                : 'Sinovga hali kelmagan',
                            tone: attended ? StatusTone.ok : StatusTone.neutral,
                          ),
                          StatusChip(
                            'Qaror: ${_decisionLabel(lead.stage)}',
                            tone: StatusTone.neutral,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      const FieldCaption('Natija'),
                      ChoiceCard(
                        title: 'Guruhga qo\'shish',
                        subtitle:
                            'O\'quvchi yaratiladi, oylik hisob boshlanadi',
                        selected: enrolling,
                        onTap: () =>
                            setState(() => _outcome = AfterTrialOutcome.enroll),
                      ),
                      const SizedBox(height: 8),
                      ChoiceCard(
                        title: 'Keyinroq bog\'lanish',
                        subtitle: 'Qabulda qoladi, eslatma belgilanadi',
                        selected: _outcome == AfterTrialOutcome.later,
                        onTap: () =>
                            setState(() => _outcome = AfterTrialOutcome.later),
                      ),
                      const SizedBox(height: 8),
                      ChoiceCard(
                        title: 'Rad etildi',
                        subtitle:
                            'Sababini yozing (narx, vaqt, boshqa markaz...)',
                        selected: _outcome == AfterTrialOutcome.reject,
                        onTap: () =>
                            setState(() => _outcome = AfterTrialOutcome.reject),
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_outcome == AfterTrialOutcome.later)
                      _CallBackField(
                        date: _callBack,
                        onPick: (d) => setState(() => _callBack = d),
                      ),
                    if (_outcome == AfterTrialOutcome.reject)
                      TextField(
                        controller: _reason,
                        autofocus: true,
                        decoration: const InputDecoration(
                          labelText: 'Rad etish sababi',
                        ),
                      ),
                    if (enrolling)
                      _EnrollSection(
                        groups: groups,
                        group: group,
                        preview: _preview,
                        firstMonth: _firstMonth,
                        onGroup: _pickGroup,
                        onFirstMonth: (v) => setState(() => _firstMonth = v),
                        lead: lead,
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
                    FutureBuilder<FirstChargePreview>(
                      future: _preview,
                      builder: (context, previewSnapshot) {
                        final preview = previewSnapshot.data;
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Widget>[
                            OutlinedButton(
                              onPressed: _saving
                                  ? null
                                  : () => Navigator.of(context).pop(),
                              child: const Text('Bekor qilish'),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              onPressed:
                                  _saving ||
                                      (enrolling &&
                                          (group == null || preview == null))
                                  ? null
                                  : () => _confirm(lead, group, preview),
                              child: const Text('Tasdiqlash'),
                            ),
                          ],
                        );
                      },
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

  static String _decisionLabel(String stage) => switch (stage) {
    LeadStage.decisionPending => 'kutilmoqda',
    LeadStage.trialCompleted => 'kutilmoqda',
    LeadStage.followUpLater => 'keyinroq',
    _ => LeadStage.label(stage).toLowerCase(),
  };
}

class _CallBackField extends StatelessWidget {
  const _CallBackField({required this.date, required this.onPick});

  final DateTime date;
  final ValueChanged<DateTime> onPick;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 365)),
        );
        if (picked != null) onPick(picked);
      },
      icon: const Icon(Icons.event_outlined, size: 18),
      label: Text('Qachon eslatamiz: ${dayMonth(date)}'),
    );
  }
}

class _EnrollSection extends StatelessWidget {
  const _EnrollSection({
    required this.groups,
    required this.group,
    required this.preview,
    required this.firstMonth,
    required this.onGroup,
    required this.onFirstMonth,
    required this.lead,
  });

  final List<Group> groups;
  final Group? group;
  final Future<FirstChargePreview>? preview;
  final String firstMonth;
  final ValueChanged<int> onGroup;
  final ValueChanged<String> onFirstMonth;
  final Lead lead;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DropdownButtonFormField<int>(
          key: ValueKey(group?.id),
          initialValue: group?.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Guruh'),
          items: <DropdownMenuItem<int>>[
            for (final g in groups)
              DropdownMenuItem(
                value: g.id,
                child: Text(
                  '${g.name}  ·  ${slotsLabel(g.schedule)}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => v == null ? null : onGroup(v),
        ),
        if (group != null) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _Fact('Guruh', group!.name, slotsLabel(group!.schedule)),
              ),
              Expanded(
                child: _Fact(
                  'Oylik narx',
                  CurrencyFormatter.format(group!.feeAmount),
                  group!.billingLabel,
                ),
              ),
            ],
          ),
        ],
        if (preview != null)
          FutureBuilder<FirstChargePreview>(
            future: preview,
            builder: (context, snapshot) {
              final p = snapshot.data;
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${snapshot.error}',
                    style: const TextStyle(color: AppColors.dangerText),
                  ),
                );
              }
              if (p == null) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              final amount = p.isMidCycle && firstMonth == 'prorated'
                  ? p.proratedAmount
                  : p.fullAmount;
              final today = DateTime.now();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 14),
                  const FieldCaption('Birinchi oy hisobi'),
                  if (p.isMidCycle) ...<Widget>[
                    ChoiceCard(
                      title: 'Qolgan kunlar bo\'yicha',
                      subtitle:
                          '${dayMonth(today)}dan ${dayMonth(p.periodEnd)}gacha (${p.daysLeft}/${p.daysInPeriod} kun)',
                      trailing: Text(
                        CurrencyFormatter.format(p.proratedAmount),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      selected: firstMonth == 'prorated',
                      onTap: () => onFirstMonth('prorated'),
                    ),
                    const SizedBox(height: 8),
                    ChoiceCard(
                      title: 'To\'liq oy',
                      subtitle: group != null && group!.isAnniversary
                          ? 'Har oy shu kunda'
                          : 'Hisob oyning ${group?.billingDay ?? 1}-sanasidan',
                      trailing: Text(
                        CurrencyFormatter.format(p.fullAmount),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      selected: firstMonth == 'full',
                      onTap: () => onFirstMonth('full'),
                    ),
                  ] else
                    ChoiceCard(
                      title: group != null && group!.isAnniversary
                          ? 'Har oy ${today.day}-sanada'
                          : 'To\'liq oy',
                      subtitle: 'Bu guruhda birinchi oy qisman hisoblanmaydi',
                      trailing: Text(
                        CurrencyFormatter.format(p.fullAmount),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      selected: true,
                      onTap: () {},
                    ),
                  const SizedBox(height: 12),
                  InfoBox(
                    'Tasdiqlansa: o\'quvchi profili yaratiladi, hisob ${CurrencyFormatter.format(amount)} bo\'ladi '
                    'va Qabulda "Guruhga qo\'shildi" bosqichiga o\'tadi. Narx va ulush hisobi sozlamalarda o\'zgartiriladi.',
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, this.note);

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.inkMuted,
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        Text(
          note,
          style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
        ),
      ],
    );
  }
}
