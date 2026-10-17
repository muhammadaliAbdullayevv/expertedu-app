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

import 'package:expert_edu_center/app/shell/top_bar.dart';
import 'package:expert_edu_center/app/theme/app_theme.dart';
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
    await tester.tap(find.text('Qabul').first);
    await shot(tester, 'qabul-board');
    await tester.tap(find.text('Jadval ko\'rinishi'));
    await shot(tester, 'qabul-table');
    await tester.tap(find.text('Doska ko\'rinishi'));
    await settle(tester);
    // A card's page, with the one step that makes a lead a student.
    await tester.tap(find.text('Nodira Ismoilova').first);
    await shot(tester, 'qabul-card-panel');
    await tester.tap(find.text('Guruhga qo\'shish').first);
    await settle(tester);
    await settle(tester);
    await shot(tester, 'qabul-after-trial');
    await tester.tap(find.text('Rad etildi').last);
    await shot(tester, 'qabul-after-trial-reject');
    await tester.tap(find.text('Bekor qilish').last);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    await tester.tap(find.text('Kurs qidirish'));
    await shot(tester, 'qabul-finder');
    await tester.tap(find.text('Du · Chor · Ju'));
    await shot(tester, 'qabul-finder-days');
    await tester.enterText(find.widgetWithText(TextField, 'Ism'), 'Test Mijoz');
    await tester.enterText(find.byType(TextField).at(1), '901112299');
    await tester.tap(find.text('Sinov darsiga yozish').first);
    await settle(tester);
    await settle(tester);
    await shot(tester, 'qabul-trial-dialog');
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

    await mount(const Size(1440, 900));
    await shot(tester, 'desktop-bugun');

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
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 400));
      await shot(tester, 'desktop-command-bar');
      await tester.enterText(find.byType(TextField).last, 'bot');
      await shot(tester, 'desktop-command-bar-search');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(
        find.descendant(
          of: find.byType(AppTopBar),
          matching: find.text('Yangi'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await shot(tester, 'desktop-new-menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));

      // Narrow desktop window: the icon rail.
      await mount(const Size(1000, 700));
      await shot(tester, 'desktop-narrow');
    }

    // A very narrow desktop window still gets the desktop layout.
    await mount(const Size(700, 700));
    await shot(tester, 'desktop-narrower');
  }, skip: _out.isEmpty);
}
