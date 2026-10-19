import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/auth/application/session_controller.dart';
import '../api/api_client.dart';
import 'print_driver.dart';
import 'test_page.dart';

/// The print station: this PC, which has the printer, takes the print jobs
/// that teachers and admins send to the Telegram bot, prints them and reports
/// the result. It runs only while the app is open and signed in, and only
/// where it was switched on (Settings -> Printer).
final printStationProvider = Provider<PrintStation>((ref) {
  final session = ref.watch(sessionControllerProvider);
  final station = PrintStation(
    api: ref.watch(apiClientProvider),
    driver: PrintDriver.forPlatform(),
    signedIn: () => session.isAuthenticated,
    enabledHere:
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux,
  );
  ref.onDispose(station.dispose);
  unawaited(station.start());
  return station;
});

/// One print job, as the server hands it to the station.
class PrintJob {
  const PrintJob({
    required this.id,
    required this.title,
    required this.summary,
    required this.pages,
    required this.copies,
    required this.duplex,
    required this.color,
    required this.requestedBy,
  });

  factory PrintJob.fromJson(Map<String, dynamic> json) => PrintJob(
    id: json['id'] as int,
    title: json['title'] as String,
    summary: json['summary'] as String?,
    pages: json['pages'] as int,
    copies: json['copies'] as int,
    duplex: json['duplex'] as bool,
    color: json['color'] as bool,
    requestedBy: json['requested_by'] as String,
  );

  final int id;
  final String title;
  final String? summary;
  final int pages;
  final int copies;
  final bool duplex;
  final bool color;
  final String requestedBy;
}

/// A line of the "who printed what" list.
class PrintHistoryEntry {
  const PrintHistoryEntry({
    required this.id,
    required this.title,
    required this.summary,
    required this.pages,
    required this.copies,
    required this.requestedBy,
    required this.role,
    required this.status,
    required this.error,
    required this.createdAt,
  });

  factory PrintHistoryEntry.fromJson(Map<String, dynamic> json) =>
      PrintHistoryEntry(
        id: json['id'] as int,
        title: json['title'] as String,
        summary: json['summary'] as String?,
        pages: json['pages'] as int,
        copies: json['copies'] as int,
        requestedBy: json['requested_by'] as String,
        role: json['requested_role'] as String,
        status: json['status'] as String,
        error: json['error'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );

  final int id;
  final String title;
  final String? summary;
  final int pages;
  final int copies;
  final String requestedBy;
  final String role;
  final String status;
  final String? error;
  final DateTime createdAt;
}

class PrintStation extends ChangeNotifier {
  PrintStation({
    required this.api,
    required this.driver,
    required this.signedIn,
    this.enabledHere = true,
    Future<Directory> Function()? configDirectory,
    Future<Directory> Function()? tempDirectory,
    this.pollEvery = const Duration(seconds: 4),
  }) : _configDirectory = configDirectory ?? getApplicationSupportDirectory,
       _tempDirectory = tempDirectory ?? getTemporaryDirectory;

  final ApiClient api;
  final PrintDriver driver;
  final bool Function() signedIn;

  /// False where this kind of PC is not a print station at all (a phone).
  final bool enabledHere;
  final Duration pollEvery;
  final Future<Directory> Function() _configDirectory;
  final Future<Directory> Function() _tempDirectory;

  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  /// This PC takes the jobs (a switch in Settings, remembered).
  bool enabled = false;

  /// The printer jobs go to.
  String? printer;
  List<PrinterInfo> printers = const <PrinterInfo>[];

  /// What the person at the PC says the printer can do, over what was detected
  /// (null = go by the detection).
  bool? colorOverride;
  bool? duplexOverride;

  PrinterInfo? get selected {
    for (final p in printers) {
      if (p.name == printer) return p;
    }
    return null;
  }

  /// What the printer can do: the override, else what was detected, else not
  /// known (null: the bot offers it).
  bool? get color => colorOverride ?? selected?.color;
  bool? get duplex => duplexOverride ?? selected?.duplex;

  /// A missing program or the like, shown in Settings.
  String? problem;

  /// What it is doing, in words.
  String status = '';
  PrintJob? current;
  List<PrintHistoryEntry> history = const <PrintHistoryEntry>[];
  bool get running => enabled && printer != null;

  Future<File> _configFile() async =>
      File(p.join((await _configDirectory()).path, 'print_station.json'));

  Future<void> start() async {
    if (!enabledHere) return;
    try {
      final file = await _configFile();
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map) {
          enabled = json['enabled'] == true;
          printer = json['printer'] as String?;
          colorOverride = json['color'] as bool?;
          duplexOverride = json['duplex'] as bool?;
        }
      }
    } catch (_) {
      // A damaged settings file: start switched off.
    }
    await refreshPrinters();
    _arm();
    _changed();
  }

  Future<void> _save() async {
    try {
      final file = await _configFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'enabled': enabled,
          'printer': printer,
          'color': colorOverride,
          'duplex': duplexOverride,
        }),
      );
    } catch (_) {
      // Not being able to remember is not worth stopping for.
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = null;
    if (!running) {
      status = enabled ? 'Printer tanlang.' : '';
      return;
    }
    status = 'Ishga tushdi — topshiriq kutilmoqda.';
    _timer = Timer.periodic(pollEvery, (_) => unawaited(tick()));
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    await _save();
    _arm();
    _changed();
    if (value) await tick(); // say "I'm here" at once, not at the next round
  }

  Future<void> setPrinter(String? name) async {
    printer = name;
    await _save();
    _arm();
    _changed();
  }

  Future<void> setColor(bool? value) async {
    colorOverride = value;
    await _save();
    _changed();
  }

  Future<void> setDuplex(bool? value) async {
    duplexOverride = value;
    await _save();
    _changed();
  }

  Future<void> refreshPrinters() async {
    problem = await driver.problem();
    try {
      printers = await driver.printers();
    } on PrintFailure catch (e) {
      problem ??= e.message;
      printers = const <PrinterInfo>[];
    } on Object {
      printers = const <PrinterInfo>[];
    }
    // Nothing chosen yet: the PC's default printer is the likely one.
    if (printer == null && printers.isNotEmpty) {
      final preferred = printers.where((x) => x.isDefault);
      printer = (preferred.isNotEmpty ? preferred.first : printers.first).name;
      await _save();
    }
    _changed();
  }

  /// One round: say "I'm here", take a waiting job if there is one and print it.
  Future<void> tick() async {
    if (!running || _busy || !signedIn()) return;
    _busy = true;
    try {
      // Every round says which printer this is and what it can do (when known).
      final query = <String>[
        'printer=${Uri.encodeQueryComponent(printer!)}',
        if (color != null) 'color=$color',
        if (duplex != null) 'duplex=$duplex',
      ].join('&');
      final json = await api.post('/print/next?$query');
      if (json == null) {
        if (status != 'Topshiriq kutilmoqda.') {
          status = 'Topshiriq kutilmoqda.';
          _changed();
        }
        return;
      }
      await _handle(PrintJob.fromJson((json as Map).cast<String, dynamic>()));
    } on ApiException catch (e) {
      status = e.statusCode == 0 ? 'Server bilan aloqa yo\'q.' : e.message;
      _changed();
    } catch (e) {
      status = 'Xato: $e';
      _changed();
    } finally {
      _busy = false;
    }
  }

  Future<void> _handle(PrintJob job) async {
    current = job;
    status = 'Chop etilmoqda: ${job.title}';
    _changed();
    String? error;
    File? file;
    try {
      final bytes = await api.getBytes('/print/${job.id}/file');
      file = await _writeTemp('print_${job.id}.pdf', bytes);
      await driver.print(
        printer!,
        PrintRequest(
          path: file.path,
          copies: job.copies,
          duplex: job.duplex,
          color: job.color,
        ),
      );
    } on PrintFailure catch (e) {
      error = e.message;
    } on ApiException catch (e) {
      error = 'Faylni olib bo\'lmadi: ${e.message}';
    } catch (e) {
      error = 'Chop etib bo\'lmadi: $e';
    } finally {
      if (file != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
    await _report(job, error);
    current = null;
    status = error == null
        ? 'Printerga yuborildi: ${job.title}'
        : 'Chop etilmadi: ${job.title} — $error';
    _changed();
    unawaited(loadHistory());
  }

  Future<File> _writeTemp(String name, List<int> bytes) async {
    final dir = await _tempDirectory();
    final file = File(p.join(dir.path, 'expertedu_$name'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  /// Tells the server how it went; a short drop of the connection is tried again.
  Future<void> _report(PrintJob job, String? error) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await api.post(
          '/print/${job.id}/result',
          body: <String, Object?>{'ok': error == null, 'error': error},
        );
        return;
      } on ApiException catch (e) {
        if (e.statusCode != 0) return; // an answer, even a refusal, is final
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Prints a page that says what printer it is -- to check the setup.
  Future<String?> printTestPage() async {
    final name = printer;
    if (name == null) return 'Avval printerni tanlang.';
    File? file;
    try {
      file = await _writeTemp('test.pdf', testPagePdf(name, DateTime.now()));
      await driver.print(name, PrintRequest(path: file.path));
      return null;
    } on PrintFailure catch (e) {
      return e.message;
    } catch (e) {
      return '$e';
    } finally {
      if (file != null) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> loadHistory() async {
    if (!signedIn()) return;
    try {
      final json = await api.get(
        '/print',
        query: <String, String>{'limit': '30'},
      );
      history = <PrintHistoryEntry>[
        for (final item in (json as List))
          PrintHistoryEntry.fromJson((item as Map).cast<String, dynamic>()),
      ];
      _changed();
    } on ApiException {
      // The list is a convenience; the station goes on.
    }
  }

  /// Drops a job that has not started (the sender is told).
  Future<String?> cancel(int jobId) async {
    try {
      await api.post('/print/$jobId/cancel');
    } on ApiException catch (e) {
      return e.message;
    }
    await loadHistory();
    return null;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
