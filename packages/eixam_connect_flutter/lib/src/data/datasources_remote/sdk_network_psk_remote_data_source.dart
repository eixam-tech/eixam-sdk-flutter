import 'dart:convert';
import 'dart:typed_data';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'sdk_http_transport.dart';

/// Internal scope metadata returned by the server-authoritative PSK resolver.
enum EffectiveNetworkPskScope { app, global }

/// Ephemeral implementation-layer owner of effective network PSK bytes.
///
/// This type is intentionally kept under `lib/src`, is not exported by either
/// public package barrel, and must never be persisted or included in SDK state.
final class EffectiveNetworkPsk {
  EffectiveNetworkPsk._({
    required Uint8List bytes,
    required this.scope,
  }) : _bytes = bytes;

  Uint8List _bytes;
  final EffectiveNetworkPskScope scope;
  bool _disposed = false;

  /// Mutable bytes owned by this object. Callers must not retain this reference
  /// beyond the operation that consumes it.
  Uint8List get bytes {
    if (_disposed) {
      throw StateError('Effective network PSK has been disposed.');
    }
    return _bytes;
  }

  /// Best-effort zeroing for the mutable buffer owned by this object.
  void dispose() {
    if (_disposed) {
      return;
    }
    _bytes.fillRange(0, _bytes.length, 0);
    _bytes = Uint8List(0);
    _disposed = true;
  }

  @override
  String toString() =>
      'EffectiveNetworkPsk(scope: ${scope.name}, bytes: <redacted>)';
}

enum ProvisioningMaterialFailureCode {
  unauthorized,
  notFound,
  rateLimited,
  backendUnavailable,
  timeout,
  malformedResponse,
}

/// Secret-safe internal failure for provisioning-material acquisition.
final class ProvisioningMaterialException implements Exception {
  const ProvisioningMaterialException(this.code);

  final ProvisioningMaterialFailureCode code;

  @override
  String toString() => 'ProvisioningMaterialException(code: ${code.name})';
}

abstract interface class SdkNetworkPskRemoteDataSource {
  Future<EffectiveNetworkPsk> fetchEffectivePsk();
}

/// Signed-session client for `GET /v1/sdk/network/psk`.
///
/// Resolution between app-specific and global PSKs is exclusively a backend
/// concern. This client accepts only the exact source-certified response.
final class HttpSdkNetworkPskRemoteDataSource
    implements SdkNetworkPskRemoteDataSource {
  HttpSdkNetworkPskRemoteDataSource({required this.transport});

  static const String _path = '/v1/sdk/network/psk';
  static final RegExp _lowerHex64 = RegExp(r'^[0-9a-f]{64}$');
  static const Set<String> _responseKeys = <String>{
    'psk',
    'algorithm',
    'bytes',
    'scope',
  };

  final SdkHttpTransport transport;

  @override
  Future<EffectiveNetworkPsk> fetchEffectivePsk() async {
    try {
      final response = await transport.get(
        _path,
        headers: const <String, String>{'Accept': 'application/json'},
      );
      switch (response.statusCode) {
        case 200:
          final body = _decodeBody(response.body);
          try {
            return _parseBody(body);
          } finally {
            // Drop the map's reference to the PSK string as soon as parsing is
            // complete. Dart cannot guarantee String zeroization.
            body.clear();
          }
        case 401:
          throw const ProvisioningMaterialException(
            ProvisioningMaterialFailureCode.unauthorized,
          );
        case 404:
          throw const ProvisioningMaterialException(
            ProvisioningMaterialFailureCode.notFound,
          );
        case 429:
          throw const ProvisioningMaterialException(
            ProvisioningMaterialFailureCode.rateLimited,
          );
        default:
          throw const ProvisioningMaterialException(
            ProvisioningMaterialFailureCode.backendUnavailable,
          );
      }
    } on ProvisioningMaterialException {
      rethrow;
    } on AuthException {
      throw const ProvisioningMaterialException(
        ProvisioningMaterialFailureCode.unauthorized,
      );
    } on NetworkException catch (error) {
      if (error.code == 'E_SDK_HTTP_TIMEOUT') {
        throw const ProvisioningMaterialException(
          ProvisioningMaterialFailureCode.timeout,
        );
      }
      throw const ProvisioningMaterialException(
        ProvisioningMaterialFailureCode.backendUnavailable,
      );
    } catch (_) {
      throw const ProvisioningMaterialException(
        ProvisioningMaterialFailureCode.backendUnavailable,
      );
    }
  }

  Map<String, dynamic> _decodeBody(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const ProvisioningMaterialException(
        ProvisioningMaterialFailureCode.malformedResponse,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ProvisioningMaterialException(
        ProvisioningMaterialFailureCode.malformedResponse,
      );
    }
    return decoded;
  }

  EffectiveNetworkPsk _parseBody(Map<String, dynamic> body) {
    if (body.length != _responseKeys.length ||
        !_responseKeys.every(body.containsKey)) {
      throw const ProvisioningMaterialException(
        ProvisioningMaterialFailureCode.malformedResponse,
      );
    }
    final psk = body['psk'];
    final algorithm = body['algorithm'];
    final byteCount = body['bytes'];
    final scopeValue = body['scope'];
    if (psk is! String ||
        !_lowerHex64.hasMatch(psk) ||
        algorithm != 'AES-256' ||
        byteCount is! int ||
        byteCount != 32 ||
        (scopeValue != 'app' && scopeValue != 'global')) {
      throw const ProvisioningMaterialException(
        ProvisioningMaterialFailureCode.malformedResponse,
      );
    }

    return EffectiveNetworkPsk._(
      bytes: _decodeHex(psk),
      scope: scopeValue == 'app'
          ? EffectiveNetworkPskScope.app
          : EffectiveNetworkPskScope.global,
    );
  }

  Uint8List _decodeHex(String value) {
    final bytes = Uint8List(32);
    for (var index = 0; index < bytes.length; index++) {
      final high = _hexNibble(value.codeUnitAt(index * 2));
      final low = _hexNibble(value.codeUnitAt(index * 2 + 1));
      bytes[index] = (high << 4) | low;
    }
    return bytes;
  }

  int _hexNibble(int codeUnit) {
    return codeUnit <= 57 ? codeUnit - 48 : codeUnit - 87;
  }
}
