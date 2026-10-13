import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/section_card.dart';
import '../../groups/data/groups_repository.dart';

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
    final groups = await groupsRepo.list();
    var totalOwed = 0;
    var studentsWithDebt = 0;
    var activeStudents = 0;
    for (final group in groups) {
      final roster = await groupsRepo.roster(group.id);
      activeStudents += roster.length;
      for (final entry in roster) {
        if (entry.balance > 0) {
          totalOwed += entry.balance;
          studentsWithDebt++;
        }
      }
    }
    return _Totals(
      groupCount: groups.length,
      activeStudents: activeStudents,
      totalOwed: totalOwed,
      studentsWithDebt: studentsWithDebt,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() => _future = _load()),
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
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: _StatCard(label: 'Guruhlar', value: '${totals.groupCount}')),
                  const SizedBox(width: 12),
                  Expanded(child: _StatCard(label: 'Faol o\'quvchilar', value: '${totals.activeStudents}')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _StatCard(
                      label: 'Jami qarzdorlik',
                      value: CurrencyFormatter.format(totals.totalOwed),
                      highlight: totals.totalOwed > 0,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: _StatCard(label: 'Qarzdor o\'quvchilar', value: '${totals.studentsWithDebt}')),
                ],
              ),
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
  });

  final int groupCount;
  final int activeStudents;
  final int totalOwed;
  final int studentsWithDebt;
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value, this.highlight = false});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
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
    );
  }
}
