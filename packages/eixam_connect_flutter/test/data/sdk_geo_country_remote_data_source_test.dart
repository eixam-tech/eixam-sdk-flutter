import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_geo_country_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  HttpSdkGeoCountryRemoteDataSource buildDataSource(
    _RecordingHttpClient client,
  ) {
    final context = SdkSessionContext()
      ..currentSession = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'canonical-user-1',
        userHash: 'sdk-user-hash',
      );
    return HttpSdkGeoCountryRemoteDataSource(
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

  group('HttpSdkGeoCountryRemoteDataSource', () {
    test('sends lat/lon query and upper-cases the resolved ISO', () async {
      final client = _RecordingHttpClient(
        response: http.Response('{"country_iso":"es"}', 200),
      );
      final dataSource = buildDataSource(client);

      final resolved =
          await dataSource.resolveCountry(latitude: 41.38, longitude: 2.17);

      final request = client.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/sdk/geo/country');
      expect(request.url.queryParameters['lat'], '41.38');
      expect(request.url.queryParameters['lon'], '2.17');
      expect(request.headers['X-App-ID'], 'app-demo');
      expect(resolved.countryIso, 'ES');
    });

    test('throws when country_iso is missing or blank', () async {
      final client = _RecordingHttpClient(
        response: http.Response('{"country_iso":""}', 200),
      );
      final dataSource = buildDataSource(client);

      expect(
        () => dataSource.resolveCountry(latitude: 0, longitude: 0),
        throwsA(isA<NetworkException>()),
      );
    });

    test('maps non-2xx responses to NetworkException', () async {
      final client = _RecordingHttpClient(
        response: http.Response('boom', 503),
      );
      final dataSource = buildDataSource(client);

      expect(
        () => dataSource.resolveCountry(latitude: 0, longitude: 0),
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
