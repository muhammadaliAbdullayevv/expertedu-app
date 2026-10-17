import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../../enrollments/data/enrollments_repository.dart';

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
    this.parentPhone,
    this.heardFrom,
    this.balance = 0,
  });

  final int id;
  final String fullName;
  final String phone;
  final String? telegramUsername;
  final String? note;
  final String? parentPhone;

  /// 'instagram' | 'telegram' | 'referral' | 'walk_in' | 'other'.
  final String? heardFrom;

  /// Sum of this student's balance across every enrollment -- positive
  /// means they owe money overall.
  final int balance;

  factory Student.fromJson(Map<String, dynamic> json) => Student(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    telegramUsername: json['telegram_username'] as String?,
    note: json['note'] as String?,
    parentPhone: json['parent_phone'] as String?,
    heardFrom: json['heard_from'] as String?,
    balance: json['balance'] as int? ?? 0,
  );
}

/// The student who already has a phone number -- the add dialog's
/// duplicate warning (one student per number).
class PhoneOwner {
  const PhoneOwner({
    required this.studentId,
    required this.fullName,
    required this.phone,
    required this.groupNames,
  });

  final int studentId;
  final String fullName;
  final String phone;

  /// Groups they're currently active in.
  final List<String> groupNames;

  factory PhoneOwner.fromJson(Map<String, dynamic> json) => PhoneOwner(
    studentId: json['student_id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    groupNames: (json['group_names'] as List<dynamic>).cast<String>(),
  );
}

class StudentsRepository {
  StudentsRepository(this._api);

  final ApiClient _api;

  Future<List<Student>> list({String? query}) async {
    final json =
        await _api.get(
              '/students',
              query: query == null || query.isEmpty ? null : {'q': query},
            )
            as List<dynamic>;
    return json
        .map((e) => Student.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Student> get(int id) async {
    final json = await _api.get('/students/$id') as Map<String, dynamic>;
    return Student.fromJson(json);
  }

  /// Who already has [phone] (any format -- the server normalizes), or null.
  Future<PhoneOwner?> checkPhone(String phone) async {
    final json =
        await _api.get('/students/phone-check', query: {'phone': phone})
            as Map<String, dynamic>;
    final owner = json['owner'];
    return owner == null
        ? null
        : PhoneOwner.fromJson(owner as Map<String, dynamic>);
  }

  /// The "Yangi o'quvchi" dialog: student, enrollment, first charge and the
  /// optional first payment, saved together server-side. Returns the new
  /// student's id.
  Future<int> createWithEnrollment({
    required String fullName,
    required String phone,
    required int groupId,
    required DateTime joinedAt,
    required String firstMonth,
    String? discountKind,
    int? discountValue,
    String? parentPhone,
    String? heardFrom,
    String? note,
    int? firstPaymentAmount,
    String? firstPaymentMethod,
  }) async {
    final json =
        await _api.post(
              '/students/with-enrollment',
              body: <String, dynamic>{
                'full_name': fullName,
                'phone': phone,
                'group_id': groupId,
                'joined_at': apiDate(joinedAt),
                'first_month': firstMonth,
                'discount_kind': discountKind,
                'discount_value': discountValue,
                'parent_phone': parentPhone,
                'heard_from': heardFrom,
                'note': note,
                'first_payment_amount': firstPaymentAmount,
                'first_payment_method': firstPaymentMethod,
              },
            )
            as Map<String, dynamic>;
    return (json['student'] as Map<String, dynamic>)['id'] as int;
  }

  Future<Student> create({
    required String fullName,
    required String phone,
    String? telegramUsername,
  }) async {
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
