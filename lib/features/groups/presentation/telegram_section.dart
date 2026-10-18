import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/status_chip.dart';
import '../data/groups_repository.dart';

/// On the group page: is a Telegram chat connected, and the one-time code that connects one.
/// The bot is added to the Telegram group, then `/connect CODE` is sent there (or the link below
/// adds the bot and hands the code over in one step).
class TelegramSection extends ConsumerStatefulWidget {
  const TelegramSection({super.key, required this.groupId});

  final int groupId;

  @override
  ConsumerState<TelegramSection> createState() => _TelegramSectionState();
}

class _TelegramSectionState extends ConsumerState<TelegramSection> {
  TelegramGroupStatus? _status;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _run(
      () => ref.read(groupsRepositoryProvider).telegramStatus(widget.groupId),
    );
  }

  Future<void> _run(Future<TelegramGroupStatus> Function() action) async {
    setState(() => _busy = true);
    try {
      final status = await action();
      if (mounted) {
        setState(() {
          _status = status;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Nusxalandi')));
  }

  String _until(DateTime when) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(when.day)}.${two(when.month)} ${two(when.hour)}:${two(when.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Container(
      key: const ValueKey('telegram-section'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.send_rounded,
                size: 18,
                color: AppColors.inkMuted,
              ),
              const SizedBox(width: 8),
              const Text(
                'Telegram guruhi',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              if (status != null)
                StatusChip(
                  status.connected ? 'Ulangan' : 'Ulanmagan',
                  key: const ValueKey('telegram-state'),
                  tone: status.connected ? StatusTone.ok : StatusTone.neutral,
                ),
              const Spacer(),
              if (_busy)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          if (_error != null && status == null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Telegram holatini olib bo\'lmadi: $_error',
              key: const ValueKey('telegram-error'),
              style: const TextStyle(color: AppColors.inkMuted),
            ),
          ],
          if (status != null) ...<Widget>[
            const SizedBox(height: 10),
            if (status.connected)
              ..._connected(status)
            else
              ..._notConnected(status),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '$_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ],
      ),
    );
  }

  List<Widget> _connected(TelegramGroupStatus status) {
    return <Widget>[
      Text(
        status.chatTitle == null || status.chatTitle!.isEmpty
            ? 'Telegram guruhi ulangan.'
            : '«${status.chatTitle}» ulangan.',
        key: const ValueKey('telegram-chat'),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      if (status.connectedBy != null)
        Text(
          '${status.connectedBy} ulagan',
          style: const TextStyle(color: AppColors.inkMuted, fontSize: 13),
        ),
      const SizedBox(height: 6),
      const Text(
        'Bot har dars tugashidan 5 daqiqa oldin o\'qituvchidan o\'quvchilarning uy vazifasi haqida so\'raydi. '
        'O\'qituvchining Telegram ID si o\'qituvchi kartochkasida bo\'lishi kerak.',
        style: TextStyle(color: AppColors.inkMuted, fontSize: 13),
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton(
          key: const ValueKey('telegram-disconnect'),
          onPressed: _busy
              ? null
              : () => _run(
                  () => ref
                      .read(groupsRepositoryProvider)
                      .disconnectTelegram(widget.groupId),
                ),
          child: const Text('Uzish'),
        ),
      ),
    ];
  }

  List<Widget> _notConnected(TelegramGroupStatus status) {
    final code = status.code;
    return <Widget>[
      const Text(
        '1. Botni Telegram guruhiga admin qilib qo\'shing.\n'
        '2. Guruhda yuboring: /connect KOD',
        style: TextStyle(height: 1.5, fontSize: 13),
      ),
      const SizedBox(height: 10),
      if (code == null)
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const ValueKey('telegram-new-code'),
            onPressed: _busy
                ? null
                : () => _run(
                    () => ref
                        .read(groupsRepositoryProvider)
                        .newTelegramCode(widget.groupId),
                  ),
            child: const Text('Kod olish'),
          ),
        )
      else ...<Widget>[
        Row(
          children: <Widget>[
            Flexible(
              child: SelectableText(
                code,
                key: const ValueKey('telegram-code'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 3,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('telegram-copy-command'),
              tooltip: '/connect $code ni nusxalash',
              onPressed: () => _copy('/connect $code'),
              icon: const Icon(Icons.copy_rounded, size: 18),
            ),
          ],
        ),
        if (status.codeExpiresAt != null)
          Text(
            'Bir marta ishlaydi, ${_until(status.codeExpiresAt!)} gacha.',
            style: const TextStyle(color: AppColors.inkMuted, fontSize: 12),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: <Widget>[
            TextButton(
              key: const ValueKey('telegram-new-code'),
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => ref
                          .read(groupsRepositoryProvider)
                          .newTelegramCode(widget.groupId),
                    ),
              child: const Text('Yangi kod'),
            ),
            if (status.link != null)
              TextButton.icon(
                key: const ValueKey('telegram-copy-link'),
                onPressed: () => _copy(status.link!),
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Havolani nusxalash'),
              ),
          ],
        ),
        if (status.link != null)
          const Text(
            'Havola botni guruhga qo\'shadi va kodni o\'zi yuboradi.',
            style: TextStyle(color: AppColors.inkMuted, fontSize: 12),
          ),
      ],
    ];
  }
}
