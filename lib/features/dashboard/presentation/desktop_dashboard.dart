import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/widgets/status_chip.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../branches/application/branch_view.dart';
import '../../debtors/data/debtors_repository.dart';
import '../../debtors/presentation/overdue_label.dart';
import '../../students/presentation/open_student.dart';
import '../../students/presentation/student_text.dart';
import '../../timetable/data/timetable_models.dart';
import '../../timetable/data/timetable_repository.dart';
import '../../timetable/presentation/attendance_sheet_dialog.dart';
import '../data/dashboard_repository.dart';

/// Bugun on wide layouts: four figures in one aligned row, today's lessons as
/// a timeline, and one short list of what needs attention. The owner also gets
/// every branch side by side (while looking at all of them) and the money; an
/// admin sees what students owe and what happens today -- never what the
/// center collects.
class DesktopDashboard extends ConsumerStatefulWidget {
  const DesktopDashboard({
    super.key,
    required this.onOpenAdmissions,
    required this.onOpenDebtors,
  });

  final VoidCallback onOpenAdmissions;
  final VoidCallback onOpenDebtors;

  @override
  ConsumerState<DesktopDashboard> createState() => DesktopDashboardState();
}

class _HomeData {
  const _HomeData(this.summary, this.lessons, this.branches);

  final DashboardSummary summary;
  final List<TimetableLesson> lessons;

  /// Every branch's figures: only for the owner looking at all of them.
  final List<BranchStats> branches;
}

class DesktopDashboardState extends ConsumerState<DesktopDashboard> {
  /// Below this the timeline and the attention list stack instead of sitting
  /// side by side.
  static const double _twoColumnMinWidth = 1000;

  late Future<_HomeData> _data = _load();

  Future<_HomeData> _load() async {
    final repo = ref.read(dashboardRepositoryProvider);
    final summary = await repo.fetch();
    final lessons = await ref
        .read(timetableRepositoryProvider)
        .lessons(summary.today, summary.today);
    var branches = const <BranchStats>[];
    if (summary.moneyVisible && ref.read(branchViewProvider) == null) {
      try {
        final all = await ref.read(branchListProvider.future);
        if (all.length > 1) branches = await repo.branches();
      } catch (_) {
        // The breakdown is a bonus: the page works without it.
      }
    }
    return _HomeData(summary, lessons, branches);
  }

  /// Called by the shell (refresh button, branch switch).
  void reload() {
    final next = _load();
    setState(() {
      _data = next;
    });
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
    final s = data.summary;
    final schedule = _Timeline(
      lessons: data.lessons,
      onMark: (lesson) async {
        final changed = await showAttendanceSheet(context, lesson);
        if (changed == true && mounted) reload();
      },
    );
    final attention = _Attention(items: _attentionItems(data));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _kpis(s),
        if (data.branches.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          _BranchesPanel(
            branches: data.branches,
            onPick: (id) => ref.read(branchViewProvider.notifier).select(id),
          ),
        ],
        const SizedBox(height: 16),
        if (twoColumns)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 3, child: schedule),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: attention),
            ],
          )
        else ...<Widget>[attention, const SizedBox(height: 16), schedule],
      ],
    );
  }

  /// Four figures, equally wide and tall, every label, number and note on the
  /// same line from card to card.
  Widget _kpis(DashboardSummary s) {
    final cards = <Widget>[
      _Kpi(
        key: const ValueKey('kpi-students'),
        label: 'Faol o\'quvchilar',
        value: '${s.activeStudents}',
        note:
            '${s.activeGroups} guruh · +${s.newStudentsThisMonth} yangi bu oy',
      ),
      if (s.moneyVisible)
        _Kpi(
          key: const ValueKey('kpi-collected'),
          label: 'Bu oy tushum',
          value: CurrencyFormatter.format(s.collectedThisMonth),
          note: s.monthlyPlan == 0
              ? 'Reja yo\'q'
              : 'Reja ${CurrencyFormatter.format(s.monthlyPlan)} · '
                    '${(s.collectedThisMonth * 100 / s.monthlyPlan).round()}%',
          progress: s.monthlyPlan == 0
              ? null
              : (s.collectedThisMonth / s.monthlyPlan).clamp(0.0, 1.0),
        )
      else
        _Kpi(
          key: const ValueKey('kpi-due-today'),
          label: 'Bugun to\'lov kuni',
          value: s.dueTodayCount == 0 ? 'Yo\'q' : '${s.dueTodayCount} ta',
          note: s.dueTodayCount == 0
              ? 'Bugun hech kimning to\'lov kuni emas'
              : '${CurrencyFormatter.format(s.dueTodayAmount)} to\'lashi kerak',
        ),
      _Kpi(
        key: const ValueKey('kpi-debt'),
        label: 'Qarzdorlik',
        value: CurrencyFormatter.format(s.totalDebt),
        note: '${s.debtorCount} o\'quvchi qarzdor',
        alert: s.totalDebt > 0,
        onTap: widget.onOpenDebtors,
      ),
      _Kpi(
        key: const ValueKey('kpi-attendance'),
        label: 'Davomat',
        value: ratePercent(s.attendanceRate7d),
        note: s.attendanceRate7d == null
            ? 'Oxirgi 7 kunda davomat olinmagan'
            : 'Oxirgi 7 kun',
      ),
    ];
    return SizedBox(
      height: _Kpi.height,
      child: Row(
        children: <Widget>[
          for (var i = 0; i < cards.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 16),
            Expanded(child: cards[i]),
          ],
        ],
      ),
    );
  }

  /// What needs attention, most urgent first.
  List<_AttentionItem> _attentionItems(_HomeData data) {
    final s = data.summary;
    final now = DateTime.now();
    final items = <_AttentionItem>[];

    for (final l in data.lessons) {
      if (l.isCancelled || l.isMarked || l.endsAt.isAfter(now)) continue;
      items.add(
        _AttentionItem(
          key: 'unmarked-${l.groupId}-${l.startsAt.millisecondsSinceEpoch}',
          tag: 'Davomat',
          tone: StatusTone.warning,
          title: l.groupName,
          detail: '${DateFormatters.time(l.startsAt)} darsi: davomat olinmagan',
          action: 'Olish',
          onAction: () async {
            final changed = await showAttendanceSheet(context, l);
            if (changed == true && mounted) reload();
          },
        ),
      );
    }
    for (final t in s.trialsToday) {
      items.add(
        _AttentionItem(
          key: 'trial-${t.inquiryId}',
          tag: 'Sinov',
          tone: StatusTone.neutral,
          title: t.fullName,
          detail: [
            if (t.startsAt != null) 'Bugun ${DateFormatters.time(t.startsAt!)}',
            ?t.subjectName,
          ].join(' · '),
          action: 'Ko\'rish',
          onAction: widget.onOpenAdmissions,
        ),
      );
    }
    if (s.dueTodayCount > 0) {
      items.add(
        _AttentionItem(
          key: 'due-today',
          tag: 'To\'lov',
          tone: StatusTone.info,
          title: '${s.dueTodayCount} ta o\'quvchining to\'lov kuni bugun',
          detail: CurrencyFormatter.format(s.dueTodayAmount),
          action: 'Ochish',
          onAction: widget.onOpenDebtors,
        ),
      );
    }
    if (s.unansweredLeads > 0) {
      items.add(
        _AttentionItem(
          key: 'unanswered',
          tag: 'So\'rov',
          tone: StatusTone.info,
          title: '${s.unansweredLeads} ta so\'rovga javob berilmagan',
          detail: '24 soatdan beri',
          action: 'Qabul',
          onAction: widget.onOpenAdmissions,
        ),
      );
    }
    if (s.tasksDueToday > 0) {
      items.add(
        _AttentionItem(
          key: 'tasks',
          tag: 'Vazifa',
          tone: StatusTone.neutral,
          title: '${s.tasksDueToday} ta qo\'ng\'iroq qilish kerak',
          detail: 'Bugun yoki muddati o\'tgan',
          action: 'Qabul',
          onAction: widget.onOpenAdmissions,
        ),
      );
    }
    for (final d in s.topDebtors.take(4)) {
      items.add(_debtorItem(d, s.today));
    }
    return items;
  }

  _AttentionItem _debtorItem(Debtor d, DateTime today) => _AttentionItem(
    key: 'debtor-${d.enrollmentId}',
    tag: 'Qarz',
    tone: StatusTone.danger,
    title: d.studentFullName,
    detail:
        '${CurrencyFormatter.format(d.balance)} · '
        '${d.groupName}${d.oldestUnpaidDue == null ? '' : ' · ${overdueLabel(d.oldestUnpaidDue, today)}'}',
    action: 'Profil',
    onAction: () => ref.read(openStudentRequestProvider).value = d.studentId,
  );
}

// --- Pieces -------------------------------------------------------------------

BoxDecoration _cardDecoration() => BoxDecoration(
  color: AppColors.surface,
  borderRadius: BorderRadius.circular(AppRadius.card),
  border: Border.all(color: AppColors.border),
);

/// One of the four figures. Fixed height; the label sits at the top, the note
/// at the bottom and the number between, so a row of them lines up whatever
/// each one says. The plan meter is drawn on the card's bottom edge so it
/// never pushes the text.
class _Kpi extends StatelessWidget {
  const _Kpi({
    super.key,
    required this.label,
    required this.value,
    required this.note,
    this.progress,
    this.alert = false,
    this.onTap,
  });

  static const double height = 124;

  final String label;
  final String value;
  final String note;
  final double? progress;
  final bool alert;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _cardDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
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
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (progress != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                color: AppColors.accent,
                backgroundColor: AppColors.divider,
              ),
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
                cell(24, const Text('Filial', style: _head)),
                cell(
                  12,
                  const Text(
                    'O\'quvchilar',
                    textAlign: TextAlign.right,
                    style: _head,
                  ),
                ),
                cell(
                  18,
                  const Text(
                    'Bu oy tushum',
                    textAlign: TextAlign.right,
                    style: _head,
                  ),
                ),
                cell(
                  18,
                  const Text('Qarz', textAlign: TextAlign.right, style: _head),
                ),
                cell(
                  12,
                  const Text(
                    'Davomat',
                    textAlign: TextAlign.right,
                    style: _head,
                  ),
                ),
                cell(
                  8,
                  const Text(
                    'Darslar',
                    textAlign: TextAlign.right,
                    style: _head,
                  ),
                ),
                cell(
                  8,
                  const Text(
                    'So\'rovlar',
                    textAlign: TextAlign.right,
                    style: _head,
                  ),
                ),
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
                      24,
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
                      18,
                      _num(CurrencyFormatter.format(b.collectedThisMonth)),
                    ),
                    cell(
                      18,
                      _num(
                        b.totalDebt == 0
                            ? '—'
                            : CurrencyFormatter.format(b.totalDebt),
                        color: b.totalDebt > 0 ? AppColors.dangerText : null,
                      ),
                    ),
                    cell(12, _num(ratePercent(b.attendanceRate7d))),
                    cell(8, _num('${b.lessonsToday}')),
                    cell(8, _num('${b.openLeads}')),
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
        title: 'Bugungi jadval',
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
      title: 'Bugungi jadval',
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
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: l.isCancelled ? AppColors.neutralBg : AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.button),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
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
                  StatusChip(text, tone: tone),
                  if (canMark) ...<Widget>[
                    const SizedBox(width: 10),
                    FilledButton(
                      key: ValueKey('mark-${l.groupId}'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      onPressed: onMark,
                      child: const Text('Davomat olish'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Needs attention -------------------------------------------------------------

class _AttentionItem {
  const _AttentionItem({
    required this.key,
    required this.tag,
    required this.tone,
    required this.title,
    required this.detail,
    required this.action,
    required this.onAction,
  });

  final String key;
  final String tag;
  final StatusTone tone;
  final String title;
  final String detail;
  final String action;
  final VoidCallback onAction;
}

class _Attention extends StatelessWidget {
  const _Attention({required this.items});

  final List<_AttentionItem> items;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Diqqat talab qiladi',
      trailing: items.isEmpty ? null : '${items.length} ta',
      child: items.isEmpty
          ? const _Empty(
              'Hammasi joyida: hozircha hech narsa kutmayapti.',
              key: ValueKey('attention-empty'),
            )
          : Column(
              key: const ValueKey('attention'),
              children: <Widget>[
                for (var i = 0; i < items.length; i++) ...<Widget>[
                  if (i > 0) const Divider(height: 1, color: AppColors.divider),
                  _AttentionRow(item: items[i]),
                ],
              ],
            ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.item});

  final _AttentionItem item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey('attention-${item.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 70,
            child: Align(
              alignment: Alignment.centerLeft,
              child: StatusChip(item.tag, tone: item.tone),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  item.detail,
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
          OutlinedButton(
            key: ValueKey('attention-action-${item.key}'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onPressed: item.onAction,
            child: Text(item.action),
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
