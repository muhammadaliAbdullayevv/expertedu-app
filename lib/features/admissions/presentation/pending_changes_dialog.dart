import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../../services/sync/outbox_store.dart';
import '../data/admissions_repository.dart';
import 'admissions_ui.dart';

/// Everything made offline that hasn't reached the server: waiting, or
/// refused (with the server's reason) until someone retries or drops it.
Future<void> showPendingChangesDialog(BuildContext context) {
  return showAdaptiveFormDialog<void>(
    context,
    maxWidth: 620,
    child: const _PendingChanges(),
  );
}

class _PendingChanges extends ConsumerStatefulWidget {
  const _PendingChanges();

  @override
  ConsumerState<_PendingChanges> createState() => _PendingChangesState();
}

class _PendingChangesState extends ConsumerState<_PendingChanges> {
  late Future<List<OutboxItem>> _items = _load();

  Future<List<OutboxItem>> _load() =>
      ref.read(admissionsRepositoryProvider).pendingChanges();

  Future<void> _act(Future<void> Function() action) async {
    await action();
    refreshAdmissions(ref);
    if (mounted) {
      setState(() {
        _items = _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.read(admissionsRepositoryProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const DialogHeader(
          title: 'Yuborilmagan o\'zgarishlar',
          subtitle:
              'Internet qaytganda tartib bilan yuboriladi. Har biri bir marta bajariladi.',
        ),
        Flexible(
          child: FutureBuilder<List<OutboxItem>>(
            future: _items,
            builder: (context, snapshot) {
              final items = snapshot.data;
              if (items == null) {
                return const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (items.isEmpty) {
                return const EmptyNote('Hammasi yuborilgan');
              }
              return ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                children: <Widget>[
                  for (final item in items)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        item.isFailed
                            ? Icons.error_outline_rounded
                            : Icons.schedule_rounded,
                        color: item.isFailed ? context.colors.error : null,
                      ),
                      title: Text(item.description ?? item.entity),
                      subtitle: Text(
                        item.isFailed
                            ? 'Server qabul qilmadi: ${item.lastError}'
                            : item.dependsOnSeq != null
                            ? 'Kutilmoqda (avvalgisi yuborilgach) · ${DateFormatters.dateTime(item.createdAt)}'
                            : 'Kutilmoqda · ${DateFormatters.dateTime(item.createdAt)}',
                        style: item.isFailed
                            ? TextStyle(color: context.colors.error)
                            : null,
                      ),
                      trailing: Wrap(
                        children: <Widget>[
                          if (item.isFailed)
                            IconButton(
                              tooltip: 'Qayta yuborish',
                              onPressed: () =>
                                  _act(() => repo.retryPending(item.seq)),
                              icon: const Icon(Icons.refresh_rounded),
                            ),
                          IconButton(
                            tooltip: 'Bekor qilish (unga bog\'liqlari ham)',
                            onPressed: () =>
                                _act(() => repo.discardPending(item.seq)),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}
