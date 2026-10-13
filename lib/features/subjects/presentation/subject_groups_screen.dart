import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/thousands_input_formatter.dart';
import '../../../core/widgets/bordered_list_tile.dart';
import '../../groups/data/groups_repository.dart';
import '../../groups/presentation/group_detail_screen.dart';
import '../data/subjects_repository.dart';

class SubjectGroupsScreen extends ConsumerStatefulWidget {
  const SubjectGroupsScreen({super.key, required this.subject});

  final Subject subject;

  @override
  ConsumerState<SubjectGroupsScreen> createState() =>
      _SubjectGroupsScreenState();
}

class _SubjectGroupsScreenState extends ConsumerState<SubjectGroupsScreen> {
  late Future<List<Group>> _future;
  bool _searchVisible = false;
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _future = ref
        .read(groupsRepositoryProvider)
        .listBySubject(widget.subject.id);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    setState(
      () => _future = ref
          .read(groupsRepositoryProvider)
          .listBySubject(widget.subject.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.subject.name),
        actions: <Widget>[
          IconButton(
            icon: Icon(_searchVisible ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searchVisible = !_searchVisible;
              if (!_searchVisible) {
                _searchController.clear();
                _query = '';
              }
            }),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateGroupSheet(context),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: <Widget>[
          if (_searchVisible)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Guruhni qidirish...',
                  prefixIcon: Icon(Icons.search),
                  isDense: true,
                  filled: true,
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
          Expanded(
            child: FutureBuilder<List<Group>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Xatolik: ${snapshot.error}'));
                }
                final groups = (snapshot.data ?? const <Group>[])
                    .where(
                      (g) =>
                          _query.isEmpty ||
                          g.name.toLowerCase().contains(_query),
                    )
                    .toList();
                if (groups.isEmpty) {
                  return const Center(child: Text('Hali guruhlar yo\'q'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                  ).copyWith(bottom: 88),
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    final count = group.studentCount ?? 0;
                    final subtitle = [
                      CurrencyFormatter.format(group.feeAmount),
                      if (group.teacherName != null &&
                          group.teacherName!.isNotEmpty)
                        group.teacherName!,
                      count == 1 ? '1 o\'quvchi' : '$count o\'quvchi',
                    ].join(' • ');
                    return BorderedListTile(
                      leading: const CircleAvatar(child: Icon(Icons.groups)),
                      title: Text(group.name),
                      subtitle: Text(subtitle),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (context) =>
                                GroupDetailScreen(group: group),
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
      ),
    );
  }

  Future<void> _showCreateGroupSheet(BuildContext context) async {
    final nameController = TextEditingController();
    final teacherController = TextEditingController();
    final feeController = TextEditingController();
    final dueDayController = TextEditingController();
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
                    'Yangi guruh',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'Nomi (masalan: Beginner)',
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: teacherController,
                    decoration: const InputDecoration(
                      labelText: 'O\'qituvchi (ixtiyoriy)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: feeController,
                    decoration: const InputDecoration(
                      labelText: 'Oylik to\'lov (so\'m)',
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [ThousandsInputFormatter()],
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: dueDayController,
                    decoration: const InputDecoration(
                      labelText: 'To\'lov kuni (1-31)',
                    ),
                    keyboardType: TextInputType.number,
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      if (n == null || n < 1 || n > 31) {
                        return '1 dan 31 gacha bo\'lishi kerak';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () async {
                      if (!formKey.currentState!.validate()) return;
                      await ref
                          .read(groupsRepositoryProvider)
                          .create(
                            subjectId: widget.subject.id,
                            name: nameController.text,
                            teacherName: teacherController.text.trim().isEmpty
                                ? null
                                : teacherController.text.trim(),
                            feeAmount:
                                ThousandsInputFormatter.unformat(
                                  feeController.text,
                                ) ??
                                0,
                            dueDay: int.parse(dueDayController.text),
                          );
                      if (context.mounted) Navigator.of(context).pop(true);
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

    if (created == true) {
      _reload();
    }
  }
}
