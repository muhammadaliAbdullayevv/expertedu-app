import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/table_card.dart';
import '../../auth/application/session_controller.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';
import 'lead_details_panel.dart';

/// "So'rovlar": every lead in a searchable table. Leads made offline and
/// not yet sent are listed first, marked "Yuborilmagan".
class LeadsView extends ConsumerStatefulWidget {
  const LeadsView({super.key, required this.searchFocus});

  /// Focused by Ctrl+F from AdmissionsScreen.
  final FocusNode searchFocus;

  @override
  ConsumerState<LeadsView> createState() => _LeadsViewState();
}

class _LeadsViewState extends ConsumerState<LeadsView> {
  final _search = TextEditingController();
  Timer? _debounce;
  String _scope = 'open';
  bool _mineOnly = false;
  late Future<(LeadPage, List<Lead>)> _data = _load();
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);

  @override
  void initState() {
    super.initState();
    _refresh.addListener(_reload);
  }

  @override
  void dispose() {
    _refresh.removeListener(_reload);
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _data = _load());
  }

  Future<(LeadPage, List<Lead>)> _load() async {
    final repo = ref.read(admissionsRepositoryProvider);
    final me = int.tryParse(ref.read(sessionControllerProvider).user?.id ?? '');
    final query = _search.text.trim();
    final page = await repo.listLeads(
      scope: _scope,
      query: query,
      assignedTo: _mineOnly ? me : null,
    );
    final pending = _scope == 'closed' || query.isNotEmpty
        ? const <Lead>[]
        : await repo.pendingLeads();
    return (page, pending);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 340,
                child: TextField(
                  controller: _search,
                  focusNode: widget.searchFocus,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Ism yoki telefon (Ctrl+F)',
                  ),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce = Timer(
                      const Duration(milliseconds: 300),
                      _reload,
                    );
                  },
                ),
              ),
              SegmentedButton<String>(
                segments: const <ButtonSegment<String>>[
                  ButtonSegment(value: 'open', label: Text('Ochiq')),
                  ButtonSegment(value: 'closed', label: Text('Yopilgan')),
                  ButtonSegment(value: 'all', label: Text('Hammasi')),
                ],
                selected: <String>{_scope},
                showSelectedIcon: false,
                onSelectionChanged: (s) {
                  _scope = s.first;
                  _reload();
                },
              ),
              FilterChip(
                label: const Text('Faqat meniki'),
                selected: _mineOnly,
                onSelected: (v) {
                  _mineOnly = v;
                  _reload();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<(LeadPage, List<Lead>)>(
              future: _data,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoadFailed(error: snapshot.error!, onRetry: _reload);
                }
                final data = snapshot.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                final leads = <Lead>[...data.$2, ...data.$1.items];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: _table(leads)),
                    const SizedBox(height: 8),
                    Text(
                      'Jami: ${data.$1.total}'
                      '${data.$2.isEmpty ? '' : ' · yuborilmagan: ${data.$2.length}'}',
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _table(List<Lead> leads) {
    return TableCard(
      emptyText: _search.text.trim().isEmpty
          ? 'So\'rovlar yo\'q. "Yangi so\'rov" (Ctrl+N) bilan qo\'shing.'
          : 'Hech narsa topilmadi',
      columns: const <TableColumn>[
        TableColumn('Ism', flex: 3),
        TableColumn('Telefon', flex: 2),
        TableColumn('Fan', flex: 2),
        TableColumn('Bosqich', flex: 2),
        TableColumn('Keyingi qadam', flex: 2),
        TableColumn('Mas\'ul', flex: 2),
        TableColumn('Murojaat', flex: 2),
      ],
      rowCount: leads.length,
      onRowTap: (row) => showLeadDetails(
        context,
        leadId: leads[row].id,
        lead: leads[row].isPending ? leads[row] : null,
      ),
      cell: (context, row, column) {
        final lead = leads[row];
        final muted = context.textTheme.bodyMedium?.copyWith(
          color: context.colors.onSurfaceVariant,
        );
        return switch (column) {
          0 => Text(
            lead.fullName,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          1 => Text(PhoneFormatter.display(lead.phone)),
          2 => Text(
            lead.subjectName ?? '-',
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          3 => StageChip(lead.stage, pending: lead.isPending),
          4 => Text(
            nextStepText(lead) ?? '-',
            overflow: TextOverflow.ellipsis,
            style:
                lead.nextTaskDueAt != null &&
                    lead.nextTrialAt == null &&
                    lead.nextTaskDueAt!.isBefore(DateTime.now())
                ? TextStyle(color: context.colors.error)
                : muted,
          ),
          5 => Text(
            lead.assignedToName ?? '-',
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
          _ => Text(DateFormatters.date(lead.createdAt), style: muted),
        };
      },
    );
  }
}
