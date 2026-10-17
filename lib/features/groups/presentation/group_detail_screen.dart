import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../../enrollments/presentation/enroll_student_sheet.dart';
import '../../students/presentation/student_panel.dart';
import '../data/groups_repository.dart';

/// A group's students, with the selected student's profile beside the list --
/// the same profile as on O'quvchilar, so you never leave the group to look
/// at someone, take a payment or edit them.
class GroupDetailScreen extends ConsumerStatefulWidget {
  const GroupDetailScreen({super.key, required this.group});

  final Group group;

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  /// Below this width the profile does not fit beside the list and opens over it.
  static const double _splitWidth = 1000;

  late Future<List<RosterEntry>> _future;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _future = ref.read(groupsRepositoryProvider).roster(widget.group.id);
  }

  void _reload() {
    final next = ref.read(groupsRepositoryProvider).roster(widget.group.id);
    setState(() {
      _future = next;
    });
  }

  Future<void> _showOver(int studentId) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 480,
          height: MediaQuery.sizeOf(dialogContext).height * 0.9,
          child: StudentPanel(studentId: studentId, onChanged: _reload),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.group;
    final split = MediaQuery.sizeOf(context).width >= _splitWidth;
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
      body: FutureBuilder<List<RosterEntry>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done &&
              !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Xatolik: ${snapshot.error}'));
          }
          final roster = snapshot.data ?? const <RosterEntry>[];
          // The profile follows the selection; with nothing chosen, the first.
          final selected = roster.any((e) => e.studentId == _selected)
              ? _selected
              : (roster.isEmpty ? null : roster.first.studentId);
          final list = _list(roster, selected, split);
          if (!split) return list;
          return Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 24, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: list),
                SizedBox(
                  width: 440,
                  child: selected == null
                      ? const SizedBox.shrink()
                      : StudentPanel(
                          key: ValueKey('group-panel-$selected'),
                          studentId: selected,
                          onChanged: _reload,
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _list(List<RosterEntry> roster, int? selected, bool split) {
    final group = widget.group;
    return Column(
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
          child: roster.isEmpty
              ? const Center(child: Text('Hali o\'quvchilar yo\'q'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                  ).copyWith(bottom: 88),
                  itemCount: roster.length,
                  itemBuilder: (context, index) => _RosterRow(
                    key: ValueKey('roster-${roster[index].studentId}'),
                    entry: roster[index],
                    selected: split && roster[index].studentId == selected,
                    onTap: () {
                      final id = roster[index].studentId;
                      if (split) {
                        setState(() => _selected = id);
                      } else {
                        _showOver(id);
                      }
                    },
                    onWithdraw: () => _confirmWithdraw(roster[index]),
                  ),
                ),
        ),
      ],
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

/// One student of the group: new ones are listed first, marked "Yangi".
class _RosterRow extends StatelessWidget {
  const _RosterRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onWithdraw,
  });

  final RosterEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onWithdraw;

  @override
  Widget build(BuildContext context) {
    final owes = entry.balance > 0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: selected ? AppColors.accentSoft : AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                backgroundColor: owes ? AppColors.dangerBg : AppColors.okBg,
                child: Icon(
                  Icons.school,
                  color: owes ? AppColors.dangerText : AppColors.okText,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            entry.studentFullName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (entry.isNew) ...<Widget>[
                          const SizedBox(width: 8),
                          const StatusChip('Yangi', tone: StatusTone.info),
                        ],
                      ],
                    ),
                    Text(
                      owes
                          ? 'Qarz: ${CurrencyFormatter.format(entry.balance)}'
                          : 'To\'langan',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: owes ? AppColors.dangerText : AppColors.okText,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.person_remove_outlined),
                tooltip: 'Chiqarish',
                onPressed: onWithdraw,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
