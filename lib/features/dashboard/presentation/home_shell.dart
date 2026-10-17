import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation/destinations.dart';
import '../../../app/shell/app_sidebar.dart';
import '../../../app/shell/command_palette.dart';
import '../../../app/shell/phone_bottom_bar.dart';
import '../../../app/shell/receive_payment_flow.dart';
import '../../../app/shell/shell_counts.dart';
import '../../../app/shell/top_bar.dart';
import '../../../app/theme/app_theme.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../l10n/app_strings.dart';
import '../../../services/sync/sync_engine.dart';
import '../../admissions/presentation/admissions_screen.dart';
import '../../auth/application/session_controller.dart';
import '../../debtors/presentation/debtors_screen.dart';
import '../../finance/presentation/finance_screen.dart';
import '../../settings/presentation/desktop_settings.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../stats/presentation/stats_screen.dart';
import '../../students/data/students_repository.dart';
import '../../students/presentation/students_list_screen.dart';
import '../../subjects/presentation/subjects_list_screen.dart';
import '../../timetable/presentation/timetable_screen.dart';
import 'dashboard_screen.dart';

/// The signed-in app: the V2 navigation around the screens. A sidebar, a
/// top bar with the command bar (Ctrl K) and "+ Yangi" on wide windows; a
/// bottom bar with the payment button on the phone. What the menu offers
/// follows the signed-in role (see app/navigation/destinations.dart).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  static const _s = AppStrings.current;

  /// Below this the sidebar shrinks to an icon rail.
  static const double _fullSidebarBreakpoint = 1100;

  static bool get _isDesktopPlatform =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  Destination _current = Destination.today;
  DateTime _countsFetchedAt = DateTime.now();

  late final SessionController _session = ref.read(sessionControllerProvider);

  AppRole get _role => AppRole.parse(_session.user?.role);

  @override
  void initState() {
    super.initState();
    // Signed in from here on: send anything queued offline (this or an
    // earlier run), and keep sending as connectivity comes and goes.
    ref.read(syncEngineProvider).start();
    // The menu follows who's signed in.
    _session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  final _dashboardKey = GlobalKey<DashboardScreenState>();
  final _subjectsKey = GlobalKey<SubjectsListScreenState>();
  final _studentsKey = GlobalKey<StudentsListScreenState>();
  final _debtorsKey = GlobalKey<DebtorsScreenState>();
  final _admissionsKey = GlobalKey<AdmissionsScreenState>();
  final _timetableKey = GlobalKey<TimetableScreenState>();
  final _financeKey = GlobalKey<FinanceScreenState>();

  // Resizing a desktop window across the wide-layout breakpoint moves the
  // content Scaffold to a different spot in the tree -- this key carries it
  // (and every page's state, scroll position and open search) along
  // instead of rebuilding it from scratch.
  final _contentKey = GlobalKey();

  late final Map<Destination, Widget> _pages = <Destination, Widget>{
    Destination.today: DashboardScreen(
      key: _dashboardKey,
      onOpenDebtors: () => _go(Destination.debtors),
      onOpenAdmissions: () => _go(Destination.admissions),
    ),
    Destination.admissions: AdmissionsScreen(key: _admissionsKey),
    Destination.students: StudentsListScreen(key: _studentsKey),
    Destination.timetable: TimetableScreen(key: _timetableKey),
    Destination.groups: SubjectsListScreen(key: _subjectsKey),
    Destination.teachers: const TeachersTab(),
    Destination.finance: FinanceScreen(key: _financeKey),
    Destination.reports: const StatsScreen(),
    Destination.settings: const SettingsScreen(),
    Destination.debtors: DebtorsScreen(key: _debtorsKey),
  };

  bool _hasSearch(Destination d) =>
      d == Destination.groups || d == Destination.students;

  bool _hasRefresh(Destination d) => switch (d) {
    Destination.today ||
    Destination.debtors ||
    Destination.admissions ||
    Destination.timetable ||
    Destination.finance => true,
    _ => false,
  };

  void _refresh(Destination d) {
    switch (d) {
      case Destination.today:
        _dashboardKey.currentState?.reload();
      case Destination.admissions:
        _admissionsKey.currentState?.reload();
      case Destination.timetable:
        _timetableKey.currentState?.reload();
      case Destination.finance:
        _financeKey.currentState?.reload();
      case Destination.debtors:
        _debtorsKey.currentState?.reload();
      default:
        break;
    }
    ref.invalidate(shellCountsProvider);
  }

  String _title(Destination d) => d.label(_s);

  String? _subtitle(Destination d) =>
      d == Destination.today ? uzLongDate(DateTime.now()) : null;

  // --- Navigation ---------------------------------------------------------

  void _go(Destination destination) {
    if (!destination.allowedFor(_role)) return;
    if (destination != _current) HapticFeedback.selectionClick();
    setState(() => _current = destination);
    // Keep the sidebar numbers fresh without asking on every click.
    if (DateTime.now().difference(_countsFetchedAt) > const Duration(minutes: 1)) {
      _countsFetchedAt = DateTime.now();
      ref.invalidate(shellCountsProvider);
    }
  }

  Future<void> _receivePayment() async {
    HapticFeedback.mediumImpact();
    final recorded = await showReceivePayment(context, ref);
    if (recorded && mounted) {
      _dashboardKey.currentState?.reload();
      _debtorsKey.currentState?.reload();
      ref.invalidate(shellCountsProvider);
    }
  }

  void _newLead() {
    _go(Destination.admissions);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _admissionsKey.currentState?.newInquiry(),
    );
  }

  void _newStudent() {
    _go(Destination.students);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _studentsKey.currentState?.showCreateSheet(),
    );
  }

  List<NewMenuItem> get _newMenu => [
    if (_role != AppRole.teacher) ...[
      NewMenuItem(_s.receivePayment, Icons.payments_outlined, _receivePayment),
      NewMenuItem(_s.newLead, Icons.phone_in_talk_outlined, _newLead),
      NewMenuItem(_s.newStudent, Icons.person_add_alt_1_outlined, _newStudent),
    ],
  ];

  // --- Command bar --------------------------------------------------------

  List<PaletteEntry> get _paletteEntries => [
    if (_role != AppRole.teacher) ...[
      PaletteEntry(
        group: _s.commandSectionActions,
        label: _s.receivePayment,
        icon: Icons.payments_outlined,
        keywords: const ['kassa', 'pul', 'summa'],
        run: _receivePayment,
      ),
      PaletteEntry(
        group: _s.commandSectionActions,
        label: _s.newLead,
        icon: Icons.phone_in_talk_outlined,
        keywords: const ['qo\'ng\'iroq', 'lid'],
        run: _newLead,
      ),
      PaletteEntry(
        group: _s.commandSectionActions,
        label: _s.newStudent,
        icon: Icons.person_add_alt_1_outlined,
        run: _newStudent,
      ),
    ],
    for (final d in reachableFor(_role))
      PaletteEntry(
        group: _s.commandSectionGoTo,
        label: d.label(_s),
        icon: d.icon,
        run: () => _go(d),
      ),
  ];

  Future<List<PaletteEntry>> _searchStudents(String query) async {
    if (_role == AppRole.teacher) return const [];
    final found = await ref.read(studentsRepositoryProvider).list(query: query);
    return [
      for (final Student student in found.take(6))
        PaletteEntry(
          group: _s.commandSectionStudents,
          label: student.fullName,
          subtitle: PhoneFormatter.display(student.phone),
          icon: Icons.person_outline_rounded,
          run: () {
            _go(Destination.students);
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _studentsKey.currentState?.applySearch(student.fullName),
            );
          },
        ),
    ];
  }

  void _openCommandBar() {
    showCommandPalette(
      context,
      entries: _paletteEntries,
      searchRemote: _searchStudents,
    );
  }

  // --- Layout -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    // Desktop builds always use the desktop layout (a narrow window gets the
    // icon rail); the phone layout is only for phones, which aren't being
    // built yet.
    final wide = _isDesktopPlatform || width >= kWideLayoutBreakpoint;
    final role = _role;
    // A role change (or a stale tab) never leaves a page on screen the
    // signed-in role may not see.
    final current = _current.allowedFor(role) ? _current : Destination.today;
    final counts = ref.watch(shellCountsProvider).value ?? const {};

    // A page the role may not open isn't built at all, so it never loads
    // data (or shows it); neither is one with no phone layout yet, on a phone.
    bool built(Destination d) => d.allowedFor(role) && (wide || d.phoneReady);
    final body = SafeArea(
      top: false,
      bottom: false,
      child: Stack(
        children: <Widget>[
          IndexedStack(
            index: Destination.values.indexOf(current),
            children: <Widget>[
              for (final d in Destination.values)
                if (built(d)) _pages[d]! else const SizedBox.shrink(),
            ],
          ),
          if (!built(current)) const Positioned.fill(child: _PhoneNotReady()),
        ],
      ),
    );

    final Widget content = wide
        ? Scaffold(
            key: _contentKey,
            body: Column(
              children: <Widget>[
                AppTopBar(
                  onOpenCommandBar: _openCommandBar,
                  newMenuItems: _newMenu,
                ),
                _PageHeader(
                  title: _title(current),
                  subtitle: _subtitle(current),
                  onRefresh: _hasRefresh(current) ? () => _refresh(current) : null,
                ),
                Expanded(child: body),
              ],
            ),
          )
        : Scaffold(
            key: _contentKey,
            appBar: AppBar(
              title: Text(_title(current)),
              shape: const Border(bottom: BorderSide(color: AppColors.border)),
              actions: <Widget>[
                if (_hasSearch(current))
                  IconButton(
                    tooltip: _s.commandBarHint,
                    icon: const Icon(Icons.search_rounded),
                    onPressed: () => current == Destination.groups
                        ? _subjectsKey.currentState?.toggleSearch()
                        : _studentsKey.currentState?.toggleSearch(),
                  ),
                IconButton(
                  tooltip: _s.navMore,
                  icon: const Icon(Icons.apps_rounded),
                  onPressed: () => _showMoreSheet(context),
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: body,
            bottomNavigationBar: PhoneBottomBar(
              layout: phoneBarFor(role),
              selected: current,
              onSelect: _go,
              onPayment: _receivePayment,
            ),
          );

    final shell = wide
        ? Material(
            color: AppColors.canvas,
            child: Row(
              children: <Widget>[
                AppSidebar(
                  role: role,
                  selected: current,
                  onSelect: _go,
                  counts: counts,
                  compact: width < _fullSidebarBreakpoint,
                  userName: _session.user?.fullName ?? '',
                  onUserTap: () => _go(Destination.settings),
                ),
                Expanded(child: content),
              ],
            ),
          )
        : content;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackPressed(current);
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _openCommandBar,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
              _openCommandBar,
        },
        child: Focus(autofocus: true, child: shell),
      ),
    );
  }

  /// The phone's way to the destinations its bottom bar has no room for.
  void _showMoreSheet(BuildContext context) {
    final inBar = phoneBarFor(_role).all.toSet();
    final others = [
      for (final d in menuFor(_role))
        if (!inBar.contains(d)) d,
    ];
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 8),
            for (final d in others)
              ListTile(
                leading: Icon(d.icon),
                title: Text(d.label(_s)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _go(d);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _handleBackPressed(Destination current) {
    final cleared = switch (current) {
      Destination.today =>
        _dashboardKey.currentState?.clearSearchIfActive() ?? false,
      Destination.groups =>
        _subjectsKey.currentState?.clearSearchIfActive() ?? false,
      Destination.students =>
        _studentsKey.currentState?.clearSearchIfActive() ?? false,
      _ => false,
    };
    if (cleared) return;
    if (current != Destination.today) {
      setState(() => _current = Destination.today);
      return;
    }
    SystemNavigator.pop();
  }
}

/// "Shanba, 17-oktyabr" -- the weekday and date in Uzbek.
String uzLongDate(DateTime date) {
  const weekdays = [
    'Dushanba',
    'Seshanba',
    'Chorshanba',
    'Payshanba',
    'Juma',
    'Shanba',
    'Yakshanba',
  ];
  const months = [
    'yanvar',
    'fevral',
    'mart',
    'aprel',
    'may',
    'iyun',
    'iyul',
    'avgust',
    'sentyabr',
    'oktyabr',
    'noyabr',
    'dekabr',
  ];
  return '${weekdays[date.weekday - 1]}, ${date.day}-${months[date.month - 1]}';
}

/// Stands in for a screen that has no phone layout yet.
class _PhoneNotReady extends StatelessWidget {
  const _PhoneNotReady();

  @override
  Widget build(BuildContext context) {
    const s = AppStrings.current;
    return ColoredBox(
      color: AppColors.canvas,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.desktop_windows_outlined, size: 40, color: AppColors.inkMuted),
              const SizedBox(height: 16),
              Text(
                s.phoneNotReadyTitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                s.phoneNotReadyBody,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.inkMuted, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The page title under the top bar, the same on every wide page until a
/// page brings its own header.
class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, this.subtitle, this.onRefresh});

  final String title;
  final String? subtitle;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.56,
                    height: 1.15,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppColors.inkMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (onRefresh != null)
            IconButton(
              tooltip: AppStrings.current.refresh,
              icon: const Icon(Icons.refresh_rounded),
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}
