import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/uz_phone_field.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../branches/application/branch_view.dart';
import '../../branches/data/branches_repository.dart';
import '../data/staff_repository.dart';

/// New admin ([member] null), or edit one: name, login number, on/off, new
/// password, sign out of every device. [branchId] puts a new admin in that
/// branch and hides the branch choice (the dialog was opened from the branch).
Future<bool?> showStaffForm(
  BuildContext context, {
  StaffMember? member,
  int? branchId,
}) {
  return showAdaptiveFormDialog<bool>(
    context,
    child: StaffForm(member: member, branchId: branchId),
  );
}

class StaffForm extends ConsumerStatefulWidget {
  const StaffForm({super.key, this.member, this.branchId});

  final StaffMember? member;

  /// Fixed branch for a new admin (hides the branch field).
  final int? branchId;

  @override
  ConsumerState<StaffForm> createState() => _StaffFormState();
}

class _StaffFormState extends ConsumerState<StaffForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.member?.fullName);
  late final _phone = TextEditingController(
    text: UzPhoneField.stripPrefix(widget.member?.phone),
  );
  final _password = TextEditingController();
  late bool _active = widget.member?.isActive ?? true;
  late int? _branch = widget.member?.branchId ?? widget.branchId;
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
        final phone = UzPhoneField.toE164(_phone.text);
        await repo.update(
          member.id,
          fullName: name == member.fullName ? null : name,
          phone: member.isOwner || phone == '+${member.phone}' ? null : phone,
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

  /// Ends every session this admin has open (a lost or handed-over laptop).
  Future<void> _signOut() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(staffRepositoryProvider)
          .signOutEverywhere(widget.member!.id);
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
                    if (member == null || !member.isOwner) ...<Widget>[
                      const SizedBox(height: 14),
                      UzPhoneField(
                        key: const ValueKey('staff-phone'),
                        controller: _phone,
                        labelText: 'Telefon (kirish raqami)',
                        validator: (v) => (v ?? '').trim().length == 9
                            ? null
                            : '+998 dan keyin 9 ta raqam bo\'lishi kerak',
                      ),
                    ],
                    if ((member == null || !member.isOwner) &&
                        (member != null ||
                            widget.branchId == null)) ...<Widget>[
                      const SizedBox(height: 14),
                      _BranchField(
                        value: _branch,
                        onChanged: (id) => setState(() => _branch = id),
                      ),
                    ],
                    const SizedBox(height: 14),
                    TextFormField(
                      key: const ValueKey('staff-password'),
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
                    if (!_isNew && !member!.isOwner) ...<Widget>[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const ValueKey('staff-sign-out'),
                          onPressed: _saving ? null : _signOut,
                          icon: const Icon(Icons.logout_rounded, size: 18),
                          label: const Text('Barcha qurilmalardan chiqarish'),
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
