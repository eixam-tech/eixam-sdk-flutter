import 'dart:async';

import 'package:async/async.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/http_sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_contacts_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_devices_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_identity_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sdk_contact_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sdk_device_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/mappers/sdk_contact_mapper.dart';
import 'package:eixam_connect_flutter/src/mappers/sdk_device_registry_mapper.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/sdk/mqtt_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';
import '../support/stream_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EixamConnectSdkImpl', () {
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
    late FakeTelemetryRepository telemetryRepository;
    late FakeContactsRepository contactsRepository;
    late FakeDeviceRepository deviceRepository;
    late FakeDeathManRepository deathManRepository;
    late FakePermissionsRepository permissionsRepository;
    late FakeNotificationsRepository notificationsRepository;
    late FakeRealtimeClient realtimeClient;
    late DeviceSosController deviceSosController;
    late PreferredBleDeviceStore preferredDeviceStore;
    late EixamConnectSdkImpl sdk;

    setUp(() {
      sosRepository = FakeSosRepository();
      trackingRepository = FakeTrackingRepository(
        currentPosition: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1, 10),
          source: DeliveryMode.mobile,
        ),
      );
      telemetryRepository = FakeTelemetryRepository();
      contactsRepository = FakeContactsRepository();
      deviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(
          connected: false,
          lifecycleState: DeviceLifecycleState.unpaired,
          paired: false,
          activated: false,
        ),
      );
      deathManRepository = FakeDeathManRepository();
      permissionsRepository = FakePermissionsRepository();
      notificationsRepository = FakeNotificationsRepository();
      realtimeClient = FakeRealtimeClient();
      deviceSosController = DeviceSosController();
      preferredDeviceStore = PreferredBleDeviceStore(
        localStore: MemorySharedPrefsSdkStore(),
      );
      sdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: realtimeClient,
        deviceSosController: deviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
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
    });

    test(
        'triggerSos attaches the current position when location access is granted',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
      );

      await sdk.triggerSos(
        message: 'Need help',
        triggerSource: 'button_ui',
      );

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastMessage, 'Need help');
      expect(sosRepository.lastTriggerSource, 'button_ui');
      expect(sosRepository.lastPositionSnapshot, isNotNull);
      expect(sosRepository.lastPositionSnapshot!.latitude, 41.38);
    });

    test(
        'triggerSos continues without a position snapshot when permission lookup fails',
        () async {
      permissionsRepository.getPermissionStateError = StateError('boom');

      await sdk.triggerSos(message: 'Need help');

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastPositionSnapshot, isNull);
    });

    test(
        'requestNotificationPermission asks both repositories and returns permission state',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        notifications: SdkPermissionStatus.granted,
      );

      final result = await sdk.requestNotificationPermission();

      expect(notificationsRepository.requestPermissionCallCount, 1);
      expect(permissionsRepository.requestNotificationPermissionCallCount, 1);
      expect(result.notifications, SdkPermissionStatus.granted);
    });

    test(
        'guided rescue exposes an unsupported state until a runtime is wired in',
        () async {
      final initial = await sdk.getGuidedRescueState();
      final configured = await sdk.setGuidedRescueSession(
        targetNodeId: 0x1001,
        rescueNodeId: 0x2002,
      );

      expect(initial.hasRuntimeSupport, isFalse);
      expect(configured.targetNodeId, 0x1001);
      expect(configured.rescueNodeId, 0x2002);
      expect(configured.hasSession, isTrue);

      await expectLater(
        sdk.requestGuidedRescueStatus(),
        throwsA(
          isA<RescueException>().having(
            (error) => error.code,
            'code',
            'E_RESCUE_NOT_IMPLEMENTED',
          ),
        ),
      );
    });

    test('tracking facade delegates start and stop to the tracking repository',
        () async {
      await sdk.startTracking();
      await sdk.stopTracking();

      expect(trackingRepository.startCallCount, 1);
      expect(trackingRepository.stopCallCount, 1);
    });

    test('publishTelemetry delegates to the telemetry repository', () async {
      final payload = SdkTelemetryPayload(
        timestamp: DateTime.utc(2026, 3, 31, 10),
        latitude: 41.38,
        longitude: 2.17,
        altitude: 8,
        deviceId: 'device-1',
      );

      await sdk.publishTelemetry(payload);

      expect(telemetryRepository.publishedPayloads, hasLength(1));
      expect(
        telemetryRepository.publishedPayloads.single.deviceId,
        'device-1',
      );
    });

    test('watchPositions replays the last known tracking position', () async {
      final position = await sdk.watchPositions().first;

      expect(position.latitude, 41.38);
      expect(position.longitude, 2.17);
    });

    test('contacts facade delegates add and remove flows', () async {
      final contact = await sdk.addEmergencyContact(
        name: 'Alice',
        phone: '+34123456789',
        email: 'alice@example.com',
      );

      expect(contact.name, 'Alice');
      expect((await sdk.listEmergencyContacts()).single.id, contact.id);

      await sdk.removeEmergencyContact(contact.id);
      expect(await sdk.listEmergencyContacts(), isEmpty);
    });

    test('device facade delegates refresh and exposes the latest status',
        () async {
      final updated = buildDeviceStatus(
        deviceId: 'device-2',
        connected: true,
        paired: true,
        activated: true,
        lifecycleState: DeviceLifecycleState.ready,
      );
      deviceRepository.emitStatus(updated);

      expect((await sdk.getDeviceStatus()).deviceId, 'device-2');
      expect((await sdk.refreshDeviceStatus()).deviceId, 'device-2');
      expect(deviceRepository.refreshCallCount, 1);
    });

    test('watchDeviceStatus replays the latest known device status', () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );

      final status = await sdk.watchDeviceStatus().first;

      expect(status.deviceId, 'demo-device');
      expect(status.lifecycleState, DeviceLifecycleState.unpaired);
    });

    test('watchDeviceSosStatus replays the current controller state', () async {
      final status = await sdk.watchDeviceSosStatus().first;

      expect(status.state, DeviceSosState.inactive);
      expect(status.transitionSource, DeviceSosTransitionSource.unknown);
    });

    test(
        'initialize binds realtime streams and caches the latest facade values',
        () async {
      realtimeClient.stateToEmitOnConnect = RealtimeConnectionState.connected;
      realtimeClient.eventToEmitOnConnect = RealtimeEvent(
        type: 'sos_ack',
        timestamp: DateTime.utc(2026, 1, 1, 10),
        payload: const <String, dynamic>{'incidentId': 'sos-1'},
      );

      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );

      expect(realtimeClient.connectCallCount, 1);
      expect(notificationsRepository.initializeCallCount, 1);
      expect(
        await sdk.getRealtimeConnectionState(),
        RealtimeConnectionState.connected,
      );
      expect((await sdk.getLastRealtimeEvent())?.type, 'sos_ack');
    });

    test('watchRealtime streams expose values pushed after initialization',
        () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );

      final connectionQueue = StreamQueue<RealtimeConnectionState>(
          sdk.watchRealtimeConnectionState());
      final eventFuture = takeNextFromStream(sdk.watchRealtimeEvents());

      expect(await connectionQueue.next, RealtimeConnectionState.disconnected);
      final connectedStateFuture = connectionQueue.next;

      realtimeClient.emitConnectionState(RealtimeConnectionState.connected);
      realtimeClient.emitEvent(
        RealtimeEvent(
          type: 'status_update',
          timestamp: DateTime.utc(2026, 1, 1, 11),
        ),
      );

      expect(await connectedStateFuture, RealtimeConnectionState.connected);
      expect((await eventFuture).type, 'status_update');
      await connectionQueue.cancel();
    });

    test('watchRealtimeConnectionState replays the cached connection state',
        () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );

      expect(
        await sdk.watchRealtimeConnectionState().first,
        RealtimeConnectionState.disconnected,
      );
    });

    test('watchGuidedRescueState replays the current fallback state', () async {
      final state = await sdk.watchGuidedRescueState().first;

      expect(state.hasRuntimeSupport, isFalse);
      expect(state.unavailableReason, isNotEmpty);
    });

    test(
        'guided rescue public APIs delegate to the runtime when support is available',
        () async {
      final localGuidedRescueRuntime = FakeGuidedRescueRuntime();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        guidedRescueRuntime: localGuidedRescueRuntime,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );

        final initialState = await runtimeSdk.getGuidedRescueState();
        expect(initialState.hasRuntimeSupport, isTrue);

        final configured = await runtimeSdk.setGuidedRescueSession(
          targetNodeId: 0x1001,
          rescueNodeId: 0x2002,
        );
        expect(configured.hasSession, isTrue);
        expect(configured.targetNodeId, 0x1001);
        expect(configured.rescueNodeId, 0x2002);

        await runtimeSdk.requestGuidedRescuePosition();
        await runtimeSdk.requestGuidedRescueStatus();
        await runtimeSdk.acknowledgeGuidedRescueSos();
        await runtimeSdk.enableGuidedRescueBuzzer();
        await runtimeSdk.disableGuidedRescueBuzzer();

        expect(localGuidedRescueRuntime.requestPositionCallCount, 1);
        expect(localGuidedRescueRuntime.requestStatusCallCount, 1);
        expect(localGuidedRescueRuntime.acknowledgeSosCallCount, 1);
        expect(localGuidedRescueRuntime.enableBuzzerCallCount, 1);
        expect(localGuidedRescueRuntime.disableBuzzerCallCount, 1);

        await runtimeSdk.clearGuidedRescueSession();
        expect(localGuidedRescueRuntime.clearSessionCallCount, 1);
        expect((await runtimeSdk.getGuidedRescueState()).hasSession, isFalse);
      } finally {
        await runtimeSdk.dispose();
        await localGuidedRescueRuntime.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('watchGuidedRescueState forwards runtime state updates', () async {
      final localGuidedRescueRuntime = FakeGuidedRescueRuntime();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        guidedRescueRuntime: localGuidedRescueRuntime,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );

        final stateQueue =
            StreamQueue<GuidedRescueState>(runtimeSdk.watchGuidedRescueState());

        expect((await stateQueue.next).hasRuntimeSupport, isTrue);
        final updatedStateFuture = stateQueue.next;

        localGuidedRescueRuntime.emitState(
          GuidedRescueState(
            hasRuntimeSupport: true,
            targetNodeId: 0x1001,
            rescueNodeId: 0x2002,
            availableActions: const <GuidedRescueAction>{
              GuidedRescueAction.requestStatus,
              GuidedRescueAction.requestPosition,
            },
            lastStatusSnapshot: GuidedRescueStatusSnapshot(
              targetNodeId: 0x1001,
              rescueNodeId: 0x2002,
              targetState: GuidedRescueTargetState.active,
              retryCount: 2,
              batteryLevel: DeviceBatteryLevel.ok,
              gpsQuality: 3,
              relayPendingAck: true,
              internetAvailable: true,
              receivedAt: DateTime.utc(2026, 1, 1, 12),
            ),
            lastUpdatedAt: DateTime.utc(2026, 1, 1, 12),
          ),
        );

        final updatedState = await updatedStateFuture;
        expect(updatedState.lastStatusSnapshot?.targetState,
            GuidedRescueTargetState.active);
        expect(updatedState.canRun(GuidedRescueAction.requestStatus), isTrue);
        await stateQueue.cancel();
      } finally {
        await runtimeSdk.dispose();
        await localGuidedRescueRuntime.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('triggerSos emits a public SDK event with the incident id', () async {
      final eventFuture = takeNextFromStream(sdk.watchEvents());

      final incident = await sdk.triggerSos(
        message: 'Need help',
        triggerSource: 'button_ui',
      );

      final event = await eventFuture;
      expect(event, isA<SOSTriggeredEvent>());
      expect((event as SOSTriggeredEvent).incidentId, incident.id);
    });

    test('cancelSos emits a public SDK cancellation event', () async {
      final contactIncident = SosIncident(
        id: 'sos-1',
        state: SosState.cancelled,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      sosRepository.currentIncident = contactIncident;
      final eventFuture = takeNextFromStream(sdk.watchEvents());

      final incident = await sdk.cancelSos();

      final event = await eventFuture;
      expect(incident.state, SosState.cancelled);
      expect(event, isA<SOSCancelledEvent>());
      expect((event as SOSCancelledEvent).incidentId, incident.id);
    });

    test(
        'mqtt-backed cancel waits for mqtt confirmation before emitting cancelled event',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final cancelDataSource = _FakeCancelSosRemoteDataSource();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
      );
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: repository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );
      final events = <EixamSdkEvent>[];
      final subscription = localSdk.watchEvents().listen(events.add);

      try {
        final incident = await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        final cancelResult = await localSdk.cancelSos();

        expect(cancelResult.state, SosState.cancelRequested);
        expect(events.whereType<SOSCancelledEvent>(), isEmpty);

        realtimeClient.emitEvent(
          RealtimeEvent(
            type: 'mqtt.message',
            timestamp: DateTime.utc(2026, 3, 31, 9, 2),
            payload: <String, dynamic>{
              'incidentId': incident.id,
              'status': 'cancelled',
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(events.whereType<SOSCancelledEvent>(), hasLength(1));
        expect(
          events.whereType<SOSCancelledEvent>().single.incidentId,
          incident.id,
        );
      } finally {
        await subscription.cancel();
        await localSdk.dispose();
        await localRealtimeClient.dispose();
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test('setSession persists the signed SDK identity without bootstrap',
        () async {
      final localStore = MemorySharedPrefsSdkStore();
      final localSessionStore = SdkSessionStore(localStore: localStore);
      final localSessionContext = SdkSessionContext();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        sessionStore: localSessionStore,
        sessionContext: localSessionContext,
      );

      try {
        const session = EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        );

        await localSdk.setSession(session);
        final persisted = await localSessionStore.load();

        expect(localSessionContext.currentSession, isNotNull);
        expect(persisted?.appId, 'app-demo');
        expect(persisted?.externalUserId, 'external-123');
        expect(persisted?.userHash, 'deadbeef');
        expect(localSessionContext.currentSession?.sdkUserId, isNull);
        expect(persisted?.sdkUserId, isNull);
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('clearSession removes the persisted SDK identity', () async {
      final localStore = MemorySharedPrefsSdkStore();
      final localSessionStore = SdkSessionStore(localStore: localStore);
      final localSessionContext = SdkSessionContext();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        sessionStore: localSessionStore,
        sessionContext: localSessionContext,
      );

      try {
        await localSessionStore.save(
          const EixamSession(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            sdkUserId: 'sdk-user-42',
          ),
        );

        await localSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await localSdk.clearSession();

        expect(await localSessionStore.load(), isNull);
        expect(localSessionContext.currentSession, isNull);
        expect(localRealtimeClient.disconnectCallCount, greaterThanOrEqualTo(1));
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('setSession bootstraps and stores canonical external user id from /v1/sdk/me',
        () async {
      final localStore = MemorySharedPrefsSdkStore();
      final localSessionStore = SdkSessionStore(localStore: localStore);
      final localSessionContext = SdkSessionContext();
      late http.Request capturedRequest;
      final client = _RecordingClient(
        handler: (request) async {
          capturedRequest = request;
          return http.Response(
            '{"user":{"id":"sdk-user-42","external_user_id":"partner/user 42"}}',
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        },
      );
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        sessionStore: localSessionStore,
        sessionContext: localSessionContext,
        identityRemoteDataSource: HttpSdkIdentityRemoteDataSource(
          transport: SdkHttpTransport(
            client: client,
            config: const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
            sessionContext: localSessionContext,
          ),
        ),
      );

      try {
        await localSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
          ),
        );

        final persisted = await localSessionStore.load();
        expect(capturedRequest.url.toString(), 'https://example.test/v1/sdk/me');
        expect(capturedRequest.headers['X-User-ID'], 'external-123');
        expect(localSessionContext.currentSession?.canonicalExternalUserId,
            'partner/user 42');
        expect(persisted?.canonicalExternalUserId, 'partner/user 42');
        expect(persisted?.sdkUserId, 'sdk-user-42');
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'sdk identity enrichment composes /v1/sdk/me headers correctly without requiring sdkUserId ahead of time',
        () async {
      late http.Request capturedRequest;
      final client = _RecordingClient(
        handler: (request) async {
          capturedRequest = request;
          return http.Response(
            '{"user":{"id":"sdk-user-42","external_user_id":"canonical-user-42"}}',
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        },
      );
      final dataSource = HttpSdkIdentityRemoteDataSource(
        transport: SdkHttpTransport(
          client: client,
          config: const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          sessionContext: SdkSessionContext(),
        ),
      );
      const session = EixamSession(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );

      final bootstrapped = await dataSource.bootstrapSession(session);

      expect(capturedRequest.method, 'GET');
      expect(capturedRequest.url.toString(), 'https://example.test/v1/sdk/me');
      expect(capturedRequest.headers['X-App-ID'], 'app-demo');
      expect(capturedRequest.headers['X-User-ID'], 'external-123');
      expect(capturedRequest.headers['Authorization'], 'Bearer deadbeef');
      expect(bootstrapped.sdkUserId, 'sdk-user-42');
      expect(bootstrapped.canonicalExternalUserId, 'canonical-user-42');
    });

    test('mqtt operational publish requires a signed session', () async {
      final sessionContext = SdkSessionContext();
      final mqttClient = MqttRealtimeClient(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/mqtt',
        ),
        sessionContext: sessionContext,
        transportFactory: (_) => _FakeSdkMqttTransport(),
      );

      try {
        await expectLater(
          mqttClient.publishOperationalSos(
            MqttOperationalSosRequest(
              timestamp: DateTime.utc(2026, 3, 30, 12),
              positionSnapshot: TrackingPosition(
                latitude: 41.38,
                longitude: 2.17,
                altitude: 8,
                timestamp: DateTime.utc(2026, 3, 30, 12),
              ),
            ),
          ),
          throwsA(
            isA<AuthException>().having(
              (error) => error.code,
              'code',
              'E_SDK_SESSION_REQUIRED',
            ),
          ),
        );
      } finally {
        await mqttClient.dispose();
      }
    });

    test('mqtt realtime composes connect properties and canonical encoded event topics',
        () async {
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          sdkUserId: 'sdk-user-42',
          canonicalExternalUserId: 'partner/user 42',
        );
      late SdkMqttConnectRequest capturedRequest;
      late _FakeSdkMqttTransport transport;
      final mqttClient = MqttRealtimeClient(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/mqtt',
        ),
        sessionContext: sessionContext,
        transportFactory: (request) {
          capturedRequest = request;
          transport = _FakeSdkMqttTransport();
          return transport;
        },
      );

      try {
        await mqttClient.connect();

        expect(capturedRequest.userProperties, <String, String>{
          'x_app_id': 'app-demo',
          'x_user_id': 'external-123',
          'authorization': 'Bearer deadbeef',
        });
        expect(
          transport.subscriptions,
          <String>['sos/events/partner%2Fuser%2042'],
        );
      } finally {
        await mqttClient.dispose();
      }
    });

    test('mqtt realtime prevents overlapping connect attempts', () async {
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          canonicalExternalUserId: 'external-123',
        );
      final completer = Completer<void>();
      final transport = _FakeSdkMqttTransport(connectCompleter: completer);
      final mqttClient = MqttRealtimeClient(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/mqtt',
        ),
        sessionContext: sessionContext,
        transportFactory: (_) => transport,
      );

      try {
        final first = mqttClient.connect();
        final second = mqttClient.connect();
        await Future<void>.delayed(Duration.zero);
        expect(transport.connectCallCount, 1);

        completer.complete();
        await Future.wait(<Future<void>>[first, second]);

        expect(transport.connectCallCount, 1);
      } finally {
        await mqttClient.dispose();
      }
    });

    test('mqtt reconnect is stopped by manual disconnect', () async {
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          canonicalExternalUserId: 'external-123',
        );
      final firstTransport = _FakeSdkMqttTransport();
      final transports = <_FakeSdkMqttTransport>[firstTransport];
      final mqttClient = MqttRealtimeClient(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/mqtt',
        ),
        sessionContext: sessionContext,
        reconnectDelay: const Duration(milliseconds: 20),
        transportFactory: (_) => transports.removeAt(0),
      );

      try {
        await mqttClient.connect();
        firstTransport.emitDisconnect(solicited: false);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await mqttClient.disconnect();
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(firstTransport.connectCallCount, 1);
        expect(firstTransport.disconnectCallCount, greaterThanOrEqualTo(1));
        expect(transports, isEmpty);
      } finally {
        await mqttClient.dispose();
      }
    });

    test('mqtt SOS repository publishes alerts over mqtt topic', () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
      );

      try {
        final incident = await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        expect(incident.state, SosState.sent);
        expect(realtimeClient.publishedRequests, hasLength(1));
        final envelope = SdkMqttContract.buildOperationalSosEnvelope(
          realtimeClient.publishedRequests.single,
        );
        expect(envelope.topic, SdkMqttTopics.sosAlerts);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test('http cancel path posts to /v1/sdk/sos/cancel without a request body',
        () async {
      late http.Request capturedRequest;
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient(
            handler: (request) async {
              capturedRequest = request;
              return http.Response('{"incident":null}', 200);
            },
          ),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'app-demo',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      await dataSource.cancelSos();

      expect(capturedRequest.method, 'POST');
      expect(
        capturedRequest.url.toString(),
        'https://api.example.test/v1/sdk/sos/cancel',
      );
      expect(capturedRequest.body, isEmpty);
      expect(capturedRequest.headers['X-App-ID'], 'app-demo');
      expect(capturedRequest.headers['X-User-ID'], 'external-123');
      expect(capturedRequest.headers['Authorization'], 'Bearer deadbeef');
    });

    test('mqtt incoming SOS events map into lifecycle states', () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
      );

      try {
        final incident = await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        realtimeClient.emitEvent(
          RealtimeEvent(
            type: 'mqtt.message',
            timestamp: DateTime.utc(2026, 3, 31, 9),
            payload: <String, dynamic>{
              'incidentId': incident.id,
              'status': 'acknowledged',
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(await repository.getSosState(), SosState.acknowledged);

        realtimeClient.emitEvent(
          RealtimeEvent(
            type: 'mqtt.message',
            timestamp: DateTime.utc(2026, 3, 31, 9, 1),
            payload: <String, dynamic>{
              'incidentId': incident.id,
              'status': 'resolved',
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(await repository.getSosState(), SosState.resolved);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test('clearSession tears down mqtt SOS runtime subscription', () async {
      final sessionContext = SdkSessionContext();
      late _FakeSdkMqttTransport transport;
      final mqttClient = MqttRealtimeClient(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/mqtt',
        ),
        sessionContext: sessionContext,
        transportFactory: (_) {
          transport = _FakeSdkMqttTransport();
          return transport;
        },
      );
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: mqttClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        sessionContext: sessionContext,
      );

      try {
        await localSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'external-123',
          ),
        );

        expect(transport.subscriptions, <String>['sos/events/external-123']);

        await localSdk.clearSession();

        expect(sessionContext.currentSession, isNull);
        expect(transport.disconnectCallCount, greaterThanOrEqualTo(1));
      } finally {
        await localSdk.dispose();
        await mqttClient.dispose();
      }
    });

    test('cancel uses http only and does not publish mqtt commands', () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final cancelDataSource = _FakeCancelSosRemoteDataSource();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
      );

      try {
        final incident = await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        final cancelled = await repository.cancelSos();

        expect(cancelDataSource.cancelCallCount, 1);
        expect(realtimeClient.publishedRequests, hasLength(1));
        expect(cancelled.state, SosState.cancelRequested);

        realtimeClient.emitEvent(
          RealtimeEvent(
            type: 'mqtt.message',
            timestamp: DateTime.utc(2026, 3, 31, 9, 2),
            payload: <String, dynamic>{
              'incidentId': incident.id,
              'status': 'cancelled',
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(await repository.getSosState(), SosState.cancelled);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test('telemetry topic builder uses the canonical encoded external user id',
        () {
      const session = EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
        canonicalExternalUserId: 'partner/user 42',
      );

      expect(
        SdkMqttTopics.telemetryDataFor(session),
        'tel/partner%2Fuser%2042/data',
      );
    });

    test('telemetry payload serialization matches the mqtt contract', () {
      final envelope = SdkMqttContract.buildTelemetryEnvelope(
        session: const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          canonicalExternalUserId: 'partner/user 42',
        ),
        payload: SdkTelemetryPayload(
          timestamp: DateTime.utc(2026, 3, 31, 10, 15),
          latitude: 41.38,
          longitude: 2.17,
          altitude: 8,
          userId: 'sdk-user-42',
          deviceId: 'device-1',
          deviceBattery: 77.5,
          deviceCoverage: 4,
          mobileBattery: 61.0,
          mobileCoverage: 3,
        ),
      );

      expect(envelope.topic, 'tel/partner%2Fuser%2042/data');
      expect(envelope.payload, '{"timestamp":"2026-03-31T10:15:00.000Z","latitude":41.38,"longitude":2.17,"altitude":8.0,"userId":"sdk-user-42","deviceId":"device-1","deviceBattery":77.5,"deviceCoverage":4,"mobileBattery":61.0,"mobileCoverage":3}');
    });

    test('telemetry repository validates required coordinates before publish',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final repository = MqttTelemetryRepository(
        realtimeClient: realtimeClient,
      );

      expect(
        () => repository.publishTelemetry(
          SdkTelemetryPayload(
            timestamp: DateTime.utc(2026, 3, 31, 10, 15),
            latitude: double.nan,
            longitude: 2.17,
            altitude: 8,
          ),
        ),
        throwsA(
          isA<TrackingException>().having(
            (error) => error.code,
            'code',
            'E_TELEMETRY_LATITUDE_INVALID',
          ),
        ),
      );
    });

    test('mqtt telemetry publish uses qos1 retain false through transport',
        () async {
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          sdkUserId: 'sdk-user-42',
          canonicalExternalUserId: 'partner/user 42',
        );
      late _FakeSdkMqttTransport transport;
      final mqttClient = MqttRealtimeClient(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/mqtt',
        ),
        sessionContext: sessionContext,
        transportFactory: (_) {
          transport = _FakeSdkMqttTransport();
          return transport;
        },
      );
      final repository = MqttTelemetryRepository(
        realtimeClient: mqttClient,
      );

      try {
        await repository.publishTelemetry(
          SdkTelemetryPayload(
            timestamp: DateTime.utc(2026, 3, 31, 10, 15),
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            deviceId: 'device-1',
          ),
        );

        expect(transport.publications, hasLength(1));
        final publish = transport.publications.single;
        expect(publish.topic, 'tel/partner%2Fuser%2042/data');
        expect(publish.qos, SdkMqttQos.atLeastOnce);
        expect(publish.retain, isFalse);
        expect(publish.payload, contains('"userId":"partner/user 42"'));
      } finally {
        await mqttClient.dispose();
      }
    });

    test('device HTTP datasource matches OpenAPI request and response mapping',
        () async {
      final requests = <http.Request>[];
      final dataSource = HttpSdkDevicesRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient(
            handler: (request) async {
              requests.add(request);
              if (request.method == 'POST') {
                return http.Response(
                  '{"device":{"id":"device-1","hardware_id":"hw-1","firmware_version":"1.2.3","hardware_model":"EIXAM R1","paired_at":"2026-03-31T09:00:00.000Z","created_at":"2026-03-31T09:00:00.000Z","updated_at":"2026-03-31T09:05:00.000Z"}}',
                  200,
                );
              }
              if (request.method == 'GET') {
                return http.Response(
                  '{"devices":[{"id":"device-1","hardware_id":"hw-1","firmware_version":"1.2.3","hardware_model":"EIXAM R1","paired_at":"2026-03-31T09:00:00.000Z"}]}',
                  200,
                );
              }
              if (request.method == 'DELETE') {
                return http.Response('', 204);
              }
              throw StateError('Unexpected request ${request.method}');
            },
          ),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'app-demo',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      final upserted = await dataSource.upsertDevice(
        hardwareId: 'hw-1',
        firmwareVersion: '1.2.3',
        hardwareModel: 'EIXAM R1',
        pairedAt: DateTime.utc(2026, 3, 31, 9),
      );
      final listed = await dataSource.listDevices();
      await dataSource.deleteDevice('device-1');

      expect(requests[0].url.toString(), 'https://api.example.test/v1/sdk/devices');
      expect(
        requests[0].body,
        '{"hardware_id":"hw-1","firmware_version":"1.2.3","hardware_model":"EIXAM R1","paired_at":"2026-03-31T09:00:00.000Z"}',
      );
      expect(requests[1].url.toString(), 'https://api.example.test/v1/sdk/devices');
      expect(requests[2].url.toString(),
          'https://api.example.test/v1/sdk/devices/device-1');
      expect(upserted.hardwareId, 'hw-1');
      expect(upserted.hardwareModel, 'EIXAM R1');
      expect(listed.single.firmwareVersion, '1.2.3');
    });

    test('device registry mapper keeps backend records separate from runtime status',
        () {
      const dto = SdkDeviceDto(
        id: 'device-1',
        hardwareId: 'hw-1',
        firmwareVersion: '1.2.3',
        hardwareModel: 'EIXAM R1',
        pairedAt: '2026-03-31T09:00:00.000Z',
        createdAt: '2026-03-31T09:00:00.000Z',
        updatedAt: '2026-03-31T09:05:00.000Z',
      );

      final mapped = const SdkDeviceRegistryMapper().toDomain(dto);

      expect(mapped, isA<BackendRegisteredDevice>());
      expect(mapped, isNot(isA<DeviceStatus>()));
      expect(mapped.hardwareId, 'hw-1');
      expect(mapped.updatedAt, DateTime.utc(2026, 3, 31, 9, 5));
    });

    test('contacts HTTP datasource matches OpenAPI request and response mapping',
        () async {
      final requests = <http.Request>[];
      final dataSource = HttpSdkContactsRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient(
            handler: (request) async {
              requests.add(request);
              if (request.method == 'GET') {
                return http.Response(
                  '{"contacts":[{"id":"contact-1","name":"Alice","phone":"+34123456789","email":"alice@example.com","priority":1,"createdAt":"2026-03-31T09:00:00.000Z","updatedAt":"2026-03-31T09:05:00.000Z"}]}',
                  200,
                );
              }
              if (request.method == 'POST') {
                return http.Response(
                  '{"contact":{"id":"contact-1","name":"Alice","phone":"+34123456789","email":"alice@example.com","priority":1,"createdAt":"2026-03-31T09:00:00.000Z","updatedAt":"2026-03-31T09:05:00.000Z"}}',
                  201,
                );
              }
              if (request.method == 'PUT') {
                return http.Response(
                  '{"contact":{"id":"contact-1","name":"Alice Updated","phone":"+34123456789","email":"alice@example.com","priority":2,"createdAt":"2026-03-31T09:00:00.000Z","updatedAt":"2026-03-31T09:10:00.000Z"}}',
                  200,
                );
              }
              if (request.method == 'DELETE') {
                return http.Response('', 204);
              }
              throw StateError('Unexpected request ${request.method}');
            },
          ),
          config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
          sessionContext: SdkSessionContext()
            ..currentSession = const EixamSession.signed(
              appId: 'app-demo',
              externalUserId: 'external-123',
              userHash: 'deadbeef',
            ),
        ),
      );

      final listed = await dataSource.listContacts();
      final created = await dataSource.createContact(
        name: 'Alice',
        phone: '+34123456789',
        email: 'alice@example.com',
        priority: 1,
      );
      final updated = await dataSource.replaceContact(
        id: 'contact-1',
        name: 'Alice Updated',
        phone: '+34123456789',
        email: 'alice@example.com',
        priority: 2,
      );
      await dataSource.deleteContact('contact-1');

      expect(requests[0].url.toString(), 'https://api.example.test/v1/sdk/contacts');
      expect(requests[1].body,
          '{"name":"Alice","phone":"+34123456789","email":"alice@example.com","priority":1}');
      expect(requests[2].url.toString(),
          'https://api.example.test/v1/sdk/contacts/contact-1');
      expect(requests[2].body,
          '{"name":"Alice Updated","phone":"+34123456789","email":"alice@example.com","priority":2}');
      expect(requests[3].url.toString(),
          'https://api.example.test/v1/sdk/contacts/contact-1');
      expect(listed.single.name, 'Alice');
      expect(created.email, 'alice@example.com');
      expect(updated.priority, 2);
    });

    test('contact mapper matches backend schema exactly', () {
      const dto = SdkContactDto(
        id: 'contact-1',
        name: 'Alice',
        phone: '+34123456789',
        email: 'alice@example.com',
        priority: 1,
        createdAt: '2026-03-31T09:00:00.000Z',
        updatedAt: '2026-03-31T09:05:00.000Z',
      );

      final mapped = const SdkContactMapper().toDomain(dto);

      expect(mapped.id, 'contact-1');
      expect(mapped.name, 'Alice');
      expect(mapped.phone, '+34123456789');
      expect(mapped.email, 'alice@example.com');
      expect(mapped.priority, 1);
      expect(mapped.createdAt, DateTime.utc(2026, 3, 31, 9));
      expect(mapped.updatedAt, DateTime.utc(2026, 3, 31, 9, 5));
    });

    test('mqtt telemetry publish requires a signed session', () async {
      final sessionContext = SdkSessionContext();
      final mqttClient = MqttRealtimeClient(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/mqtt',
        ),
        sessionContext: sessionContext,
        transportFactory: (_) => _FakeSdkMqttTransport(),
      );

      try {
        await expectLater(
          mqttClient.publishTelemetry(
            SdkTelemetryPayload(
              timestamp: DateTime.utc(2026, 3, 31, 10, 15),
              latitude: 41.38,
              longitude: 2.17,
              altitude: 8,
            ),
          ),
          throwsA(
            isA<AuthException>().having(
              (error) => error.code,
              'code',
              'E_SDK_SESSION_REQUIRED',
            ),
          ),
        );
      } finally {
        await mqttClient.dispose();
      }
    });

    test(
        'scheduleDeathMan transitions the repository to monitoring and emits an event',
        () async {
      final eventFuture = takeNextFromStream(sdk.watchEvents());

      final plan = await sdk.scheduleDeathMan(
        expectedReturnAt: DateTime.now().add(const Duration(hours: 2)),
      );

      final event = await eventFuture;
      expect(plan.status, DeathManStatus.monitoring);
      expect(deathManRepository.updateCallCount, 1);
      expect(event, isA<DeathManScheduledEvent>());
      expect((event as DeathManScheduledEvent).planId, plan.id);
    });

    test('confirmDeathManCheckIn emits a status-changed event', () async {
      deathManRepository.activePlan = DeathManPlan(
        id: 'deathman-1',
        expectedReturnAt: DateTime.utc(2026, 1, 2, 12),
        gracePeriod: const Duration(minutes: 30),
        checkInWindow: const Duration(minutes: 10),
        autoTriggerSos: true,
        status: DeathManStatus.monitoring,
      );
      final eventFuture = takeNextFromStream(sdk.watchEvents());

      await sdk.confirmDeathManCheckIn('deathman-1');

      final event = await eventFuture;
      expect(event, isA<DeathManStatusChangedEvent>());
      expect((event as DeathManStatusChangedEvent).status,
          DeathManStatus.confirmedSafe.name);
    });

    test('initialize resumes monitoring for a restored active Death Man plan',
        () async {
      deathManRepository.activePlan = DeathManPlan(
        id: 'deathman-restore',
        expectedReturnAt: DateTime.now().subtract(const Duration(minutes: 2)),
        gracePeriod: const Duration(seconds: 1),
        checkInWindow: const Duration(minutes: 5),
        autoTriggerSos: false,
        status: DeathManStatus.monitoring,
      );

      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        deathManRepository.activePlan?.status,
        DeathManStatus.awaitingConfirmation,
      );
      expect(deathManRepository.updateCallCount, 2);
      expect(notificationsRepository.notifications, hasLength(2));
    });

    test(
        'device-originated SOS notifies preConfirm first and active only after timeout',
        () async {
      final localNotificationsRepository = FakeNotificationsRepository();
      final localDeviceSosController = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: localNotificationsRepository,
        realtimeClient: realtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        await localSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );

        localDeviceSosController.handleIncomingSosPacket(
          _deviceOriginPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(localNotificationsRepository.notifications, hasLength(1));
        expect(
          localNotificationsRepository.notifications.first.title,
          'Preventive SOS sent',
        );
        expect(
          localNotificationsRepository.notifications.first.body,
          'Pending confirmation. You can cancel it or confirm it now.',
        );
        expect(
          localNotificationsRepository.notifications.first.actions
              .map((action) => action.title),
          containsAll(<String>['Cancel SOS', 'Confirm SOS']),
        );

        await Future<void>.delayed(const Duration(milliseconds: 70));

        expect(localNotificationsRepository.notifications, hasLength(2));
        expect(
          localNotificationsRepository.notifications.last.title,
          'SOS activated',
        );
        expect(
          localNotificationsRepository.notifications.last.body,
          'Emergency protocol is now active. You can cancel or resolve the SOS.',
        );
        expect(
          localNotificationsRepository.notifications.last.actions
              .map((action) => action.title),
          containsAll(<String>['Cancel SOS', 'Resolve SOS']),
        );
      } finally {
        await localSdk.dispose();
      }
    });
  });
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient({required this.handler});

  final Future<http.Response> Function(http.Request request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final replayable = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    if (request is http.Request) {
      replayable.bodyBytes = request.bodyBytes;
    }
    final response = await handler(replayable);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}

class _FakeSdkMqttTransport implements SdkMqttTransport {
  _FakeSdkMqttTransport({this.connectCompleter});

  final Completer<void>? connectCompleter;
  final StreamController<SdkMqttIncomingMessage> _messageController =
      StreamController<SdkMqttIncomingMessage>.broadcast();
  final StreamController<SdkMqttDisconnectEvent> _disconnectController =
      StreamController<SdkMqttDisconnectEvent>.broadcast();
  final List<String> subscriptions = <String>[];
  final List<_PublishedMqttMessage> publications = <_PublishedMqttMessage>[];

  int connectCallCount = 0;
  int disconnectCallCount = 0;
  bool _disposed = false;

  @override
  Future<void> connect() async {
    connectCallCount++;
    await connectCompleter?.future;
  }

  @override
  Future<void> disconnect() async {
    disconnectCallCount++;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _messageController.close();
    await _disconnectController.close();
  }

  void emitDisconnect({required bool solicited}) {
    _disconnectController.add(SdkMqttDisconnectEvent(solicited: solicited));
  }

  @override
  Future<void> publish({
    required String topic,
    required String payload,
    SdkMqttQos qos = SdkMqttQos.atLeastOnce,
    bool retain = false,
  }) async {
    publications.add(
      _PublishedMqttMessage(
        topic: topic,
        payload: payload,
        qos: qos,
        retain: retain,
      ),
    );
  }

  @override
  Future<void> subscribe(String topic) async {
    subscriptions.add(topic);
  }

  @override
  Stream<SdkMqttDisconnectEvent> watchDisconnects() =>
      _disconnectController.stream;

  @override
  Stream<SdkMqttIncomingMessage> watchMessages() => _messageController.stream;
}

class _PublishedMqttMessage {
  const _PublishedMqttMessage({
    required this.topic,
    required this.payload,
    required this.qos,
    required this.retain,
  });

  final String topic;
  final String payload;
  final SdkMqttQos qos;
  final bool retain;
}

class _FakeOperationalRealtimeClient implements OperationalRealtimeClient {
  final List<MqttOperationalSosRequest> publishedRequests =
      <MqttOperationalSosRequest>[];
  final List<SdkTelemetryPayload> publishedTelemetry =
      <SdkTelemetryPayload>[];
  final StreamController<RealtimeEvent> _eventsController =
      StreamController<RealtimeEvent>.broadcast();

  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    publishedRequests.add(
      request.copyWith(sdkUserId: 'sdk-user-42'),
    );
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    publishedTelemetry.add(payload);
  }

  @override
  Future<void> reconnectIfSessionChanged(EixamSession session) async {}

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Stream<RealtimeConnectionState> watchConnectionState() =>
      const Stream<RealtimeConnectionState>.empty();

  @override
  Stream<RealtimeEvent> watchEvents() => _eventsController.stream;

  void emitEvent(RealtimeEvent event) {
    _eventsController.add(event);
  }

  Future<void> dispose() => _eventsController.close();
}

class _FakeCancelSosRemoteDataSource implements SosRemoteDataSource {
  int cancelCallCount = 0;

  @override
  Future<SosIncidentDto?> cancelSos() async {
    cancelCallCount++;
    return null;
  }

  @override
  Future<SosIncidentDto?> getActiveSos() async => null;

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  }) {
    throw UnimplementedError();
  }
}

EixamSosPacket _deviceOriginPacket() {
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
    0x50,
  ])!;
}
