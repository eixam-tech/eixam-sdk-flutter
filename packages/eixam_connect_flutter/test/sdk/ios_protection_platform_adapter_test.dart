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
              'backgroundCapabilityReady': false,
              'backgroundCapabilityState': 'unknown',
              'restorationConfigured': true,
              'platformRuntimeConfigured': true,
              'runtimeActive': false,
              'bluetoothEnabled': true,
              'notificationsGranted': true,
              'lastRestorationEvent': 'restorationDetected',
              'lastRestorationEventAt':
                  DateTime.utc(2026, 4, 5, 9).millisecondsSinceEpoch,
              'runtimeState': 'inactive',
              'coverageLevel': 'partial',
              'degradationReason':
                  'iOS host integration is scaffolded, but background BLE ownership is not implemented yet.',
            };
          case 'startProtectionRuntime':
            return <String, dynamic>{
              'success': true,
              'runtimeState': 'inactive',
              'coverageLevel': 'partial',
              'statusMessage':
                  'iOS Protection Mode base adapter is present, but real background BLE/runtime ownership is not implemented yet.',
            };
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    test('reports safe degraded iOS snapshot fields', () async {
      final adapter = IosProtectionPlatformAdapter();

      final snapshot = await adapter.getPlatformSnapshot();

      expect(snapshot.platform, ProtectionPlatform.ios);
      expect(snapshot.coverageLevel, ProtectionCoverageLevel.partial);
      expect(snapshot.backgroundCapabilityState,
          ProtectionCapabilityState.unknown);
      expect(snapshot.restorationConfigured, isTrue);
      expect(snapshot.lastRestorationEvent, 'restorationDetected');
      expect(snapshot.bleOwner, ProtectionBleOwner.flutter);
      expect(snapshot.degradationReason, contains('background BLE ownership'));
    });

    test('start returns partial coverage instead of false full support',
        () async {
      final adapter = IosProtectionPlatformAdapter();

      final result = await adapter.startProtectionRuntime(
        request: const ProtectionPlatformStartRequest(
          modeOptions: ProtectionModeOptions(),
        ),
      );

      expect(result.success, isTrue);
      expect(result.coverageLevel, ProtectionCoverageLevel.partial);
      expect(result.statusMessage, contains('not implemented yet'));
    });
  });
}
