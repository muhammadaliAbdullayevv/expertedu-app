import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/widgets/bordered_list_tile.dart';
import '../../../core/widgets/table_card.dart';
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

  void _reload() {
    setState(() => _future = ref.read(subjectsRepositoryProvider).list());
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
        if (_searchVisible && !isWideLayout(context))
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
                return _LoadFailed(onRetry: _reload);
              }
              final subjects = (snapshot.data ?? const <Subject>[])
                  .where(
                    (s) =>
                        _query.isEmpty || s.name.toLowerCase().contains(_query),
                  )
                  .toList();
              if (isWideLayout(context)) {
                return _desktopDirectory(context, subjects);
              }
              if (subjects.isEmpty) {
                return Center(
                  child: Text(
                    _query.isEmpty ? 'Hali fanlar yo\'q' : 'Mos fan topilmadi',
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
                    onTap: () => _openSubject(subject),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _openSubject(Subject subject) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => SubjectGroupsScreen(subject: subject),
      ),
    );
    _reload();
  }

  Widget _desktopDirectory(BuildContext context, List<Subject> subjects) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Fan yo\'nalishlari',
                      style: context.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Har bir yo\'nalishdagi guruhlarni boshqaring',
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: context.colors.outlineVariant),
                ),
                child: Text(
                  '${subjects.length} ta fan',
                  style: context.textTheme.labelLarge,
                ),
              ),
            ],
          ),
          if (_searchVisible) ...<Widget>[
            const SizedBox(height: 16),
            SizedBox(
              width: 360,
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Fan nomi bo\'yicha qidirish',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  suffixIcon: IconButton(
                    tooltip: 'Tozalash',
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                    icon: const Icon(Icons.close),
                  ),
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: TableCard(
              emptyText: _query.isEmpty
                  ? 'Hali fanlar yo\'q. "Yangi fan" orqali yo\'nalish qo\'shing.'
                  : 'Mos fan topilmadi',
              columns: const <TableColumn>[
                TableColumn('Fan yo\'nalishi', flex: 5),
                TableColumn('Guruhlar', flex: 2, alignEnd: true),
                TableColumn('', width: 32),
              ],
              rowCount: subjects.length,
              onRowTap: (row) => _openSubject(subjects[row]),
              cell: (context, row, column) {
                final subject = subjects[row];
                return switch (column) {
                  0 => Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: context.colors.primaryContainer,
                        foregroundColor: context.colors.primary,
                        child: const Icon(Icons.menu_book_rounded, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          subject.name,
                          overflow: TextOverflow.ellipsis,
                          style: context.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  1 => Text(
                    '${subject.groupCount}',
                    textAlign: TextAlign.end,
                    style: context.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  _ => Icon(
                    Icons.chevron_right_rounded,
                    color: context.colors.outline,
                  ),
                };
              },
            ),
          ),
        ],
      ),
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

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.cloud_off_outlined,
            size: 36,
            color: context.colors.outline,
          ),
          const SizedBox(height: 12),
          const Text('Fanlarni yuklab bo\'lmadi'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Qayta urinish'),
          ),
        ],
      ),
    );
  }
}
