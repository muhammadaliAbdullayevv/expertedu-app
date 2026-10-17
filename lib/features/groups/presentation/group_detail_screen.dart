import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../admissions/data/admissions_models.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../admissions/presentation/qabul_text.dart';
import '../../admissions/presentation/qabul_widgets.dart';
import '../../admissions/presentation/student_dialog.dart';
import '../../enrollments/data/enrollments_repository.dart';
import '../../enrollments/presentation/enroll_student_sheet.dart';
import '../../students/presentation/student_panel.dart';
import '../../students/presentation/student_text.dart';
import '../data/group_profile_models.dart';
import '../data/groups_repository.dart';
import 'group_form_dialog.dart';
import 'groups_breadcrumb.dart';

/// A group's profile page, inside Guruhlar (the sidebar stays): the teacher,
/// how full it is, who has paid, how they attend, when it meets and bills,
/// what was collected of what was expected -- then its students, with the
/// selected student's profile beside them.
class GroupDetailScreen extends ConsumerStatefulWidget {
  const GroupDetailScreen({super.key, required this.group, this.courseName});

  final Group group;

  /// The course (subject) this group is under, for the breadcrumb.
  final String? courseName;

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  /// Below this width the student's profile does not fit beside the list.
  static const double _splitWidth = 1100;

  late Future<({GroupProfileData profile, List<RosterEntry> roster})> _data =
      _load();
  int? _selected;

  Future<({GroupProfileData profile, List<RosterEntry> roster})> _load() async {
    final repo = ref.read(groupsRepositoryProvider);
    final results = await Future.wait<Object>([
      repo.profile(widget.group.id),
      repo.roster(widget.group.id),
    ]);
    return (
      profile: results[0] as GroupProfileData,
      roster: results[1] as List<RosterEntry>,
    );
  }

  void _reload() {
    final next = _load();
    setState(() {
      _data = next;
    });
  }

  Future<void> _showOver(int studentId) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 480,
          height: MediaQuery.sizeOf(dialogContext).height * 0.9,
          child: StudentPanel(
            studentId: studentId,
            groupId: widget.group.id,
            onChanged: _reload,
          ),
        ),
      ),
    );
  }

  Future<void> _edit(Group group) async {
    final saved = await showGroupFormDialog(context, group: group);
    if (saved == true && mounted) _reload();
  }

  Future<void> _addStudent() async {
    final enrolled = await showEnrollStudentSheet(
      context,
      groupId: widget.group.id,
    );
    if (enrolled == true && mounted) _reload();
  }

  Future<void> _makeStudent(GroupWaiting w) async {
    final lead = Lead(
      id: w.leadId,
      clientId: 'waiting-${w.leadId}',
      fullName: w.fullName,
      phone: w.phone,
      stage: LeadStage.newLead,
      version: 0,
      createdAt: w.createdAt,
      groupId: widget.group.id,
    );
    final message = await showStudentDialog(
      context,
      lead: lead,
      groupId: widget.group.id,
    );
    if (message != null && mounted) {
      showSnack(context, message);
      _reload();
    }
  }

  Future<void> _confirmWithdraw(RosterEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('O\'quvchini chiqarish'),
        content: Text('${entry.studentFullName} shu guruhdan chiqarilsinmi?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Yo\'q'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Ha'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(enrollmentsRepositoryProvider).withdraw(entry.enrollmentId);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child:
          FutureBuilder<({GroupProfileData profile, List<RosterEntry> roster})>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(child: Text('Xatolik: ${snapshot.error}'));
              }
              final data = snapshot.data;
              if (data == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return LayoutBuilder(
                builder: (context, box) {
                  final split = box.maxWidth >= _splitWidth;
                  final roster = data.roster;
                  final selected = roster.any((e) => e.studentId == _selected)
                      ? _selected
                      : (roster.isEmpty ? null : roster.first.studentId);
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        GroupsBreadcrumb(
                          course: widget.courseName ?? data.profile.subjectName,
                          group: data.profile.group.name,
                        ),
                        const SizedBox(height: 14),
                        _title(data.profile),
                        const SizedBox(height: 16),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Expanded(
                                child: _left(
                                  data.profile,
                                  roster,
                                  selected,
                                  split,
                                ),
                              ),
                              if (split) ...<Widget>[
                                const SizedBox(width: 16),
                                SizedBox(
                                  width: 440,
                                  child: selected == null
                                      ? const SizedBox.shrink()
                                      : StudentPanel(
                                          key: ValueKey(
                                            'group-panel-$selected',
                                          ),
                                          studentId: selected,
                                          groupId: widget.group.id,
                                          onChanged: _reload,
                                        ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
    );
  }

  Widget _title(GroupProfileData p) {
    final g = p.group;
    return Row(
      children: <Widget>[
        Flexible(
          child: Text(
            g.name,
            key: const ValueKey('group-title'),
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
            ),
          ),
        ),
        const SizedBox(width: 12),
        if (g.level != null && g.level!.isNotEmpty)
          StatusChip(g.level!, tone: StatusTone.info),
        const SizedBox(width: 6),
        if (p.isFull)
          const StatusChip('To\'lgan', tone: StatusTone.warning)
        else if (p.freeSeats != null)
          StatusChip('${p.freeSeats} bo\'sh o\'rin', tone: StatusTone.ok),
        if (!g.isActive) ...<Widget>[
          const SizedBox(width: 6),
          const StatusChip('Arxiv'),
        ],
        const Spacer(),
        OutlinedButton(
          key: const ValueKey('group-edit'),
          onPressed: () => _edit(g),
          child: const Text('Tahrirlash'),
        ),
        const SizedBox(width: 10),
        FilledButton.icon(
          key: const ValueKey('group-add-student'),
          onPressed: _addStudent,
          icon: const Icon(Icons.person_add_alt_1, size: 18),
          label: const Text('O\'quvchi qo\'shish'),
        ),
      ],
    );
  }

  Widget _left(
    GroupProfileData p,
    List<RosterEntry> roster,
    int? selected,
    bool split,
  ) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        _stats(p),
        const SizedBox(height: 14),
        _details(p),
        if (p.waiting.isNotEmpty) ...<Widget>[
          const SizedBox(height: 14),
          _waiting(p),
        ],
        const SizedBox(height: 18),
        Text(
          'O\'quvchilar',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        if (roster.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Hali o\'quvchilar yo\'q.',
              style: TextStyle(color: AppColors.inkMuted),
            ),
          ),
        for (final entry in roster)
          _RosterRow(
            key: ValueKey('roster-${entry.studentId}'),
            entry: entry,
            selected: split && entry.studentId == selected,
            onTap: () {
              if (split) {
                setState(() => _selected = entry.studentId);
              } else {
                _showOver(entry.studentId);
              }
            },
            onWithdraw: () => _confirmWithdraw(entry),
          ),
      ],
    );
  }

  Widget _card({required Widget child, Key? key, EdgeInsets? padding}) =>
      Container(
        key: key,
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      );

  /// O'quvchilar, who paid, attendance, and how much of the expected money came in.
  Widget _stats(GroupProfileData p) {
    const caption = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: AppColors.inkMuted,
    );
    const big = TextStyle(fontSize: 22, fontWeight: FontWeight.w700);
    Widget tile(Key key, String title, Widget body, {double flex = 1}) =>
        Expanded(
          flex: (flex * 10).round(),
          child: _card(
            key: key,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: caption),
                const SizedBox(height: 6),
                body,
              ],
            ),
          ),
        );
    final att = p.attendance;
    final paidShare = p.studentCount == 0 ? 0.0 : p.paidCount / p.studentCount;
    // Equal heights without a fixed one: this sits in a scrolling list.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          tile(
            const ValueKey('stat-students'),
            'O\'quvchilar',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  p.capacity == null
                      ? '${p.studentCount}'
                      : '${p.studentCount} / ${p.capacity}',
                  key: const ValueKey('stat-students-value'),
                  style: big,
                ),
                Text(
                  p.isFull
                      ? 'To\'lgan'
                      : p.freeSeats == null
                      ? 'O\'rin cheklanmagan'
                      : '${p.freeSeats} ta bo\'sh',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          tile(
            const ValueKey('stat-payments'),
            'To\'lov holati',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      '${p.paidCount}',
                      key: const ValueKey('stat-paid'),
                      style: big.copyWith(color: AppColors.okText),
                    ),
                    const Text(
                      ' to\'lagan  ',
                      style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
                    ),
                    Text(
                      '${p.unpaidCount}',
                      key: const ValueKey('stat-unpaid'),
                      style: big.copyWith(
                        color: p.unpaidCount > 0
                            ? AppColors.dangerText
                            : AppColors.inkMuted,
                      ),
                    ),
                    const Text(
                      ' qarzdor',
                      style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _Bar(paidShare, color: AppColors.okText),
              ],
            ),
            flex: 1.3,
          ),
          const SizedBox(width: 12),
          tile(
            const ValueKey('stat-attendance'),
            'Davomat',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  ratePercent(att.rate),
                  key: const ValueKey('stat-attendance-value'),
                  style: big,
                ),
                Text(
                  att.total == 0
                      ? 'Dars belgilanmagan'
                      : '${att.total} ta belgi · ${att.absent} ta kelmagan',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          tile(
            const ValueKey('stat-collected'),
            'Yig\'ildi (shu davr)',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${_millions(p.collected)} / ${_millions(p.expected)}',
                  key: const ValueKey('stat-collected-value'),
                  style: big,
                ),
                const SizedBox(height: 8),
                _Bar(p.collectedShare),
                const SizedBox(height: 4),
                Text(
                  p.debtTotal > 0
                      ? 'Jami qarz: ${CurrencyFormatter.format(p.debtTotal)}'
                      : 'Qarz yo\'q',
                  key: const ValueKey('stat-debt'),
                  style: TextStyle(
                    fontSize: 12,
                    color: p.debtTotal > 0
                        ? AppColors.dangerText
                        : AppColors.inkMuted,
                  ),
                ),
              ],
            ),
            flex: 1.5,
          ),
        ],
      ),
    );
  }

  /// "5,2 mln" -- the cards are small; the exact amount is on the debt line
  /// and in each student's profile.
  String _millions(int amount) => CurrencyFormatter.compact(amount);

  /// Teacher, days and times, payment day, price, start, next lessons.
  Widget _details(GroupProfileData p) {
    final g = p.group;
    const caption = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: AppColors.inkMuted,
    );
    Widget fact(String label, Widget value, {Key? key}) => Expanded(
      child: Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: caption),
          const SizedBox(height: 4),
          value,
        ],
      ),
    );
    const strong = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);
    final days = p.schedule.map((s) => s.weekday).toSet();
    final t = p.teacher;
    return _card(
      key: const ValueKey('group-details'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              fact(
                'Mas\'ul o\'qituvchi',
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t?.fullName ?? 'Biriktirilmagan',
                      key: const ValueKey('group-teacher'),
                      style: strong,
                    ),
                    if (t?.phone != null)
                      Text(
                        PhoneFormatter.display(t!.phone!),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.inkMuted,
                        ),
                      ),
                  ],
                ),
              ),
              fact(
                'Dars kunlari va vaqti',
                days.isEmpty
                    ? const StatusChip(
                        'Jadval kiritilmagan',
                        tone: StatusTone.warning,
                      )
                    : Column(
                        key: const ValueKey('group-schedule'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Wrap(
                            spacing: 3,
                            runSpacing: 3,
                            children: <Widget>[
                              for (var d = 1; d <= 7; d++)
                                DayPill(
                                  weekdayAbbr[d],
                                  inGroup: days.contains(d),
                                  wanted: days.contains(d),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            slotsWithEnd(p.schedule).split(' · ').last,
                            style: strong,
                          ),
                        ],
                      ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              fact(
                'To\'lov kuni',
                Column(
                  key: const ValueKey('group-billing'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(g.billingLabel, style: strong),
                    Text(
                      p.nextBillingDate == null
                          ? 'Har o\'quvchi o\'z kunida to\'laydi'
                          : 'Keyingisi: ${dayMonth(p.nextBillingDate!)}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              fact(
                'Oylik narx',
                Text(CurrencyFormatter.format(g.feeAmount), style: strong),
              ),
              fact(
                'Boshlangan',
                Text(
                  g.startDate == null ? '–' : dayMonth(g.startDate!),
                  style: strong,
                ),
              ),
            ],
          ),
          if (p.nextLessons.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            const Text('Keyingi darslar', style: caption),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                for (final d in p.nextLessons)
                  StatusChip('${weekdayDate(d)} ${clock(d)}'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// People who saved this group in Qabul and are not students yet -- listed
  /// here, kept out of the student count and the seats.
  Widget _waiting(GroupProfileData p) {
    return _card(
      key: const ValueKey('group-waiting'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Text(
                'Kutayotganlar',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
              Text(
                '${p.waiting.length} kishi · o\'quvchilar soniga kirmaydi',
                style: const TextStyle(fontSize: 12, color: AppColors.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final w in p.waiting)
            Padding(
              key: ValueKey('waiting-${w.leadId}'),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: AppColors.warnBg,
                    child: Text(
                      initials(w.fullName),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.warnText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          w.fullName,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          PhoneFormatter.display(w.phone),
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.inkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (w.trialAt != null) ...<Widget>[
                    StatusChip(
                      'Sinov: ${weekdayDate(w.trialAt!)} ${clock(w.trialAt!)}',
                      tone: StatusTone.info,
                    ),
                    const SizedBox(width: 8),
                  ],
                  const StatusChip(
                    'Hali o\'quvchi emas',
                    tone: StatusTone.warning,
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    key: ValueKey('make-student-${w.leadId}'),
                    onPressed: () => _makeStudent(w),
                    child: const Text('O\'quvchi qilish'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A thin progress bar.
class _Bar extends StatelessWidget {
  const _Bar(this.share, {this.color = AppColors.accent});

  final double share;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: share.clamp(0.0, 1.0),
        minHeight: 7,
        color: color,
        backgroundColor: AppColors.divider,
      ),
    );
  }
}

/// One student of the group: new ones are listed first, marked "Yangi".
class _RosterRow extends StatelessWidget {
  const _RosterRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
    required this.onWithdraw,
  });

  final RosterEntry entry;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onWithdraw;

  @override
  Widget build(BuildContext context) {
    final owes = entry.balance > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
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
              CircleAvatar(
                backgroundColor: owes ? AppColors.dangerBg : AppColors.okBg,
                child: Icon(
                  Icons.school,
                  color: owes ? AppColors.dangerText : AppColors.okText,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            entry.studentFullName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (entry.isNew) ...<Widget>[
                          const SizedBox(width: 8),
                          const StatusChip('Yangi', tone: StatusTone.info),
                        ],
                      ],
                    ),
                    Text(
                      owes
                          ? 'Qarz: ${CurrencyFormatter.format(entry.balance)}'
                          : 'To\'langan',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: owes ? AppColors.dangerText : AppColors.okText,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.person_remove_outlined),
                tooltip: 'Chiqarish',
                onPressed: onWithdraw,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
