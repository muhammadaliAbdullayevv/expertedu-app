import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/uz_phone_mask_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../services/api/api_client.dart';
import '../data/qabul_models.dart';
import '../data/qabul_repository.dart';
import '../data/quick_save.dart';
import 'admissions_ui.dart';
import 'pending_changes_dialog.dart';
import 'qabul_text.dart';
import 'qabul_widgets.dart';

/// Every active group with its free seats, for the fast form's picker. One
/// request when the form opens; filtering after that is instant.
final qabulGroupsProvider = FutureProvider.autoDispose<List<GroupMatch>>((
  ref,
) async {
  final found = await ref.read(qabulRepositoryProvider).searchGroups();
  return <GroupMatch>[...found.exact, ...found.near];
});

/// The day patterns offered as quick filters.
const List<(String, Set<int>)> dayPatterns = <(String, Set<int>)>[
  ('Du Chor Ju', {1, 3, 5}),
  ('Se Pay Sha', {2, 4, 6}),
];

/// The groups left after the subject and day-pattern filters. Nothing picked
/// = no filter; a pattern keeps the groups that meet only on its days.
List<GroupMatch> filterGroups(
  List<GroupMatch> all, {
  String? subject,
  Set<int> patterns = const {},
}) {
  final days = <int>{for (final i in patterns) ...dayPatterns[i].$2};
  return <GroupMatch>[
    for (final g in all)
      if ((subject == null || g.subjectName == subject) &&
          (days.isEmpty ||
              (g.weekdays.isNotEmpty && g.weekdays.every(days.contains))))
        g,
  ];
}

/// "Yangi qo'shish": the fast form. Saves a new person in a few keystrokes
/// and clears itself for the next one.
///
/// Name -> phone -> group -> trial -> note with Tab; Enter saves from
/// anywhere. A save goes into the local queue first and the form is free at
/// once; it is sent in the background, again later if the internet fails.
class QabulForm extends ConsumerStatefulWidget {
  const QabulForm({super.key, this.onOpenFinder});

  /// "Batafsil qidirish" -- the full course finder.
  final VoidCallback? onOpenFinder;

  @override
  ConsumerState<QabulForm> createState() => QabulFormState();
}

class _Saved {
  const _Saved({
    required this.clientId,
    required this.name,
    required this.phone,
    required this.note,
    required this.group,
    this.result,
    this.undone,
  });

  final String clientId;
  final String name;
  final String phone;
  final String note;
  final GroupMatch? group;
  final QuickSaveResult? result;

  /// What happened after "Qaytarish", if it was pressed.
  final String? undone;

  _Saved copy({QuickSaveResult? result, String? undone}) => _Saved(
    clientId: clientId,
    name: name,
    phone: phone,
    note: note,
    group: group,
    result: result ?? this.result,
    undone: undone ?? this.undone,
  );
}

class QabulFormState extends ConsumerState<QabulForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'qabul-name');
  final _phoneFocus = FocusNode(debugLabel: 'qabul-phone');
  final _groupFocus = FocusNode(debugLabel: 'qabul-group');
  final _trialFocus = FocusNode(debugLabel: 'qabul-trial');
  final _noteFocus = FocusNode(debugLabel: 'qabul-note');
  final _saveFocus = FocusNode(debugLabel: 'qabul-save');
  final _groupScroll = ScrollController();

  String? _subject;
  final Set<int> _patterns = {};
  GroupMatch? _group;
  Future<List<TrialDate>>? _dates;
  TrialDate? _trial;
  _Saved? _saved;
  Timer? _noticeTimer;
  String? _nameError;
  String? _phoneError;
  bool _saving = false;

  late final QuickSaveRepository _saver = ref.read(quickSaveProvider);

  @override
  void initState() {
    super.initState();
    for (final node in <FocusNode>[_groupFocus, _trialFocus]) {
      node.addListener(_repaint);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _nameFocus.requestFocus();
    });
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    for (final c in <TextEditingController>[_name, _phone, _note]) {
      c.dispose();
    }
    for (final f in <FocusNode>[
      _nameFocus,
      _phoneFocus,
      _groupFocus,
      _trialFocus,
      _noteFocus,
      _saveFocus,
    ]) {
      f.dispose();
    }
    _groupScroll.dispose();
    super.dispose();
  }

  // --- Choosing -------------------------------------------------------------

  void _pickGroup(GroupMatch? group) {
    setState(() {
      _group = group;
      _trial = null;
      _dates = group == null
          ? null
          : ref.read(qabulRepositoryProvider).trialDates(group.groupId);
    });
  }

  void _moveGroup(List<GroupMatch> visible, int step) {
    final options = <GroupMatch?>[null, ...visible];
    final at = options.indexWhere((g) => g?.groupId == _group?.groupId);
    final next = (at + step).clamp(0, options.length - 1);
    if (next == at) return;
    _pickGroup(options[next]);
    // The list scrolls to keep the choice in view; "guruhsiz" is the first row.
    if (_groupScroll.hasClients) {
      final max = _groupScroll.position.maxScrollExtent;
      final target = next * 64.0;
      _groupScroll.animateTo(
        target.clamp(0.0, max),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  void _moveTrial(List<TrialDate> dates, int step) {
    final options = <TrialDate?>[null, ...dates.where((d) => !d.sessionFull)];
    final at = options.indexWhere((d) => d?.startsAt == _trial?.startsAt);
    final next = (at + step).clamp(0, options.length - 1);
    if (next != at) setState(() => _trial = options[next]);
  }

  // --- Saving ---------------------------------------------------------------

  Future<void> save() async {
    if (_saving) return;
    final name = _name.text.trim();
    final digits = UzPhoneMaskFormatter.digitsOf(_phone.text);
    setState(() {
      _nameError = name.isEmpty ? 'Ism kiriting' : null;
      _phoneError = digits.length == 9
          ? null
          : digits.isEmpty
          ? 'Telefon kiriting'
          : 'Telefon to\'liq emas';
    });
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
    final note = _note.text.trim();
    final QuickSave job;
    try {
      // Into the local queue: milliseconds, no network. Only if that fails is
      // anything left on the screen -- what was typed stays where it is.
      job = await _saver.save(
        fullName: name,
        phone: '998$digits',
        groupId: group?.groupId,
        groupName: group?.name,
        trialStartsAt: _trial?.startsAt,
        note: note.isEmpty ? null : note,
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

    final saved = _Saved(
      clientId: job.clientId,
      name: name,
      phone: _phone.text,
      note: note,
      group: group,
    );
    setState(() {
      _saved = saved;
      _clear();
    });
    _saving = false;
    _nameFocus.requestFocus();
    _scheduleNoticeHide(const Duration(seconds: 12));

    final result = await job.settled;
    if (!mounted || _saved?.clientId != job.clientId) return;
    setState(() => _saved = _saved!.copy(result: result));
    if (result.state == SaveState.refused) _noticeTimer?.cancel();
    // A queued or sent one may have changed what the list shows.
    refreshAdmissions(ref);
  }

  void _clear() {
    _name.clear();
    _phone.clear();
    _note.clear();
    _nameError = null;
    _phoneError = null;
    _group = null;
    _trial = null;
    _dates = null;
  }

  void _scheduleNoticeHide(Duration after) {
    _noticeTimer?.cancel();
    _noticeTimer = Timer(after, () {
      if (mounted) setState(() => _saved = null);
    });
  }

  Future<void> _undo() async {
    final saved = _saved;
    if (saved == null) return;
    try {
      final outcome = await _saver.undo(saved.clientId);
      if (!mounted) return;
      final message = switch (outcome) {
        UndoOutcome.removed ||
        UndoOutcome.archived => '${saved.name} qaytarildi.',
        UndoOutcome.unchanged =>
          'Bu raqam avvaldan bor edi — ${saved.name} avvalgi so\'rovga qo\'shilgan, o\'zgarmadi.',
        UndoOutcome.offline =>
          'Internet yo\'q — hozir qaytarib bo\'lmadi. Keyinroq Ro\'yxatdan Arxivga oling.',
      };
      setState(() {
        _saved = saved.copy(undone: message);
        // Put it back in the form to fix, unless a new person is being typed.
        final restore =
            outcome == UndoOutcome.removed || outcome == UndoOutcome.archived;
        if (restore && _name.text.isEmpty && _phone.text.isEmpty) {
          _name.text = saved.name;
          _phone.text = saved.phone;
          _note.text = saved.note;
          _group = saved.group;
        }
      });
      _scheduleNoticeHide(const Duration(seconds: 8));
      refreshAdmissions(ref);
    } on ApiException catch (e) {
      if (mounted) setState(() => _saved = saved.copy(undone: e.message));
    }
  }

  // --- Keys -----------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // A focused button does its own thing with Enter.
      final focused = FocusManager.instance.primaryFocus;
      if (focused != null && focused.debugLabel == 'qabul-save') {
        return KeyEventResult.ignored;
      }
      unawaited(save());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(qabulGroupsProvider);
    return Focus(
      canRequestFocus: false,
      onKeyEvent: _onKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _notice(),
                Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _nameAndPhone(),
                        const SizedBox(height: 22),
                        _groupSection(groups),
                        const SizedBox(height: 22),
                        _trialSection(),
                        const SizedBox(height: 22),
                        const FieldCaption('Izoh (ixtiyoriy)'),
                        TextField(
                          key: const ValueKey('qabul-note'),
                          controller: _note,
                          focusNode: _noteFocus,
                          decoration: const InputDecoration(
                            hintText: 'Masalan: kechqurun qulay',
                          ),
                        ),
                        const SizedBox(height: 20),
                        const Divider(height: 1, color: AppColors.divider),
                        const SizedBox(height: 20),
                        _footer(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _notice() {
    final saved = _saved;
    // Always the same height, so the form never jumps when a notice comes.
    return SizedBox(
      height: 52,
      child: saved == null
          ? null
          : _NoticeBar(
              saved: saved,
              onUndo: _undo,
              onShowQueue: () => showPendingChangesDialog(context),
              onClose: () => setState(() => _saved = null),
            ),
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

  Widget _groupSection(AsyncValue<List<GroupMatch>> groups) {
    final all = groups.value ?? const <GroupMatch>[];
    final subjects = <String>{
      for (final g in all)
        if (g.subjectName != null) g.subjectName!,
    }.toList();
    final visible = filterGroups(all, subject: _subject, patterns: _patterns);
    // A choice that a filter has hidden is dropped, never kept invisibly.
    if (_group != null && !visible.any((g) => g.groupId == _group!.groupId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pickGroup(null);
      });
    }
    final focused = _groupFocus.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 10, right: 16),
              child: Text(
                'Guruh',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.inkMuted,
                ),
              ),
            ),
            Expanded(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  for (final subject in subjects)
                    OptionPill(
                      subject,
                      focusable: false,
                      selected: _subject == subject,
                      onTap: () => setState(
                        () => _subject = _subject == subject ? null : subject,
                      ),
                    ),
                  if (subjects.isNotEmpty)
                    Container(width: 1, height: 28, color: AppColors.border),
                  for (final (i, pattern) in dayPatterns.indexed)
                    OptionPill(
                      pattern.$1,
                      focusable: false,
                      selected: _patterns.contains(i),
                      onTap: () => setState(
                        () => _patterns.contains(i)
                            ? _patterns.remove(i)
                            : _patterns.add(i),
                      ),
                    ),
                  if (widget.onOpenFinder != null)
                    // Mouse only: Tab goes name -> phone -> group -> trial -> note.
                    ExcludeFocus(
                      child: TextButton(
                        onPressed: widget.onOpenFinder,
                        child: const Text('Batafsil qidirish'),
                      ),
                    ),
                ],
              ),
            ),
          ],
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
        Focus(
          focusNode: _groupFocus,
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              _moveGroup(visible, 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              _moveGroup(visible, -1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card + 3),
              border: Border.all(
                color: focused ? AppColors.accent : Colors.transparent,
                width: 2,
              ),
            ),
            padding: const EdgeInsets.all(2),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 230),
              child: ListView(
                controller: _groupScroll,
                shrinkWrap: true,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: ChoiceCard(
                      key: const ValueKey('group-none'),
                      focusable: false,
                      title: 'Mos guruh yo\'q: guruhsiz ro\'yxat',
                      subtitle: 'Fan va kunlar izohga yoziladi',
                      selected: _group == null,
                      onTap: () {
                        _pickGroup(null);
                        _groupFocus.requestFocus();
                      },
                    ),
                  ),
                  if (groups.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  for (final g in visible)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ChoiceCard(
                        key: ValueKey('group-${g.groupId}'),
                        focusable: false,
                        title: groupTitle(g),
                        subtitle: g.teacherName,
                        selected: _group?.groupId == g.groupId,
                        onTap: () {
                          _pickGroup(g);
                          _groupFocus.requestFocus();
                        },
                        trailing: _GroupFacts(group: g),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _trialSection() {
    final group = _group;
    final focused = _trialFocus.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FieldCaption('Bepul sinov darsi (ixtiyoriy)'),
        if (group == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Guruh tanlansa, sinov darsi sanalari shu yerda chiqadi.',
              style: TextStyle(color: AppColors.inkMuted),
            ),
          )
        else
          FutureBuilder<List<TrialDate>>(
            key: ValueKey('trial-${group.groupId}'),
            future: _dates,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Sanalar yuklanmadi — sinovsiz saqlanadi.',
                    style: TextStyle(color: AppColors.inkMuted),
                  ),
                );
              }
              final dates = snapshot.data;
              if (dates == null) {
                return const SizedBox(
                  height: 40,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              return Focus(
                focusNode: _trialFocus,
                onKeyEvent: (node, event) {
                  if (event is KeyUpEvent) return KeyEventResult.ignored;
                  if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                    _moveTrial(dates, 1);
                    return KeyEventResult.handled;
                  }
                  if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                    _moveTrial(dates, -1);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: focused ? AppColors.accent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      OptionPill(
                        'Sinovsiz',
                        focusable: false,
                        selected: _trial == null,
                        onTap: () {
                          setState(() => _trial = null);
                          _trialFocus.requestFocus();
                        },
                      ),
                      for (final d in dates)
                        OptionPill(
                          '${weekdayDate(d.startsAt)} ${clock(d.startsAt)}'
                          '${d.sessionFull ? ' · to\'lgan' : ''}',
                          focusable: false,
                          selected: _trial?.startsAt == d.startsAt,
                          onTap: d.sessionFull
                              ? () {}
                              : () {
                                  setState(() => _trial = d);
                                  _trialFocus.requestFocus();
                                },
                        ),
                    ],
                  ),
                ),
              );
            },
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
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 52),
            padding: const EdgeInsets.symmetric(horizontal: 24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text('Saqlash'),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('Enter', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Days, time and seats of a group in the picker.
class _GroupFacts extends StatelessWidget {
  const _GroupFacts({required this.group});

  final GroupMatch group;

  @override
  Widget build(BuildContext context) {
    final days = group.weekdays.toSet();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var d = 1; d <= 7; d++)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: DayPill(
              weekdayAbbr[d],
              inGroup: days.contains(d),
              wanted: days.contains(d),
            ),
          ),
        const SizedBox(width: 12),
        Text(
          firstTimeRange(group.slots).replaceAll(' – ', '–'),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        const SizedBox(width: 12),
        StatusChip(
          seatsLabel(group.freeSeats),
          tone: (group.freeSeats ?? 1) > 0 ? StatusTone.ok : StatusTone.warning,
        ),
      ],
    );
  }
}

/// "Saqlandi / Qaytarish": what just happened to the last save.
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({
    required this.saved,
    required this.onUndo,
    required this.onShowQueue,
    required this.onClose,
  });

  final _Saved saved;
  final VoidCallback onUndo;
  final VoidCallback onShowQueue;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final result = saved.result;
    final refused = result?.state == SaveState.refused;
    final undone = saved.undone;
    final tone = refused ? StatusTone.danger : StatusTone.ok;
    final text =
        undone ??
        switch (result?.state) {
          SaveState.refused =>
            '${saved.name} saqlanmadi: ${result?.message ?? 'server rad etdi'}',
          SaveState.queued =>
            '${saved.name} saqlandi — internet qaytganda yuboriladi',
          _ => '${saved.name} saqlandi',
        };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: undone != null ? AppColors.neutralBg : tone.background,
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              refused
                  ? Icons.error_outline
                  : undone != null
                  ? Icons.undo
                  : Icons.check_circle_outline,
              size: 18,
              color: undone != null ? AppColors.neutralText : tone.foreground,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: undone != null
                      ? AppColors.neutralText
                      : tone.foreground,
                ),
              ),
            ),
            if (undone == null && !refused)
              TextButton(onPressed: onUndo, child: const Text('Qaytarish')),
            if (refused)
              TextButton(onPressed: onShowQueue, child: const Text('Ko\'rish')),
            IconButton(
              tooltip: 'Yopish',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}
