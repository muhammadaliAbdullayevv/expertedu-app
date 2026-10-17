import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/bordered_list_tile.dart';
import '../../../core/widgets/status_chip.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../../enrollments/presentation/enroll_student_sheet.dart';
import '../../students/presentation/open_student.dart';
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
    setState(
      () =>
          _future = ref.read(groupsRepositoryProvider).roster(widget.group.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    return Scaffold(
      appBar: AppBar(title: Text(group.name)),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final enrolled = await showEnrollStudentSheet(
            context,
            groupId: group.id,
          );
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
                if (group.teacherName != null && group.teacherName!.isNotEmpty)
                  'O\'qituvchi: ${group.teacherName}',
                group.billingLabel,
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
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                  ).copyWith(bottom: 16),
                  itemCount: roster.length,
                  itemBuilder: (context, index) {
                    final entry = roster[index];
                    final owesMoney = entry.balance > 0;
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
                      // New students are listed first, marked "Yangi".
                      title: Row(
                        children: <Widget>[
                          Flexible(child: Text(entry.studentFullName)),
                          if (entry.isNew) ...<Widget>[
                            const SizedBox(width: 8),
                            const StatusChip('Yangi', tone: StatusTone.info),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        owesMoney
                            ? 'Qarz: ${CurrencyFormatter.format(entry.balance)}'
                            : 'To\'langan',
                        style: TextStyle(
                          color: owesMoney
                              ? Theme.of(context).colorScheme.error
                              : Colors.green,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.person_remove_outlined),
                        tooltip: 'Chiqarish',
                        onPressed: () => _confirmWithdraw(entry),
                      ),
                      // The profile, where payments are taken.
                      onTap: () {
                        ref.read(openStudentRequestProvider).value =
                            entry.studentId;
                        Navigator.of(context).popUntil((r) => r.isFirst);
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

  Future<void> _confirmWithdraw(RosterEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('O\'quvchini chiqarish'),
        content: Text('${entry.studentFullName} shu guruhdan chiqarilsinmi?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Yo\'q'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Ha'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(enrollmentsRepositoryProvider).withdraw(entry.enrollmentId);
    _reload();
  }
}
