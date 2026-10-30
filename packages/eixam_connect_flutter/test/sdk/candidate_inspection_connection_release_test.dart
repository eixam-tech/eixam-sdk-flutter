import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_metadata_probe.dart';
import 'package:eixam_connect_flutter/src/sdk/background_location_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/device_migration_coordinator.dart';
import 'package:eixam_connect_flutter/src/sdk/device_migration_firmware_service.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/device/mock_ble_client.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

const _selected = 'AA:BB:CC:DD:EE:FF';
const _control = 'AA:BB:CC:DD:EE:00';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    BleDebugRegistry.instance.reset();
  });

  for (final connected in [true, false]) {
    test(
      'Android releases only the selected App link: connected=$connected',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final fixture = _fixture(selectedConnected: connected);

        final candidate = await fixture.sdk.inspectDeviceMigrationCandidate(
          deviceId: _selected,
        );

        expect(
          candidate.compatibility,
          DeviceMigrationCompatibility.compatible,
        );
        expect(fixture.client.connected, {_control});
        expect(fixture.probe.calls, 1);
        expect(fixture.events, [
          'runtimeReleased',
          'checked:$_selected',
          if (connected) ...[
            'disconnect:$_selected',
            'disconnected:$_selected',
          ],
          'probe:$_selected',
          'runtimeReclaimed',
        ]);
      },
    );
  }

  test(
    'iOS preserves the probe refusal for an already-owned connection',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final fixture = _fixture(selectedConnected: true);

      final candidate = await fixture.sdk.inspectDeviceMigrationCandidate(
        deviceId: _selected,
      );

      expect(
        candidate.compatibility,
        DeviceMigrationCompatibility.unableToVerify,
      );
      expect(candidate.detailCode, 'connectionAlreadyOwned');
      expect(fixture.client.connected, {_selected, _control});
      expect(fixture.events, [
        'runtimeReleased',
        'probe:$_selected',
        'runtimeReclaimed',
      ]);
    },
  );

  test(
    'inspection awaits selected-link release before probing or reclaiming',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final fixture = _fixture(selectedConnected: true);
      fixture.client.disconnectGate = Completer<void>();
      var returned = false;
      final inspection = fixture.sdk
          .inspectDeviceMigrationCandidate(deviceId: _selected)
          .whenComplete(() => returned = true);
      await fixture.client.disconnectStarted.future;

      expect(returned, isFalse);
      expect(fixture.probe.calls, 0);
      expect(fixture.client.connected, {_selected, _control});
      expect(fixture.events, [
        'runtimeReleased',
        'checked:$_selected',
        'disconnect:$_selected',
      ]);

      fixture.client.disconnectGate!.complete();
      expect(
        (await inspection).compatibility,
        DeviceMigrationCompatibility.compatible,
      );
      expect(fixture.client.connected, {_control});
      expect(fixture.events.skip(fixture.events.length - 3), [
        'disconnected:$_selected',
        'probe:$_selected',
        'runtimeReclaimed',
      ]);
    },
  );

  test(
    'failed selected-link release skips probing and restores ownership',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final fixture = _fixture(selectedConnected: true);
      final failure = StateError('native disconnect failed');
      fixture.client.disconnectError = failure;

      await expectLater(
        fixture.sdk.inspectDeviceMigrationCandidate(deviceId: _selected),
        throwsA(same(failure)),
      );
      expect(fixture.probe.calls, 0);
      expect(fixture.client.connected, {_selected, _control});
      expect(fixture.events.last, 'runtimeReclaimed');

      fixture.client.disconnectError = null;
      expect(
        (await fixture.sdk.inspectDeviceMigrationCandidate(
          deviceId: _selected,
        )).compatibility,
        DeviceMigrationCompatibility.compatible,
      );
      expect(fixture.probe.calls, 1);
      expect(fixture.client.connected, {_control});
    },
  );
}

({
  EixamConnectSdkImpl sdk,
  _SelectedLinkClient client,
  _OwnershipCheckingProbe probe,
  List<String> events,
})
_fixture({required bool selectedConnected}) {
  final events = <String>[];
  final client = _SelectedLinkClient(events)
    ..connected.addAll([_control, if (selectedConnected) _selected]);
  final runtime = BleDeviceRuntimeProvider(bleClient: client);
  final repository = _OwnershipTrackingRepository(runtime, events);
  final probe = _OwnershipCheckingProbe(client, events);
  final coordinator = DeviceMigrationCoordinator(
    bleClient: client,
    metadataProbe: probe,
    firmwareUpdates: _UnusedFirmwareService(),
  );
  final store = MemorySharedPrefsSdkStore();
  final sdk = EixamConnectSdkImpl(
    sosRepository: FakeSosRepository(),
    trackingRepository: FakeTrackingRepository(),
    telemetryRepository: FakeTelemetryRepository(),
    contactsRepository: FakeContactsRepository(),
    deviceRepository: repository,
    deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
    deathManRepository: FakeDeathManRepository(),
    permissionsRepository: FakePermissionsRepository(),
    notificationsRepository: FakeNotificationsRepository(),
    realtimeClient: FakeRealtimeClient(),
    deviceSosController: runtime.deviceSosController,
    bleIncomingEvents: runtime.watchIncomingEvents(),
    preferredBleDeviceStore: PreferredBleDeviceStore(localStore: store),
    localStore: store,
    deviceMigrationCoordinator: coordinator,
    protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
    backgroundLocationPlatformAdapter:
        UnsupportedBackgroundLocationPlatformAdapter(),
    backgroundTelemetryPlatformAdapter:
        const NoopBackgroundTelemetryPlatformAdapter(),
    disposeCallback: () async {
      await repository.dispose();
      await runtime.dispose();
      await client.dispose();
    },
  );
  addTearDown(sdk.dispose);
  return (sdk: sdk, client: client, probe: probe, events: events);
}

final class _SelectedLinkClient extends MockBleClient {
  _SelectedLinkClient(this.events);

  final List<String> events;
  final connected = <String>{};
  final disconnectStarted = Completer<void>();
  Completer<void>? disconnectGate;
  Object? disconnectError;

  @override
  Future<bool> isConnected(String deviceId) async {
    events.add('checked:$deviceId');
    return connected.contains(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    events.add('disconnect:$deviceId');
    if (!disconnectStarted.isCompleted) disconnectStarted.complete();
    await disconnectGate?.future;
    if (disconnectError != null) throw disconnectError!;
    connected.remove(deviceId);
    events.add('disconnected:$deviceId');
  }
}

final class _OwnershipCheckingProbe implements MeshtasticMetadataProbe {
  _OwnershipCheckingProbe(this.client, this.events);

  final _SelectedLinkClient client;
  final List<String> events;
  int calls = 0;

  @override
  Future<MeshtasticProbeResult> inspect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    calls++;
    events.add('probe:$deviceId');
    expect(events.first, 'runtimeReleased');
    expect(client.connected, contains(_control));
    if (client.connected.contains(deviceId)) {
      throw const MeshtasticInspectionException(
        DeviceMigrationInspectionFailure.connectionAlreadyOwned,
      );
    }
    return const MeshtasticProbeResult(
      hardwareModel: 105,
      hardwareMac: _selected,
    );
  }
}

final class _OwnershipTrackingRepository extends InMemoryDeviceRepository {
  _OwnershipTrackingRepository(BleDeviceRuntimeProvider runtime, this.events)
    : super(runtimeProvider: runtime);

  final List<String> events;

  @override
  Future<DeviceStatus> releaseBleOwnershipToProtectionMode({
    required String reason,
  }) async {
    final status = await super.releaseBleOwnershipToProtectionMode(
      reason: reason,
    );
    events.add('runtimeReleased');
    return status;
  }

  @override
  Future<DeviceStatus> reclaimBleOwnershipFromProtectionMode({
    required String reason,
  }) async {
    final status = await super.reclaimBleOwnershipFromProtectionMode(
      reason: reason,
    );
    events.add('runtimeReclaimed');
    return status;
  }
}

final class _UnusedFirmwareService implements DeviceMigrationFirmwareService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Inspection must not invoke firmware operations');
}
