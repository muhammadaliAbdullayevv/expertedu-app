import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final inquiriesRepositoryProvider = Provider<InquiriesRepository>((ref) {
  return InquiriesRepository(ref.watch(apiClientProvider));
});

class Inquiry {
  const Inquiry({
    required this.id,
    required this.fullName,
    required this.phone,
    this.note,
    this.subjectId,
    this.subjectName,
    this.trialDate,
    required this.status,
    this.convertedStudentId,
    required this.createdAt,
  });

  final int id;
  final String fullName;
  final String phone;
  final String? note;
  final int? subjectId;
  final String? subjectName;
  final DateTime? trialDate;

  /// 'new' | 'contacted' | 'scheduled' | 'converted' | 'lost'.
  final String status;
  final int? convertedStudentId;
  final DateTime createdAt;

  factory Inquiry.fromJson(Map<String, dynamic> json) => Inquiry(
    id: json['id'] as int,
    fullName: json['full_name'] as String,
    phone: json['phone'] as String,
    note: json['note'] as String?,
    subjectId: json['subject_id'] as int?,
    subjectName: json['subject_name'] as String?,
    trialDate: json['trial_date'] == null
        ? null
        : DateTime.parse(json['trial_date'] as String),
    status: json['status'] as String,
    convertedStudentId: json['converted_student_id'] as int?,
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

class InquiriesRepository {
  InquiriesRepository(this._api);

  final ApiClient _api;

  Future<List<Inquiry>> list({String? status}) async {
    final json =
        await _api.get(
              '/inquiries',
              query: status == null ? null : {'status_filter': status},
            )
            as List<dynamic>;
    return json
        .map((e) => Inquiry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Inquiry> create({
    required String fullName,
    required String phone,
    String? note,
    int? subjectId,
    DateTime? trialDate,
  }) async {
    final json =
        await _api.post(
              '/inquiries',
              body: <String, dynamic>{
                'full_name': fullName,
                'phone': phone,
                'note': note,
                'subject_id': subjectId,
                'trial_date': trialDate == null ? null : _dateStr(trialDate),
              },
            )
            as Map<String, dynamic>;
    return Inquiry.fromJson(json);
  }

  Future<Inquiry> updateStatus(int id, String status) async {
    final json =
        await _api.patch(
              '/inquiries/$id',
              body: <String, dynamic>{'status': status},
            )
            as Map<String, dynamic>;
    return Inquiry.fromJson(json);
  }

  Future<void> convert(int id) {
    return _api.post('/inquiries/$id/convert');
  }

  String _dateStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
