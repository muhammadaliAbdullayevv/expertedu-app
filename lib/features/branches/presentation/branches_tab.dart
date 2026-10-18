import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../core/widgets/table_card.dart';
import '../../../services/api/api_client.dart';
import '../../admissions/presentation/admissions_ui.dart';
import '../application/branch_view.dart';
import '../data/branches_repository.dart';

/// Settings' "Filiallar" tab (owner only): Bosh ofis and the filiallar. Adding
/// one gives the owner a new branch to look at and to put an admin in
/// (Xodimlar); rename one; switch one off (never the headquarters).
class BranchesTab extends ConsumerStatefulWidget {
  const BranchesTab({super.key});

  @override
  ConsumerState<BranchesTab> createState() => _BranchesTabState();
}

class _BranchesTabState extends ConsumerState<BranchesTab> {
  late Future<List<Branch>> _future = ref
      .read(branchesRepositoryProvider)
      .list();

  void _reload() {
    final next = ref.read(branchesRepositoryProvider).list();
    setState(() {
      _future = next;
    });
    // The sidebar's switcher and every "Filial" choice follow.
    ref.invalidate(branchListProvider);
  }

  Future<void> _edit([Branch? branch]) async {
    final saved = await showAdaptiveFormDialog<bool>(
      context,
      maxWidth: 440,
      child: _BranchForm(branch: branch),
    );
    if (saved == true) _reload();
  }

  Future<void> _toggle(Branch b) async {
    try {
      await ref
          .read(branchesRepositoryProvider)
          .update(b.id, isActive: !b.isActive);
      _reload();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  static const _columns = <TableColumn>[
    TableColumn('Filial', flex: 3),
    TableColumn('Holat', flex: 1),
    TableColumn('', width: 120),
  ];

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Branch>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadFailed(error: snapshot.error!, onRetry: _reload);
        }
        final branches = snapshot.data;
        if (branches == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Har bir filialning guruhlari, o\'quvchilari, to\'lovlari va '
                      'so\'rovlari alohida. Adminni filialga Xodimlar bo\'limida biriktirasiz.',
                      style: TextStyle(color: AppColors.inkSecondary),
                    ),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('new-branch'),
                    onPressed: _edit,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Yangi filial'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: TableCard(
                  columns: _columns,
                  rowCount: branches.length,
                  onRowTap: (row) => _edit(branches[row]),
                  cell: (context, row, column) {
                    final b = branches[row];
                    return switch (column) {
                      0 => Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              b.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (b.isHeadquarters) ...<Widget>[
                            const SizedBox(width: 8),
                            const StatusChip(
                              'Bosh ofis',
                              tone: StatusTone.info,
                            ),
                          ],
                        ],
                      ),
                      1 => Text(
                        b.isActive ? 'Faol' : 'O\'chirilgan',
                        style: TextStyle(
                          color: b.isActive
                              ? AppColors.inkMuted
                              : AppColors.dangerText,
                        ),
                      ),
                      _ => Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          IconButton(
                            tooltip: 'Nomini o\'zgartirish',
                            onPressed: () => _edit(b),
                            icon: const Icon(Icons.edit_outlined, size: 20),
                          ),
                          if (!b.isHeadquarters)
                            IconButton(
                              key: ValueKey('toggle-branch-${b.id}'),
                              tooltip: b.isActive
                                  ? 'O\'chirish'
                                  : 'Qayta yoqish',
                              onPressed: () => _toggle(b),
                              icon: Icon(
                                b.isActive
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 20,
                              ),
                            ),
                        ],
                      ),
                    };
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BranchForm extends ConsumerStatefulWidget {
  const _BranchForm({this.branch});

  final Branch? branch;

  @override
  ConsumerState<_BranchForm> createState() => _BranchFormState();
}

class _BranchFormState extends ConsumerState<_BranchForm> {
  late final _name = TextEditingController(text: widget.branch?.name);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Filial nomini kiriting.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final repo = ref.read(branchesRepositoryProvider);
      final existing = widget.branch;
      if (existing == null) {
        await repo.create(name);
      } else if (existing.name != name) {
        await repo.update(existing.id, name: name);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.branch == null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DialogHeader(title: isNew ? 'Yangi filial' : 'Filial nomi'),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextField(
                key: const ValueKey('branch-name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Nomi',
                  hintText: 'Masalan: Chilonzor',
                ),
                onSubmitted: (_) => _save(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    key: const ValueKey('branch-error'),
                    style: const TextStyle(color: AppColors.dangerText),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Bekor qilish'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    key: const ValueKey('branch-save'),
                    onPressed: _saving ? null : _save,
                    child: Text(isNew ? 'Qo\'shish' : 'Saqlash'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
