import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(
    'dev.eixam.connect_flutter/protection_runtime/methods',
  );

  group('IosProtectionPlatformAdapter', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        switch (call.method) {
          case 'getPlatformSnapshot':
            return <String, dynamic>{
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
              'lastWakeAt':
                  DateTime.utc(2026, 4, 5, 9, 1).millisecondsSinceEpoch,
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
              'protectedDeviceId':
                  '9D6A4E6B-4AF7-4B1F-AF32-0B7FCB66D1F1',
              'activeDeviceId':
                  '9D6A4E6B-4AF7-4B1F-AF32-0B7FCB66D1F1',
              'expectedBleServiceUuid': 'ea00',
              'expectedBleCharacteristicUuids': <String>['ea01', 'ea02'],
              'discoveredBleServicesSummary': 'ea00[ea01,ea02]',
              'readinessFailureReason':
                  'TEL/SOS subscriptions are not active yet.',
              'degradationReason':
                  'The iOS plugin runtime is connected, but TEL/SOS subscriptions are not active yet.',
              'lastCommandRoute': 'iosPlugin',
              'lastCommandResult':
                  'SHUTDOWN native write succeeded via iosPlugin.',
              'lastCommandError': null,
            };
          case 'startProtectionRuntime':
            return <String, dynamic>{
              'success': true,
              'runtimeState': 'recovering',
              'coverageLevel': 'partial',
              'statusMessage':
                  'The iOS plugin runtime is armed, but background BLE recovery is still partial.',
            };
          case 'resumeProtectionRuntime':
            return null;
          case 'sendProtectionCommand':
            return <String, dynamic>{
              'success': true,
              'route': 'iosPlugin',
              'result': 'SHUTDOWN native write succeeded via iosPlugin.',
              'error': null,
            };
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    test('reports restoration-aware iOS snapshot fields', () async {
      final adapter = IosProtectionPlatformAdapter();

      final snapshot = await adapter.getPlatformSnapshot();

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

    test('start sends device id and returns partial coverage instead of false full support',
        () async {
      final methodCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        methodCalls.add(call);
        if (call.method == 'startProtectionRuntime') {
          return <String, dynamic>{
            'success': true,
            'runtimeState': 'recovering',
            'coverageLevel': 'partial',
            'statusMessage':
                'The iOS plugin runtime is armed, but background BLE recovery is still partial.',
          };
        }
        if (call.method == 'resumeProtectionRuntime') {
          return null;
        }
        if (call.method == 'sendProtectionCommand') {
          return <String, dynamic>{
            'success': true,
            'route': 'iosPlugin',
            'result': 'SHUTDOWN native write succeeded via iosPlugin.',
            'error': null,
          };
        }
        return <String, dynamic>{};
      });
      final adapter = IosProtectionPlatformAdapter();

      final result = await adapter.startProtectionRuntime(
        request: const ProtectionPlatformStartRequest(
          modeOptions: ProtectionModeOptions(),
          activeDeviceId: '9D6A4E6B-4AF7-4B1F-AF32-0B7FCB66D1F1',
        ),
      );
      await adapter.ensureProtectionRuntimeActive();
      final commandResult = await adapter.sendProtectionCommand(
        request: const ProtectionPlatformCommandRequest(
          label: 'SHUTDOWN',
          bytes: <int>[0x10],
        ),
      );

      expect(result.success, isTrue);
      expect(result.coverageLevel, ProtectionCoverageLevel.partial);
      expect(result.runtimeState, ProtectionRuntimeState.recovering);
      expect(result.statusMessage, contains('background BLE recovery'));
      expect(commandResult.success, isTrue);
      expect(commandResult.route, 'iosPlugin');
      expect(
        methodCalls.firstWhere((call) => call.method == 'startProtectionRuntime').arguments,
        containsPair('activeDeviceId', '9D6A4E6B-4AF7-4B1F-AF32-0B7FCB66D1F1'),
      );
      expect(
        methodCalls.map((call) => call.method),
        containsAll(<String>[
          'startProtectionRuntime',
          'resumeProtectionRuntime',
          'sendProtectionCommand',
        ]),
      );
    });
  });
}
