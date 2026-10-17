import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/layout/breakpoints.dart';
import '../../groups/data/groups_repository.dart';
import '../../inquiries/data/inquiries_repository.dart';
import '../../inquiries/presentation/add_inquiry_sheet.dart';
import '../../inquiries/presentation/inquiry_card.dart';
import '../../students/data/students_repository.dart';
import 'desktop_dashboard.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key, required this.onOpenDebtors});

  /// Switches HomeShell to the (desktop-only) Qarzdorlar tab.
  final VoidCallback onOpenDebtors;

  @override
  ConsumerState<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends ConsumerState<DashboardScreen> {
  final _desktopKey = GlobalKey<DesktopDashboardState>();

  // Only the phone layout shows these two counts -- loaded the first time
  // it's actually built, so the desktop never fetches the full group and
  // student lists just to count them.
  Future<_Counts>? _countsFuture;
  late Future<List<Inquiry>> _inquiriesFuture;

  @override
  void initState() {
    super.initState();
    _inquiriesFuture = ref.read(inquiriesRepositoryProvider).list();
  }

  Future<_Counts> _loadCounts() async {
    final groups = await ref.read(groupsRepositoryProvider).list();
    final students = await ref.read(studentsRepositoryProvider).list();
    return _Counts(groups: groups.length, students: students.length);
  }

  /// Also refreshes the desktop summary -- its lead counts and today's
  /// trial lessons change with every logged call or status change.
  void _reloadInquiries() {
    setState(
      () => _inquiriesFuture = ref.read(inquiriesRepositoryProvider).list(),
    );
    _desktopKey.currentState?.reload();
  }

  /// HomeShell's refresh button on wide layouts, where pull-to-refresh
  /// doesn't exist (a mouse can't drag a list past its top).
  void reload() {
    setState(() {
      if (_countsFuture != null) _countsFuture = _loadCounts();
      _inquiriesFuture = ref.read(inquiriesRepositoryProvider).list();
    });
    _desktopKey.currentState?.reload();
  }

  /// No search on this tab -- see HomeShell's back-button handling.
  bool clearSearchIfActive() => false;

  /// Called from HomeShell's shared FAB -- see its GlobalKey\<DashboardScreenState\>.
  Future<void> showCreateSheet() async {
    final logged = await showAddInquirySheet(context);
    if (logged == true) _reloadInquiries();
  }

  @override
  Widget build(BuildContext context) {
    if (isWideLayout(context)) {
      return DesktopDashboard(
        key: _desktopKey,
        inquiries: _inquiriesFuture,
        onInquiriesChanged: _reloadInquiries,
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
                onPressed: () async {
                  final logged = await showAddInquirySheet(context);
                  if (logged == true) _reloadInquiries();
                },
                icon: const Icon(Icons.add_call),
                label: const Text('Qo\'ng\'iroq'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<Inquiry>>(
            future: _inquiriesFuture,
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
              final inquiries = snapshot.data ?? const <Inquiry>[];
              if (inquiries.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: Text('Hali so\'rovlar yo\'q')),
                );
              }
              return Column(
                children: inquiries
                    .map(
                      (inquiry) => InquiryCard(
                        inquiry: inquiry,
                        onChanged: _reloadInquiries,
                      ),
                    )
                    .toList(),
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
