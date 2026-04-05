import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel(
    'dev.eixam.connect_flutter/protection_runtime/methods',
  );

  group('AndroidProtectionPlatformAdapter', () {
    late List<MethodCall> methodCalls;

    setUp(() {
      methodCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (call) async {
        methodCalls.add(call);
        switch (call.method) {
          case 'getPlatformSnapshot':
            return <String, dynamic>{
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
              'serviceBleConnected': true,
              'serviceBleReady': false,
              'lastBleServiceEvent': 'deviceConnected',
              'lastBleServiceEventAt':
                  DateTime.utc(2026, 4, 5, 10, 5).millisecondsSinceEpoch,
              'reconnectAttemptCount': 2,
              'lastReconnectAttemptAt':
                  DateTime.utc(2026, 4, 5, 10, 6).millisecondsSinceEpoch,
              'lastWakeAt': DateTime.utc(2026, 4, 5, 9).millisecondsSinceEpoch,
              'lastWakeReason': 'enter_protection_mode',
            };
          case 'startProtectionRuntime':
            return <String, dynamic>{
              'success': true,
              'runtimeState': 'active',
              'coverageLevel': 'partial',
              'statusMessage': 'Foreground service started.',
            };
          case 'flushProtectionQueues':
            return <String, dynamic>{
              'flushedSosCount': 1,
              'flushedTelemetryCount': 0,
              'success': true,
            };
          case 'stopProtectionRuntime':
            return null;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
    });

    test('maps native snapshot into SDK platform snapshot fields', () async {
      final adapter = AndroidProtectionPlatformAdapter();

      final snapshot = await adapter.getPlatformSnapshot();

      expect(snapshot.backgroundCapabilityReady, isTrue);
      expect(snapshot.platformRuntimeConfigured, isTrue);
      expect(snapshot.foregroundServiceConfigured, isTrue);
      expect(snapshot.serviceRunning, isTrue);
      expect(snapshot.runtimeActive, isTrue);
      expect(snapshot.bluetoothEnabled, isTrue);
      expect(snapshot.notificationsGranted, isTrue);
      expect(snapshot.lastPlatformEvent, 'runtimeStarted');
      expect(snapshot.bleOwner, ProtectionBleOwner.androidService);
      expect(snapshot.serviceBleConnected, isTrue);
      expect(snapshot.serviceBleReady, isFalse);
      expect(snapshot.reconnectAttemptCount, 2);
      expect(snapshot.runtimeState, ProtectionRuntimeState.active);
      expect(snapshot.coverageLevel, ProtectionCoverageLevel.partial);
      expect(methodCalls.single.method, 'getPlatformSnapshot');
    });

    test('maps start and stop runtime bridge calls', () async {
      final adapter = AndroidProtectionPlatformAdapter();

      final result = await adapter.startProtectionRuntime(
        request: const ProtectionPlatformStartRequest(
          modeOptions: ProtectionModeOptions(),
          activeDeviceId: 'device-123',
        ),
      );
      final flushResult = await adapter.flushProtectionQueues();
      await adapter.stopProtectionRuntime();

      expect(result.success, isTrue);
      expect(result.coverageLevel, ProtectionCoverageLevel.partial);
      expect(result.statusMessage, 'Foreground service started.');
      expect(flushResult.flushedSosCount, 1);
      expect(
        methodCalls.map((call) => call.method),
        containsAll(<String>[
          'startProtectionRuntime',
          'flushProtectionQueues',
          'stopProtectionRuntime',
        ]),
      );
    });

    test('maps runtime events into platform events', () async {
      final controller = StreamController<dynamic>.broadcast();
      final adapter = AndroidProtectionPlatformAdapter(
        eventStreamFactory: () => controller.stream,
      );

      final eventFuture = adapter.watchPlatformEvents().first;
      controller.add(<String, dynamic>{
        'type': 'runtimeRestarted',
        'timestamp': DateTime.utc(2026, 4, 5, 11).millisecondsSinceEpoch,
        'reason': 'system_restart',
      });

      final event = await eventFuture;

      expect(event.type, ProtectionPlatformEventType.runtimeRestarted);
      expect(event.reason, 'system_restart');
      await controller.close();
    });
  });
}
