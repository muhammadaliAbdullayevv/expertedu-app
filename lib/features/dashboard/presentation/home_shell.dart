import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../groups/presentation/groups_list_screen.dart';
import '../../settings/presentation/settings_screen.dart';
import '../../stats/presentation/stats_screen.dart';
import '../../students/presentation/students_list_screen.dart';
import 'dashboard_screen.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _currentIndex = 0;

  final _dashboardKey = GlobalKey<DashboardScreenState>();
  final _groupsKey = GlobalKey<GroupsListScreenState>();
  final _studentsKey = GlobalKey<StudentsListScreenState>();

  late final List<Widget> _pages = <Widget>[
    DashboardScreen(key: _dashboardKey),
    GroupsListScreen(key: _groupsKey),
    StudentsListScreen(key: _studentsKey),
    const StatsScreen(),
    const SettingsScreen(),
  ];

  static const _titles = <String>['Bosh sahifa', 'Guruhlar', 'O\'quvchilar', 'Statistika', 'Sozlamalar'];

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
                    _groupsKey.currentState?.showCreateSheet();
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
                  icon: Icon(Icons.groups_outlined),
                  selectedIcon: Icon(Icons.groups_rounded),
                  label: 'Guruhlar',
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
