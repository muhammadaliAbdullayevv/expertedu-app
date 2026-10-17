import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
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

  void _reload() => setState(() => _future = _load());

  Future<void> _refresh() async {
    final future = _load();
    setState(() => _future = future);
    await future;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: FutureBuilder<_Totals>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) return _LoadFailed(onRetry: _reload);
          final totals = snapshot.data!;
          return LayoutBuilder(
            builder: (context, constraints) {
              const gap = 16.0;
              final columns = constraints.maxWidth >= 1100
                  ? 3
                  : constraints.maxWidth >= 620
                  ? 2
                  : 1;
              final side = constraints.maxWidth >= 840
                  ? math.max(24.0, (constraints.maxWidth - 1400) / 2)
                  : 16.0;
              final contentWidth = constraints.maxWidth - 2 * side;
              final cardWidth = (contentWidth - gap * (columns - 1)) / columns;
              return ListView(
                padding: EdgeInsets.fromLTRB(side, 24, side, 32),
                children: <Widget>[
                  Text(
                    'Markaz statistikasi',
                    style: context.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Guruhlar, faol o\'quvchilar va to\'lovlar bo\'yicha joriy holat',
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: <Widget>[
                      SizedBox(
                        width: cardWidth,
                        height: 154,
                        child: _StatCard(
                          icon: Icons.menu_book_rounded,
                          label: 'Guruhlar',
                          value: '${totals.groupCount}',
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        height: 154,
                        child: _StatCard(
                          icon: Icons.school_rounded,
                          label: 'Faol o\'quvchilar',
                          value: '${totals.activeStudents}',
                        ),
                      ),
                      SizedBox(
                        width: cardWidth,
                        height: 154,
                        child: _StatCard(
                          icon: Icons.payments_rounded,
                          label: 'Jami qarzdorlik',
                          value: CurrencyFormatter.format(totals.totalOwed),
                          highlight: totals.totalOwed > 0,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
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
    final accent = highlight ? context.colors.error : AppColors.accent;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 18,
                  backgroundColor: accent.withValues(alpha: 0.1),
                  foregroundColor: accent,
                  child: Icon(icon, size: 19),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: context.textTheme.headlineSmall?.copyWith(
                  color: highlight ? context.colors.error : null,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
          const Text('Statistikani yuklab bo\'lmadi'),
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
