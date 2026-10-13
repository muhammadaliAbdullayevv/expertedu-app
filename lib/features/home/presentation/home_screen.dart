import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../auth/application/session_controller.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.strings.appName),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(sessionControllerProvider).signOut(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text('Salom, ${session.user?.fullName ?? ''}', style: context.textTheme.titleMedium),
          const SizedBox(height: 16),
          Card(
            child: ListTile(
              leading: const Icon(Icons.groups),
              title: const Text('Guruhlar'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/groups'),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.school),
              title: const Text('O\'quvchilar'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/students'),
            ),
          ),
        ],
      ),
    );
  }
}
