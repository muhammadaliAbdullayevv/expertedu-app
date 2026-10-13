import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/thousands_input_formatter.dart';
import '../data/groups_repository.dart';

class GroupsListScreen extends ConsumerStatefulWidget {
  const GroupsListScreen({super.key});

  @override
  ConsumerState<GroupsListScreen> createState() => _GroupsListScreenState();
}

class _GroupsListScreenState extends ConsumerState<GroupsListScreen> {
  late Future<List<Group>> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(groupsRepositoryProvider).list();
  }

  void _reload() {
    setState(() => _future = ref.read(groupsRepositoryProvider).list());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Guruhlar')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateSheet(context),
        child: const Icon(Icons.add),
      ),
      body: FutureBuilder<List<Group>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Xatolik: ${snapshot.error}'));
          }
          final groups = snapshot.data ?? const <Group>[];
          if (groups.isEmpty) {
            return const Center(child: Text('Hali guruhlar yo\'q'));
          }
          return ListView.builder(
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final group = groups[index];
              return ListTile(
                title: Text(group.name),
                subtitle: Text('${CurrencyFormatter.format(group.feeAmount)} -- har oyning ${group.dueDay}-kuni'),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _showCreateSheet(BuildContext context) async {
    final nameController = TextEditingController();
    final feeController = TextEditingController();
    final dueDayController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text('Yangi guruh', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                TextFormField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Nomi'),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: feeController,
                  decoration: const InputDecoration(labelText: 'Oylik to\'lov (so\'m)'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [ThousandsInputFormatter()],
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Majburiy' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: dueDayController,
                  decoration: const InputDecoration(labelText: 'To\'lov kuni (1-31)'),
                  keyboardType: TextInputType.number,
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    if (n == null || n < 1 || n > 31) return '1 dan 31 gacha bo\'lishi kerak';
                    return null;
                  },
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    await ref.read(groupsRepositoryProvider).create(
                      name: nameController.text,
                      feeAmount: ThousandsInputFormatter.unformat(feeController.text) ?? 0,
                      dueDay: int.parse(dueDayController.text),
                    );
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
                  child: const Text('Yaratish'),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (created == true) {
      _reload();
    }
  }
}
