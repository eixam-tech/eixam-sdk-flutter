import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_channel_mapper.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidProtectionPlatformAdapter mapping', () {
    test('maps native snapshot into SDK platform snapshot fields', () {
      final snapshot = mapAndroidProtectionPlatformSnapshot(<String, dynamic>{
        'backgroundCapabilityReady': true,
        'platformRuntimeConfigured': true,
        'foregroundServiceConfigured': true,
        'serviceRunning': true,
        'runtimeActive': true,
        'bluetoothEnabled': true,
        'notificationsGranted': true,
        'lastFailureReason': null,
        'lastPlatformEvent': 'runtimeStarted',
        'lastPlatformEventAt': DateTime.utc(
          2026,
          4,
          5,
          10,
        ).millisecondsSinceEpoch,
        'runtimeState': 'active',
        'coverageLevel': 'partial',
        'bleOwner': 'androidService',
        'backgroundCapabilityState': 'configured',
        'restorationConfigured': true,
        'serviceBleConnected': true,
        'serviceBleReady': false,
        'expectedBleServiceUuid': '6ba1b218-15a8-461f-9fa8-5dcae273ea00',
        'expectedBleCharacteristicUuids': <String>[
          '6ba1b218-15a8-461f-9fa8-5dcae273ea01',
          '6ba1b218-15a8-461f-9fa8-5dcae273ea02',
          '6ba1b218-15a8-461f-9fa8-5dcae273ea03',
          '6ba1b218-15a8-461f-9fa8-5dcae273ea04',
        ],
        'discoveredBleServicesSummary':
            '180f[] | 6ba1b218-15a8-461f-9fa8-5dcae273ea00[6ba1b218-15a8-461f-9fa8-5dcae273ea01,6ba1b218-15a8-461f-9fa8-5dcae273ea02,6ba1b218-15a8-461f-9fa8-5dcae273ea03]',
        'readinessFailureReason':
            'Required EIXAM protection characteristics are missing.',
        'nativeBackendBaseUrl': 'https://api.example.test',
        'nativeBackendConfigValid': true,
        'nativeBackendConfigIssue': null,
        'debugLocalhostBackendAllowed': false,
        'debugCleartextBackendAllowed': false,
        'pendingNativeSosCreateCount': 1,
        'pendingNativeSosCancelCount': 0,
        'lastRestorationEvent': 'restorationDetected',
        'lastRestorationEventAt': DateTime.utc(
          2026,
          4,
          5,
          10,
          4,
        ).millisecondsSinceEpoch,
        'lastBleServiceEvent': 'deviceConnected',
        'lastBleServiceEventAt': DateTime.utc(
          2026,
          4,
          5,
          10,
          5,
        ).millisecondsSinceEpoch,
        'reconnectAttemptCount': 2,
        'lastReconnectAttemptAt': DateTime.utc(
          2026,
          4,
          5,
          10,
          6,
        ).millisecondsSinceEpoch,
        'lastNativeBackendHandoffResult': 'create_synced',
        'lastNativeBackendHandoffError': null,
        'protectedDeviceId': 'device-123',
        'lastCommandRoute': 'androidService',
        'lastCommandResult':
            'SHUTDOWN native write succeeded via androidService.',
        'lastCommandError': null,
        'lastWakeAt': DateTime.utc(2026, 4, 5, 9).millisecondsSinceEpoch,
        'lastWakeReason': 'enter_protection_mode',
      });

      expect(snapshot.backgroundCapabilityReady, isTrue);
      expect(snapshot.platformRuntimeConfigured, isTrue);
      expect(snapshot.foregroundServiceConfigured, isTrue);
      expect(snapshot.serviceRunning, isTrue);
      expect(snapshot.runtimeActive, isTrue);
      expect(snapshot.bluetoothEnabled, isTrue);
      expect(snapshot.notificationsGranted, isTrue);
      expect(snapshot.lastPlatformEvent, 'runtimeStarted');
      expect(snapshot.bleOwner, ProtectionBleOwner.androidService);
      expect(snapshot.restorationConfigured, isTrue);
      expect(snapshot.serviceBleConnected, isTrue);
      expect(snapshot.serviceBleReady, isFalse);
      expect(
        snapshot.expectedBleServiceUuid,
        '6ba1b218-15a8-461f-9fa8-5dcae273ea00',
      );
      expect(snapshot.expectedBleCharacteristicUuids, hasLength(4));
      expect(
        snapshot.discoveredBleServicesSummary,
        contains('6ba1b218-15a8-461f-9fa8-5dcae273ea00'),
      );
      expect(
        snapshot.readinessFailureReason,
        contains('Required EIXAM protection characteristics'),
      );
      expect(snapshot.nativeBackendBaseUrl, 'https://api.example.test');
      expect(snapshot.nativeBackendConfigValid, isTrue);
      expect(snapshot.debugLocalhostBackendAllowed, isFalse);
      expect(snapshot.debugCleartextBackendAllowed, isFalse);
      expect(snapshot.pendingNativeSosCreateCount, 1);
      expect(snapshot.pendingNativeSosCancelCount, 0);
      expect(snapshot.lastRestorationEvent, 'restorationDetected');
      expect(snapshot.reconnectAttemptCount, 2);
      expect(snapshot.lastNativeBackendHandoffResult, 'create_synced');
      expect(snapshot.protectedDeviceId, 'device-123');
      expect(snapshot.lastCommandRoute, 'androidService');
      expect(snapshot.lastCommandResult, contains('SHUTDOWN'));
      expect(snapshot.runtimeState, ProtectionRuntimeState.active);
      expect(snapshot.coverageLevel, ProtectionCoverageLevel.partial);
    });

    test('maps start, flush, and command bridge results', () {
      final startResult = mapProtectionPlatformStartResult(<String, dynamic>{
        'success': true,
        'runtimeState': 'active',
        'coverageLevel': 'partial',
        'statusMessage': 'Foreground service started.',
      });
      final flushResult = mapProtectionPlatformFlushResult(<String, dynamic>{
        'flushedSosCount': 1,
        'flushedTelemetryCount': 0,
        'success': true,
      });
      final commandResult =
          mapProtectionPlatformCommandResult(<String, dynamic>{
            'success': true,
            'route': 'androidService',
            'result': 'SHUTDOWN native write succeeded via androidService.',
            'error': null,
          });

      expect(startResult.success, isTrue);
      expect(startResult.coverageLevel, ProtectionCoverageLevel.partial);
      expect(startResult.statusMessage, 'Foreground service started.');
      expect(flushResult.flushedSosCount, 1);
      expect(commandResult.success, isTrue);
      expect(commandResult.route, 'androidService');
    });

    test('maps runtime events into platform events', () {
      final event = mapAndroidProtectionPlatformEvent(<Object?, Object?>{
        'type': 'runtimeRestarted',
        'timestamp': DateTime.utc(2026, 4, 5, 11).millisecondsSinceEpoch,
        'reason': 'system_restart',
      });

      expect(event.type, ProtectionPlatformEventType.runtimeRestarted);
      expect(event.reason, 'system_restart');
    });

    test('maps event-driven native command readiness predicates', () {
      final event = mapAndroidProtectionPlatformEvent(<Object?, Object?>{
        'type': 'nativeCommandReadinessChanged',
        'timestamp': DateTime.utc(2026, 9, 21).millisecondsSinceEpoch,
        'reason': 'eixam_service_and_ea04_discovered',
        'previous': false,
        'gattConnected': true,
        'serviceReady': true,
        'cmdEa04Ready': true,
        'identityReady': true,
        'queueHealthy': true,
        'nativeCommandReady': true,
      });

      expect(
        event.type,
        ProtectionPlatformEventType.nativeCommandReadinessChanged,
      );
      expect(event.previousNativeCommandReady, isFalse);
      expect(event.gattConnected, isTrue);
      expect(event.serviceReady, isTrue);
      expect(event.cmdEa04Ready, isTrue);
      expect(event.identityReady, isTrue);
      expect(event.queueHealthy, isTrue);
      expect(event.nativeCommandReady, isTrue);
    });

    test('maps raw native notification correlation before SOS parsing', () {
      final event = mapAndroidProtectionPlatformEvent(<Object?, Object?>{
        'type': 'bleNotificationReceived',
        'timestamp': DateTime.utc(2026, 9, 21).millisecondsSinceEpoch,
        'payloadHex': 'a81a4b5948cd1b34442800c0',
        'source': 'tel_notify',
        'characteristicUuid': '6ba1b218-15a8-461f-9fa8-5dcae273ea01',
        'byteLength': 12,
        'packetType': 'sos',
        'firstOpcode': '0xa8',
        'receiveSequence': 1,
        'receiveCorrelation': 'native-1',
        'connectedDeviceMarker': '**:**:**:**:1A:A8',
      });

      expect(event.type, ProtectionPlatformEventType.bleNotificationReceived);
      expect(event.packetType, 'sos');
      expect(event.firstOpcode, '0xa8');
      expect(event.receiveSequence, 1);
      expect(event.receiveCorrelation, 'native-1');
      expect(event.byteLength, 12);
    });

    test('maps structured native SOS lifecycle payload fields', () {
      final event = mapAndroidProtectionPlatformEvent(<Object?, Object?>{
        'type': 'ownDeviceSosLifecycleObserved',
        'timestamp': DateTime.utc(2026, 4, 29, 10).millisecondsSinceEpoch,
        'payloadHex': '341200000000000000000050',
        'source': 'sos',
        'classification': 'ownDeviceSos',
      });

      expect(
        event.type,
        ProtectionPlatformEventType.ownDeviceSosLifecycleObserved,
      );
      expect(event.payloadHex, '341200000000000000000050');
      expect(event.source, 'sos');
      expect(event.classification, 'ownDeviceSos');
    });
  });
}
