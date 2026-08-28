import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('SdkSessionStore', () {
    test('does not persist the unused refresh token on new writes', () async {
      final localStore = MemorySharedPrefsSdkStore();
      final store = SdkSessionStore(localStore: localStore);

      await store.save(
        const EixamSession.signed(
          appId: 'app-1',
          externalUserId: 'user-1',
          userHash: 'signed-user-hash',
          sdkUserId: 'sdk-user-1',
          canonicalExternalUserId: 'canonical-user-1',
          refreshToken: 'sdk-refresh-token',
        ),
      );

      final persisted =
          localStore.jsonValues[SharedPrefsSdkStore.sdkSessionKey];

      expect(persisted, isNotNull);
      expect(persisted, isNot(containsPair('refreshToken', anything)));
      expect(persisted?['userHash'], 'signed-user-hash');
    });

    test('continues to read legacy sessions that contain a refresh token',
        () async {
      final localStore = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.sdkSessionKey] = <String, dynamic>{
          'appId': 'app-1',
          'externalUserId': 'user-1',
          'userHash': 'signed-user-hash',
          'sdkUserId': 'sdk-user-1',
          'canonicalExternalUserId': 'canonical-user-1',
          'refreshToken': 'legacy-sdk-refresh-token',
        };
      final store = SdkSessionStore(localStore: localStore);

      final session = await store.load();

      expect(session, isNotNull);
      expect(session?.refreshToken, 'legacy-sdk-refresh-token');
      expect(session?.userHash, 'signed-user-hash');
    });

    test('migrates legacy identity only after verified secure write', () async {
      final localStore = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.sdkSessionKey] = <String, dynamic>{
          'appId': 'app-1',
          'externalUserId': 'user-1',
          'userHash': 'signed-user-hash',
          'sdkUserId': 'sdk-user-1',
        };
      final secureStore = InMemorySecureKeyValueStore();
      final store = SdkSessionStore(
        localStore: localStore,
        secureStore: secureStore,
      );

      final session = await store.load();

      expect(session?.userHash, 'signed-user-hash');
      expect(
        secureStore.values[SecureStorageKeys.sdkSessionIdentity.value],
        contains('signed-user-hash'),
      );
      expect(
        localStore.jsonValues,
        isNot(contains(SharedPrefsSdkStore.sdkSessionKey)),
      );
      expect((await store.load())?.userHash, 'signed-user-hash');
    });

    test('preserves legacy identity when secure write is interrupted',
        () async {
      final localStore = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.sdkSessionKey] = <String, dynamic>{
          'appId': 'app-1',
          'externalUserId': 'user-1',
          'userHash': 'signed-user-hash',
        };
      final store = SdkSessionStore(
        localStore: localStore,
        secureStore: const UnavailableSecureKeyValueStore(),
      );

      await expectLater(
        store.load(),
        throwsA(isA<SecureKeyValueStoreUnavailableException>()),
      );
      expect(
        localStore.jsonValues,
        contains(SharedPrefsSdkStore.sdkSessionKey),
      );
    });

    test('clear removes secure and legacy identity', () async {
      final localStore = MemorySharedPrefsSdkStore()
        ..jsonValues[SharedPrefsSdkStore.sdkSessionKey] = <String, dynamic>{
          'appId': 'legacy',
        };
      final secureStore = InMemorySecureKeyValueStore(<String, String>{
        SecureStorageKeys.sdkSessionIdentity.value: '{}',
      });
      final store = SdkSessionStore(
        localStore: localStore,
        secureStore: secureStore,
      );

      await store.clear();

      expect(localStore.jsonValues, isEmpty);
      expect(secureStore.values, isEmpty);
    });

    test('secure session read failure logs only its operation and type',
        () async {
      final failure = _privateFailure();
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: _ControlledSecureStore(readFailure: failure),
      );

      final captured = await _captureFailure(store.load);

      _expectSafeFailureDiagnostic(
        captured,
        failure: failure,
        operation: 'session_read',
      );
    });

    test('secure session write failure logs only its operation and type',
        () async {
      final failure = _privateFailure();
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: _ControlledSecureStore(writeFailure: failure),
      );

      final captured = await _captureFailure(
        () => store.save(_privateSession()),
      );

      _expectSafeFailureDiagnostic(
        captured,
        failure: failure,
        operation: 'session_write',
      );
    });

    test('secure verification read failure logs its distinct operation',
        () async {
      final failure = _privateFailure();
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: _ControlledSecureStore(readFailure: failure),
      );

      final captured = await _captureFailure(
        () => store.save(_privateSession()),
      );

      _expectSafeFailureDiagnostic(
        captured,
        failure: failure,
        operation: 'session_write_verify_read',
      );
    });

    test('secure verification mismatch retains its typed failure diagnostic',
        () async {
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: _ControlledSecureStore(
          echoWrites: false,
          readValue: 'private-mismatched-secure-value',
        ),
      );

      final captured = await _captureFailure(
        () => store.save(_privateSession()),
      );

      expect(
        captured.error,
        isA<SecureKeyValueStoreUnavailableException>().having(
          (error) => error.code,
          'code',
          'secure_storage_verification_failed',
        ),
      );
      expect(
        captured.diagnostics,
        <String>[
          'SECURE_STORE_OPERATION_FAILED '
              'operation=session_write_verify_read '
              'reason=SecureKeyValueStoreUnavailableException',
        ],
      );
      expect(
        captured.diagnostics.single,
        isNot(contains('private-mismatched-secure-value')),
      );
    });

    test('secure session delete failure logs only its operation and type',
        () async {
      final failure = _privateFailure();
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: _ControlledSecureStore(deleteFailure: failure),
      );

      final captured = await _captureFailure(store.clear);

      _expectSafeFailureDiagnostic(
        captured,
        failure: failure,
        operation: 'session_delete',
      );
    });

    test('unreadable session remains fatal when recovery is disabled',
        () async {
      const failure = SecureKeyValueStoreEntryUnreadableException();
      final secureStore = _ControlledSecureStore(readFailure: failure);
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: secureStore,
      );

      final captured = await _captureFailure(store.load);

      expect(captured.error, same(failure));
      expect(secureStore.deletedKeys, isEmpty);
      expect(
        captured.diagnostics,
        <String>[
          'SECURE_STORE_OPERATION_FAILED operation=session_read '
              'reason=SecureKeyValueStoreEntryUnreadableException',
        ],
      );
    });

    test('recovery deletes only unreadable session and returns absent',
        () async {
      const failure = SecureKeyValueStoreEntryUnreadableException();
      final secureStore = _ControlledSecureStore(
        readFailure: failure,
        initialValues: <String, String>{
          SecureStorageKeys.sdkSessionIdentity.value: 'unreadable-session',
          SecureStorageKeys.sdkSosLifecycleProvenance.value:
              'untouched-sos-provenance',
          'unrelated-secure-entry': 'untouched-value',
        },
      );
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: secureStore,
      );

      final captured = await _captureFailure(
        () => store.load(recoverUnreadableEntry: true),
      );

      expect(captured.error, isNull);
      expect(
        secureStore.deletedKeys,
        <String>[SecureStorageKeys.sdkSessionIdentity.value],
      );
      expect(
        secureStore.values,
        <String, String>{
          SecureStorageKeys.sdkSosLifecycleProvenance.value:
              'untouched-sos-provenance',
          'unrelated-secure-entry': 'untouched-value',
        },
      );
      expect(
        captured.diagnostics,
        <String>[
          'SECURE_STORE_OPERATION_FAILED operation=session_read '
              'reason=SecureKeyValueStoreEntryUnreadableException',
          'SECURE_SESSION_RECOVERY stage=persisted_session_read '
              'reason=entry_unreadable action=deleted_stale_entry',
        ],
      );
    });

    test('delete failure during unreadable session recovery remains fatal',
        () async {
      const readFailure = SecureKeyValueStoreEntryUnreadableException();
      const deleteFailure = SecureKeyValueStoreDeleteException();
      final secureStore = _ControlledSecureStore(
        readFailure: readFailure,
        deleteFailure: deleteFailure,
      );
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: secureStore,
      );

      final captured = await _captureFailure(
        () => store.load(recoverUnreadableEntry: true),
      );

      expect(captured.error, same(deleteFailure));
      expect(
        captured.diagnostics,
        <String>[
          'SECURE_STORE_OPERATION_FAILED operation=session_read '
              'reason=SecureKeyValueStoreEntryUnreadableException',
          'SECURE_STORE_OPERATION_FAILED operation=session_delete '
              'reason=SecureKeyValueStoreDeleteException',
        ],
      );
    });

    test('global secure store failure cannot recover', () async {
      const failure = SecureKeyValueStoreUnavailableException();
      final secureStore = _ControlledSecureStore(readFailure: failure);
      final store = SdkSessionStore(
        localStore: MemorySharedPrefsSdkStore(),
        secureStore: secureStore,
      );

      final captured = await _captureFailure(
        () => store.load(recoverUnreadableEntry: true),
      );

      expect(captured.error, same(failure));
      expect(secureStore.deletedKeys, isEmpty);
      expect(
        captured.diagnostics,
        <String>[
          'SECURE_STORE_OPERATION_FAILED operation=session_read '
              'reason=SecureKeyValueStoreUnavailableException',
        ],
      );
    });
  });
}

SecureKeyValueStoreUnavailableException _privateFailure() =>
    const SecureKeyValueStoreUnavailableException(
      message: 'private-message private-token private-value private-key',
    );

EixamSession _privateSession() => const EixamSession.signed(
      appId: 'private-app-id',
      externalUserId: 'private-external-user-id',
      userHash: 'private-user-hash',
      refreshToken: 'private-refresh-token',
    );

Future<({Object? error, List<String> diagnostics})> _captureFailure(
  Future<void> Function() operation,
) async {
  final diagnostics = <String>[];
  final originalDebugPrint = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message != null) diagnostics.add(message);
  };
  Object? error;
  try {
    await operation();
  } catch (caught) {
    error = caught;
  } finally {
    debugPrint = originalDebugPrint;
  }
  return (error: error, diagnostics: diagnostics);
}

void _expectSafeFailureDiagnostic(
  ({Object? error, List<String> diagnostics}) captured, {
  required Object failure,
  required String operation,
}) {
  expect(captured.error, same(failure));
  expect(
    captured.diagnostics,
    <String>[
      'SECURE_STORE_OPERATION_FAILED operation=$operation '
          'reason=SecureKeyValueStoreUnavailableException',
    ],
  );
  final diagnostic = captured.diagnostics.single;
  for (final privateText in <String>[
    'private-message',
    'private-token',
    'private-value',
    'private-key',
    'private-app-id',
    'private-external-user-id',
    'private-user-hash',
    'private-refresh-token',
    SecureStorageKeys.sdkSessionIdentity.value,
  ]) {
    expect(diagnostic, isNot(contains(privateText)));
  }
}

final class _ControlledSecureStore implements SecureKeyValueStore {
  _ControlledSecureStore({
    this.readFailure,
    this.writeFailure,
    this.deleteFailure,
    this.readValue,
    this.echoWrites = true,
    Map<String, String> initialValues = const <String, String>{},
  }) : _values = Map<String, String>.from(initialValues);

  final Object? readFailure;
  final Object? writeFailure;
  final Object? deleteFailure;
  final String? readValue;
  final bool echoWrites;
  final Map<String, String> _values;
  final List<String> deletedKeys = <String>[];
  String? _writtenValue;

  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  @override
  Future<bool> containsKey(String key) async => (await read(key)) != null;

  @override
  Future<void> delete(String key) async {
    if (deleteFailure case final failure?) throw failure;
    deletedKeys.add(key);
    _values.remove(key);
    _writtenValue = null;
  }

  @override
  Future<void> deleteAll({String? namespace}) async {
    _values.clear();
    _writtenValue = null;
  }

  @override
  Future<String?> read(String key) async {
    if (readFailure case final failure?) throw failure;
    return echoWrites ? (_values[key] ?? _writtenValue) : readValue;
  }

  @override
  Future<void> write(String key, String value) async {
    if (writeFailure case final failure?) throw failure;
    _values[key] = value;
    _writtenValue = value;
  }
}
