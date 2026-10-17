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

/// How many groups the picker shows at first, and how many more each
/// "Yana ko'rsatish" adds.
const int groupPageSize = 5;

const List<String> dayToggles = <String>[
  'Du',
  'Se',
  'Chor',
  'Pay',
  'Ju',
  'Sha',
  'Yak',
];

/// The groups the picker lists, best first. [query] keeps the groups whose
/// subject or name contains it. [days] (ISO weekdays the client can come)
/// only orders: an exact match -- every day of the group is one of them --
/// comes first, then the rest by how many days fit, then groups with no
/// schedule entered (they cannot be judged, so they are never hidden).
List<GroupMatch> rankGroups(
  List<GroupMatch> all, {
  String query = '',
  Set<int> days = const {},
}) {
  final q = query.trim().toLowerCase();
  final kept = <GroupMatch>[
    for (final g in all)
      if (q.isEmpty ||
          g.name.toLowerCase().contains(q) ||
          (g.subjectName ?? '').toLowerCase().contains(q))
        g,
  ];
  if (days.isEmpty) return kept;
  int rank(GroupMatch g) {
    final own = g.weekdays;
    if (own.isEmpty) return 2;
    return own.every(days.contains) ? 0 : 1;
  }

  int fit(GroupMatch g) => g.weekdays.where(days.contains).length;
  final indexed = kept.indexed.toList();
  indexed.sort((a, b) {
    final byRank = rank(a.$2).compareTo(rank(b.$2));
    if (byRank != 0) return byRank;
    final byFit = fit(b.$2).compareTo(fit(a.$2));
    return byFit != 0 ? byFit : a.$1.compareTo(b.$1);
  });
  return <GroupMatch>[for (final e in indexed) e.$2];
}

/// "Yangi qo'shish": the fast form. Saves a new person in a few keystrokes
/// and clears itself for the next one.
///
/// Name -> phone -> group -> trial -> note with Tab; Enter saves from
/// anywhere. A save goes into the local queue first and the form is free at
/// once; it is sent in the background, again later if the internet fails.
class QabulForm extends ConsumerStatefulWidget {
  const QabulForm({super.key});

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
  final _search = TextEditingController();
  final _searchFocus = FocusNode(
    debugLabel: 'qabul-group-search',
    skipTraversal: true,
  );

  final Set<int> _days = {};
  int _shown = groupPageSize;
  bool _noneChosen = false;
  bool _trialOpen = false;
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
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // --- Choosing -------------------------------------------------------------

  void _pickGroup(GroupMatch? group) {
    setState(() {
      _group = group;
      _noneChosen = group == null;
      _trial = null;
      _trialOpen = false;
      _dates = group == null
          ? null
          : ref.read(qabulRepositoryProvider).trialDates(group.groupId);
    });
  }

  /// Up/Down walk the listed groups and then "Guruhsiz" (the last row);
  /// from nothing chosen, Down picks the first group.
  void _moveGroup(List<GroupMatch> shown, int step) {
    final options = <GroupMatch?>[...shown, null];
    final at = _noneChosen
        ? options.length - 1
        : _group == null
        ? -1
        : options.indexWhere((g) => g?.groupId == _group!.groupId);
    final next = (at + step).clamp(0, options.length - 1);
    if (next != at) _pickGroup(options[next]);
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
    _noneChosen = false;
    _trial = null;
    _trialOpen = false;
    _dates = null;
    _search.clear();
    _days.clear();
    _shown = groupPageSize;
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
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: _scroll(groups)),
          Positioned(right: 28, bottom: 24, child: _notice()),
        ],
      ),
    );
  }

  Widget _scroll(AsyncValue<List<GroupMatch>> groups) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
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
    );
  }

  Widget _notice() {
    final saved = _saved;
    if (saved == null) return const SizedBox.shrink();
    return _NoticeBar(
      saved: saved,
      onUndo: _undo,
      onShowQueue: () => showPendingChangesDialog(context),
      onClose: () => setState(() => _saved = null),
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
    final ranked = rankGroups(all, query: _search.text, days: _days);
    final shown = ranked.take(_shown).toList();
    // A choice that the search has pushed out of the list is dropped, never
    // kept invisibly.
    if (_group != null && !ranked.any((g) => g.groupId == _group!.groupId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pickGroup(null);
      });
    }
    final focused = _groupFocus.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FieldCaption('Guruh'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            SizedBox(
              width: 260,
              child: TextField(
                key: const ValueKey('qabul-group-search'),
                controller: _search,
                focusNode: _searchFocus,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 18),
                  hintText: 'Fan yoki guruh nomi',
                ),
                onChanged: (_) => setState(() => _shown = groupPageSize),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Wrap(
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
        if (groups.isLoading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        Focus(
          focusNode: _groupFocus,
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              _moveGroup(shown, 1);
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              _moveGroup(shown, -1);
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final g in shown)
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
                if (ranked.length > shown.length)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ExcludeFocus(
                        child: TextButton(
                          key: const ValueKey('group-more'),
                          onPressed: () =>
                              setState(() => _shown += groupPageSize),
                          child: const Text('Yana ko\'rsatish'),
                        ),
                      ),
                    ),
                  ),
                if (all.isNotEmpty && ranked.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10, left: 4),
                    child: Text(
                      'Mos guruh topilmadi.',
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  ),
                ChoiceCard(
                  key: const ValueKey('group-none'),
                  focusable: false,
                  title: 'Mos guruh yo\'q: guruhsiz ro\'yxat',
                  subtitle: 'Fan va kunlar izohga yoziladi',
                  selected: _noneChosen,
                  onTap: () {
                    _pickGroup(null);
                    _groupFocus.requestFocus();
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Hidden until a group is chosen; then one link that opens the dates.
  Widget _trialSection() {
    final group = _group;
    if (group == null) return const SizedBox.shrink();
    final focused = _trialFocus.hasFocus;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: FutureBuilder<List<TrialDate>>(
        key: ValueKey('trial-${group.groupId}'),
        future: _dates,
        builder: (context, snapshot) {
          final dates = snapshot.data;
          final failed = snapshot.hasError;
          Widget body;
          if (!_trialOpen) {
            body = const SizedBox.shrink();
          } else if (failed) {
            body = const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Sanalar yuklanmadi — sinovsiz saqlanadi.',
                style: TextStyle(color: AppColors.inkMuted),
              ),
            );
          } else if (dates == null) {
            body = const Padding(
              padding: EdgeInsets.only(top: 10),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          } else if (dates.isEmpty) {
            body = const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Yaqin darslar topilmadi.',
                style: TextStyle(color: AppColors.inkMuted),
              ),
            );
          } else {
            body = Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  OptionPill(
                    'Sinovsiz',
                    focusable: false,
                    selected: _trial == null,
                    onTap: () => setState(() => _trial = null),
                  ),
                  for (final d in dates)
                    OptionPill(
                      '${weekdayDate(d.startsAt)} ${clock(d.startsAt)}'
                      '${d.sessionFull ? ' · to\'lgan' : ''}',
                      focusable: false,
                      selected: _trial?.startsAt == d.startsAt,
                      onTap: d.sessionFull
                          ? () {}
                          : () => setState(() => _trial = d),
                    ),
                ],
              ),
            );
          }
          return Focus(
            focusNode: _trialFocus,
            onKeyEvent: (node, event) {
              if (event is KeyUpEvent) return KeyEventResult.ignored;
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.space ||
                  key == LogicalKeyboardKey.arrowDown) {
                if (!_trialOpen) {
                  setState(() => _trialOpen = true);
                  return KeyEventResult.handled;
                }
              }
              if (_trialOpen && dates != null) {
                if (key == LogicalKeyboardKey.arrowRight) {
                  _moveTrial(dates, 1);
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowLeft) {
                  _moveTrial(dates, -1);
                  return KeyEventResult.handled;
                }
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  InkWell(
                    key: const ValueKey('trial-link'),
                    canRequestFocus: false,
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      setState(() => _trialOpen = !_trialOpen);
                      _trialFocus.requestFocus();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            _trialOpen ? Icons.remove : Icons.add,
                            size: 18,
                            color: AppColors.accentText,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _trial == null
                                ? 'Sinov darsi qo\'shish'
                                : 'Sinov darsi: ${weekdayDate(_trial!.startsAt)} ${clock(_trial!.startsAt)}',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppColors.accentText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  body,
                ],
              ),
            ),
          );
        },
      ),
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

/// Days, time and seats of a group in the picker. A group whose schedule has
/// not been entered says so, instead of seven grey pills.
class _GroupFacts extends StatelessWidget {
  const _GroupFacts({required this.group});

  final GroupMatch group;

  @override
  Widget build(BuildContext context) {
    final days = group.weekdays.toSet();
    final seats = group.freeSeats;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (days.isEmpty)
          const StatusChip('Jadval kiritilmagan', tone: StatusTone.warning)
        else ...<Widget>[
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
        ],
        const SizedBox(width: 12),
        StatusChip(
          studentsOrSeats(group),
          tone: (seats ?? 1) > 0 ? StatusTone.ok : StatusTone.warning,
        ),
      ],
    );
  }
}

/// The dark toast at the bottom right: "Zilola saqlandi", the group under
/// it, and "Qaytarish". It floats over the page, so the form never moves.
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
    final title =
        undone ??
        switch (result?.state) {
          SaveState.refused =>
            '${saved.name} saqlanmadi: ${result?.message ?? 'server rad etdi'}',
          SaveState.queued =>
            '${saved.name} saqlandi — internet qaytganda yuboriladi',
          _ => '${saved.name} saqlandi',
        };
    final subtitle = undone == null && !refused
        ? (saved.group == null ? 'Guruhsiz' : groupTitle(saved.group!))
        : null;
    final icon = refused
        ? Icons.error_outline
        : undone != null
        ? Icons.undo
        : Icons.check;
    final iconColor = refused
        ? const Color(0xFFE5645A)
        : const Color(0xFF2FBF71);
    return Material(
      color: AppColors.ink,
      borderRadius: BorderRadius.circular(AppRadius.card),
      elevation: 6,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 300, maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: iconColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 15, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Color(0xFFB9B9C2),
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (undone == null && !refused)
                TextButton(
                  onPressed: onUndo,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFB8B0F5),
                  ),
                  child: const Text('Qaytarish'),
                ),
              if (refused)
                TextButton(
                  onPressed: onShowQueue,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFB8B0F5),
                  ),
                  child: const Text('Ko\'rish'),
                ),
              IconButton(
                tooltip: 'Yopish',
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 16, color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
