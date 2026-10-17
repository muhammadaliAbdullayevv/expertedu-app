import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../billing/presentation/record_payment_sheet.dart';
import '../../billing/presentation/transaction_history_screen.dart';
import '../data/debtors_repository.dart';
import 'overdue_label.dart';

enum _Sort { amount, overdue }

/// Desktop-only (see HomeShell): every enrollment that owes money, as a
/// filterable, sortable table -- the screen for a collections pass.
class DebtorsScreen extends ConsumerStatefulWidget {
  const DebtorsScreen({super.key});

  @override
  ConsumerState<DebtorsScreen> createState() => DebtorsScreenState();
}

class DebtorsScreenState extends ConsumerState<DebtorsScreen> {
  static const double _maxContentWidth = 1400;
  static const double _actionsWidth = 196;

  late Future<List<Debtor>> _future;
  final _searchController = TextEditingController();
  String _query = '';
  int? _groupId;
  bool _includeWithdrawn = true;
  _Sort _sort = _Sort.amount;

  @override
  void initState() {
    super.initState();
    _future = ref.read(debtorsRepositoryProvider).list();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void reload() {
    final next = ref.read(debtorsRepositoryProvider).list();
    setState(() {
      _future = next;
    });
  }

  List<Debtor> _visible(List<Debtor> all) {
    final query = _query.trim().toLowerCase();
    final digits = query.replaceAll(RegExp(r'\D'), '');
    final rows = all.where((debtor) {
      if (!_includeWithdrawn && debtor.isWithdrawn) return false;
      if (_groupId != null && debtor.groupId != _groupId) return false;
      if (query.isEmpty) return true;
      return debtor.studentFullName.toLowerCase().contains(query) ||
          (digits.isNotEmpty && debtor.studentPhone.contains(digits));
    }).toList();

    switch (_sort) {
      case _Sort.amount:
        rows.sort((a, b) => b.balance.compareTo(a.balance));
      case _Sort.overdue:
        // Longest-unpaid first; a debt with no unpaid charge date (can't
        // normally happen) sinks to the bottom.
        rows.sort((a, b) {
          final ad = a.oldestUnpaidDue, bd = b.oldestUnpaidDue;
          if (ad == null) return bd == null ? 0 : 1;
          if (bd == null) return -1;
          return ad.compareTo(bd);
        });
    }
    return rows;
  }

  Future<void> _recordPayment(Debtor debtor) async {
    final paid = await showRecordPaymentSheet(
      context,
      enrollmentId: debtor.enrollmentId,
      balance: debtor.balance,
    );
    if (paid == true) reload();
  }

  Future<void> _openHistory(Debtor debtor) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TransactionHistoryScreen(
          enrollmentId: debtor.enrollmentId,
          studentName: debtor.studentFullName,
        ),
      ),
    );
    // A payment may have been recorded from the history screen too.
    reload();
  }

  void _copyPhone(String phone) {
    Clipboard.setData(ClipboardData(text: PhoneFormatter.display(phone)));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Telefon raqam nusxalandi')));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Debtor>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('Ma\'lumotlarni yuklab bo\'lmadi: ${snapshot.error}'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: reload,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Qayta urinish'),
                ),
              ],
            ),
          );
        }

        final all = snapshot.data!;
        final rows = _visible(all);
        final total = rows.fold<int>(0, (sum, d) => sum + d.balance);
        final students = rows.map((d) => d.studentId).toSet().length;
        final groups = <int, String>{
          for (final debtor in all) debtor.groupId: debtor.groupName,
        }.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
        final today = DateTime.now();

        return LayoutBuilder(
          builder: (context, constraints) {
            final sidePadding = math.max(
              24.0,
              (constraints.maxWidth - _maxContentWidth) / 2,
            );
            return Padding(
              padding: EdgeInsets.fromLTRB(sidePadding, 20, sidePadding, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      SizedBox(
                        width: 300,
                        child: TextField(
                          controller: _searchController,
                          onChanged: (value) => setState(() => _query = value),
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Ism yoki telefon',
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _query = '');
                                    },
                                  ),
                          ),
                        ),
                      ),
                      DropdownButton<int?>(
                        value: _groupId,
                        borderRadius: BorderRadius.circular(12),
                        onChanged: (value) => setState(() => _groupId = value),
                        items: <DropdownMenuItem<int?>>[
                          const DropdownMenuItem(
                            value: null,
                            child: Text('Barcha guruhlar'),
                          ),
                          for (final group in groups)
                            DropdownMenuItem(
                              value: group.key,
                              child: Text(group.value),
                            ),
                        ],
                      ),
                      FilterChip(
                        label: const Text('Chiqib ketganlar ham'),
                        selected: _includeWithdrawn,
                        onSelected: (value) =>
                            setState(() => _includeWithdrawn = value),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Jami: ${CurrencyFormatter.format(total)} · $students o\'quvchi',
                    style: context.textTheme.titleMedium?.copyWith(
                      color: total > 0 ? context.colors.error : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Card(
                      margin: const EdgeInsets.only(bottom: 16),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: <Widget>[
                          _headerRow(context),
                          const Divider(height: 1),
                          Expanded(
                            child: rows.isEmpty
                                ? Center(
                                    child: Text(
                                      all.isEmpty
                                          ? 'Hech kim qarzdor emas'
                                          : 'Mos keladigan qarzdor topilmadi',
                                      style: context.textTheme.bodyMedium
                                          ?.copyWith(
                                            color:
                                                context.colors.onSurfaceVariant,
                                          ),
                                    ),
                                  )
                                : ListView.separated(
                                    itemCount: rows.length,
                                    separatorBuilder: (_, _) =>
                                        const Divider(height: 1),
                                    itemBuilder: (context, index) =>
                                        _row(context, rows[index], today),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _headerRow(BuildContext context) {
    final style = context.textTheme.labelMedium?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    Widget sortable(String label, _Sort sort, {TextAlign? align}) {
      final active = _sort == sort;
      return InkWell(
        onTap: () => setState(() => _sort = sort),
        child: Row(
          mainAxisAlignment: align == TextAlign.end
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: style?.copyWith(
                fontWeight: active ? FontWeight.w700 : null,
                color: active ? context.colors.onSurface : null,
              ),
            ),
            if (active)
              Icon(
                Icons.arrow_downward_rounded,
                size: 14,
                color: context.colors.onSurface,
              ),
          ],
        ),
      );
    }

    return Container(
      color: context.colors.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: <Widget>[
          Expanded(flex: 3, child: Text('O\'quvchi', style: style)),
          Expanded(flex: 2, child: Text('Telefon', style: style)),
          Expanded(flex: 2, child: Text('Guruh', style: style)),
          Expanded(
            flex: 2,
            child: sortable('Qarz', _Sort.amount, align: TextAlign.end),
          ),
          const SizedBox(width: 24),
          Expanded(flex: 2, child: sortable('Qachondan', _Sort.overdue)),
          const SizedBox(width: _actionsWidth),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Debtor debtor, DateTime today) {
    final muted = context.textTheme.bodySmall?.copyWith(
      color: context.colors.onSurfaceVariant,
    );
    return InkWell(
      onTap: () => _openHistory(debtor),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 3,
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      debtor.studentFullName,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (debtor.isWithdrawn) ...<Widget>[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: context.colors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('chiqib ketgan', style: muted),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: 'Nusxa olish',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _copyPhone(debtor.studentPhone),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 4,
                      ),
                      child: Text(PhoneFormatter.display(debtor.studentPhone)),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(debtor.groupName, overflow: TextOverflow.ellipsis),
            ),
            Expanded(
              flex: 2,
              child: Text(
                CurrencyFormatter.format(debtor.balance),
                textAlign: TextAlign.end,
                style: context.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: context.colors.error,
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              flex: 2,
              child: debtor.oldestUnpaidDue == null
                  ? const SizedBox.shrink()
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(DateFormatters.date(debtor.oldestUnpaidDue!)),
                        Text(
                          overdueLabel(debtor.oldestUnpaidDue, today),
                          style: muted,
                        ),
                      ],
                    ),
            ),
            SizedBox(
              width: _actionsWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  IconButton(
                    tooltip: 'To\'lovlar tarixi',
                    onPressed: () => _openHistory(debtor),
                    icon: const Icon(Icons.receipt_long_outlined),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.tonal(
                    onPressed: () => _recordPayment(debtor),
                    child: const Text('To\'lov'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
