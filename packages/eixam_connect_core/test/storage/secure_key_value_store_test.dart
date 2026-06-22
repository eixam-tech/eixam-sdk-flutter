import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('InMemorySecureKeyValueStore', () {
    test('writes and reads a value', () async {
      final store = InMemorySecureKeyValueStore();
      const key = SecureStorageKeys.sdkSessionIdentity;

      await store.write(key.value, 'signed-session');

      expect(await store.read(key.value), 'signed-session');
      expect(await store.containsKey(key.value), isTrue);
    });

    test('delete removes one key', () async {
      final store = InMemorySecureKeyValueStore();

      await store.write(SecureStorageKeys.appAuthAccessToken.value, 'access');
      await store.write(SecureStorageKeys.appAuthRefreshToken.value, 'refresh');
      await store.delete(SecureStorageKeys.appAuthAccessToken.value);

      expect(
          await store.read(SecureStorageKeys.appAuthAccessToken.value), isNull);
      expect(
        await store.read(SecureStorageKeys.appAuthRefreshToken.value),
        'refresh',
      );
    });

    test('namespace delete removes only matching generated keys', () async {
      final store = InMemorySecureKeyValueStore();

      await store.write(SecureStorageKeys.appAuthAccessToken.value, 'access');
      await store.write(
        SecureStorageKeys.appAuthenticatedContext.value,
        'context',
      );
      await store.write(SecureStorageKeys.sdkSessionIdentity.value, 'sdk');

      await store.deleteAll(namespace: SecureStorageNamespaces.appAuthSession);

      expect(
          await store.read(SecureStorageKeys.appAuthAccessToken.value), isNull);
      expect(
        await store.read(SecureStorageKeys.appAuthenticatedContext.value),
        isNull,
      );
      expect(
          await store.read(SecureStorageKeys.sdkSessionIdentity.value), 'sdk');
    });

    test('namespace delete removes only matching raw namespace keys', () async {
      final store = InMemorySecureKeyValueStore();

      await store.write('sdk.device.preferred.v1', 'device');
      await store.write('sdk.session.identity.v1', 'session');

      await store.deleteAll(namespace: SecureStorageNamespaces.sdkDevice);

      expect(await store.read('sdk.device.preferred.v1'), isNull);
      expect(await store.read('sdk.session.identity.v1'), 'session');
    });

    test('deleteAll without namespace clears the store', () async {
      final store = InMemorySecureKeyValueStore();

      await store.write(SecureStorageKeys.appAuthAccessToken.value, 'access');
      await store.write(SecureStorageKeys.sdkSessionIdentity.value, 'sdk');

      await store.deleteAll();

      expect(store.values, isEmpty);
    });
  });

  group('UnavailableSecureKeyValueStore', () {
    test('fails predictably', () async {
      const store = UnavailableSecureKeyValueStore();

      await expectLater(
        store.read(SecureStorageKeys.sdkSessionIdentity.value),
        throwsA(
          isA<SecureKeyValueStoreUnavailableException>()
              .having(
                (error) => error.code,
                'code',
                UnavailableSecureKeyValueStore.unavailableCode,
              )
              .having(
                (error) => error.message,
                'message',
                'Secure key-value storage is unavailable.',
              ),
        ),
      );
    });
  });

  group('SecureStorageKeys', () {
    test('namespaces are stable', () {
      expect(SecureStorageNamespaces.appAuthSession, 'app.auth.session');
      expect(SecureStorageNamespaces.sdkSession, 'sdk.session');
      expect(SecureStorageNamespaces.sdkDevice, 'sdk.device');
    });

    test('reserved keys are stable', () {
      expect(
        SecureStorageKeys.appAuthAccessToken.value,
        'eixam.app.auth.session.access_token.v1',
      );
      expect(
        SecureStorageKeys.appAuthRefreshToken.value,
        'eixam.app.auth.session.refresh_token.v1',
      );
      expect(
        SecureStorageKeys.appAuthenticatedContext.value,
        'eixam.app.auth.session.authenticated_context.v1',
      );
      expect(
        SecureStorageKeys.sdkSessionIdentity.value,
        'eixam.sdk.session.identity.v1',
      );
    });
  });
}
