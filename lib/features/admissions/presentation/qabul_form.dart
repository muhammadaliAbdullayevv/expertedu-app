import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/formatters/uz_phone_mask_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../services/api/api_client.dart';
import '../../branches/application/branch_view.dart';
import '../../subjects/data/subjects_repository.dart';
import '../data/admissions_repository.dart';
import '../data/qabul_models.dart';
import '../data/qabul_repository.dart';
import '../data/quick_save.dart';
import 'admissions_ui.dart';
import 'group_schedules_dialog.dart';
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

/// Groups of one branch for the owner's "Guruhni almashtirish": [branch] is a
/// branch id, 0 = every branch, null = the branch in view.
final qabulBranchGroupsProvider = FutureProvider.autoDispose
    .family<List<GroupMatch>, int?>((ref, branch) async {
      final found = await ref
          .read(qabulRepositoryProvider)
          .searchGroups(branchId: branch);
      return <GroupMatch>[...found.exact, ...found.near];
    });

final qabulSubjectsProvider = FutureProvider.autoDispose<List<Subject>>(
  (ref) => ref.read(admissionsRepositoryProvider).subjects(),
);

/// How many groups the search shows at first, and how many more each
/// "Ko'proq" adds.
const int groupPageSize = 6;

/// Levels offered as quick picks for a person with no group yet; the field
/// takes any text (A1, B2, ...).
const List<String> levelPicks = <String>[
  'Beginner',
  'Elementary',
  'Intermediate',
  'IELTS',
  'CEFR',
];

/// The groups whose name, subject or teacher contains [query]. Nothing typed
/// = nothing listed: the admin knows the course and types it.
List<GroupMatch> searchGroups(List<GroupMatch> all, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const <GroupMatch>[];
  return <GroupMatch>[
    for (final g in all)
      if (g.name.toLowerCase().contains(q) ||
          (g.subjectName ?? '').toLowerCase().contains(q) ||
          (g.teacherName ?? '').toLowerCase().contains(q))
        g,
  ];
}

/// "Yangi qo'shish": type the course, click the group, then name, surname,
/// phone, parent phone and address. Enter saves; the form clears and the
/// cursor goes back to the course search.
///
/// With no fitting group, "Guruhsiz saqlash" keeps what they asked for
/// (subject, level, time and days) so the center can open a group once
/// several people want the same thing.
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
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _phone = TextEditingController();
  final _parentPhone = TextEditingController();
  final _address = TextEditingController();
  final _level = TextEditingController();
  final _wish = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'qabul-search');
  final _firstFocus = FocusNode(debugLabel: 'qabul-first');
  final _phoneFocus = FocusNode(debugLabel: 'qabul-phone');
  final _saveFocus = FocusNode(debugLabel: 'qabul-save');

  int _shown = groupPageSize;
  GroupMatch? _group;
  bool _groupless = false;
  Subject? _subject;
  String? _groupError;
  String? _firstError;
  String? _lastError;
  String? _phoneError;
  String? _parentError;
  bool _saving = false;

  DuplicateCheck _dupes = DuplicateCheck.none;
  Timer? _dupeTimer;
  String _dupeKey = '';

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
    _dupeTimer?.cancel();
    for (final c in <TextEditingController>[
      _search,
      _first,
      _last,
      _phone,
      _parentPhone,
      _address,
      _level,
      _wish,
    ]) {
      c.dispose();
    }
    for (final f in <FocusNode>[
      _searchFocus,
      _firstFocus,
      _phoneFocus,
      _saveFocus,
    ]) {
      f.dispose();
    }
    super.dispose();
  }

  // --- Duplicate warning ----------------------------------------------------

  String get _fullName => '${_first.text.trim()} ${_last.text.trim()}'.trim();

  /// Asks the server who already has this phone or this exact name -- once the
  /// phone is complete, or both name and surname are typed. Only a warning;
  /// a failed check is simply no warning.
  void _scheduleDupeCheck() {
    _dupeTimer?.cancel();
    final digits = UzPhoneMaskFormatter.digitsOf(_phone.text);
    final phone = digits.length == 9 ? '998$digits' : '';
    final name = _first.text.trim().isNotEmpty && _last.text.trim().isNotEmpty
        ? _fullName
        : '';
    final key = '$phone|$name';
    if (key == _dupeKey) return;
    _dupeKey = key;
    if (phone.isEmpty && name.isEmpty) {
      if (!_dupes.isEmpty) setState(() => _dupes = DuplicateCheck.none);
      return;
    }
    _dupeTimer = Timer(const Duration(milliseconds: 350), () async {
      try {
        final found = await ref
            .read(qabulRepositoryProvider)
            .duplicates(phone: phone, fullName: name);
        if (mounted && _dupeKey == key) setState(() => _dupes = found);
      } catch (_) {
        // No warning is better than a wrong one.
      }
    });
  }

  // --- Saving ---------------------------------------------------------------

  Future<void> save() async {
    if (_saving) return;
    final digits = UzPhoneMaskFormatter.digitsOf(_phone.text);
    final parentDigits = UzPhoneMaskFormatter.digitsOf(_parentPhone.text);
    final noGroup = _group == null && !_groupless;
    final noSubject = _groupless && _subject == null;
    setState(() {
      _groupError = noGroup
          ? 'Kursni tanlang yoki "Guruhsiz saqlash" ni bosing.'
          : noSubject
          ? 'Fanni tanlang.'
          : null;
      _firstError = _first.text.trim().isEmpty ? 'Ismni kiriting' : null;
      _lastError = _last.text.trim().isEmpty ? 'Familiyani kiriting' : null;
      _phoneError = digits.length == 9
          ? null
          : digits.isEmpty
          ? 'Telefon kiriting'
          : 'Telefon to\'liq emas';
      _parentError = parentDigits.isEmpty || parentDigits.length == 9
          ? null
          : 'Telefon to\'liq emas';
    });
    if (noGroup || noSubject) {
      _searchFocus.requestFocus();
      return;
    }
    if (_firstError != null || _lastError != null) {
      _firstFocus.requestFocus();
      return;
    }
    if (_phoneError != null) {
      _phoneFocus.requestFocus();
      return;
    }
    if (_parentError != null) return;

    _saving = true;
    final name = _fullName;
    final group = _group;
    final level = _level.text.trim();
    final wish = _wish.text.trim();
    final address = _address.text.trim();
    final QuickSave job;
    try {
      // Into the local queue: milliseconds, no network. Only if that fails
      // does anything stay on the screen -- what was typed is not lost.
      job = await _saver.save(
        fullName: name,
        phone: '998$digits',
        groupId: group?.groupId,
        groupName: group?.name,
        parentPhone: parentDigits.isEmpty ? null : '998$parentDigits',
        address: address.isEmpty ? null : address,
        subjectId: group == null ? _subject?.id : null,
        subjectName: group == null ? _subject?.name : null,
        level: group == null && level.isNotEmpty ? level : null,
        note: group == null && wish.isNotEmpty ? wish : null,
      );
    } catch (e) {
      _saving = false;
      if (!mounted) return;
      setState(
        () => _firstError = e is ApiException
            ? e.message
            : 'Saqlab bo\'lmadi. Qayta urinib ko\'ring.',
      );
      return;
    }
    if (!mounted) return;

    // The course search stays: the next person often asks for the same one.
    setState(() {
      for (final c in <TextEditingController>[
        _first,
        _last,
        _phone,
        _parentPhone,
        _address,
        _level,
        _wish,
      ]) {
        c.clear();
      }
      _group = null;
      _groupless = false;
      _subject = null;
      _dupes = DuplicateCheck.none;
      _dupeKey = '';
      _groupError = _firstError = _lastError = _phoneError = _parentError =
          null;
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
    // In the course search Enter picks the only match, or moves on to the name.
    if (focused == _searchFocus) {
      final matches = searchGroups(
        ref.read(qabulGroupsProvider).value ?? const <GroupMatch>[],
        _search.text,
      );
      if (matches.length == 1) _choose(matches.single);
      _firstFocus.requestFocus();
      return KeyEventResult.handled;
    }
    unawaited(save());
    return KeyEventResult.handled;
  }

  void _choose(GroupMatch g) {
    setState(() {
      _group = g;
      _groupless = false;
      _groupError = null;
    });
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(qabulGroupsProvider);
    final all = groups.value ?? const <GroupMatch>[];
    final matches = searchGroups(all, _search.text);
    final shown = matches.take(_shown).toList();
    // A choice the search has pushed out of the list is dropped, never kept
    // invisibly.
    if (_group != null && !matches.any((g) => g.groupId == _group!.groupId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _group = null);
      });
    }
    final noSchedule = all.where((g) => g.slots.isEmpty).length;
    final showBranches = ref.watch(showBranchLabelsProvider);
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (noSchedule > 0) _scheduleBanner(noSchedule),
                if (showBranches) _allBranchesNote(),
                Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _course(groups, matches, shown),
                      const SizedBox(height: 22),
                      _person(),
                      const SizedBox(height: 20),
                      const Divider(height: 1, color: AppColors.divider),
                      const SizedBox(height: 20),
                      _footer(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The owner looking at every branch: a request for a group goes to that
  /// group's branch; one without a group has to go somewhere.
  Widget _allBranchesNote() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        key: const ValueKey('all-branches-note'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.accentSoft,
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        child: const Text(
          'Hammasi rejimida so\'rov tanlangan guruhning filialiga yoziladi. '
          'Guruhsiz so\'rov Bosh ofisga tushadi — boshqa filial uchun avval '
          'chapdan o\'sha filialni tanlang.',
          style: TextStyle(fontSize: 13, color: AppColors.accentText),
        ),
      ),
    );
  }

  /// Groups with no days or time are shown as such; this is the way to fill
  /// them in for all of them at once.
  Widget _scheduleBanner(int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        decoration: BoxDecoration(
          color: AppColors.warnBg,
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '$count ta guruhda jadval kiritilmagan.',
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.warnText,
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('fill-schedules'),
              onPressed: () async {
                await showGroupSchedulesDialog(context);
                ref.invalidate(qabulGroupsProvider);
              },
              child: const Text('To\'ldirish'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _course(
    AsyncValue<List<GroupMatch>> groups,
    List<GroupMatch> matches,
    List<GroupMatch> shown,
  ) {
    final typed = _search.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const FieldCaption('Kurs'),
        TextField(
          key: const ValueKey('qabul-group-search'),
          controller: _search,
          focusNode: _searchFocus,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 20),
            hintText: 'Kurs nomini, tilni yoki o\'qituvchini kiriting',
          ),
          onChanged: (_) => setState(() {
            _shown = groupPageSize;
            _groupError = null;
          }),
        ),
        const SizedBox(height: 12),
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
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator()),
          ),
        if (groups.hasValue && typed && matches.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
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
              showBranch: ref.watch(showBranchLabelsProvider),
              selected: _group?.groupId == g.groupId,
              onTap: () {
                _choose(g);
                _firstFocus.requestFocus();
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
        if (_group != null && _group!.isFull)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(
              'Guruh to\'lgan (${_group!.enrolled}'
              '${_group!.capacity == null ? '' : '/${_group!.capacity}'}). '
              'Baribir qo\'shish mumkin: o\'quvchilar soni oshadi, guruh to\'lgan qoladi.',
              key: const ValueKey('full-note'),
              style: const TextStyle(color: AppColors.warnText),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('save-groupless'),
            onPressed: () {
              setState(() {
                _groupless = !_groupless;
                if (_groupless) _group = null;
                _groupError = null;
              });
            },
            child: Text(
              _groupless
                  ? 'Guruh tanlash'
                  : 'Mos guruh yo\'q — guruhsiz saqlash',
            ),
          ),
        ),
        if (_groupless) _wishPanel(),
        if (_groupError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _groupError!,
              style: const TextStyle(color: AppColors.dangerText),
            ),
          ),
      ],
    );
  }

  /// What a person with no group asked for: the subject, the level and a few
  /// words about time and days -- so the center can see what several people
  /// are waiting for before it opens a group.
  Widget _wishPanel() {
    final subjects = ref.watch(qabulSubjectsProvider).value ?? const [];
    return Container(
      key: const ValueKey('wish-panel'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const FieldCaption('Fan yoki til'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final s in subjects)
                OptionPill(
                  s.name,
                  focusable: false,
                  selected: _subject?.id == s.id,
                  onTap: () => setState(() {
                    _subject = s;
                    _groupError = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const FieldCaption('Daraja'),
          TextField(
            key: const ValueKey('wish-level'),
            controller: _level,
            decoration: const InputDecoration(
              hintText: 'Masalan: Beginner, IELTS, A1',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final l in levelPicks)
                OptionPill(
                  l,
                  focusable: false,
                  selected: _level.text == l,
                  onTap: () => setState(() => _level.text = l),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const FieldCaption('Qo\'shimcha: vaqt va kunlar'),
          TextField(
            key: const ValueKey('wish-note'),
            controller: _wish,
            decoration: const InputDecoration(
              hintText: 'Masalan: kechqurun, du-chor-ju',
            ),
          ),
        ],
      ),
    );
  }

  Widget _person() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _field(
                'Ism',
                TextField(
                  key: const ValueKey('qabul-first'),
                  controller: _first,
                  focusNode: _firstFocus,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    hintText: 'Ism',
                    errorText: _firstError,
                  ),
                  onChanged: (_) {
                    if (_firstError != null) setState(() => _firstError = null);
                    _scheduleDupeCheck();
                  },
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _field(
                'Familiya',
                TextField(
                  key: const ValueKey('qabul-last'),
                  controller: _last,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    hintText: 'Familiya',
                    errorText: _lastError,
                  ),
                  onChanged: (_) {
                    if (_lastError != null) setState(() => _lastError = null);
                    _scheduleDupeCheck();
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _field(
                'Telefon',
                _phoneField(
                  'qabul-phone',
                  _phone,
                  _phoneError,
                  focus: _phoneFocus,
                  onChanged: () {
                    if (_phoneError != null) setState(() => _phoneError = null);
                    _scheduleDupeCheck();
                  },
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _field(
                'Ota-ona telefoni',
                _phoneField(
                  'qabul-parent-phone',
                  _parentPhone,
                  _parentError,
                  onChanged: () {
                    if (_parentError != null) {
                      setState(() => _parentError = null);
                    }
                  },
                ),
              ),
            ),
          ],
        ),
        if (!_dupes.isEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _DuplicateWarning(check: _dupes),
        ],
        const SizedBox(height: 14),
        _field(
          'Manzil',
          TextField(
            key: const ValueKey('qabul-address'),
            controller: _address,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              hintText: 'Tuman, ko\'cha, mo\'ljal',
            ),
          ),
        ),
      ],
    );
  }

  Widget _field(String caption, Widget field) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[FieldCaption(caption), field],
  );

  Widget _phoneField(
    String key,
    TextEditingController controller,
    String? error, {
    FocusNode? focus,
    required VoidCallback onChanged,
  }) {
    return TextField(
      key: ValueKey(key),
      controller: controller,
      focusNode: focus,
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
        prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        hintText: '90 123 45 67',
        errorText: error,
      ),
      onChanged: (_) => onChanged(),
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

/// A warning under the phone fields: this phone or this name is already
/// known. It never blocks saving -- one person may study in several groups.
class _DuplicateWarning extends StatelessWidget {
  const _DuplicateWarning({required this.check});

  final DuplicateCheck check;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (check.phoneStudent != null && !check.phoneStudent!.inScope)
        'Bu raqam ${check.phoneStudent!.branchNames.join(', ')} filialidagi '
            'o\'quvchiniki: ${check.phoneStudent!.fullName}.'
      else if (check.phoneStudent != null)
        'Bu raqam o\'quvchiniki: ${check.phoneStudent!.fullName}'
            '${_groups(check.phoneStudent!.groups)}.',
      for (final l in check.phoneLeads)
        'Bu raqam bilan saqlangan: ${l.fullName}${_where(l)}.',
      for (final s in check.nameStudents)
        'Xuddi shu ism-familiyali o\'quvchi bor: ${s.fullName}, '
            '${PhoneFormatter.display(s.phone)}${_groups(s.groups)}.',
      for (final l in check.nameLeads)
        'Xuddi shu ism-familiya bilan saqlangan: ${l.fullName}, '
            '${PhoneFormatter.display(l.phone)}${_where(l)}.',
    ];
    // Four lines are enough to know; the rest is a count.
    final shown = lines.take(4).toList();
    final more = lines.length - shown.length;
    return Container(
      key: const ValueKey('duplicate-warning'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warnBg,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final line in shown)
            Text(
              line,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.warnText,
              ),
            ),
          if (more > 0)
            Text(
              '...va yana $more ta',
              style: const TextStyle(color: AppColors.warnText),
            ),
          const Text(
            'Saqlash mumkin: bitta odam bir nechta guruhda o\'qishi mumkin.',
            style: TextStyle(fontSize: 12, color: AppColors.warnText),
          ),
        ],
      ),
    );
  }

  static String _groups(List<String> groups) =>
      groups.isEmpty ? '' : ' (${groups.join(', ')})';

  static String _where(SimilarLead l) {
    final what = l.groupName ?? l.subjectName;
    return what == null ? '' : ' ($what)';
  }
}

/// One group in the search results: name, days and time, teacher, price and
/// how full it is. A full group is marked but can still be chosen.
class GroupRow extends StatelessWidget {
  const GroupRow({
    super.key,
    required this.group,
    required this.selected,
    required this.onTap,
    this.showBranch = false,
  });

  final GroupMatch group;
  final bool selected;
  final VoidCallback onTap;

  /// Say which branch the group is in (the owner looking at every branch).
  final bool showBranch;

  @override
  Widget build(BuildContext context) {
    final hasSchedule = group.slots.isNotEmpty;
    final free = group.freeSeats;
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
              flex: 4,
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
                        ? slotsWithEnd(group.slots)
                        : 'Jadval kiritilmagan',
                    style: TextStyle(
                      fontSize: 12,
                      color: hasSchedule
                          ? AppColors.inkMuted
                          : AppColors.warnText,
                    ),
                  ),
                  if (showBranch && group.branchName != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: StatusChip(
                        group.branchName!,
                        key: ValueKey('group-branch-${group.groupId}'),
                        tone: StatusTone.info,
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
            Expanded(
              flex: 2,
              child: Text(
                CurrencyFormatter.format(group.feeAmount),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (free == 0)
              StatusChip(
                'To\'lgan · ${group.enrolled} o\'quvchi',
                tone: StatusTone.warning,
              )
            else
              Text(
                <String>[
                  '${group.enrolled} o\'quvchi',
                  if (free != null) '$free bo\'sh',
                ].join(' · '),
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
