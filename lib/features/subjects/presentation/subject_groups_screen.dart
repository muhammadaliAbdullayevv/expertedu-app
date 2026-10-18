import '../../branches/application/branch_view.dart';
import '../../branches/presentation/choose_branch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/bordered_list_tile.dart';
import '../../groups/data/groups_repository.dart';
import '../../groups/presentation/group_detail_screen.dart';
import '../../groups/presentation/group_form_dialog.dart';
import '../../groups/presentation/groups_breadcrumb.dart';
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
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateGroupSheet(context),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: <Widget>[
          // Where you are inside Guruhlar -- the course is shown, the sidebar stays.
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 0, 24, 8),
            child: Row(
              children: <Widget>[
                Expanded(child: GroupsBreadcrumb(course: widget.subject.name)),
                IconButton(
                  tooltip: 'Qidirish',
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
          ),
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
                      if (ref.watch(showBranchLabelsProvider) &&
                          group.branchName != null)
                        group.branchName!,
                    ].join(' • ');
                    return BorderedListTile(
                      leading: const CircleAvatar(child: Icon(Icons.groups)),
                      title: Text(group.name),
                      subtitle: Text(subtitle),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (context) => GroupDetailScreen(
                              group: group,
                              courseName: widget.subject.name,
                            ),
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

  /// The same full form as Sozlamalar -> Guruhlar, with this course already
  /// chosen.
  Future<void> _showCreateGroupSheet(BuildContext context) async {
    if (!await ensureBranchChosen(context, ref)) return;
    if (!context.mounted) return;
    final saved = await showGroupFormDialog(
      context,
      subjectId: widget.subject.id,
    );
    if (saved == true && mounted) _reload();
  }
}
