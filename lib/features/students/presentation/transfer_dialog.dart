import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/data/qabul_models.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../admissions/presentation/qabul_form.dart'
    show GroupRow, groupPageSize, qabulGroupsProvider, searchGroups;
import '../../admissions/presentation/qabul_widgets.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../data/student_models.dart';
import '../data/students_repository.dart';

/// "Guruhni almashtirish": pick which of his current groups he leaves (when
/// he is in more than one -- [fromGroupId] says which to start on), then the
/// group he goes to. The new group bills him by its own price from today; what
/// he owed on the old one stays owed. Returns what was made, or null.
Future<TransferResult?> showTransferDialog(
  BuildContext context, {
  required StudentProfileData profile,
  int? fromGroupId,
}) {
  return showAdaptiveFormDialog<TransferResult>(
    context,
    maxWidth: 680,
    child: TransferDialog(profile: profile, fromGroupId: fromGroupId),
  );
}

class TransferDialog extends ConsumerStatefulWidget {
  const TransferDialog({super.key, required this.profile, this.fromGroupId});

  final StudentProfileData profile;
  final int? fromGroupId;

  @override
  ConsumerState<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<TransferDialog> {
  final _search = TextEditingController();
  final _note = TextEditingController();
  int _shown = groupPageSize;
  late ProfileGroup? _from = _initialFrom();
  GroupMatch? _to;
  Future<FirstChargePreview>? _preview;
  bool _saving = false;
  String? _error;

  late final List<ProfileGroup> _current = widget.profile.activeGroups;

  ProfileGroup? _initialFrom() {
    final active = widget.profile.activeGroups;
    if (active.length == 1) return active.first;
    final wanted = widget.fromGroupId;
    return active.where((g) => g.groupId == wanted).firstOrNull;
  }

  @override
  void dispose() {
    _search.dispose();
    _note.dispose();
    super.dispose();
  }

  void _pickTo(GroupMatch g) {
    setState(() {
      _to = g;
      _error = null;
      _preview = ref
          .read(enrollmentsRepositoryProvider)
          .previewFirstCharge(groupId: g.groupId, joinedAt: DateTime.now());
    });
  }

  int _due(GroupMatch g, FirstChargePreview p) =>
      g.prorateFirstPeriod ? p.proratedAmount : p.fullAmount;

  Future<void> _confirm() async {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final note = _note.text.trim();
      final result = await ref
          .read(studentsRepositoryProvider)
          .transfer(
            widget.profile.student.id,
            fromGroupId: from.groupId,
            toGroupId: to.groupId,
            note: note.isEmpty ? null : note,
          );
      if (mounted) Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(qabulGroupsProvider);
    final taken = {for (final g in _current) g.groupId};
    final all = (groups.value ?? const <GroupMatch>[])
        .where((g) => !taken.contains(g.groupId))
        .toList();
    final matches = searchGroups(all, _search.text);
    final shown = matches.take(_shown).toList();
    final from = _from;
    final to = _to;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DialogHeader(
            title: 'Guruhni almashtirish',
            subtitle: widget.profile.student.fullName,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FieldCaption(
                  _current.length > 1
                      ? 'Qaysi guruhdan o\'tadi'
                      : 'Hozirgi guruh',
                ),
                for (final g in _current) _currentCard(g, g == from),
                if (_current.isEmpty)
                  const Text(
                    'O\'quvchi hozir hech qaysi guruhda emas.',
                    style: TextStyle(color: AppColors.inkMuted),
                  ),
                const SizedBox(height: 16),
                const FieldCaption('Qaysi guruhga o\'tadi'),
                TextField(
                  key: const ValueKey('transfer-search'),
                  controller: _search,
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
                      key: ValueKey('transfer-to-${m.groupId}'),
                      group: m,
                      selected: to?.groupId == m.groupId,
                      onTap: () => _pickTo(m),
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
                if (from != null && to != null) ...<Widget>[
                  const SizedBox(height: 14),
                  _summary(from, to),
                  const SizedBox(height: 14),
                  const FieldCaption('Izoh (ixtiyoriy)'),
                  TextField(
                    key: const ValueKey('transfer-note'),
                    controller: _note,
                    decoration: const InputDecoration(
                      hintText: 'Masalan: darajasi oshdi',
                    ),
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
                          : () => Navigator.of(context).pop(),
                      child: const Text('Bekor qilish'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      key: const ValueKey('transfer-confirm'),
                      onPressed: _saving || from == null || to == null
                          ? null
                          : _confirm,
                      child: const Text('Almashtirish'),
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

  Widget _currentCard(ProfileGroup g, bool selected) {
    final choosable = _current.length > 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        key: ValueKey('transfer-from-${g.groupId}'),
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: choosable ? () => setState(() => _from = g) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSoft : AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              if (choosable) ...<Widget>[
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: selected ? AppColors.accent : AppColors.inkMuted,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  g.groupName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                g.balance > 0
                    ? 'Qarz ${CurrencyFormatter.format(g.balance)}'
                    : 'To\'langan',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: g.balance > 0
                      ? AppColors.dangerText
                      : AppColors.okText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summary(ProfileGroup from, GroupMatch to) {
    return FutureBuilder<FirstChargePreview>(
      future: _preview,
      builder: (context, snapshot) {
        final p = snapshot.data;
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${from.groupName} → ${to.name}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Yangi guruh bo\'yicha birinchi hisob (bugundan)',
                      style: TextStyle(color: AppColors.inkSecondary),
                    ),
                  ),
                  if (p == null)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Text(
                      CurrencyFormatter.format(_due(to, p)),
                      key: const ValueKey('transfer-due'),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              if (from.balance > 0) ...<Widget>[
                const Divider(height: 20, color: AppColors.divider),
                Container(
                  key: const ValueKey('transfer-old-debt'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.warnBg,
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                  child: Text(
                    'Eski guruhdan qarz: ${CurrencyFormatter.format(from.balance)}. '
                    'U o\'chmaydi — yangi guruhda birinchi to\'lov qilinguncha '
                    'o\'quvchi profilida eslatib turiladi.',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.warnText,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
