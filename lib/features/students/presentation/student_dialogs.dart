import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/formatters/thousands_input_formatter.dart';
import '../../../core/formatters/uz_phone_mask_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../admissions/presentation/qabul_widgets.dart';
import '../../billing/data/transactions_repository.dart';
import '../data/student_models.dart';
import '../data/students_repository.dart';
import 'student_text.dart';

const _methods = <(String, String)>[
  ('cash', 'Naqd'),
  ('card', 'Karta'),
  ('click_payme', 'Click / Payme'),
];

/// "To'lov qabul qilish" -- only here, on the student's profile. Returns true
/// once a payment was recorded.
Future<bool?> showPaymentDialog(
  BuildContext context, {
  required StudentProfileData profile,
  int? enrollmentId,
}) {
  return showAdaptiveFormDialog<bool>(
    context,
    maxWidth: 480,
    child: PaymentDialog(profile: profile, enrollmentId: enrollmentId),
  );
}

class PaymentDialog extends ConsumerStatefulWidget {
  const PaymentDialog({super.key, required this.profile, this.enrollmentId});

  final StudentProfileData profile;

  /// Which group to start on; defaults to the one with the largest debt.
  final int? enrollmentId;

  @override
  ConsumerState<PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<PaymentDialog> {
  late final List<ProfileGroup> _groups = widget.profile.activeGroups;
  late ProfileGroup? _group = _initialGroup();
  late final _amount = TextEditingController();
  final _note = TextEditingController();
  String _method = 'cash';
  bool _saving = false;
  String? _error;

  ProfileGroup? _initialGroup() {
    if (_groups.isEmpty) return null;
    final wanted = widget.enrollmentId;
    if (wanted != null) {
      final match = _groups.where((g) => g.enrollmentId == wanted);
      if (match.isNotEmpty) return match.first;
    }
    return ([..._groups]..sort((a, b) => b.balance.compareTo(a.balance))).first;
  }

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  void _prefill() {
    final owed = _group?.balance ?? 0;
    _amount.text = owed > 0 ? ThousandsInputFormatter.format(owed) : '';
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final group = _group;
    final amount = ThousandsInputFormatter.unformat(_amount.text);
    if (group == null) return;
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Summani kiriting.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(transactionsRepositoryProvider)
          .recordPayment(
            enrollmentId: group.enrollmentId,
            amount: amount,
            method: _method,
            note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DialogHeader(
            title: 'To\'lov qabul qilish',
            subtitle: widget.profile.student.fullName,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: group == null
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'O\'quvchi hech qaysi guruhda emas: to\'lov qabul qilib bo\'lmaydi.',
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (_groups.length > 1)
                        DropdownButtonFormField<int>(
                          key: const ValueKey('payment-group'),
                          initialValue: group.enrollmentId,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Qaysi guruh uchun',
                          ),
                          items: <DropdownMenuItem<int>>[
                            for (final g in _groups)
                              DropdownMenuItem(
                                value: g.enrollmentId,
                                child: Text(
                                  '${g.groupName}  ·  '
                                  '${g.balance > 0 ? 'qarz ${CurrencyFormatter.format(g.balance)}' : 'qarzi yo\'q'}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (id) {
                            if (id == null) return;
                            setState(() {
                              _group = _groups.firstWhere(
                                (g) => g.enrollmentId == id,
                              );
                              _prefill();
                            });
                          },
                        )
                      else
                        Text(
                          group.groupName,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const ValueKey('payment-amount'),
                        controller: _amount,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        inputFormatters: <TextInputFormatter>[
                          ThousandsInputFormatter(),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Summa (so\'m)',
                          helperText: group.balance > 0
                              ? 'Qarz: ${CurrencyFormatter.format(group.balance)}'
                              : null,
                        ),
                        onSubmitted: (_) => _save(),
                      ),
                      const SizedBox(height: 14),
                      const FieldCaption('To\'lov usuli'),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final (value, label) in _methods)
                            OptionPill(
                              label,
                              key: ValueKey('method-$value'),
                              focusable: false,
                              selected: _method == value,
                              onTap: () => setState(() => _method = value),
                            ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _note,
                        decoration: const InputDecoration(
                          labelText: 'Izoh (ixtiyoriy)',
                        ),
                      ),
                    ],
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.dangerText),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Bekor qilish'),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  key: const ValueKey('payment-save'),
                  onPressed: _saving || group == null ? null : _save,
                  child: const Text('Saqlash'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Bekor qilish" on a payment -- asks for the reason, then cancels. The
/// payment stays on record, marked cancelled. Returns true once cancelled.
Future<bool?> showCancelPaymentDialog(
  BuildContext context, {
  required ProfilePayment payment,
}) {
  return showAdaptiveFormDialog<bool>(
    context,
    maxWidth: 460,
    child: CancelPaymentDialog(payment: payment),
  );
}

class CancelPaymentDialog extends ConsumerStatefulWidget {
  const CancelPaymentDialog({super.key, required this.payment});

  final ProfilePayment payment;

  @override
  ConsumerState<CancelPaymentDialog> createState() =>
      _CancelPaymentDialogState();
}

class _CancelPaymentDialogState extends ConsumerState<CancelPaymentDialog> {
  final _reason = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _cancel() async {
    final reason = _reason.text.trim();
    if (reason.isEmpty) {
      setState(() => _error = 'Sababini yozing.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(transactionsRepositoryProvider)
          .cancelPayment(widget.payment.id, reason);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DialogHeader(
          title: 'To\'lovni bekor qilish',
          subtitle:
              '${CurrencyFormatter.format(p.amount)} · ${methodLabel(p.method)}'
              '${p.groupName == null ? '' : ' · ${p.groupName}'}',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const InfoBox(
                'To\'lov o\'chirilmaydi: u "Bekor qilingan" deb qoladi, '
                'qarz esa qaytadan hisoblanadi.',
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('cancel-reason'),
                controller: _reason,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Bekor qilish sababi',
                  errorText: _error,
                ),
                onSubmitted: (_) => _cancel(),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Yopish'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    key: const ValueKey('cancel-confirm'),
                    onPressed: _saving ? null : _cancel,
                    child: const Text('Bekor qilish'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Tahrirlash": name, phone, parent phone, address, note. Returns the saved
/// student, or null if closed.
Future<Student?> showEditStudentDialog(
  BuildContext context, {
  required Student student,
}) {
  return showAdaptiveFormDialog<Student>(
    context,
    maxWidth: 520,
    child: EditStudentDialog(student: student),
  );
}

class EditStudentDialog extends ConsumerStatefulWidget {
  const EditStudentDialog({super.key, required this.student});

  final Student student;

  @override
  ConsumerState<EditStudentDialog> createState() => _EditStudentDialogState();
}

class _EditStudentDialogState extends ConsumerState<EditStudentDialog> {
  late final _name = TextEditingController(text: widget.student.fullName);
  late final _phone = TextEditingController(
    text: UzPhoneMaskFormatter.format(
      UzPhoneMaskFormatter.digitsOf(widget.student.phone),
    ),
  );
  late final _parent = TextEditingController(
    text: UzPhoneMaskFormatter.format(
      UzPhoneMaskFormatter.digitsOf(widget.student.parentPhone ?? ''),
    ),
  );
  late final _address = TextEditingController(
    text: widget.student.address ?? '',
  );
  late final _note = TextEditingController(text: widget.student.note ?? '');
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_name, _phone, _parent, _address, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Only what changed goes to the server.
  Map<String, dynamic> _changes() {
    final s = widget.student;
    final phoneDigits = UzPhoneMaskFormatter.digitsOf(_phone.text);
    final parentDigits = UzPhoneMaskFormatter.digitsOf(_parent.text);
    final changes = <String, dynamic>{};
    if (_name.text.trim() != s.fullName) {
      changes['full_name'] = _name.text.trim();
    }
    if ('998$phoneDigits' != s.phone) changes['phone'] = '998$phoneDigits';
    final parent = parentDigits.isEmpty ? '' : '998$parentDigits';
    if (parent != (s.parentPhone ?? '')) changes['parent_phone'] = parent;
    if (_address.text.trim() != (s.address ?? '')) {
      changes['address'] = _address.text.trim();
    }
    if (_note.text.trim() != (s.note ?? '')) {
      changes['note'] = _note.text.trim();
    }
    return changes;
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Ism va familiyani kiriting.');
      return;
    }
    if (UzPhoneMaskFormatter.digitsOf(_phone.text).length != 9) {
      setState(() => _error = 'Telefon to\'liq emas.');
      return;
    }
    final parentDigits = UzPhoneMaskFormatter.digitsOf(_parent.text);
    if (parentDigits.isNotEmpty && parentDigits.length != 9) {
      setState(() => _error = 'Ota-ona telefoni to\'liq emas.');
      return;
    }
    final changes = _changes();
    if (changes.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref
          .read(studentsRepositoryProvider)
          .update(widget.student.id, changes);
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _phoneField(String key, String label, TextEditingController c) =>
      TextField(
        key: ValueKey(key),
        controller: c,
        keyboardType: TextInputType.phone,
        inputFormatters: [UzPhoneMaskFormatter()],
        decoration: InputDecoration(
          labelText: label,
          prefixText: '+998 ',
          hintText: '90 123 45 67',
        ),
      );

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DialogHeader(
            title: 'Profilni tahrirlash',
            subtitle: PhoneFormatter.display(widget.student.phone),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                TextField(
                  key: const ValueKey('edit-name'),
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Ism va familiya',
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: _phoneField('edit-phone', 'Telefon', _phone),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _phoneField(
                        'edit-parent-phone',
                        'Ota-ona telefoni',
                        _parent,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('edit-address'),
                  controller: _address,
                  decoration: const InputDecoration(labelText: 'Manzil'),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const ValueKey('edit-note'),
                  controller: _note,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Izoh'),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _error!,
                      key: const ValueKey('edit-error'),
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
                      key: const ValueKey('edit-save'),
                      onPressed: _saving ? null : _save,
                      child: const Text('Saqlash'),
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
