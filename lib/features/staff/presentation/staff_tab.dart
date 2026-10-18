import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/table_card.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../data/staff_repository.dart';
import 'staff_form.dart';

/// Settings' "Xodimlar" tab (owner only): the owner and the admins they've
/// added. Switching an admin off or resetting a password signs that
/// account out of every device.
class StaffTab extends ConsumerStatefulWidget {
  const StaffTab({super.key});

  @override
  ConsumerState<StaffTab> createState() => _StaffTabState();
}

class _StaffTabState extends ConsumerState<StaffTab> {
  late Future<List<StaffMember>> _future = ref
      .read(staffRepositoryProvider)
      .list();

  void _reload() =>
      setState(() => _future = ref.read(staffRepositoryProvider).list());

  Future<void> _add() async {
    if (await showStaffForm(context) == true) _reload();
  }

  Future<void> _edit(StaffMember member) async {
    if (await showStaffForm(context, member: member) == true) _reload();
  }

  static const _columns = <TableColumn>[
    TableColumn('Xodim', flex: 3),
    TableColumn('Telefon', flex: 2),
    TableColumn('Rol', flex: 1),
    TableColumn('Filial', flex: 2),
    TableColumn('Holat', flex: 1),
    TableColumn('Oxirgi kirish', flex: 2),
    TableColumn('', width: 56),
  ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<StaffMember>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadFailed(error: snapshot.error!, onRetry: _reload);
        }
        final staff = snapshot.data;
        if (staff == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final muted = context.textTheme.bodyMedium?.copyWith(
          color: context.colors.onSurfaceVariant,
        );
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Har bir admin faqat o\'z filialini ko\'radi; xodimlar, moliya '
                      'va oylik faqat egasiga ko\'rinadi.',
                      style: muted,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _add,
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: const Text('Yangi admin'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TableCard(
                  columns: _columns,
                  rowCount: staff.length,
                  onRowTap: (row) => _edit(staff[row]),
                  cell: (context, row, column) {
                    final member = staff[row];
                    return switch (column) {
                      0 => Text(
                        member.fullName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      1 => Text(PhoneFormatter.display(member.phone)),
                      2 => Text(
                        member.isOwner ? 'Egasi' : 'Admin',
                        style: muted,
                      ),
                      3 => Text(
                        member.isOwner
                            ? 'Hamma filial'
                            : (member.branchName ?? '—'),
                        key: ValueKey('staff-branch-${member.id}'),
                        style: muted,
                      ),
                      4 => Text(
                        member.isActive ? 'Faol' : 'O\'chirilgan',
                        style: member.isActive
                            ? muted
                            : TextStyle(color: context.colors.error),
                      ),
                      5 => Text(
                        member.lastLoginAt == null
                            ? 'Hali kirmagan'
                            : DateFormatters.dateTime(member.lastLoginAt!),
                        style: muted,
                      ),
                      _ => IconButton(
                        tooltip: 'Tahrirlash',
                        onPressed: () => _edit(member),
                        icon: const Icon(Icons.edit_outlined, size: 20),
                      ),
                    };
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
