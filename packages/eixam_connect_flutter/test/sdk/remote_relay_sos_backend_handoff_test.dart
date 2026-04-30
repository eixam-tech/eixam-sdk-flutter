import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_payload_classifier.dart';
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

    test('12-byte remote relay SOS backend handoff includes packet location',
        () async {
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      bleEvents.add(_remoteRelayEventFromPayload());
      await _eventually(() => realtimeClient.publishedSos.length == 1);

      final request = realtimeClient.publishedSos.single;
      expect(request.deviceId, '16909060');
      expect(request.timestamp, DateTime.utc(2026, 4, 28, 10, 15));
      expect(
        request.positionSnapshot!.latitude,
        closeTo(42.7711486816406, 0.000001),
      );
      expect(
        request.positionSnapshot!.longitude,
        closeTo(-132.044506072998, 0.000001),
      );
      expect(request.positionSnapshot!.altitude, 800);
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

    test('12-byte remote relay SOS propagates location to SDK event', () async {
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      bleEvents.add(_remoteRelayEventFromPayload());
      await _eventually(
        () => events.whereType<RemoteRelaySosObservedEvent>().isNotEmpty,
      );

      final snapshot =
          events.whereType<RemoteRelaySosObservedEvent>().single.snapshot;
      expect(snapshot.location, isNotNull);
      expect(snapshot.location!.latitude, closeTo(42.7711486816406, 0.000001));
      expect(
          snapshot.location!.longitude, closeTo(-132.044506072998, 0.000001));
      expect(snapshot.location!.altitude, 800);

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

    test(
        '7-byte remote relay SOS without location still publishes backend SOS and sends ACK_RELAY',
        () async {
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      bleEvents.add(
        _remoteRelayEventFromPayload(
          payload: const <int>[0x04, 0x03, 0x02, 0x01, 0x00, 0x80, 0x09],
        ),
      );
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

    test('remote relay notification is independent of local pre-SOS', () async {
      bleEvents.add(_remoteRelayEventFromPayload());
      await _eventually(
          () => notificationsRepository.notifications.length == 1);

      final notification = notificationsRepository.notifications.single;
      expect(notification.title, 'Remote SOS received');
      expect(notification.payload, contains('"kind":"sos_received"'));
      expect(await sdk.getPreSosStatus(), isNull);
      expect(
        (await deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
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

    test('platform unknown-origin SOS routes to remote candidate handoff',
        () async {
      await sdk.dispose();
      final events = <EixamSdkEvent>[];
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
      final subscription = sdk.watchEvents().listen(events.add);
      await sdk.enterProtectionMode();

      platformEvents.add(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.sosEventReceived,
          timestamp: DateTime.utc(2026, 4, 28, 10, 30),
          reason: 'unknown:SOS_NOTIFY:77dee60dbb8d681a071f8043',
        ),
      );
      await _eventually(() => realtimeClient.publishedSos.length == 1);
      await _eventually(
        () => events.whereType<RemoteRelaySosBackendHandoffResultEvent>().any(
              (event) =>
                  event.status == RemoteRelaySosBackendHandoffStatus.submitted,
            ),
      );

      final request = realtimeClient.publishedSos.single;
      expect(request.deviceId, '233234039');
      expect(request.positionSnapshot, isNotNull);
      expect(
        request.positionSnapshot!.latitude,
        closeTo(6.228389739990234, 0.000001),
      );
      expect(
        request.positionSnapshot!.longitude,
        closeTo(4.994316101074219, 0.000001),
      );
      expect(request.positionSnapshot!.altitude, 600);
      expect(notificationsRepository.notifications, hasLength(1));
      expect(
        events.whereType<RemoteRelaySosObservedEvent>().single.snapshot,
        isA<RemoteRelaySosSnapshot>()
            .having((snapshot) => snapshot.originatorNodeId, 'originatorNodeId',
                233234039)
            .having((snapshot) => snapshot.relayNodeId, 'relayNodeId', isNull)
            .having((snapshot) => snapshot.location, 'location', isNotNull),
      );
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);
      expect(await sdk.getPreSosStatus(), isNull);
      expect(deviceCommands, isEmpty);
      expect(deviceCommands.any((command) => command.opcode == 0x07), isFalse);
      final result =
          events.whereType<RemoteRelaySosBackendHandoffResultEvent>().single;
      expect(result.ackRelaySent, isFalse);

      await subscription.cancel();
      await platformEvents.close();
    });

    test(
      'platform event mislabeled as own-device routes by payload originator identity',
      () async {
        await sdk.dispose();
        BleDebugRegistry.instance.reset();
        final events = <EixamSdkEvent>[];
        final platformEvents =
            StreamController<ProtectionPlatformEvent>.broadcast();
        final platformAdapter = _FakeProtectionPlatformAdapter(
          platformEvents: platformEvents.stream,
        );
        final localDeviceSosController = DeviceSosController(
          countdownDuration: const Duration(milliseconds: 40),
          countdownTick: const Duration(milliseconds: 5),
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
          deviceSosController: localDeviceSosController,
          bleIncomingEvents: bleEvents.stream,
          preferredBleDeviceStore: preferredDeviceStore,
          protectionPlatformAdapter: platformAdapter,
        );
        await sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        final subscription = sdk.watchEvents().listen(events.add);
        await sdk.enterProtectionMode();

        platformEvents.add(
          ProtectionPlatformEvent(
            type: ProtectionPlatformEventType.ownDeviceSosLifecycleObserved,
            timestamp: DateTime.utc(2026, 4, 28, 10, 31),
            reason: 'remote:sos:168496141:04030201008009',
          ),
        );
        await _eventually(() => realtimeClient.publishedSos.length == 1);
        await _eventually(
          () => events.whereType<RemoteRelaySosObservedEvent>().isNotEmpty,
        );

        final observed = events.whereType<RemoteRelaySosObservedEvent>().single;
        expect(observed.snapshot.originatorNodeId, 0x01020304);
        expect(observed.snapshot.relayNodeId, 0x0A0B0C0D);
        expect(await sdk.getPreSosStatus(), isNull);
        expect(
          (await localDeviceSosController.getStatus()).state,
          DeviceSosState.inactive,
        );
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains('sos_identity_decision') &&
                event.message.contains('decision=remote_relay') &&
                event.message.contains(
                  'platformEventType=ownDeviceSosLifecycleObserved',
                ),
          ),
          isTrue,
        );

        await subscription.cancel();
        await platformEvents.close();
      },
    );

    test('platform own-device SOS does not route as external relay', () async {
      await sdk.dispose();
      BleDebugRegistry.instance.reset();
      final events = <EixamSdkEvent>[];
      final platformEvents =
          StreamController<ProtectionPlatformEvent>.broadcast();
      final platformAdapter = _FakeProtectionPlatformAdapter(
        platformEvents: platformEvents.stream,
      );
      final localDeviceSosController = DeviceSosController();
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
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: bleEvents.stream,
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: platformAdapter,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
      final subscription = sdk.watchEvents().listen(events.add);
      await sdk.enterProtectionMode();

      platformEvents.add(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.ownDeviceSosLifecycleObserved,
          timestamp: DateTime.utc(2026, 4, 28, 10, 31),
          reason: 'own:sos:34120000008009',
        ),
      );
      platformEvents.add(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.sosEventReceived,
          timestamp: DateTime.utc(2026, 4, 28, 10, 31, 1),
          reason: 'own:sos:34120000008009',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(realtimeClient.publishedSos, isEmpty);
      expect(events.whereType<RemoteRelaySosObservedEvent>(), isEmpty);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) => event.message.contains('native_own_device_sos'),
        ),
        isTrue,
      );

      await subscription.cancel();
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

BleIncomingEvent _remoteRelayEventFromPayload({
  List<int> payload = const <int>[
    0x04,
    0x03,
    0x02,
    0x01,
    0x48,
    0xCD,
    0x1B,
    0x34,
    0x44,
    0x28,
    0x00,
    0x80,
  ],
}) {
  final payloadHex = EixamBleProtocol.hex(payload);
  final classification =
      const BleIncomingPayloadClassifier().classifySosPayload(
    payload: payload,
    payloadHex: payloadHex,
    receivedAt: DateTime.utc(2026, 4, 28, 10, 15),
    source: DeviceSosTransitionSource.device,
    channel: EixamBleChannel.sos,
    connectedBleTagNodeId: 0x0A0B0C0D,
    fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
      kind: BleIncomingPayloadKind.unknownOriginSos,
    ),
  );
  final snapshot = classification.remoteRelaySosSnapshot!;
  return BleIncomingEvent(
    deviceId: 'relay-tag',
    canonicalHardwareId: 'relay-node',
    type: BleIncomingEventType.sosMeshPacket,
    channel: EixamBleChannel.sos,
    payload: snapshot.rawPayload,
    payloadHex: payloadHex,
    source: DeviceSosTransitionSource.device,
    receivedAt: snapshot.receivedAt,
    sosPacket: classification.sosPacket,
    remoteRelaySosSnapshot: snapshot,
    classification: classification,
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
    rawPayload: <int>[
      originatorNodeId & 0xFF,
      (originatorNodeId >> 8) & 0xFF,
      (originatorNodeId >> 16) & 0xFF,
      (originatorNodeId >> 24) & 0xFF,
      0x48,
      0xCD,
      0x1B,
      0x34,
      0x44,
      0x28,
      0x00,
      0x80,
    ],
    payloadHex: EixamBleProtocol.hex(<int>[
      originatorNodeId & 0xFF,
      (originatorNodeId >> 8) & 0xFF,
      (originatorNodeId >> 16) & 0xFF,
      (originatorNodeId >> 24) & 0xFF,
      0x48,
      0xCD,
      0x1B,
      0x34,
      0x44,
      0x28,
      0x00,
      0x80,
    ]),
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
