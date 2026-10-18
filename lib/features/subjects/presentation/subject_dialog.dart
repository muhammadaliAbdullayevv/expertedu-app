import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../data/subjects_repository.dart';

/// "Yangi fan": asks for a name (Ingliz tili, Matematika, IELTS...) and makes
/// it. Subjects are shared by every branch; each group picks one. Returns the
/// new subject, or null when cancelled.
Future<Subject?> showSubjectDialog(BuildContext context) {
  return showAdaptiveFormDialog<Subject>(
    context,
    maxWidth: 440,
    child: const _SubjectForm(),
  );
}

class _SubjectForm extends ConsumerStatefulWidget {
  const _SubjectForm();

  @override
  ConsumerState<_SubjectForm> createState() => _SubjectFormState();
}

class _SubjectFormState extends ConsumerState<_SubjectForm> {
  final _name = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Fan nomini kiriting.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final subject = await ref.read(subjectsRepositoryProvider).create(name);
      if (mounted) Navigator.of(context).pop(subject);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const DialogHeader(title: 'Yangi fan'),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                key: const ValueKey('subject-name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Fan nomi',
                  hintText: 'Masalan: Ingliz tili',
                  helperText:
                      'Hamma filiallar uchun umumiy ro\'yxatga qo\'shiladi',
                ),
                onSubmitted: (_) => _save(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('subject-error'),
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
                    key: const ValueKey('subject-save'),
                    onPressed: _saving ? null : _save,
                    child: const Text('Qo\'shish'),
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
