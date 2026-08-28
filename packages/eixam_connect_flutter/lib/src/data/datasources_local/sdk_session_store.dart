import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../storage/secure_store_operation_diagnostics.dart';
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
    try {
      await secureStore.write(
        SecureStorageKeys.sdkSessionIdentity.value,
        encoded,
      );
    } on SecureKeyValueStoreException catch (error) {
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sessionWrite,
        error,
      );
      rethrow;
    }
    late final String? verified;
    try {
      verified = await secureStore.read(
        SecureStorageKeys.sdkSessionIdentity.value,
      );
    } on SecureKeyValueStoreException catch (error) {
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sessionWriteVerifyRead,
        error,
      );
      rethrow;
    }
    if (verified != encoded) {
      const error = SecureKeyValueStoreUnavailableException(
        code: 'secure_storage_verification_failed',
        message: 'Secure SDK identity write could not be verified.',
      );
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sessionWriteVerifyRead,
        error,
      );
      throw error;
    }
    await _localStore.remove(SharedPrefsSdkStore.sdkSessionKey);
  }

  Future<EixamSession?> load({bool recoverUnreadableEntry = false}) async {
    final secureStore = _secureStore;
    if (secureStore == null) {
      return _decode(
        await _localStore.readJson(SharedPrefsSdkStore.sdkSessionKey),
      );
    }
    late final String? secureRaw;
    try {
      secureRaw = await secureStore.read(
        SecureStorageKeys.sdkSessionIdentity.value,
      );
    } on SecureKeyValueStoreEntryUnreadableException catch (error) {
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sessionRead,
        error,
      );
      if (!recoverUnreadableEntry) rethrow;
      try {
        await secureStore.delete(SecureStorageKeys.sdkSessionIdentity.value);
      } on SecureKeyValueStoreException catch (deleteError) {
        reportSecureStoreOperationFailure(
          SecureStoreOperation.sessionDelete,
          deleteError,
        );
        rethrow;
      }
      reportSecureSessionRecovery();
      return null;
    } on SecureKeyValueStoreException catch (error) {
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sessionRead,
        error,
      );
      rethrow;
    }
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
    final secureStore = _secureStore;
    if (secureStore == null) return;
    try {
      await secureStore.delete(SecureStorageKeys.sdkSessionIdentity.value);
    } on SecureKeyValueStoreException catch (error) {
      reportSecureStoreOperationFailure(
        SecureStoreOperation.sessionDelete,
        error,
      );
      rethrow;
    }
  }
}
