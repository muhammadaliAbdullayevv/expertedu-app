import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../data/teachers_repository.dart';

/// OWNER ONLY: the same person was made twice. Pick the record that stays;
/// [teacher]'s groups, lessons and pay move over and [teacher] is archived.
/// Returns true once merged.
Future<bool?> showTeacherMergeDialog(
  BuildContext context, {
  required Teacher teacher,
}) {
  return showAdaptiveFormDialog<bool>(
    context,
    maxWidth: 480,
    child: _TeacherMergeDialog(teacher: teacher),
  );
}

class _TeacherMergeDialog extends ConsumerStatefulWidget {
  const _TeacherMergeDialog({required this.teacher});

  final Teacher teacher;

  @override
  ConsumerState<_TeacherMergeDialog> createState() =>
      _TeacherMergeDialogState();
}

class _TeacherMergeDialogState extends ConsumerState<_TeacherMergeDialog> {
  late final Future<List<Teacher>> _others = ref
      .read(teachersRepositoryProvider)
      .listEverywhere()
      .then(
        (all) => [
          for (final t in all)
            if (t.id != widget.teacher.id) t,
        ],
      );
  int? _into;
  bool _saving = false;
  String? _error;

  Future<void> _merge() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(teachersRepositoryProvider)
          .merge(widget.teacher.id, intoId: _into!);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _label(Teacher t) => <String>[
    t.fullName,
    if (t.phone != null) PhoneFormatter.display(t.phone!),
    if (t.branchNames.isNotEmpty) t.branchNames.join(', '),
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final t = widget.teacher;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DialogHeader(title: 'Birlashtirish', subtitle: t.fullName),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'Bir odam ikki marta kiritilgan bo\'lsa: qaysi yozuv qolsin?',
                style: TextStyle(color: AppColors.inkSecondary),
              ),
              const SizedBox(height: 12),
              FutureBuilder<List<Teacher>>(
                future: _others,
                builder: (context, snapshot) {
                  final others = snapshot.data;
                  if (snapshot.hasError) {
                    return Text('${snapshot.error}');
                  }
                  if (others == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return DropdownButtonFormField<int>(
                    key: const ValueKey('merge-into'),
                    isExpanded: true,
                    initialValue: _into,
                    decoration: const InputDecoration(
                      labelText: 'Qoladigan o\'qituvchi',
                    ),
                    items: <DropdownMenuItem<int>>[
                      for (final o in others)
                        DropdownMenuItem(
                          value: o.id,
                          child: Text(
                            _label(o),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _into = v),
                  );
                },
              ),
              if (_into != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${t.fullName}ning hamma guruhi, darsi va oyligi tanlangan '
                    'o\'qituvchiga o\'tadi, filiallari qo\'shiladi. ${t.fullName} '
                    'arxivga olinadi. Bu amalni qaytarib bo\'lmaydi.',
                    key: const ValueKey('merge-warning'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.inkMuted,
                    ),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    key: const ValueKey('merge-error'),
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
                    key: const ValueKey('merge-save'),
                    onPressed: _saving || _into == null ? null : _merge,
                    child: const Text('Birlashtirish'),
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
