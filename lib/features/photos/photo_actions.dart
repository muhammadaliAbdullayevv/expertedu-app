import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../admissions/presentation/admissions_ui.dart';
import 'photo_picker.dart';
import 'photos_repository.dart';

/// Asks for a picture and saves it as the person's photo. True when the
/// photo changed; says what went wrong otherwise.
Future<bool> changePhoto(
  BuildContext context,
  WidgetRef ref,
  PhotoOwner owner,
  int id,
) async {
  try {
    final picture = await ref.read(photoPickerProvider)();
    if (picture == null) return false;
    await ref.read(photosRepositoryProvider).set(owner, id, picture);
    if (context.mounted) showSnack(context, 'Rasm saqlandi.');
    return true;
  } catch (e) {
    if (context.mounted) {
      showSnack(context, 'Rasmni saqlab bo\'lmadi: $e');
    }
    return false;
  }
}

Future<bool> removePhoto(
  BuildContext context,
  WidgetRef ref,
  PhotoOwner owner,
  int id,
) async {
  try {
    await ref.read(photosRepositoryProvider).remove(owner, id);
    if (context.mounted) showSnack(context, 'Rasm o\'chirildi.');
    return true;
  } catch (e) {
    if (context.mounted) {
      showSnack(context, 'Rasmni o\'chirib bo\'lmadi: $e');
    }
    return false;
  }
}
