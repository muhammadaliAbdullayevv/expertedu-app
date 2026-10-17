import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../students/data/students_repository.dart';
import '../data/enrollments_repository.dart';

/// Returns true if a student was enrolled. [initialStudent] starts with
/// that student already picked -- the add dialog's "Boshqa guruhga
/// qo'shish" for a phone number that already belongs to someone.
Future<bool?> showEnrollStudentSheet(
  BuildContext context, {
  required int groupId,
  Student? initialStudent,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) =>
        _EnrollStudentSheet(groupId: groupId, initialStudent: initialStudent),
  );
}

class _EnrollStudentSheet extends ConsumerStatefulWidget {
  const _EnrollStudentSheet({required this.groupId, this.initialStudent});

  final int groupId;
  final Student? initialStudent;

  @override
  ConsumerState<_EnrollStudentSheet> createState() =>
      _EnrollStudentSheetState();
}

class _EnrollStudentSheetState extends ConsumerState<_EnrollStudentSheet> {
  final _searchController = TextEditingController();
  late Future<List<Student>> _future;
  Student? _selected;
  String? _error;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialStudent;
    if (initial != null) {
      _selected = initial;
      _searchController.text = initial.phone;
    }
    _future = ref.read(studentsRepositoryProvider).list(query: initial?.phone);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _search(String query) {
    setState(
      () => _future = ref.read(studentsRepositoryProvider).list(query: query),
    );
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'O\'quvchi qo\'shish',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                hintText: 'Qidirish...',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: FutureBuilder<List<Student>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final students = snapshot.data ?? const <Student>[];
                  if (students.isEmpty) {
                    return const Center(child: Text('Topilmadi'));
                  }
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: students.length,
                    itemBuilder: (context, index) {
                      final student = students[index];
                      final selected = _selected?.id == student.id;
                      return ListTile(
                        selected: selected,
                        leading: Icon(
                          selected ? Icons.check_circle : Icons.circle_outlined,
                        ),
                        title: Text(student.fullName),
                        subtitle: Text(student.phone),
                        onTap: () => setState(() => _selected = student),
                      );
                    },
                  );
                },
              ),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _selected == null || _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Qo\'shish'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref
          .read(enrollmentsRepositoryProvider)
          .create(
            studentId: _selected!.id,
            groupId: widget.groupId,
            joinedAt: DateTime.now(),
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
