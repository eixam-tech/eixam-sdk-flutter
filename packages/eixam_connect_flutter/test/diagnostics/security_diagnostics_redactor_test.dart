import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/http_sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/diagnostics/security_diagnostics_redactor.dart';
import 'package:eixam_connect_flutter/src/sdk/location_debug_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  tearDown(() {
    BleDebugRegistry.instance.reset();
  });

  group('SecurityDiagnosticsRedactor', () {
    test('location authority diagnostics are disabled by default', () {
      expect(LocationDebugLog.enabled, isFalse);
    });

    test('redacts raw payload, identity, location, headers, and topics', () {
      final message = SecurityDiagnosticsRedactor.sanitizeEventMessage(
        'payloadHex=01 02 aa bb deviceId=device-secret nodeId=4242 '
        'lat=41.387400 lon=2.168600 lng=2.168600 X-App-ID=app-secret '
        'X-User-ID=user-secret signature=sos:device-secret:deadbeef '
        'lastPacketSignature=4242:de ad be ef '
        'topic=sos/alerts/sdk-user-secret',
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
      expect(message, isNot(contains('deadbeef')));
      expect(message, isNot(contains('4242:de ad be ef')));
      expect(message, contains('packet_bytes_present=true'));
      expect(message, contains('device_identity_present=true'));
      expect(message, contains('originator_identity_present=true'));
      expect(message, contains('packet_identity_present=true'));
      expect(message, contains('topic_category=operational'));
    });

    test('redacts bridge-style summaries with raw BLE payloads', () {
      final message = SecurityDiagnosticsRedactor.sanitizeEventMessage(
        'device=AA:BB:CC:DD:EE:FF nodeId=0x01020304 (16909060) '
        'lat=41.3874 lng=2.1686 '
        'raw=de ad be ef',
        allowSensitive: false,
      );

      expect(message, isNot(contains('AA:BB:CC:DD:EE:FF')));
      expect(message, isNot(contains('41.3874')));
      expect(message, isNot(contains('2.1686')));
      expect(message, isNot(contains('16909060')));
      expect(message, isNot(contains('de ad be ef')));
      expect(message, contains('device_identity_present=true'));
      expect(message, contains('packet_bytes_present=true'));
    });

    test('formatters suppress raw BLE payloads, identifiers, and coordinates',
        () {
      expect(
        SecurityDiagnosticsRedactor.formatHexPayloadForDiagnostics(
          'de ad be ef',
          allowSensitive: false,
        ),
        '<redacted-hex bytes=4>',
      );
      expect(
        SecurityDiagnosticsRedactor.formatIdentifierForDiagnostics(
          'device-secret',
          allowSensitive: false,
        ),
        '<redacted>',
      );
      expect(
        SecurityDiagnosticsRedactor.formatCoordinateForDiagnostics(
          41.3874,
          allowSensitive: false,
        ),
        '<redacted>',
      );
    });

    test('formatters keep detailed diagnostics when sensitive mode is allowed',
        () {
      expect(
        SecurityDiagnosticsRedactor.formatHexPayloadForDiagnostics(
          'de ad be ef',
          allowSensitive: true,
        ),
        'de ad be ef',
      );
      expect(
        SecurityDiagnosticsRedactor.formatCoordinateForDiagnostics(
          41.3874,
          allowSensitive: true,
        ),
        '41.3874',
      );
    });

    test('redacts sensitive JSON values directly', () {
      final redacted = SecurityDiagnosticsRedactor.redactJsonValue(
        <String, Object?>{
          'id': 'incident-secret',
          'deviceId': 'device-secret',
          'latitude': 41.3874,
          'longitude': 2.1686,
          'message': 'safe developer note',
          'psk': 'psk-secret',
          'network_psk': 'network-psk-secret',
          'softSim': 'softsim-secret',
          'backendToken': 'backend-token-secret',
        },
      ) as Map<String, Object?>;

      expect(redacted['id'], '<redacted>');
      expect(redacted['deviceId'], '<redacted>');
      expect(redacted['latitude'], '<redacted>');
      expect(redacted['longitude'], '<redacted>');
      expect(redacted['message'], 'safe developer note');
      expect(redacted['psk'], '<redacted>');
      expect(redacted['network_psk'], '<redacted>');
      expect(redacted['softSim'], '<redacted>');
      expect(redacted['backendToken'], '<redacted>');
    });

    test('always suppresses secret-bearing BLE command payloads', () {
      const secretHex =
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

      expect(
        SecurityDiagnosticsRedactor.formatBleCommandPayloadForDiagnostics(
          secretHex,
          containsSecret: true,
        ),
        SecurityDiagnosticsRedactor.redactedPayload,
      );
      expect(
        SecurityDiagnosticsRedactor.formatBleCommandPayloadForDiagnostics(
          '23',
          containsSecret: false,
        ),
        '23',
      );
    });

    test('redacts provisioning secrets in event messages', () {
      const secret =
          '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
      for (final allowSensitive in <bool>[false, true]) {
        final message = SecurityDiagnosticsRedactor.sanitizeEventMessage(
          'psk=$secret networkPsk=$secret softSim=$secret '
          'backendToken=$secret result=rejected',
          allowSensitive: allowSensitive,
        );

        expect(message, isNot(contains(secret)));
        expect(message, contains('secret_present=true'));
      }
    });

    test('converts raw exceptions to bounded categories', () {
      final message = SecurityDiagnosticsRedactor.sanitizeEventMessage(
        'SOS_BACKEND_FAILED error=SocketException: host user-secret '
        'retry=2',
        allowSensitive: false,
      );

      expect(message, contains('error_category=transport'));
      expect(message, contains('retry=2'));
      expect(message, isNot(contains('host user-secret')));
    });

    test('never exposes attempt IDs or exact timestamps', () {
      for (final allowSensitive in <bool>[false, true]) {
        final message = SecurityDiagnosticsRedactor.sanitizeEventMessage(
          'DEVICE_RECONNECT attemptId=app-1737 '
          'lastPacketAt=2026-07-27T10:11:12.123Z '
          'updatedAt=2026-07-27T10:11:13.123Z '
          'deadline=2026-07-27T10:11:32.123Z ageMs=1512',
          allowSensitive: allowSensitive,
        );

        expect(message, contains('attempt_present=true'));
        expect(message, contains('timestamp_present=true'));
        expect(message, contains('age_category=fresh'));
        expect(message, isNot(contains('app-1737')));
        expect(message, isNot(contains('2026-07-27')));
        expect(message, isNot(contains('1512')));
      }
    });

    test('structured release events emit only allowlisted fields', () {
      final message = SecurityDiagnosticsRedactor.structuredEvent(
        'SOS_BACKEND_RESULT',
        fields: const <String, Object?>{
          'transport': 'mqtt',
          'result': 'accepted',
          'incident_present': true,
          'deviceId': 'device-secret',
          'payload': 'raw-secret',
        },
      );

      expect(message, contains('transport=mqtt'));
      expect(message, contains('result=accepted'));
      expect(message, contains('incident_present=true'));
      expect(message, isNot(contains('device-secret')));
      expect(message, isNot(contains('raw-secret')));
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

    test('redacts selected device identifiers in release-like events', () {
      BleDebugRegistry.instance.debugSetSensitiveDiagnosticsEnabled(false);

      BleDebugRegistry.instance.selectDevice('AA:BB:CC:DD:EE:FF');

      final message =
          BleDebugRegistry.instance.currentState.events.single.message;
      expect(message, isNot(contains('AA:BB:CC:DD:EE:FF')));
      expect(message, contains('device_identity_present=true'));
    });

    test('deduplicates identical logs but preserves transitions and failures',
        () {
      BleDebugRegistry.instance.debugSetSensitiveDiagnosticsEnabled(false);

      BleDebugRegistry.instance.recordEvent(
        'SOS_CAPABILITY_EVAL ready=true source=runtime',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_CAPABILITY_EVAL ready=true source=runtime',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_CAPABILITY_EVAL ready=false source=runtime',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_CAPABILITY_EVAL failed error=TimeoutException',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_CAPABILITY_EVAL failed error=TimeoutException',
      );

      final messages = BleDebugRegistry.instance.currentState.events
          .map((event) => event.message)
          .toList();
      expect(messages, hasLength(4));
      expect(messages[0], contains('ready=true'));
      expect(messages[1], contains('ready=false'));
      expect(messages[2], contains('error_category=timeout'));
      expect(messages[3], contains('error_category=timeout'));
    });

    test('dedupes on safe state but never suppresses actuator progress', () {
      BleDebugRegistry.instance.debugSetSensitiveDiagnosticsEnabled(false);

      BleDebugRegistry.instance.recordEvent(
        'BLE_POWERED_CACHE state=ready deviceId=device-one',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_POWERED_CACHE state=ready deviceId=device-two',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_POWERED_CACHE state=notReady deviceId=device-two',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_ACTUATOR_PROGRESS state=sending deviceId=device-one',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_ACTUATOR_PROGRESS state=sending deviceId=device-two',
      );

      final messages = BleDebugRegistry.instance.currentState.events
          .map((event) => event.message)
          .toList();
      expect(messages, hasLength(4));
      expect(
        messages
            .where((message) => message.contains('BLE_POWERED_CACHE'))
            .length,
        2,
      );
      expect(
        messages
            .where((message) => message.contains('SOS_ACTUATOR_PROGRESS'))
            .length,
        2,
      );
      expect(messages.join('\n'), isNot(contains('device-one')));
      expect(messages.join('\n'), isNot(contains('device-two')));
    });
  });

  group('HttpSosRemoteDataSource diagnostics', () {
    test('active SOS query accepts only explicit null absence', () async {
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'test-app',
          externalUserId: 'test-user',
          userHash: 'test-hash',
        );
      final transport = SdkHttpTransport(
        client: MockClient(
          (_) async => http.Response('{"incident":null}', 200),
        ),
        config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
        sessionContext: sessionContext,
      );

      expect(
        await HttpSosRemoteDataSource(transport: transport).getActiveSos(),
        isNull,
      );
    });

    test('active SOS query rejects missing incident field', () async {
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'test-app',
          externalUserId: 'test-user',
          userHash: 'test-hash',
        );
      final transport = SdkHttpTransport(
        client: MockClient((_) async => http.Response('{}', 200)),
        config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
        sessionContext: sessionContext,
      );

      await expectLater(
        HttpSosRemoteDataSource(transport: transport).getActiveSos(),
        throwsA(
          isA<SosException>().having(
            (error) => error.code,
            'code',
            'E_HTTP_SOS_GET_ACTIVE_FAILED',
          ),
        ),
      );
    });

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
      expect(diagnostics, contains('app_identity_present=true'));
      expect(diagnostics, contains('user_identity_present=true'));
      expect(diagnostics, contains('payload_present=true'));
    });

    test('logs redacted external cancel failure response body', () async {
      BleDebugRegistry.instance.debugSetSensitiveDiagnosticsEnabled(false);
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'app-secret',
          externalUserId: 'gateway-secret@example.com',
          userHash: 'hash-secret',
        );
      final transport = SdkHttpTransport(
        client: MockClient((request) async {
          expect(request.url.path, '/v1/sdk/sos/cancel');
          expect(request.body, contains('"deviceId":"device-secret"'));
          return http.Response(
            '{"error":{"code":"validation_error",'
            '"message":"Referenced device does not exist",'
            '"deviceId":"device-secret"}}',
            422,
          );
        }),
        config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
        sessionContext: sessionContext,
      );
      final dataSource = HttpSosRemoteDataSource(transport: transport);

      await expectLater(
        dataSource.cancelSos(
          deviceId: 'device-secret',
          source: 'remote_lora_relay',
          triggerSource: 'remote_lora_relay',
          relaySource: 'remote_lora_relay',
          originatorNodeId: 4242,
        ),
        throwsA(isA<SosHttpException>()),
      );

      final diagnostics = BleDebugRegistry.instance.currentState.events
          .map((event) => event.message)
          .join('\n');
      expect(diagnostics, contains('EXTERNAL_SOS cancel_response'));
      expect(diagnostics, contains('httpStatus=422'));
      expect(diagnostics, contains('topic_category=operational'));
      expect(diagnostics, contains('payload_present=true'));
      expect(diagnostics, contains('error_category=unexpected'));
      expect(diagnostics, isNot(contains('Referenced device does not exist')));
      expect(diagnostics, isNot(contains('device-secret')));
      expect(diagnostics, isNot(contains('gateway-secret@example.com')));
      expect(diagnostics, isNot(contains('hash-secret')));
    });
  });
}
