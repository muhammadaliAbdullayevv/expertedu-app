import 'dart:io';

import 'package:flutter/services.dart';

/// Widget tests draw text in the boxy "Ahem" test font unless a real one is
/// loaded, which makes every width-dependent layout check meaningless.
/// Loads the app's own font (DM Sans) so overflow and wrapping in tests are
/// the real thing. Call from setUpAll.
Future<void> loadAppFonts() async {
  final loader = FontLoader('DM Sans');
  for (final weight in const [400, 500, 600, 700]) {
    final bytes = File('assets/fonts/dm_sans/DMSans-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();

  // The icon font, so screenshots show icons instead of boxes.
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final icons = File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      final iconLoader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.view(Uint8List.fromList(icons.readAsBytesSync()).buffer)));
      await iconLoader.load();
    }
  }
}
