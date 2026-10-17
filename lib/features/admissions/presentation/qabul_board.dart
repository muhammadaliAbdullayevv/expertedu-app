import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/app_sidebar.dart' show Avatar;
import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../students/presentation/heard_from.dart';
import '../data/qabul_models.dart';
import '../data/qabul_repository.dart';
import 'admissions_ui.dart';
import 'qabul_text.dart';

/// Qabul (V2): the four KPI tiles and one column per stage -- "so'rovdan
/// o'quvchigacha: har bir odam qaysi bosqichda ekanini ko'ring". Every number
/// is the server's (app/funnel.py), shared with Bugun and O'quvchilar.
class QabulBoard extends ConsumerStatefulWidget {
  const QabulBoard({super.key, required this.onOpenLead, required this.onAdd});

  /// A card was tapped.
  final void Function(int leadId) onOpenLead;

  /// "+ Qo'shish" under a column (its key, see [BoardStage]).
  final void Function(String columnKey) onAdd;

  @override
  ConsumerState<QabulBoard> createState() => _QabulBoardState();
}

class _QabulBoardState extends ConsumerState<QabulBoard> {
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);
  late Future<AdmissionsBoard> _future = _load();

  Future<AdmissionsBoard> _load() => ref.read(qabulRepositoryProvider).board();

  @override
  void initState() {
    super.initState();
    _refresh.addListener(_onRefresh);
  }

  @override
  void dispose() {
    _refresh.removeListener(_onRefresh);
    super.dispose();
  }

  void _onRefresh() {
    if (mounted) setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AdmissionsBoard>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('${snapshot.error}'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => setState(() => _future = _load()),
                  child: const Text('Qayta urinish'),
                ),
              ],
            ),
          );
        }
        return QabulBoardView(
          board: snapshot.data!,
          now: DateTime.now(),
          onOpenLead: widget.onOpenLead,
          onAdd: widget.onAdd,
        );
      },
    );
  }
}

/// The board for a given [board] and [now] -- no loading, so it can be drawn
/// and tested on its own.
class QabulBoardView extends StatelessWidget {
  const QabulBoardView({
    super.key,
    required this.board,
    required this.now,
    required this.onOpenLead,
    required this.onAdd,
  });

  final AdmissionsBoard board;
  final DateTime now;
  final void Function(int leadId) onOpenLead;
  final void Function(String columnKey) onAdd;

  @override
  Widget build(BuildContext context) {
    final kpi = board.kpi;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 4, 32, 16),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: _Kpi('Shu oy so\'rovlar', '${kpi.leads}')),
                const SizedBox(width: 14),
                Expanded(
                  child: _Kpi('Sinovga kelganlar', '${kpi.trialPeople}'),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Kpi('Guruhga qo\'shilganlar', '${kpi.joined}'),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _Kpi(
                    'So\'rovdan o\'quvchiga',
                    percent(kpi.conversionRate),
                    hint: kpi.cohortSize == 0
                        ? null
                        : 'Shu oy kelgan ${kpi.cohortSize} tadan ${kpi.cohortJoined} tasi',
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                for (final column in board.columns) ...<Widget>[
                  _Column(
                    column: column,
                    now: now,
                    onOpenLead: onOpenLead,
                    onAdd: () => onAdd(column.key),
                  ),
                  const SizedBox(width: 12),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, {this.hint});

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.inkMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
          ),
          if (hint != null)
            Text(
              hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
            ),
        ],
      ),
    );
  }
}

class _Column extends StatelessWidget {
  const _Column({
    required this.column,
    required this.now,
    required this.onOpenLead,
    required this.onAdd,
  });

  final BoardColumn column;
  final DateTime now;
  final void Function(int leadId) onOpenLead;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final joined = column.key == BoardStage.joined;
    final hidden = column.count - column.leads.length;
    return Container(
      width: 244,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.divider,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    column.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: joined ? AppColors.okText : AppColors.ink,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${column.count}',
                    key: ValueKey('count-${column.key}'),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final lead in column.leads) ...<Widget>[
            _Card(lead: lead, now: now, onTap: () => onOpenLead(lead.id)),
            const SizedBox(height: 8),
          ],
          if (hidden > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'va yana $hidden ta',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
              ),
            ),
          _AddButton(onPressed: onAdd),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.lead, required this.now, required this.onTap});

  final BoardLead lead;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badge = stageBadge(lead, now);
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          lead.fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          PhoneFormatter.display(lead.phone),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: lead.assignedToName ?? '',
                    child: Avatar(name: lead.assignedToName ?? '', size: 26),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  if (lead.subjectName != null)
                    StatusChip(lead.subjectName!, tone: StatusTone.info),
                  if (lead.source != null)
                    StatusChip(
                      heardFromLabel(lead.source),
                      tone: StatusTone.neutral,
                    ),
                  if (badge != null) StatusChip(badge.text, tone: badge.tone),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                cardFooter(lead, now),
                style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onPressed,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderStrong),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.add_rounded, size: 16, color: AppColors.inkMuted),
            SizedBox(width: 6),
            Text(
              'Qo\'shish',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
