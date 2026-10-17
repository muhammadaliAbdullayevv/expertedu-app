import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/widgets/bordered_list_tile.dart';
import '../../../core/widgets/table_card.dart';
import '../data/students_repository.dart';
import 'add_student_dialog.dart';
import 'student_summary_dialog.dart';

class StudentsListScreen extends ConsumerStatefulWidget {
  const StudentsListScreen({super.key});

  @override
  ConsumerState<StudentsListScreen> createState() => StudentsListScreenState();
}

class StudentsListScreenState extends ConsumerState<StudentsListScreen> {
  final _searchController = TextEditingController();
  late Future<List<Student>> _future;
  bool _searchVisible = false;
  String _query = '';
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _future = ref.read(studentsRepositoryProvider).list();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _reload({String? query}) {
    setState(() {
      _query = query ?? _query;
      _future = ref.read(studentsRepositoryProvider).list(query: _query);
    });
  }

  /// Called from HomeShell's shared search icon.
  void toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchDebounce?.cancel();
        _searchController.clear();
        _reload(query: '');
      }
    });
  }

  /// True (and search cleared) if there was something to clear -- lets
  /// HomeShell's back-button handling behave like the shop app's.
  bool clearSearchIfActive() {
    if (!_searchVisible) return false;
    toggleSearch();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        if (_searchVisible && !isWideLayout(context))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Qidirish...',
                prefixIcon: Icon(Icons.search),
                isDense: true,
                filled: true,
              ),
              onChanged: (value) {
                _query = value;
                _searchDebounce?.cancel();
                _searchDebounce = Timer(
                  const Duration(milliseconds: 300),
                  () => _reload(query: value),
                );
              },
            ),
          ),
        Expanded(
          child: FutureBuilder<List<Student>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return _LoadFailed(onRetry: _reload);
              }
              final students = snapshot.data ?? const <Student>[];
              if (isWideLayout(context)) {
                return _desktopDirectory(context, students);
              }
              if (students.isEmpty) {
                return const Center(child: Text('Hali o\'quvchilar yo\'q'));
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(
                  vertical: 8,
                ).copyWith(bottom: 88),
                itemCount: students.length,
                itemBuilder: (context, index) {
                  final student = students[index];
                  final owesMoney = student.balance > 0;
                  return BorderedListTile(
                    leading: CircleAvatar(
                      backgroundColor: owesMoney
                          ? Theme.of(context).colorScheme.errorContainer
                          : AppColors.success.withValues(alpha: 0.15),
                      child: Icon(
                        Icons.school,
                        color: owesMoney
                            ? Theme.of(context).colorScheme.error
                            : AppColors.success,
                      ),
                    ),
                    title: Text(student.fullName),
                    subtitle: Text(PhoneFormatter.display(student.phone)),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Icon(
                          owesMoney
                              ? Icons.error_outline
                              : Icons.check_circle_outline,
                          size: 18,
                          color: owesMoney
                              ? Theme.of(context).colorScheme.error
                              : AppColors.success,
                        ),
                        if (owesMoney)
                          Text(
                            CurrencyFormatter.format(student.balance),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                    onTap: () => showStudentSummaryDialog(context, student.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _desktopDirectory(BuildContext context, List<Student> students) {
    final totalDebt = students.fold<int>(
      0,
      (sum, student) => sum + (student.balance > 0 ? student.balance : 0),
    );
    final debtorCount = students.where((student) => student.balance > 0).length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.max(24.0, (constraints.maxWidth - 1400) / 2);
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('O\'quvchilar bazasi', style: context.textTheme.titleLarge),
            const SizedBox(height: 3),
            Text(
              'Aloqa ma\'lumotlari va to\'lov holati',
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        );
        final metrics = <Widget>[
          _DirectoryMetric(
            label: 'Jami',
            value: '${students.length}',
            icon: Icons.school_outlined,
          ),
          _DirectoryMetric(
            label: 'Qarzdor',
            value: '$debtorCount',
            icon: Icons.account_balance_wallet_outlined,
            alert: debtorCount > 0,
          ),
          _DirectoryMetric(
            label: 'Jami qarz',
            value: CurrencyFormatter.format(totalDebt),
            icon: Icons.payments_outlined,
            alert: totalDebt > 0,
          ),
        ];
        return Padding(
          padding: EdgeInsets.fromLTRB(side, 20, side, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (constraints.maxWidth < 1100) ...<Widget>[
                heading,
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: metrics),
              ] else
                Row(
                  children: <Widget>[
                    Expanded(child: heading),
                    for (var i = 0; i < metrics.length; i++) ...<Widget>[
                      if (i > 0) const SizedBox(width: 10),
                      metrics[i],
                    ],
                  ],
                ),
              if (_searchVisible) ...<Widget>[
                const SizedBox(height: 16),
                SizedBox(
                  width: 360,
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Ism yoki telefon bo\'yicha qidirish',
                      suffixIcon: IconButton(
                        tooltip: 'Tozalash',
                        onPressed: () {
                          _searchController.clear();
                          _searchDebounce?.cancel();
                          _reload(query: '');
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ),
                    onChanged: (value) {
                      _query = value;
                      _searchDebounce?.cancel();
                      _searchDebounce = Timer(
                        const Duration(milliseconds: 300),
                        () => _reload(query: value),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: TableCard(
                  emptyText: _query.trim().isEmpty
                      ? 'Hali o\'quvchilar yo\'q'
                      : 'Mos o\'quvchilar topilmadi',
                  columns: const <TableColumn>[
                    TableColumn('O\'quvchi', flex: 4),
                    TableColumn('Telefon', flex: 2),
                    TableColumn('To\'lov holati', flex: 2),
                    TableColumn('Qoldiq', flex: 2, alignEnd: true),
                    TableColumn('', width: 32),
                  ],
                  rowCount: students.length,
                  onRowTap: (row) =>
                      showStudentSummaryDialog(context, students[row].id),
                  cell: (context, row, column) {
                    final student = students[row];
                    final hasDebt = student.balance > 0;
                    return switch (column) {
                      0 => Row(
                        children: <Widget>[
                          CircleAvatar(
                            radius: 17,
                            backgroundColor: AppColors.accentSoft,
                            foregroundColor: AppColors.accent,
                            child: Text(
                              student.fullName.isEmpty
                                  ? '?'
                                  : student.fullName[0].toUpperCase(),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  student.fullName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (student.parentPhone != null)
                                  Text(
                                    'Ota-ona: ${PhoneFormatter.display(student.parentPhone!)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.textTheme.bodySmall
                                        ?.copyWith(
                                          color:
                                              context.colors.onSurfaceVariant,
                                        ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      1 => Text(PhoneFormatter.display(student.phone)),
                      2 => _BalanceStatus(hasDebt: hasDebt),
                      3 => Text(
                        CurrencyFormatter.format(student.balance),
                        textAlign: TextAlign.end,
                        style: context.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: hasDebt ? context.colors.error : null,
                        ),
                      ),
                      _ => Icon(
                        Icons.chevron_right_rounded,
                        color: context.colors.outline,
                      ),
                    };
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Called from HomeShell's shared FAB (phone) and the sidebar's
  /// "Yangi o'quvchi" (desktop) -- see its GlobalKey\<StudentsListScreenState\>.
  Future<void> showCreateSheet() async {
    final saved = await showAddStudentDialog(context);
    if (saved == true) {
      _reload();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('O\'quvchi saqlandi')));
      }
    }
  }
}

class _DirectoryMetric extends StatelessWidget {
  const _DirectoryMetric({
    required this.label,
    required this.value,
    required this.icon,
    this.alert = false,
  });

  final String label;
  final String value;
  final IconData icon;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final color = alert ? context.colors.error : context.colors.primary;
    return Container(
      constraints: const BoxConstraints(minHeight: 50, maxWidth: 210),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                label,
                style: context.textTheme.labelSmall?.copyWith(
                  color: context.colors.onSurfaceVariant,
                ),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: alert ? context.colors.error : null,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BalanceStatus extends StatelessWidget {
  const _BalanceStatus({required this.hasDebt});

  final bool hasDebt;

  @override
  Widget build(BuildContext context) {
    final color = hasDebt ? context.colors.error : AppColors.success;
    final background = hasDebt
        ? context.colors.errorContainer
        : AppColors.success.withValues(alpha: 0.1);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            hasDebt ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 5),
          Text(
            hasDebt ? 'Qarzdor' : 'Hisob toza',
            style: context.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
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
          const Text('O\'quvchilarni yuklab bo\'lmadi'),
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
