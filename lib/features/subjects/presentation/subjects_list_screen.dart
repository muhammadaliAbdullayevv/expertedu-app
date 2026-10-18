import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/bordered_list_tile.dart';
import '../data/subjects_repository.dart';
import 'subject_groups_screen.dart';

class SubjectsListScreen extends ConsumerStatefulWidget {
  const SubjectsListScreen({super.key});

  @override
  ConsumerState<SubjectsListScreen> createState() => SubjectsListScreenState();
}

class SubjectsListScreenState extends ConsumerState<SubjectsListScreen> {
  final _searchController = TextEditingController();
  late Future<List<Subject>> _future;
  bool _searchVisible = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = ref.read(subjectsRepositoryProvider).list();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Called by the shell when the owner switches branch.
  void reload() => _reload();

  void _reload() {
    final next = ref.read(subjectsRepositoryProvider).list();
    setState(() {
      _future = next;
    });
  }

  /// Called from HomeShell's shared search icon.
  void toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchController.clear();
        _query = '';
      }
    });
  }

  /// Lets HomeShell's back-button handling close an open search first.
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
                hintText: 'Fanni qidirish...',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                filled: true,
              ),
              onChanged: (value) =>
                  setState(() => _query = value.trim().toLowerCase()),
            ),
          ),
        Expanded(
          child: FutureBuilder<List<Subject>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(child: Text('Xatolik: ${snapshot.error}'));
              }
              final subjects = (snapshot.data ?? const <Subject>[])
                  .where(
                    (s) =>
                        _query.isEmpty || s.name.toLowerCase().contains(_query),
                  )
                  .toList();
              if (subjects.isEmpty) {
                return const Center(child: Text('Hali fanlar yo\'q'));
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                ).copyWith(bottom: 88),
                itemCount: subjects.length,
                itemBuilder: (context, index) {
                  final subject = subjects[index];
                  return BorderedListTile(
                    leading: const CircleAvatar(child: Icon(Icons.menu_book)),
                    title: Text(subject.name),
                    subtitle: Text(
                      subject.groupCount == 1
                          ? '1 ta guruh'
                          : '${subject.groupCount} ta guruh',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (context) =>
                              SubjectGroupsScreen(subject: subject),
                        ),
                      );
                      _reload();
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  /// Called from HomeShell's shared FAB -- see its GlobalKey\<SubjectsListScreenState\>.
  Future<void> showCreateSheet() async {
    final context = this.context;
    final nameController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String? error;

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
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
                        'Yangi fan',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: nameController,
                        decoration: const InputDecoration(
                          labelText: 'Fan nomi (masalan: Ingliz tili)',
                        ),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                      ),
                      if (error != null) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () async {
                          if (!formKey.currentState!.validate()) return;
                          try {
                            await ref
                                .read(subjectsRepositoryProvider)
                                .create(nameController.text.trim());
                            if (context.mounted) {
                              Navigator.of(context).pop(true);
                            }
                          } catch (e) {
                            setSheetState(() => error = e.toString());
                          }
                        },
                        child: const Text('Yaratish'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (created == true) {
      _reload();
    }
  }
}
