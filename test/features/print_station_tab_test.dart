import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/settings/presentation/print_station_tab.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:expert_edu_center/services/printing/print_driver.dart';
import 'package:expert_edu_center/services/printing/print_station.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

class _NoTokens extends TokenStorage {
  @override
  Future<String?> readToken() async => null;
}

class _NoPrinters implements PrintDriver {
  @override
  Future<List<PrinterInfo>> printers() async => const <PrinterInfo>[];

  @override
  Future<String?> problem() async => null;

  @override
  Future<void> print(String printer, PrintRequest request) async {}
}

/// The station without the file system, the network or a printer: the tab is what is tested.
class _FakeStation extends PrintStation {
  _FakeStation()
    : super(
        api: ApiClient(_NoTokens()),
        driver: _NoPrinters(),
        signedIn: () => true,
      ) {
    printers = const <PrinterInfo>[
      PrinterInfo('Office'),
      PrinterInfo('Hall', isDefault: true, color: false, duplex: false),
    ];
    printer = 'Hall';
    history = <PrintHistoryEntry>[
      PrintHistoryEntry(
        id: 1,
        title: 'Headway Unit 3.pdf',
        summary: '1-5, 8',
        pages: 6,
        copies: 2,
        requestedBy: 'Madina Karimova',
        role: 'teacher',
        status: 'done',
        error: null,
        createdAt: DateTime(2026, 10, 19, 9, 5),
      ),
      PrintHistoryEntry(
        id: 2,
        title: 'Vocabulary.pdf',
        summary: null,
        pages: 1,
        copies: 1,
        requestedBy: 'Jasur',
        role: 'admin',
        status: 'queued',
        error: null,
        createdAt: DateTime(2026, 10, 19, 9, 10),
      ),
      PrintHistoryEntry(
        id: 3,
        title: 'Old.pdf',
        summary: null,
        pages: 1,
        copies: 1,
        requestedBy: 'Jasur',
        role: 'admin',
        status: 'failed',
        error: 'Qog\'oz tugadi',
        createdAt: DateTime(2026, 10, 19, 8, 0),
      ),
    ];
  }

  final List<bool> switched = <bool>[];
  final List<int> cancelled = <int>[];
  String? testResult;
  int tests = 0;

  @override
  Future<void> start() async {}

  @override
  Future<void> setColor(bool? value) async {
    colorOverride = value;
    notifyListeners();
  }

  @override
  Future<void> setDuplex(bool? value) async {
    duplexOverride = value;
    notifyListeners();
  }

  @override
  Future<void> setEnabled(bool value) async {
    switched.add(value);
    enabled = value;
    notifyListeners();
  }

  @override
  Future<void> setPrinter(String? name) async {
    printer = name;
    notifyListeners();
  }

  @override
  Future<String?> printTestPage() async {
    tests++;
    return testResult;
  }

  @override
  Future<String?> cancel(int jobId) async {
    cancelled.add(jobId);
    return null;
  }

  @override
  Future<void> loadHistory() async {}

  @override
  Future<void> refreshPrinters() async {}
}

Future<void> _pump(
  WidgetTester tester,
  _FakeStation station, {
  double width = 900,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [printStationProvider.overrideWithValue(station)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: PrintStationTab()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('the station is off until it is switched on, and then says so', (
    tester,
  ) async {
    final station = _FakeStation();
    await _pump(tester, station);
    expect(find.text('O\'chiq'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('print-enabled')));
    await tester.pumpAndSettle();
    expect(station.switched, [true]);
    expect(find.text('Yoqilgan'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the printer is chosen from the PC\'s printers, the default first picked',
    (tester) async {
      final station = _FakeStation();
      await _pump(tester, station);
      expect(find.text('Hall'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('print-printer')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Office').last);
      await tester.pumpAndSettle();
      expect(station.printer, 'Office');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a missing printing program is shown', (tester) async {
    final station = _FakeStation()..problem = 'SumatraPDF topilmadi.';
    await _pump(tester, station);
    expect(find.byKey(const ValueKey('print-problem')), findsOneWidget);
    expect(find.text('SumatraPDF topilmadi.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the test page can be printed and says how it went', (
    tester,
  ) async {
    final station = _FakeStation()..testResult = '«Hall» printeri xato berdi.';
    await _pump(tester, station);
    await tester.tap(find.byKey(const ValueKey('print-test')));
    await tester.pumpAndSettle();
    expect(station.tests, 1);
    expect(find.text('«Hall» printeri xato berdi.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'who printed what is listed; only a waiting job can be cancelled',
    (tester) async {
      final station = _FakeStation();
      await _pump(tester, station);
      expect(find.text('Headway Unit 3.pdf'), findsOneWidget);
      expect(find.textContaining('Madina Karimova'), findsOneWidget);
      expect(find.text('Yuborildi'), findsOneWidget);
      expect(find.text('Navbatda'), findsOneWidget);
      expect(find.text('Qog\'oz tugadi'), findsOneWidget);
      expect(find.byKey(const ValueKey('print-cancel-1')), findsNothing);
      expect(find.byKey(const ValueKey('print-cancel-3')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('print-cancel-2')));
      await tester.pumpAndSettle();
      expect(station.cancelled, [2]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'what the printer can do is shown as detected and can be set by hand',
    (tester) async {
      final station = _FakeStation();
      await _pump(tester, station);
      expect(find.text('Avtomatik (yo\'q)'), findsNWidgets(2));
      await tester.tap(find.byKey(const ValueKey('print-color')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ha').last);
      await tester.pumpAndSettle();
      expect(station.colorOverride, true);
      expect(station.duplexOverride, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a narrow window does not overflow', (tester) async {
    await _pump(tester, _FakeStation(), width: 420);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
