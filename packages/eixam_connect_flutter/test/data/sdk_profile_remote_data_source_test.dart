import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_profile_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('SdkProfileHttpSupport', () {
    test('parses ErrorEnvelope code and message', () {
      final env = SdkProfileHttpSupport.tryParseErrorEnvelope(
        '{"error":{"code":"bad_phone","message":"invalid phone"}}',
      );
      expect(env?.code, 'bad_phone');
      expect(env?.message, 'invalid phone');
    });

    test('maps phone field hint from structured error code', () {
      final hints = SdkProfileHttpSupport.fieldHintsFromEnvelope(
        SdkProfileErrorEnvelope(code: 'bad_phone', message: 'invalid phone'),
        '',
      );
      expect(hints.single.field, SdkProfileFieldKey.phone);
      expect(hints.single.message, 'bad_phone');
    });

    test('maps 400 responses to profile validation exception', () {
      final error = SdkProfileHttpSupport.tryMapHttpFailure(
        http.Response(
          '{"error":{"code":"bad_phone","message":"invalid phone"}}',
          400,
        ),
      );

      expect(error, isNotNull);
      expect(error!.code, 'E_SDK_ME_VALIDATION');
      expect(error.statusCode, 400);
      expect(error.apiErrorCode, 'bad_phone');
      expect(error.fieldHints.single.field, SdkProfileFieldKey.phone);
    });

    test('maps 429 responses to rate limit exception', () {
      final error = SdkProfileHttpSupport.tryMapHttpFailure(
        http.Response(
          '{"error":{"code":"rate_limited","message":"too many requests"}}',
          429,
        ),
      );

      expect(error, isNotNull);
      expect(error!.code, 'E_SDK_ME_RATE_LIMITED');
      expect(error.statusCode, 429);
      expect(error.apiErrorCode, 'rate_limited');
    });

    test('returns null for success responses', () {
      final error = SdkProfileHttpSupport.tryMapHttpFailure(
        http.Response('{"user":{}}', 200),
      );

      expect(error, isNull);
    });
  });

  group('HttpSdkProfileRemoteDataSource.deleteUserData', () {
    test('sends SDK signed headers and accepts 404', () async {
      final client = _RecordingHttpClient(
        response: http.Response('', 404),
      );
      final dataSource = HttpSdkProfileRemoteDataSource(
        transport: SdkHttpTransport(
          client: client,
          config: const EixamSdkConfig(
            apiBaseUrl: 'https://api.staging.eixam.io',
            websocketUrl: 'wss://mqtt.staging.eixam.io',
          ),
          sessionContext: SdkSessionContext(),
        ),
      );

      await dataSource.deleteUserData(
        sessionOverride: const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'canonical-user-1',
          userHash: 'sdk-user-hash',
        ),
      );

      expect(client.requests, hasLength(1));
      final request = client.requests.single;
      expect(request.method, 'DELETE');
      expect(request.url.path, '/v1/sdk/me');
      expect(request.headers['X-App-ID'], 'app-demo');
      expect(request.headers['X-User-ID'], 'canonical-user-1');
      expect(request.headers['Authorization'], 'Bearer sdk-user-hash');
    });
  });

  group('SdkHttpTransport', () {
    test('maps backend socket failures to NetworkException with stable code',
        () async {
      final transport = SdkHttpTransport(
        client: _ThrowingHttpClient(const SocketException('offline')),
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.staging.eixam.io',
          websocketUrl: 'wss://mqtt.staging.eixam.io',
        ),
        sessionContext: SdkSessionContext()
          ..currentSession = const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'canonical-user-1',
            userHash: 'sdk-user-hash',
          ),
      );

      await expectLater(
        transport.get('/v1/sdk/me'),
        throwsA(
          isA<NetworkException>()
              .having(
                (error) => error.code,
                'code',
                'E_SDK_HTTP_GET_FAILED',
              )
              .having(
                (error) => error.message,
                'message',
                'offline',
              ),
        ),
      );
    });
  });
}

final class _RecordingHttpClient extends http.BaseClient {
  _RecordingHttpClient({required this.response});

  final http.Response response;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
      request: request,
    );
  }
}

final class _ThrowingHttpClient extends http.BaseClient {
  _ThrowingHttpClient(this.error);

  final Object error;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw error;
  }
}
