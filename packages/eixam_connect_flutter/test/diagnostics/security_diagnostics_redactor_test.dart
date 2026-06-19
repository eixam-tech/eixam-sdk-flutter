import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/http_sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/diagnostics/security_diagnostics_redactor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() {
    BleDebugRegistry.instance.reset();
  });

  group('SecurityDiagnosticsRedactor', () {
    test('redacts raw payload, identity, location, headers, and topics', () {
      final message = SecurityDiagnosticsRedactor.sanitizeEventMessage(
        'payloadHex=01 02 aa bb deviceId=device-secret nodeId=4242 '
        'lat=41.387400 lon=2.168600 X-App-ID=app-secret '
        'X-User-ID=user-secret topic=sos/alerts/sdk-user-secret',
        allowSensitive: false,
      );

      expect(message, isNot(contains('01 02 aa bb')));
      expect(message, isNot(contains('device-secret')));
      expect(message, isNot(contains('4242')));
      expect(message, isNot(contains('41.387400')));
      expect(message, isNot(contains('2.168600')));
      expect(message, isNot(contains('app-secret')));
      expect(message, isNot(contains('user-secret')));
      expect(message, isNot(contains('sdk-user-secret')));
      expect(message, contains('<redacted-hex bytes=4>'));
      expect(message, contains('topic=<redacted-topic>'));
    });

    test('redacts sensitive JSON values directly', () {
      final redacted = SecurityDiagnosticsRedactor.redactJsonValue(
        <String, Object?>{
          'id': 'incident-secret',
          'deviceId': 'device-secret',
          'latitude': 41.3874,
          'longitude': 2.1686,
          'message': 'safe developer note',
        },
      ) as Map<String, Object?>;

      expect(redacted['id'], '<redacted>');
      expect(redacted['deviceId'], '<redacted>');
      expect(redacted['latitude'], '<redacted>');
      expect(redacted['longitude'], '<redacted>');
      expect(redacted['message'], 'safe developer note');
    });
  });

  group('BleDebugRegistry release-like diagnostics', () {
    test('does not retain raw incoming notification payload hex', () {
      BleDebugRegistry.instance.debugSetSensitiveDiagnosticsEnabled(false);

      BleDebugRegistry.instance.recordIncomingNotification(
        channel: 'sos',
        characteristic: '2a37',
        payloadHex: 'de ad be ef',
        receivedAt: DateTime.utc(2026, 1, 1),
      );
      BleDebugRegistry.instance.update(lastCommandSent: '04');

      final state = BleDebugRegistry.instance.currentState;
      expect(state.lastPacketReceived, isNot('de ad be ef'));
      expect(state.lastRawNotificationPayloadHex, isNot('de ad be ef'));
      expect(state.lastCommandSent, isNot('04'));
      expect(state.lastPacketReceived, contains('<redacted-hex bytes=4>'));
      expect(state.lastCommandSent, contains('<redacted-hex bytes=1>'));
    });
  });

  group('HttpSosRemoteDataSource diagnostics', () {
    test('redacts identity headers and omits full request/response bodies',
        () async {
      BleDebugRegistry.instance.debugSetSensitiveDiagnosticsEnabled(false);
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'app-secret',
          externalUserId: 'user-secret@example.com',
          userHash: 'hash-secret',
        );
      final transport = SdkHttpTransport(
        client: MockClient((request) async {
          expect(request.headers['X-App-ID'], 'app-secret');
          expect(request.headers['X-User-ID'], 'user-secret@example.com');
          return http.Response(
            '{"incident":{"id":"incident-secret","state":"cancelled",'
            '"createdAt":"2026-01-01T00:00:00.000Z",'
            '"deviceId":"device-secret","originatorNodeId":4242,'
            '"latitude":41.3874,"longitude":2.1686}}',
            200,
          );
        }),
        config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
        sessionContext: sessionContext,
      );
      final dataSource = HttpSosRemoteDataSource(transport: transport);

      await dataSource.cancelSos(
        deviceId: 'device-secret',
        source: 'remote_lora_relay',
        originatorNodeId: 4242,
        incidentId: 'incident-secret',
        cycleKey: 'sos:4242:incident-secret',
      );

      final diagnostics = BleDebugRegistry.instance.currentState.events
          .map((event) => event.message)
          .join('\n');
      expect(diagnostics, isNot(contains('app-secret')));
      expect(diagnostics, isNot(contains('user-secret@example.com')));
      expect(diagnostics, isNot(contains('hash-secret')));
      expect(diagnostics, isNot(contains('device-secret')));
      expect(diagnostics, isNot(contains('incident-secret')));
      expect(diagnostics, isNot(contains('41.3874')));
      expect(diagnostics, isNot(contains('2.1686')));
      expect(diagnostics, contains('X-App-ID=<redacted>'));
      expect(diagnostics, contains('X-User-ID=<redacted>'));
      expect(diagnostics, contains('body='));
    });
  });
}
