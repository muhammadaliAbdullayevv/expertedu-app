import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';

final branchesRepositoryProvider = Provider<BranchesRepository>((ref) {
  return BranchesRepository(ref.watch(apiClientProvider));
});

/// Bosh ofis or a filial.
class Branch {
  const Branch({
    required this.id,
    required this.name,
    this.isHeadquarters = false,
    this.isActive = true,
  });

  final int id;
  final String name;
  final bool isHeadquarters;
  final bool isActive;

  factory Branch.fromJson(Map<String, dynamic> json) => Branch(
    id: json['id'] as int,
    name: json['name'] as String,
    isHeadquarters: json['is_headquarters'] as bool? ?? false,
    isActive: json['is_active'] as bool? ?? true,
  );
}

/// The owner sees every branch here; an admin only their own.
class BranchesRepository {
  BranchesRepository(this._api);

  final ApiClient _api;

  Future<List<Branch>> list() async {
    final json = await _api.get('/branches') as List<dynamic>;
    return [for (final b in json) Branch.fromJson(b as Map<String, dynamic>)];
  }

  /// OWNER ONLY.
  Future<Branch> create(String name) async {
    final json =
        await _api.post('/branches', body: {'name': name})
            as Map<String, dynamic>;
    return Branch.fromJson(json);
  }

  /// OWNER ONLY: rename and/or switch off (never the headquarters).
  Future<Branch> update(int id, {String? name, bool? isActive}) async {
    final json =
        await _api.patch(
              '/branches/$id',
              body: <String, dynamic>{'name': ?name, 'is_active': ?isActive},
            )
            as Map<String, dynamic>;
    return Branch.fromJson(json);
  }
}
