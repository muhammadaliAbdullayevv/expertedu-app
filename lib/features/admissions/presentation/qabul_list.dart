import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../services/api/api_client.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';
import 'student_dialog.dart';

/// "Ro'yxat": the people saved at the front desk who have not joined yet --
/// name, phone, group, date -- with a search and two buttons: "O'quvchi
/// qilish" and "Arxiv". Nothing else.
class QabulList extends ConsumerStatefulWidget {
  const QabulList({super.key, required this.searchFocus});

  /// Focused by Ctrl+F from the page.
  final FocusNode searchFocus;

  @override
  ConsumerState<QabulList> createState() => _QabulListState();
}

class _QabulListState extends ConsumerState<QabulList> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  late Future<(LeadPage, List<Lead>)> _data = _load();
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);

  @override
  void initState() {
    super.initState();
    _refresh.addListener(_reload);
  }

  @override
  void dispose() {
    _refresh.removeListener(_reload);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    final next = _load();
    setState(() {
      _data = next;
    });
  }

  Future<(LeadPage, List<Lead>)> _load() async {
    final repo = ref.read(admissionsRepositoryProvider);
    final page = await repo.listLeads(query: _query);
    // Saved while the internet was down and not sent yet: first in the list,
    // so nobody is saved twice for lack of seeing them.
    final pending = _query.isEmpty ? await repo.pendingLeads() : const <Lead>[];
    return (page, pending);
  }

  Future<void> _makeStudent(Lead lead) async {
    final message = await showStudentDialog(
      context,
      lead: lead,
      groupId: lead.groupId,
    );
    if (message != null && mounted) showSnack(context, message);
    refreshAdmissions(ref);
  }

  /// Arxiv: the person is kept (never deleted), only taken off this list.
  Future<void> _archive(Lead lead) async {
    try {
      await ref
          .read(admissionsRepositoryProvider)
          .changeStage(lead, LeadStage.notInterested, reason: 'Arxivga olindi');
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 340,
              child: TextField(
                key: const ValueKey('qabul-search'),
                controller: _search,
                focusNode: widget.searchFocus,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 20),
                  hintText: 'Ism yoki telefon',
                ),
                onChanged: (value) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), () {
                    _query = value.trim();
                    _reload();
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<(LeadPage, List<Lead>)>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoadFailed(error: snapshot.error!, onRetry: _reload);
                }
                final data = snapshot.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final leads = <Lead>[...data.$2, ...data.$1.items];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _Demand(leads: leads),
                    Expanded(child: _table(leads)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(List<Lead> leads) {
    if (leads.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Text(
            _query.isNotEmpty
                ? 'Hech narsa topilmadi.'
                : 'Hali hech kim saqlanmagan. "Yangi qo\'shish" bilan boshlang.',
            style: const TextStyle(color: AppColors.inkMuted),
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          const _HeaderRow(),
          const Divider(height: 1, color: AppColors.divider),
          Expanded(
            child: ListView.separated(
              itemCount: leads.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.divider),
              itemBuilder: (context, i) => _LeadRow(
                key: ValueKey('lead-${leads[i].id}-${leads[i].clientId}'),
                lead: leads[i],
                onStudent: () => _makeStudent(leads[i]),
                onArchive: () => _archive(leads[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _muted = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w600,
  color: AppColors.inkMuted,
);

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: <Widget>[
          Expanded(flex: 4, child: Text('Mijoz', style: _muted)),
          Expanded(flex: 4, child: Text('Guruh', style: _muted)),
          Expanded(flex: 2, child: Text('Sana', style: _muted)),
          SizedBox(width: 250),
        ],
      ),
    );
  }
}

class _LeadRow extends StatelessWidget {
  const _LeadRow({
    super.key,
    required this.lead,
    required this.onStudent,
    required this.onArchive,
  });

  final Lead lead;
  final VoidCallback onStudent;
  final VoidCallback onArchive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  lead.fullName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  PhoneFormatter.display(lead.phone),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkMuted,
                  ),
                ),
                if (lead.address != null && lead.address!.isNotEmpty)
                  Text(
                    lead.address!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.inkMuted,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(flex: 4, child: _GroupCell(lead: lead)),
          Expanded(
            flex: 2,
            child: lead.isPending
                ? const Align(
                    alignment: Alignment.centerLeft,
                    child: StatusChip('Yuborilmagan', tone: StatusTone.warning),
                  )
                : Text(
                    DateFormatters.date(lead.createdAt),
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.inkSecondary,
                    ),
                  ),
          ),
          SizedBox(
            width: 250,
            child: lead.isPending
                ? const SizedBox.shrink()
                : Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      FilledButton(
                        key: const ValueKey('row-student'),
                        onPressed: onStudent,
                        child: const Text('O\'quvchi qilish'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        key: const ValueKey('row-archive'),
                        onPressed: onArchive,
                        child: const Text('Arxiv'),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// The group a person asked for -- or, for someone with no group yet, a
/// "Kutmoqda" mark with the subject, level and what they said about time.
class _GroupCell extends StatelessWidget {
  const _GroupCell({required this.lead});

  final Lead lead;

  @override
  Widget build(BuildContext context) {
    if (lead.groupName != null) {
      return Text(
        lead.groupName!,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      );
    }
    final wish = demandLabel(lead);
    final note = lead.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            const StatusChip('Kutmoqda', tone: StatusTone.warning),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                wish,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (note != null && note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              note,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
            ),
          ),
      ],
    );
  }
}

/// "Fransuz tili · A1" -- what a person with no group is waiting for.
String demandLabel(Lead lead) {
  final parts = <String>[
    ?lead.subjectName,
    if (lead.level != null && lead.level!.isNotEmpty) lead.level!,
  ];
  return parts.isEmpty ? 'Guruh tanlanmagan' : parts.join(' · ');
}

/// What the people with no group are waiting for, most wanted first -- so
/// the center can see "5 people want French A1" before it opens a group.
/// Hidden when nobody is waiting.
class _Demand extends StatelessWidget {
  const _Demand({required this.leads});

  final List<Lead> leads;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final lead in leads) {
      if (lead.groupId != null || lead.groupName != null) continue;
      counts.update(demandLabel(lead), (n) => n + 1, ifAbsent: () => 1);
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    final ordered = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Padding(
      key: const ValueKey('demand'),
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 4, right: 14),
              child: Text(
                'Guruh kutayotganlar',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final e in ordered)
                    StatusChip(
                      '${e.key}: ${e.value} kishi',
                      tone: e.value >= 4 ? StatusTone.ok : StatusTone.neutral,
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
