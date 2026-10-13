import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/uz_phone_field.dart';
import '../data/students_repository.dart';

class StudentsListScreen extends ConsumerStatefulWidget {
  const StudentsListScreen({super.key});

  @override
  ConsumerState<StudentsListScreen> createState() => StudentsListScreenState();
}

class StudentsListScreenState extends ConsumerState<StudentsListScreen> {
  final _searchController = TextEditingController();
  late Future<List<Student>> _future;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = ref.read(studentsRepositoryProvider).list();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _reload({String? query}) {
    setState(() {
      _query = query ?? _query;
      _future = ref.read(studentsRepositoryProvider).list(query: _query);
    });
  }

  /// True (and search cleared) if there was something to clear -- lets
  /// HomeShell's back-button handling behave like the shop app's.
  bool clearSearchIfActive() {
    if (_searchController.text.isEmpty) return false;
    _searchController.clear();
    _reload(query: '');
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: 'Qidirish...',
              prefixIcon: Icon(Icons.search),
              isDense: true,
              filled: true,
            ),
            onChanged: (value) => _reload(query: value),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Student>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('Xatolik: ${snapshot.error}'));
              }
              final students = snapshot.data ?? const <Student>[];
              if (students.isEmpty) {
                return const Center(child: Text('Hali o\'quvchilar yo\'q'));
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: students.length,
                itemBuilder: (context, index) {
                  final student = students[index];
                  return ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.school)),
                    title: Text(student.fullName),
                    subtitle: Text(student.phone),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// Called from HomeShell's shared FAB -- see its GlobalKey\<StudentsListScreenState\>.
  Future<void> showCreateSheet() async {
    final context = this.context;
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Yangi o\'quvchi', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'F.I.Sh.'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                ),
                const SizedBox(height: 12),
                UzPhoneField(
                  controller: phoneController,
                  labelText: 'Telefon',
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    await ref.read(studentsRepositoryProvider).create(
                      fullName: nameController.text,
                      phone: UzPhoneField.toE164(phoneController.text),
                    );
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
                  child: const Text('Qo\'shish'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (created == true) {
      _reload();
    }
  }
}
