import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lets the user choose a picture and hands back a small square PNG of it
/// (null when they cancel). Swappable in tests.
typedef PhotoPicker = Future<Uint8List?> Function();

final photoPickerProvider = Provider<PhotoPicker>((ref) => pickPhoto);

/// The side of the square photo we keep -- plenty for an avatar, and small
/// enough to send quickly.
const photoSide = 400;

Future<Uint8List?> pickPhoto() async {
  final file = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[
      XTypeGroup(
        label: 'Rasm',
        extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
      ),
    ],
  );
  if (file == null) return null;
  return squarePhoto(await file.readAsBytes());
}

/// Crops the middle square out of [bytes] and scales it to [photoSide] px,
/// as a PNG. Throws if the bytes are not a picture.
Future<Uint8List> squarePhoto(Uint8List bytes, {int side = photoSide}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final shortest = image.width < image.height ? image.width : image.height;
  final source = ui.Rect.fromLTWH(
    (image.width - shortest) / 2,
    (image.height - shortest) / 2,
    shortest.toDouble(),
    shortest.toDouble(),
  );
  final target = ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble());
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    source,
    target,
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final square = await recorder.endRecording().toImage(side, side);
  final data = await square.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  square.dispose();
  codec.dispose();
  return data!.buffer.asUint8List();
}
