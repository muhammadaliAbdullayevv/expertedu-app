import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/dashboard/data/dashboard_repository.dart';
import '../../features/teachers/data/teachers_repository.dart';
import '../navigation/destinations.dart';

/// The small numbers beside sidebar labels. Each count comes from data the
/// app already loads; one that can't be fetched (offline, a role without
/// access) is simply missing and shows no badge.
final shellCountsProvider = FutureProvider<Map<Destination, int>>((ref) async {
  final counts = <Destination, int>{};
  try {
    final summary = await ref.read(dashboardRepositoryProvider).fetch();
    counts[Destination.admissions] = summary.openLeads;
    counts[Destination.students] = summary.activeStudents;
    counts[Destination.groups] = summary.activeGroups;
  } catch (_) {}
  try {
    final teachers = await ref.read(teachersRepositoryProvider).list();
    counts[Destination.teachers] = teachers.where((t) => t.isActive).length;
  } catch (_) {}
  return counts;
});
