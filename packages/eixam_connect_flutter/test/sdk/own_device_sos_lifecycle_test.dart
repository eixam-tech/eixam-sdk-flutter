import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('own-device native SOS lifecycle', () {
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
    late FakeTelemetryRepository telemetryRepository;
    late FakeContactsRepository contactsRepository;
    late FakeDeviceRepository deviceRepository;
    late FakeSdkDeviceRegistryRepository deviceRegistryRepository;
    late FakeDeathManRepository deathManRepository;
    late FakePermissionsRepository permissionsRepository;
    late FakeNotificationsRepository notificationsRepository;
    late PreferredBleDeviceStore preferredDeviceStore;

    setUp(() {
      BleDebugRegistry.instance.reset();
      sosRepository = FakeSosRepository();
      trackingRepository = FakeTrackingRepository(
        currentPosition: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 4, 29, 10),
          source: DeliveryMode.mobile,
        ),
      );
      telemetryRepository = FakeTelemetryRepository();
      contactsRepository = FakeContactsRepository();
      deviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(
          deviceId: 'own-tag',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.activated,
        ),
      );
      deviceRegistryRepository = FakeSdkDeviceRegistryRepository();
      deathManRepository = FakeDeathManRepository();
      permissionsRepository = FakePermissionsRepository();
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      notificationsRepository = FakeNotificationsRepository();
      preferredDeviceStore = PreferredBleDeviceStore(
        localStore: MemorySharedPrefsSdkStore(),
      );
    });

    tearDown(() async {
      await sosRepository.dispose();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deviceRepository.dispose();
      await deathManRepository.dispose();
    });

    EixamConnectSdkImpl buildSdk({
      required Stream<ProtectionPlatformEvent> events,
      required FakeRealtimeClient realtimeClient,
      required DeviceSosController deviceSosController,
      _FakeProtectionPlatformAdapter? adapter,
    }) {
      return EixamConnectSdkImpl(
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
        deviceSosController: deviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter:
            adapter ?? _FakeProtectionPlatformAdapter(platformEvents: events),
      );
    }

    test('sosType 1 from own device surfaces as pre-SOS countdown only',
        () async {
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final realtimeClient = FakeRealtimeClient();
      final sdk = buildSdk(
        events: events.stream,
        realtimeClient: realtimeClient,
        deviceSosController: DeviceSosController(),
      );

      try {
        await sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        events.add(_ownEvent(_ownPreSosPacket().rawHex));
        await Future<void>.delayed(const Duration(milliseconds: 30));

        final status = await sdk.getDeviceSosStatus();
        expect(status.state, DeviceSosState.preConfirm);
        expect(status.sosType, 1);
        expect(await sdk.getSosState(), SosState.arming);
        expect(sosRepository.triggerCallCount, 0);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains('[REMOTE_RELAY_SOS]'),
          ),
          isFalse,
        );
      } finally {
        await events.close();
        await sdk.dispose();
        await realtimeClient.dispose();
      }
    });

    test('own-device E1 01 terminal packet cancels pre-SOS locally', () async {
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final realtimeClient = FakeRealtimeClient();
      final sdk = buildSdk(
        events: events.stream,
        realtimeClient: realtimeClient,
        deviceSosController: DeviceSosController(),
      );

      try {
        await sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        events
          ..add(_ownEvent(_ownPreSosPacket().rawHex))
          ..add(_ownEvent('e10134120000'));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.inactive);
        expect(await sdk.getSosState(), SosState.cancelled);
        expect(sosRepository.cancelCallCount, 0);
      } finally {
        await events.close();
        await sdk.dispose();
        await realtimeClient.dispose();
      }
    });

    test('own-device E2 app cancel ACK is terminal and beats stale active',
        () async {
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final realtimeClient = FakeRealtimeClient();
      final sdk = buildSdk(
        events: events.stream,
        realtimeClient: realtimeClient,
        deviceSosController: DeviceSosController(),
      );

      try {
        await sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        events.add(_ownEvent(_ownActivePacket().rawHex));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(await sdk.getSosState(), SosState.sent);

        events.add(_ownEvent('e20234120000'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.resolved);
        expect(await sdk.getSosState(), SosState.resolved);

        sosRepository.currentIncident =
            sosRepository.currentIncident.copyWith(state: SosState.sent);
        sosRepository.stateController.add(SosState.sent);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(await sdk.getSosState(), SosState.resolved);
      } finally {
        await events.close();
        await sdk.dispose();
        await realtimeClient.dispose();
      }
    });

    test('app cancel sends one-byte SOS_CANCEL as a short native command',
        () async {
      sosRepository.currentIncident = SosIncident(
        id: 'sos-1',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final adapter = _FakeProtectionPlatformAdapter(
        platformEvents: events.stream,
        onSendCommand: (request) {
          if (request.label == 'SOS CANCEL') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(_ownEvent('e20234120000'));
            });
          }
        },
      );
      final controller = DeviceSosController(
        appActivationObservationTimeout: const Duration(milliseconds: 80),
      )..handleIncomingSosPacket(
          _ownActivePacket(),
          source: DeviceSosTransitionSource.device,
        );
      final realtimeClient = FakeRealtimeClient();
      final sdk = buildSdk(
        events: events.stream,
        realtimeClient: realtimeClient,
        deviceSosController: controller,
        adapter: adapter,
      );

      try {
        await sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await sdk.setSession(_testSession);
        await sdk.enterProtectionMode();
        final cancelled = await sdk.cancelSos();

        expect(cancelled.deliveryChannel, SosDeliveryChannel.backendAndDevice);
        expect(adapter.lastCommandRequest?.label, 'SOS CANCEL');
        expect(adapter.lastCommandRequest?.bytes, <int>[0x04]);
        expect(adapter.lastCommandRequest?.forceCmdCharacteristic, isFalse);
      } finally {
        await events.close();
        await sdk.dispose();
        await realtimeClient.dispose();
      }
    });

    test('app cancel reports backend-only when no command channel is available',
        () async {
      sosRepository.currentIncident = SosIncident(
        id: 'sos-1',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final adapter = _FakeProtectionPlatformAdapter(
        serviceBleReady: false,
        platformEvents: const Stream<ProtectionPlatformEvent>.empty(),
      );
      final controller = DeviceSosController()
        ..handleIncomingSosPacket(
          _ownActivePacket(),
          source: DeviceSosTransitionSource.device,
        );
      final realtimeClient = FakeRealtimeClient();
      final sdk = buildSdk(
        events: const Stream<ProtectionPlatformEvent>.empty(),
        realtimeClient: realtimeClient,
        deviceSosController: controller,
        adapter: adapter,
      );

      try {
        await sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await sdk.setSession(_testSession);
        await sdk.enterProtectionMode();
        final cancelled = await sdk.cancelSos();

        expect(cancelled.deliveryChannel, SosDeliveryChannel.backendOnly);
        expect(adapter.sendCommandCallCount, 0);
      } finally {
        await sdk.dispose();
        await realtimeClient.dispose();
      }
    });
  });
}

ProtectionPlatformEvent _ownEvent(String payloadHex) {
  return ProtectionPlatformEvent(
    type: ProtectionPlatformEventType.ownDeviceSosLifecycleObserved,
    timestamp: DateTime.utc(2026, 4, 29, 10),
    reason: 'own:sos:$payloadHex',
  );
}

EixamSosPacket _ownPreSosPacket() {
  return EixamSosPacket.tryParse(
    <int>[0x34, 0x12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x50],
  )!;
}

EixamSosPacket _ownActivePacket() {
  return EixamSosPacket.tryParse(
    <int>[0x34, 0x12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x80],
  )!;
}

const _testSession = EixamSession(
  appId: 'partner-app',
  externalUserId: 'sdk-test-user',
  userHash: 'signed-user-hash',
);

class _FakeProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  _FakeProtectionPlatformAdapter({
    required this.platformEvents,
    this.serviceBleReady = true,
    this.onSendCommand,
  });

  final Stream<ProtectionPlatformEvent> platformEvents;
  final bool serviceBleReady;
  final FutureOr<void> Function(ProtectionPlatformCommandRequest request)?
      onSendCommand;
  int sendCommandCallCount = 0;
  ProtectionPlatformCommandRequest? lastCommandRequest;

  @override
  ProtectionPlatform get platform => ProtectionPlatform.android;

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async {
    return ProtectionPlatformSnapshot(
      backgroundCapabilityReady: true,
      platformRuntimeConfigured: true,
      foregroundServiceConfigured: true,
      serviceRunning: true,
      runtimeActive: true,
      platform: ProtectionPlatform.android,
      bleOwner: ProtectionBleOwner.androidService,
      serviceBleConnected: true,
      serviceBleReady: serviceBleReady,
      runtimeState: ProtectionRuntimeState.active,
      coverageLevel: serviceBleReady
          ? ProtectionCoverageLevel.full
          : ProtectionCoverageLevel.partial,
      protectedDeviceId: 'own-tag',
      activeDeviceId: 'own-tag',
    );
  }

  @override
  Future<ProtectionPlatformStartResult> startProtectionRuntime({
    required ProtectionPlatformStartRequest request,
  }) async {
    return const ProtectionPlatformStartResult(success: true);
  }

  @override
  Future<void> stopProtectionRuntime() async {}

  @override
  Future<void> ensureProtectionRuntimeActive({
    String reason = 'app_foreground_resume',
  }) async {}

  @override
  Future<ProtectionPlatformFlushResult> flushProtectionQueues() async {
    return const ProtectionPlatformFlushResult();
  }

  @override
  Future<ProtectionPlatformCommandResult> sendProtectionCommand({
    required ProtectionPlatformCommandRequest request,
  }) async {
    sendCommandCallCount++;
    lastCommandRequest = request;
    await onSendCommand?.call(request);
    return const ProtectionPlatformCommandResult(success: true);
  }

  @override
  Future<ProtectionPermissionResult> requestProtectionPermissions() async {
    return const ProtectionPermissionResult(
      locationGranted: true,
      notificationsGranted: true,
      bluetoothGranted: true,
    );
  }

  @override
  Future<void> openProtectionSettings() async {}

  @override
  Stream<ProtectionPlatformEvent> watchPlatformEvents() => platformEvents;
}
