import 'package:async/async.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';
import '../support/stream_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EixamConnectSdkImpl', () {
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
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

    test('watchPositions replays the last known tracking position', () async {
      final position = await sdk.watchPositions().first;

      expect(position.latitude, 41.38);
      expect(position.longitude, 2.17);
    });

    test('contacts facade delegates add, toggle, and remove flows', () async {
      final contact = await sdk.addEmergencyContact(
        name: 'Alice',
        phone: '+34123456789',
      );

      expect(contact.name, 'Alice');
      expect((await sdk.listEmergencyContacts()).single.id, contact.id);

      await sdk.setEmergencyContactActive(contact.id, false);
      expect((await sdk.listEmergencyContacts()).single.active, isFalse);

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

      final incident = await sdk.cancelSos(reason: 'Resolved');

      final event = await eventFuture;
      expect(incident.state, SosState.cancelled);
      expect(event, isA<SOSCancelledEvent>());
      expect((event as SOSCancelledEvent).incidentId, incident.id);
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
