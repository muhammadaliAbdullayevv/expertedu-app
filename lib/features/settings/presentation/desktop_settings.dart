import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/currency_formatter.dart';
import '../../../core/formatters/phone_formatter.dart';
import '../../../core/widgets/table_card.dart';
import '../../auth/application/session_controller.dart';
import '../../groups/data/groups_repository.dart';
import '../../staff/presentation/staff_tab.dart';
import '../../groups/presentation/group_form_dialog.dart';
import '../../teachers/data/teachers_repository.dart';
import '../../teachers/presentation/teacher_form_dialog.dart';

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
    final isOwner = ref.watch(sessionControllerProvider).isOwner;
    return DefaultTabController(
      // Rebuilt from scratch if the tab count changes (another account).
      key: ValueKey<bool>(isOwner),
      length: isOwner ? 4 : 3,
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
                const Tab(text: 'O\'qituvchilar'),
                if (isOwner) const Tab(text: 'Xodimlar'),
                const Tab(text: 'Hisob'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                const _GroupsTab(),
                const _TeachersTab(),
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

  static const _columns = <TableColumn>[
    TableColumn('Guruh', flex: 3),
    TableColumn('Fan', flex: 2),
    TableColumn('O\'qituvchi', flex: 2),
    TableColumn('Oylik narx', flex: 2, alignEnd: true),
    TableColumn('To\'lov kuni', flex: 2, alignEnd: true),
    TableColumn('O\'quvchilar', flex: 2, alignEnd: true),
    TableColumn('', width: 56),
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
                3 => Text(CurrencyFormatter.format(group.feeAmount)),
                4 => Text('har oy ${group.dueDay}-sana'),
                5 => Text('${group.studentCount ?? 0}'),
                _ => IconButton(
                  tooltip: 'Tahrirlash',
                  onPressed: () => _openForm(group),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
              };
            },
          ),
        );
      },
    );
  }
}

class _TeachersTab extends ConsumerStatefulWidget {
  const _TeachersTab();

  @override
  ConsumerState<_TeachersTab> createState() => _TeachersTabState();
}

class _TeachersTabState extends ConsumerState<_TeachersTab> {
  late Future<List<Teacher>> _future = ref
      .read(teachersRepositoryProvider)
      .list();

  void _reload() {
    setState(() => _future = ref.read(teachersRepositoryProvider).list());
  }

  Future<void> _openForm([Teacher? teacher]) async {
    final saved = await showTeacherFormDialog(context, teacher: teacher);
    if (saved == true) _reload();
  }

  static const _columns = <TableColumn>[
    TableColumn('O\'qituvchi', flex: 3),
    TableColumn('Telefon', flex: 2),
    TableColumn('Guruhlar', flex: 1, alignEnd: true),
    TableColumn('Izoh', flex: 3),
    TableColumn('', width: 56),
  ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Teacher>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _LoadFailed(error: snapshot.error!, onRetry: _reload);
        }
        final teachers = snapshot.data!;
        return _AdminPage(
          toolbar: <Widget>[
            _muted(context, '${teachers.length} ta o\'qituvchi'),
            const Spacer(),
            FilledButton.icon(
              onPressed: _openForm,
              icon: const Icon(Icons.add),
              label: const Text('Yangi o\'qituvchi'),
            ),
          ],
          table: TableCard(
            columns: _columns,
            rowCount: teachers.length,
            emptyText: 'Hali o\'qituvchilar yo\'q',
            onRowTap: (row) => _openForm(teachers[row]),
            cell: (context, row, column) {
              final teacher = teachers[row];
              return switch (column) {
                0 => Text(
                  teacher.fullName,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                1 =>
                  teacher.phone == null
                      ? _muted(context, '—')
                      : Text(PhoneFormatter.display(teacher.phone!)),
                2 => Text('${teacher.groupCount ?? 0}'),
                3 => _muted(context, teacher.note ?? ''),
                _ => IconButton(
                  tooltip: 'Tahrirlash',
                  onPressed: () => _openForm(teacher),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
              };
            },
          ),
        );
      },
    );
  }
}
