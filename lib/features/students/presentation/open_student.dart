import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// "Show me this student": anything that wants a student's profile -- a
/// debtor in Bugun or Qarzdorlar, a name in a group's list, a search result --
/// puts the id here; the shell switches to O'quvchilar and the page opens the
/// profile. Payments are taken and cancelled only there.
final openStudentRequestProvider = Provider<ValueNotifier<int?>>((ref) {
  final notifier = ValueNotifier<int?>(null);
  ref.onDispose(notifier.dispose);
  return notifier;
});
