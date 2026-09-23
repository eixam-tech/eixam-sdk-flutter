import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_mode_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';

void main() {
  test(
    'releases Flutter ownership before native runtime GATT starts',
    () async {
      var flutterReleased = false;
      final ownerTransitions = <ProtectionBleOwner>[];
      final adapter = _OrderingProtectionPlatformAdapter(
        flutterReleased: () => flutterReleased,
      );
      final controller = ProtectionModeController(
        platformAdapter: adapter,
        sessionProvider: () async => const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
        sdkConfigProvider: () =>
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        deviceStatusProvider: () async => buildDeviceStatus(
          deviceId: 'CF:82:00:00:00:01',
          canonicalHardwareId: 'CF:82:00:00:00:01',
          connected: !flutterReleased,
          paired: true,
          activated: true,
        ),
        permissionStateProvider: () async => const PermissionState(
          location: SdkPermissionStatus.granted,
          notifications: SdkPermissionStatus.granted,
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        ),
        operationalDiagnosticsProvider: () async =>
            const SdkOperationalDiagnostics(
              connectionState: RealtimeConnectionState.connected,
              bridge: SdkBridgeDiagnostics(),
            ),
        onBleOwnershipChanged: (owner) async {
          ownerTransitions.add(owner);
          if (owner == ProtectionBleOwner.androidService) {
            flutterReleased = true;
          }
        },
      );
      addTearDown(controller.dispose);
      addTearDown(adapter.dispose);

      final result = await controller.enter();

      expect(result.success, isTrue);
      expect(adapter.startObservedFlutterReleased, isTrue);
      expect(ownerTransitions, <ProtectionBleOwner>[
        ProtectionBleOwner.androidService,
      ]);
    },
  );

  test(
    'native readiness atomically establishes ownership and rejects an older session',
    () async {
      final adapter = _OrderingProtectionPlatformAdapter(
        flutterReleased: () => true,
      );
      final controller = _testController(adapter);
      addTearDown(controller.dispose);
      addTearDown(adapter.dispose);

      adapter.emit(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.nativeCommandReadinessChanged,
          timestamp: DateTime.utc(2026, 9, 21, 22, 40, 8),
          reason: 'eixam_service_and_ea04_discovered',
          nativeOwner: true,
          gattConnected: true,
          serviceReady: true,
          cmdEa04Ready: true,
          identityReady: true,
          queueHealthy: true,
          nativeCommandReady: true,
          sessionGeneration: 8,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentStatus.modeState, ProtectionModeState.armed);
      expect(
        controller.currentStatus.bleOwner,
        ProtectionBleOwner.androidService,
      );
      expect(controller.currentStatus.nativeCommandReady, isTrue);

      adapter.emit(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.ownDeviceSosLifecycleSuppressed,
          timestamp: DateTime.utc(2026, 9, 21, 22, 40, 9),
          reason: 'recent_terminal_action',
        ),
      );
      adapter.emit(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.serviceRestarted,
          timestamp: DateTime.utc(2026, 9, 21, 22, 40, 10),
          reason: 'service_restart_marker',
        ),
      );
      adapter.emit(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.nativeCommandReadinessChanged,
          timestamp: DateTime.utc(2026, 9, 21, 22, 40, 7),
          reason: 'stale_previous_session',
          nativeOwner: false,
          gattConnected: false,
          serviceReady: false,
          cmdEa04Ready: false,
          identityReady: false,
          queueHealthy: false,
          nativeCommandReady: false,
          sessionGeneration: 7,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.currentStatus.modeState, ProtectionModeState.armed);
      expect(
        controller.currentStatus.bleOwner,
        ProtectionBleOwner.androidService,
      );
      expect(controller.currentStatus.nativeCommandReady, isTrue);
      expect(
        (await controller.getDiagnostics()).lastBleServiceEvent,
        'staleNativeCommandReadinessIgnored',
      );
    },
  );

  test(
    'exit stops native runtime and rejects a late connected event',
    () async {
      final adapter = _OrderingProtectionPlatformAdapter(
        flutterReleased: () => true,
      );
      final controller = _testController(adapter);
      addTearDown(controller.dispose);
      addTearDown(adapter.dispose);
      expect((await controller.enter()).success, isTrue);

      final stopped = await controller.exit();
      adapter.emit(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.deviceConnected,
          timestamp: DateTime.utc(2026, 9, 23),
          reason: 'late_old_native_session',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(adapter.stopCalls, 1);
      expect(stopped.modeState, ProtectionModeState.off);
      expect(controller.currentStatus.deviceConnected, isFalse);
      expect(controller.currentStatus.bleOwner, ProtectionBleOwner.flutter);
      expect(
        (await controller.getDiagnostics()).lastBleServiceEvent,
        'suppressedNativeConnectivityIgnored',
      );
    },
  );

  test('exit propagates a native runtime stop failure', () async {
    final adapter = _OrderingProtectionPlatformAdapter(
      flutterReleased: () => true,
    )..stopError = StateError('native stop failed');
    final controller = _testController(adapter);
    addTearDown(controller.dispose);
    addTearDown(adapter.dispose);
    expect((await controller.enter()).success, isTrue);

    await expectLater(controller.exit(), throwsA(isA<StateError>()));

    expect(adapter.stopCalls, 1);
    expect(controller.currentStatus.modeState, ProtectionModeState.stopping);
  });
}

ProtectionModeController _testController(ProtectionPlatformAdapter adapter) {
  return ProtectionModeController(
    platformAdapter: adapter,
    sessionProvider: () async => const EixamSession.signed(
      appId: 'app-demo',
      externalUserId: 'external-123',
      userHash: 'deadbeef',
    ),
    sdkConfigProvider: () =>
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
    deviceStatusProvider: () async => buildDeviceStatus(
      deviceId: 'CF:82:00:00:00:01',
      canonicalHardwareId: 'CF:82:00:00:00:01',
      connected: false,
      paired: true,
      activated: true,
    ),
    permissionStateProvider: () async => const PermissionState(
      location: SdkPermissionStatus.granted,
      notifications: SdkPermissionStatus.granted,
      bluetooth: SdkPermissionStatus.granted,
      bluetoothEnabled: true,
    ),
    operationalDiagnosticsProvider: () async => const SdkOperationalDiagnostics(
      connectionState: RealtimeConnectionState.connected,
      bridge: SdkBridgeDiagnostics(),
    ),
  );
}

final class _OrderingProtectionPlatformAdapter extends Fake
    implements ProtectionPlatformAdapter {
  _OrderingProtectionPlatformAdapter({required this.flutterReleased});

  final bool Function() flutterReleased;
  final StreamController<ProtectionPlatformEvent> _events =
      StreamController<ProtectionPlatformEvent>.broadcast();
  bool started = false;
  bool startObservedFlutterReleased = false;
  int stopCalls = 0;
  Object? stopError;

  void emit(ProtectionPlatformEvent event) => _events.add(event);

  @override
  ProtectionPlatform get platform => ProtectionPlatform.android;

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async {
    if (!started) {
      return const ProtectionPlatformSnapshot(
        backgroundCapabilityReady: true,
        platformRuntimeConfigured: true,
        foregroundServiceConfigured: true,
        platform: ProtectionPlatform.android,
        bleOwner: ProtectionBleOwner.flutter,
      );
    }
    return const ProtectionPlatformSnapshot(
      backgroundCapabilityReady: true,
      platformRuntimeConfigured: true,
      foregroundServiceConfigured: true,
      serviceRunning: true,
      runtimeActive: true,
      runtimeState: ProtectionRuntimeState.active,
      coverageLevel: ProtectionCoverageLevel.partial,
      platform: ProtectionPlatform.android,
      bleOwner: ProtectionBleOwner.androidService,
      protectedDeviceId: 'CF:82:00:00:00:01',
      activeDeviceId: 'CF:82:00:00:00:01',
    );
  }

  @override
  Future<ProtectionPlatformStartResult> startProtectionRuntime({
    required ProtectionPlatformStartRequest request,
  }) async {
    startObservedFlutterReleased = flutterReleased();
    started = true;
    return const ProtectionPlatformStartResult(
      success: true,
      runtimeState: ProtectionRuntimeState.active,
      coverageLevel: ProtectionCoverageLevel.partial,
    );
  }

  @override
  Future<void> stopProtectionRuntime() async {
    stopCalls += 1;
    final error = stopError;
    if (error != null) throw error;
    started = false;
  }

  @override
  Stream<ProtectionPlatformEvent> watchPlatformEvents() => _events.stream;

  Future<void> dispose() => _events.close();
}
