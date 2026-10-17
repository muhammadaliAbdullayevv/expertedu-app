import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../services/sync/sync_engine.dart';
import 'admissions_overview.dart';
import 'admissions_ui.dart';
import 'follow_ups_view.dart';
import 'lead_details_panel.dart';
import 'leads_view.dart';
import 'new_inquiry_dialog.dart';
import 'pending_changes_dialog.dart';
import 'pipeline_view.dart';
import 'trials_view.dart';

/// "Qabul" (desktop): prospects from the first call to enrollment.
///
/// Keyboard: Ctrl+N new inquiry, Ctrl+F search leads, Ctrl+1..5 tabs,
/// F5 reload; inside dialogs Ctrl+Enter saves and Esc closes.
class AdmissionsScreen extends ConsumerStatefulWidget {
  const AdmissionsScreen({super.key});

  @override
  ConsumerState<AdmissionsScreen> createState() => AdmissionsScreenState();
}

class AdmissionsScreenState extends ConsumerState<AdmissionsScreen>
    with SingleTickerProviderStateMixin {
  static const List<String> _tabs = <String>[
    'Umumiy',
    'So\'rovlar',
    'Voronka',
    'Sinov darslari',
    'Vazifalar',
  ];

  static const List<LogicalKeyboardKey> _tabKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
  ];

  late final TabController _tabController = TabController(
    length: _tabs.length,
    vsync: this,
  );
  final _searchFocus = FocusNode();
  late final SyncEngine _sync = ref.read(syncEngineProvider);

  @override
  void initState() {
    super.initState();
    // Something queued offline just reached the server: show it for real.
    _sync.syncedRevision.addListener(_onSynced);
  }

  @override
  void dispose() {
    _sync.syncedRevision.removeListener(_onSynced);
    _tabController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSynced() => refreshAdmissions(ref);

  void reload() => refreshAdmissions(ref);

  Future<void> newInquiry() async {
    final result = await showNewInquiryDialog(context);
    if (!mounted || result == null) return;
    refreshAdmissions(ref);
    switch (result) {
      case InquiryCreated(:final lead):
        if (lead.isPending) {
          showSnack(
            context,
            'Oflayn saqlandi — internet qaytganda yuboriladi.',
          );
        } else if (lead.merged) {
          showSnack(context, 'Bu raqamdagi ochiq so\'rovga qo\'shildi.');
        }
        // Straight on to the next step: a trial, a task, a note.
        await showLeadDetails(context, leadId: lead.id, lead: lead);
      case InquiryOpenExisting(:final leadId):
        await showLeadDetails(context, leadId: leadId);
    }
  }

  void _focusSearch() {
    _tabController.animateTo(1);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            newInquiry,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.f5): reload,
        for (final (i, key) in _tabKeys.indexed)
          SingleActivator(key, control: true): () =>
              _tabController.animateTo(i),
      },
      child: Focus(
        autofocus: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              decoration: BoxDecoration(
                color: context.colors.surface,
                border: Border(
                  bottom: BorderSide(color: context.colors.outlineVariant),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(12, 0, 16, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      dividerHeight: 0,
                      indicatorColor: AppColors.accent,
                      indicatorWeight: 3,
                      labelColor: context.colors.onSurface,
                      unselectedLabelColor: context.colors.onSurfaceVariant,
                      labelStyle: context.textTheme.labelLarge,
                      tabs: <Tab>[for (final tab in _tabs) Tab(text: tab)],
                    ),
                  ),
                  _SyncStatus(sync: _sync),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Ctrl+N',
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onPressed: newInquiry,
                      icon: const Icon(Icons.add_call, size: 18),
                      label: const Text('Yangi so\'rov'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                // Drag-and-drop on the board would fight a swipeable tab view.
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  AdmissionsOverview(onOpenTab: _tabController.animateTo),
                  LeadsView(searchFocus: _searchFocus),
                  const PipelineView(),
                  const TrialsView(),
                  const FollowUpsView(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Oflayn" and "N ta yuborilmagan" -- tap to see what's waiting.
class _SyncStatus extends StatelessWidget {
  const _SyncStatus({required this.sync});

  final SyncEngine sync;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: sync.online,
      builder: (context, online, _) => ValueListenableBuilder<int>(
        valueListenable: sync.pendingCount,
        builder: (context, pending, _) {
          if (online && pending == 0) return const SizedBox.shrink();
          return TextButton.icon(
            onPressed: () => showPendingChangesDialog(context),
            icon: Icon(
              online ? Icons.cloud_upload_outlined : Icons.cloud_off_rounded,
              size: 18,
              color: online ? null : context.colors.error,
            ),
            label: Text(
              <String>[
                if (!online) 'Oflayn',
                if (pending > 0) '$pending ta yuborilmagan',
              ].join(' · '),
            ),
          );
        },
      ),
    );
  }
}
