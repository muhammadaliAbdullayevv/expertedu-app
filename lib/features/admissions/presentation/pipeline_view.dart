import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../services/api/api_client.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';
import 'lead_action_dialogs.dart';
import 'lead_details_panel.dart';
import 'schedule_trial_dialog.dart';

/// "Voronka": open leads in a column per stage. Drag a card to a stage an
/// operator may set by hand; dropping on "Sinov rejalashtirildi" books a
/// trial instead, and the trial-done column only fills from attendance.
/// Every move is also on the card's menu, for the keyboard.
class PipelineView extends ConsumerStatefulWidget {
  const PipelineView({super.key});

  @override
  ConsumerState<PipelineView> createState() => _PipelineViewState();
}

class _PipelineViewState extends ConsumerState<PipelineView> {
  late Future<List<Lead>> _leads = _load();
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);
  // The board's own: the columns' lists mustn't share the default one.
  final _horizontal = ScrollController();

  static const double _columnWidth = 272;

  @override
  void initState() {
    super.initState();
    _refresh.addListener(_reload);
  }

  @override
  void dispose() {
    _refresh.removeListener(_reload);
    _horizontal.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _leads = _load());
  }

  Future<List<Lead>> _load() async {
    final page = await ref.read(admissionsRepositoryProvider).listLeads();
    return page.items;
  }

  Future<void> _moveTo(Lead lead, String stage) async {
    if (stage == lead.stage) return;
    if (stage == LeadStage.trialScheduled) {
      await showScheduleTrialDialog(context, lead: lead);
      return;
    }
    if (!LeadStage.manual.contains(stage)) {
      showSnack(
        context,
        '"${LeadStage.label(stage)}" sinov davomatidan keladi.',
      );
      return;
    }
    // Closing asks why, and "later" asks when -- straight moves don't.
    if (LeadStage.closed.contains(stage) || stage == LeadStage.followUpLater) {
      await showChangeStageDialog(context, ref, lead, initialStage: stage);
      return;
    }
    try {
      await ref.read(admissionsRepositoryProvider).changeStage(lead, stage);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
    refreshAdmissions(ref);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Lead>>(
      future: _leads,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadFailed(error: snapshot.error!, onRetry: _reload);
        }
        final leads = snapshot.data;
        if (leads == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Scrollbar(
          controller: _horizontal,
          thumbVisibility: true,
          child: ListView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            children: <Widget>[
              for (final stage in LeadStage.open)
                _column(stage, leads.where((l) => l.stage == stage).toList()),
              _closeColumn(),
            ],
          ),
        );
      },
    );
  }

  Widget _column(String stage, List<Lead> leads) {
    final droppable = stage != LeadStage.trialCompleted;
    return DragTarget<Lead>(
      onWillAcceptWithDetails: (details) =>
          droppable && details.data.stage != stage,
      onAcceptWithDetails: (details) => _moveTo(details.data, stage),
      builder: (context, candidates, _) => Container(
        width: _columnWidth,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          color: candidates.isNotEmpty
              ? stageColor(stage).withValues(alpha: 0.08)
              : context.colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: candidates.isNotEmpty
                ? stageColor(stage)
                : context.colors.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: stageColor(stage),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      LeadStage.label(stage),
                      style: context.textTheme.titleSmall,
                    ),
                  ),
                  Text('${leads.length}', style: context.textTheme.labelLarge),
                ],
              ),
            ),
            Expanded(
              child: leads.isEmpty
                  ? Center(
                      child: Text(
                        droppable ? 'Bu yerga torting' : 'Davomatdan keladi',
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      primary: false,
                      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                      children: <Widget>[
                        for (final lead in leads)
                          Draggable<Lead>(
                            data: lead,
                            feedback: SizedBox(
                              width: _columnWidth - 20,
                              child: Material(
                                elevation: 6,
                                borderRadius: BorderRadius.circular(12),
                                child: _LeadCard(lead: lead),
                              ),
                            ),
                            childWhenDragging: Opacity(
                              opacity: 0.4,
                              child: _LeadCard(lead: lead),
                            ),
                            child: _LeadCard(
                              lead: lead,
                              onOpen: () =>
                                  showLeadDetails(context, leadId: lead.id),
                              onMove: (stage) => _moveTo(lead, stage),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Drop here to close a lead -- it asks for the reason.
  Widget _closeColumn() {
    return SizedBox(
      width: 180,
      child: Column(
        children: <Widget>[
          for (final stage in LeadStage.closed)
            Expanded(
              child: DragTarget<Lead>(
                onAcceptWithDetails: (details) => _moveTo(details.data, stage),
                builder: (context, candidates, _) => Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: candidates.isNotEmpty
                        ? context.colors.errorContainer
                        : null,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: context.colors.outlineVariant),
                  ),
                  child: Text(
                    LeadStage.label(stage),
                    textAlign: TextAlign.center,
                    style: context.textTheme.bodyMedium?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LeadCard extends StatelessWidget {
  const _LeadCard({required this.lead, this.onOpen, this.onMove});

  final Lead lead;
  final VoidCallback? onOpen;
  final ValueChanged<String>? onMove;

  @override
  Widget build(BuildContext context) {
    final next = nextStepText(lead);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      lead.fullName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${PhoneFormatter.display(lead.phone)}'
                      '${lead.subjectName == null ? '' : ' · ${lead.subjectName}'}',
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.bodySmall,
                    ),
                    if (next != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          next,
                          style: context.textTheme.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (onMove != null)
                PopupMenuButton<String>(
                  tooltip: 'Bosqichga o\'tkazish',
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: onMove,
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    if (lead.nextTrialBookingId == null)
                      const PopupMenuItem(
                        value: LeadStage.trialScheduled,
                        child: Text('Sinov darsiga yozish'),
                      ),
                    for (final stage in LeadStage.manual)
                      if (stage != lead.stage)
                        PopupMenuItem(
                          value: stage,
                          child: Text(LeadStage.label(stage)),
                        ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
