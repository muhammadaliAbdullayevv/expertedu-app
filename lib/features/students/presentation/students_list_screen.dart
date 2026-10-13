import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/uz_phone_field.dart';
import '../data/students_repository.dart';

class StudentsListScreen extends ConsumerStatefulWidget {
  const StudentsListScreen({super.key});

  @override
  ConsumerState<StudentsListScreen> createState() => _StudentsListScreenState();
}

class _StudentsListScreenState extends ConsumerState<StudentsListScreen> {
  late Future<List<Student>> _future;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = ref.read(studentsRepositoryProvider).list();
  }

  void _reload({String? query}) {
    setState(() {
      _query = query ?? _query;
      _future = ref.read(studentsRepositoryProvider).list(query: _query);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('O\'quvchilar'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Qidirish...',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                filled: true,
              ),
              onChanged: (value) => _reload(query: value),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateSheet(context),
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<Student>>(
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
            itemCount: students.length,
            itemBuilder: (context, index) {
              final student = students[index];
              return ListTile(title: Text(student.fullName), subtitle: Text(student.phone));
            },
          );
        },
      ),
    );
  }

  Future<void> _showCreateSheet(BuildContext context) async {
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
