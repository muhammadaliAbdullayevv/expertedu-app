import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final groupsRepositoryProvider = Provider<GroupsRepository>((ref) {
  return GroupsRepository(ref.watch(apiClientProvider));
});

class Group {
  const Group({
    required this.id,
    required this.name,
    required this.feeAmount,
    required this.dueDay,
    required this.isActive,
    this.note,
  });

  final int id;
  final String name;
  final int feeAmount;
  final int dueDay;
  final bool isActive;
  final String? note;

  factory Group.fromJson(Map<String, dynamic> json) => Group(
    id: json['id'] as int,
    name: json['name'] as String,
    feeAmount: json['fee_amount'] as int,
    dueDay: json['due_day'] as int,
    isActive: json['is_active'] as bool,
    note: json['note'] as String?,
  );
}

class GroupsRepository {
  GroupsRepository(this._api);

  final ApiClient _api;

  Future<List<Group>> list({bool includeInactive = false}) async {
    final json =
        await _api.get('/groups', query: {'include_inactive': includeInactive.toString()}) as List<dynamic>;
    return json.map((e) => Group.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Group> create({required String name, required int feeAmount, required int dueDay, String? note}) async {
    final json =
        await _api.post(
              '/groups',
              body: <String, dynamic>{'name': name, 'fee_amount': feeAmount, 'due_day': dueDay, 'note': note},
            )
            as Map<String, dynamic>;
    return Group.fromJson(json);
  }
}
