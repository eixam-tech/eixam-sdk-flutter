import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'shared_prefs_sdk_store.dart';

/// Persists the authenticated SDK identity/bootstrap state between launches.
class SdkSessionStore {
  SdkSessionStore({
    required SharedPrefsSdkStore localStore,
    SecureKeyValueStore? secureStore,
  })  : _localStore = localStore,
        _secureStore = secureStore;

  final SharedPrefsSdkStore _localStore;
  final SecureKeyValueStore? _secureStore;

  Future<void> save(EixamSession session) async {
    final payload = session.toJson()..remove('refreshToken');
    final secureStore = _secureStore;
    if (secureStore == null) {
      await _localStore.saveJson(SharedPrefsSdkStore.sdkSessionKey, payload);
      return;
    }
    final encoded = jsonEncode(payload);
    await secureStore.write(
        SecureStorageKeys.sdkSessionIdentity.value, encoded);
    final verified = await secureStore.read(
      SecureStorageKeys.sdkSessionIdentity.value,
    );
    if (verified != encoded) {
      throw const SecureKeyValueStoreUnavailableException(
        code: 'secure_storage_verification_failed',
        message: 'Secure SDK identity write could not be verified.',
      );
    }
    await _localStore.remove(SharedPrefsSdkStore.sdkSessionKey);
  }

  Future<EixamSession?> load() async {
    final secureStore = _secureStore;
    if (secureStore == null) {
      return _decode(
        await _localStore.readJson(SharedPrefsSdkStore.sdkSessionKey),
      );
    }
    final secureRaw = await secureStore.read(
      SecureStorageKeys.sdkSessionIdentity.value,
    );
    if (secureRaw != null && secureRaw.isNotEmpty) {
      return _decodeRaw(secureRaw);
    }
    final legacy =
        await _localStore.readJson(SharedPrefsSdkStore.sdkSessionKey);
    final session = _decode(legacy);
    if (session == null) return null;
    await save(session);
    return session;
  }

  EixamSession? _decodeRaw(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? _decode(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  EixamSession? _decode(Map<String, dynamic>? json) {
    if (json == null) return null;
    try {
      return EixamSession.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    await _localStore.remove(SharedPrefsSdkStore.sdkSessionKey);
    await _secureStore?.delete(SecureStorageKeys.sdkSessionIdentity.value);
  }
}
