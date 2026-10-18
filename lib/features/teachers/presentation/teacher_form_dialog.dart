import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/uz_phone_field.dart';
import '../../auth/application/session_controller.dart';
import '../data/teachers_repository.dart';

/// Create ([teacher] null) or edit a teacher. Returns true once saved.
Future<bool?> showTeacherFormDialog(BuildContext context, {Teacher? teacher}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => _TeacherFormDialog(teacher: teacher),
  );
}

class _TeacherFormDialog extends ConsumerStatefulWidget {
  const _TeacherFormDialog({this.teacher});

  final Teacher? teacher;

  @override
  ConsumerState<_TeacherFormDialog> createState() => _TeacherFormDialogState();
}

class _TeacherFormDialogState extends ConsumerState<_TeacherFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.teacher?.fullName);
  late final _phone = TextEditingController(
    text: UzPhoneField.stripPrefix(widget.teacher?.phone),
  );
  late final _note = TextEditingController(text: widget.teacher?.note);
  late final _telegramId = TextEditingController(
    text: widget.teacher?.telegramUserId?.toString() ?? '',
  );
  bool _saving = false;
  String? _error;
  List<TeacherMatch> _matches = const [];
  Timer? _lookupTimer;

  bool get _isNew => widget.teacher == null;

  /// One person is one teacher: while a new one is typed, anyone with the same
  /// number or name (in any branch) is shown, to be joined instead of made again.
  void _lookupSoon() {
    if (!_isNew) return;
    _lookupTimer?.cancel();
    _lookupTimer = Timer(const Duration(milliseconds: 400), () async {
      final phone = _phone.text.trim().length == 9
          ? UzPhoneField.toE164(_phone.text)
          : null;
      try {
        final found = await ref
            .read(teachersRepositoryProvider)
            .lookup(phone: phone, name: _name.text);
        if (mounted) setState(() => _matches = found);
      } catch (_) {
        // The server still refuses a twin when saving.
      }
    });
  }

  /// Already here: nothing to add.
  bool get _blocked => _matches.any((m) => m.inScope);

  Future<void> _join(TeacherMatch m) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final phone = _phone.text.trim().length == 9
          ? UzPhoneField.toE164(_phone.text)
          : null;
      await ref
          .read(teachersRepositoryProvider)
          .joinBranch(m.teacherId, phone: phone);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _lookupTimer?.cancel();
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    _telegramId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = ref.read(teachersRepositoryProvider);
    final phone = _phone.text.trim().isEmpty
        ? null
        : UzPhoneField.toE164(_phone.text);
    final note = _note.text.trim().isEmpty ? null : _note.text.trim();
    final telegramId = int.tryParse(_telegramId.text.trim());
    try {
      final existing = widget.teacher;
      if (existing == null) {
        await repo.create(
          fullName: _name.text.trim(),
          phone: phone,
          note: note,
          telegramUserId: telegramId,
        );
      } else {
        await repo.update(
          existing.id,
          fullName: _name.text.trim(),
          phone: phone,
          note: note,
          telegramUserId: telegramId,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.teacher == null
            ? 'Yangi o\'qituvchi'
            : 'O\'qituvchini tahrirlash',
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextFormField(
                controller: _name,
                autofocus: true,
                onChanged: (_) => _lookupSoon(),
                decoration: const InputDecoration(labelText: 'F.I.Sh.'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
              ),
              const SizedBox(height: 12),
              UzPhoneField(
                controller: _phone,
                labelText: 'Telefon (ixtiyoriy)',
                onChanged: (_) => _lookupSoon(),
              ),
              for (final m in _matches)
                _MatchTile(
                  match: m,
                  owner: ref.read(sessionControllerProvider).isOwner,
                  busy: _saving,
                  onJoin: () => _join(m),
                ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('teacher-telegram-id'),
                controller: _telegramId,
                keyboardType: TextInputType.number,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                decoration: const InputDecoration(
                  labelText: 'Telegram ID (ixtiyoriy)',
                  helperText:
                      'Botga /myid yuborsa, raqamini ko\'rsatadi. Bot guruhda o\'qituvchini shu bilan taniydi.',
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _note,
                decoration: const InputDecoration(
                  labelText: 'Izoh (ixtiyoriy)',
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Bekor qilish'),
        ),
        FilledButton(
          onPressed: _saving || _blocked ? null : _save,
          child: const Text('Saqlash'),
        ),
      ],
    );
  }
}

/// Someone with this number or name already exists: the same person, in this
/// branch already or in another.
class _MatchTile extends StatelessWidget {
  const _MatchTile({
    required this.match,
    required this.owner,
    required this.busy,
    required this.onJoin,
  });

  final TeacherMatch match;
  final bool owner;
  final bool busy;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final m = match;
    final where = m.branchNames.join(', ');
    final canJoin = !m.inScope && (m.samePhone || owner);
    final text = m.inScope
        ? '"${m.fullName}" bu filialda allaqachon bor.'
        : m.samePhone
        ? 'Bu raqam bilan "${m.fullName}" $where filialida ishlaydi. Shu odammi?'
        : '$where filialida shu ismli o\'qituvchi bor: "${m.fullName}". '
              '${owner ? 'Shu odammi?' : 'Shu odam bo\'lsa, egasiga ayting; boshqa odam bo\'lsa, saqlayvering.'}';
    return Container(
      key: ValueKey('teacher-match-${m.teacherId}'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: m.inScope ? AppColors.dangerBg : AppColors.warnBg,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(text, style: const TextStyle(fontSize: 13)),
          if (canJoin)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: ValueKey('join-teacher-${m.teacherId}'),
                onPressed: busy ? null : onJoin,
                child: const Text(
                  'Shu o\'qituvchini mening filialimga qo\'shish',
                ),
              ),
            ),
        ],
      ),
    );
  }
}
