import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/storage/platform_secure_key_value_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test.eixam/secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('native entry unreadable maps to its typed Dart exception', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) => throw PlatformException(
        code: 'secure_storage_entry_unreadable',
        message: 'private-native-message',
      ),
    );
    final store = PlatformSecureKeyValueStore(methodChannel: channel);

    await expectLater(
      store.read('private-key'),
      throwsA(
        isA<SecureKeyValueStoreEntryUnreadableException>()
            .having(
              (error) => error.code,
              'code',
              'secure_storage_entry_unreadable',
            )
            .having(
              (error) => error.message,
              'message',
              isNot(contains('private-native-message')),
            ),
      ),
    );
  });

  test('native unavailable remains a typed unavailable exception', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) => throw PlatformException(
        code: 'secure_storage_unavailable',
        message: 'private-native-message',
      ),
    );
    final store = PlatformSecureKeyValueStore(methodChannel: channel);

    await expectLater(
      store.read('private-key'),
      throwsA(isA<SecureKeyValueStoreUnavailableException>()),
    );
  });

  test('native write failure remains distinguishable', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) => throw PlatformException(
        code: 'secure_storage_write_failed',
        message: 'private-native-message',
      ),
    );
    final store = PlatformSecureKeyValueStore(methodChannel: channel);

    await expectLater(
      store.write('private-key', 'private-value'),
      throwsA(isA<SecureKeyValueStoreWriteException>()),
    );
  });

  test('native delete failure remains distinguishable', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) => throw PlatformException(
        code: 'secure_storage_delete_failed',
        message: 'private-native-message',
      ),
    );
    final store = PlatformSecureKeyValueStore(methodChannel: channel);

    await expectLater(
      store.delete('private-key'),
      throwsA(isA<SecureKeyValueStoreDeleteException>()),
    );
  });

  test('missing plugin remains globally unavailable', () async {
    final store = PlatformSecureKeyValueStore(methodChannel: channel);

    await expectLater(
      store.read('private-key'),
      throwsA(isA<SecureKeyValueStoreUnavailableException>()),
    );
  });
}
