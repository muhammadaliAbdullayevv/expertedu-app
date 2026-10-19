import 'dart:convert';
import 'dart:io';

import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:expert_edu_center/services/printing/print_driver.dart';
import 'package:expert_edu_center/services/printing/print_station.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _NoTokens extends TokenStorage {
  @override
  Future<String?> readToken() async => 'token';
}

class _FakeDriver implements PrintDriver {
  List<PrinterInfo> list = <PrinterInfo>[
    const PrinterInfo('Office'),
    const PrinterInfo('Hall', isDefault: true),
  ];
  String? missing;
  PrintFailure? fail;
  final List<PrintRequest> printed = <PrintRequest>[];
  final List<String> printers_ = <String>[];
  final List<bool> existedWhilePrinting = <bool>[];
  final List<List<int>> contents = <List<int>>[];

  @override
  Future<List<PrinterInfo>> printers() async => list;

  @override
  Future<String?> problem() async => missing;

  @override
  Future<void> print(String printer, PrintRequest request) async {
    printers_.add(printer);
    printed.add(request);
    final file = File(request.path);
    existedWhilePrinting.add(file.existsSync());
    contents.add(file.readAsBytesSync());
    if (fail != null) throw fail!;
  }
}

class _Server {
  _Server();

  final List<http.Request> requests = <http.Request>[];
  Map<String, Object?>? next;
  int resultFailures = 0;

  Future<http.Response> handle(http.Request r) async {
    requests.add(r);
    final path = r.url.path;
    if (path == '/print/next') {
      final job = next;
      next = null;
      return job == null
          ? http.Response('', 204)
          : http.Response(jsonEncode(job), 200);
    }
    if (path.endsWith('/file')) return http.Response('%PDF-fake', 200);
    if (path.endsWith('/result')) {
      if (resultFailures > 0) {
        resultFailures--;
        throw const SocketException('down');
      }
      return http.Response('', 204);
    }
    if (path == '/print') {
      return http.Response(
        jsonEncode(<Object>[
          <String, Object?>{
            'id': 3,
            'title': 'Book.pdf',
            'summary': '1-5',
            'pages': 5,
            'copies': 2,
            'requested_by': 'Madina',
            'requested_role': 'teacher',
            'status': 'done',
            'error': null,
            'created_at': '2026-10-19T04:00:00+00:00',
          },
        ]),
        200,
      );
    }
    return http.Response('{}', 404);
  }

  List<http.Request> to(String suffix) =>
      requests.where((r) => r.url.path.endsWith(suffix)).toList();
}

Map<String, Object?> _job({
  int id = 7,
  int copies = 2,
  bool duplex = true,
  bool color = false,
}) => <String, Object?>{
  'id': id,
  'title': 'Headway.pdf',
  'summary': '1-3',
  'pages': 3,
  'copies': copies,
  'duplex': duplex,
  'color': color,
  'landscape': false,
  'requested_by': 'Madina',
};

void main() {
  late Directory dir;
  late _FakeDriver driver;
  late _Server server;
  var signedIn = true;

  PrintStation make({bool enabledHere = true}) => PrintStation(
    api: ApiClient(_NoTokens(), MockClient(server.handle)),
    driver: driver,
    signedIn: () => signedIn,
    enabledHere: enabledHere,
    configDirectory: () async => dir,
    tempDirectory: () async => dir,
    pollEvery: const Duration(hours: 1), // ticks are called by hand
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('print_station_test');
    driver = _FakeDriver();
    server = _Server();
    signedIn = true;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'the first start picks the PC\'s default printer and stays switched off',
    () async {
      final station = make();
      await station.start();
      expect(station.printer, 'Hall');
      expect(station.enabled, isFalse);
      expect(station.running, isFalse);
      await station.tick();
      expect(server.requests, isEmpty); // off: it does not even say "I'm here"
      station.dispose();
    },
  );

  test(
    'switched on, it takes a job, prints it with its options, reports and removes the file',
    () async {
      final station = make();
      await station.start();
      await station.setEnabled(true);
      server.requests.clear();
      server.next = _job();
      await station.tick();

      expect(driver.printers_, ['Hall']);
      final request = driver.printed.single;
      expect((request.copies, request.duplex, request.color), (2, true, false));
      expect(driver.existedWhilePrinting.single, isTrue);
      expect(utf8.decode(driver.contents.single), '%PDF-fake');
      expect(
        File(request.path).existsSync(),
        isFalse,
      ); // nothing is left behind

      final call = server.to('/print/next').single;
      expect(call.method, 'POST');
      expect(call.url.queryParameters['printer'], 'Hall');
      final result = jsonDecode(server.to('/result').single.body) as Map;
      expect(result['ok'], isTrue);
      expect(station.status, startsWith('Printerga yuborildi'));
      station.dispose();
    },
  );

  test('when printing fails the server is told why', () async {
    driver.fail = const PrintFailure('«Hall» printeri xato berdi.');
    final station = make();
    await station.start();
    await station.setEnabled(true);
    server.next = _job();
    await station.tick();
    final result = jsonDecode(server.to('/result').single.body) as Map;
    expect(result, {'ok': false, 'error': '«Hall» printeri xato berdi.'});
    expect(station.status, contains('Chop etilmadi'));
    expect(station.current, isNull);
    station.dispose();
  });

  test('no waiting job means nothing is printed', () async {
    final station = make();
    await station.start();
    await station.setEnabled(true);
    await station.tick();
    expect(driver.printed, isEmpty);
    expect(station.status, 'Topshiriq kutilmoqda.');
    station.dispose();
  });

  test('signed out, it does nothing', () async {
    final station = make();
    await station.start();
    await station.setEnabled(true);
    server.requests.clear();
    signedIn = false;
    server.next = _job();
    await station.tick();
    expect(server.requests, isEmpty);
    expect(driver.printed, isEmpty);
    station.dispose();
  });

  test(
    'a lost connection while reporting is tried again, and the job is not printed twice',
    () async {
      final station = make();
      await station.start();
      await station.setEnabled(true);
      server.next = _job();
      server.resultFailures = 1;
      await station.tick();
      expect(driver.printed, hasLength(1));
      expect(server.to('/result'), hasLength(2));
      station.dispose();
    },
  );

  test('the choice is remembered by the next start', () async {
    final first = make();
    await first.start();
    await first.setPrinter('Office');
    await first.setEnabled(true);
    first.dispose();

    final second = make();
    await second.start();
    expect((second.enabled, second.printer), (true, 'Office'));
    second.dispose();
  });

  test(
    'every round says what the printer can do, when that is known',
    () async {
      driver.list = <PrinterInfo>[
        const PrinterInfo('Hall', isDefault: true, color: false, duplex: false),
      ];
      final station = make();
      await station.start();
      await station.setEnabled(true);
      final query = server.to('/print/next').last.url.queryParameters;
      expect(
        (query['printer'], query['color'], query['duplex']),
        ('Hall', 'false', 'false'),
      );
      station.dispose();
    },
  );

  test('what is not known is not claimed either way', () async {
    final station = make();
    await station.start();
    await station.setEnabled(true);
    final query = server.to('/print/next').last.url.queryParameters;
    expect(query.containsKey('color') || query.containsKey('duplex'), isFalse);
    station.dispose();
  });

  test(
    'what the person at the PC says wins over the detection, and is remembered',
    () async {
      driver.list = <PrinterInfo>[
        const PrinterInfo('Hall', isDefault: true, color: false, duplex: false),
      ];
      final first = make();
      await first.start();
      await first.setColor(
        true,
      ); // "it does colour, the driver just does not say so"
      await first.setEnabled(true);
      final query = server.to('/print/next').last.url.queryParameters;
      expect((query['color'], query['duplex']), ('true', 'false'));
      first.dispose();

      final second = make();
      await second.start();
      expect(
        (
          second.colorOverride,
          second.duplexOverride,
          second.color,
          second.duplex,
        ),
        (true, null, true, false),
      );
      await second.setColor(null); // back to automatic
      expect(second.color, false);
      second.dispose();
    },
  );

  test('a PC that cannot be a station (a phone) never starts', () async {
    final station = make(enabledHere: false);
    await station.start();
    await station.setEnabled(true);
    await station.tick();
    expect(station.printers, isEmpty);
    station.dispose();
  });

  test('a missing printing program is reported', () async {
    driver.missing = 'SumatraPDF topilmadi.';
    final station = make();
    await station.start();
    expect(station.problem, 'SumatraPDF topilmadi.');
    station.dispose();
  });

  test('the test page goes to the chosen printer', () async {
    final station = make();
    await station.start();
    expect(await station.printTestPage(), isNull);
    expect(driver.printers_, ['Hall']);
    expect(utf8.decode(driver.contents.single).startsWith('%PDF-1.4'), isTrue);
    driver.fail = const PrintFailure('o\'chiq');
    expect(await station.printTestPage(), 'o\'chiq');
    station.dispose();
  });

  test('the history is read from the server', () async {
    final station = make();
    await station.start();
    await station.loadHistory();
    final entry = station.history.single;
    expect(
      (entry.title, entry.requestedBy, entry.pages, entry.copies, entry.status),
      ('Book.pdf', 'Madina', 5, 2, 'done'),
    );
    station.dispose();
  });
}
