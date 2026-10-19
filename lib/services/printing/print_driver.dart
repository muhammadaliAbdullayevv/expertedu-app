import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A printer the computer knows.
class PrinterInfo {
  const PrinterInfo(this.name, {this.isDefault = false});

  final String name;
  final bool isDefault;
}

/// What to print: a PDF file with its copies and sides/colour choices.
class PrintRequest {
  const PrintRequest({
    required this.path,
    this.copies = 1,
    this.duplex = false,
    this.color = false,
  });

  final String path;
  final int copies;
  final bool duplex;
  final bool color;
}

/// Printing did not work; [message] is meant for the person at the PC.
class PrintFailure implements Exception {
  const PrintFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs a program and returns what it printed and how it ended (replaced in
/// tests).
typedef RunProcess =
    Future<ProcessResult> Function(String exe, List<String> args);

Future<ProcessResult> runProcess(String exe, List<String> args) => Process.run(
  exe,
  args,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

/// The PC's printers and a way to send a PDF to one. The print station works
/// through this, so the queue logic can be tested without a printer.
abstract class PrintDriver {
  Future<List<PrinterInfo>> printers();

  /// Why printing cannot work on this PC (a missing program), or null.
  Future<String?> problem();

  /// Sends the PDF to [printer]; throws [PrintFailure] when it did not go.
  Future<void> print(String printer, PrintRequest request);

  /// The driver for the platform the app runs on.
  static PrintDriver forPlatform() {
    return defaultTargetPlatform == TargetPlatform.windows
        ? WindowsPrintDriver()
        : CupsPrintDriver();
  }
}

/// Windows: the printers come from the system (PowerShell), the printing is
/// done by SumatraPDF's silent mode -- it ships beside the app (tools\), is
/// found in its usual install places, and does copies, two-sided and
/// colour/black-and-white from the command line.
class WindowsPrintDriver implements PrintDriver {
  WindowsPrintDriver({
    RunProcess? run,
    String? executable,
    Map<String, String>? environment,
    bool Function(String path)? exists,
  }) : _run = run ?? runProcess,
       _executable = executable ?? Platform.resolvedExecutable,
       _env = environment ?? Platform.environment,
       _exists = exists ?? ((path) => File(path).existsSync());

  final RunProcess _run;
  final String _executable;
  final Map<String, String> _env;
  final bool Function(String path) _exists;

  /// Where SumatraPDF may be, best first: shipped with the app, then installed.
  List<String> get sumatraCandidates {
    final appDir = File(_executable).parent.path;
    final sep = Platform.isWindows ? r'\' : '/';
    final candidates = <String>[
      '$appDir${sep}tools${sep}SumatraPDF.exe',
      '$appDir${sep}SumatraPDF.exe',
    ];
    for (final key in <String>[
      'ProgramFiles',
      'ProgramFiles(x86)',
      'LOCALAPPDATA',
    ]) {
      final base = _env[key];
      if (base != null && base.isNotEmpty) {
        candidates.add('$base${sep}SumatraPDF${sep}SumatraPDF.exe');
      }
    }
    return candidates;
  }

  String? get sumatra {
    for (final path in sumatraCandidates) {
      if (_exists(path)) return path;
    }
    return null;
  }

  @override
  Future<String?> problem() async => sumatra == null
      ? 'SumatraPDF topilmadi. Dasturni qayta o\'rnating (u dastur bilan '
            'birga keladi) yoki sumatrapdfreader.org dan o\'rnating.'
      : null;

  @override
  Future<List<PrinterInfo>> printers() async {
    final result = await _run('powershell.exe', const <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '[Console]::OutputEncoding=[Text.Encoding]::UTF8; '
          'Get-CimInstance Win32_Printer | Select-Object Name,Default | '
          'ConvertTo-Json -Compress',
    ]);
    if (result.exitCode != 0) {
      throw PrintFailure('Printerlar ro\'yxatini olib bo\'lmadi.');
    }
    return parsePrinters('${result.stdout}');
  }

  /// PowerShell's JSON: one printer is an object, several are a list.
  static List<PrinterInfo> parsePrinters(String json) {
    final text = json.trim();
    if (text.isEmpty) return const <PrinterInfo>[];
    final decoded = jsonDecode(text);
    final items = decoded is List ? decoded : <dynamic>[decoded];
    return <PrinterInfo>[
      for (final item in items)
        if (item is Map && item['Name'] is String)
          PrinterInfo(item['Name'] as String, isDefault: item['Default'] == true),
    ];
  }

  /// SumatraPDF's `-print-settings` for a request: copies, sides, colour.
  /// (It turns a landscape sheet to fit the portrait paper by itself, so the
  /// long-edge flip is right for those too.)
  static String settings(PrintRequest r) =>
      '${r.copies}x,${r.duplex ? 'duplexlong' : 'simplex'},'
      '${r.color ? 'color' : 'monochrome'}';

  @override
  Future<void> print(String printer, PrintRequest request) async {
    final exe = sumatra;
    if (exe == null) throw PrintFailure((await problem())!);
    final result = await _run(exe, <String>[
      '-print-to',
      printer,
      '-print-settings',
      settings(request),
      '-silent',
      request.path,
    ]);
    final message = failureMessage(result.exitCode, printer);
    if (message != null) throw PrintFailure(message);
  }

  /// What SumatraPDF's exit code means (0 = it was handed to the printer).
  static String? failureMessage(int code, String printer) => switch (code) {
    0 => null,
    2 => 'Faylni ochib bo\'lmadi.',
    3 => 'Bu hujjatni chop etish taqiqlangan.',
    4 => '«$printer» printeri topilmadi.',
    5 => '«$printer» printeri xato berdi (o\'chiq yoki ulanmagan bo\'lishi mumkin).',
    6 => 'Chop etish tizim tomonidan taqiqlangan.',
    _ => 'Chop etish bajarilmadi (kod $code). Printer nomi va ulanishini tekshiring.',
  };
}

/// Linux (CUPS): `lpstat` lists the printers, `lp` prints. Used where the app
/// runs on Linux; the center's print PC is Windows.
class CupsPrintDriver implements PrintDriver {
  CupsPrintDriver({RunProcess? run}) : _run = run ?? runProcess;

  final RunProcess _run;

  @override
  Future<String?> problem() async {
    try {
      final result = await _run('lpstat', const <String>['-r']);
      return result.exitCode == 0 ? null : 'CUPS (chop etish xizmati) ishlamayapti.';
    } on ProcessException {
      return 'CUPS topilmadi (lp/lpstat o\'rnatilmagan).';
    }
  }

  @override
  Future<List<PrinterInfo>> printers() async {
    final ProcessResult names;
    try {
      names = await _run('lpstat', const <String>['-e']);
    } on ProcessException {
      return const <PrinterInfo>[];
    }
    if (names.exitCode != 0) return const <PrinterInfo>[];
    var defaultName = '';
    final d = await _run('lpstat', const <String>['-d']);
    final match = RegExp(r':\s*(\S.*)$').firstMatch('${d.stdout}'.trim());
    if (match != null) defaultName = match.group(1)!.trim();
    return <PrinterInfo>[
      for (final line in LineSplitter.split('${names.stdout}'))
        if (line.trim().isNotEmpty)
          PrinterInfo(line.trim(), isDefault: line.trim() == defaultName),
    ];
  }

  /// The arguments of `lp` for a request.
  static List<String> arguments(String printer, PrintRequest r) => <String>[
    '-d',
    printer,
    '-n',
    '${r.copies}',
    '-o',
    'sides=${r.duplex ? 'two-sided-long-edge' : 'one-sided'}',
    '-o',
    'print-color-mode=${r.color ? 'color' : 'monochrome'}',
    r.path,
  ];

  @override
  Future<void> print(String printer, PrintRequest request) async {
    final ProcessResult result;
    try {
      result = await _run('lp', arguments(printer, request));
    } on ProcessException {
      throw const PrintFailure('CUPS topilmadi (lp o\'rnatilmagan).');
    }
    if (result.exitCode != 0) {
      final why = '${result.stderr}'.trim();
      throw PrintFailure(
        why.isEmpty ? 'Chop etish bajarilmadi (kod ${result.exitCode}).' : why,
      );
    }
  }
}
