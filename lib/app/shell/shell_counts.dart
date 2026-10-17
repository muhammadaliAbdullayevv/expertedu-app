import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/admissions/data/qabul_models.dart';
import '../../features/admissions/data/qabul_repository.dart';
import '../navigation/destinations.dart';

/// The small numbers beside sidebar labels. They come from the server's one
/// definition of every lead/student count (server/app/funnel.py), so they
/// are the very numbers Qabul, Bugun and O'quvchilar show. One that can't be
/// fetched (offline) is simply missing and shows no badge.
final shellCountsProvider = FutureProvider<Map<Destination, int>>((ref) async {
  try {
    final c = await ref.read(qabulRepositoryProvider).shellCounts();
    return {
      Destination.students: c.activeStudents,
      Destination.groups: c.activeGroups,
      Destination.teachers: c.activeTeachers,
    };
  } catch (_) {
    return const {};
  }
});

/// O'quvchilar' header numbers -- leads, trials included, are not students.
final studentSummaryProvider = FutureProvider<StudentSummary?>((ref) async {
  try {
    return await ref.read(qabulRepositoryProvider).studentSummary();
  } catch (_) {
    return null;
  }
});
