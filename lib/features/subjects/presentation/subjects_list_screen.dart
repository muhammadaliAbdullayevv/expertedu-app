import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/bordered_list_tile.dart';
import '../data/subjects_repository.dart';
import 'subject_dialog.dart';
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
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 4),
          child: Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Fanlar hamma filiallar uchun umumiy; guruhlar esa har filialda alohida.',
                  style: TextStyle(color: AppColors.inkMuted),
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('new-subject'),
                onPressed: showCreateSheet,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Yangi fan'),
              ),
            ],
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
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _query.isEmpty
                            ? 'Hali fanlar yo\'q. Guruh ochish uchun avval fan qo\'shing.'
                            : 'Mos keladigan fan topilmadi',
                        key: const ValueKey('no-subjects'),
                      ),
                      if (_query.isEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          key: const ValueKey('new-subject-empty'),
                          onPressed: showCreateSheet,
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Yangi fan'),
                        ),
                      ],
                    ],
                  ),
                );
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

  /// "Yangi fan" (the button here, and the phone's shared + button).
  Future<void> showCreateSheet() async {
    final created = await showSubjectDialog(context);
    if (created != null && mounted) _reload();
  }
}
