import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_device_config_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  HttpSdkDeviceConfigRemoteDataSource buildDataSource(
    _RecordingHttpClient client,
  ) {
    final context = SdkSessionContext()
      ..currentSession = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'canonical-user-1',
        userHash: 'sdk-user-hash',
      );
    return HttpSdkDeviceConfigRemoteDataSource(
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

  group('HttpSdkDeviceConfigRemoteDataSource', () {
    test('sends country_iso query with signed headers and parses payload',
        () async {
      final client = _RecordingHttpClient(
        response: http.Response(
          '{"region":"EU868","lora_region_code":3,"country":"IT",'
          '"duty_cycle":1.0}',
          200,
        ),
      );
      final dataSource = buildDataSource(client);

      final config = await dataSource.fetchByCountry(countryIso: 'es');

      final request = client.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/sdk/device-configs');
      expect(request.url.queryParameters['country_iso'], 'es');
      expect(request.headers['X-App-ID'], 'app-demo');
      expect(request.headers['X-User-ID'], 'canonical-user-1');
      expect(request.headers['Authorization'], 'Bearer sdk-user-hash');
      expect(config.deviceConfig, 'EU868');
      expect(config.loraRegionByte, 3);
      expect(config.regionByte, 3);
      expect(config.regionCode, LoraRegionCode.eu868);
      expect(config.raw['duty_cycle'], 1.0);
    });

    test('omits country_iso when not provided', () async {
      final client = _RecordingHttpClient(
        response: http.Response('{"device_config":"EU868"}', 200),
      );
      final dataSource = buildDataSource(client);

      await dataSource.fetchByCountry();

      final request = client.requests.single;
      expect(request.url.queryParameters.containsKey('country_iso'), isFalse);
    });

    test('treats 404 as an empty config that falls back to EU (no throw)',
        () async {
      final client = _RecordingHttpClient(response: http.Response('', 404));
      final dataSource = buildDataSource(client);

      final config = await dataSource.fetchByCountry(countryIso: 'XX');

      // No byte from the backend -> EU868 fallback, never left region-less.
      expect(config.deviceConfig, isNull);
      expect(config.loraRegionByte, isNull);
      expect(config.regionByte, LoraRegionCode.eu868.wireValue);
      expect(config.regionCode, LoraRegionCode.eu868);
      expect(config.hasApplicableRegion, isTrue);
    });

    test('maps other non-2xx responses to NetworkException', () async {
      final client = _RecordingHttpClient(
        response: http.Response('boom', 500),
      );
      final dataSource = buildDataSource(client);

      expect(
        () => dataSource.fetchByCountry(countryIso: 'ES'),
        throwsA(isA<NetworkException>()),
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
