import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/application/session_controller.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/groups/presentation/groups_list_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/students/presentation/students_list_screen.dart';

GoRouter? globalRouter;

final appRouterProvider = Provider<GoRouter>((ref) {
  final session = ref.watch(sessionControllerProvider);

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: session,
    redirect: (context, state) {
      if (!session.isReady) {
        return null;
      }
      final isLoginRoute = state.matchedLocation == '/login';
      if (!session.isAuthenticated && !isLoginRoute) {
        return '/login';
      }
      if (session.isAuthenticated && isLoginRoute) {
        return '/';
      }
      return null;
    },
    routes: <RouteBase>[
      GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(path: '/groups', builder: (context, state) => const GroupsListScreen()),
      GoRoute(path: '/students', builder: (context, state) => const StudentsListScreen()),
    ],
  );
  globalRouter = router;
  return router;
});
