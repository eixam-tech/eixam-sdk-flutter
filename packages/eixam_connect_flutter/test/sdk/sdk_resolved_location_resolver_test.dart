import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_resolved_location_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 9, 9, 12);

  SdkResolvedLocationResolver buildResolver({
    TrackingPosition? phonePosition,
    SdkResolvedLocation? latestOwnDeviceLocation,
    DeviceStatus? deviceStatus,
  }) {
    return SdkResolvedLocationResolver(
      trackingRepository: FakeTrackingRepository(
        currentPosition: phonePosition,
      ),
      deviceStatusProvider: () =>
          deviceStatus ??
          buildDeviceStatus(
            deviceId: 'ble-1',
            nodeId: 42,
            canonicalHardwareId: 'hw-1',
            connected: true,
            paired: true,
            activated: true,
          ),
      bridgeDiagnosticsProvider: () => SdkBridgeDiagnostics(
        isActive: true,
        latestOwnDeviceLocation: latestOwnDeviceLocation,
      ),
      clock: () => now,
    );
  }

  test('emergency backend uses a stale last-known device fix', () async {
    final resolver = buildResolver(
      latestOwnDeviceLocation: SdkResolvedLocation.connectedDevice(
        latitude: 41.39,
        longitude: 2.16,
        timestamp: now.subtract(const Duration(hours: 3)),
        deviceId: '42',
        hardwareId: 'hw-1',
        nodeId: 42,
        isFresh: false,
        freshness: const Duration(hours: 3),
      ),
    );

    final location = await resolver.resolve(
      useCase: SdkResolvedLocationUseCase.emergencyBackend,
    );

    expect(location, isNotNull);
    expect(location!.latitude, 41.39);
    expect(location.longitude, 2.16);
    expect(location.isFresh, isFalse);
    expect(location.authoritativeForBackend, isTrue);
  });

  test('telemetry backend still rejects a stale last-known device fix',
      () async {
    final resolver = buildResolver(
      latestOwnDeviceLocation: SdkResolvedLocation.connectedDevice(
        latitude: 41.39,
        longitude: 2.16,
        timestamp: now.subtract(const Duration(hours: 3)),
        deviceId: '42',
        hardwareId: 'hw-1',
        nodeId: 42,
        isFresh: false,
        freshness: const Duration(hours: 3),
      ),
    );

    final location = await resolver.resolve(
      useCase: SdkResolvedLocationUseCase.telemetryBackend,
    );

    expect(location, isNull);
  });

  test('emergency backend never accepts Null Island as last-known', () async {
    final resolver = buildResolver(
      latestOwnDeviceLocation: SdkResolvedLocation.connectedDevice(
        latitude: 0,
        longitude: 0,
        timestamp: now.subtract(const Duration(seconds: 5)),
        deviceId: '42',
        hardwareId: 'hw-1',
        nodeId: 42,
      ),
    );

    final location = await resolver.resolve(
      useCase: SdkResolvedLocationUseCase.emergencyBackend,
    );

    expect(location, isNull);
  });
}
