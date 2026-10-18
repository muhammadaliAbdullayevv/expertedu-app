import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/person_avatar.dart';
import '../../../core/widgets/status_chip.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../auth/application/session_controller.dart';
import '../../branches/application/branch_view.dart';
import '../../finance/data/finance_repository.dart';
import '../../finance/presentation/finance_screen.dart';
import '../../photos/photo_actions.dart';
import '../../photos/photos_repository.dart';
import '../../timetable/data/timetable_models.dart';
import '../data/teachers_repository.dart';
import 'teacher_branches_dialog.dart';
import 'teacher_form_dialog.dart';
import 'teacher_text.dart';

const _caption = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w600,
  color: AppColors.inkMuted,
);

/// The right-hand page of one teacher: who they are, what they earn this
/// month, their groups with days and times, how their lessons go, today and
/// tomorrow, and the last six months of pay.
class TeacherPanel extends ConsumerStatefulWidget {
  const TeacherPanel({
    super.key,
    required this.teacherId,
    required this.onChanged,
  });

  final int teacherId;

  /// Something changed (an edit, a photo, archive): the table reloads.
  final VoidCallback onChanged;

  @override
  ConsumerState<TeacherPanel> createState() => _TeacherPanelState();
}

class _TeacherPanelState extends ConsumerState<TeacherPanel> {
  late Future<TeacherProfileData> _profile = _load();

  /// The salary month shown (its first day); null = this month.
  DateTime? _month;

  Future<TeacherProfileData> _load() => ref
      .read(teachersRepositoryProvider)
      .profile(widget.teacherId, month: _month);

  void _reload({bool tell = true}) {
    final next = _load();
    setState(() {
      _profile = next;
    });
    if (tell) widget.onChanged();
  }

  void _shiftMonth(TeacherProfileData p, int by) {
    final now = DateTime.now();
    final next = DateTime(p.month.year, p.month.month + by);
    setState(() {
      _month = next.year == now.year && next.month == now.month ? null : next;
    });
    _reload(tell: false);
  }

  Future<void> _edit(Teacher teacher) async {
    final saved = await showTeacherFormDialog(context, teacher: teacher);
    if (saved == true && mounted) _reload();
  }

  Future<void> _branches(Teacher teacher) async {
    final saved = await showTeacherBranchesDialog(context, teacher: teacher);
    if (saved == true && mounted) _reload();
  }

  Future<void> _photo(Teacher teacher, {required bool remove}) async {
    final changed = remove
        ? await removePhoto(context, ref, PhotoOwner.teacher, teacher.id)
        : await changePhoto(context, ref, PhotoOwner.teacher, teacher.id);
    if (changed && mounted) _reload();
  }

  Future<void> _setActive(TeacherProfileData p, bool active) async {
    if (!active && p.groups.isNotEmpty) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Arxivga o\'tkazilsinmi?'),
          content: Text(
            '${p.teacher.fullName}ning ${p.groups.length} ta guruhi bor. '
            'Arxivga o\'tsa ham guruhlari unda qoladi — avval boshqa '
            'o\'qituvchiga berishni unutmang.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Bekor qilish'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Arxivga o\'tkazish'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    }
    try {
      await ref
          .read(teachersRepositoryProvider)
          .setActive(p.teacher.id, active);
      if (mounted) _reload();
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    }
  }

  Future<void> _editRule(TeacherProfileData p) async {
    final saved = await showSalaryRuleDialog(
      context,
      TeacherSalary(
        teacherId: p.teacher.id,
        fullName: p.teacher.fullName,
        isActive: p.teacher.isActive,
        salaryMethod: p.salaryMethod,
        salaryPercent: p.salaryPercent,
        salaryFixed: p.salaryFixed,
        collected: p.collected,
        earned: p.earned,
        paid: p.paid,
        remaining: p.remaining,
      ),
    );
    if (saved == true && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<TeacherProfileData>(
        future: _profile,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return LoadFailed(error: snapshot.error!, onRetry: _reload);
          }
          final p = snapshot.data;
          if (p == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _header(p),
                const SizedBox(height: 16),
                // Pay is the owner's alone: an admin gets no salary card.
                if (p.salaryVisible) ...<Widget>[
                  _salaryCard(p),
                  const SizedBox(height: 22),
                ],
                const Text('Guruhlari', style: _caption),
                const SizedBox(height: 8),
                if (p.groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Hozircha guruhi yo\'q.',
                      key: ValueKey('teacher-no-groups'),
                      style: TextStyle(color: AppColors.inkMuted),
                    ),
                  ),
                for (final g in p.groups) _GroupCard(group: g),
                const SizedBox(height: 14),
                const Text('Bugun va ertaga', style: _caption),
                const SizedBox(height: 8),
                _Lessons(lessons: p.lessons),
                if (p.salaryVisible) ...<Widget>[
                  const SizedBox(height: 22),
                  const Text('So\'nggi 6 oy', style: _caption),
                  const SizedBox(height: 8),
                  _History(points: p.history),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(TeacherProfileData p) {
    final t = p.teacher;
    const muted = TextStyle(fontSize: 13, color: AppColors.inkMuted);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        PersonAvatar(name: t.fullName, photo: t.photo, radius: 28),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                t.fullName,
                key: const ValueKey('teacher-panel-name'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                t.phone == null
                    ? 'Telefon yo\'q'
                    : PhoneFormatter.display(t.phone!),
                style: muted,
              ),
              if (t.note != null && t.note!.isNotEmpty)
                Text(t.note!, style: muted),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  children: <Widget>[
                    StatusChip(
                      t.isActive ? 'Faol' : 'Arxiv',
                      tone: t.isActive ? StatusTone.ok : StatusTone.neutral,
                    ),
                    StatusChip('${p.studentTotal} o\'quvchi'),
                    for (final name in t.branchNames)
                      StatusChip(
                        name,
                        key: ValueKey('teacher-branch-chip-$name'),
                        tone: StatusTone.info,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Tahrirlash',
          child: InkWell(
            key: const ValueKey('teacher-edit'),
            borderRadius: BorderRadius.circular(AppRadius.button),
            onTap: () => _edit(t),
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.button),
                border: Border.all(color: AppColors.borderStrong),
              ),
              child: const Icon(Icons.edit_outlined, size: 19),
            ),
          ),
        ),
        const SizedBox(width: 6),
        PopupMenuButton<String>(
          key: const ValueKey('teacher-menu'),
          tooltip: 'Sozlamalar',
          onSelected: (value) => switch (value) {
            'photo' => _photo(t, remove: false),
            'photo-remove' => _photo(t, remove: true),
            'branches' => _branches(t),
            'archive' => _setActive(p, false),
            _ => _setActive(p, true),
          },
          itemBuilder: (_) => <PopupMenuEntry<String>>[
            PopupMenuItem(
              key: const ValueKey('menu-photo'),
              value: 'photo',
              child: Text(
                t.photo == null ? 'Rasm yuklash' : 'Rasmni almashtirish',
              ),
            ),
            if (t.photo != null)
              const PopupMenuItem(
                key: ValueKey('menu-photo-remove'),
                value: 'photo-remove',
                child: Text('Rasmni o\'chirish'),
              ),
            if (ref.read(sessionControllerProvider).isOwner)
              const PopupMenuItem(
                key: ValueKey('menu-branches'),
                value: 'branches',
                child: Text('Filiallarni o\'zgartirish'),
              ),
            const PopupMenuDivider(),
            PopupMenuItem(
              key: const ValueKey('menu-archive'),
              value: t.isActive ? 'archive' : 'restore',
              child: Text(t.isActive ? 'Arxivga o\'tkazish' : 'Faollashtirish'),
            ),
          ],
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.button),
              border: Border.all(color: AppColors.borderStrong),
            ),
            child: const Icon(Icons.more_horiz, size: 20),
          ),
        ),
      ],
    );
  }

  /// "Oylik · Oktyabr 2026": what the groups have collected so far, the
  /// agreed share, and so the salary at this moment.
  Widget _salaryCard(TeacherProfileData p) {
    final now = DateTime.now();
    final isNow = p.month.year == now.year && p.month.month == now.month;
    final hasRule = p.salaryMethod != null;
    final isOwner = ref.read(sessionControllerProvider).isOwner;
    return Container(
      key: const ValueKey('teacher-salary'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton(
                key: const ValueKey('teacher-month-prev'),
                visualDensity: VisualDensity.compact,
                tooltip: 'Oldingi oy',
                onPressed: () => _shiftMonth(p, -1),
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(
                  'Oylik · ${DateFormatters.monthYearLabel(p.month)}'
                  '${p.groups.length > 1 ? ' · ${p.groups.length} ta guruh jami' : ''}',
                  textAlign: TextAlign.center,
                  key: const ValueKey('teacher-month'),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.accentText,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('teacher-month-next'),
                visualDensity: VisualDensity.compact,
                tooltip: 'Keyingi oy',
                onPressed: isNow ? null : () => _shiftMonth(p, 1),
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            CurrencyFormatter.format(p.earned),
            key: const ValueKey('teacher-earned'),
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            hasRule
                ? 'Yig\'ilgan ${CurrencyFormatter.format(p.collected)} dan '
                      '${ruleText(p.salaryMethod, p.salaryPercent, p.salaryFixed)}'
                : 'Oylik turi belgilanmagan — hisoblanmaydi.',
            key: const ValueKey('teacher-collected'),
            style: const TextStyle(fontSize: 13, color: AppColors.inkSecondary),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _fact('To\'langan', CurrencyFormatter.format(p.paid)),
              _fact('Qoldi', CurrencyFormatter.format(p.remaining)),
              if (p.monthClosed)
                const StatusChip('Oy yopilgan', tone: StatusTone.info)
              else if (isNow)
                const Tooltip(
                  message:
                      'Hozirgacha yig\'ilgan to\'lovlardan hisoblangan; to\'lovlar kelgan sari o\'zgaradi.',
                  child: StatusChip('Hozirgi holat'),
                ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Kelishuv: ${ruleText(p.salaryMethod, p.salaryPercent, p.salaryFixed)}',
                  key: const ValueKey('teacher-rule'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkSecondary,
                  ),
                ),
              ),
              if (isOwner)
                TextButton(
                  key: const ValueKey('teacher-rule-edit'),
                  onPressed: () => _editRule(p),
                  child: const Text('O\'zgartirish'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fact(String caption, String value) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(caption, style: _caption),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

/// One group: only its name, days and times, and how many students. Its
/// numbers (attendance, money) are on the group's own page.
class _GroupCard extends ConsumerWidget {
  const _GroupCard({required this.group});

  final TeacherGroupCard group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = group;
    final showBranch = ref.watch(showBranchLabelsProvider);
    return Container(
      key: ValueKey('teacher-group-${g.groupId}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            g.name,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          if ([
            ?g.subjectName,
            ?g.level,
            if (showBranch) ?g.branchName,
          ].isNotEmpty)
            Text(
              [
                ?g.subjectName,
                ?g.level,
                if (showBranch) ?g.branchName,
              ].join(' · '),
              style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
            ),
          const SizedBox(height: 8),
          Text(
            '${scheduleSummary(g.schedule)} · '
            '${studentsText(g.studentCount, g.capacity)}',
            key: ValueKey('teacher-group-info-${g.groupId}'),
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// "Bugun 14:00–15:30 · Beginner A": today's and tomorrow's lessons.
class _Lessons extends StatelessWidget {
  const _Lessons({required this.lessons});

  final List<TimetableLesson> lessons;

  static String _day(DateTime when) {
    final today = DateTime.now();
    final local = when.toLocal();
    final d = DateTime(local.year, local.month, local.day);
    final t = DateTime(today.year, today.month, today.day);
    return switch (d.difference(t).inDays) {
      0 => 'Bugun',
      1 => 'Ertaga',
      _ => DateFormatters.date(local),
    };
  }

  @override
  Widget build(BuildContext context) {
    if (lessons.isEmpty) {
      return const Text(
        'Bugun va ertaga dars yo\'q.',
        key: ValueKey('teacher-lessons'),
        style: TextStyle(color: AppColors.inkMuted),
      );
    }
    return Column(
      key: const ValueKey('teacher-lessons'),
      children: <Widget>[
        for (final l in lessons)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 56,
                  child: Text(
                    _day(l.startsAt),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.inkMuted,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${DateFormatters.time(l.startsAt)}–${DateFormatters.time(l.endsAt)}'
                    ' · ${l.groupName}${l.room == null ? '' : ' · ${l.room}'}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (l.isCancelled)
                  const StatusChip('Bekor qilingan', tone: StatusTone.danger)
                else if (l.isMarked)
                  const StatusChip('Davomat olingan', tone: StatusTone.ok),
              ],
            ),
          ),
      ],
    );
  }
}

/// Six months of pay: a bar for what was earned, and what was paid out.
class _History extends StatelessWidget {
  const _History({required this.points});

  final List<TeacherMonthPoint> points;

  @override
  Widget build(BuildContext context) {
    final most = points.fold<int>(0, (m, p) => p.earned > m ? p.earned : m);
    return Column(
      key: const ValueKey('teacher-history'),
      children: <Widget>[
        for (final p in points)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 86,
                  child: Text(
                    DateFormatters.monthYearLabel(p.month),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: most == 0 ? 0 : p.earned / most,
                      minHeight: 8,
                      color: AppColors.accent,
                      backgroundColor: AppColors.divider,
                    ),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: Text(
                    CurrencyFormatter.format(p.earned),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (p.closed)
                  Tooltip(
                    message: p.paid >= p.earned && p.earned > 0
                        ? 'To\'liq to\'langan'
                        : 'To\'langan: ${CurrencyFormatter.format(p.paid)}',
                    child: Icon(
                      p.paid >= p.earned && p.earned > 0
                          ? Icons.check_circle_rounded
                          : Icons.lock_outline_rounded,
                      size: 16,
                      color: p.paid >= p.earned && p.earned > 0
                          ? AppColors.okText
                          : AppColors.inkMuted,
                    ),
                  )
                else
                  const SizedBox(width: 16),
              ],
            ),
          ),
      ],
    );
  }
}
