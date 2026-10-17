import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/layout/breakpoints.dart';
import '../../admissions/data/admissions_models.dart';
import '../../admissions/data/admissions_repository.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../admissions/presentation/lead_card.dart';
import '../../admissions/presentation/lead_details_panel.dart';
import '../../admissions/presentation/new_inquiry_dialog.dart';
import '../../groups/data/groups_repository.dart';
import '../../students/data/students_repository.dart';
import 'desktop_dashboard.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({
    super.key,
    required this.onOpenDebtors,
    required this.onOpenAdmissions,
  });

  /// Switches HomeShell to the (desktop-only) Qarzdorlar tab.
  final VoidCallback onOpenDebtors;

  /// Switches HomeShell to the (desktop-only) Qabul tab.
  final VoidCallback onOpenAdmissions;

  @override
  ConsumerState<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends ConsumerState<DashboardScreen> {
  final _desktopKey = GlobalKey<DesktopDashboardState>();

  // Only the phone layout shows these two counts -- loaded the first time
  // it's actually built, so the desktop never fetches the full group and
  // student lists just to count them.
  Future<_Counts>? _countsFuture;
  late Future<List<Lead>> _leadsFuture = _loadLeads();
  late final ValueNotifier<int> _admissionsRefresh = ref.read(
    admissionsRefreshProvider,
  );

  @override
  void initState() {
    super.initState();
    _admissionsRefresh.addListener(_reloadLeads);
  }

  @override
  void dispose() {
    _admissionsRefresh.removeListener(_reloadLeads);
    super.dispose();
  }

  /// Open leads, offline-queued ones first. On the desktop the panel that
  /// shows them is only built once the summary has loaded, so a failure
  /// can arrive before anything listens -- marked handled here; the panel
  /// still gets the error when it does listen.
  Future<List<Lead>> _loadLeads() {
    Future<List<Lead>> load() async {
      final repo = ref.read(admissionsRepositoryProvider);
      final page = await repo.listLeads();
      return <Lead>[...await repo.pendingLeads(), ...page.items];
    }

    return load()..ignore();
  }

  Future<_Counts> _loadCounts() async {
    final groups = await ref.read(groupsRepositoryProvider).list();
    final students = await ref.read(studentsRepositoryProvider).list();
    return _Counts(groups: groups.length, students: students.length);
  }

  /// Also refreshes the desktop summary -- its lead counts and today's
  /// trial lessons change with every logged call or status change.
  void _reloadLeads() {
    if (!mounted) return;
    setState(() {
      _leadsFuture = _loadLeads();
    });
    _desktopKey.currentState?.reload();
  }

  /// HomeShell's refresh button on wide layouts, where pull-to-refresh
  /// doesn't exist (a mouse can't drag a list past its top).
  void reload() {
    setState(() {
      if (_countsFuture != null) _countsFuture = _loadCounts();
      _leadsFuture = _loadLeads();
    });
    _desktopKey.currentState?.reload();
  }

  /// No search on this tab -- see HomeShell's back-button handling.
  bool clearSearchIfActive() => false;

  /// Called from HomeShell's shared FAB -- see its GlobalKey\<DashboardScreenState\>.
  Future<void> showCreateSheet() async {
    final result = await showNewInquiryDialog(context);
    if (result == null || !mounted) return;
    refreshAdmissions(ref);
    switch (result) {
      case InquiryCreated(:final lead):
        if (lead.isPending) {
          showSnack(
            context,
            'Oflayn saqlandi — internet qaytganda yuboriladi.',
          );
        }
        await showLeadDetails(context, leadId: lead.id, lead: lead);
      case InquiryOpenExisting(:final leadId):
        await showLeadDetails(context, leadId: leadId);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isWideLayout(context)) {
      return DesktopDashboard(
        key: _desktopKey,
        leads: _leadsFuture,
        onOpenAdmissions: widget.onOpenAdmissions,
        onOpenDebtors: widget.onOpenDebtors,
      );
    }

    _countsFuture ??= _loadCounts();
    return RefreshIndicator(
      onRefresh: () async {
        reload();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        children: <Widget>[
          FutureBuilder<_Counts>(
            future: _countsFuture,
            builder: (context, snapshot) {
              final counts = snapshot.data;
              return Row(
                children: <Widget>[
                  Expanded(
                    child: _StatCard(
                      icon: Icons.menu_book,
                      label: 'Guruhlar',
                      value: counts?.groups.toString() ?? '--',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(
                      icon: Icons.school,
                      label: 'O\'quvchilar',
                      value: counts?.students.toString() ?? '--',
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          Row(
            children: <Widget>[
              Expanded(
                child: Text('So\'rovlar', style: context.textTheme.titleMedium),
              ),
              TextButton.icon(
                onPressed: showCreateSheet,
                icon: const Icon(Icons.add_call),
                label: const Text('Qo\'ng\'iroq'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<Lead>>(
            future: _leadsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Center(child: Text('Xatolik: ${snapshot.error}'));
              }
              final leads = snapshot.data ?? const <Lead>[];
              if (leads.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('Ochiq so\'rovlar yo\'q')),
                );
              }
              return Column(
                children: <Widget>[
                  for (final lead in leads) LeadCard(lead: lead),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Counts {
  const _Counts({required this.groups, required this.students});

  final int groups;
  final int students;
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

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
            Icon(icon, color: context.colors.primary),
            const SizedBox(height: 8),
            Text(value, style: context.textTheme.headlineSmall),
            Text(label, style: context.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
