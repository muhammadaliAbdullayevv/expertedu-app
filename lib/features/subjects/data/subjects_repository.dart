import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final subjectsRepositoryProvider = Provider<SubjectsRepository>((ref) {
  return SubjectsRepository(ref.watch(apiClientProvider));
});

class Subject {
  const Subject({
    required this.id,
    required this.name,
    required this.groupCount,
  });

  final int id;
  final String name;
  final int groupCount;

  factory Subject.fromJson(Map<String, dynamic> json) => Subject(
    id: json['id'] as int,
    name: json['name'] as String,
    groupCount: json['group_count'] as int? ?? 0,
  );
}

class SubjectsRepository {
  SubjectsRepository(this._api);

  final ApiClient _api;

  Future<List<Subject>> list() async {
    final json = await _api.get('/subjects') as List<dynamic>;
    return json
        .map((e) => Subject.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Subject> create(String name) async {
    final json =
        await _api.post('/subjects', body: <String, dynamic>{'name': name})
            as Map<String, dynamic>;
    return Subject.fromJson(json);
  }
}
