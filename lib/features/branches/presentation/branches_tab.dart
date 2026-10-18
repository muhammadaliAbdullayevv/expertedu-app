import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../core/widgets/table_card.dart';
import '../../../core/widgets/uz_phone_field.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../staff/data/staff_repository.dart';
import '../../staff/presentation/staff_form.dart';
import '../application/branch_view.dart';
import '../data/branches_repository.dart';

/// Settings' "Filiallar" tab (owner only): Bosh ofis and the filiallar, each
/// with its admin. A new branch is made together with its admin (name, login
/// number, password); opening a branch renames it and manages its admins:
/// change their number or password, sign them out of every device, switch
/// them off, add another. A branch can be switched off (never the headquarters).
class BranchesTab extends ConsumerStatefulWidget {
  const BranchesTab({super.key});

  @override
  ConsumerState<BranchesTab> createState() => _BranchesTabState();
}

class _BranchesTabState extends ConsumerState<BranchesTab> {
  late Future<_Data> _future = _load();

  Future<_Data> _load() async {
    final branches = await ref.read(branchesRepositoryProvider).list();
    final staff = await ref.read(staffRepositoryProvider).list();
    return _Data(branches, staff);
  }

  void _reload() {
    final next = _load();
    setState(() {
      _future = next;
    });
    // The sidebar's switcher and every "Filial" choice follow.
    ref.invalidate(branchListProvider);
  }

  Future<void> _edit([Branch? branch]) async {
    await showAdaptiveFormDialog<bool>(
      context,
      maxWidth: 520,
      child: _BranchForm(branch: branch),
    );
    // Admins may have been changed inside, whichever way it was closed.
    if (mounted) _reload();
  }

  Future<void> _toggle(Branch b) async {
    try {
      await ref
          .read(branchesRepositoryProvider)
          .update(b.id, isActive: !b.isActive);
      _reload();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  static const _columns = <TableColumn>[
    TableColumn('Filial', flex: 3),
    TableColumn('Admin', flex: 4),
    TableColumn('Holat', flex: 1),
    TableColumn('', width: 120),
  ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Data>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadFailed(error: snapshot.error!, onRetry: _reload);
        }
        final data = snapshot.data;
        if (data == null) {
          return const Center(child: CircularProgressIndicator());
        }
        final branches = data.branches;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Har bir filialning guruhlari, o\'quvchilari, to\'lovlari va '
                      'so\'rovlari alohida. Filialni oching: nomini, adminning raqami va '
                      'parolini o\'zgartirish yoki adminni o\'chirish mumkin.',
                      style: TextStyle(color: AppColors.inkSecondary),
                    ),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('new-branch'),
                    onPressed: _edit,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Yangi filial'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TableCard(
                  columns: _columns,
                  rowCount: branches.length,
                  onRowTap: (row) => _edit(branches[row]),
                  cell: (context, row, column) {
                    final b = branches[row];
                    return switch (column) {
                      0 => Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              b.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (b.isHeadquarters) ...<Widget>[
                            const SizedBox(width: 8),
                            const StatusChip(
                              'Bosh ofis',
                              tone: StatusTone.info,
                            ),
                          ],
                        ],
                      ),
                      1 => _AdminsCell(admins: data.adminsOf(b.id), branch: b),
                      2 => Text(
                        b.isActive ? 'Faol' : 'O\'chirilgan',
                        style: TextStyle(
                          color: b.isActive
                              ? AppColors.inkMuted
                              : AppColors.dangerText,
                        ),
                      ),
                      _ => Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          IconButton(
                            tooltip: 'Nomini o\'zgartirish',
                            onPressed: () => _edit(b),
                            icon: const Icon(Icons.edit_outlined, size: 20),
                          ),
                          if (!b.isHeadquarters)
                            IconButton(
                              key: ValueKey('toggle-branch-${b.id}'),
                              tooltip: b.isActive
                                  ? 'O\'chirish'
                                  : 'Qayta yoqish',
                              onPressed: () => _toggle(b),
                              icon: Icon(
                                b.isActive
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 20,
                              ),
                            ),
                        ],
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

class _Data {
  const _Data(this.branches, this.staff);

  final List<Branch> branches;
  final List<StaffMember> staff;

  /// The branch's admins that can sign in.
  List<StaffMember> adminsOf(int branchId) => [
    for (final m in staff)
      if (!m.isOwner && m.isActive && m.branchId == branchId) m,
  ];
}

/// Who runs a branch: their names and login numbers, or a warning that nobody
/// can sign in to it.
class _AdminsCell extends StatelessWidget {
  const _AdminsCell({required this.admins, required this.branch});

  final List<StaffMember> admins;
  final Branch branch;

  @override
  Widget build(BuildContext context) {
    if (admins.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: StatusChip(
          'Admin yo\'q',
          key: ValueKey('branch-no-admin-${branch.id}'),
          tone: StatusTone.warning,
        ),
      );
    }
    return Column(
      key: ValueKey('branch-admins-${branch.id}'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final a in admins)
          Text(
            '${a.fullName} · ${PhoneFormatter.display(a.phone)}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.inkSecondary),
          ),
      ],
    );
  }
}

class _BranchForm extends ConsumerStatefulWidget {
  const _BranchForm({this.branch});

  final Branch? branch;

  @override
  ConsumerState<_BranchForm> createState() => _BranchFormState();
}

class _BranchFormState extends ConsumerState<_BranchForm> {
  late final _name = TextEditingController(text: widget.branch?.name);
  final _adminName = TextEditingController();
  final _adminPhone = TextEditingController();
  final _adminPassword = TextEditingController();
  late Future<List<StaffMember>> _admins = _loadAdmins();
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.branch == null;

  @override
  void dispose() {
    _name.dispose();
    _adminName.dispose();
    _adminPhone.dispose();
    _adminPassword.dispose();
    super.dispose();
  }

  /// The people who run this branch, on or off.
  Future<List<StaffMember>> _loadAdmins() async {
    final id = widget.branch?.id;
    if (id == null) return const [];
    final all = await ref.read(staffRepositoryProvider).list();
    return [
      for (final m in all)
        if (!m.isOwner && m.branchId == id) m,
    ];
  }

  void _reloadAdmins() {
    final next = _loadAdmins();
    setState(() {
      _admins = next;
    });
  }

  Future<void> _editAdmin(StaffMember? member) async {
    final changed = await showStaffForm(
      context,
      member: member,
      branchId: widget.branch!.id,
    );
    if (changed == true && mounted) _reloadAdmins();
  }

  /// All three admin fields, or none (the admin can be added later).
  String? _adminProblem() {
    final name = _adminName.text.trim();
    final phone = _adminPhone.text.trim();
    final password = _adminPassword.text;
    if (name.isEmpty && phone.isEmpty && password.isEmpty) return null;
    if (name.isEmpty) return 'Adminning ismini kiriting.';
    if (phone.length != 9) {
      return 'Adminning raqami: +998 dan keyin 9 ta raqam.';
    }
    if (password.length < 6) return 'Parol kamida 6 belgi bo\'lsin.';
    return null;
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Filial nomini kiriting.');
      return;
    }
    final problem = _isNew ? _adminProblem() : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(branchesRepositoryProvider);
      final existing = widget.branch;
      if (existing == null) {
        final withAdmin = _adminName.text.trim().isNotEmpty;
        await repo.create(
          name,
          adminName: withAdmin ? _adminName.text.trim() : null,
          adminPhone: withAdmin ? UzPhoneField.toE164(_adminPhone.text) : null,
          adminPassword: withAdmin ? _adminPassword.text : null,
        );
      } else if (existing.name != name) {
        await repo.update(existing.id, name: name);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DialogHeader(title: _isNew ? 'Yangi filial' : 'Filial'),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                TextField(
                  key: const ValueKey('branch-name'),
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Nomi',
                    hintText: 'Masalan: Chilonzor',
                  ),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 20),
                if (_isNew) _newAdminFields() else _adminsSection(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      key: const ValueKey('branch-error'),
                      style: const TextStyle(color: AppColors.dangerText),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              OutlinedButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: Text(_isNew ? 'Bekor qilish' : 'Yopish'),
              ),
              const SizedBox(width: 10),
              FilledButton(
                key: const ValueKey('branch-save'),
                onPressed: _saving ? null : _save,
                child: Text(_isNew ? 'Qo\'shish' : 'Saqlash'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static const _section = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);

  /// The first admin, made together with the branch.
  Widget _newAdminFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('Filial admini', style: _section),
        const SizedBox(height: 4),
        const Text(
          'Shu raqam va parol bilan kiradi va faqat shu filialni ko\'radi. '
          'Keyinroq ham qo\'shish mumkin.',
          style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('admin-name'),
          controller: _adminName,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Admin ismi'),
        ),
        const SizedBox(height: 12),
        UzPhoneField(
          key: const ValueKey('admin-phone'),
          controller: _adminPhone,
          labelText: 'Kirish raqami',
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('admin-password'),
          controller: _adminPassword,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Parol',
            helperText: 'Kamida 6 belgi',
          ),
        ),
      ],
    );
  }

  /// Who can sign in to this branch, with what to do about each.
  Widget _adminsSection() {
    return FutureBuilder<List<StaffMember>>(
      future: _admins,
      builder: (context, snapshot) {
        final admins = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(child: Text('Adminlar', style: _section)),
                TextButton.icon(
                  key: const ValueKey('add-admin'),
                  onPressed: () => _editAdmin(null),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: const Text('Admin qo\'shish'),
                ),
              ],
            ),
            if (snapshot.hasError)
              Text(
                '${snapshot.error}',
                style: const TextStyle(color: AppColors.dangerText),
              )
            else if (admins == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (admins.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Bu filialda admin yo\'q: hech kim unga kira olmaydi.',
                  key: ValueKey('no-admins'),
                  style: TextStyle(color: AppColors.warnText),
                ),
              )
            else
              for (final a in admins) _AdminRow(admin: a, onEdit: _editAdmin),
          ],
        );
      },
    );
  }
}

class _AdminRow extends StatelessWidget {
  const _AdminRow({required this.admin, required this.onEdit});

  final StaffMember admin;
  final ValueChanged<StaffMember> onEdit;

  @override
  Widget build(BuildContext context) {
    final a = admin;
    return Container(
      key: ValueKey('admin-${a.id}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        a.fullName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (!a.isActive) ...<Widget>[
                      const SizedBox(width: 8),
                      const StatusChip('O\'chirilgan', tone: StatusTone.danger),
                    ],
                  ],
                ),
                Text(
                  '${PhoneFormatter.display(a.phone)} · '
                  '${a.lastLoginAt == null ? 'hali kirmagan' : 'oxirgi kirish ${DateFormatters.dateTime(a.lastLoginAt!)}'}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: ValueKey('edit-admin-${a.id}'),
            onPressed: () => onEdit(a),
            child: const Text('Tahrirlash'),
          ),
        ],
      ),
    );
  }
}
