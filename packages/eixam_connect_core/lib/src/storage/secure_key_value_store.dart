/// A small, platform-neutral key-value contract for future secure storage.
///
/// SEC-STORAGE Phase 1 is abstraction-only: no platform secure-storage
/// dependency is selected here, and no app auth or SDK session data is migrated
/// from the existing SharedPreferences stores by this contract alone.
abstract interface class SecureKeyValueStore {
  /// Reads the value for [key], or returns null when the key is absent.
  Future<String?> read(String key);

  /// Stores [value] for [key].
  Future<void> write(String key, String value);

  /// Deletes [key]. Deleting an absent key is a successful no-op.
  Future<void> delete(String key);

  /// Deletes keys under [namespace], or every key when [namespace] is null.
  Future<void> deleteAll({String? namespace});

  /// Returns true when [key] currently exists.
  Future<bool> containsKey(String key);
}

/// Stable logical namespaces reserved for future secure-storage keys.
abstract final class SecureStorageNamespaces {
  static const String appAuthSession = 'app.auth.session';
  static const String sdkSession = 'sdk.session';
  static const String sdkDevice = 'sdk.device';
  static const String sdkSosLifecycle = 'sdk.sos.lifecycle';
}

/// Stable secure-storage key constants reserved for future migrations.
abstract final class SecureStorageKeys {
  static const SecureStorageKey appAuthAccessToken = SecureStorageKey(
    namespace: SecureStorageNamespaces.appAuthSession,
    name: 'access_token',
  );

  static const SecureStorageKey appAuthRefreshToken = SecureStorageKey(
    namespace: SecureStorageNamespaces.appAuthSession,
    name: 'refresh_token',
  );

  static const SecureStorageKey appAuthenticatedContext = SecureStorageKey(
    namespace: SecureStorageNamespaces.appAuthSession,
    name: 'authenticated_context',
  );

  static const SecureStorageKey sdkSessionIdentity = SecureStorageKey(
    namespace: SecureStorageNamespaces.sdkSession,
    name: 'identity',
  );

  static const SecureStorageKey sdkSosLifecycleProvenance = SecureStorageKey(
    namespace: SecureStorageNamespaces.sdkSosLifecycle,
    name: 'provenance',
  );

  /// Returns the key prefix used for [namespace].
  static String namespacePrefix(String namespace) => 'eixam.$namespace.';
}

/// A versioned secure-storage key.
final class SecureStorageKey {
  const SecureStorageKey({
    required this.namespace,
    required this.name,
    this.version = 1,
  });

  final String namespace;
  final String name;
  final int version;

  String get value =>
      '${SecureStorageKeys.namespacePrefix(namespace)}$name.v$version';
}

/// Deterministic in-memory secure key-value store for tests.
final class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  InMemorySecureKeyValueStore([Map<String, String>? initialValues])
      : _values =
            Map<String, String>.from(initialValues ?? const <String, String>{});

  final Map<String, String> _values;

  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> deleteAll({String? namespace}) async {
    if (namespace == null) {
      _values.clear();
      return;
    }

    final generatedPrefix = SecureStorageKeys.namespacePrefix(namespace);
    final rawPrefix = '$namespace.';
    _values.removeWhere(
      (key, _) => key.startsWith(generatedPrefix) || key.startsWith(rawPrefix),
    );
  }

  @override
  Future<bool> containsKey(String key) async => _values.containsKey(key);
}

/// Secure store implementation for builds/tests where secure storage is absent.
final class UnavailableSecureKeyValueStore implements SecureKeyValueStore {
  const UnavailableSecureKeyValueStore();

  static const String unavailableCode = 'secure_storage_unavailable';

  @override
  Future<String?> read(String key) => _fail();

  @override
  Future<void> write(String key, String value) => _fail();

  @override
  Future<void> delete(String key) => _fail();

  @override
  Future<void> deleteAll({String? namespace}) => _fail();

  @override
  Future<bool> containsKey(String key) => _fail();

  Future<T> _fail<T>() => Future<T>.error(
        const SecureKeyValueStoreUnavailableException(),
      );
}

/// Base type for stable, non-sensitive secure-storage failure classifications.
sealed class SecureKeyValueStoreException implements Exception {
  const SecureKeyValueStoreException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;
}

final class SecureKeyValueStoreEntryUnreadableException
    extends SecureKeyValueStoreException {
  const SecureKeyValueStoreEntryUnreadableException({
    super.code = 'secure_storage_entry_unreadable',
    super.message = 'Secure key-value storage entry is unreadable.',
  });

  @override
  String toString() =>
      'SecureKeyValueStoreEntryUnreadableException($code): $message';
}

final class SecureKeyValueStoreWriteException
    extends SecureKeyValueStoreException {
  const SecureKeyValueStoreWriteException({
    super.code = 'secure_storage_write_failed',
    super.message = 'Secure key-value storage write failed.',
  });

  @override
  String toString() => 'SecureKeyValueStoreWriteException($code): $message';
}

final class SecureKeyValueStoreDeleteException
    extends SecureKeyValueStoreException {
  const SecureKeyValueStoreDeleteException({
    super.code = 'secure_storage_delete_failed',
    super.message = 'Secure key-value storage delete failed.',
  });

  @override
  String toString() => 'SecureKeyValueStoreDeleteException($code): $message';
}

final class SecureKeyValueStoreUnavailableException
    extends SecureKeyValueStoreException {
  const SecureKeyValueStoreUnavailableException({
    super.code = UnavailableSecureKeyValueStore.unavailableCode,
    super.message = 'Secure key-value storage is unavailable.',
  });

  @override
  String toString() =>
      'SecureKeyValueStoreUnavailableException($code): $message';
}
