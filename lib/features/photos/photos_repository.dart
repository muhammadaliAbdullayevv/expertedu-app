import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/api/api_client.dart';

/// Whose photo: the server keeps teachers' and students' separately.
enum PhotoOwner {
  teacher('teachers'),
  student('students');

  const PhotoOwner(this.path);
  final String path;
}

final photosRepositoryProvider = Provider<PhotosRepository>((ref) {
  return PhotosRepository(ref.watch(apiClientProvider));
});

/// A stored photo's picture. The name changes with every new photo, so a
/// copy kept here never goes stale. Null when it can't be loaded (the
/// letter is drawn instead).
final photoBytesProvider = FutureProvider.family<Uint8List?, String>((
  ref,
  name,
) async {
  try {
    return await ref.read(photosRepositoryProvider).bytes(name);
  } catch (_) {
    return null;
  }
});

class PhotosRepository {
  PhotosRepository(this._api);

  final ApiClient _api;

  Future<Uint8List> bytes(String name) => _api.getBytes('/photos/file/$name');

  /// Uploads [png] as the person's photo; returns its stored name.
  Future<String> set(PhotoOwner owner, int id, Uint8List png) async {
    final json =
        await _api.putBytes('/photos/${owner.path}/$id', bytes: png)
            as Map<String, dynamic>;
    return json['photo'] as String;
  }

  Future<void> remove(PhotoOwner owner, int id) =>
      _api.delete('/photos/${owner.path}/$id');
}
