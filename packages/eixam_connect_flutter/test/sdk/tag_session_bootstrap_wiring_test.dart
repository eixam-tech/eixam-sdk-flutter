import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

/// The bootstrap wired into the SDK: a TAG reconnect re-sends the volume the
/// host set earlier (TAG firmware keeps it in RAM only).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final releaseLog = <String>[];
  setUp(() {
    releaseLog.clear();
    sdkReleaseLogSinkForTesting = releaseLog.add;
  });
  tearDown(() => sdkReleaseLogSinkForTesting = null);

  test('a reconnect re-sends the volume set before the TAG rebooted', () async {
    final harness = _Harness();
    await harness.start();

    await harness.sdk.setDeviceNotificationVolume(10);
    await harness.sdk.setDeviceSosVolume(10);
    harness.commands.clear();

    // TAG reboot: link drops, comes back as a new connection.
    harness.deviceRepository.emitStatus(
      buildDeviceStatus(
        connected: false,
        nodeId: 7,
        canonicalHardwareId: 'HW-1',
        lifecycleState: DeviceLifecycleState.paired,
      ),
    );
    await pumpEventQueue(times: 5);
    harness.deviceRepository.emitStatus(
      buildDeviceStatus(nodeId: 7, canonicalHardwareId: 'HW-1'),
    );
    await _waitUntil(() => harness.commands.length >= 2);

    expect(harness.commands, <String>['0x11:10', '0x12:10']);
    expect(releaseLog, contains('TAG_SESSION_BOOTSTRAP code=volume_restored'));
    expect(harness.statusReads, greaterThanOrEqualTo(1));
    await harness.dispose();
  });

  test('a TAG countdown on reconnect holds the volume until it ends', () async {
    final harness = _Harness();
    await harness.start();
    await harness.sdk.setDeviceSosVolume(20);
    harness.commands.clear();

    harness.deviceRepository.emitStatus(
      buildDeviceStatus(
        connected: false,
        nodeId: 7,
        canonicalHardwareId: 'HW-1',
        lifecycleState: DeviceLifecycleState.paired,
      ),
    );
    await pumpEventQueue(times: 5);
    final countdown = await harness.deviceSosController.triggerSos();
    expect(countdown.state, DeviceSosState.preConfirm);
    harness.commands.clear();
    harness.deviceRepository.emitStatus(
      buildDeviceStatus(nodeId: 7, canonicalHardwareId: 'HW-1'),
    );
    await _waitUntil(
      () => releaseLog.any((l) => l.contains('deferred_for_safety')),
    );
    expect(harness.commands, isEmpty);

    await harness.deviceSosController.cancelSos();
    await _waitUntil(() => harness.commands.isNotEmpty);
    expect(harness.commands, <String>['0x12:20']);
    await harness.dispose();
  });
}

final class _Harness {
  _Harness()
    : deviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(
          nodeId: 7,
          canonicalHardwareId: 'HW-1',
        ),
      ) {
    sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
      deathManRepository: deathManRepository,
      permissionsRepository: FakePermissionsRepository(),
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: realtimeClient,
      deviceSosController: deviceSosController,
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: localStore),
      localStore: localStore,
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
      tagBatteryProbeRequest: () async {
        statusReads++;
        return const DeviceRuntimeStatus(
          region: 3,
          modemPreset: 0,
          meshSpreadingFactor: 9,
          isProvisioned: true,
          usePreset: false,
          txEnabled: true,
          inetOk: false,
          positionConfirmed: false,
          nodeId: 7,
          batteryPercent: 80,
          telIntervalSeconds: 45,
        );
      },
    );
  }

  final FakeSosRepository sosRepository = FakeSosRepository();
  final FakeTrackingRepository trackingRepository = FakeTrackingRepository();
  final FakeContactsRepository contactsRepository = FakeContactsRepository();
  final FakeDeviceRepository deviceRepository;
  final FakeDeathManRepository deathManRepository = FakeDeathManRepository();
  final FakeRealtimeClient realtimeClient = FakeRealtimeClient();
  final DeviceSosController deviceSosController = DeviceSosController();
  final MemorySharedPrefsSdkStore localStore = MemorySharedPrefsSdkStore();
  final List<String> commands = <String>[];
  int statusReads = 0;
  late final EixamConnectSdkImpl sdk;

  Future<void> start() async {
    await deviceSosController.attach(
      commandWriter: (EixamDeviceCommand command) async {
        final bytes = command.bytes;
        if (bytes.isNotEmpty && (bytes[0] == 0x11 || bytes[0] == 0x12)) {
          commands.add('0x${bytes[0].toRadixString(16)}:${bytes[1]}');
        }
      },
    );
    await sdk.initialize(
      const EixamSdkConfig(
        apiBaseUrl: 'https://api.example.test',
        deferRuntimeStartup: true,
      ),
    );
    await pumpEventQueue(times: 10);
  }

  Future<void> dispose() async {
    await sdk.dispose();
    await sosRepository.dispose();
    await trackingRepository.dispose();
    await contactsRepository.dispose();
    await deviceRepository.dispose();
    await deathManRepository.dispose();
    await realtimeClient.dispose();
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
