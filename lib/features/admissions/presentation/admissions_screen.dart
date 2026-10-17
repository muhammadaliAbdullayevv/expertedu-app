import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../services/sync/sync_engine.dart';
import 'admissions_ui.dart';
import 'pending_changes_dialog.dart';
import 'qabul_form.dart';
import 'qabul_list.dart';

/// The two views of Qabul.
enum QabulView { add, list }

/// "Qabul" (desktop): one page, two views switched by a button at the top --
/// "Yangi qo'shish" (the fast form, the default) and "Ro'yxat". No numbers,
/// no stages: speed is the point. A person saved here is only a lead -- no
/// seat, no charge, no debt -- until "O'quvchi qilish".
///
/// Keyboard: Ctrl+N the form, Ctrl+L the list, Ctrl+F search the list, F5
/// reload; in the form Tab moves on and Enter saves.
class AdmissionsScreen extends ConsumerStatefulWidget {
  const AdmissionsScreen({super.key, this.initialView = QabulView.add});

  final QabulView initialView;

  @override
  ConsumerState<AdmissionsScreen> createState() => AdmissionsScreenState();
}

class AdmissionsScreenState extends ConsumerState<AdmissionsScreen> {
  late QabulView _view = widget.initialView;

  final _searchFocus = FocusNode();
  final _formKey = GlobalKey<QabulFormState>();
  late final SyncEngine _sync = ref.read(syncEngineProvider);

  @override
  void initState() {
    super.initState();
    // Something queued reached the server: show it for real.
    _sync.syncedRevision.addListener(_onSynced);
  }

  @override
  void dispose() {
    _sync.syncedRevision.removeListener(_onSynced);
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSynced() => refreshAdmissions(ref);

  void reload() => refreshAdmissions(ref);

  /// "+ Yangi" / Ctrl+N: back to the form, ready to type.
  void newInquiry() => setState(() {
    _view = QabulView.add;
  });

  void _focusSearch() {
    setState(() {
      _view = QabulView.list;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            newInquiry,
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () =>
            setState(() {
              _view = QabulView.list;
            }),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.f5): reload,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _header(),
          Expanded(
            child: switch (_view) {
              QabulView.add => QabulForm(key: _formKey),
              QabulView.list => QabulList(searchFocus: _searchFocus),
            },
          ),
        ],
      ),
    );
  }

  Widget _header() {
    final adding = _view == QabulView.add;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                adding
                    ? 'Yangi mijozni saqlang. U o\'quvchi emas, hisob yaratilmaydi.'
                    : 'Saqlangan mijozlar. Kelganda "O\'quvchi qilish" tugmasini bosing.',
                style: const TextStyle(fontSize: 15, color: AppColors.inkMuted),
              ),
            ),
          ),
          _SyncStatus(sync: _sync),
          const SizedBox(width: 12),
          _ViewSwitch(view: _view, onChanged: (v) => setState(() => _view = v)),
        ],
      ),
    );
  }
}

/// The segmented button at the top of the page.
class _ViewSwitch extends StatelessWidget {
  const _ViewSwitch({required this.view, required this.onChanged});

  final QabulView view;
  final ValueChanged<QabulView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: Border.all(color: AppColors.border),
        color: AppColors.surface,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _Segment(
            key: const ValueKey('view-add'),
            label: 'Yangi qo\'shish',
            icon: Icons.add,
            selected: view == QabulView.add,
            onTap: () => onChanged(QabulView.add),
          ),
          _Segment(
            key: const ValueKey('view-list'),
            label: 'Ro\'yxat',
            selected: view == QabulView.list,
            onTap: () => onChanged(QabulView.list),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.white : AppColors.ink;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 22),
        color: selected ? AppColors.ink : Colors.transparent,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Oflayn" and "N ta yuborilmagan" -- tap to see what's waiting. Shown only
/// when something is waiting or the internet is down.
class _SyncStatus extends StatelessWidget {
  const _SyncStatus({required this.sync});

  final SyncEngine sync;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: sync.online,
      builder: (context, online, _) => ValueListenableBuilder<int>(
        valueListenable: sync.pendingCount,
        builder: (context, pending, _) {
          if (online && pending == 0) return const SizedBox.shrink();
          return TextButton.icon(
            onPressed: () => showPendingChangesDialog(context),
            icon: Icon(
              online ? Icons.cloud_upload_outlined : Icons.cloud_off_rounded,
              size: 18,
              color: online ? null : context.colors.error,
            ),
            label: Text(
              <String>[
                if (!online) 'Oflayn',
                if (pending > 0) '$pending ta yuborilmagan',
              ].join(' · '),
            ),
          );
        },
      ),
    );
  }
}
