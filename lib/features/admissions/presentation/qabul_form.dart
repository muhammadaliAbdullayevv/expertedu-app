import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/uz_phone_mask_formatter.dart';
import '../../../services/api/api_client.dart';
import '../data/qabul_models.dart';
import '../data/qabul_repository.dart';
import '../data/quick_save.dart';
import 'admissions_ui.dart';
import 'pending_changes_dialog.dart';
import 'qabul_text.dart';
import 'qabul_widgets.dart';

/// Every active group with its students and seats, for the picker. One
/// request when the form opens; filtering after that is instant.
final qabulGroupsProvider = FutureProvider.autoDispose<List<GroupMatch>>((
  ref,
) async {
  final found = await ref.read(qabulRepositoryProvider).searchGroups();
  return <GroupMatch>[...found.exact, ...found.near];
});

/// How many groups the picker shows at first, and how many more each
/// "Ko'proq" adds.
const int groupPageSize = 6;

const List<String> dayToggles = <String>[
  'Du',
  'Se',
  'Chor',
  'Pay',
  'Ju',
  'Sha',
  'Yak',
];

/// The groups the picker lists. With nothing typed and no day picked, all of
/// them. [query] keeps the groups whose subject or name contains it. [days]
/// are the weekdays the client can come (ISO, 1 = Monday): a group stays when
/// every day it meets on is one of them -- so a group with no schedule entered
/// cannot be judged and does not show while a day is picked.
List<GroupMatch> filterGroups(
  List<GroupMatch> all, {
  String query = '',
  Set<int> days = const {},
}) {
  final q = query.trim().toLowerCase();
  return <GroupMatch>[
    for (final g in all)
      if ((q.isEmpty ||
              g.name.toLowerCase().contains(q) ||
              (g.subjectName ?? '').toLowerCase().contains(q)) &&
          (days.isEmpty ||
              (g.weekdays.isNotEmpty && g.weekdays.every(days.contains))))
        g,
  ];
}

/// "Yangi qo'shish": search a group, click it, type the name and phone, save.
/// Enter saves; the form clears and the cursor goes back to the search box.
///
/// A save goes into the local queue first and the form is free at once; it
/// is sent in the background and tried again if the internet fails.
class QabulForm extends ConsumerStatefulWidget {
  const QabulForm({super.key});

  @override
  ConsumerState<QabulForm> createState() => QabulFormState();
}

class QabulFormState extends ConsumerState<QabulForm> {
  final _search = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'qabul-search');
  final _nameFocus = FocusNode(debugLabel: 'qabul-name');
  final _phoneFocus = FocusNode(debugLabel: 'qabul-phone');
  final _saveFocus = FocusNode(debugLabel: 'qabul-save');

  final Set<int> _days = {};
  int _shown = groupPageSize;
  GroupMatch? _group;
  bool _groupless = false;
  String? _nameError;
  String? _phoneError;
  String? _groupError;
  bool _saving = false;

  late final QuickSaveRepository _saver = ref.read(quickSaveProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[_search, _name, _phone]) {
      c.dispose();
    }
    for (final f in <FocusNode>[
      _searchFocus,
      _nameFocus,
      _phoneFocus,
      _saveFocus,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  // --- Saving ---------------------------------------------------------------

  Future<void> save() async {
    if (_saving) return;
    final name = _name.text.trim();
    final digits = UzPhoneMaskFormatter.digitsOf(_phone.text);
    final noGroup = _group == null && !_groupless;
    setState(() {
      _groupError = noGroup
          ? 'Guruhni tanlang yoki "Guruhsiz saqlash" ni bosing.'
          : null;
      _nameError = name.isEmpty ? 'Ism kiriting' : null;
      _phoneError = digits.length == 9
          ? null
          : digits.isEmpty
          ? 'Telefon kiriting'
          : 'Telefon to\'liq emas';
    });
    if (noGroup) {
      _searchFocus.requestFocus();
      return;
    }
    if (_nameError != null) {
      _nameFocus.requestFocus();
      return;
    }
    if (_phoneError != null) {
      _phoneFocus.requestFocus();
      return;
    }

    _saving = true;
    final group = _group;
    final QuickSave job;
    try {
      // Into the local queue: milliseconds, no network. Only if that fails
      // does anything stay on the screen -- what was typed is not lost.
      job = await _saver.save(
        fullName: name,
        phone: '998$digits',
        groupId: group?.groupId,
        groupName: group?.name,
      );
    } catch (e) {
      _saving = false;
      if (!mounted) return;
      setState(
        () => _nameError = e is ApiException
            ? e.message
            : 'Saqlab bo\'lmadi. Qayta urinib ko\'ring.',
      );
      return;
    }
    if (!mounted) return;

    // The search and the days stay: the next person often wants the same.
    setState(() {
      _name.clear();
      _phone.clear();
      _group = null;
      _groupless = false;
      _nameError = _phoneError = _groupError = null;
    });
    _saving = false;
    _searchFocus.requestFocus();
    showSnack(
      context,
      'Saqlandi',
      actionLabel: 'Qaytarish',
      onAction: () => _undo(job.clientId, name),
    );

    final result = await job.settled;
    if (!mounted) return;
    if (result.state == SaveState.refused) {
      showSnack(
        context,
        '$name saqlanmadi: ${result.message ?? 'server rad etdi'}',
        actionLabel: 'Ko\'rish',
        onAction: () => showPendingChangesDialog(context),
      );
    }
    refreshAdmissions(ref);
  }

  Future<void> _undo(String clientId, String name) async {
    try {
      final outcome = await _saver.undo(clientId);
      if (!mounted) return;
      showSnack(context, switch (outcome) {
        UndoOutcome.removed || UndoOutcome.archived => '$name qaytarildi.',
        UndoOutcome.unchanged =>
          'Bu raqam avvaldan bor edi — $name avvalgi yozuvga qo\'shilgan, o\'zgarmadi.',
        UndoOutcome.offline =>
          'Internet yo\'q — hozir qaytarib bo\'lmadi. Keyinroq Ro\'yxatdan Arxivga oling.',
      });
      refreshAdmissions(ref);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  // --- Keys -----------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final focused = FocusManager.instance.primaryFocus;
    // A focused button does its own thing with Enter.
    if (focused != null && focused.debugLabel == 'qabul-save') {
      return KeyEventResult.ignored;
    }
    // In the search box Enter just moves on to the name.
    if (focused == _searchFocus) {
      _nameFocus.requestFocus();
      return KeyEventResult.handled;
    }
    unawaited(save());
    return KeyEventResult.handled;
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(qabulGroupsProvider);
    final all = groups.value ?? const <GroupMatch>[];
    final matches = filterGroups(all, query: _search.text, days: _days);
    final shown = matches.take(_shown).toList();
    // A choice the search has pushed out of the list is dropped, never kept
    // invisibly.
    if (_group != null && !matches.any((g) => g.groupId == _group!.groupId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _group = null);
      });
    }
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: AppColors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _filters(),
                  const SizedBox(height: 14),
                  ..._results(groups, matches, shown),
                  const SizedBox(height: 14),
                  _grouplessLink(),
                  const SizedBox(height: 18),
                  _nameAndPhone(),
                  const SizedBox(height: 20),
                  const Divider(height: 1, color: AppColors.divider),
                  const SizedBox(height: 20),
                  _footer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _filters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FieldCaption('Guruh qidirish'),
        TextField(
          key: const ValueKey('qabul-group-search'),
          controller: _search,
          focusNode: _searchFocus,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 20),
            hintText: 'Fan yoki guruh nomi',
          ),
          onChanged: (_) => setState(() {
            _shown = groupPageSize;
            _groupError = null;
          }),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final (i, label) in dayToggles.indexed)
              OptionPill(
                label,
                focusable: false,
                selected: _days.contains(i + 1),
                onTap: () => setState(() {
                  _shown = groupPageSize;
                  if (!_days.remove(i + 1)) _days.add(i + 1);
                }),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _results(
    AsyncValue<List<GroupMatch>> groups,
    List<GroupMatch> matches,
    List<GroupMatch> shown,
  ) {
    return <Widget>[
      if (groups.hasError)
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'Guruhlar yuklanmadi. Guruhsiz saqlash mumkin.',
                style: TextStyle(color: AppColors.inkMuted),
              ),
            ),
            TextButton(
              onPressed: () => ref.invalidate(qabulGroupsProvider),
              child: const Text('Qayta urinish'),
            ),
          ],
        ),
      if (groups.isLoading)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (groups.hasValue && matches.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text(
            'Mos guruh topilmadi.',
            style: TextStyle(color: AppColors.inkMuted),
          ),
        ),
      for (final g in shown)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GroupRow(
            key: ValueKey('group-${g.groupId}'),
            group: g,
            selected: _group?.groupId == g.groupId,
            onTap: () {
              setState(() {
                _group = g;
                _groupless = false;
                _groupError = null;
              });
              _nameFocus.requestFocus();
            },
          ),
        ),
      if (matches.length > shown.length)
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            key: const ValueKey('group-more'),
            onPressed: () => setState(() => _shown += groupPageSize),
            child: const Text('Ko\'proq'),
          ),
        ),
    ];
  }

  /// "Guruhsiz saqlash": nothing fits, so only the name and phone are needed.
  Widget _grouplessLink() {
    return Row(
      children: <Widget>[
        TextButton(
          key: const ValueKey('save-groupless'),
          onPressed: () {
            setState(() {
              _groupless = true;
              _group = null;
              _groupError = null;
            });
            _nameFocus.requestFocus();
          },
          child: const Text('Guruhsiz saqlash'),
        ),
        if (_groupless)
          const Text(
            'Guruhsiz saqlanadi',
            style: TextStyle(color: AppColors.inkMuted),
          ),
        if (_groupError != null)
          Flexible(
            child: Text(
              _groupError!,
              style: const TextStyle(color: AppColors.dangerText),
            ),
          ),
      ],
    );
  }

  Widget _nameAndPhone() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const FieldCaption('Ism'),
              TextField(
                key: const ValueKey('qabul-name'),
                controller: _name,
                focusNode: _nameFocus,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  hintText: 'Ism va familiya',
                  errorText: _nameError,
                ),
                onChanged: (_) {
                  if (_nameError != null) setState(() => _nameError = null);
                },
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const FieldCaption('Telefon'),
              TextField(
                key: const ValueKey('qabul-phone'),
                controller: _phone,
                focusNode: _phoneFocus,
                keyboardType: TextInputType.phone,
                inputFormatters: <TextInputFormatter>[UzPhoneMaskFormatter()],
                decoration: InputDecoration(
                  // An icon, not prefixText: that one hides until you type.
                  prefixIcon: const Padding(
                    padding: EdgeInsets.only(left: 16, right: 6),
                    child: Text(
                      '+998',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: AppColors.ink,
                      ),
                    ),
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 0,
                    minHeight: 0,
                  ),
                  hintText: '90 123 45 67',
                  errorText: _phoneError,
                ),
                onChanged: (_) {
                  if (_phoneError != null) setState(() => _phoneError = null);
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _footer() {
    return Row(
      children: <Widget>[
        const Expanded(
          child: Text(
            'Saqlangach forma tozalanadi, keyingi mijozni darrov '
            'yozishingiz mumkin.',
            style: TextStyle(fontSize: 13, color: AppColors.inkMuted),
          ),
        ),
        const SizedBox(width: 16),
        FilledButton(
          focusNode: _saveFocus,
          onPressed: save,
          child: const Text('Saqlash'),
        ),
      ],
    );
  }
}

/// One group in the picker: name, days and time, teacher, students.
class GroupRow extends StatelessWidget {
  const GroupRow({
    super.key,
    required this.group,
    required this.selected,
    required this.onTap,
  });

  final GroupMatch group;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasSchedule = group.slots.isNotEmpty;
    final free = group.freeSeats;
    final students = <String>[
      '${group.enrolled} o\'quvchi',
      if (free != null) '$free bo\'sh',
    ].join(' · ');
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.card),
      canRequestFocus: false,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? AppColors.accentSoft : AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(
            color: selected ? AppColors.accent : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    groupTitle(group),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    hasSchedule
                        ? slotsLabel(group.slots)
                        : 'Jadval kiritilmagan',
                    style: TextStyle(
                      fontSize: 12,
                      color: hasSchedule
                          ? AppColors.inkMuted
                          : AppColors.warnText,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                group.teacherName ?? '',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.inkSecondary,
                ),
              ),
            ),
            Text(
              students,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.inkSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
