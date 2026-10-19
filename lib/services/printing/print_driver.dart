import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A printer the computer knows.
class PrinterInfo {
  const PrinterInfo(
    this.name, {
    this.isDefault = false,
    this.uri,
    this.color,
    this.duplex,
  });

  final String name;
  final bool isDefault;

  /// What the printer can do, when it could be found out (null = not known;
  /// an unknown ability is offered, never hidden).
  final bool? color;
  final bool? duplex;

  /// Set for a printer found on the network that has no system queue: its IPP
  /// address, which the direct route prints to.
  final String? uri;
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

Future<ProcessResult> runProcess(String exe, List<String> args) =>
    Process.run(exe, args, stdoutEncoding: utf8, stderrEncoding: utf8);

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
        : LinuxPrintDriver();
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
          'Get-CimInstance Win32_Printer | Select-Object Name,Default,Capabilities | '
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
        if (item is Map && item['Name'] is String) _windowsPrinter(item),
    ];
  }

  /// Win32_Printer.Capabilities lists what the driver says it can do: 2 =
  /// colour, 3 = two-sided. A driver that lists nothing tells us nothing.
  static PrinterInfo _windowsPrinter(Map<dynamic, dynamic> item) {
    final raw = item['Capabilities'];
    final caps = raw is List
        ? raw.whereType<num>().toList()
        : raw is num
        ? <num>[raw]
        : <num>[];
    return PrinterInfo(
      item['Name'] as String,
      isDefault: item['Default'] == true,
      color: caps.isEmpty ? null : caps.contains(2),
      duplex: caps.isEmpty ? null : caps.contains(3),
    );
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
    5 =>
      '«$printer» printeri xato berdi (o\'chiq yoki ulanmagan bo\'lishi mumkin).',
    6 => 'Chop etish tizim tomonidan taqiqlangan.',
    _ =>
      'Chop etish bajarilmadi (kod $code). Printer nomi va ulanishini tekshiring.',
  };
}

/// Linux (CUPS): `lpstat` lists the installed printers, `lp` prints. Used where the app
/// runs on Linux; the center's print PC is Windows.
///
/// Only *installed* printers count (`lpstat -p`). A printer that is merely
/// discovered on the network (`lpstat -e` says "network") has no queue: `lp`
/// answers "No such file or directory" for it, so it is not offered.
class CupsPrintDriver implements PrintDriver {
  CupsPrintDriver({RunProcess? run, bool Function(String path)? exists})
    : _run = run ?? runProcess,
      _exists = exists ?? ((path) => File(path).existsSync());

  final RunProcess _run;
  final bool Function(String path) _exists;

  Future<ProcessResult?> _try(String exe, List<String> args) async {
    try {
      return await _run(exe, args);
    } on ProcessException {
      return null;
    }
  }

  @override
  Future<String?> problem() async {
    final running = await _try('lpstat', const <String>['-r']);
    if (running == null) return 'CUPS topilmadi (lp/lpstat o\'rnatilmagan).';
    if (running.exitCode != 0) return 'CUPS (chop etish xizmati) ishlamayapti.';
    return null;
  }

  @override
  Future<List<PrinterInfo>> printers() async {
    final list = await _try('lpstat', const <String>['-p']);
    if (list == null || list.exitCode != 0) return const <PrinterInfo>[];
    var defaultName = '';
    final d = await _try('lpstat', const <String>['-d']);
    final match = RegExp(
      r':\s*(\S.*)$',
    ).firstMatch('${d?.stdout ?? ''}'.trim());
    if (match != null) defaultName = match.group(1)!.trim();
    final printers = <PrinterInfo>[];
    for (final line in LineSplitter.split('${list.stdout}')) {
      final m = RegExp(r'^printer\s+(\S+)').firstMatch(line);
      if (m == null) continue;
      final name = m.group(1)!;
      final options = await _try('lpoptions', <String>['-p', name, '-l']);
      final caps = options == null || options.exitCode != 0
          ? (color: null, duplex: null)
          : parseOptions('${options.stdout}');
      printers.add(
        PrinterInfo(
          name,
          isDefault: name == defaultName,
          color: caps.color,
          duplex: caps.duplex,
        ),
      );
    }
    return printers;
  }

  /// What `lpoptions -p NAME -l` says: a two-sided option, a colour-model
  /// option with more than grey in it. Nothing listed at all = not known.
  static ({bool? color, bool? duplex}) parseOptions(String output) {
    final lines = LineSplitter.split(
      output,
    ).where((l) => l.contains(':')).toList();
    if (lines.isEmpty) return (color: null, duplex: null);
    bool? color;
    var duplex = false;
    for (final line in lines) {
      final key = line.split('/').first.split(':').first.toLowerCase();
      final values = line.substring(line.indexOf(':') + 1).toLowerCase();
      if (key == 'duplex' || key == 'sides') duplex = true;
      if (key == 'colormodel' ||
          key == 'print-color-mode' ||
          key == 'colormode') {
        color = RegExp(
          r'\b(rgb|color|colour|cmyk|auto|cmy)\b',
        ).hasMatch(values);
      }
    }
    return (color: color, duplex: duplex);
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
    final result = await _try('lp', arguments(printer, request));
    if (result == null) {
      throw const PrintFailure('CUPS topilmadi (lp o\'rnatilmagan).');
    }
    if (result.exitCode != 0) {
      final why = '${result.stderr}'.trim();
      // The file is there, so "no such file" is about the printer, not the PDF.
      if (why.contains('No such file or directory') && _exists(request.path)) {
        throw PrintFailure(
          '«$printer» printeri tizimga qo\'shilmagan (faqat tarmoqda topilgan). '
          'Uni tizim sozlamalaridan qo\'shing.',
        );
      }
      throw PrintFailure(
        why.isEmpty ? 'Chop etish bajarilmadi (kod ${result.exitCode}).' : why,
      );
    }
  }
}

/// Printers found on the local network (Bonjour/IPP) that print without any
/// system queue: the PDF is turned into PWG raster pages by Ghostscript and sent
/// as an IPP Print-Job with `ipptool`. Some printers cannot answer CUPS's
/// "all attributes" question, so CUPS cannot install them -- but they do take
/// PWG raster. (Black and white, one side: what such a basic printer does.)
class DirectIppPrintDriver implements PrintDriver {
  DirectIppPrintDriver({RunProcess? run}) : _run = run ?? runProcess;

  final RunProcess _run;

  /// The addresses seen by the last [printers] call, by display name.
  final Map<String, String> _uris = <String, String>{};

  Future<ProcessResult?> _try(String exe, List<String> args) async {
    try {
      return await _run(exe, args);
    } on ProcessException {
      return null;
    }
  }

  /// "Canon MF110/910|ipp://host.local:631/ipp/print" lines from `ippfind`.
  static List<(String, String)> parseFound(String output) {
    final found = <(String, String)>[];
    for (final line in LineSplitter.split(output)) {
      final at = line.lastIndexOf('|');
      if (at <= 0) continue;
      final name = line.substring(0, at).trim();
      final uri = line.substring(at + 1).trim();
      if (name.isNotEmpty && uri.startsWith('ipp')) found.add((name, uri));
    }
    return found;
  }

  @override
  Future<List<PrinterInfo>> printers() async {
    final result = await _try('ippfind', const <String>[
      '-T',
      '4',
      '-x',
      'echo',
      '{service_name}|{service_uri}',
      ';',
    ]);
    if (result == null || result.exitCode != 0) return const <PrinterInfo>[];
    _uris.clear();
    final list = <PrinterInfo>[];
    for (final (name, uri) in parseFound('${result.stdout}')) {
      final shown = '$name (tarmoq)';
      if (_uris.containsKey(shown)) continue;
      _uris[shown] = uri;
      final caps = await _capabilities(uri);
      list.add(
        PrinterInfo(shown, uri: uri, color: caps.color, duplex: caps.duplex),
      );
    }
    return list;
  }

  bool owns(String printer) => _uris.containsKey(printer);

  /// `ipptool` output: "color-supported (boolean) = false", "sides-supported
  /// (keyword) = one-sided,two-sided-long-edge".
  static ({bool? color, bool? duplex}) parseCapabilities(String output) {
    final color = RegExp(
      r'color-supported \(boolean\) = (true|false)',
    ).firstMatch(output);
    final sides = RegExp(
      r'sides-supported \(keyword\) = (\S+)',
    ).firstMatch(output);
    return (
      color: switch (color?.group(1)) {
        'true' => true,
        'false' => false,
        _ => null,
      },
      duplex: sides?.group(1)?.contains('two-sided'),
    );
  }

  /// Asks the printer a short question (some answer nothing to a long one).
  Future<({bool? color, bool? duplex})> _capabilities(String uri) async {
    final file = File(
      '${Directory.systemTemp.path}/expertedu_caps_${uri.hashCode.abs()}.test',
    );
    try {
      file.writeAsStringSync(_capabilitiesTest);
      final result = await _try('ipptool', <String>[
        '-tv',
        '-T',
        '5',
        uri,
        file.path,
      ]);
      if (result == null || result.exitCode != 0) {
        return (color: null, duplex: null);
      }
      return parseCapabilities('${result.stdout}');
    } catch (_) {
      return (color: null, duplex: null);
    } finally {
      try {
        file.deleteSync();
      } catch (_) {}
    }
  }

  static const _capabilitiesTest = '''
{
  OPERATION Get-Printer-Attributes
  GROUP operation-attributes-tag
  ATTR charset attributes-charset utf-8
  ATTR language attributes-natural-language en
  ATTR uri printer-uri \$uri
  ATTR keyword requested-attributes color-supported,sides-supported
  STATUS successful-ok
}
''';

  @override
  Future<String?> problem() async {
    if (_uris.isEmpty) return null;
    for (final tool in <String>['gs', 'ipptool']) {
      final found = await _try('which', <String>[tool]);
      if (found == null || found.exitCode != 0) {
        return tool == 'gs'
            ? 'Ghostscript (gs) o\'rnatilmagan: sudo dnf install ghostscript'
            : 'ipptool o\'rnatilmagan: sudo dnf install cups-ipptool';
      }
    }
    return null;
  }

  /// Ghostscript's arguments: A4, 600 dpi (what such printers list for PWG
  /// raster), grayscale, each page fitted to the sheet.
  static List<String> rasterArguments(String pdf, String output) => <String>[
    '-q',
    '-dNOPAUSE',
    '-dBATCH',
    '-dSAFER',
    '-sDEVICE=pwgraster',
    '-r600',
    '-sPAPERSIZE=a4',
    '-dFIXEDMEDIA',
    '-dPDFFitPage',
    '-sColorModel=sgray',
    '-sOutputFile=$output',
    pdf,
  ];

  /// `ipptool`'s arguments for sending a raster file as a print job.
  static List<String> sendArguments(String raster, String uri) => <String>[
    '-f',
    raster,
    '-d',
    'filetype=image/pwg-raster',
    '-t',
    uri,
    'print-job.test',
  ];

  @override
  Future<void> print(String printer, PrintRequest request) async {
    final uri = _uris[printer];
    if (uri == null) throw PrintFailure('«$printer» printeri topilmadi.');
    final raster = '${request.path}.pwg';
    try {
      final converted = await _try('gs', rasterArguments(request.path, raster));
      if (converted == null) {
        throw const PrintFailure(
          'Ghostscript (gs) o\'rnatilmagan: sudo dnf install ghostscript',
        );
      }
      if (converted.exitCode != 0) {
        throw const PrintFailure('PDF ni chop etishga tayyorlab bo\'lmadi.');
      }
      // The printer has no "copies" it can be asked for here: one job per copy.
      for (var copy = 0; copy < request.copies; copy++) {
        final sent = await _try('ipptool', sendArguments(raster, uri));
        if (sent == null) {
          throw const PrintFailure(
            'ipptool o\'rnatilmagan: sudo dnf install cups-ipptool',
          );
        }
        if (sent.exitCode != 0 || !'${sent.stdout}'.contains('[PASS]')) {
          throw PrintFailure(
            '«$printer» printeri javob bermadi (yoqilganini va tarmoqqa '
            'ulanganini tekshiring).',
          );
        }
      }
    } finally {
      try {
        File(raster).deleteSync();
      } catch (_) {}
    }
  }
}

/// Linux: the printers CUPS has installed, plus the ones only found on the
/// network (printed to directly). A printer both ways is offered once, as CUPS's.
class LinuxPrintDriver implements PrintDriver {
  LinuxPrintDriver({CupsPrintDriver? cups, DirectIppPrintDriver? direct})
    : _cups = cups ?? CupsPrintDriver(),
      _direct = direct ?? DirectIppPrintDriver();

  final CupsPrintDriver _cups;
  final DirectIppPrintDriver _direct;

  static String _key(String name) =>
      name.toLowerCase().replaceAll(RegExp(r'\(tarmoq\)|[^a-z0-9]'), '');

  @override
  Future<List<PrinterInfo>> printers() async {
    final installed = await _cups.printers();
    final seen = installed.map((p) => _key(p.name)).toSet();
    final network = (await _direct.printers()).where(
      (p) => !seen.contains(_key(p.name)),
    );
    return <PrinterInfo>[...installed, ...network];
  }

  @override
  Future<String?> problem() async {
    final direct = await _direct.problem();
    if (direct != null) return direct;
    if ((await printers()).isNotEmpty) return null;
    return _cups.problem();
  }

  @override
  Future<void> print(String printer, PrintRequest request) {
    if (_direct.owns(printer)) return _direct.print(printer, request);
    return _cups.print(printer, request);
  }
}
