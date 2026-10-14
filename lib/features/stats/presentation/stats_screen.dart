import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
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

    var activeStudents = 0;
    var totalOwed = 0;
    for (final group in groups) {
      final roster = await groupsRepo.roster(group.id);
      activeStudents += roster.length;
      for (final entry in roster) {
        if (entry.balance > 0) totalOwed += entry.balance;
      }
    }

    return _Totals(
      groupCount: groups.length,
      activeStudents: activeStudents,
      totalOwed: totalOwed,
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
              _StatCard(
                icon: Icons.payments,
                label: 'Jami qarzdorlik (hammasi bo\'lib)',
                value: CurrencyFormatter.format(totals.totalOwed),
                highlight: totals.totalOwed > 0,
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
  });

  final int groupCount;
  final int activeStudents;
  final int totalOwed;
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
