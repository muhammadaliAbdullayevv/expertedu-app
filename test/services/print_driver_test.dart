import 'dart:convert';
import 'dart:io';

import 'package:expert_edu_center/services/printing/print_driver.dart';
import 'package:expert_edu_center/services/printing/test_page.dart';
import 'package:flutter_test/flutter_test.dart';

ProcessResult _ok([String out = '', int code = 0, String err = '']) =>
    ProcessResult(1, code, out, err);

void main() {
  group('Windows (SumatraPDF)', () {
    test('PowerShell lists one printer as an object, several as a list', () {
      final one = WindowsPrintDriver.parsePrinters(
        '{"Name":"HP LaserJet","Default":true}',
      );
      expect(one.map((p) => (p.name, p.isDefault)), [('HP LaserJet', true)]);
      final many = WindowsPrintDriver.parsePrinters(
        '[{"Name":"Microsoft Print to PDF","Default":false},{"Name":"Canon \u0414\u0430","Default":true}]',
      );
      expect(many.map((p) => p.name), [
        'Microsoft Print to PDF',
        'Canon \u0414\u0430',
      ]);
      expect(many[1].isDefault, isTrue);
      expect(WindowsPrintDriver.parsePrinters('  '), isEmpty);
    });

    test('copies, sides and colour become SumatraPDF print settings', () {
      String s(PrintRequest r) => WindowsPrintDriver.settings(r);
      expect(s(const PrintRequest(path: 'a.pdf')), '1x,simplex,monochrome');
      expect(
        s(
          const PrintRequest(
            path: 'a.pdf',
            copies: 3,
            duplex: true,
            color: true,
          ),
        ),
        '3x,duplexlong,color',
      );
    });

    test(
      'it prints silently to the chosen printer with those settings',
      () async {
        final calls = <(String, List<String>)>[];
        final driver = WindowsPrintDriver(
          run: (exe, args) async {
            calls.add((exe, args));
            return _ok();
          },
          executable: r'C:\App\expert_edu_center.exe',
          environment: const <String, String>{},
          exists: (path) =>
              path.endsWith(r'tools\SumatraPDF.exe') ||
              path.endsWith('tools/SumatraPDF.exe'),
        );
        await driver.print(
          'HP LaserJet 400',
          const PrintRequest(path: r'C:\Temp\job.pdf', copies: 2, duplex: true),
        );
        final (exe, args) = calls.single;
        expect(exe, endsWith('SumatraPDF.exe'));
        expect(args, [
          '-print-to',
          'HP LaserJet 400',
          '-print-settings',
          '2x,duplexlong,monochrome',
          '-silent',
          r'C:\Temp\job.pdf',
        ]);
      },
    );

    test(
      'SumatraPDF is looked for beside the app first, then where it installs',
      () {
        final driver = WindowsPrintDriver(
          run: (_, _) async => _ok(),
          executable: '/app/expert_edu_center.exe',
          environment: const <String, String>{
            'ProgramFiles': '/pf',
            'LOCALAPPDATA': '/local',
          },
          exists: (_) => false,
        );
        final found = driver.sumatraCandidates;
        expect(found.first, contains('tools'));
        expect(found.any((p) => p.startsWith('/pf')), isTrue);
        expect(found.any((p) => p.startsWith('/local')), isTrue);
      },
    );

    test(
      'no SumatraPDF: a plain explanation, and printing fails with it',
      () async {
        final driver = WindowsPrintDriver(
          run: (_, _) async => _ok(),
          executable: '/app/x.exe',
          environment: const <String, String>{},
          exists: (_) => false,
        );
        expect(await driver.problem(), contains('SumatraPDF'));
        await expectLater(
          driver.print('P', const PrintRequest(path: 'a.pdf')),
          throwsA(isA<PrintFailure>()),
        );
      },
    );

    test('its exit codes are explained', () {
      expect(WindowsPrintDriver.failureMessage(0, 'P'), isNull);
      expect(WindowsPrintDriver.failureMessage(4, 'HP'), contains('HP'));
      expect(WindowsPrintDriver.failureMessage(5, 'HP'), contains('xato'));
      expect(WindowsPrintDriver.failureMessage(99, 'HP'), contains('99'));
    });

    test('a refused print is a PrintFailure', () async {
      final driver = WindowsPrintDriver(
        run: (_, _) async => _ok('', 4),
        executable: '/app/x.exe',
        environment: const <String, String>{},
        exists: (_) => true,
      );
      await expectLater(
        driver.print('Gone', const PrintRequest(path: 'a.pdf')),
        throwsA(
          isA<PrintFailure>().having(
            (e) => e.message,
            'message',
            contains('Gone'),
          ),
        ),
      );
    });

    test('printers come from PowerShell', () async {
      final driver = WindowsPrintDriver(
        run: (exe, args) async {
          expect(exe, 'powershell.exe');
          return _ok('{"Name":"HP","Default":true}');
        },
        executable: '/app/x.exe',
        environment: const <String, String>{},
        exists: (_) => true,
      );
      expect((await driver.printers()).single.name, 'HP');
    });
  });

  group('Linux (CUPS)', () {
    test('lp gets the copies, sides and colour', () {
      expect(
        CupsPrintDriver.arguments(
          'Office',
          const PrintRequest(
            path: '/t/a.pdf',
            copies: 2,
            duplex: true,
            color: true,
          ),
        ),
        [
          '-d',
          'Office',
          '-n',
          '2',
          '-o',
          'sides=two-sided-long-edge',
          '-o',
          'print-color-mode=color',
          '/t/a.pdf',
        ],
      );
      expect(
        CupsPrintDriver.arguments(
          'Office',
          const PrintRequest(path: '/t/a.pdf'),
        ),
        contains('sides=one-sided'),
      );
    });

    test('only installed printers are listed, the default marked', () async {
      final driver = CupsPrintDriver(
        run: (exe, args) async => switch (args.first) {
          '-p' => _ok(
            'printer Office is idle.  enabled since Mon\nprinter PDF is idle.  enabled since Mon\n',
          ),
          '-d' => _ok('system default destination: PDF\n'),
          _ => _ok(),
        },
      );
      final printers = await driver.printers();
      expect(printers.map((p) => (p.name, p.isDefault)), [
        ('Office', false),
        ('PDF', true),
      ]);
      expect(await driver.problem(), isNull);
    });

    test(
      'a printer only discovered on the network is not a CUPS printer',
      () async {
        final driver = CupsPrintDriver(
          run: (exe, args) async => switch (args.first) {
            '-p' => _ok('', 1, 'lpstat: No destinations added.'),
            _ => _ok('', 1),
          },
        );
        expect(await driver.printers(), isEmpty);
      },
    );

    test('CUPS not running is explained', () async {
      final driver = CupsPrintDriver(run: (exe, args) async => _ok('', 1));
      expect(await driver.problem(), contains('ishlamayapti'));
    });

    test('"no such file" for a PDF that exists is about the printer', () async {
      final driver = CupsPrintDriver(
        run: (_, _) async => _ok('', 1, 'lp: No such file or directory'),
        exists: (_) => true,
      );
      await expectLater(
        driver.print('Canon_MF110_910', const PrintRequest(path: '/tmp/a.pdf')),
        throwsA(
          isA<PrintFailure>().having(
            (e) => e.message,
            'message',
            contains('tizimga qo\'shilmagan'),
          ),
        ),
      );
    });

    test('a failed lp is explained with what it said', () async {
      final driver = CupsPrintDriver(
        run: (_, _) async =>
            _ok('', 1, 'lp: The printer or class does not exist.'),
      );
      await expectLater(
        driver.print('X', const PrintRequest(path: 'a.pdf')),
        throwsA(
          isA<PrintFailure>().having(
            (e) => e.message,
            'message',
            contains('does not exist'),
          ),
        ),
      );
    });
  });

  group('Linux, printers only found on the network (direct IPP)', () {
    const found = 'Canon MF110/910|ipp://Canon005d73.local:631/ipp/print\n';

    test('ippfind lines are read, odd ones skipped', () {
      expect(
        DirectIppPrintDriver.parseFound(
          '$found\nnonsense\n|ipp://x\nName|http://no\n',
        ),
        [('Canon MF110/910', 'ipp://Canon005d73.local:631/ipp/print')],
      );
    });

    test('they are listed with their address', () async {
      final driver = DirectIppPrintDriver(run: (_, _) async => _ok(found));
      final printers = await driver.printers();
      expect(printers.single.name, 'Canon MF110/910 (tarmoq)');
      expect(printers.single.uri, 'ipp://Canon005d73.local:631/ipp/print');
      expect(driver.owns('Canon MF110/910 (tarmoq)'), isTrue);
    });

    test(
      'a PDF is rastered as A4 grayscale and sent as one IPP job per copy',
      () async {
        final calls = <(String, List<String>)>[];
        final driver = DirectIppPrintDriver(
          run: (exe, args) async {
            calls.add((exe, args));
            return exe == 'ipptool'
                ? _ok('print-job.test  [PASS]')
                : _ok(found);
          },
        );
        await driver.printers();
        calls.clear();
        await driver.print(
          'Canon MF110/910 (tarmoq)',
          const PrintRequest(path: '/tmp/job.pdf', copies: 2),
        );
        expect(calls.map((c) => c.$1), ['gs', 'ipptool', 'ipptool']);
        expect(
          calls.first.$2,
          containsAll([
            '-sDEVICE=pwgraster',
            '-sPAPERSIZE=a4',
            '-sColorModel=sgray',
            '-r600',
            '/tmp/job.pdf',
          ]),
        );
        expect(calls.first.$2, contains('-sOutputFile=/tmp/job.pdf.pwg'));
        expect(calls[1].$2, [
          '-f',
          '/tmp/job.pdf.pwg',
          '-d',
          'filetype=image/pwg-raster',
          '-t',
          'ipp://Canon005d73.local:631/ipp/print',
          'print-job.test',
        ]);
      },
    );

    test('a printer that does not answer is a PrintFailure', () async {
      final driver = DirectIppPrintDriver(
        run: (exe, args) async =>
            exe == 'ipptool' ? _ok('print-job.test  [FAIL]', 1) : _ok(found),
      );
      await driver.printers();
      await expectLater(
        driver.print(
          'Canon MF110/910 (tarmoq)',
          const PrintRequest(path: '/tmp/job.pdf'),
        ),
        throwsA(
          isA<PrintFailure>().having(
            (e) => e.message,
            'message',
            contains('javob bermadi'),
          ),
        ),
      );
    });

    test(
      'a PDF Ghostscript cannot read is a PrintFailure and nothing is sent',
      () async {
        final sent = <String>[];
        final driver = DirectIppPrintDriver(
          run: (exe, args) async {
            sent.add(exe);
            return exe == 'gs' ? _ok('', 1) : _ok(found);
          },
        );
        await driver.printers();
        sent.clear();
        await expectLater(
          driver.print(
            'Canon MF110/910 (tarmoq)',
            const PrintRequest(path: '/tmp/job.pdf'),
          ),
          throwsA(isA<PrintFailure>()),
        );
        expect(sent, ['gs']);
      },
    );

    test('missing Ghostscript is explained', () async {
      final driver = DirectIppPrintDriver(
        run: (exe, args) async => switch (exe) {
          'ippfind' => _ok(found),
          'which' => _ok('', args.first == 'gs' ? 1 : 0),
          _ => _ok(),
        },
      );
      await driver.printers();
      expect(await driver.problem(), contains('ghostscript'));
    });

    test(
      'the Linux driver offers CUPS printers and network ones, a printer found both ways once',
      () async {
        final driver = LinuxPrintDriver(
          cups: CupsPrintDriver(
            run: (exe, args) async => args.first == '-p'
                ? _ok(
                    'printer Canon_MF110_910 is idle.\nprinter Office is idle.\n',
                  )
                : _ok(),
          ),
          direct: DirectIppPrintDriver(
            run: (_, _) async => _ok(
              '$found'
              'HP LaserJet|ipp://hp.local:631/ipp/print\n',
            ),
          ),
        );
        expect((await driver.printers()).map((p) => p.name), [
          'Canon_MF110_910',
          'Office',
          'HP LaserJet (tarmoq)',
        ]);
      },
    );
  });

  group('what a printer can do', () {
    test(
      'Windows: the driver\'s capability list says colour (2) and two-sided (3); nothing listed = not known',
      () {
        final printers = WindowsPrintDriver.parsePrinters(
          '[{"Name":"Mono","Default":false,"Capabilities":[4,5]},'
          '{"Name":"Full","Default":true,"Capabilities":[2,3,4]},'
          '{"Name":"Silent","Default":false,"Capabilities":null},'
          '{"Name":"One","Default":false,"Capabilities":2}]',
        );
        expect(printers.map((p) => (p.name, p.color, p.duplex)), [
          ('Mono', false, false),
          ('Full', true, true),
          ('Silent', null, null),
          ('One', true, false),
        ]);
      },
    );

    test('CUPS: options with a two-sided and a colour-model choice', () {
      final full = CupsPrintDriver.parseOptions(
        'PageSize/Media Size: *A4 Letter\nDuplex/Double-Sided Printing: *None DuplexNoTumble\nColorModel/Color Model: Gray *RGB\n',
      );
      expect((full.color, full.duplex), (true, true));
      final mono = CupsPrintDriver.parseOptions(
        'PageSize/Media Size: *A4\nColorModel/Color Model: *Gray\n',
      );
      expect((mono.color, mono.duplex), (false, false));
      final none = CupsPrintDriver.parseOptions('');
      expect((none.color, none.duplex), (null, null));
      // No colour option listed at all is not "no colour": it is not known.
      expect(
        CupsPrintDriver.parseOptions('PageSize/Media Size: *A4\n').color,
        isNull,
      );
    });

    test('direct IPP: the printer\'s own answer', () {
      const mono =
          'color-supported (boolean) = false\n        sides-supported (keyword) = one-sided\n';
      const full =
          'color-supported (boolean) = true\n        sides-supported (1setOf keyword) = one-sided\n';
      final a = DirectIppPrintDriver.parseCapabilities(mono);
      expect((a.color, a.duplex), (false, false));
      final b = DirectIppPrintDriver.parseCapabilities(
        'color-supported (boolean) = true\nsides-supported (keyword) = one-sided,two-sided-long-edge\n',
      );
      expect((b.color, b.duplex), (true, true));
      final c = DirectIppPrintDriver.parseCapabilities('');
      expect((c.color, c.duplex), (null, null));
      expect(full, isNotEmpty);
    });

    test('a network printer is listed with what it said it can do', () async {
      final driver = DirectIppPrintDriver(
        run: (exe, args) async => exe == 'ippfind'
            ? _ok('Canon MF110/910|ipp://c.local:631/ipp/print\n')
            : _ok(
                'color-supported (boolean) = false\nsides-supported (keyword) = one-sided\n',
              ),
      );
      final printer = (await driver.printers()).single;
      expect((printer.color, printer.duplex), (false, false));
    });

    test(
      'a network printer that does not answer the short question is "not known"',
      () async {
        final driver = DirectIppPrintDriver(
          run: (exe, args) async => exe == 'ippfind'
              ? _ok('X|ipp://x.local:631/ipp/print\n')
              : _ok('', 1),
        );
        final printer = (await driver.printers()).single;
        expect((printer.color, printer.duplex), (null, null));
      },
    );
  });

  test('the test page is a well-formed one-page PDF', () {
    final bytes = testPagePdf(
      'HP LaserJet (Hall) \\ \u0416',
      DateTime(2026, 10, 19, 9, 5),
    );
    final text = latin1.decode(bytes);
    expect(text, startsWith('%PDF-1.4'));
    expect(text, contains('Expert Edu Center'));
    expect(text, contains('2026-10-19 09:05'));
    expect(text, contains(r'HP LaserJet \(Hall\) \\ ?'));
    // The cross-reference table points at every object, and startxref at the table.
    final startxref = int.parse(
      RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!,
    );
    expect(text.substring(startxref), startsWith('xref'));
    final offsets = RegExp(
      r'(\d{10}) 00000 n',
    ).allMatches(text).map((m) => int.parse(m.group(1)!)).toList();
    expect(offsets, hasLength(5));
    for (var i = 0; i < offsets.length; i++) {
      expect(text.substring(offsets[i]), startsWith('${i + 1} 0 obj'));
    }
    final length = int.parse(
      RegExp(r'/Length (\d+)').firstMatch(text)!.group(1)!,
    );
    final body = text.substring(
      text.indexOf('stream\n') + 7,
      text.indexOf('\nendstream'),
    );
    expect(body.length, length);
  });
}
