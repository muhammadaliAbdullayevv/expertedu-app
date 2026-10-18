import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../branches/application/branch_view.dart';
import '../../students/presentation/open_student.dart';
import '../../students/presentation/student_text.dart';
import '../../timetable/data/timetable_models.dart';
import '../../timetable/presentation/attendance_sheet_dialog.dart';
import '../data/dashboard_repository.dart';

/// Bugun on wide layouts: what happened today and what is waiting. Today's
/// lessons with how each was attended, who did not come, and what the admin has
/// to do (calls, unanswered requests, trials, who pays today). The owner also
/// gets a strip of how the day is going and, while looking at every branch,
/// each branch's day side by side. Nothing here is money: that is Moliya's and
/// Hisobotlar's.
class DesktopDashboard extends ConsumerStatefulWidget {
  const DesktopDashboard({
    super.key,
    required this.onOpenAdmissions,
    this.refreshEvery = const Duration(minutes: 3),
  });

  final VoidCallback onOpenAdmissions;

  /// The page asks again this often, so it stays true while it is left open.
  final Duration refreshEvery;

  @override
  ConsumerState<DesktopDashboard> createState() => DesktopDashboardState();
}

class _HomeData {
  const _HomeData(this.today, this.branches);

  final TodayView today;

  /// Every branch's day: only for the owner looking at all of them.
  final List<BranchStats> branches;
}

class DesktopDashboardState extends ConsumerState<DesktopDashboard> {
  /// Below this the lessons and the side cards stack instead of sitting side
  /// by side.
  static const double _twoColumnMinWidth = 1000;

  /// How many names a side card lists before it says "+N more".
  static const int _listed = 8;

  late Future<_HomeData> _data = _load();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.refreshEvery, (_) => _refreshQuietly());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<_HomeData> _load() async {
    final repo = ref.read(dashboardRepositoryProvider);
    final today = await repo.today();
    var branches = const <BranchStats>[];
    if (today.isOwner && ref.read(branchViewProvider) == null) {
      try {
        final all = await ref.read(branchListProvider.future);
        if (all.length > 1) branches = await repo.branches();
      } catch (_) {
        // The breakdown is a bonus: the page works without it.
      }
    }
    return _HomeData(today, branches);
  }

  /// Called by the shell (refresh button, branch switch).
  void reload() {
    final next = _load();
    setState(() {
      _data = next;
    });
  }

  /// The timer's refresh: swaps the new figures in when they arrive and says
  /// nothing if the server cannot be reached (the old ones stay).
  Future<void> _refreshQuietly() async {
    try {
      final fresh = await _load();
      if (!mounted) return;
      setState(() {
        _data = Future.value(fresh);
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          // The same 32 px as every other page, so the title above lines up
          // with the first card.
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
          child: FutureBuilder<_HomeData>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _LoadError(error: snapshot.error!, onRetry: reload);
              }
              final data = snapshot.data;
              if (data == null) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 64),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return _content(
                data,
                twoColumns: constraints.maxWidth - 64 >= _twoColumnMinWidth,
              );
            },
          ),
        );
      },
    );
  }

  // --- Layout ---------------------------------------------------------------

  Widget _content(_HomeData data, {required bool twoColumns}) {
    final t = data.today;
    final schedule = _Timeline(
      lessons: t.lessons,
      onMark: (lesson) async {
        final changed = await showAttendanceSheet(context, lesson);
        if (changed == true && mounted) reload();
      },
    );
    final side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Absentees(
          items: t.absentees,
          listed: _listed,
          onOpen: (id) => ref.read(openStudentRequestProvider).value = id,
        ),
        const SizedBox(height: 16),
        _Waiting(
          today: t,
          listed: _listed,
          onOpenAdmissions: widget.onOpenAdmissions,
          onOpenStudent: (id) =>
              ref.read(openStudentRequestProvider).value = id,
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (t.isOwner) ...<Widget>[_strip(t.stats), const SizedBox(height: 16)],
        if (data.branches.isNotEmpty) ...<Widget>[
          _BranchesPanel(
            branches: data.branches,
            onPick: (id) => ref.read(branchViewProvider.notifier).select(id),
          ),
          const SizedBox(height: 16),
        ],
        if (twoColumns)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 3, child: schedule),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: side),
            ],
          )
        else ...<Widget>[side, const SizedBox(height: 16), schedule],
        const SizedBox(height: 16),
        _Tomorrow(lessons: t.tomorrowLessons, trials: t.tomorrowTrials),
      ],
    );
  }

  /// The owner's five figures, equally wide and tall: label at the top, the
  /// number in the middle, a note at the bottom, on the same lines card to card.
  Widget _strip(TodayStats s) {
    final cards = <Widget>[
      _Kpi(
        key: const ValueKey('kpi-lessons'),
        label: 'Darslar',
        value: s.lessonsPlanned == 0
            ? '0'
            : '${s.lessonsHeld} / ${s.lessonsPlanned}',
        note: s.lessonsPlanned == 0
            ? 'Bugun dars yo\'q'
            : 'o\'tdi, davomat olingan',
      ),
      _Kpi(
        key: const ValueKey('kpi-attendance'),
        label: 'Bugungi davomat',
        value: ratePercent(s.attendanceRate),
        note: s.expected == 0
            ? 'Davomat hali olinmagan'
            : '${s.came} keldi · ${s.absent} kelmadi',
      ),
      _Kpi(
        key: const ValueKey('kpi-unmarked'),
        label: 'Davomatsiz darslar',
        value: '${s.lessonsUnmarked}',
        note: s.lessonsUnmarked == 0
            ? 'Hammasi belgilangan'
            : 'o\'tgan, davomat olinmagan',
        alert: s.lessonsUnmarked > 0,
      ),
      _Kpi(
        key: const ValueKey('kpi-risk'),
        label: 'Xavf ostida',
        value: '${s.atRiskStudents}',
        note: 'davomati past o\'quvchi',
        alert: s.atRiskStudents > 0,
      ),
      _Kpi(
        key: const ValueKey('kpi-requests'),
        label: 'Yangi so\'rovlar',
        value: '${s.newLeadsToday}',
        note: s.trialsToday == 0
            ? 'Bugun sinov yo\'q'
            : '${s.trialsToday} ta sinov bugun',
      ),
    ];
    return LayoutBuilder(
      builder: (context, box) {
        // Five across when they fit; otherwise three and two, same width.
        const gap = 16.0;
        final perRow = box.maxWidth >= 5 * 190 + 4 * gap ? 5 : 3;
        final width = (box.maxWidth - (perRow - 1) * gap) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final c in cards)
              SizedBox(width: width, height: _Kpi.height, child: c),
          ],
        );
      },
    );
  }
}

// --- Pieces -------------------------------------------------------------------

BoxDecoration _cardDecoration() => BoxDecoration(
  color: AppColors.surface,
  borderRadius: BorderRadius.circular(AppRadius.card),
  border: Border.all(color: AppColors.border),
);

/// One figure of the owner's strip. Fixed height; the label sits at the top,
/// the note at the bottom and the number between, so a row of them lines up
/// whatever each one says.
class _Kpi extends StatelessWidget {
  const _Kpi({
    super.key,
    required this.label,
    required this.value,
    required this.note,
    this.alert = false,
  });

  static const double height = 112;

  final String label;
  final String value;
  final String note;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _cardDecoration(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.inkMuted,
            ),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 28,
                height: 1.1,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: alert ? AppColors.dangerText : AppColors.ink,
              ),
            ),
          ),
          const Spacer(),
          Text(
            note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// A card with a header row (title, note on the right) and a thin divider.
class _Card extends StatelessWidget {
  const _Card({required this.title, this.trailing, required this.child});

  final String title;
  final String? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.inkMuted,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),
          child,
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.inkMuted),
      ),
    );
  }
}

// --- Branches (owner) ----------------------------------------------------------

/// Every branch's day, one row each. Clicking a row makes it the branch in
/// view, so the figures above and below change in place.
class _BranchesPanel extends StatelessWidget {
  const _BranchesPanel({required this.branches, required this.onPick});

  final List<BranchStats> branches;
  final ValueChanged<int> onPick;

  static const _head = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.inkMuted,
  );

  @override
  Widget build(BuildContext context) {
    Widget cell(int flex, Widget child) => Expanded(flex: flex, child: child);
    Widget head(String text) =>
        Text(text, textAlign: TextAlign.right, style: _head);
    return _Card(
      title: 'Filiallar bo\'yicha',
      trailing: 'Filialni bosing: hamma raqamlar shu filialga o\'tadi',
      child: Column(
        key: const ValueKey('branch-stats'),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: <Widget>[
                cell(22, const Text('Filial', style: _head)),
                cell(12, head('O\'quvchilar')),
                cell(12, head('Darslar')),
                cell(12, head('Davomat')),
                cell(14, head('Davomatsiz')),
                cell(12, head('Xavf ostida')),
                cell(8, head('So\'rovlar')),
                cell(8, head('Sinov')),
              ],
            ),
          ),
          for (final b in branches) ...<Widget>[
            const Divider(height: 1, color: AppColors.divider),
            InkWell(
              key: ValueKey('branch-row-${b.branchId}'),
              onTap: () => onPick(b.branchId),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 13,
                ),
                child: Row(
                  children: <Widget>[
                    cell(
                      22,
                      Text(
                        b.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    cell(12, _num('${b.activeStudents}')),
                    cell(
                      12,
                      _num(
                        b.lessonsPlanned == 0
                            ? '—'
                            : '${b.lessonsHeld} / ${b.lessonsPlanned}',
                      ),
                    ),
                    cell(12, _num(ratePercent(b.attendanceRate))),
                    cell(
                      14,
                      _num(
                        b.lessonsUnmarked == 0 ? '—' : '${b.lessonsUnmarked}',
                        color: b.lessonsUnmarked > 0
                            ? AppColors.warnText
                            : null,
                      ),
                    ),
                    cell(
                      12,
                      _num(
                        b.atRiskStudents == 0 ? '—' : '${b.atRiskStudents}',
                        color: b.atRiskStudents > 0
                            ? AppColors.dangerText
                            : null,
                      ),
                    ),
                    cell(
                      8,
                      _num(b.newLeadsToday == 0 ? '—' : '${b.newLeadsToday}'),
                    ),
                    cell(
                      8,
                      _num(b.trialsToday == 0 ? '—' : '${b.trialsToday}'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _num(String text, {Color? color}) => Text(
    text,
    textAlign: TextAlign.right,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: color ?? AppColors.ink,
    ),
  );
}

// --- Today's lessons -------------------------------------------------------------

class _Timeline extends StatelessWidget {
  const _Timeline({required this.lessons, required this.onMark});

  final List<TimetableLesson> lessons;
  final ValueChanged<TimetableLesson> onMark;

  @override
  Widget build(BuildContext context) {
    final live = lessons.where((l) => !l.isCancelled).length;
    if (lessons.isEmpty) {
      return const _Card(
        title: 'Bugungi darslar',
        child: _Empty('Bugun dars yo\'q.', key: ValueKey('timeline-empty')),
      );
    }
    final now = DateTime.now();
    final rows = <Widget>[];
    var markerShown = false;
    for (final l in lessons) {
      if (!markerShown && l.startsAt.isAfter(now)) {
        markerShown = true;
        rows.add(_NowMarker(now: now));
      }
      rows.add(_LessonRow(lesson: l, now: now, onMark: () => onMark(l)));
    }
    if (!markerShown) rows.add(_NowMarker(now: now));
    return _Card(
      title: 'Bugungi darslar',
      trailing: '$live ta dars',
      child: Padding(
        key: const ValueKey('timeline'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Column(children: rows),
      ),
    );
  }
}

class _NowMarker extends StatelessWidget {
  const _NowMarker({required this.now});

  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('now-marker'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 58,
            child: Text(
              DateFormatters.time(now),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.accentText,
              ),
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Hozir',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.accentText,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(child: Divider(height: 1, color: AppColors.accent)),
        ],
      ),
    );
  }
}

class _LessonRow extends StatelessWidget {
  const _LessonRow({
    required this.lesson,
    required this.now,
    required this.onMark,
  });

  /// The status chip and the result column have fixed widths, so they line up
  /// from row to row whatever the lesson says.
  static const double chipWidth = 144;
  static const double resultWidth = 150;

  final TimetableLesson lesson;
  final DateTime now;
  final VoidCallback onMark;

  @override
  Widget build(BuildContext context) {
    final l = lesson;
    final started = !l.startsAt.isAfter(now);
    final over = !l.endsAt.isAfter(now);
    final (String text, StatusTone tone) = l.isCancelled
        ? ('Bekor qilingan', StatusTone.danger)
        : l.isMarked
        ? ('Davomat olingan', StatusTone.ok)
        : over
        ? ('Davomat olinmagan', StatusTone.warning)
        : started
        ? ('Davom etmoqda', StatusTone.info)
        : ('Kutilmoqda', StatusTone.neutral);
    final canMark = !l.isCancelled && started && !l.isMarked;
    return Padding(
      key: ValueKey('lesson-${l.groupId}-${l.startsAt.millisecondsSinceEpoch}'),
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 58,
            child: Text(
              DateFormatters.time(l.startsAt),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: Container(
              height: 60,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: l.isCancelled ? AppColors.neutralBg : AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.button),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          l.groupName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            decoration: l.isCancelled
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        Text(
                          <String>[
                            ?l.teacherName,
                            ?l.room,
                            '${l.studentCount} o\'quvchi',
                          ].join(' · '),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  StatusChip(text, tone: tone, width: chipWidth),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: resultWidth,
                    child: canMark
                        ? Align(
                            alignment: Alignment.centerRight,
                            child: FilledButton(
                              key: ValueKey('mark-${l.groupId}'),
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                              ),
                              onPressed: onMark,
                              child: const Text('Davomat olish'),
                            ),
                          )
                        : l.isMarked
                        ? _Result(lesson: l)
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// How a marked lesson went: a thin bar split into on time / late / absent /
/// excused, and the two numbers that matter under it.
class _Result extends StatelessWidget {
  const _Result({required this.lesson});

  final TimetableLesson lesson;

  @override
  Widget build(BuildContext context) {
    final l = lesson;
    final onTime = l.presentCount - l.lateCount;
    final parts = <(int, Color)>[
      (onTime, AppColors.success),
      (l.lateCount, AppColors.brandYellow),
      (l.absentCount, AppColors.danger),
      (l.excusedCount, AppColors.borderStrong),
    ];
    return Column(
      key: ValueKey('result-${l.groupId}'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final (count, color) in parts)
                  if (count > 0)
                    Expanded(
                      flex: count,
                      child: ColoredBox(color: color),
                    ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          '${l.presentCount} keldi · ${l.absentCount} kelmadi',
          textAlign: TextAlign.right,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
        ),
      ],
    );
  }
}

// --- Who did not come ------------------------------------------------------------

class _Absentees extends StatelessWidget {
  const _Absentees({
    required this.items,
    required this.listed,
    required this.onOpen,
  });

  final List<AbsentToday> items;
  final int listed;
  final ValueChanged<int> onOpen;

  @override
  Widget build(BuildContext context) {
    final shown = items.take(listed).toList();
    return _Card(
      title: 'Bugun kelmaganlar',
      trailing: items.isEmpty ? null : '${items.length} ta',
      child: items.isEmpty
          ? const _Empty(
              'Bugun hech kim kelmay qolmadi.',
              key: ValueKey('absent-empty'),
            )
          : Column(
              key: const ValueKey('absentees'),
              children: <Widget>[
                for (var i = 0; i < shown.length; i++) ...<Widget>[
                  if (i > 0) const Divider(height: 1, color: AppColors.divider),
                  _SideRow(
                    key: ValueKey(
                      'absent-${shown[i].studentId}-${shown[i].groupId}',
                    ),
                    tag: StatusChip(
                      DateFormatters.time(shown[i].startsAt),
                      tone: StatusTone.danger,
                      width: _SideRow.tagWidth,
                    ),
                    title: shown[i].fullName,
                    detail: <String>[
                      shown[i].groupName,
                      PhoneFormatter.display(shown[i].phone),
                    ].join(' · '),
                    action: 'Profil',
                    onAction: () => onOpen(shown[i].studentId),
                  ),
                ],
                if (items.length > shown.length)
                  _More('va yana ${items.length - shown.length} ta'),
              ],
            ),
    );
  }
}

// --- Waiting for the admin ---------------------------------------------------------

class _Waiting extends StatelessWidget {
  const _Waiting({
    required this.today,
    required this.listed,
    required this.onOpenAdmissions,
    required this.onOpenStudent,
  });

  final TodayView today;
  final int listed;
  final VoidCallback onOpenAdmissions;
  final ValueChanged<int> onOpenStudent;

  @override
  Widget build(BuildContext context) {
    final t = today;
    final total =
        t.callsTotal +
        t.unansweredTotal +
        t.trialsToday.length +
        t.payTodayTotal;
    final rows = <Widget>[];
    void add(Widget row) {
      if (rows.isNotEmpty) {
        rows.add(const Divider(height: 1, color: AppColors.divider));
      }
      rows.add(row);
    }

    for (final c in t.calls) {
      add(
        _SideRow(
          key: ValueKey('call-${c.taskId}'),
          tag: StatusChip(
            'Qo\'ng\'iroq',
            tone: c.overdue ? StatusTone.warning : StatusTone.info,
            width: _SideRow.tagWidth,
          ),
          title: c.leadName,
          detail: '${PhoneFormatter.display(c.leadPhone)} · ${c.title}',
          action: 'Qabul',
          onAction: onOpenAdmissions,
        ),
      );
    }
    if (t.callsTotal > t.calls.length) {
      add(_More('va yana ${t.callsTotal - t.calls.length} ta qo\'ng\'iroq'));
    }
    for (final l in t.unanswered) {
      add(
        _SideRow(
          key: ValueKey('unanswered-${l.leadId}'),
          tag: const StatusChip(
            'So\'rov',
            tone: StatusTone.warning,
            width: _SideRow.tagWidth,
          ),
          title: l.fullName,
          detail: <String>[
            ?l.subjectName,
            'javobsiz ${DateTime.now().difference(l.createdAt).inDays} kun',
          ].join(' · '),
          action: 'Qabul',
          onAction: onOpenAdmissions,
        ),
      );
    }
    if (t.unansweredTotal > t.unanswered.length) {
      add(
        _More('va yana ${t.unansweredTotal - t.unanswered.length} ta so\'rov'),
      );
    }
    for (final trial in t.trialsToday) {
      add(
        _SideRow(
          key: ValueKey('trial-${trial.inquiryId}'),
          tag: const StatusChip(
            'Sinov',
            tone: StatusTone.neutral,
            width: _SideRow.tagWidth,
          ),
          title: trial.fullName,
          detail: <String>[
            if (trial.startsAt != null)
              'Bugun ${DateFormatters.time(trial.startsAt!)}',
            ?trial.subjectName,
          ].join(' · '),
          action: 'Qabul',
          onAction: onOpenAdmissions,
        ),
      );
    }
    for (final p in t.payToday) {
      add(
        _SideRow(
          key: ValueKey('pay-${p.studentId}'),
          tag: const StatusChip(
            'To\'lov',
            tone: StatusTone.info,
            width: _SideRow.tagWidth,
          ),
          title: p.fullName,
          detail: '${p.groupName} · ${CurrencyFormatter.format(p.amount)}',
          action: 'Profil',
          onAction: () => onOpenStudent(p.studentId),
        ),
      );
    }
    if (t.payTodayTotal > t.payToday.length) {
      add(_More('va yana ${t.payTodayTotal - t.payToday.length} ta to\'lov'));
    }
    return _Card(
      title: 'Sizni kutayotganlar',
      trailing: total == 0 ? null : '$total ta',
      child: rows.isEmpty
          ? const _Empty(
              'Hammasi joyida: hozircha hech narsa kutmayapti.',
              key: ValueKey('waiting-empty'),
            )
          : Column(key: const ValueKey('waiting'), children: rows),
    );
  }
}

/// One line of a side card: a tag, a name over a detail, and one button. The
/// tag and the button have fixed widths so the cards line up row to row.
class _SideRow extends StatelessWidget {
  const _SideRow({
    super.key,
    required this.tag,
    required this.title,
    required this.detail,
    required this.action,
    required this.onAction,
  });

  static const double tagWidth = 86;

  final Widget tag;
  final String title;
  final String detail;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
      child: Row(
        children: <Widget>[
          tag,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 76,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
              onPressed: onAction,
              child: Text(action),
            ),
          ),
        ],
      ),
    );
  }
}

class _More extends StatelessWidget {
  const _More(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
      ),
    );
  }
}

// --- Tomorrow -----------------------------------------------------------------------

class _Tomorrow extends StatelessWidget {
  const _Tomorrow({required this.lessons, required this.trials});

  final int lessons;
  final int trials;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (lessons > 0) '$lessons ta dars',
      if (trials > 0) '$trials ta sinov',
    ];
    return Container(
      key: const ValueKey('tomorrow'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: _cardDecoration(),
      child: Row(
        children: <Widget>[
          const Icon(Icons.event_outlined, size: 18, color: AppColors.inkMuted),
          const SizedBox(width: 10),
          const Text(
            'Ertaga',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          Text(
            parts.isEmpty ? 'dars ham, sinov ham yo\'q' : parts.join(' · '),
            style: const TextStyle(fontSize: 14, color: AppColors.inkMuted),
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) =>
      LoadFailed(error: error, onRetry: onRetry);
}
