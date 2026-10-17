import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../services/api/api_client.dart';
import '../data/admissions_models.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';
import 'lead_action_dialogs.dart';
import 'lead_details_panel.dart';

const List<String> _weekdays = <String>[
  'Dushanba',
  'Seshanba',
  'Chorshanba',
  'Payshanba',
  'Juma',
  'Shanba',
  'Yakshanba',
];

/// "Sinov darslari": a week of trial sessions, as a calendar (a column per
/// day) or a list. Attendance is marked here, per booking -- it's kept on
/// the trial booking only, apart from anything about regular groups.
class TrialsView extends ConsumerStatefulWidget {
  const TrialsView({super.key});

  @override
  ConsumerState<TrialsView> createState() => _TrialsViewState();
}

class _TrialsViewState extends ConsumerState<TrialsView> {
  late DateTime _weekStart = _mondayOf(DateTime.now());
  bool _asList = false;
  bool _showCancelled = false;
  late Future<List<TrialSession>> _sessions = _load();
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);

  static DateTime _mondayOf(DateTime day) {
    final date = DateUtils.dateOnly(day);
    return date.subtract(Duration(days: date.weekday - 1));
  }

  @override
  void initState() {
    super.initState();
    _refresh.addListener(_reload);
  }

  @override
  void dispose() {
    _refresh.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    if (mounted) setState(() => _sessions = _load());
  }

  Future<List<TrialSession>> _load() => ref
      .read(admissionsRepositoryProvider)
      .listSessions(
        _weekStart,
        _weekStart.add(const Duration(days: 6)),
        includeCancelled: _showCancelled,
      );

  void _shiftWeek(int weeks) {
    _weekStart = DateUtils.dateOnly(_weekStart.add(Duration(days: 7 * weeks)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final weekEnd = _weekStart.add(const Duration(days: 6));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              IconButton.outlined(
                tooltip: 'Oldingi hafta',
                onPressed: () => _shiftWeek(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton.outlined(
                tooltip: 'Keyingi hafta',
                onPressed: () => _shiftWeek(1),
                icon: const Icon(Icons.chevron_right),
              ),
              OutlinedButton(
                onPressed: () {
                  _weekStart = _mondayOf(DateTime.now());
                  _reload();
                },
                child: const Text('Bu hafta'),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  DateFormatters.dateRangeLabel(_weekStart, weekEnd),
                  style: context.textTheme.titleMedium,
                ),
              ),
              SegmentedButton<bool>(
                segments: const <ButtonSegment<bool>>[
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.calendar_view_week_rounded),
                    label: Text('Kalendar'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.view_list_rounded),
                    label: Text('Ro\'yxat'),
                  ),
                ],
                selected: <bool>{_asList},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _asList = s.first),
              ),
              FilterChip(
                label: const Text('Bekor qilinganlar'),
                selected: _showCancelled,
                onSelected: (v) {
                  _showCancelled = v;
                  _reload();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: FutureBuilder<List<TrialSession>>(
              future: _sessions,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return LoadFailed(error: snapshot.error!, onRetry: _reload);
                }
                final sessions = snapshot.data;
                if (sessions == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return LayoutBuilder(
                  builder: (context, constraints) =>
                      _asList || constraints.maxWidth < 900
                      ? _list(sessions)
                      : _calendar(sessions),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _calendar(List<TrialSession> sessions) {
    final today = DateUtils.dateOnly(DateTime.now());
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Builder(
              builder: (context) {
                final day = _weekStart.add(Duration(days: i));
                final daySessions = sessions
                    .where(
                      (s) => DateUtils.isSameDay(s.startsAt.toLocal(), day),
                    )
                    .toList();
                final isToday = DateUtils.isSameDay(day, today);
                return Container(
                  margin: EdgeInsets.only(right: i == 6 ? 0 : 8),
                  decoration: BoxDecoration(
                    color: context.colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isToday
                          ? context.colors.onSurface
                          : context.colors.outlineVariant,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          '${_weekdays[i]}\n${day.day} ${DateFormatters.monthName(day).toLowerCase()}',
                          style: context.textTheme.labelLarge,
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                          children: <Widget>[
                            for (final session in daySessions)
                              _SessionCard(
                                session: session,
                                compact: true,
                                onTap: () => _openSession(session),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _list(List<TrialSession> sessions) {
    if (sessions.isEmpty) {
      return const EmptyNote(
        'Bu haftada sinov darsi yo\'q.\nSo\'rov ichidan "Sinov darsi" orqali yozing.',
      );
    }
    return ListView(
      children: <Widget>[
        for (final session in sessions)
          _SessionCard(session: session, onTap: () => _openSession(session)),
      ],
    );
  }

  Future<void> _openSession(TrialSession session) async {
    await showAdaptiveFormDialog<void>(
      context,
      maxWidth: 620,
      child: _SessionSheet(sessionId: session.id, initial: session),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.onTap,
    this.compact = false,
  });

  final TrialSession session;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cancelled = session.status == 'cancelled';
    final time =
        '${DateFormatters.time(session.startsAt)}–${DateFormatters.time(session.endsAt)}';
    final details = <String>[
      ?session.teacherName,
      ?session.room,
      'joy: ${session.booked}/${session.capacity}',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Opacity(
            opacity: cancelled ? 0.5 : 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  compact
                      ? time
                      : '${DateFormatters.dateGroupLabel(session.startsAt)}, $time',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  session.title + (cancelled ? ' (bekor qilingan)' : ''),
                  maxLines: compact ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall,
                ),
                Text(
                  details,
                  maxLines: compact ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colors.onSurfaceVariant,
                  ),
                ),
                if (!compact && session.bookings.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final booking in session.bookings)
                        if (booking.status != TrialStatus.rescheduled)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              '${booking.leadFullName} · ${TrialStatus.label(booking.status)}',
                            ),
                          ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One session's bookings, with attendance to mark once it has started.
class _SessionSheet extends ConsumerStatefulWidget {
  const _SessionSheet({required this.sessionId, required this.initial});

  final int sessionId;
  final TrialSession initial;

  @override
  ConsumerState<_SessionSheet> createState() => _SessionSheetState();
}

class _SessionSheetState extends ConsumerState<_SessionSheet> {
  late TrialSession _session = widget.initial;
  late final ValueNotifier<int> _refresh = ref.read(admissionsRefreshProvider);
  String? _busyBooking;

  @override
  void initState() {
    super.initState();
    _refresh.addListener(_reload);
  }

  @override
  void dispose() {
    _refresh.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final day = DateUtils.dateOnly(_session.startsAt.toLocal());
    final sessions = await ref
        .read(admissionsRepositoryProvider)
        .listSessions(day, day, includeCancelled: true);
    final fresh = sessions.where((s) => s.id == widget.sessionId);
    if (mounted && fresh.isNotEmpty) setState(() => _session = fresh.first);
  }

  Future<void> _mark(TrialSessionBooking booking, String status) async {
    setState(() => _busyBooking = '${booking.id}');
    try {
      await ref
          .read(admissionsRepositoryProvider)
          .markAttendance(booking.id, status);
      refreshAdmissions(ref);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busyBooking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final cancelled = session.status == 'cancelled';
    final bookings = session.bookings
        .where((b) => b.status != TrialStatus.rescheduled)
        .toList();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DialogHeader(
          title: session.title,
          subtitle:
              '${DateFormatters.dateTime(session.startsAt)}–${DateFormatters.time(session.endsAt)} · '
              '${session.teacherName ?? 'o\'qituvchi tanlanmagan'}'
              '${session.room == null ? '' : ' · ${session.room}'} · '
              'joy: ${session.booked}/${session.capacity}',
        ),
        if (!session.hasStarted && !cancelled)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Davomat dars boshlangandan keyin belgilanadi.',
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            children: <Widget>[
              if (bookings.isEmpty) const EmptyNote('Hech kim yozilmagan'),
              for (final booking in bookings)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(booking.leadFullName),
                  subtitle: Text(
                    '${PhoneFormatter.display(booking.leadPhone)}'
                    '${booking.feedback == null ? '' : ' · ${booking.feedback}'}',
                  ),
                  onTap: () => showLeadDetails(context, leadId: booking.leadId),
                  trailing: Wrap(
                    spacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      TrialStatusChip(booking.status),
                      if (session.hasStarted &&
                          _busyBooking != '${booking.id}' &&
                          booking.status != TrialStatus.cancelled) ...<Widget>[
                        if (booking.status != TrialStatus.attended)
                          IconButton(
                            tooltip: 'Keldi',
                            onPressed: () =>
                                _mark(booking, TrialStatus.attended),
                            icon: const Icon(Icons.check_circle_outline),
                          ),
                        if (booking.status != TrialStatus.absent)
                          IconButton(
                            tooltip: 'Kelmadi',
                            onPressed: () => _mark(booking, TrialStatus.absent),
                            icon: const Icon(Icons.cancel_outlined),
                          ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Row(
            children: <Widget>[
              if (!cancelled && !session.hasStarted)
                TextButton.icon(
                  onPressed: () => showReasonDialog(
                    context,
                    title: 'Sinov darsini bekor qilish',
                    subtitle:
                        'Yozilganlar "Bog\'lanildi" bosqichiga qaytadi va ularga '
                        'qayta bog\'lanish vazifasi qo\'shiladi.',
                    action: 'Darsni bekor qilish',
                    onConfirm: (reason) async {
                      await ref
                          .read(admissionsRepositoryProvider)
                          .cancelSession(session.id, reason: reason);
                      refreshAdmissions(ref);
                    },
                  ),
                  icon: const Icon(Icons.event_busy_rounded),
                  label: const Text('Darsni bekor qilish'),
                ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Yopish'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
