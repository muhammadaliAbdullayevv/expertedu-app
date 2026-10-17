import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../services/api/api_client.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import '../data/qabul_models.dart';
import 'admissions_ui.dart';
import 'lead_details_panel.dart';
import 'qabul_form.dart';
import 'qabul_text.dart';
import 'student_dialog.dart';
import 'trial_booking_dialog.dart';

/// What the list is showing: filters picked by the operator.
class QabulFilters {
  const QabulFilters({
    this.query = '',
    this.groupId,
    this.groupless = false,
    this.withTrial = false,
    this.archive = false,
  });

  final String query;
  final int? groupId;
  final bool groupless;
  final bool withTrial;
  final bool archive;

  QabulFilters copy({
    String? query,
    Object? groupId = _keep,
    bool? groupless,
    bool? withTrial,
    bool? archive,
  }) => QabulFilters(
    query: query ?? this.query,
    groupId: identical(groupId, _keep) ? this.groupId : groupId as int?,
    groupless: groupless ?? this.groupless,
    withTrial: withTrial ?? this.withTrial,
    archive: archive ?? this.archive,
  );

  static const Object _keep = Object();
}

/// "Ro'yxat": the people saved at the front desk who have not joined yet.
/// Search, filters (group, groupless, with a trial, archive) and the three
/// actions: Sinov darsi, O'quvchi qilish, Arxiv.
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
  QabulFilters _filters = const QabulFilters();
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

  void _set(QabulFilters filters) {
    _filters = filters;
    _reload();
  }

  Future<(LeadPage, List<Lead>)> _load() async {
    final repo = ref.read(admissionsRepositoryProvider);
    final f = _filters;
    final page = await repo.listLeads(
      query: f.query,
      groupId: f.groupId,
      groupless: f.groupless,
      withTrial: f.withTrial,
      archive: f.archive,
    );
    // Saved while offline, not sent yet: first in the list, so nobody is
    // saved twice for lack of seeing them. Only where no filter hides them.
    final plain =
        !f.archive &&
        f.query.isEmpty &&
        f.groupId == null &&
        !f.withTrial &&
        !f.groupless;
    final pending = plain ? await repo.pendingLeads() : const <Lead>[];
    return (page, pending);
  }

  // --- Actions --------------------------------------------------------------

  Future<void> _bookTrial(Lead lead) async {
    await showTrialBookingDialog(context, lead: lead, groupId: lead.groupId);
    _reload();
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

  /// Arxiv: no question asked -- it is one click to bring the person back.
  Future<void> _archive(Lead lead) async {
    final repo = ref.read(admissionsRepositoryProvider);
    try {
      final archived = await repo.changeStage(
        lead,
        LeadStage.notInterested,
        reason: 'Arxivga olindi',
      );
      if (!mounted) return;
      showSnack(
        context,
        '${lead.fullName} arxivga olindi.',
        actionLabel: 'Qaytarish',
        onAction: () => _restore(archived),
      );
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
    _reload();
  }

  Future<void> _restore(Lead lead) async {
    try {
      await ref
          .read(admissionsRepositoryProvider)
          .changeStage(lead, LeadStage.contacted);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
    _reload();
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(qabulGroupsProvider).value ?? const <GroupMatch>[];
    final byId = {for (final g in groups) g.groupId: g};
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _filterBar(groups),
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
                return _table(leads, byId);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterBar(List<GroupMatch> groups) {
    final f = _filters;
    final groupLabel = f.groupId == null
        ? 'Hammasi'
        : groups
                  .where((g) => g.groupId == f.groupId)
                  .map((g) => g.name)
                  .firstOrNull ??
              'Tanlangan';
    return Row(
      children: <Widget>[
        SizedBox(
          width: 300,
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
              _debounce = Timer(
                const Duration(milliseconds: 300),
                () => _set(_filters.copy(query: value.trim())),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        PopupMenuButton<int>(
          key: const ValueKey('qabul-group-filter'),
          tooltip: 'Guruh bo\'yicha',
          onSelected: (id) => _set(
            _filters.copy(groupId: id == 0 ? null : id, groupless: false),
          ),
          itemBuilder: (_) => <PopupMenuEntry<int>>[
            const PopupMenuItem(value: 0, child: Text('Hammasi')),
            for (final g in groups)
              PopupMenuItem(value: g.groupId, child: Text(groupTitle(g))),
          ],
          child: _FilterButton(
            selected: f.groupId != null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  'Guruh',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                Text(
                  groupLabel,
                  style: const TextStyle(color: AppColors.inkSecondary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        _FilterButton(
          key: const ValueKey('qabul-groupless'),
          selected: f.groupless,
          onTap: () => _set(
            f.copy(
              groupless: !f.groupless,
              groupId: f.groupless ? f.groupId : null,
            ),
          ),
          child: const Text(
            'Guruhsiz',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 8),
        _FilterButton(
          key: const ValueKey('qabul-with-trial'),
          selected: f.withTrial,
          onTap: () => _set(f.copy(withTrial: !f.withTrial)),
          child: const Text(
            'Sinov belgilangan',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        const Spacer(),
        _FilterButton(
          key: const ValueKey('qabul-archive'),
          selected: f.archive,
          onTap: () => _set(f.copy(archive: !f.archive)),
          child: const Text(
            'Arxiv',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _table(List<Lead> leads, Map<int, GroupMatch> groups) {
    if (leads.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Text(
            _filters.archive
                ? 'Arxivda hech kim yo\'q.'
                : _filters.query.isNotEmpty ||
                      _filters.groupId != null ||
                      _filters.groupless ||
                      _filters.withTrial
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
                group: groups[leads[i].groupId],
                archive: _filters.archive,
                onOpen: () async {
                  final lead = leads[i];
                  await showLeadDetails(
                    context,
                    leadId: lead.id,
                    lead: lead.isPending ? lead : null,
                  );
                  _reload();
                },
                onTrial: () => _bookTrial(leads[i]),
                onStudent: () => _makeStudent(leads[i]),
                onArchive: () => _archive(leads[i]),
                onRestore: () => _restore(leads[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({
    super.key,
    required this.child,
    this.onTap,
    this.selected = false,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.button),
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.button),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
          ),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontSize: 14,
            color: selected ? AppColors.accentText : AppColors.ink,
          ),
          child: child,
        ),
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
          SizedBox(width: 50),
          Expanded(flex: 5, child: Text('Mijoz', style: _muted)),
          Expanded(flex: 5, child: Text('Guruh', style: _muted)),
          Expanded(flex: 4, child: Text('Sinov', style: _muted)),
          Expanded(flex: 3, child: Text('Qo\'shilgan', style: _muted)),
          SizedBox(width: 320),
        ],
      ),
    );
  }
}

class _LeadRow extends StatelessWidget {
  const _LeadRow({
    super.key,
    required this.lead,
    required this.group,
    required this.archive,
    required this.onOpen,
    required this.onTrial,
    required this.onStudent,
    required this.onArchive,
    required this.onRestore,
  });

  final Lead lead;
  final GroupMatch? group;
  final bool archive;
  final VoidCallback onOpen;
  final VoidCallback onTrial;
  final VoidCallback onStudent;
  final VoidCallback onArchive;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final trial = lead.nextTrialAt;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              radius: 18,
              backgroundColor: AppColors.accentSoft,
              child: Text(
                initials(lead.fullName),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppColors.accentText,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              flex: 5,
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
                ],
              ),
            ),
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    lead.groupName ?? 'Guruhsiz',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _groupLine(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Align(
                alignment: Alignment.centerLeft,
                child: lead.isPending
                    ? const StatusChip('Yuborilmagan', tone: StatusTone.warning)
                    : trial == null
                    ? const Text(
                        '–',
                        style: TextStyle(color: AppColors.inkMuted),
                      )
                    : StatusChip(
                        'Sinov: ${trial.day}-${_shortMonth(trial)} ${clock(trial)}',
                        tone: StatusTone.info,
                      ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                _added(now),
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.inkSecondary,
                ),
              ),
            ),
            SizedBox(width: 320, child: _actions(context)),
          ],
        ),
      ),
    );
  }

  String _shortMonth(DateTime d) => dayMonth(d).split('-').last.substring(0, 3);

  String _added(DateTime now) {
    final days = daysSince(lead.createdAt, now);
    return days <= 0 ? 'Bugun' : '$days kun oldin';
  }

  /// Under the group: its days and time, or what a groupless person wants.
  String _groupLine() {
    final g = group;
    if (g != null) return slotsLabel(g.slots);
    final parts = <String>[
      ?lead.subjectName,
      if (lead.note != null && lead.note!.isNotEmpty) lead.note!,
    ];
    return parts.isEmpty ? '' : parts.join(', ');
  }

  Widget _actions(BuildContext context) {
    if (lead.isPending) return const SizedBox.shrink();
    if (archive) {
      return Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton(
          key: const ValueKey('row-restore'),
          onPressed: onRestore,
          child: const Text('Qayta ochish'),
        ),
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        OutlinedButton(
          key: const ValueKey('row-trial'),
          onPressed: onTrial,
          child: const Text('Sinov darsi'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('row-student'),
          onPressed: onStudent,
          child: const Text('O\'quvchi qilish'),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          key: const ValueKey('row-more'),
          tooltip: 'Boshqa',
          onSelected: (value) => switch (value) {
            'open' => onOpen(),
            _ => onArchive(),
          },
          itemBuilder: (_) => const <PopupMenuEntry<String>>[
            PopupMenuItem(value: 'open', child: Text('Ochish')),
            PopupMenuItem(value: 'archive', child: Text('Arxiv')),
          ],
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.button),
              border: Border.all(color: AppColors.border),
            ),
            child: const Icon(Icons.more_horiz, size: 18),
          ),
        ),
      ],
    );
  }
}
