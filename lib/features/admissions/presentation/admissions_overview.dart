import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';

enum _Period { thisMonth, lastMonth, last30, custom }

/// "Umumiy": admissions numbers for a period, plus what needs doing now.
/// Each rate says what it's out of -- see AdmissionsReport on the server.
class AdmissionsOverview extends ConsumerStatefulWidget {
  const AdmissionsOverview({super.key, required this.onOpenTab});

  /// 1 = leads, 3 = trials, 4 = tasks.
  final ValueChanged<int> onOpenTab;

  @override
  ConsumerState<AdmissionsOverview> createState() => _AdmissionsOverviewState();
}

class _AdmissionsOverviewState extends ConsumerState<AdmissionsOverview> {
  static const double _maxWidth = 1300;

  _Period _period = _Period.thisMonth;
  late DateTimeRange _range = _rangeFor(_Period.thisMonth);
  late Future<AdmissionsReport> _report = _load();
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);

  @override
  void initState() {
    super.initState();
    _refresh.addListener(_reload);
  }

  @override
  void dispose() {
    _refresh.removeListener(_reload);
    super.dispose();
  }

  static DateTimeRange _rangeFor(_Period period) {
    final today = DateUtils.dateOnly(DateTime.now());
    return switch (period) {
      _Period.lastMonth => DateTimeRange(
        start: DateTime(today.year, today.month - 1, 1),
        end: DateTime(today.year, today.month, 0),
      ),
      _Period.last30 => DateTimeRange(
        start: today.subtract(const Duration(days: 29)),
        end: today,
      ),
      _ => DateTimeRange(
        start: DateTime(today.year, today.month, 1),
        end: today,
      ),
    };
  }

  void _reload() {
    if (mounted) {
      setState(() {
        _report = _load();
      });
    }
  }

  Future<AdmissionsReport> _load() =>
      ref.read(admissionsRepositoryProvider).report(_range.start, _range.end);

  Future<void> _choose(_Period period) async {
    if (period == _Period.custom) {
      final today = DateUtils.dateOnly(DateTime.now());
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(today.year - 2),
        lastDate: today,
        initialDateRange: _range,
      );
      if (picked == null) return;
      _range = picked;
    } else {
      _range = _rangeFor(period);
    }
    _period = period;
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.max(24.0, (constraints.maxWidth - _maxWidth) / 2);
        return ListView(
          padding: EdgeInsets.fromLTRB(side, 20, side, 32),
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final (period, label) in <(_Period, String)>[
                  (_Period.thisMonth, 'Bu oy'),
                  (_Period.lastMonth, 'O\'tgan oy'),
                  (_Period.last30, 'Oxirgi 30 kun'),
                  (_Period.custom, 'Oraliq...'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _period == period,
                    onSelected: (_) => _choose(period),
                  ),
                const SizedBox(width: 8),
                Text(
                  DateFormatters.dateRangeLabel(_range.start, _range.end),
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FutureBuilder<AdmissionsReport>(
              future: _report,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoadFailed(error: snapshot.error!, onRetry: _reload);
                }
                final report = snapshot.data;
                if (report == null) {
                  return const Padding(
                    padding: EdgeInsets.all(48),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return _content(report);
              },
            ),
          ],
        );
      },
    );
  }

  Widget _content(AdmissionsReport report) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _CardRow(
          children: <Widget>[
            _Kpi(
              label: 'Yangi so\'rovlar',
              value: '${report.newInquiries}',
              note: 'davrda kelgan',
              onTap: () => widget.onOpenTab(1),
            ),
            _Kpi(
              label: 'Sinov darslari',
              value: '${report.trialsAttended} / ${report.trialsBooked}',
              note:
                  'kelgan / yozilgan · kelmagan: ${report.trialsAbsent} · '
                  'bekor: ${report.trialsCancelled}',
              onTap: () => widget.onOpenTab(3),
            ),
            _Kpi(
              label: 'Guruhga yozildi',
              value: '${report.enrollments}',
              note: 'davrda "Guruhga yozish" orqali',
            ),
            _Kpi(
              label: 'Kelish darajasi',
              value: percent(report.showRate),
              note: 'kelgan ÷ (kelgan + kelmagan)',
            ),
          ],
        ),
        const SizedBox(height: 12),
        _CardRow(
          children: <Widget>[
            _Kpi(
              label: 'So\'rovdan o\'quvchiga',
              value: percent(report.leadConversionRate),
              note:
                  'davrda kelgan ${report.cohortSize} so\'rovdan '
                  '${report.cohortEnrolled} tasi hozirgacha yozilgan',
            ),
            _Kpi(
              label: 'Sinovdan o\'quvchiga',
              value: percent(report.trialConversionRate),
              note:
                  'davrda sinovga kelgan ${report.trialCohortSize} kishidan '
                  '${report.trialCohortEnrolled} tasi yozilgan',
            ),
            _Kpi(
              label: 'Keyingi 7 kun',
              value: '${report.upcomingTrials}',
              note: 'rejalashtirilgan sinov',
              onTap: () => widget.onOpenTab(3),
            ),
            _Kpi(
              label: 'Vazifalar',
              value: '${report.followUpsOverdue + report.followUpsDueToday}',
              note:
                  'muddati o\'tgan: ${report.followUpsOverdue} · bugun: ${report.followUpsDueToday}',
              alert: report.followUpsOverdue > 0,
              onTap: () => widget.onOpenTab(4),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _CardRow(
          children: <Widget>[
            _Panel(
              title: 'Ochiq so\'rovlar, bosqich bo\'yicha',
              child: _StageBars(rows: report.openByStage),
            ),
            _Panel(
              title: 'Manba bo\'yicha (davrda kelganlar)',
              child: _SourceTable(rows: report.cohortBySource),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Sinovga yozilish o\'quvchi bo\'lish hisoblanmaydi: faqat "Guruhga yozish" '
          'qilinganlar sanaladi. Davr markaz kalendari bo\'yicha, chegaralar ichida.',
          style: context.textTheme.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Side by side when there's room, stacked otherwise.
class _CardRow extends StatelessWidget {
  const _CardRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final child in children)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: child,
                ),
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: children[i]),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.label,
    required this.value,
    required this.note,
    this.alert = false,
    this.onTap,
  });

  final String label;
  final String value;
  final String note;
  final bool alert;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: context.textTheme.labelLarge?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                value,
                style: context.textTheme.headlineSmall?.copyWith(
                  color: alert ? context.colors.error : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                note,
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(title, style: context.textTheme.titleSmall),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _StageBars extends StatelessWidget {
  const _StageBars({required this.rows});

  final List<CountByKey> rows;

  @override
  Widget build(BuildContext context) {
    final most = rows.fold<int>(0, (m, r) => math.max(m, r.count));
    return Column(
      children: <Widget>[
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 150,
                  child: Text(
                    LeadStage.label(row.key),
                    style: context.textTheme.bodyMedium,
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: most == 0 ? 0 : row.count / most,
                      minHeight: 10,
                      color: stageColor(row.key),
                      backgroundColor: context.colors.surfaceContainerHigh,
                    ),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    '${row.count}',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SourceTable extends StatelessWidget {
  const _SourceTable({required this.rows});

  final List<CountByKey> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const EmptyNote('Davrda so\'rov yo\'q');
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text('Manba', style: muted)),
            SizedBox(width: 70, child: Text('So\'rov', style: muted)),
            SizedBox(width: 70, child: Text('Yozildi', style: muted)),
            SizedBox(width: 60, child: Text('%', style: muted)),
          ],
        ),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    row.key == 'unknown'
                        ? 'Ko\'rsatilmagan'
                        : sourceLabel(row.key),
                  ),
                ),
                SizedBox(width: 70, child: Text('${row.count}')),
                SizedBox(width: 70, child: Text('${row.enrolled}')),
                SizedBox(
                  width: 60,
                  child: Text(
                    percent(row.count == 0 ? null : row.enrolled / row.count),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
