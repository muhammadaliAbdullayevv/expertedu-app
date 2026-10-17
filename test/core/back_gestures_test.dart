import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_edu_center/core/widgets/back_gestures.dart';

void main() {
  late int backs;

  Future<void> pump(WidgetTester tester) async {
    backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackGestures(
            onBack: () => backs++,
            child: Focus(
              autofocus: true,
              child: Column(
                children: <Widget>[
                  const TextField(key: ValueKey('field')),
                  Expanded(
                    child: ListView(
                      children: [for (var i = 0; i < 50; i++) Text('row $i')],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Two fingers on the touchpad: [dx] > 0 is the fingers moving right.
  Future<void> swipe(WidgetTester tester, double dx, {double dy = 0}) async {
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    // Content follows the fingers, so the scroll delta is the opposite sign.
    await tester.sendEventToBinding(pointer.hover(const Offset(300, 300)));
    await tester.sendEventToBinding(pointer.scroll(Offset(-dx, -dy)));
  }

  testWidgets('Esc goes back', (tester) async {
    await pump(tester);
    await tester.tap(find.text('row 0'));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(backs, 1);
  });

  testWidgets('Esc goes back even while typing in a field', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('field')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(backs, 1);
  });

  testWidgets('a two-finger swipe to the right goes back once', (tester) async {
    await pump(tester);
    await tester.pump(const Duration(seconds: 1));
    // One swipe arrives as many small scroll events, then inertia.
    for (var i = 0; i < 12; i++) {
      await swipe(tester, 20);
    }
    expect(backs, 1);
  });

  testWidgets('swiping to the left does nothing', (tester) async {
    await pump(tester);
    for (var i = 0; i < 12; i++) {
      await swipe(tester, -20);
    }
    expect(backs, 0);
  });

  testWidgets('a short sideways wobble does nothing', (tester) async {
    await pump(tester);
    await swipe(tester, 30);
    expect(backs, 0);
  });

  testWidgets('scrolling down the page never goes back', (tester) async {
    await pump(tester);
    for (var i = 0; i < 30; i++) {
      await swipe(tester, 10, dy: 40);
    }
    expect(backs, 0);
  });

  testWidgets('a second swipe after a pause goes back again', (tester) async {
    await pump(tester);
    for (var i = 0; i < 8; i++) {
      await swipe(tester, 20);
    }
    expect(backs, 1);
    await tester.pump(const Duration(seconds: 1));
    // Real time, not the fake clock, is what the widget reads.
    await tester.runAsync(
      () => Future<void>.delayed(
        BackGestures.quiet + const Duration(milliseconds: 100),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await swipe(tester, 20);
    }
    expect(backs, 2);
  });

  testWidgets('Esc inside a dialog closes the dialog, not the page', (
    tester,
  ) async {
    await pump(tester);
    final context = tester.element(find.byType(Scaffold));
    showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(title: Text('dialog')),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsNothing);
    expect(backs, 0);
  });
}
