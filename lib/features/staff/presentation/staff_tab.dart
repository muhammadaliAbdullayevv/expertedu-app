import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/table_card.dart';
import '../../../core/widgets/uz_phone_field.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../branches/application/branch_view.dart';
import '../../branches/data/branches_repository.dart';
import '../data/staff_repository.dart';

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
    if (await _showStaffForm(context, ref) == true) _reload();
  }

  Future<void> _edit(StaffMember member) async {
    if (await _showStaffForm(context, ref, member: member) == true) _reload();
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

/// New admin ([member] null), or edit one: name, on/off, new password.
Future<bool?> _showStaffForm(
  BuildContext context,
  WidgetRef ref, {
  StaffMember? member,
}) {
  return showAdaptiveFormDialog<bool>(
    context,
    child: _StaffForm(member: member),
  );
}

class _StaffForm extends ConsumerStatefulWidget {
  const _StaffForm({this.member});

  final StaffMember? member;

  @override
  ConsumerState<_StaffForm> createState() => _StaffFormState();
}

class _StaffFormState extends ConsumerState<_StaffForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.member?.fullName);
  final _phone = TextEditingController();
  final _password = TextEditingController();
  late bool _active = widget.member?.isActive ?? true;
  late int? _branch = widget.member?.branchId;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.member == null;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(staffRepositoryProvider);
    final member = widget.member;
    try {
      if (member == null) {
        await repo.create(
          phone: UzPhoneField.toE164(_phone.text),
          fullName: _name.text.trim(),
          password: _password.text,
          branchId: _branch,
        );
      } else {
        final name = _name.text.trim();
        await repo.update(
          member.id,
          fullName: name == member.fullName ? null : name,
          isActive: _active == member.isActive ? null : _active,
          branchId: _branch == member.branchId ? null : _branch,
        );
        if (_password.text.isNotEmpty) {
          await repo.resetPassword(member.id, _password.text);
        }
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    return SubmitShortcut(
      onSubmit: _save,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DialogHeader(
              title: _isNew ? 'Yangi admin' : member!.fullName,
              subtitle: _isNew
                  ? 'Telefon raqami va parol bilan kiradi'
                  : PhoneFormatter.display(member!.phone),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    TextFormField(
                      controller: _name,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Ism'),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? 'Ism kiritilishi shart'
                          : null,
                    ),
                    if (_isNew) ...<Widget>[
                      const SizedBox(height: 14),
                      UzPhoneField(
                        controller: _phone,
                        labelText: 'Telefon',
                        validator: (v) => (v ?? '').trim().length == 9
                            ? null
                            : '+998 dan keyin 9 ta raqam bo\'lishi kerak',
                      ),
                    ],
                    if (member == null || !member.isOwner) ...<Widget>[
                      const SizedBox(height: 14),
                      _BranchField(
                        value: _branch,
                        onChanged: (id) => setState(() => _branch = id),
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: _isNew ? 'Parol' : 'Yangi parol (ixtiyoriy)',
                        helperText: _isNew
                            ? 'Kamida 6 belgi'
                            : 'Kiritilsa, barcha qurilmalardan chiqariladi',
                      ),
                      validator: (v) {
                        final value = v ?? '';
                        if (!_isNew && value.isEmpty) return null;
                        return value.length < 6 ? 'Kamida 6 belgi' : null;
                      },
                    ),
                    if (!_isNew && !member!.isOwner) ...<Widget>[
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _active,
                        onChanged: (v) => setState(() => _active = v),
                        title: const Text('Faol'),
                        subtitle: const Text(
                          'O\'chirilsa, kira olmaydi va barcha qurilmalardan chiqariladi',
                        ),
                      ),
                    ],
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        style: TextStyle(color: context.colors.error),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Bekor qilish'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_isNew ? 'Qo\'shish' : 'Saqlash'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The branch an admin works in: they see only this branch's students, groups,
/// money and Qabul, whatever the owner does elsewhere.
class _BranchField extends ConsumerWidget {
  const _BranchField({required this.value, required this.onChanged});

  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(branchListProvider).value ?? const <Branch>[];
    final selected = branches.any((b) => b.id == value) ? value : null;
    return DropdownButtonFormField<int>(
      key: const ValueKey('staff-branch-field'),
      initialValue: selected,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Filial',
        helperText: 'Admin faqat shu filialni ko\'radi',
      ),
      items: <DropdownMenuItem<int>>[
        for (final b in branches)
          DropdownMenuItem(value: b.id, child: Text(b.name)),
      ],
      onChanged: onChanged,
      hint: const Text('Bosh ofis'),
    );
  }
}
