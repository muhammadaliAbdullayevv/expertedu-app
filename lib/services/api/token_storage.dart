import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

class TokenStorage {
  // encryptedSharedPreferences avoids a well-known hang in the raw
  // AndroidKeyStore path on some Samsung devices/firmware.
  TokenStorage()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
      );

  final FlutterSecureStorage _storage;
  static const _tokenKey = 'auth_token';
  static const _gatewayKeyKey = 'sms_gateway_key';
  static const _gatewayEnabledKey = 'sms_gateway_enabled';
  static const _savedAccountsKey = 'saved_accounts';
  static const _lastFcmTokenKey = 'last_fcm_token';
  static const _useDynamicColorKey = 'use_dynamic_color';

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<void> saveToken(String token) => _storage.write(key: _tokenKey, value: token);

  Future<void> clearToken() => _storage.delete(key: _tokenKey);

  /// The raw JSON list backing the account switcher -- kept as an opaque
  /// string here (encode/decode lives in AuthRepository, which owns the
  /// SavedAccount shape) so this class stays a plain key/value store like
  /// the rest of it.
  Future<String?> readSavedAccountsRaw() => _storage.read(key: _savedAccountsKey);

  Future<void> saveSavedAccountsRaw(String json) =>
      _storage.write(key: _savedAccountsKey, value: json);

  Future<String?> readGatewayKey() => _storage.read(key: _gatewayKeyKey);

  Future<void> saveGatewayKey(String key) => _storage.write(key: _gatewayKeyKey, value: key);

  Future<bool> readGatewayEnabled() async {
    return (await _storage.read(key: _gatewayEnabledKey)) == 'true';
  }

  Future<void> saveGatewayEnabled(bool enabled) {
    return _storage.write(key: _gatewayEnabledKey, value: enabled ? 'true' : 'false');
  }

  /// The FCM token this device last successfully registered with the
  /// server -- lets PushNotificationsService notice when Firebase has
  /// issued a *different* token (a reinstall, cleared app data, or a
  /// routine Firebase-side rotation) and clean up the old registration
  /// instead of leaving it behind as a second, stale row that still gets
  /// pushed to, duplicating every notification on this one device.
  Future<String?> readLastFcmToken() => _storage.read(key: _lastFcmTokenKey);

  Future<void> saveLastFcmToken(String token) =>
      _storage.write(key: _lastFcmTokenKey, value: token);

  Future<void> clearLastFcmToken() => _storage.delete(key: _lastFcmTokenKey);

  /// Defaults to false -- Material You's wallpaper-extracted palette can
  /// look nothing like the deliberately chosen SAFO CITY brand colors (see
  /// AppTheme's own doc comment), so this stays an explicit opt-in rather
  /// than silently overriding the brand look for everyone.
  Future<bool> readUseDynamicColor() async {
    return (await _storage.read(key: _useDynamicColorKey)) == 'true';
  }

  Future<void> saveUseDynamicColor(bool enabled) {
    return _storage.write(key: _useDynamicColorKey, value: enabled ? 'true' : 'false');
  }
}
