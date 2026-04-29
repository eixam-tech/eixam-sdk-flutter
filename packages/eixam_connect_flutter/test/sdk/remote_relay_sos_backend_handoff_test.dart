import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remote relay SOS backend handoff', () {
    late StreamController<BleIncomingEvent> bleEvents;
    late _FakeOperationalRealtimeClient realtimeClient;
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
    late FakeTelemetryRepository telemetryRepository;
    late FakeContactsRepository contactsRepository;
    late FakeDeviceRepository deviceRepository;
    late FakeSdkDeviceRegistryRepository deviceRegistryRepository;
    late FakeDeathManRepository deathManRepository;
    late FakePermissionsRepository permissionsRepository;
    late FakeNotificationsRepository notificationsRepository;
    late DeviceSosController deviceSosController;
    late PreferredBleDeviceStore preferredDeviceStore;
    late EixamConnectSdkImpl sdk;
    late List<EixamDeviceCommand> deviceCommands;

    setUp(() async {
      bleEvents = StreamController<BleIncomingEvent>.broadcast();
      realtimeClient = _FakeOperationalRealtimeClient();
      sosRepository = FakeSosRepository();
      trackingRepository = FakeTrackingRepository();
      telemetryRepository = FakeTelemetryRepository();
      contactsRepository = FakeContactsRepository();
      deviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(
          deviceId: 'relay-tag',
          canonicalHardwareId: 'relay-node',
          connected: true,
          paired: true,
          activated: true,
        ),
      );
      deviceRegistryRepository = FakeSdkDeviceRegistryRepository();
      deathManRepository = FakeDeathManRepository();
      permissionsRepository = FakePermissionsRepository();
      notificationsRepository = FakeNotificationsRepository();
      deviceSosController = DeviceSosController();
      preferredDeviceStore = PreferredBleDeviceStore(
        localStore: MemorySharedPrefsSdkStore(),
      );
      deviceCommands = <EixamDeviceCommand>[];
      await deviceSosController.attach(
        commandWriter: (command) async {
          deviceCommands.add(command);
        },
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
        deviceSosController: deviceSosController,
        bleIncomingEvents: bleEvents.stream,
        preferredBleDeviceStore: preferredDeviceStore,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
    });

    tearDown(() async {
      await sdk.dispose();
      await bleEvents.close();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deviceRepository.dispose();
      await deathManRepository.dispose();
      await realtimeClient.dispose();
      await sosRepository.dispose();
    });

    test('publishes backend SOS with originator node id as deviceId', () async {
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      bleEvents.add(_remoteRelayEvent());
      await _eventually(() => realtimeClient.publishedSos.length == 1);

      final request = realtimeClient.publishedSos.single;
      expect(request.deviceId, '16909060');
      expect(request.timestamp, DateTime.utc(2026, 4, 28, 10, 15));
      expect(request.positionSnapshot!.latitude, 41.3874);
      expect(request.positionSnapshot!.longitude, 2.1686);
      expect(request.positionSnapshot!.altitude, 42.5);
      expect(events.whereType<RemoteRelaySosObservedEvent>(), isNotEmpty);
      expect(
        events
            .whereType<RemoteRelaySosBackendHandoffResultEvent>()
            .single
            .status,
        RemoteRelaySosBackendHandoffStatus.submitted,
      );

      await subscription.cancel();
    });

    test('uses originatorNodeId, not relayNodeId, as backend deviceId',
        () async {
      bleEvents.add(
        _remoteRelayEvent(
          snapshot: _snapshot(originatorNodeId: 1234, relayNodeId: 9999),
        ),
      );
      await _eventually(() => realtimeClient.publishedSos.length == 1);

      expect(realtimeClient.publishedSos.single.deviceId, '1234');
      expect(realtimeClient.publishedSos.single.deviceId, isNot('9999'));
    });

    test('without location still publishes backend SOS and sends ACK_RELAY',
        () async {
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      bleEvents.add(_remoteRelayEvent(snapshot: _snapshot(location: null)));
      await _eventually(() => realtimeClient.publishedSos.length == 1);
      await _eventually(() => deviceCommands.length == 1);

      final request = realtimeClient.publishedSos.single;
      expect(request.deviceId, '16909060');
      expect(request.positionSnapshot, isNull);
      expect(deviceCommands.single.bytes, <int>[0x08, 0x04, 0x03, 0x02, 0x01]);
      final result =
          events.whereType<RemoteRelaySosBackendHandoffResultEvent>().single;
      expect(result.status, RemoteRelaySosBackendHandoffStatus.submitted);
      expect(result.ackRelaySent, isTrue);

      await subscription.cancel();
    });

    test('backend success sends SOS_ACK_RELAY 0x08 to originator node',
        () async {
      bleEvents.add(
        _remoteRelayEvent(snapshot: _snapshot(originatorNodeId: 0x01020304)),
      );
      await _eventually(() => deviceCommands.length == 1);

      final command = deviceCommands.single;
      expect(command.opcode, 0x08);
      expect(command.bytes, <int>[0x08, 0x04, 0x03, 0x02, 0x01]);
    });

    test('backend failure emits failed event and leaves local SOS state idle',
        () async {
      realtimeClient.publishSosError = const SosException(
        'E_BACKEND_DOWN',
        'backend unavailable',
      );
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      bleEvents.add(_remoteRelayEvent());
      await _eventually(
        () => events.whereType<RemoteRelaySosBackendHandoffResultEvent>().any(
            (event) =>
                event.status == RemoteRelaySosBackendHandoffStatus.failed),
      );

      expect(deviceCommands, isEmpty);
      expect(await sdk.getSosState(), SosState.idle);
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);
      expect(sosRepository.triggerCallCount, 0);

      await subscription.cancel();
    });

    test('remote relay still emits RemoteRelaySosObservedEvent', () async {
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      bleEvents.add(_remoteRelayEvent());
      await _eventually(
        () => events.whereType<RemoteRelaySosObservedEvent>().isNotEmpty,
      );

      final event = events.whereType<RemoteRelaySosObservedEvent>().single;
      expect(event.snapshot.originatorNodeId, 0x01020304);

      await subscription.cancel();
    });

    test('duplicate remote relay snapshot is not submitted twice', () async {
      final event = _remoteRelayEvent();

      bleEvents.add(event);
      bleEvents.add(event);
      await _eventually(() => realtimeClient.publishedSos.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(realtimeClient.publishedSos.length, 1);
    });

    test('own-device SOS repository behavior remains unchanged', () async {
      await sdk.triggerSos(
        const SosTriggerPayload(message: 'local SOS'),
      );

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastMessage, 'local SOS');
      expect(realtimeClient.publishedSos, isEmpty);
    });

    test('platform unknown-origin SOS does not enter deviceSosController',
        () async {
      await sdk.dispose();
      final platformEvents =
          StreamController<ProtectionPlatformEvent>.broadcast();
      final platformAdapter = _FakeProtectionPlatformAdapter(
        platformEvents: platformEvents.stream,
      );
      deviceSosController = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      deviceCommands = <EixamDeviceCommand>[];
      await deviceSosController.attach(
        commandWriter: (command) async {
          deviceCommands.add(command);
        },
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
        deviceSosController: deviceSosController,
        bleIncomingEvents: bleEvents.stream,
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: platformAdapter,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
      await sdk.enterProtectionMode();

      platformEvents.add(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.sosEventReceived,
          timestamp: DateTime.utc(2026, 4, 28, 10, 30),
          reason: '78563412004009',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);
      expect(await sdk.getPreSosStatus(), isNull);
      expect(deviceCommands, isEmpty);

      await platformEvents.close();
    });

    group('remote relay cancel handoff', () {
      late _FakeCancelRemoteDataSource cancelDataSource;

      Future<void> useSdkWithCancelDataSource() async {
        await sdk.dispose();
        deviceSosController = DeviceSosController();
        deviceCommands = <EixamDeviceCommand>[];
        await deviceSosController.attach(
          commandWriter: (command) async {
            deviceCommands.add(command);
          },
        );
        cancelDataSource = _FakeCancelRemoteDataSource();
        sdk = EixamConnectSdkImpl(
          sosRepository: MqttOperationalSosRepository(
            realtimeClient: realtimeClient,
            cancelRemoteDataSource: cancelDataSource,
          ),
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
          bleIncomingEvents: bleEvents.stream,
          preferredBleDeviceStore: preferredDeviceStore,
        );
        await sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
      }

      setUp(() {
        cancelDataSource = _FakeCancelRemoteDataSource();
      });

      test('remote 0xE1/0x02 cancel posts cancel with originator node deviceId',
          () async {
        await useSdkWithCancelDataSource();
        final events = <EixamSdkEvent>[];
        final subscription = sdk.watchEvents().listen(events.add);

        bleEvents.add(
          _remoteRelayEvent(
            snapshot: _cancelSnapshot(
              originatorNodeId: 1234,
              relayNodeId: 9999,
            ),
          ),
        );
        await _eventually(() => cancelDataSource.cancelDeviceIds.length == 1);

        expect(cancelDataSource.cancelDeviceIds.single, '1234');
        expect(cancelDataSource.cancelDeviceIds.single, isNot('9999'));
        expect(cancelDataSource.sentCancelWithoutDeviceId, isFalse);
        expect(sosRepository.cancelCallCount, 0);
        expect(await sdk.getSosState(), SosState.idle);
        expect((await deviceSosController.getStatus()).state,
            DeviceSosState.inactive);
        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.status, RemoteRelaySosBackendHandoffStatus.submitted);
        expect(result.deviceId, '1234');
        expect(result.originatorNodeId, 1234);
        expect(result.relayNodeId, 9999);

        await subscription.cancel();
      });

      test('remote cancel backend 409 emits failed conflict result', () async {
        await useSdkWithCancelDataSource();
        cancelDataSource.cancelError = const SosHttpException(
          'E_HTTP_SOS_CANCEL_CONFLICT',
          'conflict',
          statusCode: 409,
        );
        final events = <EixamSdkEvent>[];
        final subscription = sdk.watchEvents().listen(events.add);

        bleEvents.add(_remoteRelayEvent(snapshot: _cancelSnapshot()));
        await _eventually(
          () => events.whereType<RemoteRelaySosCancelHandoffResultEvent>().any(
                (event) =>
                    event.status == RemoteRelaySosBackendHandoffStatus.failed,
              ),
        );

        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.reason, 'conflict_not_associated');
        expect(cancelDataSource.cancelDeviceIds.single, '16909060');

        await subscription.cancel();
      });

      test('remote cancel backend 422 emits failed unknown_device result',
          () async {
        await useSdkWithCancelDataSource();
        cancelDataSource.cancelError = const SosHttpException(
          'E_HTTP_SOS_CANCEL_UNKNOWN_DEVICE',
          'unknown device',
          statusCode: 422,
        );
        final events = <EixamSdkEvent>[];
        final subscription = sdk.watchEvents().listen(events.add);

        bleEvents.add(_remoteRelayEvent(snapshot: _cancelSnapshot()));
        await _eventually(
          () => events.whereType<RemoteRelaySosCancelHandoffResultEvent>().any(
                (event) =>
                    event.status == RemoteRelaySosBackendHandoffStatus.failed,
              ),
        );

        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.reason, 'unknown_device');

        await subscription.cancel();
      });

      test('remote cancel backend exception emits failed event without crash',
          () async {
        await useSdkWithCancelDataSource();
        cancelDataSource.cancelError =
            const NetworkException('E_NETWORK', 'offline');
        final events = <EixamSdkEvent>[];
        final subscription = sdk.watchEvents().listen(events.add);

        bleEvents.add(_remoteRelayEvent(snapshot: _cancelSnapshot()));
        await _eventually(
          () => events.whereType<RemoteRelaySosCancelHandoffResultEvent>().any(
                (event) =>
                    event.status == RemoteRelaySosBackendHandoffStatus.failed,
              ),
        );

        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.reason, 'network_error');
        expect(await sdk.getSosState(), SosState.idle);
        expect(sosRepository.cancelCallCount, 0);

        await subscription.cancel();
      });

      test('own-device cancel behavior remains unchanged', () async {
        await sdk.triggerSos(const SosTriggerPayload(message: 'local SOS'));

        await sdk.cancelSos();

        expect(sosRepository.cancelCallCount, 1);
        expect(sosRepository.currentIncident.state, SosState.cancelled);
      });
    });
  });
}

BleIncomingEvent _remoteRelayEvent({RemoteRelaySosSnapshot? snapshot}) {
  final resolvedSnapshot = snapshot ?? _snapshot();
  return BleIncomingEvent(
    deviceId: 'relay-tag',
    canonicalHardwareId: 'relay-node',
    type: BleIncomingEventType.sosMeshPacket,
    channel: EixamBleChannel.sos,
    payload: resolvedSnapshot.rawPayload,
    payloadHex: EixamBleProtocol.hex(resolvedSnapshot.rawPayload),
    source: DeviceSosTransitionSource.device,
    receivedAt: resolvedSnapshot.receivedAt,
    remoteRelaySosSnapshot: resolvedSnapshot,
    classification: BleIncomingPayloadClassification(
      kind: resolvedSnapshot.kind == RemoteRelaySosKind.sos
          ? BleIncomingPayloadKind.remoteRelaySos
          : BleIncomingPayloadKind.sosCancel,
      remoteRelaySosSnapshot: resolvedSnapshot,
    ),
  );
}

RemoteRelaySosSnapshot _cancelSnapshot({
  int originatorNodeId = 0x01020304,
  int? relayNodeId = 0x0A0B0C0D,
}) {
  return RemoteRelaySosSnapshot(
    kind: RemoteRelaySosKind.clear,
    originatorNodeId: originatorNodeId,
    relayNodeId: relayNodeId,
    source: RemoteRelaySosSource.sosNotify,
    sosType: 0,
    receivedAt: DateTime.utc(2026, 4, 28, 10, 20),
    rawPayload: <int>[
      0xE1,
      0x02,
      originatorNodeId & 0xFF,
      (originatorNodeId >> 8) & 0xFF,
      (originatorNodeId >> 16) & 0xFF,
      (originatorNodeId >> 24) & 0xFF,
    ],
    payloadHex: EixamBleProtocol.hex(<int>[
      0xE1,
      0x02,
      originatorNodeId & 0xFF,
      (originatorNodeId >> 8) & 0xFF,
      (originatorNodeId >> 16) & 0xFF,
      (originatorNodeId >> 24) & 0xFF,
    ]),
    eventOpcode: 0xE1,
    eventSubcode: 0x02,
  );
}

RemoteRelaySosSnapshot _snapshot({
  int originatorNodeId = 0x01020304,
  int? relayNodeId = 0x0A0B0C0D,
  Object? location = _defaultRemoteRelayLocation,
}) {
  final resolvedLocation = identical(location, _defaultRemoteRelayLocation)
      ? TrackingPosition(
          latitude: 41.3874,
          longitude: 2.1686,
          altitude: 42.5,
          timestamp: DateTime.utc(2026, 4, 28, 10),
        )
      : location as TrackingPosition?;
  return RemoteRelaySosSnapshot(
    kind: RemoteRelaySosKind.sos,
    originatorNodeId: originatorNodeId,
    relayNodeId: relayNodeId,
    source: RemoteRelaySosSource.sosNotify,
    sosType: 2,
    receivedAt: DateTime.utc(2026, 4, 28, 10, 15),
    rawPayload: <int>[0xAA, 0xBB, originatorNodeId & 0xFF],
    payloadHex:
        'aabb${(originatorNodeId & 0xFF).toRadixString(16).padLeft(2, '0')}',
    location: resolvedLocation,
  );
}

class _FakeCancelRemoteDataSource implements SosRemoteDataSource {
  final List<String?> cancelDeviceIds = <String?>[];
  Object? cancelError;

  bool get sentCancelWithoutDeviceId =>
      cancelDeviceIds.any((deviceId) => deviceId == null || deviceId.isEmpty);

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SosIncidentDto?> cancelSos({String? deviceId}) async {
    cancelDeviceIds.add(deviceId);
    final error = cancelError;
    if (error != null) {
      throw error;
    }
    return null;
  }

  @override
  Future<SosIncidentDto?> resolveSos() async => null;

  @override
  Future<SosIncidentDto?> getActiveSos() async => null;
}

class _FakeProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  _FakeProtectionPlatformAdapter({
    required this.platformEvents,
  });

  final Stream<ProtectionPlatformEvent> platformEvents;

  @override
  ProtectionPlatform get platform => ProtectionPlatform.android;

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async {
    return const ProtectionPlatformSnapshot(
      backgroundCapabilityReady: true,
      platformRuntimeConfigured: true,
      foregroundServiceConfigured: true,
      serviceRunning: true,
      runtimeActive: true,
      platform: ProtectionPlatform.android,
      bleOwner: ProtectionBleOwner.androidService,
      serviceBleConnected: true,
      serviceBleReady: true,
      runtimeState: ProtectionRuntimeState.active,
      coverageLevel: ProtectionCoverageLevel.full,
      protectedDeviceId: 'relay-tag',
      activeDeviceId: 'relay-tag',
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

const Object _defaultRemoteRelayLocation = Object();

Future<void> _eventually(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}

class _FakeOperationalRealtimeClient implements OperationalRealtimeClient {
  final List<MqttOperationalSosRequest> publishedSos =
      <MqttOperationalSosRequest>[];
  final List<SdkTelemetryPayload> publishedTelemetry = <SdkTelemetryPayload>[];
  final StreamController<RealtimeConnectionState> _connectionController =
      StreamController<RealtimeConnectionState>.broadcast();
  final StreamController<RealtimeEvent> _eventController =
      StreamController<RealtimeEvent>.broadcast();
  Object? publishSosError;

  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    final error = publishSosError;
    if (error != null) {
      throw error;
    }
    publishedSos.add(request);
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    publishedTelemetry.add(payload);
  }

  @override
  Future<void> reconnectIfSessionChanged(EixamSession session) async {}

  @override
  Future<void> connect() async {
    _connectionController.add(RealtimeConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {}

  @override
  Stream<RealtimeConnectionState> watchConnectionState() =>
      _connectionController.stream;

  @override
  Stream<RealtimeEvent> watchEvents() => _eventController.stream;

  Future<void> dispose() async {
    await _connectionController.close();
    await _eventController.close();
  }
}
