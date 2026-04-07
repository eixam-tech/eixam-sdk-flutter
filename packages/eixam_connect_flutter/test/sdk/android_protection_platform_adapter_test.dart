import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_channel_mapper.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AndroidProtectionPlatformAdapter mapping', () {
    test('maps native snapshot into SDK platform snapshot fields', () {
      final snapshot = mapAndroidProtectionPlatformSnapshot(
        <String, dynamic>{
          'backgroundCapabilityReady': true,
          'platformRuntimeConfigured': true,
          'foregroundServiceConfigured': true,
          'serviceRunning': true,
          'runtimeActive': true,
          'bluetoothEnabled': true,
          'notificationsGranted': true,
          'lastFailureReason': null,
          'lastPlatformEvent': 'runtimeStarted',
          'lastPlatformEventAt':
              DateTime.utc(2026, 4, 5, 10).millisecondsSinceEpoch,
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
          'lastRestorationEventAt':
              DateTime.utc(2026, 4, 5, 10, 4).millisecondsSinceEpoch,
          'lastBleServiceEvent': 'deviceConnected',
          'lastBleServiceEventAt':
              DateTime.utc(2026, 4, 5, 10, 5).millisecondsSinceEpoch,
          'reconnectAttemptCount': 2,
          'lastReconnectAttemptAt':
              DateTime.utc(2026, 4, 5, 10, 6).millisecondsSinceEpoch,
          'lastNativeBackendHandoffResult': 'create_synced',
          'lastNativeBackendHandoffError': null,
          'protectedDeviceId': 'device-123',
          'lastCommandRoute': 'androidService',
          'lastCommandResult':
              'SHUTDOWN native write succeeded via androidService.',
          'lastCommandError': null,
          'lastWakeAt': DateTime.utc(2026, 4, 5, 9).millisecondsSinceEpoch,
          'lastWakeReason': 'enter_protection_mode',
        },
      );

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
      final commandResult = mapProtectionPlatformCommandResult(
        <String, dynamic>{
          'success': true,
          'route': 'androidService',
          'result': 'SHUTDOWN native write succeeded via androidService.',
          'error': null,
        },
      );

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
  });
}
