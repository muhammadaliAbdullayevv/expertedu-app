import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final studentsRepositoryProvider = Provider<StudentsRepository>((ref) {
  return StudentsRepository(ref.watch(apiClientProvider));
});

class Student {
  const Student({
    required this.id,
    required this.fullName,
    required this.phone,
    this.telegramUsername,
    this.note,
  });

  final int id;
  final String fullName;
  final String phone;
  final String? telegramUsername;
  final String? note;

  factory Student.fromJson(Map<String, dynamic> json) => Student(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    telegramUsername: json['telegram_username'] as String?,
    note: json['note'] as String?,
  );
}

class StudentsRepository {
  StudentsRepository(this._api);

  final ApiClient _api;

  Future<List<Student>> list({String? query}) async {
    final json =
        await _api.get('/students', query: query == null || query.isEmpty ? null : {'q': query}) as List<dynamic>;
    return json.map((e) => Student.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Student> create({required String fullName, required String phone, String? telegramUsername}) async {
    final json =
        await _api.post(
              '/students',
              body: <String, dynamic>{
                'full_name': fullName,
                'phone': phone,
                'telegram_username': telegramUsername,
              },
            )
            as Map<String, dynamic>;
    return Student.fromJson(json);
  }
}
