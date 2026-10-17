import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../features/photos/photos_repository.dart';

/// A person's round picture: their photo when they have one, otherwise the
/// first letters of their name on a colour that comes from the name (so
/// the same person always looks the same).
class PersonAvatar extends ConsumerWidget {
  const PersonAvatar({
    super.key,
    required this.name,
    this.photo,
    this.radius = 18,
  });

  final String name;

  /// The stored photo name from the server; null = none.
  final String? photo;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final letters = _Letters(name, radius);
    final stored = photo;
    if (stored == null) return letters;
    final bytes = ref.watch(photoBytesProvider(stored)).value;
    if (bytes == null) return letters;
    return ClipOval(
      child: Image.memory(
        bytes,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => letters,
      ),
    );
  }
}

/// The letters avatar -- also what shows while a photo loads.
class _Letters extends StatelessWidget {
  const _Letters(this.name, this.radius);

  final String name;
  final double radius;

  static const _palette = <(Color, Color)>[
    (AppColors.accentSoft, AppColors.accentText),
    (Color(0xFFE3EEFB), Color(0xFF1F5A9E)),
    (Color(0xFFFBEBD9), Color(0xFF9A5A12)),
    (Color(0xFFF1E4F7), Color(0xFF7A3A94)),
    (Color(0xFFE0F4F1), Color(0xFF17756A)),
    (Color(0xFFFBE4E6), Color(0xFFA23A48)),
  ];

  /// The same name always gives the same colour (a stable sum, not
  /// String.hashCode, which differs between runs).
  static (Color, Color) colorsFor(String name) {
    var sum = 0;
    for (final unit in name.trim().toLowerCase().runes) {
      sum = (sum * 31 + unit) & 0x7fffffff;
    }
    return _palette[sum % _palette.length];
  }

  static String lettersOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    final letters = parts
        .take(2)
        .map((p) => String.fromCharCode(p.runes.first).toUpperCase())
        .join();
    return letters.isEmpty ? '–' : letters;
  }

  @override
  Widget build(BuildContext context) {
    final (background, ink) = colorsFor(name);
    return CircleAvatar(
      radius: radius,
      backgroundColor: background,
      child: Text(
        lettersOf(name),
        style: TextStyle(
          fontSize: radius * 0.68,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
      ),
    );
  }
}

/// The colour pair and letters, for tests.
(Color, Color) avatarColorsFor(String name) => _Letters.colorsFor(name);
String avatarLettersOf(String name) => _Letters.lettersOf(name);
