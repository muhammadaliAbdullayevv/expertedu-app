import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router/app_router.dart';
import 'app/theme/app_theme.dart';
import 'core/extensions/build_context_x.dart';
import 'core/widgets/update_banner.dart';
import 'services/updates/app_update_controller.dart';

void main() {
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    ref.watch(appUpdateControllerProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => context.strings.appName,
      theme: AppTheme.light(),
      routerConfig: router,
      builder: (context, child) => Column(
        children: <Widget>[
          const UpdateBanner(),
          Expanded(child: child ?? const SizedBox.shrink()),
        ],
      ),
    );
  }
}
