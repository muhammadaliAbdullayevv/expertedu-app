import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/data/groups_repository.dart';
import '../../inquiries/data/inquiries_repository.dart';
import '../../inquiries/presentation/add_inquiry_sheet.dart';
import '../../students/data/students_repository.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends ConsumerState<DashboardScreen> {
  late Future<_Counts> _countsFuture;
  late Future<List<Inquiry>> _inquiriesFuture;

  @override
  void initState() {
    super.initState();
    _countsFuture = _loadCounts();
    _inquiriesFuture = ref.read(inquiriesRepositoryProvider).list();
  }

  Future<_Counts> _loadCounts() async {
    final groups = await ref.read(groupsRepositoryProvider).list();
    final students = await ref.read(studentsRepositoryProvider).list();
    return _Counts(groups: groups.length, students: students.length);
  }

  void _reloadInquiries() {
    setState(
      () => _inquiriesFuture = ref.read(inquiriesRepositoryProvider).list(),
    );
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
    final session = ref.watch(sessionControllerProvider);
    return RefreshIndicator(
      onRefresh: () async {
        setState(() {
          _countsFuture = _loadCounts();
          _inquiriesFuture = ref.read(inquiriesRepositoryProvider).list();
        });
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        children: <Widget>[
          Text(
            'Salom, ${session.user?.fullName ?? ''}',
            style: context.textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
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
                      (inquiry) => _InquiryCard(
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

class _InquiryCard extends ConsumerWidget {
  const _InquiryCard({required this.inquiry, required this.onChanged});

  final Inquiry inquiry;
  final VoidCallback onChanged;

  Color _statusColor(BuildContext context) => switch (inquiry.status) {
    'new' => context.colors.primary,
    'contacted' => Colors.orange,
    'scheduled' => Colors.purple,
    'converted' => Colors.green,
    _ => context.colors.outline,
  };

  String _statusLabel() => switch (inquiry.status) {
    'new' => 'Yangi',
    'contacted' => 'Bog\'lanildi',
    'scheduled' => 'Sinovga yozildi',
    'converted' => 'Talaba bo\'ldi',
    _ => 'Yo\'qotildi',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitleParts = <String>[
      inquiry.phone,
      if (inquiry.subjectName != null) inquiry.subjectName!,
      if (inquiry.trialDate != null)
        'Sinov: ${inquiry.trialDate!.day}.${inquiry.trialDate!.month}.${inquiry.trialDate!.year}',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: context.colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: context.colors.outlineVariant),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          leading: CircleAvatar(
            backgroundColor: _statusColor(context).withValues(alpha: 0.15),
            child: Icon(Icons.phone_in_talk, color: _statusColor(context)),
          ),
          title: Text(inquiry.fullName),
          subtitle: Text(subtitleParts.join(' • ')),
          trailing: inquiry.status == 'converted'
              ? Chip(
                  label: Text(_statusLabel()),
                  backgroundColor: _statusColor(
                    context,
                  ).withValues(alpha: 0.15),
                )
              : PopupMenuButton<String>(
                  initialValue: inquiry.status,
                  child: Chip(
                    label: Text(_statusLabel()),
                    backgroundColor: _statusColor(
                      context,
                    ).withValues(alpha: 0.15),
                  ),
                  onSelected: (action) async {
                    final repo = ref.read(inquiriesRepositoryProvider);
                    if (action == 'convert') {
                      await repo.convert(inquiry.id);
                    } else {
                      await repo.updateStatus(inquiry.id, action);
                    }
                    onChanged();
                  },
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem(
                      value: 'contacted',
                      child: Text('Bog\'landim'),
                    ),
                    const PopupMenuItem(
                      value: 'scheduled',
                      child: Text('Sinovga yozildi'),
                    ),
                    const PopupMenuItem(
                      value: 'convert',
                      child: Text('Talabaga aylantirish'),
                    ),
                    const PopupMenuItem(
                      value: 'lost',
                      child: Text('Yo\'qotildi'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
