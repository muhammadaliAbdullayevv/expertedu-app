import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/thousands_input_formatter.dart';
import '../../../core/formatters/uz_phone_mask_formatter.dart';
import '../../../core/layout/breakpoints.dart';
import '../../billing/payment_methods.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../../enrollments/presentation/enroll_student_sheet.dart';
import '../../groups/data/groups_repository.dart';
import '../data/students_repository.dart';
import 'heard_from.dart';
import 'student_summary_dialog.dart';

/// "Yangi o'quvchi": a new student is always added straight into a group --
/// with the first month's charge, optional discount and first payment --
/// in one save. Centered dialog on wide layouts, full screen on phones.
/// Returns true once something was saved (a new student, or an existing
/// one added to another group from the duplicate-phone warning).
Future<bool?> showAddStudentDialog(BuildContext context) {
  final wide = isWideLayout(context);
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => wide
        ? Dialog(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 620,
                maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.9,
              ),
              child: const _AddStudentForm(),
            ),
          )
        : const Dialog.fullscreen(child: _AddStudentForm()),
  );
}

class _AddStudentForm extends ConsumerStatefulWidget {
  const _AddStudentForm();

  @override
  ConsumerState<_AddStudentForm> createState() => _AddStudentFormState();
}

class _AddStudentFormState extends ConsumerState<_AddStudentForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _discount = TextEditingController();
  final _parentPhone = TextEditingController();
  final _note = TextEditingController();
  final _payment = TextEditingController();

  late final Future<List<Group>> _groups = ref
      .read(groupsRepositoryProvider)
      .list();
  Group? _group;
  DateTime _startDate = DateUtils.dateOnly(DateTime.now());
  String _discountKind = 'amount';
  String? _heardFrom;
  String _paymentMethod = 'cash';

  // The first month's two possible charges, from the server -- shown
  // before the user picks full or prorated. Re-fetched whenever the group,
  // start date or discount changes; _previewRequest drops stale answers.
  FirstChargePreview? _preview;
  int _previewRequest = 0;
  Timer? _previewDebounce;
  String? _firstMonth;

  // Live duplicate-phone check: one student per number.
  PhoneOwner? _phoneOwner;
  bool _checkingPhone = false;
  String? _checkedPhone;
  Timer? _phoneDebounce;

  bool _submitted = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _phoneDebounce?.cancel();
    for (final controller in <TextEditingController>[
      _name,
      _phone,
      _discount,
      _parentPhone,
      _note,
      _payment,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  // --- Derived values -----------------------------------------------------

  int? get _discountValue => _discountKind == 'percent'
      ? int.tryParse(_discount.text.trim())
      : ThousandsInputFormatter.unformat(_discount.text);

  /// Null when the discount is fine (including empty).
  String? get _discountError {
    final value = _discountValue;
    if (_discount.text.trim().isEmpty || value == null) return null;
    if (_discountKind == 'percent' && value > 100) {
      return 'Chegirma 0-100% oralig\'ida bo\'lishi kerak';
    }
    final group = _group;
    if (_discountKind == 'amount' && group != null && value > group.feeAmount) {
      return 'Chegirma guruh narxidan oshmasligi kerak';
    }
    return null;
  }

  /// The discount to send -- null when empty, zero or invalid.
  ({String kind, int value})? get _validDiscount {
    final value = _discountValue;
    if (value == null || value == 0 || _discountError != null) return null;
    return (kind: _discountKind, value: value);
  }

  int _monthlyAfterDiscount(Group group) {
    final preview = _preview;
    if (preview != null) return preview.discountedFee;
    final discount = _validDiscount;
    if (discount == null) return group.feeAmount;
    return discount.kind == 'amount'
        ? group.feeAmount - discount.value
        : (group.feeAmount * (100 - discount.value) / 100).round();
  }

  static bool _isFull(Group group) =>
      group.capacity != null && (group.studentCount ?? 0) >= group.capacity!;

  static String _seats(Group group) => group.capacity == null
      ? '${group.studentCount ?? 0} o\'quvchi'
      : '${group.studentCount ?? 0}/${group.capacity}';

  // --- Server lookups -------------------------------------------------------

  void _schedulePreview({bool immediate = false}) {
    _previewDebounce?.cancel();
    final group = _group;
    if (group == null || _discountError != null) {
      setState(() => _preview = null);
      return;
    }
    _previewDebounce = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 300),
      () async {
        final request = ++_previewRequest;
        final discount = _validDiscount;
        try {
          final preview = await ref
              .read(enrollmentsRepositoryProvider)
              .previewFirstCharge(
                groupId: group.id,
                joinedAt: _startDate,
                discountKind: discount?.kind,
                discountValue: discount?.value,
              );
          if (!mounted || request != _previewRequest) return;
          setState(() {
            // A different pair of amounts means asking again.
            if (_preview?.proratedAmount != preview.proratedAmount ||
                _preview?.fullAmount != preview.fullAmount) {
              _firstMonth = null;
            }
            _preview = preview;
          });
        } catch (e) {
          if (!mounted || request != _previewRequest) return;
          setState(() {
            _preview = null;
            _error = e.toString();
          });
        }
      },
    );
  }

  void _onPhoneChanged(String text) {
    _phoneDebounce?.cancel();
    final digits = UzPhoneMaskFormatter.digitsOf(text);
    if (digits.length != 9) {
      setState(() {
        _phoneOwner = null;
        _checkedPhone = null;
        _checkingPhone = false;
      });
      return;
    }
    final phone = '998$digits';
    setState(() => _checkingPhone = true);
    _phoneDebounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final owner = await ref
            .read(studentsRepositoryProvider)
            .checkPhone(phone);
        if (!mounted || UzPhoneMaskFormatter.toApi(_phone.text) != phone) {
          return;
        }
        setState(() {
          _phoneOwner = owner;
          _checkedPhone = phone;
          _checkingPhone = false;
        });
      } catch (_) {
        // The server checks again on save -- don't block typing on this.
        if (mounted) setState(() => _checkingPhone = false);
      }
    });
  }

  // --- Actions --------------------------------------------------------------

  Future<void> _pickStartDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: today.subtract(const Duration(days: 365)),
      lastDate: today.add(const Duration(days: 180)),
      helpText: 'Boshlanish sanasi',
    );
    if (picked == null || picked == _startDate) return;
    setState(() => _startDate = picked);
    _schedulePreview(immediate: true);
  }

  Future<void> _addExistingToGroup(PhoneOwner owner) async {
    final group = _group;
    if (group == null) return;
    final enrolled = await showEnrollStudentSheet(
      context,
      groupId: group.id,
      initialStudent: Student(
        id: owner.studentId,
        fullName: owner.fullName,
        phone: owner.phone,
      ),
    );
    if (enrolled == true && mounted) Navigator.of(context).pop(true);
  }

  Future<void> _save() async {
    setState(() {
      _submitted = true;
      _error = null;
    });
    final formOk = _formKey.currentState!.validate();
    final group = _group;
    final preview = _preview;
    if (!formOk || group == null || _phoneOwner != null) return;
    if (_discountError != null || preview == null) return;
    if (preview.isMidCycle && _firstMonth == null) return;

    final payment = ThousandsInputFormatter.unformat(_payment.text) ?? 0;
    final discount = _validDiscount;
    final note = _note.text.trim();
    setState(() => _saving = true);
    try {
      await ref
          .read(studentsRepositoryProvider)
          .createWithEnrollment(
            fullName: _name.text.trim(),
            phone: UzPhoneMaskFormatter.toApi(_phone.text),
            groupId: group.id,
            joinedAt: _startDate,
            firstMonth: preview.isMidCycle ? _firstMonth! : 'prorated',
            discountKind: discount?.kind,
            discountValue: discount?.value,
            parentPhone: _parentPhone.text.trim().isEmpty
                ? null
                : UzPhoneMaskFormatter.toApi(_parentPhone.text),
            heardFrom: _heardFrom,
            note: note.isEmpty ? null : note,
            firstPaymentAmount: payment > 0 ? payment : null,
            firstPaymentMethod: payment > 0 ? _paymentMethod : null,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
      // Someone may have saved this number since the live check ran.
      final phone = UzPhoneMaskFormatter.toApi(_phone.text);
      final owner = await ref
          .read(studentsRepositoryProvider)
          .checkPhone(phone)
          .catchError((_) => null);
      if (mounted && owner != null) {
        setState(() {
          _phoneOwner = owner;
          _checkedPhone = phone;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // --- UI -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final phoneBlocked =
        _phoneOwner != null &&
        _checkedPhone == UzPhoneMaskFormatter.toApi(_phone.text);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Yangi o\'quvchi',
                  style: context.textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Yopish',
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  TextFormField(
                    controller: _name,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'F.I.Sh.'),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'F.I.Sh. kiritilishi shart'
                        : null,
                  ),
                  const SizedBox(height: 14),
                  _phoneField(
                    controller: _phone,
                    label: 'Telefon',
                    required: true,
                    onChanged: _onPhoneChanged,
                    suffix: _checkingPhone
                        ? const Padding(
                            padding: EdgeInsets.all(14),
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : null,
                  ),
                  if (phoneBlocked) ...<Widget>[
                    const SizedBox(height: 8),
                    _duplicateWarning(_phoneOwner!),
                  ],
                  const SizedBox(height: 14),
                  _groupPicker(),
                  if (_group != null) ...<Widget>[
                    const SizedBox(height: 8),
                    _groupSummary(_group!),
                  ],
                  const SizedBox(height: 14),
                  _startDateField(),
                  if (_preview != null) ...<Widget>[
                    const SizedBox(height: 8),
                    _firstMonthChoice(_preview!),
                  ],
                  const SizedBox(height: 14),
                  _discountField(),
                  const SizedBox(height: 14),
                  _phoneField(
                    controller: _parentPhone,
                    label: 'Ota-ona telefoni (ixtiyoriy)',
                    required: false,
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String?>(
                    initialValue: _heardFrom,
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
                    onChanged: (value) => setState(() => _heardFrom = value),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _note,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Izoh (ixtiyoriy)',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _firstPaymentFields(),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      style: TextStyle(color: context.colors.error),
                    ),
                  ],
                ],
              ),
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
                // A phone that already belongs to a student blocks saving
                // outright -- never a second student with the same number.
                onPressed: _saving || phoneBlocked ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Saqlash'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _phoneField({
    required TextEditingController controller,
    required String label,
    required bool required,
    ValueChanged<String>? onChanged,
    Widget? suffix,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: TextInputType.phone,
      inputFormatters: <TextInputFormatter>[UzPhoneMaskFormatter()],
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        prefixText: '+998 ',
        hintText: '90 123 45 67',
        suffixIcon: suffix,
      ),
      validator: (v) {
        final digits = UzPhoneMaskFormatter.digitsOf(v ?? '');
        if (digits.isEmpty) {
          return required ? 'Telefon kiritilishi shart' : null;
        }
        return digits.length == 9
            ? null
            : '+998 dan keyin 9 ta raqam bo\'lishi kerak';
      },
    );
  }

  Widget _duplicateWarning(PhoneOwner owner) {
    final groups = owner.groupNames.isEmpty
        ? 'guruhsiz'
        : owner.groupNames.join(', ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.colors.error.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Bu raqam allaqachon mavjud: ${owner.fullName} ($groups)',
            style: TextStyle(
              color: context.colors.error,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OutlinedButton(
                onPressed: () =>
                    showStudentSummaryDialog(context, owner.studentId),
                child: const Text('Ochish'),
              ),
              FilledButton.tonal(
                // The enroll sheet adds to one group -- the one picked below.
                onPressed: _group == null
                    ? null
                    : () => _addExistingToGroup(owner),
                child: const Text('Boshqa guruhga qo\'shish'),
              ),
              if (_group == null)
                Text(
                  'Avval quyida guruhni tanlang',
                  style: context.textTheme.bodySmall,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _groupPicker() {
    return FutureBuilder<List<Group>>(
      future: _groups,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Text('Guruhlarni yuklab bo\'lmadi: ${snapshot.error}');
        }
        final groups = [...?snapshot.data]
          ..sort((a, b) => a.name.compareTo(b.name));
        return DropdownMenu<int>(
          expandedInsets: EdgeInsets.zero,
          enabled: snapshot.hasData,
          label: const Text('Guruh'),
          hintText: 'Nomi, fan yoki o\'qituvchi bo\'yicha qidiring',
          leadingIcon: const Icon(Icons.search),
          enableFilter: true,
          requestFocusOnTap: true,
          menuHeight: 340,
          errorText: _submitted && _group == null ? 'Guruhni tanlang' : null,
          onSelected: (id) {
            if (id == null) return;
            setState(() {
              _group = groups.firstWhere((g) => g.id == id);
              _preview = null;
              _firstMonth = null;
            });
            _schedulePreview(immediate: true);
          },
          dropdownMenuEntries: <DropdownMenuEntry<int>>[
            for (final group in groups)
              DropdownMenuEntry<int>(
                value: group.id,
                // What the filter searches and the field shows once picked.
                label: [
                  group.name,
                  group.teacherName,
                  group.subjectName,
                ].whereType<String>().join(' · '),
                enabled: !_isFull(group),
                labelWidget: _GroupOption(
                  group: group,
                  seats: _seats(group),
                  full: _isFull(group),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _groupSummary(Group group) {
    final monthly = _monthlyAfterDiscount(group);
    final style = context.textTheme.bodyMedium;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: context.colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.colors.outlineVariant),
      ),
      child: Text.rich(
        TextSpan(
          style: style,
          children: <InlineSpan>[
            const TextSpan(text: 'Oylik: '),
            // Old price struck through, then the discounted one -- no arrow
            // glyph, which the bundled fonts don't all have.
            if (monthly != group.feeAmount) ...<InlineSpan>[
              TextSpan(
                text: CurrencyFormatter.format(group.feeAmount),
                style: TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const TextSpan(text: ' '),
            ],
            TextSpan(
              text: CurrencyFormatter.format(monthly),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (monthly != group.feeAmount)
              const TextSpan(text: ' (chegirma bilan)'),
            TextSpan(text: ' · To\'lov kuni: har oy ${group.dueDay}-sana'),
            TextSpan(
              text: ' · O\'qituvchi: ${group.teacherName ?? 'tanlanmagan'}',
            ),
          ],
        ),
      ),
    );
  }

  Widget _startDateField() {
    return InkWell(
      onTap: _pickStartDate,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Boshlanish sanasi',
          suffixIcon: Icon(Icons.calendar_today_outlined, size: 20),
        ),
        child: Text(DateFormatters.date(_startDate)),
      ),
    );
  }

  /// "Birinchi oy: to'liq yoki proporsional?" -- only asked when the start
  /// date falls inside a payment cycle that has already begun.
  Widget _firstMonthChoice(FirstChargePreview preview) {
    if (!preview.isMidCycle) {
      return Text(
        'Birinchi oy: ${CurrencyFormatter.format(preview.fullAmount)} '
        '(to\'lov kunidan boshlanadi)',
        style: context.textTheme.bodySmall?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      );
    }
    final missing = _submitted && _firstMonth == null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: missing ? context.colors.error : context.colors.outlineVariant,
        ),
      ),
      child: RadioGroup<String>(
        groupValue: _firstMonth,
        onChanged: (value) => setState(() => _firstMonth = value),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Birinchi oy: to\'liq yoki proporsional?',
              style: context.textTheme.titleSmall,
            ),
            const SizedBox(height: 2),
            Text(
              'Keyingi to\'lov kuni: ${DateFormatters.date(preview.periodEnd)}',
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            RadioListTile<String>(
              value: 'prorated',
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Proporsional: ${CurrencyFormatter.format(preview.proratedAmount)}',
              ),
              subtitle: Text(
                '${preview.daysLeft} kun / ${preview.daysInPeriod} kun '
                '(${DateFormatters.date(_startDate)} – '
                '${DateFormatters.date(preview.periodEnd)})',
              ),
            ),
            RadioListTile<String>(
              value: 'full',
              contentPadding: EdgeInsets.zero,
              title: Text(
                'To\'liq oy: ${CurrencyFormatter.format(preview.fullAmount)}',
              ),
            ),
            if (missing)
              Text(
                'Birinchi oy uchun birini tanlang',
                style: TextStyle(color: context.colors.error, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  Widget _discountField() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextFormField(
            controller: _discount,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              if (_discountKind == 'amount')
                ThousandsInputFormatter()
              else ...<TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
            ],
            decoration: InputDecoration(
              labelText: 'Chegirma (ixtiyoriy)',
              suffixText: _discountKind == 'amount' ? 'so\'m' : '%',
              errorText: _discountError,
            ),
            onChanged: (_) {
              setState(() {});
              _schedulePreview();
            },
          ),
        ),
        const SizedBox(width: 12),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SegmentedButton<String>(
            segments: const <ButtonSegment<String>>[
              ButtonSegment(value: 'amount', label: Text('so\'m')),
              ButtonSegment(value: 'percent', label: Text('%')),
            ],
            selected: <String>{_discountKind},
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              setState(() {
                _discountKind = selection.first;
                _discount.clear();
              });
              _schedulePreview(immediate: true);
            },
          ),
        ),
      ],
    );
  }

  Widget _firstPaymentFields() {
    final amount = ThousandsInputFormatter.unformat(_payment.text) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextFormField(
          controller: _payment,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[ThousandsInputFormatter()],
          decoration: const InputDecoration(
            labelText: 'Birinchi to\'lov (ixtiyoriy)',
            suffixText: 'so\'m',
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (amount > 0) ...<Widget>[
          const SizedBox(height: 10),
          SegmentedButton<String>(
            segments: <ButtonSegment<String>>[
              for (final entry in paymentMethodLabels.entries)
                ButtonSegment(value: entry.key, label: Text(entry.value)),
            ],
            selected: <String>{_paymentMethod},
            onSelectionChanged: (selection) =>
                setState(() => _paymentMethod = selection.first),
          ),
        ],
      ],
    );
  }
}

/// One row in the group dropdown: name, teacher and price on the left,
/// free seats (or "To'lgan") on the right.
class _GroupOption extends StatelessWidget {
  const _GroupOption({
    required this.group,
    required this.seats,
    required this.full,
  });

  final Group group;
  final String seats;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                group.name,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '${group.teacherName ?? 'O\'qituvchi tanlanmagan'} · '
                '${CurrencyFormatter.format(group.feeAmount)}',
                style: muted,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (full)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: context.colors.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'To\'lgan · $seats',
              style: TextStyle(color: context.colors.error, fontSize: 12),
            ),
          )
        else
          Text(seats, style: muted),
      ],
    );
  }
}
