import 'package:expert_edu_center/app/theme/app_theme.dart';
import 'package:expert_edu_center/features/groups/data/groups_repository.dart';
import 'package:expert_edu_center/features/groups/presentation/telegram_section.dart';
import 'package:expert_edu_center/services/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/load_fonts.dart';

class _FakeGroups implements GroupsRepository {
  _FakeGroups(this.status);

  TelegramGroupStatus status;
  int codesMade = 0;
  int disconnects = 0;
  Object? statusError;

  @override
  Future<TelegramGroupStatus> telegramStatus(int groupId) async {
    if (statusError != null) throw statusError!;
    return status;
  }

  @override
  Future<TelegramGroupStatus> newTelegramCode(int groupId) async {
    codesMade++;
    return status = TelegramGroupStatus(
      connected: false,
      code: 'K7M4QXP$codesMade',
      codeExpiresAt: DateTime(2030, 1, 2, 9, 30),
      link: 'https://t.me/Expert_AI_Admin_bot?startgroup=K7M4QXP$codesMade',
    );
  }

  @override
  Future<TelegramGroupStatus> disconnectTelegram(int groupId) async {
    disconnects++;
    return status = const TelegramGroupStatus(connected: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, _FakeGroups groups) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [groupsRepositoryProvider.overrideWithValue(groups)],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: TelegramSection(groupId: 7)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpNarrow(WidgetTester tester, _FakeGroups groups) async {
  // The group page puts this section beside the group's facts, in a column this wide.
  await tester.pumpWidget(
    ProviderScope(
      overrides: [groupsRepositoryProvider.overrideWithValue(groups)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: SingleChildScrollView(child: TelegramSection(groupId: 7)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(
    loadAppFonts,
  ); // real glyph widths: the test font is much wider than the app's

  // The group page puts this section beside the group's facts, in a column 320 wide: no state may overflow it.
  testWidgets('narrow column: an open code with its link fits', (tester) async {
    await _pumpNarrow(
      tester,
      _FakeGroups(
        TelegramGroupStatus(
          connected: false,
          code: 'K7M4QXPA',
          codeExpiresAt: DateTime(2030, 1, 2, 9, 30),
          link: 'https://t.me/Expert_AI_Admin_bot?startgroup=K7M4QXPA',
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('telegram-code')), findsOneWidget);
    expect(find.byKey(const ValueKey('telegram-copy-link')), findsOneWidget);
  });

  testWidgets('narrow column: not connected, no code yet, fits', (
    tester,
  ) async {
    await _pumpNarrow(
      tester,
      _FakeGroups(const TelegramGroupStatus(connected: false)),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('telegram-new-code')), findsOneWidget);
  });

  testWidgets('narrow column: connected, with a long chat name, fits', (
    tester,
  ) async {
    await _pumpNarrow(
      tester,
      _FakeGroups(
        TelegramGroupStatus(
          connected: true,
          chatTitle:
              'Ingliz tili Beginner A — kechki guruh (o\'quvchilar chati)',
          connectedBy: 'Administrator Adminovich',
          connectedAt: DateTime(2030, 1, 1),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('telegram-disconnect')), findsOneWidget);
  });

  testWidgets('not connected: says so, and a code is made on request', (
    tester,
  ) async {
    final groups = _FakeGroups(const TelegramGroupStatus(connected: false));
    await _pump(tester, groups);
    expect(find.text('Ulanmagan'), findsOneWidget);
    expect(find.byKey(const ValueKey('telegram-code')), findsNothing);
    expect(find.textContaining('/connect KOD'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('telegram-new-code')));
    await tester.pumpAndSettle();
    expect(groups.codesMade, 1);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const ValueKey('telegram-code')))
          .data,
      'K7M4QXP1',
    );
    expect(
      find.textContaining('Bir marta ishlaydi, 02.01 09:30 gacha'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('telegram-copy-link')), findsOneWidget);
  });

  testWidgets('an open code is shown on loading and can be replaced', (
    tester,
  ) async {
    final groups = _FakeGroups(
      TelegramGroupStatus(
        connected: false,
        code: 'ABCD2345',
        codeExpiresAt: DateTime(2030, 1, 2, 9, 30),
        link: 'https://t.me/Expert_AI_Admin_bot?startgroup=ABCD2345',
      ),
    );
    await _pump(tester, groups);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const ValueKey('telegram-code')))
          .data,
      'ABCD2345',
    );
    await tester.tap(find.byKey(const ValueKey('telegram-new-code')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SelectableText>(find.byKey(const ValueKey('telegram-code')))
          .data,
      'K7M4QXP1',
    );
  });

  testWidgets('the command and the link can be copied', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final groups = _FakeGroups(
      TelegramGroupStatus(
        connected: false,
        code: 'ABCD2345',
        codeExpiresAt: DateTime(2030, 1, 2, 9, 30),
        link: 'https://t.me/Expert_AI_Admin_bot?startgroup=ABCD2345',
      ),
    );
    await _pump(tester, groups);
    await tester.tap(find.byKey(const ValueKey('telegram-copy-command')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('telegram-copy-link')));
    await tester.pump();
    expect(copied, [
      '/connect ABCD2345',
      'https://t.me/Expert_AI_Admin_bot?startgroup=ABCD2345',
    ]);
    expect(find.text('Nusxalandi'), findsOneWidget);
  });

  testWidgets(
    'connected: shows the chat and who connected it, and can disconnect',
    (tester) async {
      final groups = _FakeGroups(
        TelegramGroupStatus(
          connected: true,
          chatTitle: 'Beginner A (chat)',
          connectedBy: 'Admin Adminov',
          connectedAt: DateTime(2030, 1, 1),
        ),
      );
      await _pump(tester, groups);
      expect(find.text('Ulangan'), findsOneWidget);
      expect(find.text('«Beginner A (chat)» ulangan.'), findsOneWidget);
      expect(find.text('Admin Adminov ulagan'), findsOneWidget);
      expect(find.byKey(const ValueKey('telegram-code')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('telegram-disconnect')));
      await tester.pumpAndSettle();
      expect(groups.disconnects, 1);
      expect(find.text('Ulanmagan'), findsOneWidget);
    },
  );

  testWidgets('a server that cannot say shows a quiet note, not a crash', (
    tester,
  ) async {
    final groups = _FakeGroups(const TelegramGroupStatus(connected: false))
      ..statusError = ApiException(500, 'boom');
    await _pump(tester, groups);
    expect(find.byKey(const ValueKey('telegram-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('telegram-new-code')), findsNothing);
  });
}
