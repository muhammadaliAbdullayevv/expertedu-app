import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/widgets/status_chip.dart';
import '../../../services/printing/print_station.dart';

/// Settings -> Printer (desktop): makes this PC the print station -- the one
/// with the printer, which prints what teachers and admins send to the
/// Telegram bot -- and lists who printed what lately.
class PrintStationTab extends ConsumerStatefulWidget {
  const PrintStationTab({super.key});

  @override
  ConsumerState<PrintStationTab> createState() => _PrintStationTabState();
}

class _PrintStationTabState extends ConsumerState<PrintStationTab> {
  Timer? _refresh;
  String? _note;

  @override
  void initState() {
    super.initState();
    final station = ref.read(printStationProvider);
    unawaited(station.loadHistory());
    _refresh = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(station.loadHistory()),
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _test(PrintStation station) async {
    final problem = await station.printTestPage();
    if (mounted) {
      setState(
        () => _note = problem ?? 'Sinov varag\'i printerga yuborildi.',
      );
    }
  }

  Future<void> _cancel(PrintStation station, int id) async {
    final problem = await station.cancel(id);
    if (mounted && problem != null) setState(() => _note = problem);
  }

  @override
  Widget build(BuildContext context) {
    final station = ref.watch(printStationProvider);
    return ListenableBuilder(
      listenable: station,
      builder: (context, _) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: <Widget>[
              _setup(station),
              const SizedBox(height: 16),
              _history(station),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card({required Widget child, Key? key}) => Container(
    key: key,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.divider),
    ),
    child: child,
  );

  Widget _setup(PrintStation station) {
    final problem = station.problem;
    final names = station.printers.map((p) => p.name).toList();
    return _card(
      key: const ValueKey('print-station'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.print_rounded, size: 18, color: AppColors.inkMuted),
              const SizedBox(width: 8),
              const Text(
                'Printer stansiyasi',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 10),
              StatusChip(
                station.running ? 'Yoqilgan' : 'O\'chiq',
                key: const ValueKey('print-state'),
                tone: station.running ? StatusTone.ok : StatusTone.neutral,
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'O\'qituvchi, admin yoki ega Telegram botga PDF yoki rasm yuborsa, '
            'shu kompyuter uni printerdan chiqaradi. Buning uchun dastur ochiq '
            'va shu filial admini hisobida kirilgan bo\'lishi kerak.',
            style: TextStyle(color: AppColors.inkMuted, fontSize: 13, height: 1.4),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              const Expanded(child: Text('Bu kompyuter printer stansiyasi')),
              Switch(
                key: const ValueKey('print-enabled'),
                value: station.enabled,
                onChanged: (value) => unawaited(station.setEnabled(value)),
              ),
            ],
          ),
          if (problem != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                problem,
                key: const ValueKey('print-problem'),
                style: const TextStyle(color: AppColors.danger, fontSize: 13),
              ),
            ),
          Row(
            children: <Widget>[
              Expanded(
                child: names.isEmpty
                    ? const Text(
                        'Printer topilmadi.',
                        style: TextStyle(color: AppColors.inkMuted),
                      )
                    : DropdownButtonFormField<String>(
                        key: const ValueKey('print-printer'),
                        initialValue: names.contains(station.printer)
                            ? station.printer
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Printer',
                          isDense: true,
                        ),
                        items: <DropdownMenuItem<String>>[
                          for (final name in names)
                            DropdownMenuItem<String>(
                              value: name,
                              child: Text(name, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                        onChanged: (value) => unawaited(station.setPrinter(value)),
                      ),
              ),
              IconButton(
                key: const ValueKey('print-refresh'),
                tooltip: 'Printerlarni yangilash',
                onPressed: () => unawaited(station.refreshPrinters()),
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              OutlinedButton.icon(
                key: const ValueKey('print-test'),
                onPressed: station.printer == null ? null : () => _test(station),
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('Sinov varag\'ini chiqarish'),
              ),
              if (station.status.isNotEmpty)
                Text(
                  station.status,
                  key: const ValueKey('print-status'),
                  style: const TextStyle(color: AppColors.inkMuted, fontSize: 13),
                ),
            ],
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_note!, style: const TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }

  (String, StatusTone) _tone(String status) => switch (status) {
    'done' => ('Yuborildi', StatusTone.ok),
    'queued' => ('Navbatda', StatusTone.info),
    'printing' => ('Chop etilmoqda', StatusTone.info),
    'failed' => ('Xato', StatusTone.danger),
    'expired' => ('Muddati o\'tdi', StatusTone.warning),
    'cancelled' => ('Bekor qilindi', StatusTone.neutral),
    _ => (status, StatusTone.neutral),
  };

  String _when(DateTime when) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(when.day)}.${two(when.month)} ${two(when.hour)}:${two(when.minute)}';
  }

  Widget _history(PrintStation station) {
    final items = station.history;
    return _card(
      key: const ValueKey('print-history'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'Oxirgi chop etishlar',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          if (items.isEmpty)
            const Text(
              'Hozircha hech narsa chop etilmagan.',
              style: TextStyle(color: AppColors.inkMuted),
            ),
          for (final job in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                key: ValueKey('print-job-${job.id}'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          job.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${job.requestedBy} · ${_when(job.createdAt)} · '
                          '${job.pages} varaq × ${job.copies}'
                          '${job.summary == null ? '' : ' · ${job.summary}'}',
                          style: const TextStyle(
                            color: AppColors.inkMuted,
                            fontSize: 12,
                          ),
                        ),
                        if (job.error != null)
                          Text(
                            job.error!,
                            style: const TextStyle(
                              color: AppColors.dangerText,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Builder(
                    builder: (context) {
                      final (label, tone) = _tone(job.status);
                      return StatusChip(label, tone: tone);
                    },
                  ),
                  if (job.status == 'queued')
                    IconButton(
                      key: ValueKey('print-cancel-${job.id}'),
                      tooltip: 'Bekor qilish',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _cancel(station, job.id),
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
