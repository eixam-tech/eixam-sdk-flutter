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
}

final class _OrderingProtectionPlatformAdapter extends Fake
    implements ProtectionPlatformAdapter {
  _OrderingProtectionPlatformAdapter({required this.flutterReleased});

  final bool Function() flutterReleased;
  final StreamController<ProtectionPlatformEvent> _events =
      StreamController<ProtectionPlatformEvent>.broadcast();
  bool started = false;
  bool startObservedFlutterReleased = false;

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
  Stream<ProtectionPlatformEvent> watchPlatformEvents() => _events.stream;

  Future<void> dispose() => _events.close();
}
