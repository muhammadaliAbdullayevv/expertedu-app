import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/bordered_list_tile.dart';
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
  bool _searchVisible = false;
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

  /// Called from HomeShell's shared search icon.
  void toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchController.clear();
        _reload(query: '');
      }
    });
  }

  /// True (and search cleared) if there was something to clear -- lets
  /// HomeShell's back-button handling behave like the shop app's.
  bool clearSearchIfActive() {
    if (!_searchVisible) return false;
    toggleSearch();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        if (_searchVisible)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              autofocus: true,
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
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                ).copyWith(bottom: 88),
                itemCount: students.length,
                itemBuilder: (context, index) {
                  final student = students[index];
                  final owesMoney = student.balance > 0;
                  return BorderedListTile(
                    leading: CircleAvatar(
                      backgroundColor: owesMoney
                          ? Theme.of(context).colorScheme.errorContainer
                          : Colors.green.withValues(alpha: 0.15),
                      child: Icon(
                        Icons.school,
                        color: owesMoney
                            ? Theme.of(context).colorScheme.error
                            : Colors.green,
                      ),
                    ),
                    title: Text(student.fullName),
                    subtitle: Text(student.phone),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Icon(
                          owesMoney
                              ? Icons.error_outline
                              : Icons.check_circle_outline,
                          size: 18,
                          color: owesMoney
                              ? Theme.of(context).colorScheme.error
                              : Colors.green,
                        ),
                        if (owesMoney)
                          Text(
                            CurrencyFormatter.format(student.balance),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
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
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Yangi o\'quvchi',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'F.I.Sh.'),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                  ),
                  const SizedBox(height: 12),
                  UzPhoneField(
                    controller: phoneController,
                    labelText: 'Telefon',
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () async {
                      if (!formKey.currentState!.validate()) return;
                      await ref
                          .read(studentsRepositoryProvider)
                          .create(
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
          ),
        );
      },
    );

    if (created == true) {
      _reload();
    }
  }
}
