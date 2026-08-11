import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_network_psk_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const String _validPsk =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

void main() {
  HttpSdkNetworkPskRemoteDataSource buildDataSource(http.Client client) {
    final context = SdkSessionContext()
      ..currentSession = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'user-1',
        userHash: 'signed-user-hash',
      );
    return HttpSdkNetworkPskRemoteDataSource(
      transport: SdkHttpTransport(
        client: client,
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.staging.eixam.io',
          websocketUrl: 'wss://mqtt.staging.eixam.io',
        ),
        sessionContext: context,
      ),
    );
  }

  String responseBody({
    String psk = _validPsk,
    String algorithm = 'AES-256',
    Object bytes = 32,
    String scope = 'app',
  }) {
    return '{"psk":"$psk","algorithm":"$algorithm",'
        '"bytes":$bytes,"scope":"$scope"}';
  }

  group('HttpSdkNetworkPskRemoteDataSource success', () {
    test('uses signed session and decodes exactly 32 app-scoped bytes',
        () async {
      final client = _RecordingClient(
        response: http.Response(responseBody(), 200),
      );
      final dataSource = buildDataSource(client);

      final material = await dataSource.fetchEffectivePsk();
      final request = client.requests.single;

      expect(request.method, 'GET');
      expect(request.url.path, '/v1/sdk/network/psk');
      expect(request.url.query, isEmpty);
      expect(request.headers['X-App-ID'], 'app-demo');
      expect(request.headers['X-User-ID'], 'user-1');
      expect(request.headers['Authorization'], 'Bearer signed-user-hash');
      expect(material.scope, EffectiveNetworkPskScope.app);
      expect(material.bytes, List<int>.generate(32, (index) => index));

      final ownedBytes = material.bytes;
      material.dispose();
      expect(ownedBytes, everyElement(0));
      expect(() => material.bytes, throwsStateError);
    });

    test('accepts the source-certified global scope without local fallback',
        () async {
      final client = _RecordingClient(
        response: http.Response(responseBody(scope: 'global'), 200),
      );
      final material = await buildDataSource(client).fetchEffectivePsk();

      expect(material.scope, EffectiveNetworkPskScope.global);
      material.dispose();
      expect(client.requests, hasLength(1));
    });
  });

  group('HttpSdkNetworkPskRemoteDataSource malformed response', () {
    final malformedBodies = <String, String>{
      'uppercase hex': responseBody(psk: _validPsk.toUpperCase()),
      'short PSK': responseBody(psk: _validPsk.substring(0, 62)),
      'odd-length PSK': responseBody(psk: _validPsk.substring(0, 63)),
      'long PSK': responseBody(psk: '${_validPsk}00'),
      'non-hex PSK': responseBody(psk: '${_validPsk.substring(0, 63)}z'),
      'wrong algorithm': responseBody(algorithm: 'AES-128'),
      'wrong byte metadata': responseBody(bytes: 31),
      'non-integer byte metadata': responseBody(bytes: '"32"'),
      'floating-point byte metadata': responseBody(bytes: 32.0),
      'unknown scope': responseBody(scope: 'device'),
      'missing field': '{"psk":"$_validPsk","algorithm":"AES-256",'
          '"bytes":32}',
      'extra field':
          '${responseBody().substring(0, responseBody().length - 1)},'
              '"fallback":"global"}',
      'invalid JSON': '{"psk":',
      'non-object JSON': '[]',
    };

    for (final entry in malformedBodies.entries) {
      test('rejects ${entry.key}', () async {
        final dataSource = buildDataSource(
          _RecordingClient(response: http.Response(entry.value, 200)),
        );

        await expectLater(
          dataSource.fetchEffectivePsk(),
          throwsA(_failure(ProvisioningMaterialFailureCode.malformedResponse)),
        );
      });
    }
  });

  group('HttpSdkNetworkPskRemoteDataSource errors', () {
    test('maps a missing signed SDK session to unauthorized', () async {
      final dataSource = HttpSdkNetworkPskRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient(response: http.Response('{}', 200)),
          config: const EixamSdkConfig(
            apiBaseUrl: 'https://api.staging.eixam.io',
          ),
          sessionContext: SdkSessionContext(),
        ),
      );

      await expectLater(
        dataSource.fetchEffectivePsk(),
        throwsA(_failure(ProvisioningMaterialFailureCode.unauthorized)),
      );
    });

    for (final entry in <int, ProvisioningMaterialFailureCode>{
      401: ProvisioningMaterialFailureCode.unauthorized,
      404: ProvisioningMaterialFailureCode.notFound,
      429: ProvisioningMaterialFailureCode.rateLimited,
      500: ProvisioningMaterialFailureCode.backendUnavailable,
      503: ProvisioningMaterialFailureCode.backendUnavailable,
    }.entries) {
      test('maps HTTP ${entry.key}', () async {
        final dataSource = buildDataSource(
          _RecordingClient(
            response: http.Response(
              '{"error":"$_validPsk"}',
              entry.key,
            ),
          ),
        );

        await expectLater(
          dataSource.fetchEffectivePsk(),
          throwsA(_failure(entry.value)),
        );
      });
    }

    test('maps timeout without response details', () async {
      final dataSource = buildDataSource(
        _ThrowingClient(TimeoutException('contains $_validPsk')),
      );

      await expectLater(
        dataSource.fetchEffectivePsk(),
        throwsA(_failure(ProvisioningMaterialFailureCode.timeout)),
      );
    });

    test('maps network failure without response details', () async {
      final dataSource = buildDataSource(
        _ThrowingClient(SocketException('contains $_validPsk')),
      );

      await expectLater(
        dataSource.fetchEffectivePsk(),
        throwsA(_failure(ProvisioningMaterialFailureCode.backendUnavailable)),
      );
    });

    test('exceptions and material diagnostics never contain PSK bytes',
        () async {
      final dataSource = buildDataSource(
        _RecordingClient(response: http.Response('$_validPsk-not-json', 200)),
      );

      try {
        await dataSource.fetchEffectivePsk();
        fail('Expected malformed response.');
      } on ProvisioningMaterialException catch (error) {
        expect(error.toString(), isNot(contains(_validPsk)));
      }

      final material = await buildDataSource(
        _RecordingClient(response: http.Response(responseBody(), 200)),
      ).fetchEffectivePsk();
      expect(material.toString(), isNot(contains(_validPsk)));
      expect(material.toString(), contains('<redacted>'));
      material.dispose();
    });
  });
}

Matcher _failure(ProvisioningMaterialFailureCode code) {
  return isA<ProvisioningMaterialException>().having(
    (error) => error.code,
    'code',
    code,
  );
}

final class _RecordingClient extends http.BaseClient {
  _RecordingClient({required this.response});

  final http.Response response;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

final class _ThrowingClient extends http.BaseClient {
  _ThrowingClient(this.error);

  final Object error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Future<http.StreamedResponse>.error(error);
  }
}
