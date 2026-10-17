import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../services/api/api_client.dart';
import '../../students/presentation/add_student_dialog.dart';
import '../../students/presentation/student_summary_dialog.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';
import 'lead_action_dialogs.dart';
import 'schedule_trial_dialog.dart';

/// Opens a lead: a panel sliding in from the right on wide layouts, full
/// screen on phones. [lead] is enough for one still waiting in the
/// offline outbox; otherwise its [leadId] is loaded.
Future<void> showLeadDetails(BuildContext context, {int? leadId, Lead? lead}) {
  assert(leadId != null || lead != null);
  final panel = _LeadDetailsPanel(leadId: leadId ?? lead!.id, pending: lead);
  if (!isWideLayout(context)) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(child: panel),
    );
  }
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Yopish',
    barrierColor: const Color(0x330F172A),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, _, _) => Align(
      alignment: Alignment.centerRight,
      // A hairline edge and a soft, wide shadow -- Material elevation draws
      // a hard dark band against the dimmed screen.
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: context.colors.outlineVariant),
          ),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x1A0F172A),
              blurRadius: 32,
              offset: Offset(-8, 0),
            ),
          ],
        ),
        child: Material(
          color: context.colors.surface,
          child: SizedBox(
            width: 600,
            height: double.infinity,
            child: SafeArea(child: panel),
          ),
        ),
      ),
    ),
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0.15, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
      child: FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _LeadDetailsPanel extends ConsumerStatefulWidget {
  const _LeadDetailsPanel({required this.leadId, this.pending});

  final int leadId;
  final Lead? pending;

  @override
  ConsumerState<_LeadDetailsPanel> createState() => _LeadDetailsPanelState();
}

class _LeadDetailsPanelState extends ConsumerState<_LeadDetailsPanel> {
  Future<LeadDetail>? _detail;
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);

  bool get _isPending => widget.pending?.isPending ?? false;

  @override
  void initState() {
    super.initState();
    if (!_isPending) _load();
    _refresh.addListener(_onRefresh);
  }

  @override
  void dispose() {
    _refresh.removeListener(_onRefresh);
    super.dispose();
  }

  void _onRefresh() {
    if (mounted && !_isPending) setState(_load);
  }

  void _load() {
    _detail = ref.read(admissionsRepositoryProvider).getLead(widget.leadId);
  }

  /// Runs an online-only action; a stale version reloads the lead.
  Future<void> _run(Future<void> Function() action, {String? done}) async {
    try {
      await action();
      refreshAdmissions(ref);
      if (done != null && mounted) showSnack(context, done);
    } on ApiException catch (e) {
      if (!mounted) return;
      showSnack(context, e.message);
      if (e.statusCode == 409) refreshAdmissions(ref);
    }
  }

  Future<void> _enroll(LeadDetail detail) async {
    final lead = detail.lead;
    final result = await showEnrollLeadWizard(
      context,
      LeadEnrollment(
        leadId: lead.id,
        fullName: lead.fullName,
        phone: lead.phone,
        parentPhone: lead.parentPhone,
        source: lead.source,
        note: lead.note,
        subjectId: lead.subjectId,
      ),
    );
    if (result == null || !mounted) return;
    refreshAdmissions(ref);
    showSnack(
      context,
      '${result.studentName} guruhga yozildi · birinchi oy '
      '${CurrencyFormatter.format(result.firstCharge)}'
      '${result.reusedStudent ? ' (mavjud o\'quvchi)' : ''}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: _isPending
            ? _PendingLeadView(lead: widget.pending!)
            : FutureBuilder<LeadDetail>(
                future: _detail,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Column(
                      children: <Widget>[
                        const DialogHeader(title: 'So\'rov'),
                        Expanded(
                          child: LoadFailed(
                            error: snapshot.error!,
                            onRetry: () => setState(_load),
                          ),
                        ),
                      ],
                    );
                  }
                  final detail = snapshot.data;
                  if (detail == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return _content(detail);
                },
              ),
      ),
    );
  }

  Widget _content(LeadDetail detail) {
    final lead = detail.lead;
    final open = lead.isOpen;
    final enrollable =
        open ||
        lead.stage == LeadStage.notInterested ||
        lead.stage == LeadStage.unreachable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DialogHeader(
          title: lead.fullName,
          subtitle:
              '${PhoneFormatter.display(lead.phone)} · ${lead.subjectName ?? 'fan tanlanmagan'}',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              StageChip(lead.stage),
              if (lead.lostReason != null)
                Text(lead.lostReason!, style: context.textTheme.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (lead.stage != LeadStage.enrolled) ...<Widget>[
                OutlinedButton.icon(
                  onPressed: () => showAddInteractionDialog(context, ref, lead),
                  icon: const Icon(Icons.call_outlined, size: 18),
                  label: const Text('Aloqa / izoh'),
                ),
                if (open)
                  OutlinedButton.icon(
                    onPressed: lead.nextTrialBookingId != null
                        ? null
                        : () => showScheduleTrialDialog(context, lead: lead),
                    icon: const Icon(Icons.event_available_outlined, size: 18),
                    label: const Text('Sinov darsi'),
                  ),
                if (open)
                  OutlinedButton.icon(
                    onPressed: () => showAddTaskDialog(context, ref, lead),
                    icon: const Icon(Icons.task_alt_rounded, size: 18),
                    label: const Text('Vazifa'),
                  ),
                OutlinedButton.icon(
                  onPressed: () => showChangeStageDialog(context, ref, lead),
                  icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                  label: Text(open ? 'Bosqich' : 'Qayta ochish'),
                ),
                OutlinedButton.icon(
                  onPressed: () => showEditLeadDialog(context, ref, lead),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Tahrirlash'),
                ),
              ],
              if (enrollable)
                // The one explicit way in: a filled button, like every main
                // action.
                FilledButton.icon(
                  onPressed: () => _enroll(detail),
                  icon: const Icon(Icons.how_to_reg_rounded, size: 18),
                  label: const Text('Guruhga yozish'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            children: <Widget>[
              if (lead.stage == LeadStage.enrolled)
                _Banner(
                  icon: Icons.verified_rounded,
                  color: AppColors.success,
                  text:
                      'O\'quvchi bo\'ldi${lead.enrolledAt == null ? '' : ': ${DateFormatters.date(lead.enrolledAt!)}'}. '
                      'So\'rov tarixi saqlanib qoladi.',
                  action: lead.studentId == null
                      ? null
                      : TextButton(
                          onPressed: () => showStudentSummaryDialog(
                            context,
                            lead.studentId!,
                          ),
                          child: const Text('O\'quvchini ochish'),
                        ),
                )
              else if (detail.student != null)
                _Banner(
                  icon: Icons.school_outlined,
                  color: AppColors.inkSecondary,
                  text:
                      'Bu raqam o\'quvchiga tegishli: ${detail.student!.fullName} '
                      '(${detail.student!.groupNames.isEmpty ? 'guruhsiz' : detail.student!.groupNames.join(', ')}). '
                      'Yozilganda yangi o\'quvchi ochilmaydi.',
                  action: TextButton(
                    onPressed: () => showStudentSummaryDialog(
                      context,
                      detail.student!.studentId,
                    ),
                    child: const Text('Ochish'),
                  ),
                ),
              _info(lead),
              _section('Sinov darslari'),
              if (detail.bookings.isEmpty)
                const _Muted('Hali sinov darsi yo\'q')
              else
                for (final booking in detail.bookings)
                  _BookingTile(
                    booking: booking,
                    lead: lead,
                    onAttendance: (status) => _run(
                      () => ref
                          .read(admissionsRepositoryProvider)
                          .markAttendance(booking.id, status),
                      done: status == TrialStatus.attended
                          ? 'Keldi deb belgilandi'
                          : 'Kelmadi deb belgilandi — qayta bog\'lanish vazifasi qo\'shildi',
                    ),
                    onFeedback: () => showTrialFeedbackDialog(
                      context,
                      ref,
                      booking,
                      leadName: lead.fullName,
                    ),
                    onReschedule: () => showScheduleTrialDialog(
                      context,
                      lead: lead,
                      rescheduling: booking,
                    ),
                    onCancel: () => showReasonDialog(
                      context,
                      title: 'Sinovni bekor qilish',
                      subtitle: 'So\'rov ochiq qoladi.',
                      action: 'Bekor qilish',
                      onConfirm: (reason) async {
                        await ref
                            .read(admissionsRepositoryProvider)
                            .cancelBooking(booking.id, reason: reason);
                        refreshAdmissions(ref);
                      },
                    ),
                  ),
              _section('Vazifalar'),
              if (detail.tasks.isEmpty)
                const _Muted('Vazifa yo\'q')
              else
                for (final task in detail.tasks)
                  _TaskTile(
                    task: task,
                    onComplete: () => _run(
                      () => ref
                          .read(admissionsRepositoryProvider)
                          .completeTask(task.id),
                    ),
                  ),
              _section('Tarix'),
              for (final item in detail.interactions) _TimelineTile(item: item),
            ],
          ),
        ),
      ],
    );
  }

  Widget _info(Lead lead) {
    final rows = <(String, String)>[
      ('Manba', sourceLabel(lead.source)),
      ('Mas\'ul', lead.assignedToName ?? '-'),
      if (lead.parentPhone != null)
        ('Ota-ona', PhoneFormatter.display(lead.parentPhone!)),
      if (lead.preferredTrialDate != null)
        ('Qulay sana', DateFormatters.date(lead.preferredTrialDate!)),
      ('Murojaat', DateFormatters.dateTime(lead.createdAt)),
      if (lead.note != null) ('Izoh', lead.note!),
    ];
    return Column(
      children: <Widget>[
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 110,
                  child: Text(
                    row.$1,
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(child: Text(row.$2)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(title, style: context.textTheme.titleSmall),
  );
}

/// A lead made offline: only what was typed, and the writes that can be
/// queued on top of it.
class _PendingLeadView extends ConsumerWidget {
  const _PendingLeadView({required this.lead});

  final Lead lead;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DialogHeader(
          title: lead.fullName,
          subtitle:
              '${PhoneFormatter.display(lead.phone)} · ${lead.subjectName ?? 'fan tanlanmagan'}',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: _Banner(
            icon: Icons.cloud_upload_outlined,
            color: AppColors.inkSecondary,
            text:
                'Bu so\'rov hali serverga yuborilmagan. Izoh, vazifa va sinov '
                'darsini hozir qo\'shish mumkin — hammasi ketma-ket yuboriladi.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () => showAddInteractionDialog(context, ref, lead),
                icon: const Icon(Icons.call_outlined, size: 18),
                label: const Text('Aloqa / izoh'),
              ),
              OutlinedButton.icon(
                onPressed: () => showScheduleTrialDialog(context, lead: lead),
                icon: const Icon(Icons.event_available_outlined, size: 18),
                label: const Text('Sinov darsi'),
              ),
              OutlinedButton.icon(
                onPressed: () => showAddTaskDialog(context, ref, lead),
                icon: const Icon(Icons.task_alt_rounded, size: 18),
                label: const Text('Vazifa'),
              ),
            ],
          ),
        ),
        if (lead.note != null)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Izoh: ${lead.note}'),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: context.textTheme.bodyMedium)),
          ?action,
        ],
      ),
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: context.textTheme.bodyMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
    ),
  );
}

class _BookingTile extends StatelessWidget {
  const _BookingTile({
    required this.booking,
    required this.lead,
    required this.onAttendance,
    required this.onFeedback,
    required this.onReschedule,
    required this.onCancel,
  });

  final TrialBooking booking;
  final Lead lead;
  final ValueChanged<String> onAttendance;
  final VoidCallback onFeedback;
  final VoidCallback onReschedule;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final session = booking.session;
    final scheduled = booking.status == TrialStatus.scheduled;
    final marked =
        booking.status == TrialStatus.attended ||
        booking.status == TrialStatus.absent;
    final started = session?.hasStarted ?? false;
    final editable = lead.stage != LeadStage.enrolled || marked;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    session == null
                        ? 'Sinov darsi'
                        : '${shortDateTime(session.startsAt)}–${DateFormatters.time(session.endsAt)} · ${session.title}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                TrialStatusChip(booking.status),
              ],
            ),
            if (session != null)
              Text(
                <String>[
                  session.teacherName ?? 'O\'qituvchi tanlanmagan',
                  if (session.room != null) session.room!,
                ].join(' · '),
                style: context.textTheme.bodySmall,
              ),
            if (booking.cancelReason != null)
              Text(
                'Sabab: ${booking.cancelReason}',
                style: context.textTheme.bodySmall,
              ),
            if (booking.feedback != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Fikr: ${booking.feedback}'
                  '${booking.recommendedLevel == null ? '' : ' (daraja: ${booking.recommendedLevel})'}',
                ),
              ),
            if (editable)
              Wrap(
                spacing: 4,
                children: <Widget>[
                  if ((scheduled && started) || marked) ...<Widget>[
                    if (booking.status != TrialStatus.attended)
                      TextButton.icon(
                        onPressed: () => onAttendance(TrialStatus.attended),
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Keldi'),
                      ),
                    if (booking.status != TrialStatus.absent)
                      TextButton.icon(
                        onPressed: () => onAttendance(TrialStatus.absent),
                        icon: const Icon(Icons.close_rounded, size: 18),
                        label: const Text('Kelmadi'),
                      ),
                  ],
                  if (booking.status == TrialStatus.attended)
                    TextButton.icon(
                      onPressed: onFeedback,
                      icon: const Icon(Icons.rate_review_outlined, size: 18),
                      label: Text(
                        booking.feedback == null
                            ? 'Fikr yozish'
                            : 'Fikrni tahrirlash',
                      ),
                    ),
                  if (scheduled && !started) ...<Widget>[
                    TextButton.icon(
                      onPressed: onReschedule,
                      icon: const Icon(Icons.update_rounded, size: 18),
                      label: const Text('Ko\'chirish'),
                    ),
                    TextButton.icon(
                      onPressed: onCancel,
                      icon: const Icon(Icons.event_busy_rounded, size: 18),
                      label: const Text('Bekor qilish'),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, required this.onComplete});

  final FollowUpTask task;
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final color = task.isOverdue ? context.colors.error : null;
    return Row(
      children: <Widget>[
        Checkbox(
          value: !task.isOpen,
          onChanged: task.isOpen ? (_) => onComplete() : null,
        ),
        Expanded(
          child: Text(
            task.title,
            style: TextStyle(
              decoration: task.isOpen ? null : TextDecoration.lineThrough,
              color: task.isOpen ? null : context.colors.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          task.status == 'cancelled'
              ? 'bekor qilingan'
              : shortDateTime(task.dueAt),
          style: context.textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.item});

  final LeadInteraction item;

  IconData get _icon => switch (item.kind) {
    'call_in' => Icons.call_received_rounded,
    'call_out' => Icons.call_made_rounded,
    'sms' => Icons.sms_outlined,
    'telegram' => Icons.send_outlined,
    'visit' => Icons.storefront_outlined,
    'note' => Icons.sticky_note_2_outlined,
    _ => Icons.history_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final system = item.kind == 'system';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            _icon,
            size: 18,
            color: system
                ? context.colors.onSurfaceVariant
                : context.colors.onSurface,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  system
                      ? item.body
                      : '${LeadInteraction.kindLabels[item.kind]}: ${item.body}',
                  style: system
                      ? context.textTheme.bodyMedium?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        )
                      : context.textTheme.bodyMedium,
                ),
                Text(
                  '${DateFormatters.dateTime(item.createdAt)}'
                  '${item.createdByName == null ? '' : ' · ${item.createdByName}'}',
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
