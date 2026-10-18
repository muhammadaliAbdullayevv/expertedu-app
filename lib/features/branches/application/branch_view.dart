import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../data/branches_repository.dart';

/// Which branch the owner is looking at: one (its id), or null = Hammasi (all
/// of them). Every request carries it as the X-Branch header; an admin never
/// has a choice -- the server puts them in their own branch whatever is sent.
///
/// The single source of truth for requests is [ApiClient.branchId]; the state
/// here lets the sidebar, the shell and the lists hear about a change.
class BranchView extends Notifier<int?> {
  @override
  int? build() => ref.read(apiClientProvider).branchId;

  /// Look at one branch (or [null] = all).
  void select(int? id) {
    final api = ref.read(apiClientProvider);
    if (api.branchId == id && state == id) return;
    api.branchId = id;
    state = id;
  }

  /// A new session starts looking at everything.
  void reset() => select(null);
}

final branchViewProvider = NotifierProvider<BranchView, int?>(BranchView.new);

/// The branches (all of them for the owner, just one for an admin).
final branchListProvider = FutureProvider<List<Branch>>(
  (ref) => ref.read(branchesRepositoryProvider).list(),
);

/// Whether lists should say which branch each row belongs to: when every
/// branch is in view and there is more than one to tell apart. (An admin's
/// branch list has just their own branch, so they never see labels.)
final showBranchLabelsProvider = Provider<bool>((ref) {
  final viewing = ref.watch(branchViewProvider);
  final count = ref.watch(branchListProvider).value?.length ?? 0;
  return viewing == null && count > 1;
});
