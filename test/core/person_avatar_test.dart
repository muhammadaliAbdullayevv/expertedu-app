import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:expert_edu_center/core/widgets/person_avatar.dart';
import 'package:expert_edu_center/features/photos/photo_picker.dart';
import 'package:expert_edu_center/features/photos/photos_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> picture(int w, int h) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Widget host(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  group('the letters', () {
    test('first letters of the first two words, capitals', () {
      expect(avatarLettersOf('madina karimova'), 'MK');
      expect(avatarLettersOf('Botir'), 'B');
      expect(avatarLettersOf('  Ali   Valiyev  Ogli '), 'AV');
      expect(avatarLettersOf(''), '–');
    });

    test('the same name always has the same colours', () {
      expect(
        avatarColorsFor('Madina Karimova'),
        avatarColorsFor('madina karimova'),
      );
      expect(
        avatarColorsFor('Madina Karimova'),
        avatarColorsFor('Madina Karimova'),
      );
      // Different people spread over more than one colour.
      final colours = {
        for (final n in [
          'Ali',
          'Vali',
          'Madina',
          'Jasur',
          'Nilufar',
          'Botir',
          'Dilnoza',
        ])
          avatarColorsFor(n),
      };
      expect(colours.length, greaterThan(2));
    });

    testWidgets('no photo: the letters are drawn', (tester) async {
      await tester.pumpWidget(
        host(const PersonAvatar(name: 'Madina Karimova')),
      );
      expect(find.text('MK'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('a photo', () {
    testWidgets('is drawn instead of the letters once it has loaded', (
      tester,
    ) async {
      final png = (await tester.runAsync(() => picture(8, 8)))!;
      await tester.pumpWidget(
        host(
          const PersonAvatar(name: 'Madina Karimova', photo: 'teacher-1-a.png'),
          overrides: [
            photoBytesProvider('teacher-1-a.png').overrideWith((ref) => png),
          ],
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('MK'), findsNothing);
    });

    testWidgets('that cannot be loaded falls back to the letters', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const PersonAvatar(name: 'Madina Karimova', photo: 'teacher-1-a.png'),
          overrides: [
            photoBytesProvider('teacher-1-a.png').overrideWith((ref) => null),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('MK'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('shows the letters while it is still loading', (tester) async {
      await tester.pumpWidget(
        host(
          const PersonAvatar(name: 'Madina Karimova', photo: 'teacher-1-a.png'),
          overrides: [
            photoBytesProvider('teacher-1-a.png').overrideWith(
              (ref) => Future<Uint8List?>.delayed(
                const Duration(seconds: 5),
                () => null,
              ),
            ),
          ],
        ),
      );
      expect(find.text('MK'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });
  });

  group('squaring a picked picture', () {
    test(
      'a wide picture becomes the middle square, 400 px, as a PNG',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final wide = await picture(300, 100);
        final out = await squarePhoto(wide);
        expect(out.sublist(0, 8), [
          0x89,
          0x50,
          0x4e,
          0x47,
          0x0d,
          0x0a,
          0x1a,
          0x0a,
        ]);
        final codec = await ui.instantiateImageCodec(out);
        final frame = await codec.getNextFrame();
        expect((frame.image.width, frame.image.height), (photoSide, photoSide));
      },
    );

    test('something that is not a picture is refused', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await expectLater(
        squarePhoto(Uint8List.fromList([1, 2, 3, 4])),
        throwsA(anything),
      );
    });
  });
}
