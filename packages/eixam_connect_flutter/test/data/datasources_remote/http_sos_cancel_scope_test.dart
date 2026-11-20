import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/http_sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() {
    BleDebugRegistry.instance.reset();
  });

  Future<Map<String, dynamic>?> cancelBody({
    String? incidentId,
    DateTime? occurredAt,
  }) async {
    String? sent;
    final transport = SdkHttpTransport(
      client: MockClient((request) async {
        expect(request.url.path, '/v1/sdk/sos/cancel');
        sent = request.body;
        return http.Response('{"incident":null}', 200);
      }),
      config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      sessionContext: SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'test-app',
          externalUserId: 'test-user',
          userHash: 'test-hash',
        ),
    );
    await HttpSosRemoteDataSource(transport: transport).cancelSos(
      incidentId: incidentId,
      occurredAt: occurredAt,
    );
    final body = sent;
    return body == null || body.isEmpty
        ? null
        : jsonDecode(body) as Map<String, dynamic>;
  }

  // The backend scopes a cancel to the incident it names, or, without one, to
  // incidents opened before the cancel happened: a cancel delivered late must
  // not close an SOS raised since.
  test('cancel says when it happened, in UTC', () async {
    final body = await cancelBody(
      occurredAt: DateTime.parse('2026-04-28T12:20:00+02:00'),
    );
    expect(body, <String, dynamic>{'occurredAt': '2026-04-28T10:20:00.000Z'});
  });

  test('cancel without a time or an incident keeps its empty body', () async {
    expect(await cancelBody(), isNull);
  });

  test('cancel keeps naming its backend incident', () async {
    final body = await cancelBody(incidentId: ' backend-sos-2468 ');
    expect(body, <String, dynamic>{'incidentId': 'backend-sos-2468'});
  });
}
