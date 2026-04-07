import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_channel_mapper.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Direct MethodChannel adapter tests did not terminate reliably in the
  // current headless Windows runner, so this suite validates the concrete
  // adapter mapping contract through the shared pure mapper layer instead.
  group('IosProtectionPlatformAdapter mapping', () {
    test('maps restoration-aware iOS snapshot fields deterministically', () {
      final snapshot = mapIosProtectionPlatformSnapshot(<String, dynamic>{
        'backgroundCapabilityReady': true,
        'backgroundCapabilityState': 'configured',
        'restorationConfigured': true,
        'platformRuntimeConfigured': true,
        'runtimeActive': true,
        'bluetoothEnabled': true,
        'notificationsGranted': true,
        'lastRestorationEvent': 'restorationDetected',
        'lastRestorationEventAt':
            DateTime.utc(2026, 4, 5, 9).millisecondsSinceEpoch,
        'lastWakeReason': 'corebluetooth_restoration',
        'lastWakeAt': DateTime.utc(2026, 4, 5, 9, 1).millisecondsSinceEpoch,
        'lastBleServiceEvent': 'subscriptionsActive',
        'lastBleServiceEventAt':
            DateTime.utc(2026, 4, 5, 9, 2).millisecondsSinceEpoch,
        'reconnectAttemptCount': 2,
        'lastReconnectAttemptAt':
            DateTime.utc(2026, 4, 5, 9, 3).millisecondsSinceEpoch,
        'runtimeState': 'recovering',
        'coverageLevel': 'partial',
        'bleOwner': 'iosPlugin',
        'serviceBleConnected': true,
        'serviceBleReady': false,
        'protectedDeviceId': '9D6A4E6B-4AF7-4B1F-AF32-0B7FCB66D1F1',
        'activeDeviceId': '9D6A4E6B-4AF7-4B1F-AF32-0B7FCB66D1F1',
        'expectedBleServiceUuid': 'ea00',
        'expectedBleCharacteristicUuids': <String>['ea01', 'ea02'],
        'discoveredBleServicesSummary': 'ea00[ea01,ea02]',
        'readinessFailureReason': 'TEL/SOS subscriptions are not active yet.',
        'degradationReason':
            'The iOS plugin runtime is connected, but TEL/SOS subscriptions are not active yet.',
        'lastCommandRoute': 'iosPlugin',
        'lastCommandResult': 'SHUTDOWN native write succeeded via iosPlugin.',
        'lastCommandError': null,
      });

      expect(snapshot.platform, ProtectionPlatform.ios);
      expect(snapshot.coverageLevel, ProtectionCoverageLevel.partial);
      expect(snapshot.backgroundCapabilityState,
          ProtectionCapabilityState.configured);
      expect(snapshot.restorationConfigured, isTrue);
      expect(snapshot.lastRestorationEvent, 'restorationDetected');
      expect(snapshot.bleOwner, ProtectionBleOwner.iosPlugin);
      expect(snapshot.runtimeState, ProtectionRuntimeState.recovering);
      expect(snapshot.serviceBleConnected, isTrue);
      expect(snapshot.serviceBleReady, isFalse);
      expect(snapshot.protectedDeviceId, isNotEmpty);
      expect(snapshot.activeDeviceId, isNotEmpty);
      expect(snapshot.reconnectAttemptCount, 2);
      expect(snapshot.lastCommandRoute, 'iosPlugin');
      expect(snapshot.lastCommandResult, contains('SHUTDOWN'));
      expect(snapshot.degradationReason, contains('TEL/SOS subscriptions'));
    });

    test('maps start and command results deterministically', () {
      final startResult = mapProtectionPlatformStartResult(
        <String, dynamic>{
          'success': true,
          'runtimeState': 'recovering',
          'coverageLevel': 'partial',
          'statusMessage':
              'The iOS plugin runtime is armed, but background BLE recovery is still partial.',
        },
      );
      final commandResult = mapProtectionPlatformCommandResult(
        <String, dynamic>{
          'success': true,
          'route': 'iosPlugin',
          'result': 'SHUTDOWN native write succeeded via iosPlugin.',
          'error': null,
        },
      );

      expect(startResult.success, isTrue);
      expect(startResult.coverageLevel, ProtectionCoverageLevel.partial);
      expect(startResult.runtimeState, ProtectionRuntimeState.recovering);
      expect(startResult.statusMessage, contains('background BLE recovery'));
      expect(commandResult.success, isTrue);
      expect(commandResult.route, 'iosPlugin');
    });

    test('maps iOS platform events deterministically', () {
      final event = mapIosProtectionPlatformEvent(<Object?, Object?>{
        'type': 'restorationDetected',
        'timestamp': DateTime.utc(2026, 4, 5, 11).millisecondsSinceEpoch,
        'reason': 'corebluetooth_restoration',
      });

      expect(event.type, ProtectionPlatformEventType.restorationDetected);
      expect(event.reason, 'corebluetooth_restoration');
    });
  });
}
