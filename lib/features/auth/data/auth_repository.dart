import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../../../services/api/token_storage.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    ref.watch(apiClientProvider),
    ref.watch(tokenStorageProvider),
  );
});

/// One entry in the on-device account switcher -- lets an owner/admin stay
/// logged into more than one account on the same install and switch
/// between them instantly. Holds the actual JWT so switching back is
/// instant; only ever stored in the same encrypted storage the single
/// active token already lived in.
class SavedAccount {
  const SavedAccount({
    required this.token,
    required this.userId,
    required this.phone,
    required this.fullName,
    required this.role,
  });

  final String token;
  final String userId;
  final String phone;
  final String fullName;
  final String role;

  bool get isOwner => role == 'owner';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'token': token,
    'user_id': userId,
    'phone': phone,
    'full_name': fullName,
    'role': role,
  };

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
    token: json['token'] as String,
    userId: json['user_id'] as String,
    phone: json['phone'] as String,
    fullName: json['full_name'] as String,
    role: json['role'] as String,
  );

  factory SavedAccount.fromAuthUser(AuthUser user, String token) =>
      SavedAccount(
        token: token,
        userId: user.id,
        phone: user.phone,
        fullName: user.fullName,
        role: user.role,
      );
}

class AuthUser {
  const AuthUser({
    required this.id,
    required this.phone,
    required this.fullName,
    required this.role,
  });

  final String id;
  final String phone;
  final String fullName;
  final String role;

  bool get isOwner => role == 'owner';

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: (json['user_id'] ?? json['id']).toString(),
      phone: json['phone'] as String,
      fullName: json['full_name'] as String,
      role: json['role'] as String,
    );
  }
}

class AuthRepository {
  AuthRepository(this._api, this._tokenStorage);

  final ApiClient _api;
  final TokenStorage _tokenStorage;

  Future<AuthUser> login({
    required String phone,
    required String password,
  }) async {
    final json =
        await _api.post(
              '/auth/login',
              body: <String, String>{'phone': phone, 'password': password},
              withAuth: false,
            )
            as Map<String, dynamic>;
    final token = json['token'] as String;
    await _tokenStorage.saveToken(token);
    final user = AuthUser.fromJson(json);
    // Bookkeeping for the account switcher must never fail a login that
    // already succeeded against the server (token is already saved above).
    try {
      await _upsertSavedAccount(SavedAccount.fromAuthUser(user, token));
    } catch (_) {
      // Ignore -- the switcher list just won't show this account.
    }
    return user;
  }

  /// Logs into a *second* account for the switcher without making it the
  /// active session -- use [switchAccount] afterward to actually activate it.
  Future<SavedAccount> addAccount({
    required String phone,
    required String password,
  }) async {
    final json =
        await _api.post(
              '/auth/login',
              body: <String, String>{'phone': phone, 'password': password},
              withAuth: false,
            )
            as Map<String, dynamic>;
    final token = json['token'] as String;
    final account = SavedAccount.fromAuthUser(AuthUser.fromJson(json), token);
    await _upsertSavedAccount(account);
    return account;
  }

  /// Best-effort read of the saved-accounts list -- a single malformed entry
  /// must not make the whole switcher list, or [login]/[addAccount] which
  /// upsert into it, blow up.
  Future<List<SavedAccount>> _readSavedAccountsSafe() async {
    final raw = await _tokenStorage.readSavedAccountsRaw();
    if (raw == null || raw.isEmpty) return <SavedAccount>[];
    List<dynamic> list;
    try {
      list = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return <SavedAccount>[];
    }
    final accounts = <SavedAccount>[];
    for (final entry in list) {
      try {
        accounts.add(SavedAccount.fromJson(entry as Map<String, dynamic>));
      } catch (_) {
        // Skip this one entry rather than losing/blocking the rest.
      }
    }
    return accounts;
  }

  Future<AuthUser?> currentUser() async {
    final token = await _tokenStorage.readToken();
    if (token == null) {
      return null;
    }
    try {
      final json = await _api.get('/me') as Map<String, dynamic>;
      return AuthUser.fromJson(json);
    } on ApiException {
      return null;
    }
  }

  /// Signing out forgets this account on this device entirely -- it does
  /// not revoke the token server-side.
  Future<void> signOut(String? phone) async {
    await _tokenStorage.clearToken();
    if (phone != null) {
      await removeSavedAccount(phone);
    }
  }

  Future<List<SavedAccount>> listSavedAccounts() => _readSavedAccountsSafe();

  Future<void> removeSavedAccount(String phone) async {
    final accounts = await _readSavedAccountsSafe();
    accounts.removeWhere((a) => a.phone == phone);
    await _tokenStorage.saveSavedAccountsRaw(
      jsonEncode(accounts.map((a) => a.toJson()).toList()),
    );
  }

  Future<void> _upsertSavedAccount(SavedAccount account) async {
    final accounts = await _readSavedAccountsSafe();
    accounts.removeWhere((a) => a.phone == account.phone);
    accounts.add(account);
    await _tokenStorage.saveSavedAccountsRaw(
      jsonEncode(accounts.map((a) => a.toJson()).toList()),
    );
  }

  /// Makes [account] the active session -- verifies its saved token still
  /// works first, removing it from the switcher instead of silently
  /// switching to a dead session if not.
  Future<AuthUser> switchAccount(SavedAccount account) async {
    final previousToken = await _tokenStorage.readToken();
    await _tokenStorage.saveToken(account.token);
    try {
      final json = await _api.get('/me') as Map<String, dynamic>;
      return AuthUser.fromJson(json);
    } on ApiException {
      if (previousToken != null) {
        await _tokenStorage.saveToken(previousToken);
      } else {
        await _tokenStorage.clearToken();
      }
      await removeSavedAccount(account.phone);
      rethrow;
    }
  }

  /// Invalidates every session for the CURRENT account (including this
  /// device), forcing a fresh login everywhere.
  Future<void> revokeMySessions() => _api.post('/me/revoke-sessions');
}
