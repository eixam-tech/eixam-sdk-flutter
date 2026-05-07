import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_event_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const protectionMethodChannel = MethodChannel(
    'dev.eixam.connect_flutter/protection_runtime/methods',
  );

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(protectionMethodChannel, (call) async {
      switch (call.method) {
        case 'getPlatformSnapshot':
          return <String, dynamic>{
            'backgroundCapabilityReady': false,
            'platformRuntimeConfigured': false,
            'runtimeState': 'inactive',
            'coverageLevel': 'none',
          };
        case 'flushProtectionQueues':
          return <String, dynamic>{
            'flushedSosCount': 0,
            'flushedTelemetryCount': 0,
            'success': true,
          };
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(protectionMethodChannel, null);
  });

  group('SOS-01..SOS-16 SDK lifecycle matrix', () {
    test('SOS-01 app-origin resolve during countdown resolves and clears',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

        expect(await harness.sdk.getSosState(), SosState.arming);
        expect(await harness.sdk.getPreSosStatus(), isNotNull);

        await harness.sdk.resolveSos();

        expect(harness.sosRepository.triggerCallCount, 1);
        expect(harness.sosRepository.resolveCallCount, 1);
        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.resolved);
        expect(harness.sosRepository.currentIncident.state, SosState.resolved);
      } finally {
        await harness.dispose();
      }
    });

    test('resolved summary remains until acknowledged, then returns idle',
        () async {
      final repository = _HistoryFakeSosRepository();
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.sdk.triggerSos(const SosTriggerPayload());
        await harness.sdk.resolveSos();

        expect(await harness.sdk.getSosState(), SosState.resolved);
        expect(repository.resolveCallCount, 1);

        final acknowledged = await harness.sdk.acknowledgeSosSummary();

        expect(acknowledged, SosState.idle);
        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(repository.resolveCallCount, 1);
        expect(repository.cancelCallCount, 0);

        final history = await harness.sdk.listSosHistory();
        expect(history.items, hasLength(1));
        expect(history.items.single.id, repository.currentIncident.id);
        expect(history.items.single.state, SosState.resolved);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-02 app-origin cancel active SOS cancels and clears', () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.triggerSos(const SosTriggerPayload());

        expect(await harness.sdk.getSosState(), SosState.sent);

        final cancelled = await harness.sdk.cancelSos();

        expect(harness.sosRepository.cancelCallCount, 1);
        expect(cancelled.state, SosState.cancelled);
        expect(await harness.sdk.getSosState(), SosState.cancelled);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-03 app-origin cancel during countdown stops before send',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

        final cancelled = await harness.sdk.cancelSos();

        expect(cancelled.state, SosState.cancelled);
        expect(harness.sosRepository.triggerCallCount, 0);
        expect(harness.sosRepository.cancelCallCount, 0);
        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.idle);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-04 BLE app-origin cancel requests backend and clears state',
        () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.deviceSosController.attach(commandWriter: (_) async {});
        await harness.sdk.triggerSos(const SosTriggerPayload());

        await harness.sdk.cancelSos();

        expect(harness.sosRepository.cancelCallCount, 1);
        expect(await harness.sdk.getSosState(), SosState.cancelled);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-05 BLE app-origin resolve requests backend and clears state',
        () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.deviceSosController.attach(commandWriter: (_) async {});
        await harness.sdk.triggerSos(const SosTriggerPayload());

        await harness.sdk.resolveSos();

        expect(harness.sosRepository.resolveCallCount, 1);
        expect(await harness.sdk.getSosState(), SosState.resolved);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-06 BLE device cancel clears app-origin active SOS', () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.attachObservedDeviceCloseAck();
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.sent,
          triggerSource: 'app',
        );

        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacket(),
          source: DeviceSosTransitionSource.device,
        );
        harness.deviceSosController.handleIncomingSosEventPacket(
          _deviceCancelPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 3);

        expect(harness.sosRepository.cancelCallCount, 1);
        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.cancelled);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-07 BLE device-origin countdown cancel clears countdown',
        () async {
      final harness = _SdkSosHarness(
        connectedBle: true,
        deviceCountdown: const Duration(seconds: 20),
      );
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );

        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginCountdownPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 2);
        expect(await harness.sdk.getPreSosStatus(), isNotNull);

        harness.deviceSosController.handleIncomingSosEventPacket(
          _deviceCancelPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 2);

        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.cancelled);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-08 BLE device-origin active can be cancelled by app', () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.attachObservedDeviceCloseAck();
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.sent,
          triggerSource: 'ble_device_runtime',
        );
        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 2);

        await harness.sdk.cancelSos();
        await pumpEventQueue(times: 2);

        expect(harness.sosRepository.cancelCallCount, 1);
        expect(await harness.sdk.getSosState(), SosState.cancelled);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-09 BLE device-origin active can be resolved by app', () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.attachObservedDeviceCloseAck();
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.sent,
          triggerSource: 'ble_device_runtime',
        );
        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 2);

        await harness.sdk.resolveSos();
        await pumpEventQueue(times: 2);

        expect(harness.sosRepository.resolveCallCount, 1);
        expect(await harness.sdk.getSosState(), SosState.resolved);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-10 resume can expose coherent device-origin countdown', () async {
      final harness = _SdkSosHarness(
        connectedBle: true,
        deviceCountdown: const Duration(seconds: 20),
      );
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginCountdownPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 2);

        harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 2);
        final status = await harness.sdk.getPreSosStatus();

        expect(status, isNotNull);
        expect(status!.remainingSeconds, inInclusiveRange(1, 20));
        expect(await harness.sdk.getSosState(), SosState.arming);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-11 resume rehydrates backend active SOS', () async {
      final repository = FakeRehydratingSosRepository()
        ..currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'ble_device_runtime',
        )
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.hydratedFromBackend,
          resultingState: SosState.sent,
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();
        harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 3);

        expect(await harness.sdk.getSosState(), SosState.sent);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-12 resume lets backend terminal/idle beat stale active state',
        () async {
      final repository = FakeRehydratingSosRepository()
        ..currentIncident = _incident(
          state: SosState.cancelled,
          triggerSource: 'ble_device_runtime',
        )
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

        harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 3);

        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.idle);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-13 LoRa/backend foreground active maps to SDK active', () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        harness.sosRepository.currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'remote_lora_relay',
        );
        harness.sosRepository.stateController.add(SosState.sent);
        await pumpEventQueue(times: 2);

        expect(await harness.sdk.getSosState(), SosState.sent);
        expect(
          (await harness.sdk.getCurrentSosIncident())?.triggerSource,
          'remote_lora_relay',
        );
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-14 LoRa/backend terminal clears SDK active state', () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        harness.sosRepository.currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'remote_lora_relay',
        );
        harness.sosRepository.stateController.add(SosState.sent);
        await pumpEventQueue(times: 1);
        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.cancelled,
        );
        harness.sosRepository.stateController.add(SosState.cancelled);
        await pumpEventQueue(times: 2);

        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.cancelled);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-15 resume reconstructs active LoRa/backend SOS', () async {
      final repository = FakeRehydratingSosRepository()
        ..currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'remote_lora_relay',
        )
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.hydratedFromBackend,
          resultingState: SosState.sent,
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();
        harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 3);

        expect(await harness.sdk.getSosState(), SosState.sent);
        expect(
          (await harness.sdk.getCurrentSosIncident())?.triggerSource,
          'remote_lora_relay',
        );
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-16 resume does not resurrect stale countdown after LoRa cancel',
        () async {
      final repository = FakeRehydratingSosRepository()
        ..currentIncident = _incident(
          state: SosState.cancelled,
          triggerSource: 'remote_lora_relay',
        )
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.hydratedFromBackend,
          resultingState: SosState.cancelled,
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

        harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 3);

        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.cancelled);
      } finally {
        await harness.dispose();
      }
    });
  });
}

final class _SdkSosHarness {
  _SdkSosHarness({
    FakeSosRepository? sosRepository,
    bool connectedBle = false,
    Duration deviceCountdown = const Duration(seconds: 20),
  })  : sosRepository = sosRepository ?? FakeSosRepository(),
        trackingRepository = FakeTrackingRepository(
          currentPosition: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.utc(2026, 1, 1, 10),
            source: DeliveryMode.mobile,
          ),
        ),
        telemetryRepository = FakeTelemetryRepository(),
        contactsRepository = FakeContactsRepository(),
        deviceRepository = FakeDeviceRepository(
          initialStatus: buildDeviceStatus(
            deviceId: connectedBle ? 'ble-1' : 'none',
            canonicalHardwareId: connectedBle ? 'CF:82:00:00:00:01' : null,
            connected: connectedBle,
            paired: connectedBle,
            activated: connectedBle,
          ),
        ),
        deviceRegistryRepository = FakeSdkDeviceRegistryRepository(),
        deathManRepository = FakeDeathManRepository(),
        permissionsRepository = FakePermissionsRepository(
          permissionState: const PermissionState(
            location: SdkPermissionStatus.granted,
            notifications: SdkPermissionStatus.granted,
            bluetooth: SdkPermissionStatus.granted,
          ),
        ),
        notificationsRepository = FakeNotificationsRepository(),
        realtimeClient = FakeRealtimeClient(),
        deviceSosController = DeviceSosController(
          countdownDuration: deviceCountdown,
          countdownTick: const Duration(milliseconds: 5),
        ),
        preferredBleDeviceStore = PreferredBleDeviceStore(
          localStore: MemorySharedPrefsSdkStore(),
        ) {
    sdk = EixamConnectSdkImpl(
      sosRepository: this.sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: telemetryRepository,
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deviceRegistryRepository: deviceRegistryRepository,
      deathManRepository: deathManRepository,
      permissionsRepository: permissionsRepository,
      notificationsRepository: notificationsRepository,
      realtimeClient: realtimeClient,
      deviceSosController: deviceSosController,
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: preferredBleDeviceStore,
    );
  }

  final FakeSosRepository sosRepository;
  final FakeTrackingRepository trackingRepository;
  final FakeTelemetryRepository telemetryRepository;
  final FakeContactsRepository contactsRepository;
  final FakeDeviceRepository deviceRepository;
  final FakeSdkDeviceRegistryRepository deviceRegistryRepository;
  final FakeDeathManRepository deathManRepository;
  final FakePermissionsRepository permissionsRepository;
  final FakeNotificationsRepository notificationsRepository;
  final FakeRealtimeClient realtimeClient;
  final DeviceSosController deviceSosController;
  final PreferredBleDeviceStore preferredBleDeviceStore;
  late final EixamConnectSdkImpl sdk;

  Future<void> setSession() {
    return sdk.setSession(
      const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      ),
    );
  }

  Future<void> attachObservedDeviceCloseAck() {
    return deviceSosController.attach(
      commandWriter: (command) async {
        if (command.opcode == 0x04) {
          scheduleMicrotask(() {
            deviceSosController.handleIncomingSosEventPacket(
              _deviceResolveAckPacket(),
              source: DeviceSosTransitionSource.device,
            );
          });
        }
      },
    );
  }

  Future<void> dispose() async {
    await sdk.dispose();
    await sosRepository.dispose();
    await trackingRepository.dispose();
    await contactsRepository.dispose();
    await deviceRepository.dispose();
    await realtimeClient.dispose();
  }
}

final class _HistoryFakeSosRepository extends FakeSosRepository {
  @override
  Future<SosHistoryPage> listSosHistory(
      {String? cursor, int limit = 20}) async {
    return SosHistoryPage(
      items: <SosHistoryItem>[
        SosHistoryItem(
          id: currentIncident.id,
          state: currentIncident.state,
          createdAt: currentIncident.createdAt,
          triggerSource: currentIncident.triggerSource,
          message: currentIncident.message,
          deliveryChannel: currentIncident.deliveryChannel,
          positionSnapshot: currentIncident.positionSnapshot,
        ),
      ],
      hasMore: false,
    );
  }
}

SosIncident _incident({
  required SosState state,
  required String triggerSource,
}) {
  return SosIncident(
    id: 'sos-${triggerSource.replaceAll('_', '-')}',
    state: state,
    createdAt: DateTime.utc(2026, 3, 31, 10),
    triggerSource: triggerSource,
  );
}

EixamSosPacket _deviceOriginCountdownPacket() {
  return EixamSosPacket.tryParse(<int>[
    0x34,
    0x12,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x50,
  ])!;
}

EixamSosPacket _deviceOriginActivePacket() {
  return EixamSosPacket.tryParse(<int>[
    0x34,
    0x12,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x80,
  ])!;
}

EixamSosEventPacket _deviceCancelPacket() {
  return EixamSosEventPacket.tryParse(
    <int>[0xE1, 0x01, 0x34, 0x12, 0x00, 0x00],
  )!;
}

EixamSosEventPacket _deviceResolveAckPacket() {
  return EixamSosEventPacket.tryParse(
    <int>[0xE1, 0x02, 0x34, 0x12, 0x00, 0x00],
  )!;
}
