import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';

/// Keychain/Android-Keystore-backed storage for authentication secrets.
final class PlatformSecureKeyValueStore implements SecureKeyValueStore {
  PlatformSecureKeyValueStore({MethodChannel? methodChannel})
      : _methodChannel =
            methodChannel ?? const MethodChannel(_methodChannelName);

  static const String _methodChannelName =
      'dev.eixam.connect.flutter/secure_storage';

  final MethodChannel _methodChannel;

  @override
  Future<bool> containsKey(String key) async => (await read(key)) != null;

  @override
  Future<void> delete(String key) => _invokeVoid('delete', <String, Object>{
        'key': key,
      });

  @override
  Future<void> deleteAll({String? namespace}) =>
      _invokeVoid('deleteAll', <String, Object?>{'namespace': namespace});

  @override
  Future<String?> read(String key) async {
    try {
      return await _methodChannel.invokeMethod<String>('read', <String, Object>{
        'key': key,
      });
    } on PlatformException catch (error) {
      throw SecureKeyValueStoreUnavailableException(
        code: error.code,
        message: error.message ?? 'Platform secure storage is unavailable.',
      );
    } on MissingPluginException {
      throw const SecureKeyValueStoreUnavailableException();
    }
  }

  @override
  Future<void> write(String key, String value) =>
      _invokeVoid('write', <String, Object>{'key': key, 'value': value});

  Future<void> _invokeVoid(
      String method, Map<String, Object?> arguments) async {
    try {
      await _methodChannel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error) {
      throw SecureKeyValueStoreUnavailableException(
        code: error.code,
        message: error.message ?? 'Platform secure storage is unavailable.',
      );
    } on MissingPluginException {
      throw const SecureKeyValueStoreUnavailableException();
    }
  }
}
