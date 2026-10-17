import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../services/sync/sync_engine.dart';
import '../../admissions/presentation/admissions_screen.dart';
import '../../debtors/presentation/debtors_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../stats/presentation/stats_screen.dart';
import '../../students/presentation/students_list_screen.dart';
import '../../subjects/presentation/subjects_list_screen.dart';
import 'dashboard_screen.dart';
import 'desktop_sidebar.dart';

enum _Tab {
  home(Icons.home_outlined, Icons.home_rounded, 'Bosh sahifa'),
  admissions(
    Icons.how_to_reg_outlined,
    Icons.how_to_reg_rounded,
    'Qabul',
    desktopOnly: true,
  ),
  subjects(Icons.menu_book_outlined, Icons.menu_book_rounded, 'Fanlar'),
  students(Icons.school_outlined, Icons.school_rounded, 'O\'quvchilar'),
  debtors(
    Icons.account_balance_wallet_outlined,
    Icons.account_balance_wallet_rounded,
    'Qarzdorlar',
    desktopOnly: true,
  ),
  stats(Icons.query_stats_outlined, Icons.query_stats_rounded, 'Statistika'),
  settings(Icons.settings_outlined, Icons.settings_rounded, 'Sozlamalar');

  const _Tab(
    this.icon,
    this.selectedIcon,
    this.label, {
    this.desktopOnly = false,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;

  /// Only reachable from the wide layout's side rail -- the phone app keeps
  /// its five tabs.
  final bool desktopOnly;
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// Wide enough to spare the sidebar's extended width for labels beside
  /// the icons (and a labelled action button) instead of under them.
  static const double _extendedRailBreakpoint = 1200;

  _Tab _currentTab = _Tab.home;

  @override
  void initState() {
    super.initState();
    // Signed in from here on: send anything queued offline (this or an
    // earlier run), and keep sending as connectivity comes and goes.
    ref.read(syncEngineProvider).start();
  }

  final _dashboardKey = GlobalKey<DashboardScreenState>();
  final _subjectsKey = GlobalKey<SubjectsListScreenState>();
  final _studentsKey = GlobalKey<StudentsListScreenState>();
  final _debtorsKey = GlobalKey<DebtorsScreenState>();
  final _admissionsKey = GlobalKey<AdmissionsScreenState>();

  // Resizing a desktop window across the wide-layout breakpoint moves the
  // content Scaffold to a different spot in the tree -- this key carries it
  // (and every tab's state, scroll position and open search) along instead
  // of rebuilding it from scratch.
  final _contentKey = GlobalKey();

  // Desktop pages are kept by tab rather than by index, so the IndexedStack
  // below can always hold one child per tab in a fixed order.
  late final Map<_Tab, Widget> _pages = <_Tab, Widget>{
    _Tab.home: DashboardScreen(
      key: _dashboardKey,
      onOpenDebtors: () => _selectTab(_Tab.debtors),
      onOpenAdmissions: () => _selectTab(_Tab.admissions),
    ),
    _Tab.admissions: AdmissionsScreen(key: _admissionsKey),
    _Tab.subjects: SubjectsListScreen(key: _subjectsKey),
    _Tab.students: StudentsListScreen(key: _studentsKey),
    _Tab.debtors: DebtorsScreen(key: _debtorsKey),
    _Tab.stats: const StatsScreen(),
    _Tab.settings: const SettingsScreen(),
  };

  // Only the tabs with their own searchable list show the search icon --
  // the rest don't have one to search.
  static bool _hasSearch(_Tab tab) =>
      tab == _Tab.subjects || tab == _Tab.students;

  // Home/Subjects/Students each have something to create; the rest don't,
  // so they get no create button at all.
  static bool _hasCreate(_Tab tab) =>
      tab == _Tab.home || tab == _Tab.subjects || tab == _Tab.students;

  static IconData _createIcon(_Tab tab) =>
      tab == _Tab.home ? Icons.add_call : Icons.add;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final useRail = width >= kWideLayoutBreakpoint;
    final tabs = _Tab.values.where((t) => useRail || !t.desktopOnly).toList();
    // Shrinking the window to the phone layout while on a desktop-only tab
    // falls back to Home rather than showing a tab the bottom bar lacks.
    final tab = tabs.contains(_currentTab) ? _currentTab : _Tab.home;

    final content = Scaffold(
      key: _contentKey,
      appBar: AppBar(
        title: Text(tab.label),
        // A visible bottom border instead of just elevation -- also
        // where a notification bell will sit once that exists, next to
        // the search icon below.
        shape: Border(
          bottom: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        actions: <Widget>[
          if (_hasSearch(tab))
            IconButton(
              icon: const Icon(Icons.search),
              onPressed: () {
                if (tab == _Tab.subjects) {
                  _subjectsKey.currentState?.toggleSearch();
                } else {
                  _studentsKey.currentState?.toggleSearch();
                }
              },
            ),
          // On the phone the FAB creates a subject; the desktop has one
          // fixed sidebar action (new student), so subjects get their own.
          if (useRail && tab == _Tab.subjects)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: OutlinedButton.icon(
                onPressed: () => _subjectsKey.currentState?.showCreateSheet(),
                icon: const Icon(Icons.add),
                label: const Text('Yangi fan'),
              ),
            ),
          // Pull-to-refresh needs a touch drag -- a mouse can't do it, so
          // the desktop's own screens get an explicit button instead.
          if (useRail &&
              (tab == _Tab.home ||
                  tab == _Tab.debtors ||
                  tab == _Tab.admissions))
            IconButton(
              tooltip: tab == _Tab.admissions ? 'Yangilash (F5)' : 'Yangilash',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => switch (tab) {
                _Tab.home => _dashboardKey.currentState?.reload(),
                _Tab.admissions => _admissionsKey.currentState?.reload(),
                _ => _debtorsKey.currentState?.reload(),
              },
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: IndexedStack(
          index: _Tab.values.indexOf(tab),
          children: <Widget>[
            for (final t in _Tab.values)
              // A desktop-only page isn't built at all on the phone layout,
              // so it never loads data there.
              if (t.desktopOnly && !useRail)
                const SizedBox.shrink()
              else
                _pages[t]!,
          ],
        ),
      ),
      floatingActionButton: !useRail && _hasCreate(tab)
          ? FloatingActionButton(
              onPressed: () => _onCreatePressed(tab),
              child: Icon(_createIcon(tab)),
            )
          : null,
      bottomNavigationBar: useRail ? null : _buildBottomBar(tabs, tab),
    );

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackPressed(tab);
      },
      // No Scaffold around the sidebar layout -- the content Scaffold has to
      // stay the root one, or SnackBars would stretch under the sidebar too.
      child: useRail
          ? Material(
              child: Row(
                children: <Widget>[
                  DesktopSidebar(
                    items: <SidebarItem>[
                      for (final t in tabs)
                        (
                          icon: t.icon,
                          selectedIcon: t.selectedIcon,
                          label: t.label,
                        ),
                    ],
                    selectedIndex: tabs.indexOf(tab),
                    onSelect: (index) => _selectTab(tabs[index]),
                    extended: width >= _extendedRailBreakpoint,
                    // The desktop's one main action, the same on every tab:
                    // calls are logged from the phone app, students here.
                    actionLabel: 'Yangi o\'quvchi',
                    actionIcon: Icons.person_add_alt_1_rounded,
                    onAction: () =>
                        _studentsKey.currentState?.showCreateSheet(),
                  ),
                  Expanded(child: content),
                ],
              ),
            )
          : content,
    );
  }

  Widget _buildBottomBar(List<_Tab> tabs, _Tab current) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: NavigationBar(
          selectedIndex: tabs.indexOf(current),
          onDestinationSelected: (index) => _selectTab(tabs[index]),
          destinations: <NavigationDestination>[
            for (final tab in tabs)
              NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.label,
              ),
          ],
        ),
      ),
    );
  }

  void _selectTab(_Tab tab) {
    if (tab != _currentTab) {
      HapticFeedback.selectionClick();
    }
    setState(() => _currentTab = tab);
  }

  void _onCreatePressed(_Tab tab) {
    HapticFeedback.mediumImpact();
    switch (tab) {
      case _Tab.home:
        _dashboardKey.currentState?.showCreateSheet();
      case _Tab.subjects:
        _subjectsKey.currentState?.showCreateSheet();
      case _Tab.students:
        _studentsKey.currentState?.showCreateSheet();
      default:
        break;
    }
  }

  void _handleBackPressed(_Tab tab) {
    final cleared = switch (tab) {
      _Tab.home => _dashboardKey.currentState?.clearSearchIfActive() ?? false,
      _Tab.subjects =>
        _subjectsKey.currentState?.clearSearchIfActive() ?? false,
      _Tab.students =>
        _studentsKey.currentState?.clearSearchIfActive() ?? false,
      _ => false,
    };
    if (cleared) return;

    if (tab != _Tab.home) {
      setState(() => _currentTab = _Tab.home);
      return;
    }
    SystemNavigator.pop();
  }
}
