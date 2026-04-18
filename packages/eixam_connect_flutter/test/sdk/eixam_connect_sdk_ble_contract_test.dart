import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_relay_rx_packet.dart';
import 'package:eixam_connect_flutter/src/device/mock_ble_client.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EixamConnectSdk BLE public contract', () {
    late MockBleClient bleClient;
    late BleDeviceRuntimeProvider runtimeProvider;
    late InMemoryDeviceRepository deviceRepository;
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
    late FakeTelemetryRepository telemetryRepository;
    late FakeContactsRepository contactsRepository;
    late FakeSdkDeviceRegistryRepository deviceRegistryRepository;
    late FakeDeathManRepository deathManRepository;
    late FakePermissionsRepository permissionsRepository;
    late FakeNotificationsRepository notificationsRepository;
    late FakeRealtimeClient realtimeClient;
    late PreferredBleDeviceStore preferredDeviceStore;
    late EixamConnectSdkImpl sdk;

    setUp(() async {
      BleDebugRegistry.instance.reset();
      bleClient = MockBleClient();
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
      deviceRepository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
        localStore: MemorySharedPrefsSdkStore(),
      );
      await deviceRepository.restoreState();
      sosRepository = FakeSosRepository();
      trackingRepository = FakeTrackingRepository();
      telemetryRepository = FakeTelemetryRepository();
      contactsRepository = FakeContactsRepository();
      deviceRegistryRepository = FakeSdkDeviceRegistryRepository();
      deathManRepository = FakeDeathManRepository();
      permissionsRepository = FakePermissionsRepository();
      notificationsRepository = FakeNotificationsRepository();
      realtimeClient = FakeRealtimeClient();
      preferredDeviceStore = PreferredBleDeviceStore(
        localStore: MemorySharedPrefsSdkStore(),
      );
      sdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: realtimeClient,
        deviceSosController: runtimeProvider.deviceSosController,
        bleIncomingEvents: runtimeProvider.watchIncomingEvents(),
        preferredBleDeviceStore: preferredDeviceStore,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
    });

    tearDown(() async {
      await sdk.dispose();
      await deviceRepository.dispose();
      await runtimeProvider.dispose();
      await bleClient.dispose();
      await sosRepository.dispose();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deathManRepository.dispose();
      await realtimeClient.dispose();
    });

    test('public SDK sets notification and SOS volumes via BLE runtime',
        () async {
      await _connectDemoDevice(sdk);

      await sdk.setDeviceNotificationVolume(35);
      await sdk.setDeviceSosVolume(90);

      expect(bleClient.writtenCommands[0].bytes, <int>[0x11, 35]);
      expect(bleClient.writtenCommands[1].bytes, <int>[0x12, 90]);
    });

    test('public SDK exposes parsed device runtime status', () async {
      await _connectDemoDevice(sdk);

      final status = await sdk.getDeviceRuntimeStatus();

      expect(status.nodeId, 0x1234);
      expect(status.batteryPercent, 88);
      expect(status.telIntervalSeconds, 60);
    });

    test('public SDK reboot sends the expected BLE command', () async {
      await _connectDemoDevice(sdk);

      await sdk.rebootDevice();

      expect(bleClient.writtenCommands.last.bytes, <int>[0x22]);
    });

    test('public SDK rejects device command APIs without a connected device',
        () async {
      await expectLater(
        sdk.setDeviceNotificationVolume(10),
        throwsA(
          isA<DeviceException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_COMMAND_NOT_READY',
          ),
        ),
      );
    });
  });

  group('EixamConnectSdk operational diagnostics', () {
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
    late FakeTelemetryRepository telemetryRepository;
    late FakeContactsRepository contactsRepository;
    late FakeDeviceRepository deviceRepository;
    late FakeSdkDeviceRegistryRepository deviceRegistryRepository;
    late FakeDeathManRepository deathManRepository;
    late FakePermissionsRepository permissionsRepository;
    late FakeNotificationsRepository notificationsRepository;
    late FakeRealtimeClient realtimeClient;
    late StreamController<BleIncomingEvent> bleEvents;
    late PreferredBleDeviceStore preferredDeviceStore;
    late EixamConnectSdkImpl sdk;

    setUp(() async {
      sosRepository = FakeSosRepository();
      trackingRepository = FakeTrackingRepository();
      telemetryRepository = FakeTelemetryRepository();
      contactsRepository = FakeContactsRepository();
      deviceRepository = FakeDeviceRepository(
        initialStatus: const DeviceStatus(
          deviceId: 'ble-demo-r1',
          paired: true,
          activated: true,
          connected: true,
        ),
      );
      deviceRegistryRepository = FakeSdkDeviceRegistryRepository();
      deathManRepository = FakeDeathManRepository();
      permissionsRepository = FakePermissionsRepository();
      notificationsRepository = FakeNotificationsRepository();
      realtimeClient = FakeRealtimeClient();
      bleEvents = StreamController<BleIncomingEvent>.broadcast();
      preferredDeviceStore = PreferredBleDeviceStore(
        localStore: MemorySharedPrefsSdkStore(),
      );
      sdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: realtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: bleEvents.stream,
        preferredBleDeviceStore: preferredDeviceStore,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
    });

    tearDown(() async {
      await sdk.dispose();
      await sosRepository.dispose();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deviceRepository.dispose();
      await deathManRepository.dispose();
      await realtimeClient.dispose();
      await bleEvents.close();
    });

    test('exposes last typed TEL relay telemetry through diagnostics',
        () async {
      final relayPacket = EixamTelRelayRxPacket.tryParse(
        const <int>[
          0xD2,
          0xA8,
          0x1A,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x21,
          0xF6,
          0xC4,
          0xB0,
          0x1B,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x21,
        ],
        receivedAt: DateTime.utc(2026, 4, 18, 12),
      )!;

      bleEvents.add(
        BleIncomingEvent(
          deviceId: 'ble-demo-r1',
          type: BleIncomingEventType.telRelayRx,
          channel: EixamBleChannel.tel,
          payload: relayPacket.payload,
          payloadHex: EixamBleProtocol.hex(relayPacket.payload),
          source: DeviceSosTransitionSource.device,
          receivedAt: DateTime.utc(2026, 4, 18, 12),
          telRelayRxPacket: relayPacket,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final diagnostics = await sdk.getOperationalDiagnostics();

      expect(diagnostics.lastTelRelayRx, isNotNull);
      expect(diagnostics.lastTelRelayRx!.rxSnr, -10);
      expect(diagnostics.lastTelRelayRx!.rxRssi, -60);
    });
  });
}

Future<void> _connectDemoDevice(EixamConnectSdk sdk) async {
  BleDebugRegistry.instance
      .update(selectedDeviceId: MockBleClient.demoDeviceId);
  await sdk.connectDevice(pairingCode: '1234');
}
