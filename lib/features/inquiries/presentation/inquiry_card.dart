import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../data/inquiries_repository.dart';

/// One logged call on the home screen, with its status menu (contacted /
/// trial scheduled / convert to student / lost). Shared by the phone and
/// desktop home layouts.
class InquiryCard extends ConsumerWidget {
  const InquiryCard({
    super.key,
    required this.inquiry,
    required this.onChanged,
  });

  final Inquiry inquiry;
  final VoidCallback onChanged;

  Color _statusColor(BuildContext context) => switch (inquiry.status) {
    'new' => context.colors.primary,
    'contacted' => Colors.orange,
    'scheduled' => Colors.purple,
    'converted' => Colors.green,
    _ => context.colors.outline,
  };

  String _statusLabel() => switch (inquiry.status) {
    'new' => 'Yangi',
    'contacted' => 'Bog\'lanildi',
    'scheduled' => 'Sinovga yozildi',
    'converted' => 'Talaba bo\'ldi',
    _ => 'Yo\'qotildi',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subtitleParts = <String>[
      PhoneFormatter.display(inquiry.phone),
      if (inquiry.subjectName != null) inquiry.subjectName!,
      if (inquiry.trialDate != null)
        'Sinov: ${inquiry.trialDate!.day}.${inquiry.trialDate!.month}.${inquiry.trialDate!.year}',
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: context.colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: context.colors.outlineVariant),
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          leading: CircleAvatar(
            backgroundColor: _statusColor(context).withValues(alpha: 0.15),
            child: Icon(Icons.phone_in_talk, color: _statusColor(context)),
          ),
          title: Text(inquiry.fullName),
          subtitle: Text(subtitleParts.join(' • ')),
          trailing: inquiry.status == 'converted'
              ? Chip(
                  label: Text(_statusLabel()),
                  backgroundColor: _statusColor(
                    context,
                  ).withValues(alpha: 0.15),
                )
              : PopupMenuButton<String>(
                  initialValue: inquiry.status,
                  child: Chip(
                    label: Text(_statusLabel()),
                    backgroundColor: _statusColor(
                      context,
                    ).withValues(alpha: 0.15),
                  ),
                  onSelected: (action) async {
                    final repo = ref.read(inquiriesRepositoryProvider);
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      if (action == 'convert') {
                        await repo.convert(inquiry.id);
                      } else {
                        await repo.updateStatus(inquiry.id, action);
                      }
                    } catch (e) {
                      messenger.showSnackBar(
                        SnackBar(content: Text('Xatolik: $e')),
                      );
                      return;
                    }
                    onChanged();
                  },
                  itemBuilder: (context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem(
                      value: 'contacted',
                      child: Text('Bog\'landim'),
                    ),
                    const PopupMenuItem(
                      value: 'scheduled',
                      child: Text('Sinovga yozildi'),
                    ),
                    const PopupMenuItem(
                      value: 'convert',
                      child: Text('Talabaga aylantirish'),
                    ),
                    const PopupMenuItem(
                      value: 'lost',
                      child: Text('Yo\'qotildi'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
