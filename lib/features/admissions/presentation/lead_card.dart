import 'package:flutter/material.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../data/admissions_models.dart';
import 'admissions_ui.dart';
import 'lead_details_panel.dart';

/// One lead in a list -- the phone's home screen and the desktop home's
/// "So'nggi so'rovlar". Tapping opens the lead.
class LeadCard extends StatelessWidget {
  const LeadCard({super.key, required this.lead});

  final Lead lead;

  @override
  Widget build(BuildContext context) {
    final next = nextStepText(lead);
    final subtitle = <String>[
      PhoneFormatter.display(lead.phone),
      ?lead.subjectName,
      ?next,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          leading: CircleAvatar(
            backgroundColor: stageColor(lead.stage).withValues(alpha: 0.12),
            child: Icon(Icons.phone_in_talk, color: stageColor(lead.stage)),
          ),
          title: Text(lead.fullName),
          subtitle: Text(subtitle, style: context.textTheme.bodySmall),
          trailing: StageChip(lead.stage, pending: lead.isPending),
          onTap: () => showLeadDetails(
            context,
            leadId: lead.id,
            lead: lead.isPending ? lead : null,
          ),
        ),
      ),
    );
  }
}
