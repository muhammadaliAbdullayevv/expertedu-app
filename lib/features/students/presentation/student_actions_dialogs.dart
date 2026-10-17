import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../admissions/presentation/qabul_widgets.dart';
import '../data/student_models.dart';
import '../data/students_repository.dart';

/// "Guruhdan chiqarish": the student leaves this one group. Asks why, and says
/// whether he has paid everything for it. Returns what he still owes on the
/// group (0 = nothing), or null if closed.
Future<int?> showRemoveFromGroupDialog(
  BuildContext context, {
  required StudentProfileData profile,
  required ProfileGroup group,
}) {
  return showAdaptiveFormDialog<int>(
    context,
    maxWidth: 520,
    child: _ReasonDialog(
      title: 'Guruhdan chiqarish',
      subtitle: '${profile.student.fullName} · ${group.groupName}',
      explain:
          'O\'quvchi bu guruhdan chiqariladi. Davomati, to\'lovlari va boshqa '
          'barcha ma\'lumotlari saqlanadi; keyin uni shu guruhga qaytarish mumkin.',
      debt: group.balance,
      debtLabel: 'Bu guruh bo\'yicha',
      confirmLabel: 'Guruhdan chiqarish',
      noteLabel: 'Chiqarish sababi',
      required: true,
      run: (ref, note) => ref
          .read(studentsRepositoryProvider)
          .removeFromGroup(
            profile.student.id,
            groupId: group.groupId,
            note: note,
          ),
    ),
  );
}

/// "Arxivga o'tkazish": the student leaves every group he is in and is marked
/// archived. Returns what he still owes in all, or null if closed.
Future<int?> showArchiveDialog(
  BuildContext context, {
  required StudentProfileData profile,
}) {
  final groups = profile.activeGroups.map((g) => g.groupName).join(', ');
  return showAdaptiveFormDialog<int>(
    context,
    maxWidth: 520,
    child: _ReasonDialog(
      title: 'Arxivga o\'tkazish',
      subtitle: profile.student.fullName,
      explain:
          '${groups.isEmpty ? 'O\'quvchi' : 'O\'quvchi $groups guruh${profile.activeGroups.length > 1 ? 'lari' : 'i'}dan chiqariladi va'} '
          'arxivga o\'tadi. Davomati, to\'lovlari va barcha ma\'lumotlari saqlanadi. '
          'Keyin arxivdan chiqarsangiz, guruhlari profilida xira holda turadi va '
          'istalganini qayta faollashtirish mumkin.',
      debt: profile.balance,
      debtLabel: 'Barcha guruhlar bo\'yicha',
      confirmLabel: 'Arxivga o\'tkazish',
      noteLabel: 'Arxivga o\'tkazish sababi',
      required: true,
      run: (ref, note) => ref
          .read(studentsRepositoryProvider)
          .archive(profile.student.id, note: note),
    ),
  );
}

/// "Arxivdan chiqarish": no groups come back by themselves.
Future<int?> showUnarchiveDialog(
  BuildContext context, {
  required StudentProfileData profile,
}) {
  return showAdaptiveFormDialog<int>(
    context,
    maxWidth: 520,
    child: _ReasonDialog(
      title: 'Arxivdan chiqarish',
      subtitle: profile.student.fullName,
      explain:
          'O\'quvchi arxivdan chiqadi, lekin hech qaysi guruhga o\'zi qaytmaydi: '
          'oldingi guruhlari profilida xira holda turadi, har birini alohida '
          'faollashtirish mumkin.',
      debt: null,
      debtLabel: '',
      confirmLabel: 'Arxivdan chiqarish',
      noteLabel: 'Izoh (ixtiyoriy)',
      required: false,
      run: (ref, note) async {
        await ref
            .read(studentsRepositoryProvider)
            .unarchive(profile.student.id, note: note.isEmpty ? null : note);
        return 0;
      },
    ),
  );
}

/// The words for "did he pay everything?" -- shared by the dialog and the
/// messages after it.
String debtSentence(String label, int debt) => debt > 0
    ? '$label qarz: ${CurrencyFormatter.format(debt)}'
    : '$label qarz yo\'q — barcha to\'lovlar to\'langan';

class _ReasonDialog extends ConsumerStatefulWidget {
  const _ReasonDialog({
    required this.title,
    required this.subtitle,
    required this.explain,
    required this.debt,
    required this.debtLabel,
    required this.confirmLabel,
    required this.noteLabel,
    required this.required,
    required this.run,
  });

  final String title;
  final String subtitle;
  final String explain;

  /// What he owes (null = not shown).
  final int? debt;
  final String debtLabel;
  final String confirmLabel;
  final String noteLabel;
  final bool required;
  final Future<int> Function(WidgetRef ref, String note) run;

  @override
  ConsumerState<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends ConsumerState<_ReasonDialog> {
  final _note = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final note = _note.text.trim();
    if (widget.required && note.isEmpty) {
      setState(() => _error = 'Sababini yozing.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final debt = await widget.run(ref, note);
      if (mounted) Navigator.of(context).pop(debt);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final debt = widget.debt;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DialogHeader(title: widget.title, subtitle: widget.subtitle),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  widget.explain,
                  key: const ValueKey('reason-explain'),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.inkSecondary,
                  ),
                ),
                if (debt != null) ...<Widget>[
                  const SizedBox(height: 14),
                  Container(
                    key: const ValueKey('reason-debt'),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: debt > 0 ? AppColors.dangerBg : AppColors.okBg,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          debt > 0
                              ? Icons.error_outline_rounded
                              : Icons.check_circle_outline_rounded,
                          size: 20,
                          color: debt > 0
                              ? AppColors.dangerText
                              : AppColors.okText,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            debtSentence(widget.debtLabel, debt),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: debt > 0
                                  ? AppColors.dangerText
                                  : AppColors.okText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (debt > 0)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Qarz o\'chmaydi: profilda qoladi va keyin ham to\'lanishi mumkin.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.inkMuted,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 16),
                FieldCaption(widget.noteLabel),
                TextField(
                  key: const ValueKey('reason-note'),
                  controller: _note,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: widget.required
                        ? 'Masalan: boshqa shaharga ko\'chdi'
                        : null,
                  ),
                  onChanged: (_) => setState(() => _error = null),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      key: const ValueKey('reason-error'),
                      style: const TextStyle(color: AppColors.dangerText),
                    ),
                  ),
                const SizedBox(height: 18),
                Row(
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
                      key: const ValueKey('reason-confirm'),
                      onPressed: _saving ? null : _confirm,
                      child: Text(widget.confirmLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
