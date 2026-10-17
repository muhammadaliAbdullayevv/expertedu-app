import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/thousands_input_formatter.dart';
import '../../../core/widgets/table_card.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../billing/payment_methods.dart';
import '../../teachers/data/teachers_repository.dart';
import '../data/finance_repository.dart';

/// "Moliya" (desktop, owner only): income, expenses and profit; teachers'
/// percentage salaries and their payouts; the expense list.
class FinanceScreen extends ConsumerStatefulWidget {
  const FinanceScreen({super.key});

  @override
  ConsumerState<FinanceScreen> createState() => FinanceScreenState();
}

class FinanceScreenState extends ConsumerState<FinanceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  /// Bumped after any change, so every tab reloads.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  @override
  void dispose() {
    _tabs.dispose();
    _revision.dispose();
    super.dispose();
  }

  void reload() => _revision.value++;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): reload,
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              decoration: BoxDecoration(
                color: context.colors.surface,
                border: Border(
                  bottom: BorderSide(color: context.colors.outlineVariant),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TabBar(
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerHeight: 0,
                indicatorColor: AppColors.accent,
                indicatorWeight: 3,
                labelColor: context.colors.onSurface,
                unselectedLabelColor: context.colors.onSurfaceVariant,
                labelStyle: context.textTheme.labelLarge,
                tabs: const <Tab>[
                  Tab(text: 'Umumiy'),
                  Tab(text: 'Oyliklar'),
                  Tab(text: 'Xarajatlar'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  _SummaryView(revision: _revision),
                  _SalariesView(revision: _revision, onChanged: reload),
                  _ExpensesView(revision: _revision, onChanged: reload),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tab that reloads whenever [revision] changes.
mixin _Reloads<T extends StatefulWidget> on State<T> {
  ValueNotifier<int> get revision;

  void reload();

  @override
  void initState() {
    super.initState();
    revision.addListener(_onRevision);
  }

  @override
  void dispose() {
    revision.removeListener(_onRevision);
    super.dispose();
  }

  void _onRevision() {
    if (mounted) reload();
  }
}

String _money(int amount) => CurrencyFormatter.format(amount);

// --- Umumiy ------------------------------------------------------------------

class _SummaryView extends ConsumerStatefulWidget {
  const _SummaryView({required this.revision});

  final ValueNotifier<int> revision;

  @override
  ConsumerState<_SummaryView> createState() => _SummaryViewState();
}

class _SummaryViewState extends ConsumerState<_SummaryView>
    with _Reloads<_SummaryView> {
  late Future<FinanceSummary> _summary = _load();

  @override
  ValueNotifier<int> get revision => widget.revision;

  Future<FinanceSummary> _load() =>
      ref.read(financeRepositoryProvider).summary(months: 6);

  @override
  void reload() => setState(() => _summary = _load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FinanceSummary>(
      future: _summary,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadFailed(error: snapshot.error!, onRetry: reload);
        }
        final summary = snapshot.data;
        if (summary == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final current = summary.months.last;
        final most = summary.months.fold<int>(
          1,
          (m, x) => math.max(m, math.max(x.income, x.expenses)),
        );
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Moliyaviy ko\'rinish',
                        style: context.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        DateFormatters.monthYearLabel(current.month),
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  'So\'nggi 6 oy',
                  style: context.textTheme.labelLarge?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                const gap = 12.0;
                final columns = constraints.maxWidth >= 1080 ? 4 : 2;
                final width =
                    (constraints.maxWidth - gap * (columns - 1)) / columns;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: <Widget>[
                    SizedBox(
                      width: width,
                      height: 156,
                      child: _Kpi(
                        'Tushum',
                        _money(current.income),
                        'to\'lovlar',
                        icon: Icons.south_west_rounded,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      height: 156,
                      child: _Kpi(
                        'Xarajat',
                        _money(current.expenses),
                        'oyliklar bilan',
                        icon: Icons.north_east_rounded,
                        color: AppColors.inkMuted,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      height: 156,
                      child: _Kpi(
                        'Foyda',
                        _money(current.profit),
                        'tushum − xarajat',
                        icon: Icons.account_balance_rounded,
                        color: current.profit < 0
                            ? AppColors.danger
                            : AppColors.success,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      height: 156,
                      child: _Kpi(
                        'To\'lanmagan oyliklar',
                        _money(summary.salariesUnpaidThisMonth),
                        'hisoblangan, hali to\'lanmagan',
                        icon: Icons.schedule_rounded,
                        color: summary.salariesUnpaidThisMonth > 0
                            ? AppColors.danger
                            : null,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            'Oylik dinamika',
                            style: context.textTheme.titleMedium,
                          ),
                        ),
                        _ChartLegend(color: AppColors.accent, label: 'Tushum'),
                        const SizedBox(width: 16),
                        _ChartLegend(
                          color: AppColors.inkMuted,
                          label: 'Xarajat',
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    for (final month in summary.months.reversed)
                      _MonthRow(month: month, most: most),
                  ],
                ),
              ),
            ),
            if (current.byCategory.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'Bu oy xarajatlari',
                        style: context.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      for (final entry
                          in (current.byCategory.entries.toList()
                            ..sort((a, b) => b.value.compareTo(a.value))))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(expenseCategoryLabel(entry.key)),
                              ),
                              Text(
                                _money(entry.value),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(
    this.label,
    this.value,
    this.note, {
    required this.icon,
    this.color,
  });

  final String label;
  final String value;
  final String note;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final accent = color ?? context.colors.primary;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 16,
                  backgroundColor: accent.withValues(alpha: 0.1),
                  foregroundColor: accent,
                  child: Icon(icon, size: 17),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.textTheme.labelLarge?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                style: context.textTheme.headlineSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Spacer(),
            Text(
              note,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartLegend extends StatelessWidget {
  const _ChartLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: context.textTheme.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _MonthRow extends StatelessWidget {
  const _MonthRow({required this.month, required this.most});

  final FinanceMonth month;
  final int most;

  @override
  Widget build(BuildContext context) {
    Widget bar(int value, Color color) => ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: value / most,
        minHeight: 8,
        color: color,
        backgroundColor: context.colors.surfaceContainerHigh,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 140,
            child: Text(DateFormatters.monthYearLabel(month.month)),
          ),
          Expanded(
            child: Column(
              children: <Widget>[
                bar(month.income, AppColors.accent),
                const SizedBox(height: 4),
                bar(month.expenses, AppColors.inkMuted),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 330,
            child: Text(
              '${CurrencyFormatter.compact(month.income)} − '
              '${CurrencyFormatter.compact(month.expenses)} = ',
              textAlign: TextAlign.end,
              style: context.textTheme.bodySmall,
            ),
          ),
          SizedBox(
            width: 150,
            child: Text(
              _money(month.profit),
              textAlign: TextAlign.end,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: month.profit < 0 ? AppColors.danger : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Oyliklar ----------------------------------------------------------------

class _SalariesView extends ConsumerStatefulWidget {
  const _SalariesView({required this.revision, required this.onChanged});

  final ValueNotifier<int> revision;
  final VoidCallback onChanged;

  @override
  ConsumerState<_SalariesView> createState() => _SalariesViewState();
}

class _SalariesViewState extends ConsumerState<_SalariesView>
    with _Reloads<_SalariesView> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late Future<SalaryMonth> _data = _load();

  @override
  ValueNotifier<int> get revision => widget.revision;

  Future<SalaryMonth> _load() =>
      ref.read(financeRepositoryProvider).salaries(_month);

  @override
  void reload() => setState(() => _data = _load());

  void _shift(int months) {
    _month = DateTime(_month.year, _month.month + months);
    reload();
  }

  Future<void> _editPercent(TeacherSalary teacher) async {
    final controller = TextEditingController(
      text: teacher.salaryPercent == null
          ? ''
          : teacher.salaryPercent!.toStringAsFixed(
              teacher.salaryPercent! % 1 == 0 ? 0 : 1,
            ),
    );
    final saved = await showReasonlessFormDialog(
      context,
      title: 'Oylik foizi · ${teacher.fullName}',
      subtitle: 'Guruhlaridagi o\'quvchilar to\'lovidan ulushi',
      field: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
        ],
        decoration: const InputDecoration(
          labelText: 'Foiz',
          suffixText: '%',
          helperText: 'Bo\'sh qoldirilsa, foiz bilan hisoblanmaydi',
        ),
      ),
      onSave: () {
        final text = controller.text.trim().replaceAll(',', '.');
        final value = text.isEmpty ? null : double.tryParse(text);
        if (text.isNotEmpty && value == null) throw 'Son kiriting.';
        return ref
            .read(financeRepositoryProvider)
            .setSalaryPercent(teacher.teacherId, value);
      },
    );
    if (saved == true) widget.onChanged();
  }

  Future<void> _pay(SalaryMonth month, TeacherSalary teacher) async {
    final saved = await showExpenseDialog(
      context,
      ref,
      category: 'salary',
      teacherId: teacher.teacherId,
      salaryMonth: month.month,
      amount: math.max(teacher.remaining, 0),
    );
    if (saved == true) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodyMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: FutureBuilder<SalaryMonth>(
        future: _data,
        builder: (context, snapshot) {
          final month = snapshot.data;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton.outlined(
                    tooltip: 'Oldingi oy',
                    onPressed: () => _shift(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: 'Keyingi oy',
                    onPressed: () => _shift(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    DateFormatters.monthYearLabel(_month),
                    style: context.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  if (month != null)
                    Text(
                      'Hisoblangan: ${_money(month.totalEarned)} · '
                      'to\'langan: ${_money(month.totalPaid)} · '
                      'qoldiq: ${_money(month.totalRemaining)}',
                      style: muted,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'O\'qituvchi o\'z guruhlaridagi o\'quvchilar shu oyda to\'lagan '
                'summaning belgilangan foizini oladi.',
                style: context.textTheme.bodySmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(child: _table(snapshot)),
            ],
          );
        },
      ),
    );
  }

  Widget _table(AsyncSnapshot<SalaryMonth> snapshot) {
    if (snapshot.hasError) {
      return LoadFailed(error: snapshot.error!, onRetry: reload);
    }
    final month = snapshot.data;
    if (month == null) return const Center(child: CircularProgressIndicator());
    final teachers = month.teachers;
    return TableCard(
      emptyText: 'O\'qituvchilar yo\'q',
      columns: const <TableColumn>[
        TableColumn('O\'qituvchi', flex: 3),
        TableColumn('Foiz', alignEnd: true),
        TableColumn('Yig\'ilgan', flex: 2, alignEnd: true),
        TableColumn('Hisoblangan', flex: 2, alignEnd: true),
        TableColumn('To\'langan', flex: 2, alignEnd: true),
        TableColumn('Qoldiq', flex: 2, alignEnd: true),
        TableColumn('', width: 130),
      ],
      rowCount: teachers.length,
      onRowTap: (row) => _editPercent(teachers[row]),
      cell: (context, row, column) {
        final t = teachers[row];
        return switch (column) {
          0 => Text(
            t.fullName + (t.isActive ? '' : ' (faol emas)'),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          1 => Text(
            t.salaryPercent == null
                ? '—'
                : '${t.salaryPercent!.toStringAsFixed(t.salaryPercent! % 1 == 0 ? 0 : 1)}%',
          ),
          2 => Text(_money(t.collected)),
          3 => Text(_money(t.earned)),
          4 => Text(_money(t.paid)),
          5 => Text(
            _money(t.remaining),
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: t.remaining > 0
                  ? AppColors.danger
                  : t.remaining < 0
                  ? const Color(0xFFD97706)
                  : null,
            ),
          ),
          _ => Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                tooltip: 'Foizni o\'zgartirish',
                onPressed: () => _editPercent(t),
                icon: const Icon(Icons.percent_rounded, size: 20),
              ),
              TextButton(
                onPressed: () => _pay(month, t),
                child: const Text('To\'lash'),
              ),
            ],
          ),
        };
      },
    );
  }
}

// --- Xarajatlar --------------------------------------------------------------

enum _Range { thisMonth, lastMonth, last90 }

class _ExpensesView extends ConsumerStatefulWidget {
  const _ExpensesView({required this.revision, required this.onChanged});

  final ValueNotifier<int> revision;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ExpensesView> createState() => _ExpensesViewState();
}

class _ExpensesViewState extends ConsumerState<_ExpensesView>
    with _Reloads<_ExpensesView> {
  _Range _rangeKind = _Range.thisMonth;
  String? _category;
  bool _showVoided = false;
  late Future<List<Expense>> _data = _load();

  @override
  ValueNotifier<int> get revision => widget.revision;

  DateTimeRange get _range {
    final today = DateUtils.dateOnly(DateTime.now());
    return switch (_rangeKind) {
      _Range.lastMonth => DateTimeRange(
        start: DateTime(today.year, today.month - 1, 1),
        end: DateTime(today.year, today.month, 0),
      ),
      _Range.last90 => DateTimeRange(
        start: today.subtract(const Duration(days: 89)),
        end: today,
      ),
      _Range.thisMonth => DateTimeRange(
        start: DateTime(today.year, today.month, 1),
        end: today,
      ),
    };
  }

  Future<List<Expense>> _load() => ref
      .read(financeRepositoryProvider)
      .expenses(
        _range.start,
        _range.end,
        category: _category,
        includeVoided: _showVoided,
      );

  @override
  void reload() => setState(() => _data = _load());

  Future<void> _add() async {
    final saved = await showExpenseDialog(context, ref);
    if (saved == true) widget.onChanged();
  }

  Future<void> _void(Expense expense) async {
    final reason = TextEditingController();
    final done = await showReasonlessFormDialog(
      context,
      title: 'Xarajatni bekor qilish',
      subtitle:
          '${expenseCategoryLabel(expense.category)} · ${_money(expense.amount)} · '
          'yozuv saqlanib qoladi',
      field: TextField(
        controller: reason,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Sabab'),
      ),
      onSave: () {
        if (reason.text.trim().isEmpty) throw 'Sababini yozing.';
        return ref
            .read(financeRepositoryProvider)
            .voidExpense(expense.id, reason.text.trim());
      },
    );
    if (done == true) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.textTheme.bodyMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              for (final (kind, label) in <(_Range, String)>[
                (_Range.thisMonth, 'Bu oy'),
                (_Range.lastMonth, 'O\'tgan oy'),
                (_Range.last90, 'Oxirgi 90 kun'),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _rangeKind == kind,
                  onSelected: (_) {
                    _rangeKind = kind;
                    reload();
                  },
                ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  isExpanded: true,
                  initialValue: _category,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Turi',
                  ),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem(value: null, child: Text('Hammasi')),
                    for (final entry in expenseCategoryLabels.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (v) {
                    _category = v;
                    reload();
                  },
                ),
              ),
              FilterChip(
                label: const Text('Bekor qilinganlar'),
                selected: _showVoided,
                onSelected: (v) {
                  _showVoided = v;
                  reload();
                },
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Yangi xarajat'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<List<Expense>>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoadFailed(error: snapshot.error!, onRetry: reload);
                }
                final expenses = snapshot.data;
                if (expenses == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final total = expenses
                    .where((e) => !e.isVoided)
                    .fold<int>(0, (sum, e) => sum + e.amount);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(
                      child: TableCard(
                        emptyText: 'Bu davrda xarajat yo\'q',
                        columns: const <TableColumn>[
                          TableColumn('Sana', flex: 2),
                          TableColumn('Turi', flex: 2),
                          TableColumn('Izoh', flex: 4),
                          TableColumn('Usul', flex: 2),
                          TableColumn('Summa', flex: 2, alignEnd: true),
                          TableColumn('', width: 56),
                        ],
                        rowCount: expenses.length,
                        cell: (context, row, column) {
                          final e = expenses[row];
                          final style = e.isVoided
                              ? TextStyle(
                                  color: context.colors.onSurfaceVariant,
                                  decoration: TextDecoration.lineThrough,
                                )
                              : null;
                          return switch (column) {
                            0 => Text(
                              DateFormatters.date(e.spentOn),
                              style: style,
                            ),
                            1 => Text(
                              expenseCategoryLabel(e.category),
                              style: style,
                            ),
                            2 => Text(
                              <String>[
                                if (e.teacherName != null)
                                  '${e.teacherName} · ${DateFormatters.monthYearLabel(e.salaryMonth!)}',
                                ?e.note,
                                if (e.isVoided) 'bekor: ${e.voidReason}',
                              ].join(' · '),
                              overflow: TextOverflow.ellipsis,
                              style: style ?? muted,
                            ),
                            3 => Text(
                              paymentMethodLabel(e.method),
                              style: style,
                            ),
                            4 => Text(
                              _money(e.amount),
                              style: (style ?? const TextStyle()).copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            _ =>
                              e.isVoided
                                  ? const SizedBox.shrink()
                                  : IconButton(
                                      tooltip: 'Bekor qilish',
                                      onPressed: () => _void(e),
                                      icon: const Icon(
                                        Icons.block_rounded,
                                        size: 20,
                                      ),
                                    ),
                          };
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Jami: ${_money(total)}', style: muted),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- Dialogs -------------------------------------------------------------------

/// A one-field dialog: [onSave] throws a String (or anything) to show an
/// error and stay open.
Future<bool?> showReasonlessFormDialog(
  BuildContext context, {
  required String title,
  String? subtitle,
  required Widget field,
  required Future<void> Function() onSave,
}) {
  var saving = false;
  String? error;
  return showAdaptiveFormDialog<bool>(
    context,
    child: StatefulBuilder(
      builder: (context, setState) {
        Future<void> save() async {
          if (saving) return;
          setState(() {
            saving = true;
            error = null;
          });
          try {
            await onSave();
            if (context.mounted) Navigator.of(context).pop(true);
          } catch (e) {
            setState(() {
              error = e.toString();
              saving = false;
            });
          }
        }

        return SubmitShortcut(
          onSubmit: save,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DialogHeader(title: title, subtitle: subtitle),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    field,
                    if (error != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        error!,
                        style: TextStyle(color: context.colors.error),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Bekor qilish'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: saving ? null : save,
                      child: const Text('Saqlash'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

/// A new expense; with [category] 'salary', a payout to [teacherId] for
/// [salaryMonth].
Future<bool?> showExpenseDialog(
  BuildContext context,
  WidgetRef ref, {
  String category = 'rent',
  int? teacherId,
  DateTime? salaryMonth,
  int? amount,
}) {
  var kind = category;
  var teacher = teacherId;
  final now = DateTime.now();
  var month = salaryMonth ?? DateTime(now.year, now.month);
  var spentOn = DateUtils.dateOnly(now);
  String? method = 'cash';
  final amountText = TextEditingController(
    text: amount == null || amount == 0
        ? ''
        : ThousandsInputFormatter()
              .formatEditUpdate(
                TextEditingValue.empty,
                TextEditingValue(text: '$amount'),
              )
              .text,
  );
  final note = TextEditingController();
  final teachers = ref.read(teachersRepositoryProvider).list();
  final months = <DateTime>[
    for (var i = 0; i < 6; i++) DateTime(now.year, now.month - i),
  ];
  if (!months.contains(month)) months.add(month);
  var saving = false;
  String? error;

  return showAdaptiveFormDialog<bool>(
    context,
    child: StatefulBuilder(
      builder: (context, setState) {
        Future<void> save() async {
          if (saving) return;
          final value = ThousandsInputFormatter.unformat(amountText.text) ?? 0;
          if (value <= 0) {
            setState(() => error = 'Summani kiriting.');
            return;
          }
          if (kind == 'salary' && teacher == null) {
            setState(() => error = 'O\'qituvchini tanlang.');
            return;
          }
          setState(() {
            saving = true;
            error = null;
          });
          try {
            await ref
                .read(financeRepositoryProvider)
                .addExpense(
                  category: kind,
                  amount: value,
                  spentOn: spentOn,
                  note: note.text.trim().isEmpty ? null : note.text.trim(),
                  method: method,
                  teacherId: kind == 'salary' ? teacher : null,
                  salaryMonth: kind == 'salary' ? month : null,
                );
            if (context.mounted) Navigator.of(context).pop(true);
          } catch (e) {
            setState(() {
              error = e.toString();
              saving = false;
            });
          }
        }

        return SubmitShortcut(
          onSubmit: save,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DialogHeader(
                title: kind == 'salary' ? 'Oylik to\'lash' : 'Yangi xarajat',
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: kind,
                        decoration: const InputDecoration(labelText: 'Turi'),
                        items: <DropdownMenuItem<String>>[
                          for (final entry in expenseCategoryLabels.entries)
                            DropdownMenuItem(
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        onChanged: (v) => setState(() => kind = v ?? kind),
                      ),
                      if (kind == 'salary') ...<Widget>[
                        const SizedBox(height: 14),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: FutureBuilder<List<Teacher>>(
                                future: teachers,
                                builder: (context, snapshot) =>
                                    DropdownButtonFormField<int?>(
                                      isExpanded: true,
                                      initialValue: teacher,
                                      decoration: const InputDecoration(
                                        labelText: 'O\'qituvchi',
                                      ),
                                      items: <DropdownMenuItem<int?>>[
                                        for (final t
                                            in snapshot.data ??
                                                const <Teacher>[])
                                          DropdownMenuItem(
                                            value: t.id,
                                            child: Text(t.fullName),
                                          ),
                                      ],
                                      onChanged: (v) =>
                                          setState(() => teacher = v),
                                    ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: DropdownButtonFormField<DateTime>(
                                isExpanded: true,
                                initialValue: month,
                                decoration: const InputDecoration(
                                  labelText: 'Qaysi oy uchun',
                                ),
                                items: <DropdownMenuItem<DateTime>>[
                                  for (final m in months)
                                    DropdownMenuItem(
                                      value: m,
                                      child: Text(
                                        DateFormatters.monthYearLabel(m),
                                      ),
                                    ),
                                ],
                                onChanged: (v) =>
                                    setState(() => month = v ?? month),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: amountText,
                              autofocus: true,
                              keyboardType: TextInputType.number,
                              inputFormatters: <TextInputFormatter>[
                                ThousandsInputFormatter(),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Summa',
                                suffixText: 'so\'m',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: InkWell(
                              onTap: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: spentOn,
                                  firstDate: spentOn.subtract(
                                    const Duration(days: 366),
                                  ),
                                  lastDate: DateUtils.dateOnly(DateTime.now()),
                                );
                                if (picked != null) {
                                  setState(() => spentOn = picked);
                                }
                              },
                              child: InputDecorator(
                                decoration: const InputDecoration(
                                  labelText: 'Sana',
                                ),
                                child: Text(DateFormatters.date(spentOn)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SegmentedButton<String?>(
                        segments: <ButtonSegment<String?>>[
                          for (final entry in paymentMethodLabels.entries)
                            ButtonSegment(
                              value: entry.key,
                              label: Text(entry.value),
                            ),
                        ],
                        selected: <String?>{method},
                        onSelectionChanged: (s) =>
                            setState(() => method = s.first),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: note,
                        decoration: const InputDecoration(
                          labelText: 'Izoh (ixtiyoriy)',
                        ),
                      ),
                      if (error != null) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          error!,
                          style: TextStyle(color: context.colors.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Bekor qilish'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: saving ? null : save,
                      child: const Text('Saqlash'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
