import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/extensions/build_context_x.dart';
import '../../../core/formatters/date_formatters.dart';
import '../../students/presentation/heard_from.dart';
import '../data/admissions_models.dart';

/// Bumped after any admissions change, so every tab (leads, board, trials,
/// tasks, overview) reloads instead of each one guessing what changed.
final admissionsRefreshProvider = Provider<ValueNotifier<int>>((ref) {
  final notifier = ValueNotifier<int>(0);
  ref.onDispose(notifier.dispose);
  return notifier;
});

void refreshAdmissions(WidgetRef ref) =>
    ref.read(admissionsRefreshProvider).value++;

/// Stage colours: neutral while new, warm while a trial is in play, green
/// once enrolled, grey once closed. Only these few tones next to the
/// interface blue -- the board stays calm.
Color stageColor(String stage) => switch (stage) {
  LeadStage.newLead => AppColors.accent,
  LeadStage.contacted => const Color(0xFF7C3AED),
  LeadStage.trialScheduled => const Color(0xFFD97706),
  LeadStage.trialCompleted => const Color(0xFF0D9488),
  LeadStage.decisionPending => const Color(0xFFDB2777),
  LeadStage.followUpLater => AppColors.inkMuted,
  LeadStage.enrolled => AppColors.success,
  _ => AppColors.inkMuted,
};

class StageChip extends StatelessWidget {
  const StageChip(this.stage, {super.key, this.pending = false});

  final String stage;

  /// A lead still waiting in the offline outbox.
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final color = pending ? AppColors.inkMuted : stageColor(stage);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (pending) ...<Widget>[
            Icon(Icons.cloud_upload_outlined, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              pending ? 'Yuborilmagan' : LeadStage.label(stage),
              overflow: TextOverflow.ellipsis,
              style: context.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TrialStatusChip extends StatelessWidget {
  const TrialStatusChip(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TrialStatus.scheduled => const Color(0xFFD97706),
      TrialStatus.attended => AppColors.success,
      TrialStatus.absent => AppColors.danger,
      _ => AppColors.inkMuted,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        TrialStatus.label(status),
        style: context.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// "Sinov: 20 oktyabr, 10:00" / "Vazifa: bugun 14:00" -- what happens next
/// with a lead, for tables and cards.
String? nextStepText(Lead lead) {
  final trial = lead.nextTrialAt;
  if (trial != null) return 'Sinov: ${shortDateTime(trial)}';
  final task = lead.nextTaskDueAt;
  if (task != null) return 'Vazifa: ${shortDateTime(task)}';
  return null;
}

/// "Bugun 14:00", "Ertaga 10:00", "20 oktyabr 10:00" (the year only when
/// it isn't this one).
String shortDateTime(DateTime value) {
  final local = value.toLocal();
  final now = DateTime.now();
  final days = DateUtils.dateOnly(
    local,
  ).difference(DateUtils.dateOnly(now)).inDays;
  final time = DateFormatters.time(local);
  return switch (days) {
    0 => 'Bugun $time',
    1 => 'Ertaga $time',
    -1 => 'Kecha $time',
    _ when local.year == now.year =>
      '${local.day} ${DateFormatters.monthName(local).toLowerCase()} $time',
    _ => '${DateFormatters.date(local)} $time',
  };
}

String sourceLabel(String? source) =>
    source == null ? '-' : heardFromLabel(source);

/// "18%", "4.5%" (one decimal under 10%), "0%"; "—" when there's nothing
/// to divide by.
String percent(double? rate) {
  if (rate == null) return '—';
  if (rate == 0) return '0%';
  return '${(rate * 100).toStringAsFixed(rate < 0.1 ? 1 : 0)}%';
}

void showSnack(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ),
    );
}

/// A dialog's header row: title and a close button.
class DialogHeader extends StatelessWidget {
  const DialogHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onClose,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 12, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: context.textTheme.titleLarge),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Yopish (Esc)',
            onPressed: onClose ?? () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// Centered dialog on wide layouts, full screen on phones -- like
/// "Yangi o'quvchi".
Future<T?> showAdaptiveFormDialog<T>(
  BuildContext context, {
  required Widget child,
  double maxWidth = 560,
}) {
  final wide = MediaQuery.sizeOf(context).width >= 840;
  return showDialog<T>(
    context: context,
    builder: (dialogContext) => wide
        ? Dialog(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxWidth,
                maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.9,
              ),
              child: child,
            ),
          )
        : Dialog.fullscreen(child: child),
  );
}

/// Ctrl+Enter submits a form dialog from any field.
class SubmitShortcut extends StatelessWidget {
  const SubmitShortcut({
    super.key,
    required this.onSubmit,
    required this.child,
  });

  final VoidCallback? onSubmit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
            onSubmit?.call(),
      },
      child: child,
    );
  }
}

class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class LoadFailed extends StatelessWidget {
  const LoadFailed({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Ma\'lumotlarni yuklab bo\'lmadi: $error',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Qayta urinish'),
            ),
          ],
        ),
      ),
    );
  }
}
