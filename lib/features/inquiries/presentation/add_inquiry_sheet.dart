import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/uz_phone_field.dart';
import '../../subjects/data/subjects_repository.dart';
import '../data/inquiries_repository.dart';

/// Returns true if an inquiry was logged.
Future<bool?> showAddInquirySheet(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => const _AddInquirySheet(),
  );
}

class _AddInquirySheet extends ConsumerStatefulWidget {
  const _AddInquirySheet();

  @override
  ConsumerState<_AddInquirySheet> createState() => _AddInquirySheetState();
}

class _AddInquirySheetState extends ConsumerState<_AddInquirySheet> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _noteController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  late Future<List<Subject>> _subjectsFuture;
  int? _selectedSubjectId;
  DateTime? _trialDate;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subjectsFuture = ref.read(subjectsRepositoryProvider).list();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Qo\'ng\'iroqni yozib qo\'yish',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'F.I.Sh.'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
              ),
              const SizedBox(height: 12),
              UzPhoneField(
                controller: _phoneController,
                labelText: 'Telefon',
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
              ),
              const SizedBox(height: 12),
              FutureBuilder<List<Subject>>(
                future: _subjectsFuture,
                builder: (context, snapshot) {
                  final subjects = snapshot.data ?? const <Subject>[];
                  return DropdownButtonFormField<int>(
                    initialValue: _selectedSubjectId,
                    decoration: const InputDecoration(
                      labelText: 'Qaysi fanga qiziqdi (ixtiyoriy)',
                    ),
                    items: subjects
                        .map(
                          (s) => DropdownMenuItem(
                            value: s.id,
                            child: Text(s.name),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _selectedSubjectId = value),
                  );
                },
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _trialDate ?? DateTime.now(),
                    firstDate: DateTime.now().subtract(const Duration(days: 1)),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setState(() => _trialDate = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Sinov darsi sanasi (ixtiyoriy)',
                  ),
                  child: Text(
                    _trialDate == null
                        ? 'Tanlanmagan'
                        : '${_trialDate!.day}.${_trialDate!.month}.${_trialDate!.year}',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _noteController,
                decoration: const InputDecoration(
                  labelText: 'Izoh (ixtiyoriy)',
                ),
                maxLines: 2,
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Saqlash'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(inquiriesRepositoryProvider)
          .create(
            fullName: _nameController.text,
            phone: UzPhoneField.toE164(_phoneController.text),
            note: _noteController.text.trim().isEmpty
                ? null
                : _noteController.text.trim(),
            subjectId: _selectedSubjectId,
            trialDate: _trialDate,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
