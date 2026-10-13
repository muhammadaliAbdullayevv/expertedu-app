import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/presentation/settings_screen.dart';
import '../../stats/presentation/stats_screen.dart';
import '../../students/presentation/students_list_screen.dart';
import '../../subjects/presentation/subjects_list_screen.dart';
import 'dashboard_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _currentIndex = 0;

  final _dashboardKey = GlobalKey<DashboardScreenState>();
  final _subjectsKey = GlobalKey<SubjectsListScreenState>();
  final _studentsKey = GlobalKey<StudentsListScreenState>();

  late final List<Widget> _pages = <Widget>[
    DashboardScreen(key: _dashboardKey),
    SubjectsListScreen(key: _subjectsKey),
    StudentsListScreen(key: _studentsKey),
    const StatsScreen(),
    const SettingsScreen(),
  ];

  static const _titles = <String>[
    'Bosh sahifa',
    'Fanlar',
    'O\'quvchilar',
    'Statistika',
    'Sozlamalar',
  ];

  // Only the tabs with their own searchable list show the search icon --
  // Home/Stats/Settings don't have one to search.
  bool get _currentTabHasSearch => _currentIndex == 1 || _currentIndex == 2;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBackPressed();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_titles[_currentIndex]),
          // A visible bottom border instead of just elevation -- also
          // where a notification bell will sit once that exists, next to
          // the search icon below.
          shape: Border(
            bottom: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          actions: <Widget>[
            if (_currentTabHasSearch)
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () {
                  if (_currentIndex == 1) {
                    _subjectsKey.currentState?.toggleSearch();
                  } else {
                    _studentsKey.currentState?.toggleSearch();
                  }
                },
              ),
          ],
        ),
        body: SafeArea(
          top: false,
          bottom: false,
          child: IndexedStack(index: _currentIndex, children: _pages),
        ),
        floatingActionButton: (_currentIndex == 1 || _currentIndex == 2)
            ? FloatingActionButton(
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  if (_currentIndex == 1) {
                    _subjectsKey.currentState?.showCreateSheet();
                  } else {
                    _studentsKey.currentState?.showCreateSheet();
                  }
                },
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(30),
            child: NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (int index) {
                if (index != _currentIndex) {
                  HapticFeedback.selectionClick();
                }
                setState(() => _currentIndex = index);
              },
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: 'Bosh sahifa',
                ),
                NavigationDestination(
                  icon: Icon(Icons.menu_book_outlined),
                  selectedIcon: Icon(Icons.menu_book_rounded),
                  label: 'Fanlar',
                ),
                NavigationDestination(
                  icon: Icon(Icons.school_outlined),
                  selectedIcon: Icon(Icons.school_rounded),
                  label: 'O\'quvchilar',
                ),
                NavigationDestination(
                  icon: Icon(Icons.query_stats_outlined),
                  selectedIcon: Icon(Icons.query_stats_rounded),
                  label: 'Statistika',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: 'Sozlamalar',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handleBackPressed() {
    final cleared = switch (_currentIndex) {
      0 => _dashboardKey.currentState?.clearSearchIfActive() ?? false,
      1 => _subjectsKey.currentState?.clearSearchIfActive() ?? false,
      2 => _studentsKey.currentState?.clearSearchIfActive() ?? false,
      _ => false,
    };
    if (cleared) return;

    if (_currentIndex != 0) {
      setState(() => _currentIndex = 0);
      return;
    }
    SystemNavigator.pop();
  }
}
