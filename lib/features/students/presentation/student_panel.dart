import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/status_chip.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../../admissions/presentation/qabul_text.dart';
import '../data/student_models.dart';
import '../data/students_repository.dart';
import 'add_to_group_dialog.dart';
import 'student_dialogs.dart';
import 'student_text.dart';

/// The last lessons as small bars: a full bar for a lesson they came to, a
/// faint one for a lesson they missed -- the table's and the panel's
/// attendance indicator. Nothing marked yet shows ten empty slots.
class AttendanceBars extends StatelessWidget {
  const AttendanceBars(this.statuses, {super.key, this.height = 16});

  final List<String> statuses;
  final double height;

  @override
  Widget build(BuildContext context) {
    final marks = statuses.length > 10
        ? statuses.sublist(statuses.length - 10)
        : statuses;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (var i = 0; i < 10; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Container(
              width: 5,
              height: height,
              decoration: BoxDecoration(
                color: i < marks.length ? _color(marks[i]) : AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
      ],
    );
  }

  static Color _color(String status) => switch (status) {
    'present' => AppColors.accent,
    'late' => AppColors.accent.withValues(alpha: 0.55),
    'absent' => AppColors.danger.withValues(alpha: 0.45),
    _ => AppColors.borderStrong,
  };
}

/// The right-hand profile of one student: who they are, what they owe, their
/// groups, payments and attendance. Taking and cancelling a payment, editing
/// the profile and adding to another group happen here and nowhere else.
class StudentPanel extends ConsumerStatefulWidget {
  const StudentPanel({
    super.key,
    required this.studentId,
    required this.onChanged,
  });

  final int studentId;

  /// Something changed (a payment, an edit, a new group): the table reloads.
  final VoidCallback onChanged;

  @override
  ConsumerState<StudentPanel> createState() => StudentPanelState();
}

class StudentPanelState extends ConsumerState<StudentPanel> {
  static const _tabs = <String>['Umumiy', 'To\'lovlar', 'Davomat', 'Izohlar'];

  late Future<StudentProfileData> _profile = _load();
  int _tab = 0;

  Future<StudentProfileData> _load() =>
      ref.read(studentsRepositoryProvider).profile(widget.studentId);

  @override
  void didUpdateWidget(StudentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.studentId != widget.studentId) {
      _profile = _load();
      _tab = 0;
    }
  }

  void _reload() {
    final next = _load();
    setState(() {
      _profile = next;
    });
    widget.onChanged();
  }

  Future<void> _takePayment(StudentProfileData p, {int? enrollmentId}) async {
    final saved = await showPaymentDialog(
      context,
      profile: p,
      enrollmentId: enrollmentId,
    );
    if (saved == true && mounted) {
      showSnack(context, 'To\'lov qabul qilindi.');
      _reload();
    }
  }

  Future<void> _cancelPayment(ProfilePayment payment) async {
    final cancelled = await showCancelPaymentDialog(context, payment: payment);
    if (cancelled == true && mounted) {
      showSnack(context, 'To\'lov bekor qilindi.');
      _reload();
    }
  }

  Future<void> _edit(StudentProfileData p) async {
    final saved = await showEditStudentDialog(context, student: p.student);
    if (saved != null && mounted) {
      showSnack(context, 'Profil saqlandi.');
      _reload();
    }
  }

  Future<void> _addToGroup(StudentProfileData p) async {
    final added = await showAddToGroupDialog(context, profile: p);
    if (added != null && mounted) {
      showSnack(
        context,
        '${p.student.fullName} ${added.groupName} guruhiga qo\'shildi · '
        'birinchi hisob ${CurrencyFormatter.format(added.firstCharge)}',
      );
      _reload();
    }
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
      child: FutureBuilder<StudentProfileData>(
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
                _actions(p),
                if (p.balance != 0) ...<Widget>[
                  const SizedBox(height: 14),
                  _balanceCard(p),
                ],
                const SizedBox(height: 18),
                _tabBar(),
                const SizedBox(height: 16),
                switch (_tab) {
                  0 => _Overview(
                    profile: p,
                    onPay: (e) => _takePayment(p, enrollmentId: e),
                  ),
                  1 => _Payments(
                    profile: p,
                    onCancel: _cancelPayment,
                    onPay: () => _takePayment(p),
                  ),
                  2 => _AttendanceTab(profile: p),
                  _ => _Notes(profile: p, onEdit: () => _edit(p)),
                },
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(StudentProfileData p) {
    final s = p.student;
    const muted = TextStyle(fontSize: 13, color: AppColors.inkMuted);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        CircleAvatar(
          radius: 28,
          backgroundColor: AppColors.accentSoft,
          child: Text(
            initials(s.fullName),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.accentText,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                s.fullName,
                key: const ValueKey('panel-name'),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(PhoneFormatter.display(s.phone), style: muted),
              if (s.parentPhone != null)
                Text(
                  'Ota-onasi: ${PhoneFormatter.display(s.parentPhone!)}',
                  style: muted,
                ),
              if (s.address != null && s.address!.isNotEmpty)
                Text(s.address!, style: muted),
              if (p.isNew)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: StatusChip('Yangi', tone: StatusTone.info),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: 'Profilni tahrirlash',
          child: InkWell(
            key: const ValueKey('panel-edit'),
            borderRadius: BorderRadius.circular(AppRadius.button),
            onTap: () => _edit(p),
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
          key: const ValueKey('panel-menu'),
          tooltip: 'Sozlamalar',
          onSelected: (value) => value == 'edit' ? _edit(p) : _addToGroup(p),
          itemBuilder: (_) => const <PopupMenuEntry<String>>[
            PopupMenuItem(value: 'edit', child: Text('Profilni tahrirlash')),
            PopupMenuItem(
              value: 'group',
              child: Text('Boshqa guruhga qo\'shish'),
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

  Widget _actions(StudentProfileData p) {
    return Row(
      children: <Widget>[
        Expanded(
          child: FilledButton(
            key: const ValueKey('panel-pay'),
            onPressed: p.activeGroups.isEmpty ? null : () => _takePayment(p),
            child: const Text('To\'lov qabul qilish'),
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton(
          key: const ValueKey('panel-add-group'),
          onPressed: () => _addToGroup(p),
          child: const Text('Boshqa guruhga qo\'shish'),
        ),
      ],
    );
  }

  /// "Joriy qarz 390 000 · 3 kun kechikdi · Muddat: 14-oktyabr" -- or the
  /// money they have paid ahead.
  Widget _balanceCard(StudentProfileData p) {
    final owes = p.balance > 0;
    return Container(
      key: const ValueKey('panel-balance'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: owes ? AppColors.dangerBg : AppColors.okBg,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  owes ? 'Joriy qarz' : 'Oldindan to\'langan',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: owes ? AppColors.dangerText : AppColors.okText,
                  ),
                ),
                Text(
                  CurrencyFormatter.format(
                    p.balance.abs(),
                  ).replaceAll(' so\'m', ''),
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: owes ? AppColors.dangerText : AppColors.okText,
                  ),
                ),
              ],
            ),
          ),
          if (owes && p.debtSince != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  overdueText(p.overdueDays),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.dangerText,
                  ),
                ),
                Text(
                  'Muddat: ${dueText(p.debtSince)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.dangerText,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _tabBar() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: <Widget>[
          for (final (i, label) in _tabs.indexed)
            InkWell(
              key: ValueKey('panel-tab-$i'),
              onTap: () => setState(() => _tab = i),
              child: Container(
                height: 40,
                margin: const EdgeInsets.only(right: 20),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: i == _tab ? AppColors.accent : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: i == _tab ? AppColors.ink : AppColors.inkMuted,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

const _caption = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w600,
  color: AppColors.inkMuted,
);

/// Umumiy: every group the student is in, and what happened lately.
class _Overview extends StatelessWidget {
  const _Overview({required this.profile, required this.onPay});

  final StudentProfileData profile;
  final ValueChanged<int> onPay;

  @override
  Widget build(BuildContext context) {
    final active = profile.activeGroups;
    final ended = profile.groups.where((g) => !g.isActive).toList();
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (active.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Hech qaysi guruhda emas.',
              style: TextStyle(color: AppColors.inkMuted),
            ),
          ),
        for (final g in active) _GroupCard(group: g),
        if (ended.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              'Chiqib ketgan: ${ended.map((g) => g.groupName).join(', ')}',
              style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
            ),
          ),
        const SizedBox(height: 10),
        const Text('So\'nggi faollik', style: _caption),
        const SizedBox(height: 4),
        if (profile.activity.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Hali hech narsa bo\'lmagan.',
              style: TextStyle(color: AppColors.inkMuted),
            ),
          ),
        for (final item in profile.activity.take(6))
          _ActivityRow(item: item, now: now),
      ],
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group});

  final ProfileGroup group;

  @override
  Widget build(BuildContext context) {
    final g = group;
    Widget fact(String caption, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(caption, style: _caption),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
    return Container(
      key: ValueKey('group-card-${g.groupId}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  g.groupName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              g.balance > 0
                  ? StatusChip(
                      'Qarz ${CurrencyFormatter.format(g.balance)}',
                      tone: StatusTone.danger,
                    )
                  : const StatusChip('To\'langan', tone: StatusTone.ok),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              fact('O\'qituvchi', g.teacherName ?? '–'),
              fact(
                'Dars vaqti',
                g.schedule.isEmpty
                    ? 'Jadval kiritilmagan'
                    : slotsWithEnd(g.schedule),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              fact('Oylik narx', CurrencyFormatter.format(g.feeAmount)),
              fact('Qo\'shilgan', dayMonth(g.joinedAt)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              AttendanceBars(g.attendance.recent),
              const SizedBox(width: 10),
              Text(
                ratePercent(g.attendance.rate),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              const Text('davomat', style: _caption),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.item, required this.now});

  final ActivityItem item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final color = switch (item.kind) {
      'payment' => AppColors.okText,
      'charge' || 'absent' || 'payment_cancelled' => AppColors.dangerText,
      'late' => AppColors.warnText,
      _ => AppColors.ink,
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 78,
            child: Text(
              dayLabel(item.at, now),
              style: const TextStyle(fontSize: 13, color: AppColors.inkMuted),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  item.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                Text(
                  <String>[
                    ?item.detail,
                    if (item.amount != null)
                      CurrencyFormatter.format(item.amount!),
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// To'lovlar: every payment with its method, who took it and its receipt
/// number; a valid one can be cancelled (with a reason) -- here only.
class _Payments extends StatelessWidget {
  const _Payments({
    required this.profile,
    required this.onCancel,
    required this.onPay,
  });

  final StudentProfileData profile;
  final ValueChanged<ProfilePayment> onCancel;
  final VoidCallback onPay;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Jami to\'langan: ${CurrencyFormatter.format(profile.paidTotal)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            OutlinedButton(
              key: const ValueKey('payments-pay'),
              onPressed: profile.activeGroups.isEmpty ? null : onPay,
              child: const Text('To\'lov qabul qilish'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (profile.payments.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'Hali to\'lov olinmagan.',
              style: TextStyle(color: AppColors.inkMuted),
            ),
          ),
        for (final p in profile.payments)
          Container(
            key: ValueKey('payment-${p.id}'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.divider)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text(
                            CurrencyFormatter.format(p.amount),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              decoration: p.isCancelled
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: p.isCancelled
                                  ? AppColors.inkMuted
                                  : AppColors.ink,
                            ),
                          ),
                          const SizedBox(width: 8),
                          StatusChip(methodLabel(p.method)),
                          if (p.isCancelled) ...<Widget>[
                            const SizedBox(width: 6),
                            const StatusChip(
                              'Bekor qilingan',
                              tone: StatusTone.danger,
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        <String>[
                          dayLabel(p.receivedAt, now),
                          ?p.groupName,
                          if (p.receivedByName != null) p.receivedByName!,
                          if (p.receiptNo != null) '№ ${p.receiptNo}',
                        ].join(' · '),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.inkMuted,
                        ),
                      ),
                      if (p.isCancelled && p.cancelReason != null)
                        Text(
                          'Sabab: ${p.cancelReason}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.dangerText,
                          ),
                        ),
                    ],
                  ),
                ),
                if (!p.isCancelled)
                  TextButton(
                    key: ValueKey('cancel-payment-${p.id}'),
                    onPressed: () => onCancel(p),
                    child: const Text('Bekor qilish'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Davomat: the overall share, the counts, each group and the latest lessons.
class _AttendanceTab extends StatelessWidget {
  const _AttendanceTab({required this.profile});

  final StudentProfileData profile;

  @override
  Widget build(BuildContext context) {
    final a = profile.attendance;
    final now = DateTime.now();
    Widget count(String label, int n, StatusTone tone) => Expanded(
      child: Column(
        children: <Widget>[
          Text(
            '$n',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          StatusChip(label, tone: tone),
        ],
      ),
    );
    if (a.total == 0) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'Hali birorta dars belgilanmagan.',
          style: TextStyle(color: AppColors.inkMuted),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Text(
              ratePercent(a.rate),
              key: const ValueKey('attendance-rate'),
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '${a.total} ta darsdan',
                style: const TextStyle(color: AppColors.inkMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            count('Keldi', a.present, StatusTone.ok),
            count('Kechikdi', a.late, StatusTone.warning),
            count('Kelmadi', a.absent, StatusTone.danger),
            count('Sababli', a.excused, StatusTone.neutral),
          ],
        ),
        const SizedBox(height: 18),
        const Text('Guruhlar bo\'yicha', style: _caption),
        const SizedBox(height: 6),
        for (final g in profile.activeGroups)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    g.groupName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                AttendanceBars(g.attendance.recent),
                SizedBox(
                  width: 52,
                  child: Text(
                    ratePercent(g.attendance.rate),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        const Text('So\'nggi darslar', style: _caption),
        for (final m in profile.marks.take(10))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 78,
                  child: Text(
                    dayLabel(m.at, now),
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.inkMuted,
                    ),
                  ),
                ),
                Expanded(child: Text(m.groupName)),
                StatusChip(
                  attendanceLabel(m.status),
                  tone: attendanceTone(m.status),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Izohlar: what was written about the student; changed with "Tahrirlash".
class _Notes extends StatelessWidget {
  const _Notes({required this.profile, required this.onEdit});

  final StudentProfileData profile;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final note = profile.student.note;
    final has = note != null && note.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          has ? note : 'Izoh yo\'q.',
          key: const ValueKey('panel-note'),
          style: TextStyle(
            fontSize: 14,
            height: 1.4,
            color: has ? AppColors.ink : AppColors.inkMuted,
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: onEdit,
          child: Text(has ? 'Izohni o\'zgartirish' : 'Izoh yozish'),
        ),
      ],
    );
  }
}
