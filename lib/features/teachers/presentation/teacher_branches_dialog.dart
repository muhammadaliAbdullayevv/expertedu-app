import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../branches/application/branch_view.dart';
import '../data/teachers_repository.dart';

/// OWNER ONLY: which branches a teacher works in (at least one). Returns true
/// once saved.
Future<bool?> showTeacherBranchesDialog(
  BuildContext context, {
  required Teacher teacher,
}) {
  return showAdaptiveFormDialog<bool>(
    context,
    maxWidth: 440,
    child: _TeacherBranchesDialog(teacher: teacher),
  );
}

class _TeacherBranchesDialog extends ConsumerStatefulWidget {
  const _TeacherBranchesDialog({required this.teacher});

  final Teacher teacher;

  @override
  ConsumerState<_TeacherBranchesDialog> createState() =>
      _TeacherBranchesDialogState();
}

class _TeacherBranchesDialogState
    extends ConsumerState<_TeacherBranchesDialog> {
  late final Set<int> _picked = {...widget.teacher.branchIds};
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_picked.isEmpty) {
      setState(() => _error = 'Kamida bitta filialni tanlang.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(teachersRepositoryProvider)
          .setBranches(widget.teacher.id, _picked.toList()..sort());
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final branches = ref.watch(branchListProvider).value ?? const [];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DialogHeader(title: 'Filiallar', subtitle: widget.teacher.fullName),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'Qaysi filiallarda dars beradi? Har bir filialning oyligi alohida hisoblanadi.',
                style: TextStyle(fontSize: 13, color: AppColors.inkSecondary),
              ),
              const SizedBox(height: 10),
              for (final b in branches)
                CheckboxListTile(
                  key: ValueKey('teacher-branch-${b.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(b.name),
                  value: _picked.contains(b.id),
                  onChanged: (on) => setState(() {
                    _error = null;
                    if (on == true) {
                      _picked.add(b.id);
                    } else {
                      _picked.remove(b.id);
                    }
                  }),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('teacher-branches-error'),
                    style: const TextStyle(color: AppColors.dangerText),
                  ),
                ),
              const SizedBox(height: 14),
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
                    key: const ValueKey('teacher-branches-save'),
                    onPressed: _saving ? null : _save,
                    child: const Text('Saqlash'),
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
