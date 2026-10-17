import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/uz_phone_field.dart';
import '../data/teachers_repository.dart';

/// Create ([teacher] null) or edit a teacher. Returns true once saved.
Future<bool?> showTeacherFormDialog(BuildContext context, {Teacher? teacher}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _TeacherFormDialog(teacher: teacher),
  );
}

class _TeacherFormDialog extends ConsumerStatefulWidget {
  const _TeacherFormDialog({this.teacher});

  final Teacher? teacher;

  @override
  ConsumerState<_TeacherFormDialog> createState() => _TeacherFormDialogState();
}

class _TeacherFormDialogState extends ConsumerState<_TeacherFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.teacher?.fullName);
  late final _phone = TextEditingController(
    text: UzPhoneField.stripPrefix(widget.teacher?.phone),
  );
  late final _note = TextEditingController(text: widget.teacher?.note);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(teachersRepositoryProvider);
    final phone = _phone.text.trim().isEmpty
        ? null
        : UzPhoneField.toE164(_phone.text);
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    try {
      final existing = widget.teacher;
      if (existing == null) {
        await repo.create(
          fullName: _name.text.trim(),
          phone: phone,
          note: note,
        );
      } else {
        await repo.update(
          existing.id,
          fullName: _name.text.trim(),
          phone: phone,
          note: note,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.teacher == null
            ? 'Yangi o\'qituvchi'
            : 'O\'qituvchini tahrirlash',
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'F.I.Sh.'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
              ),
              const SizedBox(height: 12),
              UzPhoneField(
                controller: _phone,
                labelText: 'Telefon (ixtiyoriy)',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                decoration: const InputDecoration(
                  labelText: 'Izoh (ixtiyoriy)',
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Bekor qilish'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Saqlash'),
        ),
      ],
    );
  }
}
