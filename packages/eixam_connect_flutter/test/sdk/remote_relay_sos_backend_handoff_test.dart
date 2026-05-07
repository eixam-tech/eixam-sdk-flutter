import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_payload_classifier.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/http_sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_history_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/api_sos_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:eixam_connect_flutter/src/sdk/stable_app_device_id_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('remote relay SOS backend handoff', () {
    late StreamController<BleIncomingEvent> bleEvents;
    late _FakeOperationalRealtimeClient realtimeClient;
    late _MissingCurrentIncidentSosRepository sosRepository;
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
      sosRepository = _MissingCurrentIncidentSosRepository();
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
      expect(request.originatorNodeId, 16909060);
      expect(request.relayDeviceId, 0x0A0B0C0D.toString());
      expect(request.relayHardwareId, 'relay-node');
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

    test('uses originatorNodeId, not relayNodeId, as backend identity',
        () async {
      bleEvents.add(
        _remoteRelayEvent(
          snapshot: _snapshot(originatorNodeId: 1234, relayNodeId: 9999),
        ),
      );
      await _eventually(() => realtimeClient.publishedSos.length == 1);

      expect(realtimeClient.publishedSos.single.deviceId, '1234');
      expect(realtimeClient.publishedSos.single.originatorNodeId, 1234);
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
      expect(request.originatorNodeId, 16909060);
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

    test(
        'same originator and event signature with different BLE MAC is not submitted twice',
        () async {
      final snapshot = _snapshot(originatorNodeId: 0x01020304);
      final event = _remoteRelayEvent(
        snapshot: snapshot,
        deviceId: 'relay-tag-a',
        canonicalHardwareId: 'CF:82:59:4B:1A:A8',
      );
      final sameEventViaDifferentBleHardware = _remoteRelayEvent(
        snapshot: snapshot,
        deviceId: 'relay-tag-b',
        canonicalHardwareId: 'AA:BB:CC:DD:EE:FF',
      );

      bleEvents.add(event);
      bleEvents.add(sameEventViaDifferentBleHardware);
      await _eventually(() => realtimeClient.publishedSos.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(realtimeClient.publishedSos.length, 1);
      expect(realtimeClient.publishedSos.single.deviceId, '16909060');
    });

    test('local SOS from connected BLE device uses nodeId as backend deviceId',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-device-123',
          nodeId: 233234039,
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );

      await sdk.triggerSos(
        const SosTriggerPayload(message: 'local SOS'),
      );

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastMessage, 'local SOS');
      expect(sosRepository.lastDeviceId, '233234039');
      expect(sosRepository.lastOriginatorNodeId, 233234039);
      expect(sosRepository.lastDeviceId, isNot('CF:82:59:4B:1A:A8'));
      expect(realtimeClient.publishedSos, isEmpty);
    });

    test('command path unavailable still uses connected nodeId for backend SOS',
        () async {
      await deviceSosController.attach(
        shortCommandAvailable: false,
        longCommandAvailable: false,
        commandWriter: (command) async {
          deviceCommands.add(command);
        },
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'CF:82:59:4B:1A:A8',
          nodeId: 1498094248,
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );

      await sdk.triggerSos(
        const SosTriggerPayload(message: 'local SOS'),
      );

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
      expect(sosRepository.lastDeviceId, isNot('CF:82:59:4B:1A:A8'));
    });

    test('connected nodeId device countdown zero does not create app SOS',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-device-123',
          nodeId: 1498094248,
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );

      await sdk.startPreSos(countdown: const Duration(milliseconds: 35));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(sosRepository.triggerCallCount, 0);
      expect(sosRepository.lastDeviceId, isNull);
    });

    test('connected nodeId device runtime SOS is the only backend publish',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-device-123',
          nodeId: 1498094248,
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );

      await sdk.startPreSos(countdown: const Duration(milliseconds: 80));
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
      expect(sosRepository.lastTriggerSource, 'ble_device_runtime_status');
    });

    test('device runtime SOS sends final backend payload from incidentId',
        () async {
      late http.Request capturedRequest;
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient((request) async {
            capturedRequest = request;
            return http.Response(
              '{"incident":{"id":"api-sos-1","state":"sent","createdAt":"2026-04-28T10:15:00.000Z"}}',
              200,
            );
          }),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'partner-app',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      await dataSource.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        positionSnapshot: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
        deviceId: 'CF:82:59:4B:1A:A8',
        incidentId: 'device-runtime-sos:1498094248:0',
      );

      final payload = jsonDecode(capturedRequest.body) as Map<String, dynamic>;
      expect(payload['deviceId'], '1498094248');
      expect(payload['originatorNodeId'], 1498094248);
    });

    test('device runtime SOS sends final backend payload from dedupe cycle',
        () {
      final envelope = SdkMqttContract.buildOperationalSosEnvelope(
        MqttOperationalSosRequest(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          deviceId: 'CF:82:59:4B:1A:A8',
          cycleKey: 'sos-cycle:sos:1498094248:0',
        ),
      );

      final payload = jsonDecode(envelope.payload) as Map<String, dynamic>;
      expect(payload['deviceId'], '1498094248');
      expect(payload['originatorNodeId'], 1498094248);
    });

    test('runtime SOS nodeId wins over connected device MAC metadata',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'CF:82:59:4B:1A:A8',
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);

      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
      expect(sosRepository.lastDeviceId, isNot('CF:82:59:4B:1A:A8'));
    });

    test(
        'CMD unavailable but device SOS promotes incident nodeId into device status',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'CF:82:59:4B:1A:A8',
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);

      final status = await sdk.getDeviceStatus();
      expect(status.nodeId, 1498094248);
      expect(status.deviceId, 'CF:82:59:4B:1A:A8');
      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) =>
              event.message.contains('DEVICE_NODE_ID_PROMOTED') &&
              event.message.contains('nodeId=1498094248') &&
              event.message.contains('hardwareId=CF:82:59:4B:1A:A8'),
        ),
        isTrue,
      );
    });

    test('telemetry after device SOS promotion uses nodeId backend identity',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'CF:82:59:4B:1A:A8',
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);

      await sdk.publishTelemetry(
        SdkTelemetryPayload(
          timestamp: DateTime.utc(2026, 1, 1, 10, 1),
          latitude: 41.39,
          longitude: 2.18,
          altitude: 50,
          deviceId: 'CF:82:59:4B:1A:A8',
          hardwareId: 'CF:82:59:4B:1A:A8',
        ),
      );

      final payload = telemetryRepository.publishedPayloads.single;
      expect(payload.deviceId, '1498094248');
      expect(payload.nodeId, 1498094248);
      expect(payload.hardwareId, 'CF:82:59:4B:1A:A8');
      expect(payload.identitySource, 'ble_node');
      expect(payload.deviceId, isNot('CF:82:59:4B:1A:A8'));
    });

    test('device-runtime-sos active rejects incoming local sos incident',
        () async {
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);
      sosRepository.currentIncident = SosIncident(
        id: 'sos-1777977538253450',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1, 10),
      );

      final incident = await sdk.getCurrentSosIncident();

      expect(incident?.id, startsWith('device-runtime-sos:1498094248:'));
    });

    test('device-runtime-sos active ignores app-owned backend response',
        () async {
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);

      final appIncident = await sdk.triggerSos(
        const SosTriggerPayload(triggerSource: 'activate_sos'),
      );

      expect(appIncident.id, startsWith('device-runtime-sos:1498094248:'));
      expect(sosRepository.triggerCallCount, 1);
    });

    test('equivalent runtime active snapshots publish one public SOS state',
        () async {
      final states = <SosState>[];
      final subscription = sdk.watchSosState().listen(states.add);
      try {
        trackingRepository.emitPosition(
          TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.utc(2026, 1, 1, 10),
            source: DeliveryMode.mobile,
          ),
        );

        deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacketForNode(1498094248),
          source: DeviceSosTransitionSource.device,
        );
        await _eventually(() => states.contains(SosState.sent));

        deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacketForNode(1498094248),
          source: DeviceSosTransitionSource.device,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(states.where((state) => state == SosState.sent), hasLength(1));
      } finally {
        await subscription.cancel();
      }
    });

    test('equivalent runtime active snapshots do not log canonicalize spam',
        () async {
      BleDebugRegistry.instance.reset();
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final canonicalLogs = BleDebugRegistry.instance.currentState.events
          .where((event) => event.message.contains('[SOS_CANONICALIZE]'))
          .toList();
      expect(canonicalLogs, isEmpty);
    });

    test('device active state clears public countdown immediately', () async {
      final preSosStatuses = <PublicPreSosStatus?>[];
      final subscription = sdk.watchPreSosStatus().listen(preSosStatuses.add);
      try {
        trackingRepository.emitPosition(
          TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.utc(2026, 1, 1, 10),
            source: DeliveryMode.mobile,
          ),
        );

        deviceSosController.handleIncomingSosPacket(
          _deviceOriginPreConfirmPacketForNode(1498094248),
          source: DeviceSosTransitionSource.device,
        );
        await _eventually(
            () => preSosStatuses.whereType<PublicPreSosStatus>().isNotEmpty);

        deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacketForNode(1498094248),
          source: DeviceSosTransitionSource.device,
        );
        await _eventually(
            () => preSosStatuses.isNotEmpty && preSosStatuses.last == null);

        expect(await sdk.getPreSosStatus(), isNull);
        expect(await sdk.getSosState(), SosState.sent);
      } finally {
        await subscription.cancel();
      }
    });

    test('device-runtime-sos can promote to backend id from device request',
        () async {
      sosRepository.currentIncident = SosIncident(
        id: '17330a7e-74bd-4bc5-b7ee-d3f6ca13c327',
        state: SosState.idle,
        createdAt: DateTime.utc(2026, 1, 1, 10),
      );
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);

      final incident = await sdk.getCurrentSosIncident();

      expect(incident?.id, '17330a7e-74bd-4bc5-b7ee-d3f6ca13c327');
      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
    });

    test('backend id remains canonical after later runtime snapshots',
        () async {
      const backendIncidentId = '17330a7e-74bd-4bc5-b7ee-d3f6ca13c327';
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);
      sosRepository.currentIncident = SosIncident(
        id: backendIncidentId,
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1, 10),
      );

      final adopted = await sdk.getCurrentSosIncident();
      sosRepository.currentIncident = SosIncident(
        id: 'device-runtime-sos:1498094248:0',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1, 10),
      );
      final afterRuntimeSnapshot = await sdk.getCurrentSosIncident();

      expect(adopted?.id, backendIncidentId);
      expect(afterRuntimeSnapshot?.id, backendIncidentId);
    });

    test('equivalent backend canonical snapshots log once', () async {
      const backendIncidentId = '17330a7e-74bd-4bc5-b7ee-d3f6ca13c327';
      trackingRepository.emitPosition(
        TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);
      sosRepository.currentIncident = SosIncident(
        id: backendIncidentId,
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1, 10),
      );

      final first = await sdk.getCurrentSosIncident();
      final second = await sdk.getCurrentSosIncident();
      final canonicalLogs = BleDebugRegistry.instance.currentState.events
          .where((event) => event.message.contains('[SOS_CANONICALIZE]'))
          .toList();

      expect(first?.id, backendIncidentId);
      expect(second?.id, backendIncidentId);
      expect(canonicalLogs, hasLength(1));
      expect(
        canonicalLogs.single.message,
        contains('action=adopt_backend_canonical_incident_id'),
      );
    });

    test('SOS_BACKEND_PAYLOAD_FINAL logs runtime node identity', () async {
      BleDebugRegistry.instance.reset();
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient((request) async {
            return http.Response(
              '{"incident":{"id":"api-sos-1","state":"sent","createdAt":"2026-04-28T10:15:00.000Z"}}',
              200,
            );
          }),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'partner-app',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      await dataSource.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        positionSnapshot: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
        deviceId: 'CF:82:59:4B:1A:A8',
        incidentId: 'device-runtime-sos:1498094248:0',
      );

      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) =>
              event.message.contains('SOS_BACKEND_PAYLOAD_FINAL') &&
              event.message.contains('owner=device') &&
              event.message.contains('deviceId=1498094248') &&
              event.message.contains('originatorNodeId=1498094248'),
        ),
        isTrue,
      );
    });

    test('countdown zero skips activate_sos when device runtime SOS exists',
        () async {
      await deviceSosController.triggerSos();
      await deviceSosController.confirmSos();
      sosRepository.currentIncident = SosIncident(
        id: 'device-runtime-sos:1498094248:0',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await sdk.startPreSos(countdown: const Duration(milliseconds: 35));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(sosRepository.triggerCallCount, 0);
    });

    test('countdown zero handles E_SOS_ALREADY_ACTIVE as successful no-op',
        () async {
      sosRepository.triggerError = const SosException(
        'E_SOS_ALREADY_ACTIVE',
        'There is already an SOS flow in progress',
      );

      await sdk.startPreSos(countdown: const Duration(milliseconds: 35));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(sosRepository.triggerCallCount, 0);
      expect(await sdk.getSosState(), isNot(SosState.failed));
    });

    test(
        'connected device without nodeId uses app fallback without MAC deviceId',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-device-123',
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );

      await sdk.startPreSos(countdown: const Duration(milliseconds: 35));
      await _eventually(() => sosRepository.triggerCallCount == 1);

      expect(sosRepository.lastDeviceId, 'app-device-local-sdk-fallback');
      expect(sosRepository.lastDeviceId, isNot('CF:82:59:4B:1A:A8'));
      expect(sosRepository.lastOriginatorNodeId, isNull);
    });

    test('no connected device app-owned countdown still creates app SOS',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'demo-device',
          connected: false,
          paired: false,
          activated: false,
          lifecycleState: DeviceLifecycleState.unpaired,
        ),
      );

      await sdk.startPreSos(countdown: const Duration(milliseconds: 35));
      await _eventually(() => sosRepository.triggerCallCount == 1);

      expect(sosRepository.lastDeviceId, 'app-device-local-sdk-fallback');
      expect(sosRepository.lastOriginatorNodeId, isNull);
    });

    test('remote relay SOS uses ApiSosRepository remote trigger path',
        () async {
      await sdk.dispose();
      final remoteDataSource = _FakeRemoteRelaySosDataSource();
      sdk = EixamConnectSdkImpl(
        sosRepository: ApiSosRepository(remoteDataSource: remoteDataSource),
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
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      bleEvents.add(
        _remoteRelayEvent(
          snapshot: _snapshot(originatorNodeId: 1234, relayNodeId: 9999),
        ),
      );
      await _eventually(() => remoteDataSource.triggerRequests.length == 1);
      await _eventually(
        () => events.whereType<RemoteRelaySosBackendHandoffResultEvent>().any(
              (event) =>
                  event.status == RemoteRelaySosBackendHandoffStatus.submitted,
            ),
      );

      final request = remoteDataSource.triggerRequests.single;
      expect(request.triggerSource, 'remote_lora_relay');
      expect(request.deviceId, '1234');
      expect(request.originatorNodeId, 1234);
      expect(request.relayNodeId, 9999);
      expect(request.relayDeviceId, '9999');
      expect(request.relayHardwareId, 'relay-node');
      expect(request.relaySource, RemoteRelaySosSource.sosNotify.name);
      expect(realtimeClient.publishedSos, isEmpty);
      final result =
          events.whereType<RemoteRelaySosBackendHandoffResultEvent>().single;
      expect(result.incidentId, 'remote-sos-1');
      expect(result.statusCode, 201);
      expect(result.deviceId, '1234');
      expect(await sdk.getSosState(), SosState.idle);
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);

      await subscription.cancel();
    });

    test('remote relay SOS uses MqttOperationalSosRepository backend submit',
        () async {
      await sdk.dispose();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
      );
      sdk = EixamConnectSdkImpl(
        sosRepository: repository,
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

      bleEvents.add(
        _remoteRelayEvent(
          snapshot: _snapshot(originatorNodeId: 0x0A0B0C0D, relayNodeId: 44),
        ),
      );
      await _eventually(() => realtimeClient.publishedSos.length == 1);

      final request = realtimeClient.publishedSos.single;
      expect(request.deviceId, 0x0A0B0C0D.toString());
      expect(request.originatorNodeId, 0x0A0B0C0D);
      expect(request.relayNodeId, 44);
      expect(request.relayDeviceId, '44');
      expect(request.relayHardwareId, 'relay-node');
      expect(request.source, RemoteRelaySosSource.sosNotify.name);
      expect(await sdk.getSosState(), SosState.idle);
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);
      await repository.dispose();
    });

    test('HTTP SOS payload normalizes deviceId from originatorNodeId',
        () async {
      late http.Request capturedRequest;
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient((request) async {
            capturedRequest = request;
            return http.Response(
              '{"incident":{"id":"sos-1","state":"sent","createdAt":"2026-04-28T10:15:00.000Z"}}',
              200,
            );
          }),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'partner-app',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      await dataSource.triggerSos(
        triggerSource: 'remote_lora_relay',
        deviceId: 'CF:82:59:4B:1A:A8',
        originatorNodeId: 233234039,
        relayNodeId: 1498094248,
        relayDeviceId: 'CF:82:59:4B:1A:A8',
        relayHardwareId: 'CF:82:59:4B:1A:A8',
      );

      final payload = jsonDecode(capturedRequest.body) as Map<String, dynamic>;
      expect(payload['deviceId'], '233234039');
      expect(payload['originatorNodeId'], 233234039);
      expect(payload['relayDeviceId'], '1498094248');
      expect(payload['relayHardwareId'], 'CF:82:59:4B:1A:A8');
    });

    test('HTTP SOS payload normalizes device runtime incidentId from MAC',
        () async {
      late http.Request capturedRequest;
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient((request) async {
            capturedRequest = request;
            return http.Response(
              '{"incident":{"id":"sos-1","state":"sent","createdAt":"2026-04-28T10:15:00.000Z"}}',
              200,
            );
          }),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'partner-app',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      await dataSource.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        positionSnapshot: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
        deviceId: 'CF:82:59:4B:1A:A8',
        incidentId: 'device-runtime-sos:1498094248:0',
      );

      final payload = jsonDecode(capturedRequest.body) as Map<String, dynamic>;
      expect(payload['deviceId'], '1498094248');
      expect(payload['originatorNodeId'], 1498094248);
      expect(payload['hardwareId'], 'CF:82:59:4B:1A:A8');
    });

    test('HTTP SOS payload uses appDeviceId when BLE nodeId is pending',
        () async {
      late http.Request capturedRequest;
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient((request) async {
            capturedRequest = request;
            return http.Response(
              '{"incident":{"id":"sos-1","state":"sent","createdAt":"2026-04-28T10:15:00.000Z"}}',
              200,
            );
          }),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'partner-app',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      await dataSource.triggerSos(
        triggerSource: 'activate_sos',
        positionSnapshot: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
        deviceId: 'CF:82:59:4B:1A:A8',
        appDeviceId: 'app-device-123',
        hardwareId: 'CF:82:59:4B:1A:A8',
      );

      final payload = jsonDecode(capturedRequest.body) as Map<String, dynamic>;
      expect(payload['deviceId'], 'app-device-123');
      expect(payload['appDeviceId'], 'app-device-123');
      expect(payload['hardwareId'], 'CF:82:59:4B:1A:A8');
      expect(payload['identitySource'], 'app_device_ble_node_pending');
      expect(payload['deviceId'], isNot('CF:82:59:4B:1A:A8'));
    });

    test('HTTP SOS payload uses appDeviceId when no BLE is connected',
        () async {
      late http.Request capturedRequest;
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient((request) async {
            capturedRequest = request;
            return http.Response(
              '{"incident":{"id":"sos-1","state":"sent","createdAt":"2026-04-28T10:15:00.000Z"}}',
              200,
            );
          }),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'partner-app',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      await dataSource.triggerSos(
        triggerSource: 'activate_sos',
        positionSnapshot: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
        appDeviceId: 'app-device-123',
      );

      final payload = jsonDecode(capturedRequest.body) as Map<String, dynamic>;
      expect(payload['deviceId'], 'app-device-123');
      expect(payload['appDeviceId'], 'app-device-123');
      expect(payload['identitySource'], 'app_device');
    });

    test(
        'MQTT operational SOS payload normalizes deviceId from originatorNodeId',
        () {
      final envelope = SdkMqttContract.buildOperationalSosEnvelope(
        MqttOperationalSosRequest(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          deviceId: 'CF:82:59:4B:1A:A8',
          originatorNodeId: 233234039,
          relayNodeId: 1498094248,
          relayDeviceId: 'CF:82:59:4B:1A:A8',
          relayHardwareId: 'CF:82:59:4B:1A:A8',
        ),
      );

      final payload = jsonDecode(envelope.payload) as Map<String, dynamic>;
      expect(payload['deviceId'], '233234039');
      expect(payload['originatorNodeId'], 233234039);
      expect(payload['relayDeviceId'], '1498094248');
      expect(payload['relayHardwareId'], 'CF:82:59:4B:1A:A8');
    });

    test('MQTT telemetry payload normalizes MAC deviceId from nodeId', () {
      final envelope = SdkMqttContract.buildTelemetryEnvelope(
        session: const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'external-123',
          canonicalExternalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
        payload: SdkTelemetryPayload(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          latitude: 41.3874,
          longitude: 2.1686,
          altitude: 42,
          nodeId: 1498094248,
          deviceId: 'CF:82:59:4B:1A:A8',
          hardwareId: 'CF:82:59:4B:1A:A8',
        ),
      );

      final payload = jsonDecode(envelope.payload) as Map<String, dynamic>;
      expect(payload['deviceId'], '1498094248');
      expect(payload['nodeId'], 1498094248);
      expect(payload['hardwareId'], 'CF:82:59:4B:1A:A8');
      expect(payload['deviceId'], isNot('CF:82:59:4B:1A:A8'));
    });

    test('MQTT telemetry payload uses appDeviceId while BLE nodeId is pending',
        () {
      final envelope = SdkMqttContract.buildTelemetryEnvelope(
        session: const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'external-123',
          canonicalExternalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
        payload: SdkTelemetryPayload(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          latitude: 41.3874,
          longitude: 2.1686,
          altitude: 42,
          deviceId: 'CF:82:59:4B:1A:A8',
          appDeviceId: 'app-device-123',
          hardwareId: 'CF:82:59:4B:1A:A8',
        ),
      );

      final payload = jsonDecode(envelope.payload) as Map<String, dynamic>;
      expect(payload['deviceId'], 'app-device-123');
      expect(payload['appDeviceId'], 'app-device-123');
      expect(payload['hardwareId'], 'CF:82:59:4B:1A:A8');
      expect(payload['identitySource'], 'app_device_ble_node_pending');
      expect(payload['deviceId'], isNot('CF:82:59:4B:1A:A8'));
    });

    test('stable app device id is derived from canonical account identity', () {
      final first = StableAppDeviceIdStore.resolveFromSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'raw@example.com',
          canonicalExternalUserId: 'Account/User 42',
          userHash: 'signed-user-hash',
        ),
      );
      final second = StableAppDeviceIdStore.resolveFromSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'raw@example.com',
          canonicalExternalUserId: 'Account/User 42',
          userHash: 'signed-user-hash',
        ),
      );

      expect(first, isNotNull);
      expect(first!.deviceId, second!.deviceId);
      expect(first.deviceId, startsWith('app-device-account-'));
      expect(first.deviceId, isNot(contains('Account')));
      expect(first.deviceId, isNot(contains('User')));
      expect(first.deviceId, isNot(contains('raw@example.com')));
      expect(first.source, 'account_hash');
      expect(first.persistenceScope, 'account_stable');
      expect(
        first.limitation,
        'not_unique_across_multiple_mobile_devices_for_same_account',
      );
    });

    test('stable app device id hashes email-like account identifiers', () {
      final resolution = StableAppDeviceIdStore.resolveFromSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'person@example.com',
          userHash: 'signed-email-hash',
        ),
      );

      expect(resolution, isNotNull);
      expect(resolution!.deviceId, startsWith('app-device-account-'));
      expect(resolution.deviceId, isNot(contains('person@example.com')));
      expect(resolution.deviceId, isNot(contains('signed-email-hash')));
      expect(resolution.source, 'email_hash');
      expect(resolution.persistenceScope, 'account_stable');
      expect(
        resolution.limitation,
        'not_unique_across_multiple_mobile_devices_for_same_account',
      );
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
      expect(request.originatorNodeId, 233234039);
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

      test('active open refresh without incident preserves canonical id',
          () async {
        final triggered = await sdk.triggerSos(
          const SosTriggerPayload(message: 'local SOS'),
        );
        sosRepository.hideCurrentIncident = true;

        final current = await sdk.getCurrentSosIncident();

        expect(current?.id, triggered.id);
        expect(current?.state, SosState.sent);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message
                    .contains('decision=preserve_active_incident_id') &&
                event.message.contains(triggered.id),
          ),
          isTrue,
        );
      });

      test('active cancel without BLE reaches backend with preserved id',
          () async {
        deviceRepository.emitStatus(
          buildDeviceStatus(
            connected: false,
            lifecycleState: DeviceLifecycleState.unpaired,
            paired: false,
            activated: false,
          ),
        );
        final triggered = await sdk.triggerSos(
          const SosTriggerPayload(message: 'local SOS'),
        );
        sosRepository.hideCurrentIncident = true;

        final cancelled = await sdk.cancelSos();

        expect(cancelled.id, triggered.id);
        expect(cancelled.state, SosState.cancelled);
        expect(sosRepository.cancelCallCount, 1);
        expect(
          sosRepository.terminalOperations,
          <String>['cancel:${triggered.id}'],
        );
      });
    });
  });
}

BleIncomingEvent _remoteRelayEvent({
  RemoteRelaySosSnapshot? snapshot,
  String deviceId = 'relay-tag',
  String canonicalHardwareId = 'relay-node',
}) {
  final resolvedSnapshot = snapshot ?? _snapshot();
  return BleIncomingEvent(
    deviceId: deviceId,
    canonicalHardwareId: canonicalHardwareId,
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

EixamSosPacket _deviceOriginActivePacketForNode(int nodeId) {
  return EixamSosPacket.tryParse(<int>[
    nodeId & 0xFF,
    (nodeId >> 8) & 0xFF,
    (nodeId >> 16) & 0xFF,
    (nodeId >> 24) & 0xFF,
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

EixamSosPacket _deviceOriginPreConfirmPacketForNode(int nodeId) {
  const flagsWord = 0x4000;
  return EixamSosPacket.tryParse(<int>[
    nodeId & 0xFF,
    (nodeId >> 8) & 0xFF,
    (nodeId >> 16) & 0xFF,
    (nodeId >> 24) & 0xFF,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    flagsWord & 0xFF,
    (flagsWord >> 8) & 0xFF,
  ])!;
}

class _MissingCurrentIncidentSosRepository extends FakeSosRepository {
  bool hideCurrentIncident = false;

  @override
  Future<SosIncident?> getCurrentIncident() async {
    if (hideCurrentIncident) {
      return null;
    }
    return super.getCurrentIncident();
  }
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
    String? appDeviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
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

  @override
  Future<SosHistoryPageDto> listSosHistory(
      {String? cursor, int limit = 20}) async {
    return const SosHistoryPageDto(items: [], hasMore: false);
  }
}

class _FakeRemoteRelaySosDataSource implements SosRemoteDataSource {
  final List<_RecordedSosTriggerRequest> triggerRequests =
      <_RecordedSosTriggerRequest>[];
  Object? triggerError;

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    String? appDeviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    final error = triggerError;
    if (error != null) {
      throw error;
    }
    triggerRequests.add(
      _RecordedSosTriggerRequest(
        triggerSource: triggerSource,
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: relayDeviceId,
        relayHardwareId: relayHardwareId,
        relaySource: relaySource,
        incidentId: incidentId,
        cycleKey: cycleKey,
      ),
    );
    return const SosIncidentDto(
      id: 'remote-sos-1',
      state: 'sent',
      createdAt: '2026-04-28T10:15:00.000Z',
      statusCode: 201,
    );
  }

  @override
  Future<SosIncidentDto?> cancelSos({String? deviceId}) async => null;

  @override
  Future<SosIncidentDto?> resolveSos() async => null;

  @override
  Future<SosIncidentDto?> getActiveSos() async => null;

  @override
  Future<SosHistoryPageDto> listSosHistory(
      {String? cursor, int limit = 20}) async {
    return const SosHistoryPageDto(items: [], hasMore: false);
  }
}

class _RecordedSosTriggerRequest {
  const _RecordedSosTriggerRequest({
    required this.triggerSource,
    this.positionSnapshot,
    this.deviceId,
    this.originatorNodeId,
    this.relayNodeId,
    this.relayDeviceId,
    this.relayHardwareId,
    this.relaySource,
    this.incidentId,
    this.cycleKey,
  });

  final String triggerSource;
  final TrackingPosition? positionSnapshot;
  final String? deviceId;
  final int? originatorNodeId;
  final int? relayNodeId;
  final String? relayDeviceId;
  final String? relayHardwareId;
  final String? relaySource;
  final String? incidentId;
  final String? cycleKey;
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);

  final Future<http.Response> Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    final captured = http.Request(request.method, request.url)
      ..body = body
      ..headers.addAll(request.headers);
    final response = await handler(captured);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
      reasonPhrase: response.reasonPhrase,
    );
  }
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
