import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../enrollments/data/enrollments_repository.dart';
import '../../enrollments/presentation/enroll_student_sheet.dart';
import '../data/groups_repository.dart';

class GroupDetailScreen extends ConsumerStatefulWidget {
  const GroupDetailScreen({super.key, required this.group});

  final Group group;

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  late Future<List<RosterEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(groupsRepositoryProvider).roster(widget.group.id);
  }

  void _reload() {
    setState(() => _future = ref.read(groupsRepositoryProvider).roster(widget.group.id));
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    return Scaffold(
      appBar: AppBar(title: Text(group.name)),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final enrolled = await showEnrollStudentSheet(context, groupId: group.id);
          if (enrolled == true) _reload();
        },
        child: const Icon(Icons.person_add_alt_1),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              [
                if (group.teacherName != null && group.teacherName!.isNotEmpty) 'O\'qituvchi: ${group.teacherName}',
                'Har oyning ${group.dueDay}-kuni',
              ].join(' • '),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: FutureBuilder<List<RosterEntry>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Xatolik: ${snapshot.error}'));
                }
                final roster = snapshot.data ?? const <RosterEntry>[];
                if (roster.isEmpty) {
                  return const Center(child: Text('Hali o\'quvchilar yo\'q'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: roster.length,
                  itemBuilder: (context, index) {
                    final entry = roster[index];
                    return ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.school)),
                      title: Text(entry.studentFullName),
                      subtitle: Text(entry.studentPhone),
                      trailing: IconButton(
                        icon: const Icon(Icons.person_remove_outlined),
                        tooltip: 'Chiqarish',
                        onPressed: () => _confirmWithdraw(entry),
                      ),
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

  Future<void> _confirmWithdraw(RosterEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('O\'quvchini chiqarish'),
        content: Text('${entry.studentFullName} shu guruhdan chiqarilsinmi?'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Yo\'q')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Ha')),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(enrollmentsRepositoryProvider).withdraw(entry.enrollmentId);
    _reload();
  }
}
