import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/widgets/table_card.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/data/groups_repository.dart';
import '../../staff/presentation/staff_tab.dart';
import '../../timetable/data/timetable_models.dart';
import '../../timetable/presentation/group_schedule_dialog.dart';
import '../../groups/presentation/group_form_dialog.dart';

/// Settings on the wide layout: the center's groups and teachers are
/// managed here (desktop only -- the phone app adds groups from inside a
/// subject), staff accounts for the owner, and the account options the
/// phone also has.
class DesktopSettings extends ConsumerWidget {
  const DesktopSettings({super.key, required this.account});

  /// The phone's settings list, reused as the last tab.
  final Widget account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The session is a ChangeNotifier behind a plain Provider: listen to it,
    // so the owner's tabs appear once it knows who's signed in.
    final session = ref.watch(sessionControllerProvider);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => _tabs(context, isOwner: session.isOwner),
    );
  }

  Widget _tabs(BuildContext context, {required bool isOwner}) {
    return DefaultTabController(
      // Rebuilt from scratch if the tab count changes (another account).
      key: ValueKey<bool>(isOwner),
      length: isOwner ? 3 : 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              color: context.colors.surface,
              border: Border(
                bottom: BorderSide(color: context.colors.outlineVariant),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              dividerHeight: 0,
              indicatorColor: AppColors.accent,
              indicatorWeight: 3,
              labelColor: context.colors.onSurface,
              unselectedLabelColor: context.colors.onSurfaceVariant,
              labelStyle: context.textTheme.labelLarge,
              tabs: <Tab>[
                const Tab(text: 'Guruhlar'),
                if (isOwner) const Tab(text: 'Xodimlar'),
                const Tab(text: 'Hisob'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                const _GroupsTab(),
                if (isOwner) const StaffTab(),
                Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: account,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Toolbar + table, centered at a readable width on very wide screens.
class _AdminPage extends StatelessWidget {
  const _AdminPage({required this.toolbar, required this.table});

  final List<Widget> toolbar;
  final Widget table;

  static const double _maxContentWidth = 1400;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.max(
          24.0,
          (constraints.maxWidth - _maxContentWidth) / 2,
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(side, 20, side, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(children: toolbar),
              const SizedBox(height: 16),
              Expanded(child: table),
            ],
          ),
        );
      },
    );
  }
}

class _LoadFailed extends StatelessWidget {
  const _LoadFailed({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('Ma\'lumotlarni yuklab bo\'lmadi: $error'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Qayta urinish'),
          ),
        ],
      ),
    );
  }
}

Widget _muted(BuildContext context, String text) => Text(
  text,
  overflow: TextOverflow.ellipsis,
  style: context.textTheme.bodyMedium?.copyWith(
    color: context.colors.onSurfaceVariant,
  ),
);

class _GroupsTab extends ConsumerStatefulWidget {
  const _GroupsTab();

  @override
  ConsumerState<_GroupsTab> createState() => _GroupsTabState();
}

class _GroupsTabState extends ConsumerState<_GroupsTab> {
  late Future<List<Group>> _future = ref.read(groupsRepositoryProvider).list();
  String _query = '';

  void _reload() {
    setState(() => _future = ref.read(groupsRepositoryProvider).list());
  }

  Future<void> _openForm([Group? group]) async {
    final saved = await showGroupFormDialog(context, group: group);
    if (saved == true) _reload();
  }

  Future<void> _openSchedule(Group group) async {
    final saved = await showGroupScheduleDialog(context, group);
    if (saved == true) _reload();
  }

  static const _columns = <TableColumn>[
    TableColumn('Guruh', flex: 3),
    TableColumn('Fan', flex: 2),
    TableColumn('O\'qituvchi', flex: 2),
    TableColumn('Dars jadvali', flex: 3),
    TableColumn('Oylik narx', flex: 2, alignEnd: true),
    TableColumn('To\'lov kuni', flex: 2, alignEnd: true),
    TableColumn('O\'quvchilar', flex: 2, alignEnd: true),
    TableColumn('', width: 96),
  ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Group>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _LoadFailed(error: snapshot.error!, onRetry: _reload);
        }
        final query = _query.trim().toLowerCase();
        final groups = snapshot.data!.where((g) {
          if (query.isEmpty) return true;
          return <String?>[
            g.name,
            g.subjectName,
            g.teacherName,
          ].any((field) => field?.toLowerCase().contains(query) ?? false);
        }).toList();

        return _AdminPage(
          toolbar: <Widget>[
            SizedBox(
              width: 300,
              child: TextField(
                onChanged: (value) => setState(() => _query = value),
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Guruh, fan yoki o\'qituvchi',
                ),
              ),
            ),
            const SizedBox(width: 16),
            _muted(context, '${groups.length} ta guruh'),
            const Spacer(),
            FilledButton.icon(
              onPressed: _openForm,
              icon: const Icon(Icons.add),
              label: const Text('Yangi guruh'),
            ),
          ],
          table: TableCard(
            columns: _columns,
            rowCount: groups.length,
            emptyText: snapshot.data!.isEmpty
                ? 'Hali guruhlar yo\'q'
                : 'Mos keladigan guruh topilmadi',
            onRowTap: (row) => _openForm(groups[row]),
            cell: (context, row, column) {
              final group = groups[row];
              return switch (column) {
                0 => Text(
                  group.name,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                1 => Text(group.subjectName ?? '—'),
                2 =>
                  group.teacherName == null
                      ? _muted(context, 'Tanlanmagan')
                      : Text(
                          group.teacherName!,
                          overflow: TextOverflow.ellipsis,
                        ),
                3 => Tooltip(
                  message: 'Dars jadvalini o\'zgartirish',
                  child: InkWell(
                    onTap: () => _openSchedule(group),
                    child: group.schedule.isEmpty
                        ? Text(
                            'Jadval qo\'shish',
                            style: TextStyle(color: context.colors.primary),
                          )
                        : Text(
                            scheduleSummary(group.schedule),
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ),
                4 => Text(CurrencyFormatter.format(group.feeAmount)),
                5 => Text(
                  group.isAnniversary
                      ? 'o\'quvchining kuni'
                      : 'har oy ${group.billingDay}-sana',
                ),
                6 => Text('${group.studentCount ?? 0}'),
                _ => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: 'Dars jadvali',
                      onPressed: () => _openSchedule(group),
                      icon: const Icon(Icons.calendar_month_outlined, size: 20),
                    ),
                    IconButton(
                      tooltip: 'Tahrirlash',
                      onPressed: () => _openForm(group),
                      icon: const Icon(Icons.edit_outlined, size: 20),
                    ),
                  ],
                ),
              };
            },
          ),
        );
      },
    );
  }
}
