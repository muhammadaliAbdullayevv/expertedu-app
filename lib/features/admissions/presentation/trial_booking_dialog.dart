import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/app_sidebar.dart' show Avatar;
import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../services/api/api_client.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import '../data/qabul_models.dart';
import '../data/qabul_repository.dart';
import 'admissions_ui.dart';
import 'qabul_text.dart';
import 'qabul_widgets.dart';

/// "Sinov darsiga yozish": pick the group, pick one of its next lessons,
/// done. The client stays a lead -- a trial is free, makes no charge and no
/// student; they show on that lesson's attendance list as "sinov".
/// Returns true once booked (or queued while offline).
Future<bool?> showTrialBookingDialog(
  BuildContext context, {
  required Lead lead,
  int? groupId,
}) {
  return showAdaptiveFormDialog<bool>(
    context,
    maxWidth: 560,
    child: TrialBookingForm(lead: lead, initialGroupId: groupId),
  );
}

class TrialBookingForm extends ConsumerStatefulWidget {
  const TrialBookingForm({super.key, required this.lead, this.initialGroupId});

  final Lead lead;
  final int? initialGroupId;

  @override
  ConsumerState<TrialBookingForm> createState() => _TrialBookingFormState();
}

class _TrialBookingFormState extends ConsumerState<TrialBookingForm> {
  late final QabulRepository _qabul = ref.read(qabulRepositoryProvider);
  late final Future<List<GroupMatch>> _groups = _loadGroups();

  int? _groupId;
  Future<List<TrialDate>>? _dates;
  TrialDate? _date;
  bool _remind = true;
  bool _saving = false;
  String? _error;

  Future<List<GroupMatch>> _loadGroups() async {
    final result = await _qabul.searchGroups(subjectId: widget.lead.subjectId);
    final all = [...result.exact, ...result.near];
    if (all.isNotEmpty) {
      final initial = widget.initialGroupId;
      final pick =
          all.where((g) => g.groupId == initial && !g.isFull).firstOrNull ??
          all.where((g) => !g.isFull).firstOrNull;
      if (pick != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _pickGroup(pick.groupId),
        );
      }
    }
    return all;
  }

  void _pickGroup(int id) {
    if (!mounted) return;
    setState(() {
      _groupId = id;
      _date = null;
      _error = null;
      _dates = _qabul.trialDates(id).then((dates) {
        final free = dates.where((d) => !d.sessionFull).firstOrNull;
        if (mounted) setState(() => _date = free);
        return dates;
      });
    });
  }

  Future<void> _save(GroupMatch group) async {
    final date = _date;
    if (date == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final outcome = await ref
          .read(admissionsRepositoryProvider)
          .bookTrial(
            widget.lead,
            sessionId: date.trialSessionId,
            session: date.trialSessionId != null
                ? null
                : NewTrialSession(
                    kind: 'group_lesson',
                    groupId: group.groupId,
                    startsAt: date.startsAt,
                    endsAt: date.endsAt,
                    capacity: date.suggestedCapacity,
                  ),
            remind: _remind,
          );
      if (!mounted) return;
      if (outcome.queued) {
        showSnack(context, 'Oflayn saqlandi — internet qaytganda yuboriladi.');
      }
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lead = widget.lead;
    return FutureBuilder<List<GroupMatch>>(
      future: _groups,
      builder: (context, snapshot) {
        final groups = snapshot.data;
        final group = groups?.where((g) => g.groupId == _groupId).firstOrNull;
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const DialogHeader(
                title: 'Sinov darsiga yozish',
                subtitle:
                    'Mijoz so\'rovdan olinadi, yangi o\'quvchi yaratilmaydi',
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _LeadStrip(lead: lead),
                    const SizedBox(height: 16),
                    const FieldCaption('Guruhni tanlang'),
                    if (snapshot.connectionState != ConnectionState.done)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (snapshot.hasError)
                      Text('${snapshot.error}')
                    else if (groups!.isEmpty)
                      const InfoBox(
                        'Bu fan bo\'yicha faol guruh topilmadi. Avval guruh qo\'shing.',
                      )
                    else
                      for (final g in groups) ...<Widget>[
                        ChoiceCard(
                          title: g.name,
                          subtitle: [
                            slotsLabel(g.slots),
                            ?g.teacherName,
                          ].join(' · '),
                          trailing: StatusChip(
                            seatsLabel(g.freeSeats),
                            tone: g.isFull ? StatusTone.danger : StatusTone.ok,
                          ),
                          selected: g.groupId == _groupId,
                          enabled: !g.isFull,
                          onTap: () => _pickGroup(g.groupId),
                        ),
                        const SizedBox(height: 8),
                      ],
                    if (_dates != null) ...<Widget>[
                      const SizedBox(height: 8),
                      const FieldCaption('Sinov dars sanasi'),
                      _DatePicker(
                        future: _dates!,
                        selected: _date,
                        onPick: (d) => setState(() => _date = d),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        value: _remind,
                        onChanged: (v) => setState(() => _remind = v ?? false),
                        title: const Text(
                          'Mijozga dars vaqti haqida eslatish (vazifa qo\'shiladi)',
                        ),
                      ),
                    ],
                    if (_date != null) ...<Widget>[
                      const SizedBox(height: 8),
                      InfoBox(
                        'Sinov darsida oylik hisob yaratilmaydi, qarz paydo bo\'lmaydi. '
                        'Mijoz ${dayMonth(_date!.startsAt)} davomat ro\'yxatida "sinov" belgisi bilan ko\'rinadi.',
                      ),
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        OutlinedButton(
                          onPressed: _saving
                              ? null
                              : () => Navigator.of(context).pop(false),
                          child: const Text('Bekor qilish'),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          onPressed: _saving || group == null || _date == null
                              ? null
                              : () => _save(group),
                          child: const Text('Sinov darsiga yozish'),
                        ),
                      ],
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
}

class _LeadStrip extends StatelessWidget {
  const _LeadStrip({required this.lead});

  final Lead lead;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.divider.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Avatar(name: lead.fullName, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  lead.fullName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  PhoneFormatter.display(lead.phone),
                  style: const TextStyle(color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
          if (lead.subjectName != null)
            StatusChip('So\'rov: ${lead.subjectName}', tone: StatusTone.info),
        ],
      ),
    );
  }
}

class _DatePicker extends StatelessWidget {
  const _DatePicker({
    required this.future,
    required this.selected,
    required this.onPick,
  });

  final Future<List<TrialDate>> future;
  final TrialDate? selected;
  final ValueChanged<TrialDate> onPick;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<TrialDate>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return Text(
            '${snapshot.error}',
            style: const TextStyle(color: AppColors.dangerText),
          );
        }
        final dates = snapshot.data ?? const <TrialDate>[];
        if (dates.isEmpty) {
          return const InfoBox(
            'Bu guruhning yaqin darslari topilmadi — avval dars jadvalini kiriting.',
          );
        }
        return Row(
          children: <Widget>[
            for (final d in dates) ...<Widget>[
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: d.sessionFull ? null : () => onPick(d),
                  child: Opacity(
                    opacity: d.sessionFull ? 0.45 : 1,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: selected == d
                            ? AppColors.accent
                            : AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected == d
                              ? AppColors.accent
                              : AppColors.border,
                        ),
                      ),
                      child: Column(
                        children: <Widget>[
                          Text(
                            weekdayDate(d.startsAt),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: selected == d
                                  ? Colors.white
                                  : AppColors.ink,
                            ),
                          ),
                          Text(
                            d.sessionFull ? 'To\'lgan' : clock(d.startsAt),
                            style: TextStyle(
                              fontSize: 12,
                              color: selected == d
                                  ? Colors.white70
                                  : AppColors.inkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (d != dates.last) const SizedBox(width: 8),
            ],
          ],
        );
      },
    );
  }
}
