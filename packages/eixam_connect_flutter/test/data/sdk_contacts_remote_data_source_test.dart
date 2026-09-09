import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_contacts_http_support.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_contacts_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sdk_contact_dto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('SdkContactsHttpSupport', () {
    test('maps 503 to unavailable without leaking the raw body as the code',
        () {
      final error = SdkContactsHttpSupport.tryMapHttpFailure(
        http.Response(
          '{"error":{"message":"Service unavailable"}}',
          503,
        ),
        defaultCode: 'E_HTTP_CONTACT_CREATE_FAILED',
      );

      expect(error, isNotNull);
      expect(error!.code, 'E_SDK_CONTACTS_UNAVAILABLE');
      expect(error.statusCode, 503);
    });

    test('maps 422 to validation', () {
      final error = SdkContactsHttpSupport.tryMapHttpFailure(
        http.Response(
          '{"error":{"message":"email required"}}',
          422,
        ),
        defaultCode: 'E_HTTP_CONTACT_CREATE_FAILED',
      );

      expect(error, isNotNull);
      expect(error!.code, 'E_SDK_CONTACTS_VALIDATION');
    });
  });

  group('SdkContactDto', () {
    test('treats missing email as empty', () {
      final dto = SdkContactDto.fromJson(const <String, dynamic>{
        'id': 'c1',
        'name': 'Anna',
        'phone': '+34600000001',
        'priority': 1,
      });
      expect(dto.email, isEmpty);
    });
  });

  group('HttpSdkContactsRemoteDataSource.createContact', () {
    HttpSdkContactsRemoteDataSource buildDataSource(
      _RecordingHttpClient client,
    ) {
      final context = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'canonical-user-1',
          userHash: 'sdk-user-hash',
        );
      return HttpSdkContactsRemoteDataSource(
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

    const createdBody = '''
{"contact":{"id":"c1","name":"Anna","phone":"+34600000001","priority":1}}
''';

    test('omits blank email from the create payload', () async {
      final client = _RecordingHttpClient(
        response: http.Response(createdBody, 200),
      );
      final dataSource = buildDataSource(client);

      await dataSource.createContact(
        name: 'Anna',
        phone: '+34600000001',
        email: '  ',
        priority: 1,
      );

      final request = client.requests.single as http.Request;
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload.containsKey('email'), isFalse);
      expect(payload['name'], 'Anna');
      expect(payload['phone'], '+34600000001');
    });

    test('includes a real email in the create payload', () async {
      final client = _RecordingHttpClient(
        response: http.Response(
          '{"contact":{"id":"c1","name":"Anna","phone":"+34600000001","email":"anna@eixam.test","priority":1}}',
          200,
        ),
      );
      final dataSource = buildDataSource(client);

      await dataSource.createContact(
        name: 'Anna',
        phone: '+34600000001',
        email: 'anna@eixam.test',
        priority: 1,
      );

      final request = client.requests.single as http.Request;
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      expect(payload['email'], 'anna@eixam.test');
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
