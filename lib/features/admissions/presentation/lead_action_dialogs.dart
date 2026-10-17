import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/uz_phone_mask_formatter.dart';
import '../../students/presentation/heard_from.dart';
import '../../subjects/data/subjects_repository.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';

/// A small form dialog: fields, an error line and Cancel / [action]. Its
/// [onSubmit] returns normally to close with true, or throws to show the
/// error and stay open.
class _ActionDialog extends StatefulWidget {
  const _ActionDialog({
    required this.title,
    this.subtitle,
    required this.action,
    required this.onSubmit,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final String action;
  final Future<void> Function() onSubmit;
  final List<Widget> children;

  @override
  State<_ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<_ActionDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSubmit();
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
      onSubmit: _submit,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DialogHeader(title: widget.title, subtitle: widget.subtitle),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ...widget.children,
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 12),
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
                  onPressed: _saving ? null : _submit,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(widget.action),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Logs a call, message, visit or note on the lead's timeline. Works
/// offline (queued).
Future<bool?> showAddInteractionDialog(
  BuildContext context,
  WidgetRef ref,
  Lead lead,
) {
  final body = TextEditingController();
  var kind = 'call_out';
  var queued = false;
  return showAdaptiveFormDialog<bool>(
    context,
    child: StatefulBuilder(
      builder: (context, setState) => _ActionDialog(
        title: 'Aloqa yoki izoh',
        subtitle: lead.fullName,
        action: 'Saqlash',
        onSubmit: () async {
          if (body.text.trim().isEmpty) throw 'Matnni yozing.';
          final outcome = await ref
              .read(admissionsRepositoryProvider)
              .addInteraction(lead, kind: kind, body: body.text.trim());
          queued = outcome.queued;
          refreshAdmissions(ref);
          if (queued && context.mounted) {
            showSnack(context, 'Oflayn saqlandi — keyin yuboriladi.');
          }
        },
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final entry in LeadInteraction.kindLabels.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: kind == entry.key,
                  onSelected: (_) => setState(() => kind = entry.key),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: body,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Nima gaplashildi',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    ),
  );
}

/// When a follow-up is due, with one-click presets.
class _DueField extends StatelessWidget {
  const _DueField({required this.value, required this.onChanged});

  final DateTime value;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final tomorrow = DateUtils.dateOnly(now.add(const Duration(days: 1)));
    final presets = <String, DateTime>{
      '1 soatdan keyin': now.add(const Duration(hours: 1)),
      'Ertaga 10:00': tomorrow.add(const Duration(hours: 10)),
      '3 kundan keyin': DateUtils.dateOnly(
        now.add(const Duration(days: 3)),
      ).add(const Duration(hours: 10)),
      'Bir haftadan keyin': DateUtils.dateOnly(
        now.add(const Duration(days: 7)),
      ).add(const Duration(hours: 10)),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final entry in presets.entries)
              ActionChip(
                label: Text(entry.key),
                onPressed: () => onChanged(entry.value),
              ),
          ],
        ),
        const SizedBox(height: 12),
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: value,
              firstDate: DateUtils.dateOnly(now),
              lastDate: now.add(const Duration(days: 365)),
            );
            if (date == null || !context.mounted) return;
            final time = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.fromDateTime(value),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(alwaysUse24HourFormat: true),
                child: child!,
              ),
            );
            if (time == null) return;
            onChanged(
              DateTime(date.year, date.month, date.day, time.hour, time.minute),
            );
          },
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Muddat',
              suffixIcon: Icon(Icons.event_rounded, size: 20),
            ),
            child: Text(DateFormatters.dateTime(value)),
          ),
        ),
      ],
    );
  }
}

/// A follow-up task for the lead. Works offline (queued).
Future<bool?> showAddTaskDialog(
  BuildContext context,
  WidgetRef ref,
  Lead lead,
) {
  final title = TextEditingController(text: 'Qayta qo\'ng\'iroq qilish');
  var due = DateUtils.dateOnly(
    DateTime.now().add(const Duration(days: 1)),
  ).add(const Duration(hours: 10));
  return showAdaptiveFormDialog<bool>(
    context,
    child: StatefulBuilder(
      builder: (context, setState) => _ActionDialog(
        title: 'Vazifa',
        subtitle: lead.fullName,
        action: 'Qo\'shish',
        onSubmit: () async {
          if (title.text.trim().isEmpty) throw 'Vazifani yozing.';
          final outcome = await ref
              .read(admissionsRepositoryProvider)
              .addTask(lead, title: title.text.trim(), dueAt: due);
          refreshAdmissions(ref);
          if (outcome.queued && context.mounted) {
            showSnack(context, 'Oflayn saqlandi — keyin yuboriladi.');
          }
        },
        children: <Widget>[
          TextField(
            controller: title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nima qilish kerak'),
          ),
          const SizedBox(height: 14),
          _DueField(value: due, onChanged: (v) => setState(() => due = v)),
        ],
      ),
    ),
  );
}

/// Picks a stage by hand: only the ones an operator may choose. Closing
/// asks why; "Keyinroq bog'lanish" asks when.
Future<bool?> showChangeStageDialog(
  BuildContext context,
  WidgetRef ref,
  Lead lead, {
  String? initialStage,
}) {
  var stage =
      initialStage ??
      (LeadStage.manual.contains(lead.stage)
          ? lead.stage
          : LeadStage.contacted);
  final reason = TextEditingController();
  var followUpAt = DateUtils.dateOnly(
    DateTime.now().add(const Duration(days: 7)),
  ).add(const Duration(hours: 10));
  return showAdaptiveFormDialog<bool>(
    context,
    child: StatefulBuilder(
      builder: (context, setState) {
        final closing = LeadStage.closed.contains(stage);
        return _ActionDialog(
          title: 'Bosqichni o\'zgartirish',
          subtitle: '${lead.fullName} · hozir: ${LeadStage.label(lead.stage)}',
          action: 'Saqlash',
          onSubmit: () async {
            await ref
                .read(admissionsRepositoryProvider)
                .changeStage(
                  lead,
                  stage,
                  reason: reason.text.trim().isEmpty
                      ? null
                      : reason.text.trim(),
                  followUpAt: stage == LeadStage.followUpLater
                      ? followUpAt
                      : null,
                );
            refreshAdmissions(ref);
          },
          children: <Widget>[
            RadioGroup<String>(
              groupValue: stage,
              onChanged: (v) => setState(() => stage = v ?? stage),
              child: Column(
                children: <Widget>[
                  for (final option in LeadStage.manual)
                    RadioListTile<String>(
                      value: option,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(LeadStage.label(option)),
                      secondary: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: stageColor(option),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Text(
              'Sinov bosqichlari sinov darslaridan, "O\'quvchi bo\'ldi" esa '
              'faqat "Guruhga yozish"dan keladi.',
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            if (closing) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                'Yopilganda rejalashtirilgan sinov va ochiq vazifalar bekor '
                'qilinadi (tarixda qoladi).',
                style: context.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: reason,
              decoration: InputDecoration(
                labelText: closing
                    ? 'Sabab (masalan: qimmat, vaqt to\'g\'ri kelmadi)'
                    : stage == LeadStage.followUpLater
                    ? 'Nima uchun keyinroq (ixtiyoriy)'
                    : 'Izoh (ixtiyoriy)',
              ),
            ),
            if (stage == LeadStage.followUpLater) ...<Widget>[
              const SizedBox(height: 14),
              _DueField(
                value: followUpAt,
                onChanged: (v) => setState(() => followUpAt = v),
              ),
            ],
          ],
        );
      },
    ),
  );
}

/// Edits the lead's own details. Sent with the version it was loaded at.
Future<bool?> showEditLeadDialog(
  BuildContext context,
  WidgetRef ref,
  Lead lead,
) {
  final repo = ref.read(admissionsRepositoryProvider);
  final name = TextEditingController(text: lead.fullName);
  final phone = TextEditingController(
    text: UzPhoneMaskFormatter.format(lead.phone.substring(3)),
  );
  final parentPhone = TextEditingController(
    text: lead.parentPhone == null
        ? ''
        : UzPhoneMaskFormatter.format(lead.parentPhone!.substring(3)),
  );
  final note = TextEditingController(text: lead.note ?? '');
  var subjectId = lead.subjectId;
  var source = lead.source;
  var assignedTo = lead.assignedTo;
  final subjects = repo.subjects();
  final users = repo.users();
  return showAdaptiveFormDialog<bool>(
    context,
    child: StatefulBuilder(
      builder: (context, setState) => _ActionDialog(
        title: 'So\'rovni tahrirlash',
        action: 'Saqlash',
        onSubmit: () async {
          final changes = <String, dynamic>{};
          void put(String field, Object? value, Object? current) {
            if (value != current) changes[field] = value;
          }

          put('full_name', name.text.trim(), lead.fullName);
          put('phone', UzPhoneMaskFormatter.toApi(phone.text), lead.phone);
          put(
            'parent_phone',
            parentPhone.text.trim().isEmpty
                ? null
                : UzPhoneMaskFormatter.toApi(parentPhone.text),
            lead.parentPhone,
          );
          put(
            'note',
            note.text.trim().isEmpty ? null : note.text.trim(),
            lead.note,
          );
          put('subject_id', subjectId, lead.subjectId);
          put('source', source, lead.source);
          put('assigned_to', assignedTo, lead.assignedTo);
          if (changes.isEmpty) return;
          await repo.updateLead(lead, changes);
          refreshAdmissions(ref);
        },
        children: <Widget>[
          TextField(
            controller: name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Ism'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            inputFormatters: <TextInputFormatter>[UzPhoneMaskFormatter()],
            decoration: const InputDecoration(
              labelText: 'Telefon',
              prefixText: '+998 ',
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: parentPhone,
            keyboardType: TextInputType.phone,
            inputFormatters: <TextInputFormatter>[UzPhoneMaskFormatter()],
            decoration: const InputDecoration(
              labelText: 'Ota-ona telefoni',
              prefixText: '+998 ',
            ),
          ),
          const SizedBox(height: 14),
          FutureBuilder<List<Subject>>(
            future: subjects,
            builder: (context, snapshot) => DropdownButtonFormField<int?>(
              initialValue: subjectId,
              decoration: const InputDecoration(labelText: 'Qiziqqan fan'),
              items: <DropdownMenuItem<int?>>[
                const DropdownMenuItem(
                  value: null,
                  child: Text('Hali aniq emas'),
                ),
                for (final subject in snapshot.data ?? const <Subject>[])
                  DropdownMenuItem(
                    value: subject.id,
                    child: Text(subject.name),
                  ),
              ],
              onChanged: (v) => setState(() => subjectId = v),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: source,
                  decoration: const InputDecoration(
                    labelText: 'Qayerdan eshitdi',
                  ),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Tanlanmagan'),
                    ),
                    for (final entry in heardFromLabels.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (v) => setState(() => source = v),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FutureBuilder<List<StaffUser>>(
                  future: users,
                  builder: (context, snapshot) {
                    final list = snapshot.data ?? const <StaffUser>[];
                    return DropdownButtonFormField<int?>(
                      initialValue: list.any((u) => u.id == assignedTo)
                          ? assignedTo
                          : null,
                      decoration: const InputDecoration(labelText: 'Mas\'ul'),
                      items: <DropdownMenuItem<int?>>[
                        if (!list.any((u) => u.id == assignedTo))
                          const DropdownMenuItem(value: null, child: Text('-')),
                        for (final user in list)
                          DropdownMenuItem(
                            value: user.id,
                            child: Text(user.fullName),
                          ),
                      ],
                      onChanged: (v) => setState(() => assignedTo = v),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: note,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Izoh',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    ),
  );
}

/// The teacher's feedback after an attended trial, recorded by staff.
Future<bool?> showTrialFeedbackDialog(
  BuildContext context,
  WidgetRef ref,
  TrialBooking booking, {
  required String leadName,
}) {
  final feedback = TextEditingController(text: booking.feedback ?? '');
  final level = TextEditingController(text: booking.recommendedLevel ?? '');
  return showAdaptiveFormDialog<bool>(
    context,
    child: _ActionDialog(
      title: 'O\'qituvchi fikri',
      subtitle: leadName,
      action: 'Saqlash',
      onSubmit: () async {
        if (feedback.text.trim().isEmpty) throw 'Fikrni yozing.';
        await ref
            .read(admissionsRepositoryProvider)
            .recordFeedback(
              booking.id,
              feedback: feedback.text.trim(),
              recommendedLevel: level.text.trim().isEmpty
                  ? null
                  : level.text.trim(),
            );
        refreshAdmissions(ref);
      },
      children: <Widget>[
        TextField(
          controller: feedback,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Darsda qanday bo\'ldi',
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: level,
          decoration: const InputDecoration(
            labelText: 'Tavsiya etilgan daraja (ixtiyoriy)',
            hintText: 'masalan: Beginner, B1',
          ),
        ),
      ],
    ),
  );
}

/// Asks for an optional reason and runs [onConfirm] -- cancelling a trial
/// or a whole session.
Future<bool?> showReasonDialog(
  BuildContext context, {
  required String title,
  required String action,
  required Future<void> Function(String? reason) onConfirm,
  String? subtitle,
}) {
  final reason = TextEditingController();
  return showAdaptiveFormDialog<bool>(
    context,
    child: _ActionDialog(
      title: title,
      subtitle: subtitle,
      action: action,
      onSubmit: () =>
          onConfirm(reason.text.trim().isEmpty ? null : reason.text.trim()),
      children: <Widget>[
        TextField(
          controller: reason,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Sabab (ixtiyoriy)'),
        ),
      ],
    ),
  );
}
