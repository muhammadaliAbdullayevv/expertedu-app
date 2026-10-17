// Screenshot harness, not a regression test: draws the signed-in shell
// against a LOCAL demo server and writes PNGs, so the layout can be set
// beside docs/v2-design. Opt-in; skipped unless run like
//
//   flutter test test/tool/render_shell_test.dart \
//     --dart-define=API_BASE_URL=http://127.0.0.1:8765 \
//     --dart-define=RENDER_OUT=/some/dir
//
// Never point it at production.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/admissions/presentation/qabul_widgets.dart';
import 'package:expert_edu_center/features/auth/application/session_controller.dart';
import 'package:expert_edu_center/features/dashboard/presentation/home_shell.dart';
import 'package:expert_edu_center/services/api/token_storage.dart';
import 'package:expert_edu_center/services/local_db/local_database.dart';
import 'package:expert_edu_center/services/sync/connectivity_service.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/load_fonts.dart';

const _out = String.fromEnvironment('RENDER_OUT');
const _only = String.fromEnvironment('RENDER_ONLY');
const _w = int.fromEnvironment('RENDER_W', defaultValue: 1440);
const _h = int.fromEnvironment('RENDER_H', defaultValue: 900);
const _phone = String.fromEnvironment(
  'RENDER_PHONE',
  defaultValue: '998900000001',
);

class _MemoryTokens extends TokenStorage {
  String? _token;
  String? _accounts;

  @override
  Future<String?> readToken() async => _token;
  @override
  Future<void> saveToken(String token) async => _token = token;
  @override
  Future<void> clearToken() async => _token = null;
  @override
  Future<String?> readSavedAccountsRaw() async => _accounts;
  @override
  Future<void> saveSavedAccountsRaw(String json) async => _accounts = json;
  @override
  Future<String?> readLastFcmToken() async => null;
}

class _NoConnectivity extends ConnectivityService {
  @override
  Stream<bool> get onLinkChanged => const Stream<bool>.empty();
}

void main() {
  sqfliteFfiInit();
  final key = GlobalKey();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shot(WidgetTester tester, String name) async {
    await settle(tester);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_out/$name.png').writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  Future<void> qabulScenes(
    WidgetTester tester,
    Future<void> Function(WidgetTester, String) shot,
    Future<void> Function(WidgetTester) settle,
  ) async {
    Finder firstGroup() => find
        .byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('group-') &&
              (w.key! as ValueKey<String>).value != 'group-none',
        )
        .first;
    final stamp = DateTime.now().millisecondsSinceEpoch % 100000;
    String phone(int n) => '9${(10000000 + stamp * 10 + n) % 100000000}'
        .padRight(9, '0')
        .substring(0, 9);

    Future<void> type(String key, String text) async {
      await tester.enterText(find.byKey(ValueKey(key)), text);
      await tester.pump();
    }

    await tester.tap(find.text('Qabul').first);
    await shot(tester, 'qabul-add');
    await type('qabul-group-search', 'ingliz');
    await shot(tester, 'qabul-add-search');
    await tester.tap(firstGroup());
    await type('qabul-first', 'Render');
    await type('qabul-last', 'Mijoz');
    await type('qabul-phone', '935551234'); // a student of the demo center
    await type('qabul-parent-phone', '905550000');
    await type('qabul-address', 'Chilonzor, 7-kvartal');
    await settle(tester);
    await shot(tester, 'qabul-add-warning');
    await type('qabul-phone', phone(1));
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await shot(tester, 'qabul-add-saved');
    await tester.ensureVisible(find.byKey(const ValueKey('save-groupless')));
    await tester.tap(find.byKey(const ValueKey('save-groupless')));
    await settle(tester);
    await tester.tap(find.widgetWithText(OptionPill, 'Fransuz tili').first);
    await tester.tap(find.widgetWithText(OptionPill, 'Beginner').first);
    await type('wish-note', 'kechqurun, du-chor-ju');
    await shot(tester, 'qabul-add-groupless');
    await type('qabul-first', 'Kutuvchi');
    await type('qabul-last', 'Odam');
    await type('qabul-phone', phone(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('view-list')));
    await shot(tester, 'qabul-list');
    await tester.tap(find.byKey(const ValueKey('view-add')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('fill-schedules')));
    await settle(tester);
    await settle(tester);
    await shot(tester, 'qabul-schedules');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
  }

  testWidgets('render the shell', (tester) async {
    await loadAppFonts();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    PackageInfo.setMockInitialValues(
      appName: 'x',
      packageName: 'x',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
      installerStore: null,
    );
    HttpOverrides.global = null;
    final container = ProviderContainer(
      overrides: [
        tokenStorageProvider.overrideWithValue(_MemoryTokens()),
        connectivityServiceProvider.overrideWithValue(_NoConnectivity()),
        localDatabaseProvider.overrideWithValue(
          LocalDatabase(
            factory: databaseFactoryFfiNoIsolate,
            path: inMemoryDatabasePath,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    final session = container.read(sessionControllerProvider);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    final ok = await tester.runAsync(
      () => session.login(phone: _phone, password: 'demo1234'),
    );
    expect(ok, isTrue, reason: session.errorText);

    Future<void> mount(Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.light(),
              home: const HomeShell(),
            ),
          ),
        ),
      );
    }

    await mount(Size(_w.toDouble(), _h.toDouble()));
    await shot(tester, 'desktop-bugun');

    if (_only == 'students') {
      await tester.tap(find.text('O\'quvchilar').first);
      await shot(tester, 'students-table');
      await tester.tap(find.byKey(const ValueKey('panel-tab-1')));
      await shot(tester, 'students-payments');
      await tester.tap(find.byKey(const ValueKey('panel-tab-2')));
      await shot(tester, 'students-attendance');
      await tester.tap(find.byKey(const ValueKey('panel-tab-0')));
      await tester.tap(find.byKey(const ValueKey('panel-pay')));
      await settle(tester);
      await shot(tester, 'students-pay-dialog');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('panel-add-group')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('add-group-search')),
        'a',
      );
      await settle(tester);
      await shot(tester, 'students-add-group');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('panel-edit')));
      await settle(tester);
      await shot(tester, 'students-edit');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('tab-debtors')));
      await shot(tester, 'students-debtors');
      return;
    }

    if (_only == 'qabul') {
      await qabulScenes(tester, shot, settle);
      return;
    }

    if (_only.isEmpty) {
      for (final (label, file) in [
        ('Qabul', 'desktop-qabul'),
        ('O\'quvchilar', 'desktop-oquvchilar'),
        ('Jadval', 'desktop-jadval'),
        ('Guruhlar', 'desktop-guruhlar'),
        ('O\'qituvchilar', 'desktop-oqituvchilar'),
        ('Moliya', 'desktop-moliya'),
        ('Hisobotlar', 'desktop-hisobotlar'),
        ('Sozlamalar', 'desktop-sozlamalar'),
      ]) {
        await tester.tap(find.text(label).first);
        await shot(tester, file);
      }

      await tester.tap(find.text('Bugun').first);
      await settle(tester);
      // Narrow desktop window: the icon rail.
      await mount(const Size(1000, 700));
      await shot(tester, 'desktop-narrow');
    }

    // A very narrow desktop window still gets the desktop layout.
    await mount(const Size(700, 700));
    await shot(tester, 'desktop-narrower');
  }, skip: _out.isEmpty);
}
