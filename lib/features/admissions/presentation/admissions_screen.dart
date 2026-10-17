import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../services/api/api_client.dart';
import '../../../services/sync/sync_engine.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import '../data/qabul_models.dart';
import 'admissions_overview.dart';
import 'admissions_ui.dart';
import 'after_trial_dialog.dart';
import 'course_finder_screen.dart';
import 'follow_ups_view.dart';
import 'lead_details_panel.dart';
import 'leads_view.dart';
import 'new_inquiry_dialog.dart';
import 'pending_changes_dialog.dart';
import 'qabul_board.dart';
import 'trial_booking_dialog.dart';
import 'trials_view.dart';

enum _Section { leads, trials, tasks, report }

/// "Qabul" (desktop): from the first call to the first lesson -- the board
/// (or its table), the course finder, trials, tasks and the report.
///
/// Keyboard: Ctrl+N new inquiry, Ctrl+F search leads, Ctrl+1..4 sections,
/// F5 reload; inside dialogs Ctrl+Enter saves and Esc closes.
class AdmissionsScreen extends ConsumerStatefulWidget {
  const AdmissionsScreen({super.key});

  @override
  ConsumerState<AdmissionsScreen> createState() => AdmissionsScreenState();
}

class AdmissionsScreenState extends ConsumerState<AdmissionsScreen> {
  static const Map<_Section, String> _labels = <_Section, String>{
    _Section.leads: 'So\'rovlar',
    _Section.trials: 'Sinov darslari',
    _Section.tasks: 'Vazifalar',
    _Section.report: 'Hisobot',
  };

  static const List<LogicalKeyboardKey> _sectionKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
  ];

  _Section _section = _Section.leads;
  bool _table = false;
  bool _finder = false;

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
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSynced() => refreshAdmissions(ref);

  void reload() => refreshAdmissions(ref);

  /// "Yangi so'rov" -- on to the lead's page for the next step.
  Future<void> newInquiry() async {
    final result = await showNewInquiryDialog(context);
    if (!mounted || result == null) return;
    refreshAdmissions(ref);
    switch (result) {
      case InquiryCreated(:final lead):
        _explain(lead);
        await showLeadDetails(context, leadId: lead.id, lead: lead);
      case InquiryOpenExisting(:final leadId):
        await showLeadDetails(context, leadId: leadId);
    }
  }

  void _explain(Lead lead) {
    if (lead.isPending) {
      showSnack(context, 'Oflayn saqlandi — internet qaytganda yuboriladi.');
    } else if (lead.merged) {
      showSnack(context, 'Bu raqamdagi ochiq so\'rovga qo\'shildi.');
    }
  }

  /// "+ Qo'shish" under a column: a new inquiry, taken straight on to that
  /// column's step.
  Future<void> _addTo(String column) async {
    final result = await showNewInquiryDialog(context);
    if (!mounted || result == null) return;
    refreshAdmissions(ref);
    final Lead? lead = switch (result) {
      InquiryCreated(:final lead) => lead,
      InquiryOpenExisting(:final leadId) =>
        await ref
            .read(admissionsRepositoryProvider)
            .getLead(leadId)
            .then((d) => d.lead),
    };
    if (lead == null || !mounted) return;
    _explain(lead);
    if (lead.isPending) return;
    try {
      switch (column) {
        case BoardStage.contacted:
          await ref
              .read(admissionsRepositoryProvider)
              .changeStage(lead, LeadStage.contacted);
        case BoardStage.trial:
          await showTrialBookingDialog(context, lead: lead);
        case BoardStage.awaitingDecision:
          await ref
              .read(admissionsRepositoryProvider)
              .changeStage(lead, LeadStage.decisionPending);
        case BoardStage.joined:
          final message = await showAfterTrialDialog(
            context,
            lead: lead,
            afterTrial: false,
          );
          if (message != null && mounted) showSnack(context, message);
        case BoardStage.later:
          final message = await showAfterTrialDialog(
            context,
            lead: lead,
            initialOutcome: AfterTrialOutcome.later,
          );
          if (message != null && mounted) showSnack(context, message);
        case BoardStage.rejected:
          final message = await showAfterTrialDialog(
            context,
            lead: lead,
            initialOutcome: AfterTrialOutcome.reject,
          );
          if (message != null && mounted) showSnack(context, message);
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
    refreshAdmissions(ref);
  }

  void _focusSearch() {
    setState(() {
      _section = _Section.leads;
      _table = true;
      _finder = false;
    });
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
        for (final (i, key) in _sectionKeys.indexed)
          SingleActivator(key, control: true): () => setState(() {
            _section = _Section.values[i];
            _finder = false;
          }),
      },
      child: Focus(
        autofocus: true,
        child: _finder
            ? CourseFinderScreen(onBack: () => setState(() => _finder = false))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _header(),
                  Expanded(child: _content()),
                ],
              ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'So\'rovdan o\'quvchigacha: har bir odam qaysi bosqichda ekanini ko\'ring',
                  style: TextStyle(fontSize: 15, color: AppColors.inkMuted),
                ),
              ),
              _SyncStatus(sync: _sync),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => setState(() => _finder = true),
                child: const Text('Kurs qidirish'),
              ),
              if (_section == _Section.leads) ...<Widget>[
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: () => setState(() => _table = !_table),
                  child: Text(
                    _table ? 'Doska ko\'rinishi' : 'Jadval ko\'rinishi',
                  ),
                ),
              ],
              const SizedBox(width: 10),
              Tooltip(
                message: 'Ctrl+N',
                child: FilledButton.icon(
                  onPressed: newInquiry,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Yangi so\'rov'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              for (final (i, section) in _Section.values.indexed)
                _TabLabel(
                  _labels[section]!,
                  selected: section == _section,
                  tooltip: 'Ctrl+${i + 1}',
                  onTap: () => setState(() => _section = section),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _content() => switch (_section) {
    _Section.leads =>
      _table
          ? LeadsView(searchFocus: _searchFocus)
          : QabulBoard(
              onOpenLead: (id) => showLeadDetails(context, leadId: id),
              onAdd: _addTo,
            ),
    _Section.trials => const TrialsView(),
    _Section.tasks => const FollowUpsView(),
    _Section.report => AdmissionsOverview(onOpenTab: (_) {}),
  };
}

class _TabLabel extends StatelessWidget {
  const _TabLabel(
    this.text, {
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final String text;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 40,
          margin: const EdgeInsets.only(right: 20),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.ink : AppColors.inkMuted,
            ),
          ),
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
