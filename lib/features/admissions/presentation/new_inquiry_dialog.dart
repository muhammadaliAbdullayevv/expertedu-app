import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/uz_phone_mask_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../auth/application/session_controller.dart';
import '../../students/presentation/heard_from.dart';
import '../../subjects/data/subjects_repository.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';

/// What "Yangi so'rov" ended with.
sealed class NewInquiryResult {
  const NewInquiryResult();
}

/// A lead was saved -- or queued offline, when [lead] is pending.
class InquiryCreated extends NewInquiryResult {
  const InquiryCreated(this.lead);

  final Lead lead;
}

/// The number already had an open lead, and the operator chose to carry
/// on with that one instead of opening a duplicate.
class InquiryOpenExisting extends NewInquiryResult {
  const InquiryOpenExisting(this.leadId);

  final int leadId;
}

/// "Yangi so'rov": the phone number first, so an existing student or open
/// lead shows up before anything is typed twice. Creates a lead only --
/// never a student or an enrollment.
Future<NewInquiryResult?> showNewInquiryDialog(BuildContext context) {
  return showAdaptiveFormDialog<NewInquiryResult>(
    context,
    child: const _NewInquiryForm(),
  );
}

class _NewInquiryForm extends ConsumerStatefulWidget {
  const _NewInquiryForm();

  @override
  ConsumerState<_NewInquiryForm> createState() => _NewInquiryFormState();
}

class _NewInquiryFormState extends ConsumerState<_NewInquiryForm> {
  final _formKey = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _parentPhone = TextEditingController();
  final _note = TextEditingController();
  final _nameFocus = FocusNode();

  late final Future<List<Subject>> _subjects = ref
      .read(admissionsRepositoryProvider)
      .subjects();
  late final Future<List<StaffUser>> _users = ref
      .read(admissionsRepositoryProvider)
      .users();

  int? _subjectId;
  String? _subjectName;
  String? _source;
  int? _assignedTo;

  PhoneLookup? _lookup;
  String? _lookedUpPhone;
  bool _lookingUp = false;
  bool _lookupOffline = false;
  Timer? _debounce;

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _assignedTo = int.tryParse(
      ref.read(sessionControllerProvider).user?.id ?? '',
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final controller in <TextEditingController>[
      _phone,
      _name,
      _parentPhone,
      _note,
    ]) {
      controller.dispose();
    }
    _nameFocus.dispose();
    super.dispose();
  }

  String get _apiPhone => UzPhoneMaskFormatter.toApi(_phone.text);

  bool get _phoneComplete =>
      UzPhoneMaskFormatter.digitsOf(_phone.text).length == 9;

  /// An open lead for the same phone and course: saving would make a
  /// duplicate, so the dialog offers that lead instead.
  Lead? get _sameCourseLead {
    final lookup = _lookup;
    if (lookup == null || _lookedUpPhone != _apiPhone) return null;
    for (final lead in lookup.openLeads) {
      if (lead.subjectId == _subjectId) return lead;
    }
    return null;
  }

  void _onPhoneChanged(String _) {
    _debounce?.cancel();
    if (!_phoneComplete) {
      setState(() {
        _lookup = null;
        _lookedUpPhone = null;
        _lookingUp = false;
        _lookupOffline = false;
      });
      return;
    }
    final phone = _apiPhone;
    setState(() => _lookingUp = true);
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final lookup = await ref
            .read(admissionsRepositoryProvider)
            .lookupPhone(phone);
        if (!mounted || _apiPhone != phone) return;
        setState(() {
          _lookup = lookup;
          _lookedUpPhone = phone;
          _lookingUp = false;
          _lookupOffline = false;
          // The person is known: fill what's known, keep what was typed.
          if (_name.text.trim().isEmpty) {
            final known =
                lookup.student?.fullName ??
                (lookup.leads.isEmpty ? null : lookup.leads.first.fullName);
            if (known != null) _name.text = known;
          }
        });
        _nameFocus.requestFocus();
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _lookingUp = false;
          _lookupOffline = e is ApiException && e.statusCode == 0;
        });
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    if (_sameCourseLead != null) return;

    final note = _note.text.trim();
    setState(() => _saving = true);
    try {
      final outcome = await ref
          .read(admissionsRepositoryProvider)
          .createLead(
            fullName: _name.text.trim(),
            phone: _apiPhone,
            parentPhone: _parentPhone.text.trim().isEmpty
                ? null
                : UzPhoneMaskFormatter.toApi(_parentPhone.text),
            subjectId: _subjectId,
            subjectName: _subjectName,
            source: _source,
            note: note.isEmpty ? null : note,
            assignedTo: _assignedTo,
          );
      if (!mounted) return;
      final lead =
          outcome.value ??
          (await ref.read(admissionsRepositoryProvider).pendingLeads()).first;
      if (!mounted) return;
      Navigator.of(context).pop(InquiryCreated(lead));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final duplicate = _sameCourseLead;
    return SubmitShortcut(
      onSubmit: _save,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const DialogHeader(
            title: 'Yangi so\'rov',
            subtitle: 'O\'quvchi emas — faqat so\'rov. Guruhga keyin yoziladi.',
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
                      controller: _phone,
                      autofocus: true,
                      keyboardType: TextInputType.phone,
                      inputFormatters: <TextInputFormatter>[
                        UzPhoneMaskFormatter(),
                      ],
                      onChanged: _onPhoneChanged,
                      decoration: InputDecoration(
                        labelText: 'Telefon',
                        prefixText: '+998 ',
                        hintText: '90 123 45 67',
                        helperText:
                            'Avval raqam — mavjud bo\'lsa, shu yerda ko\'rinadi',
                        suffixIcon: _lookingUp
                            ? const Padding(
                                padding: EdgeInsets.all(14),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
                      validator: (v) =>
                          UzPhoneMaskFormatter.digitsOf(v ?? '').length == 9
                          ? null
                          : '+998 dan keyin 9 ta raqam bo\'lishi kerak',
                    ),
                    if (_lookupOffline) ...<Widget>[
                      const SizedBox(height: 8),
                      const _Notice(
                        icon: Icons.cloud_off_rounded,
                        text:
                            'Oflayn: raqamni tekshirib bo\'lmadi. So\'rov saqlanadi va '
                            'internet qaytganda yuboriladi; bu raqamda ochiq so\'rov bo\'lsa, '
                            'unga qo\'shiladi.',
                      ),
                    ],
                    if (_lookup != null && _lookedUpPhone == _apiPhone)
                      _lookupResult(_lookup!),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _name,
                      focusNode: _nameFocus,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Ism'),
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? 'Ism kiritilishi shart'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    _subjectPicker(),
                    if (duplicate != null) ...<Widget>[
                      const SizedBox(height: 8),
                      _duplicateWarning(duplicate),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: DropdownButtonFormField<String?>(
                            initialValue: _source,
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
                            onChanged: (value) =>
                                setState(() => _source = value),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: _assigneePicker()),
                      ],
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _parentPhone,
                      keyboardType: TextInputType.phone,
                      inputFormatters: <TextInputFormatter>[
                        UzPhoneMaskFormatter(),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Ota-ona telefoni (ixtiyoriy)',
                        prefixText: '+998 ',
                      ),
                      validator: (v) {
                        final digits = UzPhoneMaskFormatter.digitsOf(v ?? '');
                        return digits.isEmpty || digits.length == 9
                            ? null
                            : '+998 dan keyin 9 ta raqam bo\'lishi kerak';
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _note,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: 'Izoh (ixtiyoriy)',
                        hintText: 'Nimani so\'radi, qachon qulay...',
                        alignLabelWithHint: true,
                      ),
                    ),
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
              children: <Widget>[
                Text(
                  'Ctrl+Enter — saqlash',
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('Bekor qilish'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving || duplicate != null ? null : _save,
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
      ),
    );
  }

  Widget _lookupResult(PhoneLookup lookup) {
    final student = lookup.student;
    final open = lookup.openLeads;
    final closedCount = lookup.leads.length - open.length;
    if (student == null && lookup.leads.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: _Notice(
          icon: Icons.person_add_alt_rounded,
          text: 'Yangi raqam — avval murojaat qilmagan.',
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (student != null)
              Text(
                'O\'quvchi: ${student.fullName} '
                '(${student.groupNames.isEmpty ? 'guruhsiz' : student.groupNames.join(', ')}) — '
                'so\'rov unga bog\'lanadi.',
                style: context.textTheme.bodyMedium,
              ),
            for (final lead in open)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Ochiq so\'rov: ${lead.fullName} · '
                        '${lead.subjectName ?? 'fan tanlanmagan'}',
                        style: context.textTheme.bodyMedium,
                      ),
                    ),
                    StageChip(lead.stage),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).pop(InquiryOpenExisting(lead.id)),
                      child: const Text('Ochish'),
                    ),
                  ],
                ),
              ),
            if (closedCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Avvalgi yopilgan so\'rovlar: $closedCount ta',
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _duplicateWarning(Lead lead) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'Bu raqam bilan shu fan bo\'yicha ochiq so\'rov bor. Yangisini '
              'ochmasdan o\'shani davom ettiring.',
              style: TextStyle(color: context.colors.error),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: () =>
                Navigator.of(context).pop(InquiryOpenExisting(lead.id)),
            child: const Text('Ochish'),
          ),
        ],
      ),
    );
  }

  Widget _subjectPicker() {
    return FutureBuilder<List<Subject>>(
      future: _subjects,
      builder: (context, snapshot) {
        final subjects = [...?snapshot.data]
          ..sort((a, b) => a.name.compareTo(b.name));
        return DropdownButtonFormField<int?>(
          initialValue: _subjectId,
          decoration: InputDecoration(
            labelText: 'Qiziqqan fan',
            errorText: snapshot.hasError ? 'Fanlarni yuklab bo\'lmadi' : null,
          ),
          items: <DropdownMenuItem<int?>>[
            const DropdownMenuItem(value: null, child: Text('Hali aniq emas')),
            for (final subject in subjects)
              DropdownMenuItem(value: subject.id, child: Text(subject.name)),
          ],
          onChanged: (value) => setState(() {
            _subjectId = value;
            _subjectName = value == null
                ? null
                : subjects.firstWhere((s) => s.id == value).name;
          }),
        );
      },
    );
  }

  Widget _assigneePicker() {
    return FutureBuilder<List<StaffUser>>(
      future: _users,
      builder: (context, snapshot) {
        final users = snapshot.data ?? const <StaffUser>[];
        final known = users.any((u) => u.id == _assignedTo);
        return DropdownButtonFormField<int?>(
          initialValue: known ? _assignedTo : null,
          decoration: const InputDecoration(labelText: 'Mas\'ul'),
          items: <DropdownMenuItem<int?>>[
            if (!known) const DropdownMenuItem(value: null, child: Text('Men')),
            for (final user in users)
              DropdownMenuItem(value: user.id, child: Text(user.fullName)),
          ],
          onChanged: (value) => setState(() => _assignedTo = value),
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: context.colors.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: context.textTheme.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
