import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../app/theme/app_theme.dart';
import '../../billing/presentation/record_payment_sheet.dart';
import '../../debtors/data/debtors_repository.dart';
import '../../debtors/presentation/overdue_label.dart';
import '../../admissions/data/admissions_models.dart';
import '../../admissions/presentation/lead_card.dart';
import '../data/dashboard_repository.dart';

/// The home screen on wide (desktop) layouts: the center's key numbers up
/// top, then what needs doing today and the call log on the left, money on
/// the right. The phone layout keeps its simpler home -- see DashboardScreen.
class DesktopDashboard extends ConsumerStatefulWidget {
  const DesktopDashboard({
    super.key,
    required this.leads,
    required this.onOpenAdmissions,
    required this.onOpenDebtors,
  });

  /// Open leads, owned by DashboardScreen; they're worked in "Qabul".
  final Future<List<Lead>> leads;
  final VoidCallback onOpenAdmissions;
  final VoidCallback onOpenDebtors;

  @override
  ConsumerState<DesktopDashboard> createState() => DesktopDashboardState();
}

class DesktopDashboardState extends ConsumerState<DesktopDashboard> {
  static const double _maxContentWidth = 1400;

  /// Below this the side-by-side panels get too narrow for a debtor's name,
  /// amount and payment button on one line -- they stack instead.
  static const double _twoColumnMinWidth = 1100;

  late Future<DashboardSummary> _summary;

  @override
  void initState() {
    super.initState();
    _summary = ref.read(dashboardRepositoryProvider).fetch();
  }

  void reload() {
    setState(() => _summary = ref.read(dashboardRepositoryProvider).fetch());
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Centered at a readable width on very wide screens -- padding
        // rather than a constrained box, so the scrollbar stays at the
        // window's edge.
        final sidePadding = math.max(
          24.0,
          (constraints.maxWidth - _maxContentWidth) / 2,
        );
        return ListView(
          padding: EdgeInsets.fromLTRB(sidePadding, 20, sidePadding, 32),
          children: <Widget>[
            FutureBuilder<DashboardSummary>(
              future: _summary,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 64),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return _LoadError(error: snapshot.error!, onRetry: reload);
                }
                return _content(
                  context,
                  snapshot.data!,
                  twoColumns:
                      constraints.maxWidth - 2 * sidePadding >=
                      _twoColumnMinWidth,
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _content(
    BuildContext context,
    DashboardSummary summary, {
    required bool twoColumns,
  }) {
    final planProgress = summary.monthlyPlan == 0
        ? 0.0
        : (summary.collectedThisMonth / summary.monthlyPlan).clamp(0.0, 1.0);

    // What needs doing (today, the call log) and money (debts, revenue,
    // payments) -- side by side when there's room, stacked otherwise.
    final work = <Widget>[
      _TodayPanel(summary: summary),
      _LeadsPanel(leads: widget.leads, onOpenAll: widget.onOpenAdmissions),
    ];
    final money = <Widget>[
      _DebtorsPanel(
        debtors: summary.topDebtors,
        today: summary.today,
        onOpenAll: widget.onOpenDebtors,
        onPaid: reload,
      ),
      _Panel(
        title: 'Tushum, oxirgi 6 oy',
        child: _RevenueChart(months: summary.revenueByMonth),
      ),
      _RecentPaymentsPanel(payments: summary.recentPayments),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: _KpiCard(
                  icon: Icons.school_rounded,
                  label: 'Faol o\'quvchilar',
                  value: '${summary.activeStudents}',
                  detail:
                      '${summary.activeGroups} guruh · +${summary.newStudentsThisMonth} yangi bu oy',
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _KpiCard(
                  icon: Icons.payments_rounded,
                  label: 'Bu oy tushum',
                  value: CurrencyFormatter.format(summary.collectedThisMonth),
                  detail:
                      'Oylik reja: ${CurrencyFormatter.format(summary.monthlyPlan)}',
                  progress: planProgress,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _KpiCard(
                  icon: Icons.warning_amber_rounded,
                  label: 'Qarzdorlik',
                  value: CurrencyFormatter.format(summary.totalDebt),
                  detail: '${summary.debtorCount} o\'quvchi qarzdor',
                  alert: summary.totalDebt > 0,
                  onTap: widget.onOpenDebtors,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _KpiCard(
                  icon: Icons.phone_in_talk_rounded,
                  label: 'Yangi so\'rovlar (7 kun)',
                  value: '${summary.newLeadsThisWeek}',
                  detail: '${summary.openLeads} ta ochiq so\'rov',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (twoColumns)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 3, child: _column(work)),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: _column(money)),
            ],
          )
        else
          _column(<Widget>[...work, ...money]),
      ],
    );
  }
}

Widget _column(List<Widget> panels) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (var i = 0; i < panels.length; i++) ...<Widget>[
        if (i > 0) const SizedBox(height: 16),
        panels[i],
      ],
    ],
  );
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: <Widget>[
          Icon(
            Icons.cloud_off_rounded,
            size: 40,
            color: context.colors.outline,
          ),
          const SizedBox(height: 12),
          Text('Ma\'lumotlarni yuklab bo\'lmadi: $error'),
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

/// A bordered card with a title row -- every block on the desktop home.
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 40,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(title, style: context.textTheme.titleMedium),
                  ),
                  ?action,
                ],
              ),
            ),
            const SizedBox(height: 8),
            Padding(padding: const EdgeInsets.only(right: 8), child: child),
          ],
        ),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.detail,
    this.progress,
    this.alert = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final String detail;

  /// 0..1 -- drawn as a thin meter under the value when set.
  final double? progress;

  /// Debt is the one figure that's bad when it's big -- shown in the error
  /// color (with the warning icon, so it's never color alone).
  final bool alert;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = alert ? context.colors.error : context.colors.primary;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: accent.withValues(alpha: 0.12),
                    child: Icon(icon, size: 20, color: accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: context.textTheme.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right_rounded,
                      color: context.colors.outline,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                value,
                style: context.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: alert ? context.colors.error : null,
                ),
              ),
              const Spacer(),
              if (progress != null) ...<Widget>[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    color: AppColors.accent,
                    backgroundColor: context.colors.surfaceContainerHighest,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                detail,
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

class _TodayPanel extends StatelessWidget {
  const _TodayPanel({required this.summary});

  final DashboardSummary summary;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Bugun · ${DateFormatters.date(summary.today)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TodayRow(
            icon: Icons.event_available_rounded,
            label: 'Sinov darslari',
            value: '${summary.trialsToday.length} ta',
          ),
          for (final trial in summary.trialsToday)
            Padding(
              padding: const EdgeInsets.only(left: 44, bottom: 6),
              child: Text(
                <String>[
                  trial.fullName,
                  if (trial.subjectName != null) trial.subjectName!,
                  PhoneFormatter.display(trial.phone),
                ].join(' · '),
                style: context.textTheme.bodySmall,
              ),
            ),
          _TodayRow(
            icon: Icons.event_repeat_rounded,
            label: 'To\'lov kuni bugun',
            value: summary.dueTodayCount == 0
                ? 'yo\'q'
                : '${summary.dueTodayCount} ta · ${CurrencyFormatter.format(summary.dueTodayAmount)}',
          ),
          _TodayRow(
            icon: Icons.phone_missed_rounded,
            label: '24 soatdan beri javobsiz so\'rovlar',
            value: '${summary.unansweredLeads} ta',
            alert: summary.unansweredLeads > 0,
          ),
        ],
      ),
    );
  }
}

class _TodayRow extends StatelessWidget {
  const _TodayRow({
    required this.icon,
    required this.label,
    required this.value,
    this.alert = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final color = alert ? context.colors.error : context.colors.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 22, color: color),
          const SizedBox(width: 22),
          Expanded(child: Text(label, style: context.textTheme.bodyMedium)),
          Text(
            value,
            style: context.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: alert ? context.colors.error : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _LeadsPanel extends StatelessWidget {
  const _LeadsPanel({required this.leads, required this.onOpenAll});

  static const int _shown = 6;

  final Future<List<Lead>> leads;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'So\'nggi so\'rovlar',
      action: TextButton(
        onPressed: onOpenAll,
        child: const Text('Qabul bo\'limi'),
      ),
      child: FutureBuilder<List<Lead>>(
        future: leads,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasError) {
            return Text('Xatolik: ${snapshot.error}');
          }
          final list = snapshot.data ?? const <Lead>[];
          if (list.isEmpty) {
            return const _EmptyNote('Ochiq so\'rovlar yo\'q');
          }
          return Column(
            children: <Widget>[
              for (final lead in list.take(_shown)) LeadCard(lead: lead),
            ],
          );
        },
      ),
    );
  }
}

class _DebtorsPanel extends StatelessWidget {
  const _DebtorsPanel({
    required this.debtors,
    required this.today,
    required this.onOpenAll,
    required this.onPaid,
  });

  final List<Debtor> debtors;
  final DateTime today;
  final VoidCallback onOpenAll;
  final VoidCallback onPaid;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Eng katta qarzdorlar',
      action: TextButton(onPressed: onOpenAll, child: const Text('Hammasi')),
      child: debtors.isEmpty
          ? const _EmptyNote('Hech kim qarzdor emas')
          : Column(
              children: <Widget>[
                for (final debtor in debtors)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                debtor.studentFullName,
                                style: context.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                <String>[
                                  debtor.groupName,
                                  if (debtor.isWithdrawn) 'chiqib ketgan',
                                  overdueLabel(debtor.oldestUnpaidDue, today),
                                ].where((part) => part.isNotEmpty).join(' · '),
                                style: context.textTheme.bodySmall?.copyWith(
                                  color: context.colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          CurrencyFormatter.format(debtor.balance),
                          style: context.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: context.colors.error,
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () async {
                            final paid = await showRecordPaymentSheet(
                              context,
                              enrollmentId: debtor.enrollmentId,
                              balance: debtor.balance,
                            );
                            if (paid == true) onPaid();
                          },
                          child: const Text('To\'lov'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _RecentPaymentsPanel extends StatelessWidget {
  const _RecentPaymentsPanel({required this.payments});

  final List<RecentPayment> payments;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'So\'nggi to\'lovlar',
      child: payments.isEmpty
          ? const _EmptyNote('Hali to\'lovlar yo\'q')
          : Column(
              children: <Widget>[
                for (final payment in payments)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                payment.studentFullName,
                                style: context.textTheme.bodyMedium,
                              ),
                              Text(
                                '${payment.groupName} · ${DateFormatters.dateTime(payment.occurredAt)}',
                                style: context.textTheme.bodySmall?.copyWith(
                                  color: context.colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '+${CurrencyFormatter.format(payment.amount)}',
                          style: context.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: Colors.green.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Text(
          text,
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Monthly payments as columns, one series in the primary color. Only the
/// current month and the best month carry a value label; every column has
/// a hover tooltip with the exact amount, and the whole series is read out
/// to screen readers -- so no value is reachable by hover alone.
class _RevenueChart extends StatelessWidget {
  const _RevenueChart({required this.months});

  final List<MonthlyRevenue> months;

  static const double _plotHeight = 150;
  static const double _labelRoom = 20; // above the tallest column
  static const double _tickWidth = 56;
  static const double _columnWidth = 24;

  /// Rounds up to 1/2/2.5/5 x 10^n, so the axis ticks are clean numbers.
  static int _niceCeil(int value) {
    if (value <= 0) return 1000000;
    final magnitude = math.pow(10, (math.log(value) / math.ln10).floor());
    for (final step in const <double>[1, 2, 2.5, 5, 10]) {
      final candidate = (step * magnitude).round();
      if (candidate >= value) return candidate;
    }
    return (10 * magnitude).round();
  }

  @override
  Widget build(BuildContext context) {
    final peak = months.fold<int>(0, (best, m) => math.max(best, m.amount));
    final top = _niceCeil(peak);
    final ticks = <int>[0, top ~/ 2, top];
    final labelled = <int>{
      months.length - 1,
      if (peak > 0) months.indexWhere((m) => m.amount == peak),
    };
    final mutedText = context.textTheme.labelSmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );

    return Semantics(
      label:
          'Oylik tushum: ${months.map((m) => '${DateFormatters.monthYearLabel(m.month)} ${CurrencyFormatter.format(m.amount)}').join(', ')}',
      child: ExcludeSemantics(
        child: Column(
          children: <Widget>[
            SizedBox(
              height: _plotHeight + _labelRoom,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    width: _tickWidth,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        for (final tick in ticks)
                          Positioned(
                            right: 8,
                            bottom: _plotHeight * tick / top - 7,
                            child: Text(
                              tick == 0 ? '0' : CurrencyFormatter.compact(tick),
                              style: mutedText,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Stack(
                      children: <Widget>[
                        for (final tick in ticks)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: _plotHeight * tick / top,
                            child: Container(
                              height: 1,
                              color: context.colors.outlineVariant,
                            ),
                          ),
                        Positioned.fill(
                          child: Row(
                            children: <Widget>[
                              for (var i = 0; i < months.length; i++)
                                Expanded(
                                  // The whole slot is the hover target,
                                  // not just the thin column inside it.
                                  child: Tooltip(
                                    message:
                                        '${DateFormatters.monthYearLabel(months[i].month)}: ${CurrencyFormatter.format(months[i].amount)}',
                                    child: Container(
                                      color: Colors.transparent,
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: <Widget>[
                                          if (labelled.contains(i) &&
                                              months[i].amount > 0)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 4,
                                              ),
                                              child: Text(
                                                CurrencyFormatter.compact(
                                                  months[i].amount,
                                                ),
                                                style: context
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                              ),
                                            ),
                                          Container(
                                            width: _columnWidth,
                                            height:
                                                _plotHeight *
                                                months[i].amount /
                                                top,
                                            decoration: BoxDecoration(
                                              color: context.colors.primary,
                                              borderRadius:
                                                  const BorderRadius.vertical(
                                                    top: Radius.circular(4),
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                const SizedBox(width: _tickWidth),
                for (final month in months)
                  Expanded(
                    child: Text(
                      DateFormatters.monthName(month.month),
                      textAlign: TextAlign.center,
                      style: mutedText,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
