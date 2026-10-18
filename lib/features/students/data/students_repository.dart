import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../../enrollments/data/enrollments_repository.dart';
import 'student_models.dart';

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
    this.address,
    this.photo,
    this.archivedAt,
    this.balance = 0,
  });

  final int id;
  final String fullName;
  final String phone;
  final String? telegramUsername;
  final String? note;
  final String? parentPhone;

  /// Where they live, typed by hand.
  final String? address;

  /// Stored name of the profile photo; null = none.
  final String? photo;

  /// Set while he is in the archive.
  final DateTime? archivedAt;

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
    address: json['address'] as String?,
    photo: json['photo'] as String?,
    archivedAt: json['archived_at'] == null
        ? null
        : DateTime.parse(json['archived_at'] as String),
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
    this.branchNames = const [],
    this.inScope = true,
  });

  final int studentId;
  final String fullName;
  final String phone;

  /// Groups they're currently active in.
  final List<String> groupNames;

  /// The branches they are in. For a student of ANOTHER branch ([inScope]
  /// false) this and the name are all that is shown.
  final List<String> branchNames;

  /// False: the student belongs only to another branch -- the app offers
  /// "Shu o'quvchini mening filialimga qo'shish".
  final bool inScope;

  factory PhoneOwner.fromJson(Map<String, dynamic> json) => PhoneOwner(
    studentId: json['student_id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    groupNames: (json['group_names'] as List<dynamic>).cast<String>(),
    branchNames: (json['branch_names'] as List<dynamic>? ?? const [])
        .cast<String>(),
    inScope: json['in_scope'] as bool? ?? true,
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

  /// The table: every student with their groups, attendance and tab flags.
  Future<List<StudentRow>> rows({String? query}) async {
    final json =
        await _api.get(
              '/students',
              query: query == null || query.isEmpty ? null : {'q': query},
            )
            as List<dynamic>;
    return [
      for (final e in json) StudentRow.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// The profile panel's data in one request.
  Future<StudentProfileData> profile(int id) async {
    final json =
        await _api.get('/students/$id/profile') as Map<String, dynamic>;
    return StudentProfileData.fromJson(json);
  }

  /// Edits the profile; only the fields in [changes] are sent. The server
  /// refuses a phone that belongs to someone else and logs every change.
  Future<Student> update(int id, Map<String, dynamic> changes) async {
    final json =
        await _api.patch('/students/$id', body: changes)
            as Map<String, dynamic>;
    return Student.fromJson(json);
  }

  /// "Boshqa guruhga qo'shish": the seat, the first bill by the group's rule
  /// and the optional first payment, in one step.
  Future<AddedToGroup> addToGroup(
    int id, {
    required int groupId,
    required DateTime joinedAt,
    int? firstPaymentAmount,
    String? firstPaymentMethod,
  }) async {
    final json =
        await _api.post(
              '/students/$id/add-to-group',
              body: <String, dynamic>{
                'group_id': groupId,
                'joined_at': apiDate(joinedAt),
                'first_payment_amount': firstPaymentAmount,
                'first_payment_method': firstPaymentMethod,
              },
            )
            as Map<String, dynamic>;
    return AddedToGroup.fromJson(json);
  }

  /// "Arxivga o'tkazish": out of every group, everything kept. [note] is the
  /// reason (required). Returns what he still owes.
  Future<int> archive(int id, {required String note}) async {
    final json =
        await _api.post('/students/$id/archive', body: {'note': note})
            as Map<String, dynamic>;
    return json['debt'] as int;
  }

  Future<void> unarchive(int id, {String? note}) =>
      _api.post('/students/$id/unarchive', body: {'note': note});

  /// Out of one group, with a comment; everything he did there stays.
  /// Returns what he still owes on it.
  Future<int> removeFromGroup(
    int id, {
    required int groupId,
    required String note,
  }) async {
    final json =
        await _api.post(
              '/students/$id/remove-from-group',
              body: {'group_id': groupId, 'note': note},
            )
            as Map<String, dynamic>;
    return json['debt'] as int;
  }

  /// "Guruhni almashtirish": leaves [fromGroupId], joins [toGroupId] (billed
  /// by the new group's price from today).
  Future<TransferResult> transfer(
    int id, {
    required int fromGroupId,
    required int toGroupId,
    String? note,
  }) async {
    final json =
        await _api.post(
              '/students/$id/transfer',
              body: {
                'from_group_id': fromGroupId,
                'to_group_id': toGroupId,
                'note': note,
              },
            )
            as Map<String, dynamic>;
    return TransferResult.fromJson(json);
  }

  /// "Shu o'quvchini mening filialimga qo'shish": the same person is put in
  /// this branch too (the number must match). Their shared details show here;
  /// the other branch's groups, payments and notes do not.
  Future<Student> joinBranch(int id, {required String phone}) async {
    final json =
        await _api.post('/students/$id/join-branch', body: {'phone': phone})
            as Map<String, dynamic>;
    return Student.fromJson(json);
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
