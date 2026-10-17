import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters/thousands_input_formatter.dart';
import '../../subjects/data/subjects_repository.dart';
import '../../teachers/data/teachers_repository.dart';
import '../data/groups_repository.dart';

/// Create ([group] null) or edit a group. Returns true once saved.
Future<bool?> showGroupFormDialog(BuildContext context, {Group? group}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _GroupFormDialog(group: group),
  );
}

typedef _Options = ({List<Subject> subjects, List<Teacher> teachers});

class _GroupFormDialog extends ConsumerStatefulWidget {
  const _GroupFormDialog({this.group});

  final Group? group;

  @override
  ConsumerState<_GroupFormDialog> createState() => _GroupFormDialogState();
}

class _GroupFormDialogState extends ConsumerState<_GroupFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.group?.name);
  late final _fee = TextEditingController(
    text: widget.group == null
        ? ''
        : ThousandsInputFormatter.format(widget.group!.feeAmount),
  );
  late final _capacity = TextEditingController(
    text: widget.group?.capacity?.toString(),
  );
  late final _note = TextEditingController(text: widget.group?.note);
  late int? _subjectId = widget.group?.subjectId;
  late int? _teacherId = widget.group?.teacherId;
  late int? _dueDay = widget.group?.dueDay;
  bool _saving = false;
  String? _error;

  // Loaded fresh each time the dialog opens, so a teacher added a moment
  // ago on the O'qituvchilar tab is already in the list.
  late final Future<_Options> _options = () async {
    final results = await Future.wait(<Future<Object>>[
      ref.read(subjectsRepositoryProvider).list(),
      ref.read(teachersRepositoryProvider).list(),
    ]);
    return (
      subjects: results[0] as List<Subject>,
      teachers: results[1] as List<Teacher>,
    );
  }();

  @override
  void dispose() {
    _name.dispose();
    _fee.dispose();
    _capacity.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(groupsRepositoryProvider);
    final fee = ThousandsInputFormatter.unformat(_fee.text)!;
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    // Empty = no seat limit.
    final capacity = int.tryParse(_capacity.text.trim());
    try {
      final existing = widget.group;
      if (existing == null) {
        await repo.create(
          subjectId: _subjectId!,
          name: _name.text.trim(),
          teacherId: _teacherId,
          feeAmount: fee,
          dueDay: _dueDay!,
          capacity: capacity,
          note: note,
        );
      } else {
        await repo.update(
          existing.id,
          subjectId: _subjectId!,
          name: _name.text.trim(),
          teacherId: _teacherId,
          feeAmount: fee,
          dueDay: _dueDay!,
          capacity: capacity,
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
    final editing = widget.group != null;
    return AlertDialog(
      title: Text(editing ? 'Guruhni tahrirlash' : 'Yangi guruh'),
      content: SizedBox(
        width: 480,
        child: FutureBuilder<_Options>(
          future: _options,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text('Xatolik: ${snapshot.error}');
            }
            final options = snapshot.data!;
            return Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  TextFormField(
                    controller: _name,
                    autofocus: !editing,
                    decoration: const InputDecoration(labelText: 'Guruh nomi'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _subjectId,
                    decoration: const InputDecoration(labelText: 'Fan'),
                    items: <DropdownMenuItem<int>>[
                      for (final subject in options.subjects)
                        DropdownMenuItem(
                          value: subject.id,
                          child: Text(subject.name),
                        ),
                    ],
                    onChanged: (value) => setState(() => _subjectId = value),
                    validator: (v) => v == null ? 'Fanni tanlang' : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int?>(
                    initialValue: _teacherId,
                    decoration: const InputDecoration(labelText: 'O\'qituvchi'),
                    items: <DropdownMenuItem<int?>>[
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Tanlanmagan'),
                      ),
                      for (final teacher in options.teachers)
                        DropdownMenuItem(
                          value: teacher.id,
                          child: Text(teacher.fullName),
                        ),
                    ],
                    onChanged: (value) => setState(() => _teacherId = value),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          controller: _fee,
                          keyboardType: TextInputType.number,
                          inputFormatters: <ThousandsInputFormatter>[
                            ThousandsInputFormatter(),
                          ],
                          decoration: InputDecoration(
                            labelText: 'Oylik narx',
                            suffixText: 'so\'m',
                            // Charges already made keep their amount --
                            // only the next due day onward uses the new fee.
                            helperText: editing
                                ? 'Keyingi to\'lov kunidan qo\'llanadi'
                                : null,
                          ),
                          validator: (v) {
                            final amount = ThousandsInputFormatter.unformat(
                              v ?? '',
                            );
                            return amount == null || amount <= 0
                                ? 'Narxni kiriting'
                                : null;
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<int>(
                          initialValue: _dueDay,
                          menuMaxHeight: 320,
                          decoration: const InputDecoration(
                            labelText: 'To\'lov kuni',
                          ),
                          items: <DropdownMenuItem<int>>[
                            for (var day = 1; day <= 31; day++)
                              DropdownMenuItem(
                                value: day,
                                child: Text('$day-sana'),
                              ),
                          ],
                          onChanged: (value) => setState(() => _dueDay = value),
                          validator: (v) => v == null ? 'Tanlang' : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _capacity,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Sig\'im (ixtiyoriy)',
                      helperText: 'Bo\'sh qoldirilsa, o\'rinlar cheklanmaydi',
                    ),
                    validator: (v) {
                      final text = v?.trim() ?? '';
                      if (text.isEmpty) return null;
                      final value = int.tryParse(text);
                      return value == null || value <= 0
                          ? 'Musbat son kiriting'
                          : null;
                    },
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
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
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
