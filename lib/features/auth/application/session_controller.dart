import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/api/api_client.dart';
import '../data/auth_repository.dart';

final sessionControllerProvider = Provider<SessionController>((ref) {
  final controller = SessionController(ref.watch(authRepositoryProvider), ref.watch(apiClientProvider));
  ref.onDispose(controller.dispose);
  return controller;
});

class SessionController extends ChangeNotifier {
  SessionController(this._repository, this._apiClient) {
    _apiClient.onUnauthorized = _handleUnauthorized;
    unawaited(_restore());
  }

  final AuthRepository _repository;
  final ApiClient _apiClient;

  bool _ready = false;
  AuthUser? _user;
  String? _errorText;
  List<SavedAccount> _savedAccounts = const <SavedAccount>[];

  bool get isReady => _ready;
  bool get isAuthenticated => _user != null;
  AuthUser? get user => _user;
  bool get isOwner => _user?.isOwner ?? false;
  String? get errorText => _errorText;

  /// Every account this device has logged into and not forgotten -- see
  /// [switchAccount]. Includes the currently-active one.
  List<SavedAccount> get savedAccounts => _savedAccounts;

  Future<void> _restore() async {
    _user = await _repository.currentUser();
    try {
      _savedAccounts = await _repository.listSavedAccounts();
    } catch (_) {
      _savedAccounts = const <SavedAccount>[];
    }
    _ready = true;
    notifyListeners();
  }

  Future<bool> login({required String phone, required String password}) async {
    // A previous 401 may have left every further call blocked locally
    // (see ApiClient._blockedUntilReauth) -- this attempt IS the recovery
    // from that, so it must not itself get swallowed by that block.
    _apiClient.resetAuthBlock();
    try {
      _user = await _repository
          .login(phone: phone, password: password)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw ApiException(0, 'Vaqt tugadi, qayta urinib ko\'ring.'),
          );
      _errorText = null;
      _savedAccounts = await _repository.listSavedAccounts();
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      _errorText = error.message;
      notifyListeners();
      return false;
    } catch (_) {
      _errorText = 'Kutilmagan xatolik yuz berdi';
      notifyListeners();
      return false;
    }
  }

  /// Logs a *second* account into the switcher (see [SavedAccount]) without
  /// making it the active session. Tapping it in the switcher calls
  /// [switchAccount] instead.
  Future<String?> addAccount({required String phone, required String password}) async {
    _apiClient.resetAuthBlock();
    try {
      await _repository
          .addAccount(phone: phone, password: password)
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw ApiException(0, 'Vaqt tugadi, qayta urinib ko\'ring.'),
          );
      _savedAccounts = await _repository.listSavedAccounts();
      notifyListeners();
      return null;
    } on ApiException catch (error) {
      return error.message;
    } catch (_) {
      return 'Kutilmagan xatolik yuz berdi';
    }
  }

  Future<void> signOut() async {
    await _repository.signOut(_user?.phone);
    _user = null;
    _savedAccounts = await _repository.listSavedAccounts();
    notifyListeners();
  }

  /// Switches the active session to a different device-saved account
  /// without needing its password again.
  Future<String?> switchAccount(SavedAccount account) async {
    if (account.userId == _user?.id) {
      return null;
    }
    _apiClient.resetAuthBlock();
    try {
      _user = await _repository.switchAccount(account);
      _errorText = null;
      notifyListeners();
      return null;
    } on ApiException catch (error) {
      // A 401 here already ran _handleUnauthorized, which nulled _user out
      // from under us even though repository.switchAccount restores the
      // *previous* account's token to storage on failure -- reload it so
      // the account being switched FROM doesn't look signed out too.
      _user = await _repository.currentUser();
      _savedAccounts = await _repository.listSavedAccounts();
      notifyListeners();
      return error.message;
    } catch (_) {
      _user = await _repository.currentUser();
      _savedAccounts = await _repository.listSavedAccounts();
      notifyListeners();
      return 'Kutilmagan xatolik yuz berdi';
    }
  }

  /// Forgets a saved account without touching whichever one is currently
  /// active.
  Future<void> forgetAccount(SavedAccount account) async {
    await _repository.removeSavedAccount(account.phone);
    _savedAccounts = await _repository.listSavedAccounts();
    notifyListeners();
  }

  void clearError() {
    if (_errorText == null) {
      return;
    }
    _errorText = null;
    notifyListeners();
  }

  void _handleUnauthorized() {
    if (_user == null) {
      return;
    }
    _user = null;
    notifyListeners();
  }
}
