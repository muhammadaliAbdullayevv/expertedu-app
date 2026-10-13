import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/data/groups_repository.dart';
import '../../students/data/students_repository.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends ConsumerState<DashboardScreen> {
  late Future<_Counts> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_Counts> _load() async {
    final groups = await ref.read(groupsRepositoryProvider).list();
    final students = await ref.read(studentsRepositoryProvider).list();
    return _Counts(groups: groups.length, students: students.length);
  }

  /// No search on this tab -- see HomeShell's back-button handling.
  bool clearSearchIfActive() => false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider);
    return RefreshIndicator(
      onRefresh: () async => setState(() => _future = _load()),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        children: <Widget>[
          Text(
            'Salom, ${session.user?.fullName ?? ''}',
            style: context.textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          FutureBuilder<_Counts>(
            future: _future,
            builder: (context, snapshot) {
              final counts = snapshot.data;
              return Row(
                children: <Widget>[
                  Expanded(
                    child: _StatCard(
                      icon: Icons.groups,
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
