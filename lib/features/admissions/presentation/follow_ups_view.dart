import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../services/api/api_client.dart';
import '../../auth/application/session_controller.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';
import 'lead_details_panel.dart';

/// "Vazifalar": open follow-ups -- overdue first, then today, then later.
class FollowUpsView extends ConsumerStatefulWidget {
  const FollowUpsView({super.key});

  @override
  ConsumerState<FollowUpsView> createState() => _FollowUpsViewState();
}

class _FollowUpsViewState extends ConsumerState<FollowUpsView> {
  bool _mineOnly = true;
  late Future<List<FollowUpTask>> _tasks = _load();
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);

  @override
  void initState() {
    super.initState();
    _refresh.addListener(_reload);
  }

  @override
  void dispose() {
    _refresh.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _tasks = _load());
  }

  Future<List<FollowUpTask>> _load() {
    final me = int.tryParse(ref.read(sessionControllerProvider).user?.id ?? '');
    return ref
        .read(admissionsRepositoryProvider)
        .listTasks(assignedTo: _mineOnly ? me : null);
  }

  Future<void> _act(Future<void> Function() action) async {
    try {
      await action();
      refreshAdmissions(ref);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
      refreshAdmissions(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              SegmentedButton<bool>(
                segments: const <ButtonSegment<bool>>[
                  ButtonSegment(value: true, label: Text('Menga')),
                  ButtonSegment(value: false, label: Text('Hammasi')),
                ],
                selected: <bool>{_mineOnly},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  _mineOnly = s.first;
                  _reload();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<List<FollowUpTask>>(
              future: _tasks,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoadFailed(error: snapshot.error!, onRetry: _reload);
                }
                final tasks = snapshot.data;
                if (tasks == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (tasks.isEmpty) {
                  return const EmptyNote('Ochiq vazifa yo\'q');
                }
                final now = DateTime.now();
                final endOfToday = DateUtils.dateOnly(
                  now,
                ).add(const Duration(days: 1));
                final overdue = tasks.where((t) => t.dueAt.isBefore(now));
                final today = tasks.where(
                  (t) => !t.dueAt.isBefore(now) && t.dueAt.isBefore(endOfToday),
                );
                final later = tasks.where((t) => !t.dueAt.isBefore(endOfToday));
                return ListView(
                  children: <Widget>[
                    _group('Muddati o\'tgan', overdue.toList(), alert: true),
                    _group('Bugun', today.toList()),
                    _group('Keyingi', later.toList()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _group(String title, List<FollowUpTask> tasks, {bool alert = false}) {
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Text(
            '$title · ${tasks.length}',
            style: context.textTheme.titleSmall?.copyWith(
              color: alert ? context.colors.error : null,
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Column(
            children: <Widget>[
              for (var i = 0; i < tasks.length; i++) ...<Widget>[
                if (i > 0) const Divider(height: 1),
                _row(tasks[i], alert: alert),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(FollowUpTask task, {required bool alert}) {
    final repo = ref.read(admissionsRepositoryProvider);
    return ListTile(
      leading: Checkbox(
        value: false,
        onChanged: (_) => _act(() => repo.completeTask(task.id)),
      ),
      title: Text(task.title),
      subtitle: Text(
        '${task.leadFullName ?? ''} · ${PhoneFormatter.display(task.leadPhone ?? '')}'
        '${task.leadStage == null ? '' : ' · ${LeadStage.label(task.leadStage!)}'}'
        '${task.assignedToName == null ? '' : ' · ${task.assignedToName}'}',
      ),
      onTap: () => showLeadDetails(context, leadId: task.leadId),
      trailing: Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            shortDateTime(task.dueAt),
            style: TextStyle(color: alert ? context.colors.error : null),
          ),
          IconButton(
            tooltip: 'Ertaga',
            onPressed: () => _act(
              () => repo.rescheduleTask(
                task,
                DateUtils.dateOnly(
                  DateTime.now().add(const Duration(days: 1)),
                ).add(const Duration(hours: 10)),
              ),
            ),
            icon: const Icon(Icons.redo_rounded),
          ),
        ],
      ),
    );
  }
}
