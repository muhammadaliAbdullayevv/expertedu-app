import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/bordered_list_tile.dart';
import '../../groups/data/groups_repository.dart';
import '../../subjects/data/subjects_repository.dart';

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  late Future<_Totals> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_Totals> _load() async {
    final groupsRepo = ref.read(groupsRepositoryProvider);
    final subjects = await ref.read(subjectsRepositoryProvider).list();
    final groups = await groupsRepo.list();

    var activeStudents = 0;
    var totalOwed = 0;
    var studentsWithDebt = 0;
    final owedBySubject = <int, int>{};
    final debtors = <_Debtor>[];

    for (final group in groups) {
      final roster = await groupsRepo.roster(group.id);
      activeStudents += roster.length;
      for (final entry in roster) {
        if (entry.balance <= 0) continue;
        totalOwed += entry.balance;
        studentsWithDebt++;
        if (group.subjectId != null) {
          owedBySubject.update(
            group.subjectId!,
            (v) => v + entry.balance,
            ifAbsent: () => entry.balance,
          );
        }
        debtors.add(
          _Debtor(
            name: entry.studentFullName,
            groupName: group.name,
            balance: entry.balance,
          ),
        );
      }
    }
    debtors.sort((a, b) => b.balance.compareTo(a.balance));

    final subjectBreakdown =
        subjects
            .map(
              (s) => _SubjectDebt(name: s.name, owed: owedBySubject[s.id] ?? 0),
            )
            .where((s) => s.owed > 0)
            .toList()
          ..sort((a, b) => b.owed.compareTo(a.owed));

    return _Totals(
      groupCount: groups.length,
      activeStudents: activeStudents,
      totalOwed: totalOwed,
      studentsWithDebt: studentsWithDebt,
      subjectBreakdown: subjectBreakdown,
      topDebtors: debtors.take(5).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async {
        final future = _load();
        setState(() => _future = future);
        await future;
      },
      child: FutureBuilder<_Totals>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Xatolik: ${snapshot.error}'));
          }
          final totals = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _StatCard(
                      icon: Icons.menu_book,
                      label: 'Guruhlar',
                      value: '${totals.groupCount}',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.school,
                      label: 'Faol o\'quvchilar',
                      value: '${totals.activeStudents}',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _StatCard(
                      icon: Icons.payments,
                      label: 'Jami qarzdorlik',
                      value: CurrencyFormatter.format(totals.totalOwed),
                      highlight: totals.totalOwed > 0,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.error_outline,
                      label: 'Qarzdor o\'quvchilar',
                      value: '${totals.studentsWithDebt}',
                      highlight: totals.studentsWithDebt > 0,
                    ),
                  ),
                ],
              ),
              if (totals.subjectBreakdown.isNotEmpty) ...<Widget>[
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Fanlar bo\'yicha qarzdorlik',
                    style: context.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 8),
                ...totals.subjectBreakdown.map(
                  (s) => BorderedListTile(
                    leading: const CircleAvatar(child: Icon(Icons.menu_book)),
                    title: Text(s.name),
                    trailing: Text(
                      CurrencyFormatter.format(s.owed),
                      style: TextStyle(
                        color: context.colors.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
              if (totals.topDebtors.isNotEmpty) ...<Widget>[
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Eng ko\'p qarzdorlar',
                    style: context.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 8),
                ...totals.topDebtors.map(
                  (d) => BorderedListTile(
                    leading: CircleAvatar(
                      backgroundColor: context.colors.errorContainer,
                      child: Icon(Icons.person, color: context.colors.error),
                    ),
                    title: Text(d.name),
                    subtitle: Text(d.groupName),
                    trailing: Text(
                      CurrencyFormatter.format(d.balance),
                      style: TextStyle(
                        color: context.colors.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Totals {
  const _Totals({
    required this.groupCount,
    required this.activeStudents,
    required this.totalOwed,
    required this.studentsWithDebt,
    required this.subjectBreakdown,
    required this.topDebtors,
  });

  final int groupCount;
  final int activeStudents;
  final int totalOwed;
  final int studentsWithDebt;
  final List<_SubjectDebt> subjectBreakdown;
  final List<_Debtor> topDebtors;
}

class _SubjectDebt {
  const _SubjectDebt({required this.name, required this.owed});

  final String name;
  final int owed;
}

class _Debtor {
  const _Debtor({
    required this.name,
    required this.groupName,
    required this.balance,
  });

  final String name;
  final String groupName;
  final int balance;
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: context.colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: context.colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              icon,
              color: highlight ? context.colors.error : context.colors.primary,
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: context.textTheme.titleLarge?.copyWith(
                color: highlight ? context.colors.error : null,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(label, style: context.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
