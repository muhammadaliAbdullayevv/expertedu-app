import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/branch_view.dart';
import '../data/branches_repository.dart';

/// For the owner looking at EVERY branch ("Hammasi"): a new teacher, group,
/// expense or payout has to belong to one branch, so ask which -- and switch
/// the view to it, so what they just made is what they see.
///
/// True when a branch is in view (already, or now) or there is only one
/// branch; false if the owner cancelled.
Future<bool> ensureBranchChosen(
  BuildContext context,
  WidgetRef ref, {
  String what = 'qo\'shiladi',
}) async {
  if (ref.read(branchViewProvider) != null) return true;
  final List<Branch> branches;
  try {
    branches = await ref.read(branchListProvider.future);
  } catch (_) {
    // Cannot tell: let the server decide (it files it under Bosh ofis).
    return true;
  }
  if (branches.length < 2) return true;
  if (!context.mounted) return false;
  final picked = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      key: const ValueKey('choose-branch'),
      title: Text('Qaysi filialga $what?'),
      children: <Widget>[
        for (final b in branches)
          SimpleDialogOption(
            key: ValueKey('choose-branch-${b.id}'),
            onPressed: () => Navigator.of(context).pop(b.id),
            child: Row(
              children: <Widget>[
                const Icon(Icons.apartment_rounded, size: 18),
                const SizedBox(width: 10),
                Text(b.name),
              ],
            ),
          ),
      ],
    ),
  );
  if (picked == null) return false;
  ref.read(branchViewProvider.notifier).select(picked);
  return true;
}
