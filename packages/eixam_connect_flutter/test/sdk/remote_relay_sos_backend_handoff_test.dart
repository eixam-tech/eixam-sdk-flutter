import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_payload_classifier.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_event_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_history_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

const double _decoded12ByteRemoteRelayLatitude = -38.8117790222168;
const double _decoded12ByteRemoteRelayLongitude = 72.09365844726562;
const double _decodedPlatformUnknownRelayLatitude = 41.87267303466797;
const double _decodedPlatformUnknownRelayLongitude = 2.287731170654297;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const protectionMethodChannel = MethodChannel(
    'dev.eixam.connect_flutter/protection_runtime/methods',
  );
  const backgroundTelemetryMethodChannel = MethodChannel(
    'dev.eixam.connect_flutter/background_telemetry/methods',
  );

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
    late MemorySharedPrefsSdkStore localStore;
    late EixamConnectSdkImpl sdk;
    late List<EixamDeviceCommand> deviceCommands;

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(protectionMethodChannel, (call) async {
        switch (call.method) {
          case 'getPlatformSnapshot':
            return <String, dynamic>{
              'backgroundCapabilityReady': false,
              'platformRuntimeConfigured': false,
              'foregroundServiceConfigured': false,
              'serviceRunning': false,
              'runtimeActive': false,
              'runtimeState': 'inactive',
              'coverageLevel': 'none',
            };
          case 'flushProtectionQueues':
            return <String, dynamic>{
              'flushedSosCount': 0,
              'flushedTelemetryCount': 0,
              'success': true,
            };
          case 'peekPendingExternalRelayCancels':
            return <dynamic>[];
          case 'ackPendingExternalRelayCancel':
            return true;
          case 'peekPendingNativeSosCreate':
            return null;
          case 'markPendingNativeSosCreateMqttFlushStarted':
          case 'markPendingNativeSosCreateMqttPublished':
          case 'retainPendingNativeSosCreate':
          case 'ensureProtectionRuntimeActive':
          case 'stopProtectionRuntime':
            return null;
          case 'ackPendingNativeSosCreate':
          case 'dropPendingNativeSosCreate':
            return true;
        }
        return null;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backgroundTelemetryMethodChannel,
              (call) async {
        switch (call.method) {
          case 'startBackgroundTelemetry':
          case 'updateBackgroundTelemetry':
          case 'stopBackgroundTelemetry':
          case 'markQueuedBackgroundTelemetryFlushFailed':
            return null;
          case 'getBackgroundTelemetryDiagnostics':
            return <String, dynamic>{
              'backgroundTelemetryEnabled': false,
              'androidForegroundServiceRunning': false,
              'backgroundPermissionStatus': 'unknown',
              'lastBackgroundTelemetryAt': null,
              'lastBackgroundTelemetryError': null,
              'lastBackgroundLocationMode': null,
              'activeLocationRequest': false,
              'pendingNativeTelemetryCount': 0,
            };
          case 'peekQueuedBackgroundTelemetry':
            return <dynamic>[];
          case 'ackQueuedBackgroundTelemetry':
            return true;
        }
        return null;
      });
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
      localStore = MemorySharedPrefsSdkStore();
      preferredDeviceStore = PreferredBleDeviceStore(localStore: localStore);
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
        localStore: localStore,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(protectionMethodChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(backgroundTelemetryMethodChannel, null);
      await sdk.dispose();
      await bleEvents.close();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deviceRepository.dispose();
      await deathManRepository.dispose();
      await realtimeClient.dispose();
      await sosRepository.dispose();
    });

    Future<void> rebuildSdkWithDeviceSosTiming({
      required Duration countdownDuration,
      required Duration countdownTick,
    }) async {
      await sdk.dispose();
      deviceSosController = DeviceSosController(
        countdownDuration: countdownDuration,
        countdownTick: countdownTick,
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
        localStore: localStore,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
    }

    Future<void> rebuildSdkWithFastDeviceSosTiming() {
      return rebuildSdkWithDeviceSosTiming(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
    }

    TrackingPosition freshPhonePosition({
      double latitude = 41.38,
      double longitude = 2.17,
    }) {
      return TrackingPosition(
        latitude: latitude,
        longitude: longitude,
        timestamp: DateTime.now().toUtc(),
        source: DeliveryMode.mobile,
      );
    }

    Map<String, dynamic> operationalSosMqttPayload(
      MqttOperationalSosRequest request,
    ) {
      final envelope = SdkMqttContract.buildOperationalSosEnvelope(
        sdkUserId: 'partner-app:external-123',
        legacyUserId: 'external-123',
        request: request,
      );
      return jsonDecode(envelope.payload) as Map<String, dynamic>;
    }

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
        // Mirrors the current firmwareGeoMetaOffsetMinus180 decoder for this
        // 12-byte fixture.
        closeTo(_decoded12ByteRemoteRelayLatitude, 0.000001),
      );
      expect(
        request.positionSnapshot!.longitude,
        closeTo(_decoded12ByteRemoteRelayLongitude, 0.000001),
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
      expect(
        snapshot.location!.latitude,
        // Mirrors the current firmwareGeoMetaOffsetMinus180 decoder for this
        // 12-byte fixture.
        closeTo(_decoded12ByteRemoteRelayLatitude, 0.000001),
      );
      expect(
        snapshot.location!.longitude,
        closeTo(_decoded12ByteRemoteRelayLongitude, 0.000001),
      );
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
      final notificationIntents = <EixamNotificationIntent>[];
      final notificationSubscription =
          sdk.watchNotificationIntents().listen(notificationIntents.add);
      bleEvents.add(_remoteRelayEventFromPayload());
      await _eventually(() => notificationIntents.length == 1);

      final notification = notificationIntents.single;
      expect(notification.type, EixamNotificationIntentType.externalSosSent);
      expect(notification.titleKey, 'notification.external_sos.sent.title');
      expect(notification.bodyKey, 'notification.external_sos.sent.body');
      expect(notification.payload['originatorNodeId'], isNotNull);
      expect(notificationsRepository.notifications, isEmpty);
      expect(await sdk.getPreSosStatus(), isNull);
      expect(
        (await deviceSosController.getStatus()).state,
        DeviceSosState.inactive,
      );
      await notificationSubscription.cancel();
    });

    test('backend success sends SOS_ACK_RELAY 0x08 to originator node',
        () async {
      BleDebugRegistry.instance.reset();

      bleEvents.add(
        _remoteRelayEvent(snapshot: _snapshot(originatorNodeId: 0x01020304)),
      );
      await _eventually(() => deviceCommands.length == 1);

      final command = deviceCommands.single;
      expect(command.opcode, 0x08);
      expect(command.bytes, <int>[0x08, 0x04, 0x03, 0x02, 0x01]);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) =>
              event.message.contains(
                'SOS_ORIGIN_DECISION source=remote_lora_relay',
              ) &&
              event.message.contains('actionability=externalOnly') &&
              event.message.contains('localStateMutation=false') &&
              event.message.contains('publicIncident=false') &&
              event.message.contains('backendPublish=true'),
        ),
        isTrue,
      );
    });

    test(
        'successful handoff records dedup after backend success and suppresses in-flight duplicate',
        () async {
      BleDebugRegistry.instance.reset();
      realtimeClient.publishSosCompleter = Completer<void>();
      final event = _remoteRelayEvent();

      bleEvents.add(event);
      await _eventually(() => realtimeClient.publishSosCallCount == 1);

      expect(
        _debugMessagesContaining(
          'REMOTE_RELAY_SOS_HANDOFF_IN_FLIGHT_SET',
        ),
        hasLength(1),
      );
      expect(
        _debugMessagesContaining(
          'REMOTE_RELAY_SOS_HANDOFF_DEDUP_RECORDED_AFTER_SUCCESS',
        ),
        isEmpty,
      );

      bleEvents.add(event);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(realtimeClient.publishSosCallCount, 1);
      expect(realtimeClient.publishedSos, isEmpty);

      realtimeClient.publishSosCompleter!.complete();
      await _eventually(() => realtimeClient.publishedSos.length == 1);
      await _eventually(
        () => _hasDebugMessage(
          'REMOTE_RELAY_SOS_HANDOFF_DEDUP_RECORDED_AFTER_SUCCESS',
        ),
      );

      expect(
        _hasDebugMessage(
          'REMOTE_RELAY_SOS_HANDOFF_IN_FLIGHT_CLEARED',
          allOf(contains('reason=success'), contains('signature=')),
        ),
        isTrue,
      );

      final messages = _debugMessages();
      final setIndex = messages.indexWhere(
        (message) => message.contains(
          'REMOTE_RELAY_SOS_HANDOFF_IN_FLIGHT_SET',
        ),
      );
      final clearIndex = messages.indexWhere(
        (message) => message.contains(
          'REMOTE_RELAY_SOS_HANDOFF_IN_FLIGHT_CLEARED',
        ),
      );
      final dedupIndex = messages.indexWhere(
        (message) => message.contains(
          'REMOTE_RELAY_SOS_HANDOFF_DEDUP_RECORDED_AFTER_SUCCESS',
        ),
      );
      expect(setIndex, greaterThanOrEqualTo(0));
      expect(clearIndex, greaterThan(setIndex));
      expect(dedupIndex, greaterThan(clearIndex));
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

      sosRepository.hideCurrentIncident = true;

      expect(deviceCommands, isEmpty);
      expect(await sdk.getSosState(), SosState.idle);
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);
      expect(await sdk.getCurrentSosIncident(), isNull);
      expect(sosRepository.triggerCallCount, 0);

      await subscription.cancel();
    });

    test(
        'remote relay arriving while local SOS active stays external and does not overwrite local state',
        () async {
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);

      final localIncident =
          await sdk.triggerSos(const SosTriggerPayload(message: 'local SOS'));
      expect(localIncident.state, SosState.sent);
      expect(localIncident.triggerSource, 'button_ui');
      expect(await sdk.getSosState(), SosState.sent);
      expect(sosRepository.triggerCallCount, 1);

      bleEvents.add(_remoteRelayEvent());
      await _eventually(() => realtimeClient.publishedSos.length == 1);
      await _eventually(
        () => events.whereType<RemoteRelaySosObservedEvent>().isNotEmpty,
      );

      final relayRequest = realtimeClient.publishedSos.single;
      expect(relayRequest.triggerSource, 'remote_lora_relay');
      expect(relayRequest.deviceId, '16909060');
      expect(relayRequest.originatorNodeId, 16909060);
      expect(relayRequest.relayDeviceId, 0x0A0B0C0D.toString());
      expect(relayRequest.relayHardwareId, 'relay-node');
      expect(sosRepository.triggerCallCount, 1);
      expect(await sdk.getSosState(), SosState.sent);
      expect((await sdk.getCurrentSosIncident())?.id, localIncident.id);
      expect((await sdk.getCurrentSosIncident())?.triggerSource, 'button_ui');
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);
      expect(deviceCommands.single.bytes, <int>[0x08, 0x04, 0x03, 0x02, 0x01]);

      final observed = events.whereType<RemoteRelaySosObservedEvent>().single;
      expect(observed.snapshot.originatorNodeId, 0x01020304);
      expect(observed.snapshot.relayNodeId, 0x0A0B0C0D);
      final handoff =
          events.whereType<RemoteRelaySosBackendHandoffResultEvent>().single;
      expect(handoff.status, RemoteRelaySosBackendHandoffStatus.submitted);
      expect(handoff.ackRelaySent, isTrue);

      await subscription.cancel();
    });

    test('backend failure allows repeated relay packet to retry', () async {
      BleDebugRegistry.instance.reset();
      realtimeClient.publishSosError = const SosException(
        'E_BACKEND_DOWN',
        'backend unavailable',
      );
      final events = <EixamSdkEvent>[];
      final subscription = sdk.watchEvents().listen(events.add);
      final event = _remoteRelayEvent();

      bleEvents.add(event);
      await _eventually(
        () => events.whereType<RemoteRelaySosBackendHandoffResultEvent>().any(
            (event) =>
                event.status == RemoteRelaySosBackendHandoffStatus.failed),
      );

      expect(realtimeClient.publishedSos, isEmpty);
      expect(realtimeClient.publishSosCallCount, 1);
      expect(
        _debugMessagesContaining(
          'REMOTE_RELAY_SOS_HANDOFF_DEDUP_RECORDED_AFTER_SUCCESS',
        ),
        isEmpty,
      );
      expect(
        _hasDebugMessage(
          'REMOTE_RELAY_SOS_HANDOFF_IN_FLIGHT_CLEARED',
          contains('reason=failure'),
        ),
        isTrue,
      );
      expect(
        _hasDebugMessage(
          'REMOTE_RELAY_SOS_HANDOFF_DEDUP_NOT_RECORDED_ON_FAILURE',
        ),
        isTrue,
      );
      expect(
        _hasDebugMessage(
          'REMOTE_RELAY_SOS_HANDOFF_RETRY_ALLOWED_AFTER_FAILURE',
        ),
        isTrue,
      );
      expect(deviceCommands, isEmpty);
      expect(await sdk.getSosState(), SosState.idle);
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);

      realtimeClient.publishSosError = null;
      bleEvents.add(event);

      await _eventually(() => realtimeClient.publishedSos.length == 1);
      await _eventually(
        () => events.whereType<RemoteRelaySosBackendHandoffResultEvent>().any(
            (event) =>
                event.status == RemoteRelaySosBackendHandoffStatus.submitted),
      );

      expect(realtimeClient.publishSosCallCount, 2);
      final handoffResults =
          events.whereType<RemoteRelaySosBackendHandoffResultEvent>();
      expect(
        handoffResults.where(
          (event) => event.status == RemoteRelaySosBackendHandoffStatus.failed,
        ),
        hasLength(1),
      );
      expect(
        handoffResults.where(
          (event) =>
              event.status == RemoteRelaySosBackendHandoffStatus.submitted,
        ),
        hasLength(1),
      );
      expect(realtimeClient.publishedSos.single.deviceId, '16909060');
      expect(
        _hasDebugMessage(
          'REMOTE_RELAY_SOS_HANDOFF_DEDUP_RECORDED_AFTER_SUCCESS',
        ),
        isTrue,
      );
      expect(await sdk.getSosState(), SosState.idle);
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.inactive);

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
        'successful handoff dedupes same originator and event signature with different BLE MAC',
        () async {
      BleDebugRegistry.instance.reset();
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
      await _eventually(() => realtimeClient.publishedSos.length == 1);
      await _eventually(
        () => _hasDebugMessage(
          'REMOTE_RELAY_SOS_HANDOFF_DEDUP_RECORDED_AFTER_SUCCESS',
        ),
      );

      bleEvents.add(sameEventViaDifferentBleHardware);
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(realtimeClient.publishedSos.length, 1);
      expect(realtimeClient.publishSosCallCount, 1);
      expect(realtimeClient.publishedSos.single.deviceId, '16909060');
      expect(
        _hasDebugMessage(
          'REMOTE_RELAY_SOS_HANDOFF_DUPLICATE_SUPPRESSED_AFTER_SUCCESS',
        ),
        isTrue,
      );
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

    test('connected nodeId device countdown zero publishes backend SOS',
        () async {
      await rebuildSdkWithDeviceSosTiming(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(seconds: 1),
      );
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

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
      expect(await sdk.getPreSosStatus(), isNull);
    });

    test('device-origin countdown zero promotes backend SOS once', () async {
      await rebuildSdkWithDeviceSosTiming(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(seconds: 1),
      );
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
      trackingRepository.emitPosition(freshPhonePosition());
      sosRepository.currentIncident = SosIncident(
        id: 'api-sos-1',
        state: SosState.idle,
        createdAt: DateTime.utc(2026, 1, 1),
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPreConfirmPacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventually(
        () => sosRepository.triggerCallCount == 1,
        timeout: const Duration(seconds: 3),
      );

      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
      expect(await sdk.getPreSosStatus(), isNull);
      expect(
          (await deviceSosController.getStatus()).state, DeviceSosState.active);

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPreConfirmPacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(sosRepository.triggerCallCount, 1);
      expect(await sdk.getPreSosStatus(), isNull);
      expect(
          (await deviceSosController.getStatus()).state, DeviceSosState.active);
    });

    test('device-origin active first packet enters PRE-SOS before backend SOS',
        () async {
      await rebuildSdkWithDeviceSosTiming(
        countdownDuration: const Duration(milliseconds: 80),
        countdownTick: const Duration(milliseconds: 5),
      );
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
      trackingRepository.emitPosition(freshPhonePosition());
      sosRepository.currentIncident = SosIncident(
        id: 'api-sos-1',
        state: SosState.idle,
        createdAt: DateTime.utc(2026, 1, 1),
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );

      await Future<void>.delayed(const Duration(milliseconds: 25));

      final preSos = await sdk.getPreSosStatus();
      expect(preSos, isNotNull);
      expect(preSos!.remainingSeconds, greaterThan(0));
      expect(
        (await deviceSosController.getStatus()).state,
        DeviceSosState.preConfirm,
      );
      expect(sosRepository.triggerCallCount, 0);

      await _eventually(() => sosRepository.triggerCallCount == 1);

      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
      expect(await sdk.getPreSosStatus(), isNull);
      expect(
        (await deviceSosController.getStatus()).state,
        DeviceSosState.active,
      );
    });

    test(
        'first connected-device active packet promotes one authoritative cycle',
        () async {
      await rebuildSdkWithFastDeviceSosTiming();
      trackingRepository.emitPosition(freshPhonePosition());
      final lifecycles = <SosLifecycleSnapshot>[];
      final subscription = sdk.sosLifecycleStream.listen(lifecycles.add);
      addTearDown(subscription.cancel);

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );

      await _eventually(
        () => lifecycles.any(
          (lifecycle) =>
              lifecycle.stage == SosLifecycleStage.active &&
              lifecycle.origin == SosLifecycleOrigin.connectedLocalDevice,
        ),
      );
      await _eventually(() => sosRepository.triggerCallCount == 1);

      final openStages = lifecycles
          .where((lifecycle) => lifecycle.generation > 0)
          .map((lifecycle) => lifecycle.stage)
          .toList();
      expect(openStages, contains(SosLifecycleStage.arming));
      expect(openStages, contains(SosLifecycleStage.activating));
      expect(openStages, contains(SosLifecycleStage.active));
      expect(openStages, isNot(contains(SosLifecycleStage.idle)));
      expect(sosRepository.triggerCallCount, 1);
    });

    test('active retries reuse physical cycle and terminal bypasses relay',
        () async {
      await rebuildSdkWithFastDeviceSosTiming();
      trackingRepository.emitPosition(freshPhonePosition());
      sosRepository.currentIncident = SosIncident(
        id: 'api-sos-identity-cycle',
        state: SosState.idle,
        createdAt: DateTime.utc(2026, 7, 27),
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventuallyAsync(
        () => sdk.getSosLifecycle().then(
              (lifecycle) =>
                  lifecycle.stage == SosLifecycleStage.active &&
                  lifecycle.origin == SosLifecycleOrigin.connectedLocalDevice,
            ),
      );
      await _eventually(
        () => sosRepository.triggerCallCount == 1,
        timeout: const Duration(seconds: 3),
      );
      final firstStatus = await deviceSosController.getStatus();
      final firstCycle = sdk.debugDeriveDeviceSosCycleKey(firstStatus);
      final firstLifecycle = await sdk.getSosLifecycle();

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248, packetId: 3),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final repeatedStatus = await deviceSosController.getStatus();
      final repeatedCycle = sdk.debugDeriveDeviceSosCycleKey(repeatedStatus);
      final repeatedLifecycle = await sdk.getSosLifecycle();

      expect(repeatedCycle, firstCycle);
      expect(repeatedLifecycle.lifecycleId, firstLifecycle.lifecycleId);
      expect(repeatedLifecycle.localIncidentId, firstLifecycle.localIncidentId);
      expect(sosRepository.triggerCallCount, 1);

      BleDebugRegistry.instance.reset();
      deviceSosController.handleIncomingSosEventPacket(
        _deviceCancelEventForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await _eventuallyAsync(
        () => sdk.getSosLifecycle().then(
              (lifecycle) => lifecycle.stage == SosLifecycleStage.cancelled,
            ),
        timeout: const Duration(seconds: 3),
      );

      expect(sosRepository.cancelCallCount, 1);
      await _eventually(
        () => BleDebugRegistry.instance.currentState.events.any(
          (event) =>
              event.message.contains('event=device_terminal') &&
              event.message.contains('classification=connected_local') &&
              event.message.contains('action=accepted'),
        ),
      );
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) => event.message.contains('relay_terminal_residue_detected'),
        ),
        isFalse,
      );
    });

    test('device runtime SOS sends final MQTT payload from incidentId', () {
      final payload = operationalSosMqttPayload(
        MqttOperationalSosRequest(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          triggerSource: 'ble_device_runtime_status',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.utc(2026, 1, 1, 10),
            source: DeliveryMode.mobile,
          ),
          deviceId: 'CF:82:59:4B:1A:A8',
          incidentId: 'device-runtime-sos:1498094248:0',
        ),
      );

      expect(payload['deviceId'], '1498094248');
      expect(payload['originatorNodeId'], 1498094248);
    });

    test(
        'runtime SOS active packet enters PRE-SOS before nodeId backend publish',
        () async {
      await rebuildSdkWithFastDeviceSosTiming();
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'CF:82:59:4B:1A:A8',
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );
      trackingRepository.emitPosition(freshPhonePosition());

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginActivePacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Active packets intentionally enter PRE-SOS first so the user can cancel
      // before backend publish.
      expect((await deviceSosController.getStatus()).state,
          DeviceSosState.preConfirm);
      await _eventually(() => sosRepository.triggerCallCount == 1);

      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);
      expect(sosRepository.lastDeviceId, isNot('CF:82:59:4B:1A:A8'));
    });

    test(
        'CMD unavailable but device SOS promotes incident nodeId after PRE-SOS',
        () async {
      await rebuildSdkWithFastDeviceSosTiming();
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'CF:82:59:4B:1A:A8',
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );
      trackingRepository.emitPosition(freshPhonePosition());

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
      await rebuildSdkWithFastDeviceSosTiming();
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'CF:82:59:4B:1A:A8',
          canonicalHardwareId: 'CF:82:59:4B:1A:A8',
          connected: true,
          paired: true,
          activated: true,
        ),
      );
      trackingRepository.emitPosition(freshPhonePosition());
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
      await rebuildSdkWithFastDeviceSosTiming();
      trackingRepository.emitPosition(freshPhonePosition());
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

    test('equivalent runtime active snapshots publish backend SOS once',
        () async {
      await rebuildSdkWithFastDeviceSosTiming();
      trackingRepository.emitPosition(freshPhonePosition());

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

      expect(sosRepository.triggerCallCount, 1);
    });

    test('equivalent runtime active snapshots do not log canonicalize spam',
        () async {
      await rebuildSdkWithFastDeviceSosTiming();
      BleDebugRegistry.instance.reset();
      trackingRepository.emitPosition(freshPhonePosition());

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
      await rebuildSdkWithFastDeviceSosTiming();
      final preSosStatuses = <PublicPreSosStatus?>[];
      final subscription = sdk.watchPreSosStatus().listen(preSosStatuses.add);
      try {
        trackingRepository.emitPosition(freshPhonePosition());

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
        await _eventually(() => sosRepository.triggerCallCount == 1);
      } finally {
        await subscription.cancel();
      }
    });

    test('duplicate device PRE-SOS preserves first SDK deadline', () async {
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPreConfirmPacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      final first = await sdk.getPreSosStatus();
      expect(first, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPreConfirmPacketForNode(1498094248, packetId: 1),
        source: DeviceSosTransitionSource.device,
      );
      final duplicate = await sdk.getPreSosStatus();

      expect(duplicate, isNotNull);
      expect(duplicate!.cycleKey, first!.cycleKey);
      expect(duplicate.expectedActivationAt, first.expectedActivationAt);
      expect(duplicate.startedAt, first.startedAt);
      expect(duplicate.owner, PublicPreSosOwner.device);
      expect(duplicate.packetId, first.packetId);
    });

    test('app start during device-origin PRE-SOS does not restart countdown',
        () async {
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPreConfirmPacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      final first = await sdk.getPreSosStatus();
      expect(first, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sdk.startPreSos(countdown: const Duration(seconds: 20));
      final afterStart = await sdk.getPreSosStatus();

      expect(afterStart, isNotNull);
      expect(afterStart!.owner, PublicPreSosOwner.device);
      expect(afterStart.cycleKey, first!.cycleKey);
      expect(afterStart.startedAt, first.startedAt);
      expect(afterStart.expectedActivationAt, first.expectedActivationAt);
      expect(deviceCommands, isEmpty);
    });

    test('app-origin device echo enriches cycle without resetting deadline',
        () async {
      await sdk.startPreSos(countdown: const Duration(seconds: 20));
      final started = await sdk.getPreSosStatus();
      expect(started, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 20));
      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPreConfirmPacketForNode(1498094248),
        source: DeviceSosTransitionSource.device,
      );
      final echoed = await sdk.getPreSosStatus();

      expect(echoed, isNotNull);
      expect(echoed!.owner, PublicPreSosOwner.app);
      expect(echoed.expectedActivationAt, started!.expectedActivationAt);
      expect(echoed.startedAt, started.startedAt);
      expect(echoed.originatorNodeId, 1498094248);
      expect(echoed.packetId, 0);
    });

    test('device-runtime-sos can promote to backend id from device request',
        () async {
      await rebuildSdkWithFastDeviceSosTiming();
      sosRepository.currentIncident = SosIncident(
        id: '17330a7e-74bd-4bc5-b7ee-d3f6ca13c327',
        state: SosState.idle,
        createdAt: DateTime.utc(2026, 1, 1, 10),
      );
      trackingRepository.emitPosition(freshPhonePosition());
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
      await rebuildSdkWithFastDeviceSosTiming();
      const backendIncidentId = '17330a7e-74bd-4bc5-b7ee-d3f6ca13c327';
      trackingRepository.emitPosition(freshPhonePosition());
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
      await rebuildSdkWithFastDeviceSosTiming();
      const backendIncidentId = '17330a7e-74bd-4bc5-b7ee-d3f6ca13c327';
      trackingRepository.emitPosition(freshPhonePosition());
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

    test('SOS_BACKEND_PAYLOAD_FINAL logs MQTT runtime node identity', () async {
      BleDebugRegistry.instance.reset();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
      );
      addTearDown(repository.dispose);

      await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        positionSnapshot: freshPhonePosition(),
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

    test('trigger still publishes backend when device runtime SOS exists',
        () async {
      await deviceSosController.triggerSos();
      await deviceSosController.confirmSos();
      sosRepository.currentIncident = SosIncident(
        id: 'device-runtime-sos:1498094248:0',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await sdk.triggerSos(const SosTriggerPayload(message: 'local SOS'));

      expect(sosRepository.triggerCallCount, 1);
    });

    test('backend publish after countdown records device-origin SOS', () async {
      await rebuildSdkWithDeviceSosTiming(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(seconds: 1),
      );
      final states = <SosState>[];
      final subscription = sdk.watchSosState().listen(states.add);
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
      trackingRepository.emitPosition(freshPhonePosition());

      await sdk.startPreSos(countdown: const Duration(milliseconds: 35));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(states, contains(SosState.sending));
      final incident = await sdk.getCurrentSosIncident();
      expect(incident?.state, SosState.sent);
      expect(incident?.deliveryChannel, SosDeliveryChannel.deviceOnly);
      expect(sosRepository.lastDeviceId, '1498094248');
      expect(sosRepository.lastOriginatorNodeId, 1498094248);

      await subscription.cancel();
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

    test('commercial app SOS uses MQTT path even when a nodeId is present',
        () async {
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
      );
      addTearDown(repository.dispose);

      // SOS trigger is MQTT-only; HTTP remains available only for cancel.
      await repository.triggerSos(
        triggerSource: 'commercial_app',
        deviceId: '1498094248',
        hardwareId: 'CF:82:59:4B:1A:A8',
        originatorNodeId: 1498094248,
      );

      expect(realtimeClient.publishedSos, hasLength(1));
      expect(realtimeClient.publishedSos.single.deviceId, '1498094248');
      expect(realtimeClient.publishedSos.single.originatorNodeId, 1498094248);
    });

    test('MQTT SOS payload normalizes deviceId from originatorNodeId', () {
      final payload = operationalSosMqttPayload(
        MqttOperationalSosRequest(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          triggerSource: 'remote_lora_relay',
          deviceId: 'CF:82:59:4B:1A:A8',
          originatorNodeId: 233234039,
          relayNodeId: 1498094248,
          relayDeviceId: 'CF:82:59:4B:1A:A8',
          relayHardwareId: 'CF:82:59:4B:1A:A8',
        ),
      );

      expect(payload['deviceId'], '233234039');
      expect(payload['originatorNodeId'], 233234039);
      expect(payload['relayDeviceId'], '1498094248');
      expect(payload['relayHardwareId'], 'CF:82:59:4B:1A:A8');
    });

    test('MQTT SOS payload normalizes device runtime incidentId from MAC', () {
      final payload = operationalSosMqttPayload(
        MqttOperationalSosRequest(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          triggerSource: 'ble_device_runtime_status',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.utc(2026, 1, 1, 10),
            source: DeliveryMode.mobile,
          ),
          deviceId: 'CF:82:59:4B:1A:A8',
          incidentId: 'device-runtime-sos:1498094248:0',
        ),
      );

      expect(payload['deviceId'], '1498094248');
      expect(payload['originatorNodeId'], 1498094248);
      expect(payload['hardwareId'], 'CF:82:59:4B:1A:A8');
    });

    test('MQTT SOS payload omits deviceId when BLE nodeId is pending', () {
      final payload = operationalSosMqttPayload(
        MqttOperationalSosRequest(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          triggerSource: 'activate_sos',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.utc(2026, 1, 1, 10),
            source: DeliveryMode.mobile,
          ),
          deviceId: 'CF:82:59:4B:1A:A8',
          hardwareId: 'CF:82:59:4B:1A:A8',
        ),
      );

      expect(payload.containsKey('deviceId'), isFalse);
      expect(payload['hardwareId'], 'CF:82:59:4B:1A:A8');
      expect(payload['identitySource'], 'device_hardware_pending');
      expect(payload['deviceId'], isNot('CF:82:59:4B:1A:A8'));
    });

    test('MQTT SOS payload has no device id when no BLE is connected', () {
      final payload = operationalSosMqttPayload(
        MqttOperationalSosRequest(
          timestamp: DateTime.utc(2026, 4, 28, 10, 15),
          triggerSource: 'activate_sos',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.utc(2026, 1, 1, 10),
            source: DeliveryMode.mobile,
          ),
        ),
      );

      expect(payload.containsKey('deviceId'), isFalse);
      expect(payload['identitySource'], 'app');
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

    test('MQTT telemetry payload omits deviceId while BLE nodeId is pending',
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
          hardwareId: 'CF:82:59:4B:1A:A8',
        ),
      );

      final payload = jsonDecode(envelope.payload) as Map<String, dynamic>;
      expect(payload.containsKey('deviceId'), isFalse);
      expect(payload['hardwareId'], 'CF:82:59:4B:1A:A8');
      expect(payload['identitySource'], 'device_hardware');
      expect(payload['deviceId'], isNot('CF:82:59:4B:1A:A8'));
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
        localStore: localStore,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
      final subscription = sdk.watchEvents().listen(events.add);
      final notificationIntents = <EixamNotificationIntent>[];
      final notificationSubscription =
          sdk.watchNotificationIntents().listen(notificationIntents.add);
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
        // Mirrors the current firmwareGeoMetaOffsetMinus180 decoder for this
        // native unknown-origin fixture.
        closeTo(_decodedPlatformUnknownRelayLatitude, 0.000001),
      );
      expect(
        request.positionSnapshot!.longitude,
        closeTo(_decodedPlatformUnknownRelayLongitude, 0.000001),
      );
      expect(request.positionSnapshot!.altitude, 600);
      await _eventually(() => notificationIntents.length == 1);
      final notification = notificationIntents.single;
      expect(notification.type, EixamNotificationIntentType.externalSosSent);
      expect(notification.originatorNodeId, 233234039);
      expect(notificationsRepository.notifications, isEmpty);
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
      await notificationSubscription.cancel();
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
          localStore: localStore,
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
        localStore: localStore,
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

    test('native backend sync failure records failed sync, not sent', () async {
      await sdk.dispose();
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
        localStore: localStore,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );

      platformEvents.add(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.nativeBackendSyncQueued,
          timestamp: DateTime.utc(2026, 4, 28, 10, 32),
          reason: 'queued',
        ),
      );
      await _eventually(
        () => _hasDebugMessage('[NATIVE_PRE_SOS_BACKEND] action=queued'),
      );
      platformEvents.add(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.nativeBackendSyncFailed,
          timestamp: DateTime.utc(2026, 4, 28, 10, 32, 1),
          reason: 'offline',
        ),
      );
      await _eventually(
        () => _hasDebugMessage('[NATIVE_PRE_SOS_BACKEND] action=failed'),
      );

      expect(await sdk.getSosState(), isNot(SosState.sent));

      await platformEvents.close();
    });

    test('native backend sync success adopts incident after it appears',
        () async {
      await sdk.dispose();
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
        localStore: localStore,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
      sosRepository.hideCurrentIncident = true;

      platformEvents.add(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.nativeBackendSyncQueued,
          timestamp: DateTime.utc(2026, 4, 28, 10, 33),
          reason: 'queued',
        ),
      );
      await _eventually(
        () => _hasDebugMessage('[NATIVE_PRE_SOS_BACKEND] action=queued'),
      );
      platformEvents.add(
        ProtectionPlatformEvent(
          type: ProtectionPlatformEventType.nativeBackendSyncSucceeded,
          timestamp: DateTime.utc(2026, 4, 28, 10, 33, 1),
          reason: 'synced:native-sos-1',
        ),
      );
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 80), () {
          sosRepository.currentIncident = SosIncident(
            id: 'native-sos-1',
            state: SosState.sent,
            createdAt: DateTime.utc(2026, 4, 28, 10, 33),
            deliveryChannel: SosDeliveryChannel.backendAndDevice,
          );
          sosRepository.hideCurrentIncident = false;
        }),
      );
      await _eventually(
        () => _hasDebugMessage('[NATIVE_PRE_SOS_BACKEND] action=succeeded'),
      );
      await _eventuallyAsync(
        () async => (await sdk.getCurrentSosIncident())?.id == 'native-sos-1',
        timeout: const Duration(seconds: 2),
      );

      final incident = await sdk.getCurrentSosIncident();
      expect(incident?.state, SosState.sent);

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
          localStore: localStore,
        );
        await sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
      }

      Future<void> establishRemoteRelaySosContext({
        int originatorNodeId = 0x01020304,
        int? relayNodeId = 0x0A0B0C0D,
        bool includeBackendIncidentId = true,
        bool includeIdentityMapping = true,
        String? acceptedTriggerDeviceId,
        String? mappedHardwareId,
      }) async {
        await sdk.dispose();
        final now = DateTime.now().toUtc();
        final relayHardwareId = 'relay-node';
        final normalizedRelayNodeId = relayNodeId?.toUnsigned(32);
        final contextKey = <String>[
          'remote_lora_relay',
          originatorNodeId.toUnsigned(32).toString(),
          normalizedRelayNodeId?.toString() ?? 'none',
          relayHardwareId,
        ].join(':');
        await localStore.saveJson(
          SharedPrefsSdkStore.externalRelaySosContextsKey,
          <String, dynamic>{
            contextKey: <String, dynamic>{
              'originatorNodeId': originatorNodeId.toUnsigned(32),
              if (normalizedRelayNodeId != null)
                'relayNodeId': normalizedRelayNodeId,
              'relayHardwareId': relayHardwareId,
              if (includeBackendIncidentId)
                'backendIncidentId': 'backend-sos-$originatorNodeId',
              'acceptedTriggerDeviceId':
                  acceptedTriggerDeviceId ?? originatorNodeId.toString(),
              'triggerObservedAt':
                  DateTime.utc(2026, 4, 28, 10, 15).toIso8601String(),
              'baselineEventSequence': 0,
              'expiresAt':
                  now.add(const Duration(minutes: 10)).toIso8601String(),
            },
          },
        );
        await localStore.saveJson(
          SharedPrefsSdkStore.deviceIdentityMappingsKey,
          includeIdentityMapping
              ? <String, dynamic>{
                  originatorNodeId.toUnsigned(32).toString(): <String, dynamic>{
                    'hardwareId': mappedHardwareId ??
                        originatorNodeId.toUnsigned(32).toString(),
                    'observedAt': now.toIso8601String(),
                  },
                }
              : <String, dynamic>{},
        );
        await useSdkWithCancelDataSource();
        realtimeClient.publishedSos.clear();
        deviceCommands.clear();
      }

      setUp(() {
        cancelDataSource = _FakeCancelRemoteDataSource();
      });

      test('remote 0xE1/0x02 cancel uses gateway-scope fallback when safe',
          () async {
        await useSdkWithCancelDataSource();
        await establishRemoteRelaySosContext(
          originatorNodeId: 1234,
          relayNodeId: 9999,
          includeBackendIncidentId: false,
          includeIdentityMapping: false,
        );
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

        expect(cancelDataSource.cancelDeviceIds.single, isNull);
        expect(cancelDataSource.cancelDeviceIds.single, isNot('9999'));
        expect(cancelDataSource.sentCancelWithoutDeviceId, isTrue);
        expect(sosRepository.cancelCallCount, 0);
        expect(await sdk.getSosState(), SosState.idle);
        expect((await deviceSosController.getStatus()).state,
            DeviceSosState.inactive);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains(
              'remote_cancel_gateway_scope_fallback',
            ),
          ),
          isTrue,
        );
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains('cancel_result') &&
                event.message.contains('success=true') &&
                event.message.contains('fallback=gateway_scope'),
          ),
          isTrue,
        );
        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.status, RemoteRelaySosBackendHandoffStatus.submitted);
        expect(result.deviceId, isNull);
        expect(result.originatorNodeId, 1234);
        expect(result.relayNodeId, 9999);

        await subscription.cancel();
      });

      test(
          'MQTT relay SOS without backend id cancels by gateway scope fallback',
          () async {
        await useSdkWithCancelDataSource();
        final events = <EixamSdkEvent>[];
        final subscription = sdk.watchEvents().listen(events.add);

        bleEvents.add(
          _remoteRelayEvent(
            snapshot: _snapshot(originatorNodeId: 4321, relayNodeId: 8765),
          ),
        );
        await _eventually(() => realtimeClient.publishedSos.length == 1);
        expect(realtimeClient.publishedSos.single.deviceId, '4321');
        expect(realtimeClient.publishedSos.single.originatorNodeId, 4321);

        bleEvents.add(
          _remoteRelayEvent(
            snapshot:
                _cancelSnapshot(originatorNodeId: 4321, relayNodeId: 8765),
          ),
        );
        await _eventually(() => cancelDataSource.cancelDeviceIds.length == 1);

        expect(cancelDataSource.cancelDeviceIds.single, isNull);
        expect(cancelDataSource.cancelIncidentIds.single, isNull);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains(
                  'remote_cancel_gateway_scope_fallback',
                ) &&
                event.message.contains('originatorNodeId=4321') &&
                event.message.contains('relayNodeId=8765') &&
                event.message.contains('localSosInactive=true'),
          ),
          isTrue,
        );
        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.status, RemoteRelaySosBackendHandoffStatus.submitted);
        expect(result.deviceId, isNull);

        await subscription.cancel();
      });

      test('gateway-scope fallback is blocked while local SOS is active',
          () async {
        await useSdkWithCancelDataSource();
        final events = <EixamSdkEvent>[];
        final subscription = sdk.watchEvents().listen(events.add);

        bleEvents.add(
          _remoteRelayEvent(
            snapshot: _snapshot(originatorNodeId: 13579, relayNodeId: 24680),
          ),
        );
        await _eventually(() => realtimeClient.publishedSos.length == 1);
        await sdk.triggerSos(const SosTriggerPayload(message: 'local SOS'));
        expect(await sdk.getSosState(), SosState.sent);

        bleEvents.add(
          _remoteRelayEvent(
            snapshot:
                _cancelSnapshot(originatorNodeId: 13579, relayNodeId: 24680),
          ),
        );
        await _eventually(
          () => events.whereType<RemoteRelaySosCancelHandoffResultEvent>().any(
                (event) =>
                    event.status == RemoteRelaySosBackendHandoffStatus.skipped,
              ),
        );

        expect(cancelDataSource.cancelDeviceIds, isEmpty);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains(
                  'remote_cancel_gateway_scope_blocked_local_sos_active',
                ) &&
                event.message.contains('originatorNodeId=13579') &&
                event.message.contains('localSosInactive=false'),
          ),
          isTrue,
        );
        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.reason, 'missing_device_id');

        await subscription.cancel();
      });

      test('unknown remote cancel remains pending without numeric fallback',
          () async {
        await useSdkWithCancelDataSource();
        final events = <EixamSdkEvent>[];
        final subscription = sdk.watchEvents().listen(events.add);

        bleEvents.add(
          _remoteRelayEvent(
            snapshot:
                _cancelSnapshot(originatorNodeId: 5555, relayNodeId: 6666),
          ),
        );
        await _eventually(
          () => events.whereType<RemoteRelaySosCancelHandoffResultEvent>().any(
                (event) =>
                    event.status == RemoteRelaySosBackendHandoffStatus.skipped,
              ),
        );

        expect(cancelDataSource.cancelDeviceIds, isEmpty);
        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.reason, 'missing_device_id');
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains(
              'pending_cancel_kept reason=identity_missing',
            ),
          ),
          isTrue,
        );

        await subscription.cancel();
      });

      test('mapped originator hardware id wins over numeric fallback',
          () async {
        await useSdkWithCancelDataSource();
        await establishRemoteRelaySosContext(
          originatorNodeId: 7777,
          relayNodeId: 8888,
          includeBackendIncidentId: false,
          mappedHardwareId: 'originator-hardware-7777',
        );

        bleEvents.add(
          _remoteRelayEvent(
            snapshot:
                _cancelSnapshot(originatorNodeId: 7777, relayNodeId: 8888),
          ),
        );
        await _eventually(() => cancelDataSource.cancelDeviceIds.length == 1);

        expect(cancelDataSource.cancelDeviceIds.single,
            'originator-hardware-7777');
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains('cancel_identity_resolved') &&
                event.message.contains('identitySource=originator_hardware_id'),
          ),
          isTrue,
        );
      });

      test(
          'registered numeric backend hardware id may still cancel by deviceId',
          () async {
        await useSdkWithCancelDataSource();
        await establishRemoteRelaySosContext(
          originatorNodeId: 9090,
          relayNodeId: 8080,
          includeBackendIncidentId: false,
          includeIdentityMapping: false,
        );
        await sdk.ensureBackendDeviceRegistered(
          nodeId: 9090,
          reason: 'test_registered_numeric_remote_cancel',
        );

        bleEvents.add(
          _remoteRelayEvent(
            snapshot:
                _cancelSnapshot(originatorNodeId: 9090, relayNodeId: 8080),
          ),
        );
        await _eventually(() => cancelDataSource.cancelDeviceIds.length == 1);

        expect(cancelDataSource.cancelDeviceIds.single, '9090');
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains('cancel_identity_resolved') &&
                event.message.contains(
                    'identitySource=registered_numeric_trigger_device_id'),
          ),
          isTrue,
        );
      });

      test('backend incident id path wins over numeric originator fallback',
          () async {
        await useSdkWithCancelDataSource();
        await establishRemoteRelaySosContext(
          originatorNodeId: 2468,
          relayNodeId: 1357,
          includeIdentityMapping: false,
        );

        bleEvents.add(
          _remoteRelayEvent(
            snapshot:
                _cancelSnapshot(originatorNodeId: 2468, relayNodeId: 1357),
          ),
        );
        await _eventually(() => cancelDataSource.cancelDeviceIds.length == 1);

        expect(cancelDataSource.cancelDeviceIds.single, isNull);
        expect(cancelDataSource.cancelIncidentIds.single, 'backend-sos-2468');
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains('cancel_identity_resolved') &&
                event.message.contains('identitySource=backend_incident_id'),
          ),
          isTrue,
        );
      });

      test('remote cancel with wrong relay does not cancel remembered incident',
          () async {
        await useSdkWithCancelDataSource();
        await establishRemoteRelaySosContext(
          originatorNodeId: 1111,
          relayNodeId: 2222,
          includeBackendIncidentId: false,
          includeIdentityMapping: false,
        );
        final events = <EixamSdkEvent>[];
        final subscription = sdk.watchEvents().listen(events.add);

        bleEvents.add(
          _remoteRelayEvent(
            snapshot:
                _cancelSnapshot(originatorNodeId: 1111, relayNodeId: 3333),
          ),
        );
        await _eventually(
          () => events.whereType<RemoteRelaySosCancelHandoffResultEvent>().any(
                (event) =>
                    event.status == RemoteRelaySosBackendHandoffStatus.skipped,
              ),
        );

        expect(cancelDataSource.cancelDeviceIds, isEmpty);
        final result =
            events.whereType<RemoteRelaySosCancelHandoffResultEvent>().single;
        expect(result.reason, 'missing_device_id');

        await subscription.cancel();
      });

      test('remote cancel backend 409 emits failed conflict result', () async {
        await useSdkWithCancelDataSource();
        await establishRemoteRelaySosContext();
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
        expect(cancelDataSource.cancelDeviceIds.single, isNull);

        await subscription.cancel();
      });

      test('remote cancel backend 422 emits failed unknown_device result',
          () async {
        await useSdkWithCancelDataSource();
        await establishRemoteRelaySosContext();
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
        expect(result.terminalReason, SosTerminalReason.relayTerminalRejected);

        await subscription.cancel();
      });

      test('remote cancel backend exception emits failed event without crash',
          () async {
        await useSdkWithCancelDataSource();
        await establishRemoteRelaySosContext();
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

      test('promoted PRE-SOS active backend cancel reaches backend', () async {
        await rebuildSdkWithDeviceSosTiming(
          countdownDuration: const Duration(milliseconds: 35),
          countdownTick: const Duration(milliseconds: 5),
        );
        deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-device-123',
            nodeId: 418683257,
            canonicalHardwareId: 'F4:F2:18:F4:99:79',
            connected: true,
            paired: true,
            activated: true,
          ),
        );
        trackingRepository.emitPosition(freshPhonePosition());
        await sdk.startPreSos(countdown: const Duration(milliseconds: 35));
        await _eventually(() => sosRepository.triggerCallCount == 1);
        sosRepository.currentIncident = SosIncident(
          id: 'backend-sos-1',
          state: SosState.sent,
          createdAt: DateTime.utc(2026, 5, 11, 13, 13),
        );
        sosRepository.stateController.add(SosState.sent);
        await Future<void>.delayed(Duration.zero);

        final cancelled = await sdk.cancelSos();

        expect(cancelled.id, 'backend-sos-1');
        expect(cancelled.state, SosState.cancelled);
        expect(sosRepository.cancelCallCount, 1);
        expect(
          sosRepository.terminalOperations,
          <String>['cancel:backend-sos-1'],
        );
      });

      test('app-only SOS does not send fake app identity', () async {
        deviceRepository.emitStatus(
          buildDeviceStatus(
            connected: false,
            lifecycleState: DeviceLifecycleState.unpaired,
            paired: false,
            activated: false,
          ),
        );

        await sdk.triggerSos(const SosTriggerPayload(message: 'local SOS'));

        expect(sosRepository.lastDeviceId, isNull);
        expect(sosRepository.lastOriginatorNodeId, isNull);
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
    kind: RemoteRelaySosKind.cancel,
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

EixamSosPacket _deviceOriginActivePacketForNode(
  int nodeId, {
  int packetId = 0,
}) {
  final flagsWord = 0x8000 | (packetId & 0x0F);
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

EixamSosEventPacket _deviceCancelEventForNode(int nodeId) {
  return EixamSosEventPacket.tryParse(<int>[
    EixamBleProtocol.sosEventUserDeactivatedOpcode,
    0x01,
    nodeId & 0xFF,
    (nodeId >> 8) & 0xFF,
    (nodeId >> 16) & 0xFF,
    (nodeId >> 24) & 0xFF,
  ])!;
}

EixamSosPacket _deviceOriginPreConfirmPacketForNode(
  int nodeId, {
  int packetId = 0,
}) {
  final flagsWord = 0x4000 | (packetId & 0x0F);
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
  final List<String?> cancelIncidentIds = <String?>[];
  Object? cancelError;

  bool get sentCancelWithoutDeviceId =>
      cancelDeviceIds.any((deviceId) => deviceId == null || deviceId.isEmpty);

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    OsSosWidgetActivation? osWidgetActivation,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<SosIncidentDto?> cancelSos({
    String? deviceId,
    String? source,
    String? triggerSource,
    String? relaySource,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayHardwareId,
    String? incidentId,
    String? cycleKey,
  }) async {
    cancelDeviceIds.add(deviceId);
    cancelIncidentIds.add(incidentId);
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
  Future<List<ProtectionPendingExternalRelayCancelEvent>>
      peekPendingExternalRelayCancels() async {
    return const <ProtectionPendingExternalRelayCancelEvent>[];
  }

  @override
  Future<bool> ackPendingExternalRelayCancel(String signature) async => true;

  @override
  Future<ProtectionPendingNativeSosCreate?> peekPendingNativeSosCreate() async {
    return null;
  }

  @override
  Future<void> markPendingNativeSosCreateMqttFlushStarted(
    String signature,
  ) async {}

  @override
  Future<void> markPendingNativeSosCreateMqttPublished(
    String signature,
  ) async {}

  @override
  Future<void> retainPendingNativeSosCreate(
    String signature, {
    required String reason,
  }) async {}

  @override
  Future<bool> ackPendingNativeSosCreate(
    String signature, {
    String? backendIncidentId,
  }) async {
    return true;
  }

  @override
  Future<bool> dropPendingNativeSosCreate(
    String signature, {
    required String reason,
  }) async {
    return true;
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

Future<void> _eventuallyAsync(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}

List<String> _debugMessages() {
  return BleDebugRegistry.instance.currentState.events
      .map((event) => event.message)
      .toList();
}

List<String> _debugMessagesContaining(String token) {
  return _debugMessages().where((message) => message.contains(token)).toList();
}

bool _hasDebugMessage(String token, [Matcher? matcher]) {
  final messages = _debugMessagesContaining(token);
  if (matcher == null) {
    return messages.isNotEmpty;
  }
  return messages
      .any((message) => matcher.matches(message, <Object?, Object?>{}));
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
  Completer<void>? publishSosCompleter;
  int publishSosCallCount = 0;

  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    publishSosCallCount += 1;
    final completer = publishSosCompleter;
    if (completer != null) {
      await completer.future;
    }
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
