import 'dart:async';

import 'package:async/async.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
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
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_telemetry_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_data.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_event_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_fragment.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_packet.dart';
import 'package:eixam_connect_flutter/src/sdk/ble_operational_runtime_bridge.dart';
import 'package:eixam_connect_flutter/src/sdk/mqtt_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';
import '../support/stream_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const protectionMethodChannel = MethodChannel(
    'dev.eixam.connect_flutter/protection_runtime/methods',
  );

  group('EixamConnectSdkImpl', () {
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
    late DeviceSosController deviceSosController;
    late PreferredBleDeviceStore preferredDeviceStore;
    late EixamConnectSdkImpl sdk;

    setUp(() {
      BleDebugRegistry.instance.reset();
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
          case 'startProtectionRuntime':
            return <String, dynamic>{
              'success': false,
              'runtimeState': 'failed',
              'coverageLevel': 'none',
              'failureReason':
                  'Protection Mode platform runtime is not configured in this host app yet.',
            };
          case 'flushProtectionQueues':
            return <String, dynamic>{
              'flushedSosCount': 0,
              'flushedTelemetryCount': 0,
              'success': true,
            };
          case 'stopProtectionRuntime':
            return null;
        }
        return null;
      });
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
      deviceRegistryRepository = FakeSdkDeviceRegistryRepository();
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
        deviceRegistryRepository: deviceRegistryRepository,
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
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(protectionMethodChannel, null);
      await sdk.dispose();
      await sosRepository.dispose();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deviceRepository.dispose();
      await deathManRepository.dispose();
      await realtimeClient.dispose();
    });

    test(
        'triggerSos attaches the current position and backend hardware id when available',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-device-123',
          canonicalHardwareId: 'CF:82:11:22:33:44',
          paired: true,
          connected: true,
          activated: true,
        ),
      );

      await sdk.triggerSos(
        const SosTriggerPayload(
          message: 'Need help',
          triggerSource: 'button_ui',
        ),
      );

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastMessage, 'Need help');
      expect(sosRepository.lastTriggerSource, 'button_ui');
      expect(sosRepository.lastPositionSnapshot, isNotNull);
      expect(sosRepository.lastPositionSnapshot!.latitude, 41.38);
      expect(sosRepository.lastDeviceId, 'CF:82:11:22:33:44');
      expect(sosRepository.lastDeviceId, isNot('ble-device-123'));
    });

    test(
        'triggerSos continues without a position snapshot when no current position is available',
        () async {
      final localTrackingRepository = FakeTrackingRepository();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: localTrackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        await localSdk
            .triggerSos(const SosTriggerPayload(message: 'Need help'));

        expect(sosRepository.triggerCallCount, 1);
        expect(sosRepository.lastPositionSnapshot, isNull);
        expect(sosRepository.lastDeviceId, isNull);
      } finally {
        await localSdk.dispose();
        await localTrackingRepository.dispose();
      }
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
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          canonicalExternalUserId: 'canonical-user',
        ),
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-device-1',
          canonicalHardwareId: 'CF:82:AA:BB:CC:DD',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      final payload = SdkTelemetryPayload(
        timestamp: DateTime.utc(2026, 3, 31, 10),
        latitude: 41.38,
        longitude: 2.17,
        altitude: 8,
        deviceId: 'ble-device-1',
      );

      await sdk.publishTelemetry(payload);

      expect(telemetryRepository.publishedPayloads, hasLength(1));
      expect(
        telemetryRepository.publishedPayloads.single.deviceId,
        'CF:82:AA:BB:CC:DD',
      );
      expect(
        telemetryRepository.publishedPayloads.single.userId,
        'canonical-user',
      );
      expect(await sdk.getSosState(), SosState.idle);
    });

    test(
        'publishTelemetry omits a local BLE device id when backend hardware id is unavailable',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-device-1',
          paired: true,
          connected: true,
          activated: true,
        ),
      );

      await sdk.publishTelemetry(
        SdkTelemetryPayload(
          timestamp: DateTime.utc(2026, 3, 31, 10),
          latitude: 41.38,
          longitude: 2.17,
          altitude: 8,
          deviceId: 'ble-device-1',
        ),
      );

      expect(telemetryRepository.publishedPayloads, hasLength(1));
      expect(telemetryRepository.publishedPayloads.single.deviceId, isNull);
    });

    test(
        'publishTelemetry prefers canonical hardware id over local BLE id and friendly name',
        () async {
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          canonicalExternalUserId: 'canonical-user',
        ),
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-local-runtime-id',
          canonicalHardwareId: 'CF:82:12:34:56:78',
          deviceAlias: 'Meshtastic_1aa8',
          paired: true,
          connected: true,
          activated: true,
        ),
      );

      await sdk.publishTelemetry(
        SdkTelemetryPayload(
          timestamp: DateTime.utc(2026, 3, 31, 10),
          latitude: 41.38,
          longitude: 2.17,
          altitude: 8,
          deviceId: 'Meshtastic_1aa8',
        ),
      );

      expect(
        telemetryRepository.publishedPayloads.single.deviceId,
        'CF:82:12:34:56:78',
      );
      expect(
        telemetryRepository.publishedPayloads.single.deviceId,
        isNot('ble-local-runtime-id'),
      );
      expect(
        telemetryRepository.publishedPayloads.single.deviceId,
        isNot('Meshtastic_1aa8'),
      );
    });

    test('session and operational diagnostics expose canonical MQTT topics',
        () async {
      final session = const EixamSession.signed(
        appId: 'app-1',
        externalUserId: 'partner-user',
        userHash: 'token-1',
        canonicalExternalUserId: 'partner/user 42',
      );

      await sdk.setSession(session);

      final currentSession = await sdk.getCurrentSession();
      final diagnostics = await sdk.getOperationalDiagnostics();

      expect(currentSession?.canonicalExternalUserId, 'partner/user 42');
      expect(
        diagnostics.telemetryPublishTopic,
        'tel/partner%2Fuser%2042/data',
      );
      expect(
        diagnostics.sosEventTopics,
        contains('sos/events/partner%2Fuser%2042'),
      );
      expect(diagnostics.hasActiveSession, isTrue);
    });

    test('clearSession clears operational diagnostics session state', () async {
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-1',
          externalUserId: 'partner-user',
          userHash: 'token-1',
          canonicalExternalUserId: 'canonical-user',
        ),
      );

      await sdk.clearSession();

      final diagnostics = await sdk.getOperationalDiagnostics();
      expect(await sdk.getCurrentSession(), isNull);
      expect(diagnostics.session, isNull);
      expect(diagnostics.telemetryPublishTopic, isNull);
      expect(diagnostics.sosEventTopics, isEmpty);
    });

    test('watchPositions replays the last known tracking position', () async {
      final position = await sdk.watchPositions().first;

      expect(position.latitude, 41.38);
      expect(position.longitude, 2.17);
    });

    test('contacts facade delegates create, update, and delete flows',
        () async {
      final contact = await sdk.createEmergencyContact(
        name: 'Alice',
        phone: '+34123456789',
        email: 'alice@example.com',
      );
      final updated = await sdk.updateEmergencyContact(
        contact.copyWith(priority: 2),
      );

      expect(contact.name, 'Alice');
      expect(updated.priority, 2);
      expect((await sdk.listEmergencyContacts()).single.id, contact.id);

      await sdk.deleteEmergencyContact(contact.id);
      expect(await sdk.listEmergencyContacts(), isEmpty);
    });

    test('backend device registry facade delegates list, upsert, and delete',
        () async {
      final upserted = await sdk.upsertRegisteredDevice(
        hardwareId: 'hw-1',
        firmwareVersion: '1.2.3',
        hardwareModel: 'EIXAM R1',
        pairedAt: DateTime.utc(2026, 3, 31, 9),
      );

      expect(upserted.hardwareId, 'hw-1');
      expect((await sdk.listRegisteredDevices()).single.id, upserted.id);

      await sdk.deleteRegisteredDevice(upserted.id);
      expect(await sdk.listRegisteredDevices(), isEmpty);
    });

    test(
        'connectDevice automatically refreshes the matched backend registered device when session identity is ready',
        () async {
      await deviceRegistryRepository.upsertRegisteredDevice(
        hardwareId: 'CF:82:10:20:30:40',
        firmwareVersion: 'old-fw',
        hardwareModel: 'Old model',
        pairedAt: DateTime.utc(2026, 3, 1, 8),
      );
      deviceRegistryRepository.upsertCallCount = 0;
      deviceRegistryRepository.lastHardwareId = null;
      deviceRegistryRepository.lastFirmwareVersion = null;
      deviceRegistryRepository.lastHardwareModel = null;
      deviceRegistryRepository.lastPairedAt = null;

      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-local-id-1',
          canonicalHardwareId: 'CF:82:10:20:30:40',
          paired: true,
          connected: true,
          activated: true,
          model: 'EIXAM R1',
          firmwareVersion: '2.7.21',
        ),
      );

      await sdk.connectDevice(pairingCode: 'PAIR-001');
      await Future<void>.delayed(Duration.zero);

      expect(deviceRegistryRepository.upsertCallCount, 1);
      expect(deviceRegistryRepository.lastHardwareId, 'CF:82:10:20:30:40');
      expect(deviceRegistryRepository.lastFirmwareVersion, '2.7.21');
      expect(deviceRegistryRepository.lastHardwareModel, 'EIXAM R1');
      expect(deviceRegistryRepository.lastPairedAt, isNotNull);
      expect(
        deviceRegistryRepository.devices.single.hardwareId,
        'CF:82:10:20:30:40',
      );
      expect(
        deviceRegistryRepository.devices.single.firmwareVersion,
        '2.7.21',
      );
      expect(
        deviceRegistryRepository.devices.single.hardwareModel,
        'EIXAM R1',
      );
    });

    test(
        'setSession backfills automatic backend registered device sync for an already connected known device',
        () async {
      await deviceRegistryRepository.upsertRegisteredDevice(
        hardwareId: 'CF:82:55:66:77:88',
        firmwareVersion: '1.0.0',
        hardwareModel: 'EIXAM R1',
        pairedAt: DateTime.utc(2026, 3, 1, 8),
      );
      deviceRegistryRepository.upsertCallCount = 0;
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-runtime-9',
          canonicalHardwareId: 'CF:82:55:66:77:88',
          paired: true,
          connected: true,
          activated: true,
          model: 'EIXAM R1',
          firmwareVersion: '3.1.4',
        ),
      );

      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(deviceRegistryRepository.upsertCallCount, 1);
      expect(deviceRegistryRepository.lastHardwareId, 'CF:82:55:66:77:88');
      expect(deviceRegistryRepository.lastFirmwareVersion, '3.1.4');
      expect(deviceRegistryRepository.lastHardwareModel, 'EIXAM R1');
    });

    test(
        'connectDevice skips automatic backend device registration when no canonical hardware id can be resolved',
        () async {
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-local-only-id',
          paired: true,
          connected: true,
          activated: true,
          model: 'EIXAM R1',
          firmwareVersion: '2.7.21',
        ),
      );

      await sdk.connectDevice(pairingCode: 'PAIR-002');
      await Future<void>.delayed(Duration.zero);

      expect(deviceRegistryRepository.upsertCallCount, 0);
      expect(deviceRegistryRepository.devices, isEmpty);
    });

    test(
        'connectDevice auto-sync uses canonical hardware id instead of local BLE id or friendly name',
        () async {
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-local-runtime-id',
          canonicalHardwareId: 'CF:82:AB:CD:EF:01',
          deviceAlias: 'Meshtastic_1aa8',
          paired: true,
          connected: true,
          activated: true,
          model: 'EIXAM R1',
          firmwareVersion: '2.7.21',
        ),
      );

      await sdk.connectDevice(pairingCode: 'PAIR-003');
      await Future<void>.delayed(Duration.zero);

      expect(deviceRegistryRepository.lastHardwareId, 'CF:82:AB:CD:EF:01');
      expect(deviceRegistryRepository.lastHardwareId,
          isNot('ble-local-runtime-id'));
      expect(deviceRegistryRepository.lastHardwareId, isNot('Meshtastic_1aa8'));
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

      final status = await sdk.deviceStatusStream.first;

      expect(status.deviceId, 'demo-device');
      expect(status.lifecycleState, DeviceLifecycleState.unpaired);
    });

    test(
        'local device runtime facade exposes connect, disconnect, and preferred device',
        () async {
      await sdk.connectDevice(pairingCode: 'PAIR-123');
      await sdk.disconnectDevice();
      await preferredDeviceStore.savePreferredDevice(
        PreferredDevice(
          deviceId: 'device-preferred',
          displayName: 'Field Unit',
          lastConnectedAt: DateTime.utc(2026, 3, 31, 8),
        ),
      );

      expect(deviceRepository.lastPairingCode, 'PAIR-123');
      expect(deviceRepository.unpairCallCount, 1);
      expect((await sdk.preferredDevice)?.deviceId, 'device-preferred');
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

    test(
        'default protection mode stays off and reports no-op platform readiness blockers',
        () async {
      final readiness = await sdk.evaluateProtectionReadiness();
      final status = await sdk.getProtectionStatus();
      final diagnostics = await sdk.getProtectionDiagnostics();

      expect(status.modeState, ProtectionModeState.off);
      expect(status.runtimeState, ProtectionRuntimeState.inactive);
      expect(status.coverageLevel, ProtectionCoverageLevel.none);
      expect(readiness.canArm, isFalse);
      expect(
        readiness.blockingIssues.map((issue) => issue.type),
        contains(
            ProtectionBlockingIssueType.platformBackgroundCapabilityMissing),
      );
      expect(diagnostics.pendingSosCount, 0);
      expect(diagnostics.pendingTelemetryCount, 0);
    });

    test('enterProtectionMode does not arm when critical blockers exist',
        () async {
      final result = await sdk.enterProtectionMode();

      expect(result.success, isFalse);
      expect(result.status.modeState, ProtectionModeState.off);
      expect(
        result.blockingIssues.map((issue) => issue.type),
        contains(
            ProtectionBlockingIssueType.platformBackgroundCapabilityMissing),
      );
    });

    test('protection mode can enter and exit with a ready platform adapter',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-armed',
          canonicalHardwareId: 'CF:82:55:66:77:88',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      await deviceRegistryRepository.upsertRegisteredDevice(
        hardwareId: 'CF:82:55:66:77:88',
        firmwareVersion: '1.2.3',
        hardwareModel: 'EIXAM R1',
        pairedAt: DateTime.utc(2026, 3, 31, 9),
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
          expectedBleServiceUuid: '6ba1b218-15a8-461f-9fa8-5dcae273ea00',
          expectedBleCharacteristicUuids: <String>[
            '6ba1b218-15a8-461f-9fa8-5dcae273ea01',
            '6ba1b218-15a8-461f-9fa8-5dcae273ea02',
            '6ba1b218-15a8-461f-9fa8-5dcae273ea03',
            '6ba1b218-15a8-461f-9fa8-5dcae273ea04',
          ],
          discoveredBleServicesSummary:
              '6ba1b218-15a8-461f-9fa8-5dcae273ea00[6ba1b218-15a8-461f-9fa8-5dcae273ea01,6ba1b218-15a8-461f-9fa8-5dcae273ea02,6ba1b218-15a8-461f-9fa8-5dcae273ea03,6ba1b218-15a8-461f-9fa8-5dcae273ea04]',
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
      );
      final localDeviceSosController = DeviceSosController();
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );

        final enterResult = await runtimeSdk.enterProtectionMode();
        final exitedStatus = await runtimeSdk.exitProtectionMode();

        expect(enterResult.success, isTrue);
        expect(enterResult.status.modeState, ProtectionModeState.armed);
        expect(enterResult.status.coverageLevel, ProtectionCoverageLevel.full);
        expect(enterResult.status.bleOwner, ProtectionBleOwner.androidService);
        expect(enterResult.status.serviceBleReady, isTrue);
        expect(
          enterResult.status.expectedBleServiceUuid,
          '6ba1b218-15a8-461f-9fa8-5dcae273ea00',
        );
        expect(
          enterResult.status.discoveredBleServicesSummary,
          contains('6ba1b218-15a8-461f-9fa8-5dcae273ea00'),
        );
        expect(
            localAdapter.lastStartRequest?.apiBaseUrl, 'https://example.test');
        expect(localAdapter.lastStartRequest?.activeDeviceId, 'device-armed');
        expect(
          localAdapter.lastStartRequest?.backendHardwareId,
          'CF:82:55:66:77:88',
        );
        expect(exitedStatus.modeState, ProtectionModeState.off);
        expect(exitedStatus.runtimeState, ProtectionRuntimeState.inactive);
        expect(localAdapter.startCallCount, 1);
        expect(localAdapter.stopCallCount, 1);
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('protection mode reports degraded state for partial Android runtime',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-degraded',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
        ),
        startResult: const ProtectionPlatformStartResult(
          success: true,
          coverageLevel: ProtectionCoverageLevel.partial,
          statusMessage:
              'Android service is active, but BLE ownership still depends on Flutter runtime rehydration.',
        ),
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );

        final enterResult = await runtimeSdk.enterProtectionMode();

        expect(enterResult.success, isTrue);
        expect(enterResult.status.modeState, ProtectionModeState.degraded);
        expect(
            enterResult.status.coverageLevel, ProtectionCoverageLevel.partial);
        expect(
          enterResult.status.degradationReason,
          contains('has not connected to the protected device yet'),
        );
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('android platform events update protection diagnostics and ownership',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-service',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
        platformEvents: events.stream,
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();
        localAdapter.snapshot = const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
        );

        events.add(
          ProtectionPlatformEvent(
            type: ProtectionPlatformEventType.deviceConnected,
            timestamp: DateTime.utc(2026, 4, 5, 12),
            reason: 'service_ble_connected',
          ),
        );
        events.add(
          ProtectionPlatformEvent(
            type: ProtectionPlatformEventType.subscriptionsActive,
            timestamp: DateTime.utc(2026, 4, 5, 12, 1),
            reason: 'service_ble_ready',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final status = await runtimeSdk.getProtectionStatus();
        final diagnostics = await runtimeSdk.getProtectionDiagnostics();

        expect(status.bleOwner, ProtectionBleOwner.androidService);
        expect(status.serviceBleConnected, isTrue);
        expect(status.serviceBleReady, isTrue);
        expect(status.modeState, ProtectionModeState.armed);
        expect(status.coverageLevel, ProtectionCoverageLevel.full);
        expect(diagnostics.lastBleServiceEvent, 'subscriptionsActive');
      } finally {
        await events.close();
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('partial Android runtime surfaces an explicit degradation reason',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-partial',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localRealtimeClient = FakeRealtimeClient();
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: true,
          serviceBleReady: false,
          coverageLevel: ProtectionCoverageLevel.partial,
          runtimeState: ProtectionRuntimeState.active,
          degradationReason:
              'Android foreground service connected to the protected device, but TEL/SOS subscriptions are not active yet.',
        ),
        startResult: const ProtectionPlatformStartResult(
          success: true,
          coverageLevel: ProtectionCoverageLevel.partial,
        ),
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );

        final enterResult = await runtimeSdk.enterProtectionMode();

        expect(enterResult.success, isTrue);
        expect(enterResult.status.modeState, ProtectionModeState.degraded);
        expect(
          enterResult.status.degradationReason,
          contains('TEL/SOS subscriptions are not active yet'),
        );
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('invalid localhost backend config produces explicit degradation',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-localhost',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
          nativeBackendBaseUrl: 'http://127.0.0.1:8080',
          nativeBackendConfigValid: false,
          nativeBackendConfigIssue:
              'Native Protection backend base URL http://127.0.0.1:8080 is invalid for a physical Android device. Use a LAN/reachable host or adb reverse with an explicit debug setup.',
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'http://127.0.0.1:8080'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );

        final enterResult = await runtimeSdk.enterProtectionMode();

        expect(enterResult.success, isTrue);
        expect(enterResult.status.modeState, ProtectionModeState.degraded);
        expect(enterResult.status.nativeBackendConfigValid, isFalse);
        expect(
          enterResult.status.nativeBackendConfigIssue,
          contains('invalid for a physical Android device'),
        );
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('debug localhost backend config stays valid for protection runtime',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-debug-local',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
          nativeBackendBaseUrl: 'http://127.0.0.1:8080',
          nativeBackendConfigValid: true,
          nativeBackendConfigIssue:
              'Debug localhost backend allowed. Debug cleartext backend allowed',
          debugLocalhostBackendAllowed: true,
          debugCleartextBackendAllowed: true,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'http://127.0.0.1:8080'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );

        final enterResult = await runtimeSdk.enterProtectionMode();

        expect(enterResult.success, isTrue);
        expect(enterResult.status.modeState, ProtectionModeState.armed);
        expect(enterResult.status.nativeBackendConfigValid, isTrue);
        expect(enterResult.status.debugLocalhostBackendAllowed, isTrue);
        expect(enterResult.status.debugCleartextBackendAllowed, isTrue);
        expect(
          enterResult.status.nativeBackendConfigIssue,
          contains('Debug localhost backend allowed'),
        );
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('ios restoration events update protection diagnostics safely',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-ios-restore',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.ios,
          backgroundCapabilityState: ProtectionCapabilityState.configured,
          restorationConfigured: true,
          bleOwner: ProtectionBleOwner.iosPlugin,
          runtimeState: ProtectionRuntimeState.recovering,
          coverageLevel: ProtectionCoverageLevel.partial,
        ),
        startResult: const ProtectionPlatformStartResult(
          success: true,
          runtimeState: ProtectionRuntimeState.recovering,
          coverageLevel: ProtectionCoverageLevel.partial,
        ),
        platformEvents: events.stream,
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        events.add(
          ProtectionPlatformEvent(
            type: ProtectionPlatformEventType.restorationDetected,
            timestamp: DateTime.utc(2026, 4, 5, 13),
            reason: 'ios_restoration',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        final status = await runtimeSdk.getProtectionStatus();
        final diagnostics = await runtimeSdk.getProtectionDiagnostics();

        expect(status.platform, ProtectionPlatform.ios);
        expect(status.restorationConfigured, isTrue);
        expect(status.bleOwner, ProtectionBleOwner.iosPlugin);
        expect(status.lastRestorationEvent, 'restorationDetected');
        expect(diagnostics.lastRestorationEvent, 'restorationDetected');
      } finally {
        await events.close();
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('watchProtectionStatus emits additive transitions', () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-watch',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
      );
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
          ),
        );

        final statusQueue =
            StreamQueue<ProtectionStatus>(runtimeSdk.watchProtectionStatus());
        expect((await statusQueue.next).modeState, ProtectionModeState.off);

        final armingFuture = statusQueue.next;
        final degradedFuture = statusQueue.next;
        await runtimeSdk.enterProtectionMode();

        expect((await armingFuture).modeState, ProtectionModeState.arming);
        expect((await degradedFuture).modeState, ProtectionModeState.degraded);
        await statusQueue.cancel();
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'ios protection adapter reports plugin-owned degraded runtime honestly',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-ios',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.ios,
          backgroundCapabilityState: ProtectionCapabilityState.configured,
          restorationConfigured: true,
          bleOwner: ProtectionBleOwner.iosPlugin,
          runtimeActive: true,
          serviceBleConnected: true,
          serviceBleReady: false,
          runtimeState: ProtectionRuntimeState.recovering,
          coverageLevel: ProtectionCoverageLevel.partial,
          degradationReason:
              'The iOS plugin runtime is connected, but TEL/SOS subscriptions are not active yet.',
          activeDeviceId: 'device-ios',
        ),
        startResult: const ProtectionPlatformStartResult(
          success: true,
          runtimeState: ProtectionRuntimeState.recovering,
          coverageLevel: ProtectionCoverageLevel.partial,
          statusMessage:
              'The iOS plugin runtime is armed, but background BLE recovery is still partial.',
        ),
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );

        final enterResult = await runtimeSdk.enterProtectionMode();
        final status = enterResult.status;

        expect(status.platform, ProtectionPlatform.ios);
        expect(status.coverageLevel, ProtectionCoverageLevel.partial);
        expect(status.backgroundCapabilityState,
            ProtectionCapabilityState.configured);
        expect(status.bleOwner, ProtectionBleOwner.iosPlugin);
        expect(status.protectionRuntimeActive, isTrue);
        expect(status.serviceBleConnected, isTrue);
        expect(status.serviceBleReady, isFalse);
        expect(
          status.degradationReason,
          anyOf(
            contains('background BLE recovery'),
            contains('TEL/SOS subscriptions'),
          ),
        );
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('ios protection resume reattaches native runtime without pairing',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-ios-resume',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.ios,
          backgroundCapabilityState: ProtectionCapabilityState.configured,
          restorationConfigured: true,
          bleOwner: ProtectionBleOwner.iosPlugin,
          protectedDeviceId: 'device-ios-resume',
          activeDeviceId: 'device-ios-resume',
          runtimeActive: true,
          serviceBleConnected: false,
          serviceBleReady: false,
          runtimeState: ProtectionRuntimeState.recovering,
          coverageLevel: ProtectionCoverageLevel.partial,
          degradationReason:
              'The iOS plugin runtime is armed, but the protected peripheral is not connected yet.',
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: FakeRealtimeClient(),
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        runtimeSdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);

        expect(localAdapter.ensureActiveCallCount, 1);
        expect(localAdapter.lastEnsureActiveReason, 'app_foreground_resume');
        expect(
            localAdapter.lastStartRequest?.activeDeviceId, 'device-ios-resume');
      } finally {
        await runtimeSdk.dispose();
      }
    });

    test('ios protection shutdown routes through native owner', () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-ios-shutdown',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.ios,
          backgroundCapabilityState: ProtectionCapabilityState.configured,
          restorationConfigured: true,
          bleOwner: ProtectionBleOwner.iosPlugin,
          protectedDeviceId: 'device-ios-shutdown',
          activeDeviceId: 'device-ios-shutdown',
          runtimeActive: true,
          serviceBleConnected: true,
          serviceBleReady: true,
          runtimeState: ProtectionRuntimeState.active,
          coverageLevel: ProtectionCoverageLevel.full,
          lastCommandRoute: 'iosPlugin',
          lastCommandResult: 'SHUTDOWN native write succeeded via iosPlugin.',
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
        commandResult: const ProtectionPlatformCommandResult(
          success: true,
          route: 'iosPlugin',
          result: 'SHUTDOWN native write succeeded via iosPlugin.',
        ),
      );
      final localDeviceSosController = DeviceSosController();
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: FakeRealtimeClient(),
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        await runtimeSdk.sendShutdownToDevice();
        final status = await runtimeSdk.getProtectionStatus();

        expect(localAdapter.sendCommandCallCount, 1);
        expect(localAdapter.lastCommandRequest?.label, 'SHUTDOWN');
        expect(localAdapter.lastCommandRequest?.bytes, <int>[0x10]);
        expect(status.lastCommandRoute, 'iosPlugin');
        expect(status.lastCommandResult, contains('SHUTDOWN'));
      } finally {
        await runtimeSdk.dispose();
      }
    });

    test('android protection resume reattaches native runtime without pairing',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-resume',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          protectedDeviceId: 'device-resume',
          activeDeviceId: 'device-resume',
          runtimeActive: true,
          serviceRunning: true,
          serviceBleConnected: false,
          serviceBleReady: false,
          coverageLevel: ProtectionCoverageLevel.partial,
          runtimeState: ProtectionRuntimeState.recovering,
          degradationReason:
              'Android foreground service is reconnecting to the protected BLE device.',
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: FakeRealtimeClient(),
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        runtimeSdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);

        expect(localAdapter.ensureActiveCallCount, 1);
        expect(localAdapter.lastEnsureActiveReason, 'app_foreground_resume');
        expect(localAdapter.lastStartRequest?.activeDeviceId, 'device-resume');
      } finally {
        await runtimeSdk.dispose();
      }
    });

    test('android protection shutdown routes through native owner', () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-shutdown',
          connected: true,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          protectedDeviceId: 'device-shutdown',
          activeDeviceId: 'device-shutdown',
          runtimeActive: true,
          serviceRunning: true,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
          lastCommandRoute: 'androidService',
          lastCommandResult:
              'SHUTDOWN native write succeeded via androidService.',
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
        commandResult: const ProtectionPlatformCommandResult(
          success: true,
          route: 'androidService',
          result: 'SHUTDOWN native write succeeded via androidService.',
        ),
      );
      final localDeviceSosController = DeviceSosController();
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: FakeRealtimeClient(),
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        await runtimeSdk.sendShutdownToDevice();
        final status = await runtimeSdk.getProtectionStatus();

        expect(localAdapter.sendCommandCallCount, 1);
        expect(localAdapter.lastCommandRequest?.label, 'SHUTDOWN');
        expect(localAdapter.lastCommandRequest?.bytes, <int>[0x10]);
        expect(status.lastCommandRoute, 'androidService');
      } finally {
        await runtimeSdk.dispose();
      }
    });

    test('shutdown keeps Flutter path when protection mode is off', () async {
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: false,
          platform: ProtectionPlatform.android,
        ),
        startResult: const ProtectionPlatformStartResult(success: false),
      );
      final localDeviceSosController = DeviceSosController();
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: FakeRealtimeClient(),
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await localDeviceSosController.attach(
          commandWriter: (_) async {},
        );

        await runtimeSdk.sendShutdownToDevice();

        expect(localAdapter.sendCommandCallCount, 0);
      } finally {
        await runtimeSdk.dispose();
      }
    });

    test(
        'rehydrateProtectionState adopts restored ios plugin snapshot coherently',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-ios-restored',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.ios,
          backgroundCapabilityState: ProtectionCapabilityState.configured,
          restorationConfigured: true,
          bleOwner: ProtectionBleOwner.iosPlugin,
          runtimeActive: true,
          serviceBleConnected: true,
          serviceBleReady: true,
          runtimeState: ProtectionRuntimeState.active,
          coverageLevel: ProtectionCoverageLevel.full,
          activeDeviceId: 'device-ios-restored',
          lastRestorationEvent: 'restorationRehydrated',
          degradationReason: null,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
      );
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );

        final status = await runtimeSdk.rehydrateProtectionState();
        final diagnostics = await runtimeSdk.getProtectionDiagnostics();

        expect(status.platform, ProtectionPlatform.ios);
        expect(status.modeState, ProtectionModeState.armed);
        expect(status.coverageLevel, ProtectionCoverageLevel.full);
        expect(status.bleOwner, ProtectionBleOwner.iosPlugin);
        expect(status.activeDeviceId, 'device-ios-restored');
        expect(status.degradationReason, isNull);
        expect(diagnostics.lastRestorationEvent, 'restorationRehydrated');
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
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
        deviceRegistryRepository: deviceRegistryRepository,
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
        deviceRegistryRepository: deviceRegistryRepository,
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
        const SosTriggerPayload(
          message: 'Need help',
          triggerSource: 'button_ui',
        ),
      );

      final event = await eventFuture;
      expect(event, isA<SOSTriggeredEvent>());
      expect((event as SOSTriggeredEvent).incidentId, incident.id);
    });

    test('triggerSos without a connected device keeps backend-only behavior',
        () async {
      final incident = await sdk.triggerSos(
        const SosTriggerPayload(message: 'Need help'),
      );

      expect(incident.state, SosState.sent);
      expect(sosRepository.triggerCallCount, 1);
      expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.inactive);
    });

    test('triggerSos with a connected device also triggers device SOS',
        () async {
      final commands = <String>[];
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-sos-1',
          canonicalHardwareId: 'CF:82:11:22:33:44',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      await _attachObservedAppActivationWriter(
        deviceSosController,
        commandLabels: commands,
        closeAckPacket: <int>[0xE1, 0x02, 0x34, 0x12],
      );

      await sdk.triggerSos(const SosTriggerPayload(message: 'Need help'));

      expect(sosRepository.triggerCallCount, 1);
      expect(commands, <String>['SOS TRIGGER APP', 'SOS CONFIRM']);
      expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.active);
    });

    test(
        'device SOS packets after app-triggered SOS stay correlated to the existing public incident',
        () async {
      final commands = <String>[];
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-sos-correlated-1',
          canonicalHardwareId: 'CF:82:11:22:33:46',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      await _attachObservedAppActivationWriter(
        deviceSosController,
        commandLabels: commands,
        closeAckPacket: <int>[0xE1, 0x02, 0x34, 0x12],
      );

      final incident = await sdk.triggerSos(
        const SosTriggerPayload(message: 'Need help'),
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPacket(),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(Duration.zero);

      final statusAfterPacket = await sdk.getDeviceSosStatus();
      expect(statusAfterPacket.state, DeviceSosState.active);
      expect(statusAfterPacket.triggerOrigin, DeviceSosTransitionSource.app);
      expect(sosRepository.triggerCallCount, 1);
      expect((await sdk.getCurrentSosIncident())?.id, incident.id);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) => event.message.contains(
            'Device SOS backend sync created incident',
          ),
        ),
        isFalse,
      );

      final cancelled = await sdk.cancelSos();

      expect(cancelled.id, incident.id);
      expect(cancelled.state, SosState.cancelled);
      expect(sosRepository.cancelCallCount, 1);
      expect(commands, contains('SOS CANCEL'));
      expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.resolved);
    });

    test(
        'app-triggered SOS resolve converges backend and device after correlated BLE status',
        () async {
      final commands = <String>[];
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-sos-resolve-1',
          canonicalHardwareId: 'CF:82:11:22:33:47',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      await _attachObservedAppActivationWriter(
        deviceSosController,
        commandLabels: commands,
        closeAckPacket: <int>[0xE1, 0x02, 0x34, 0x12],
      );

      final incident = await sdk.triggerSos(
        const SosTriggerPayload(message: 'Need help'),
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPacket(),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(Duration.zero);

      await sdk.resolveSos();

      expect(sosRepository.resolveCallCount, 1);
      expect(sosRepository.triggerCallCount, 1);
      expect((await sdk.getCurrentSosIncident())?.id, incident.id);
      expect(sosRepository.currentIncident.state, SosState.resolved);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) => event.message.contains(
            'Device SOS backend sync created incident',
          ),
        ),
        isFalse,
      );
      expect(commands, contains('SOS CANCEL'));
      expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.resolved);
    });

    test(
        'app-triggered SOS bridge expiration is cleaned up and late BLE status still stays on the same incident',
        () async {
      final localSosRepository = FakeSosRepository();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(
          connected: false,
          lifecycleState: DeviceLifecycleState.unpaired,
          paired: false,
          activated: false,
        ),
      );
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: localSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: localDeviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        appTriggeredSosBridgeWindow: const Duration(milliseconds: 10),
      );

      try {
        localDeviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-sos-expiry-1',
            canonicalHardwareId: 'CF:82:11:22:33:48',
            paired: true,
            connected: true,
            activated: true,
          ),
        );
        await localSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await _attachObservedAppActivationWriter(localDeviceSosController);

        final incident = await localSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));

        localDeviceSosController.handleIncomingSosPacket(
          _deviceOriginPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await Future<void>.delayed(Duration.zero);

        final status = await localSdk.getDeviceSosStatus();
        expect(status.triggerOrigin, DeviceSosTransitionSource.app);
        expect(localSosRepository.triggerCallCount, 1);
        expect((await localSdk.getCurrentSosIncident())?.id, incident.id);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains(
              'App-triggered SOS bridge cleared -> incidentId=${incident.id} reason=expired',
            ),
          ),
          isTrue,
        );
      } finally {
        await localSdk.dispose();
        await localSosRepository.dispose();
        await localRealtimeClient.dispose();
        await localDeviceRepository.dispose();
      }
    });

    test(
        'triggerSos uses the live command-capable device path even when isReadyForSafety is false',
        () async {
      final commands = <String>[];
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-sos-live-1',
          canonicalHardwareId: 'CF:82:11:22:33:45',
          paired: true,
          connected: true,
          activated: false,
          lifecycleState: DeviceLifecycleState.paired,
        ),
      );
      await _attachObservedAppActivationWriter(
        deviceSosController,
        commandLabels: commands,
        closeAckPacket: <int>[0xE1, 0x02, 0x34, 0x12],
      );

      final incident = await sdk.triggerSos(
        const SosTriggerPayload(message: 'Need help'),
      );
      final diagnostics = await sdk.getOperationalDiagnostics();

      expect(sosRepository.triggerCallCount, 1);
      expect(commands, <String>['SOS TRIGGER APP', 'SOS CONFIRM']);
      expect(incident.deliveryChannel, SosDeliveryChannel.backendAndDevice);
      expect(diagnostics.deviceSosAvailable, isTrue);
      expect(
        diagnostics.currentSosCapabilityChannel,
        SosDeliveryChannel.backendAndDevice,
      );
      expect(diagnostics.currentSosCapabilityLabel, 'backend + device');
    });

    test('currentSosStateStream exposes the facade SOS state stream', () async {
      sosRepository.currentIncident = sosRepository.currentIncident.copyWith(
        state: SosState.sent,
      );

      expect(await sdk.currentSosStateStream.first, SosState.sent);
    });

    test('lastSosEventStream replays the latest SOS facade event', () async {
      await sdk.triggerSos(const SosTriggerPayload(message: 'Need help'));

      final event = await sdk.lastSosEventStream.first;

      expect(event, isA<SOSTriggeredEvent>());
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

    test('cancelSos without a connected device keeps current behavior',
        () async {
      sosRepository.currentIncident = SosIncident(
        id: 'sos-1',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1),
      );

      final incident = await sdk.cancelSos();

      expect(incident.state, SosState.cancelled);
      expect(sosRepository.cancelCallCount, 1);
      expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.inactive);
    });

    test('cancelSos with a connected device also cancels device SOS', () async {
      final commands = <String>[];
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-sos-1',
          canonicalHardwareId: 'CF:82:11:22:33:44',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      await _attachObservedAppActivationWriter(
        deviceSosController,
        commandLabels: commands,
        closeAckPacket: <int>[0xE1, 0x02, 0x34, 0x12],
      );

      await sdk.triggerSos(const SosTriggerPayload(message: 'Need help'));
      final incident = await sdk.cancelSos();

      expect(incident.state, SosState.cancelled);
      expect(sosRepository.cancelCallCount, 1);
      expect(commands, contains('SOS CANCEL'));
      expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.resolved);
    });

    test(
        'cancelSos does not claim device delivery when no observed close acknowledgement arrives',
        () async {
      final commands = <String>[];
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController(
        appActivationObservationTimeout: const Duration(milliseconds: 40),
      );
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-sos-cancel-timeout-1',
            canonicalHardwareId: 'CF:82:11:22:33:49',
            paired: true,
            connected: true,
            activated: true,
          ),
        );
        await _attachObservedAppActivationWriter(
          localDeviceSosController,
          commandLabels: commands,
        );

        final incident = await localSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help'),
        );
        final cancelled = await localSdk.cancelSos();

        expect(incident.deliveryChannel, SosDeliveryChannel.backendAndDevice);
        expect(cancelled.deliveryChannel, SosDeliveryChannel.backendOnly);
        expect(cancelled.id, incident.id);
        expect(commands, contains('SOS CANCEL'));
        expect(
          (await localSdk.getDeviceSosStatus()).state,
          DeviceSosState.active,
        );
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains(
              'Public SOS device sync failed -> action=cancel',
            ),
          ),
          isTrue,
        );
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('resolveSos delegates through the public SDK seam', () async {
      sosRepository.currentIncident = SosIncident(
        id: 'sos-1',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 1, 1),
      );

      await sdk.resolveSos();

      expect(sosRepository.resolveCallCount, 1);
      expect(sosRepository.currentIncident.state, SosState.resolved);
    });

    test('resolveSos with a connected device propagates terminal device state',
        () async {
      final commands = <String>[];
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-sos-1',
          canonicalHardwareId: 'CF:82:11:22:33:44',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      await _attachObservedAppActivationWriter(
        deviceSosController,
        commandLabels: commands,
        closeAckPacket: <int>[0xE1, 0x02, 0x34, 0x12],
      );

      await sdk.triggerSos(const SosTriggerPayload(message: 'Need help'));
      await sdk.confirmDeviceSos();
      await sdk.resolveSos();

      expect(sosRepository.resolveCallCount, 1);
      expect(commands, contains('SOS CANCEL'));
      expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.resolved);
    });

    test(
        'device activation partial failure does not claim device delivery and keeps backend SOS success',
        () async {
      final commands = <String>[];
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-sos-1',
          canonicalHardwareId: 'CF:82:11:22:33:44',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      await deviceSosController.attach(
        commandWriter: (command) async {
          commands.add(command.label);
          if (command.label == 'SOS TRIGGER APP') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              deviceSosController.handleIncomingSosPacket(
                _deviceOriginPacket(),
                source: DeviceSosTransitionSource.device,
              );
            });
          }
          if (command.label == 'SOS CONFIRM') {
            throw StateError('confirm failed');
          }
        },
      );

      final incident = await sdk.triggerSos(
        const SosTriggerPayload(message: 'Need help'),
      );

      expect(incident.state, SosState.sent);
      expect(incident.deliveryChannel, SosDeliveryChannel.backendOnly);
      expect(sosRepository.triggerCallCount, 1);
      expect(commands, <String>['SOS TRIGGER APP', 'SOS CONFIRM']);
      expect((await sdk.getDeviceSosStatus()).state, DeviceSosState.preConfirm);
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) => event.message.contains(
            'Public SOS device sync failed -> action=trigger',
          ),
        ),
        isTrue,
      );
      expect(
        BleDebugRegistry.instance.currentState.events.any(
          (event) =>
              event.message.contains(
                'App SOS device activation incomplete',
              ) &&
              event.message.contains('device_stayed_in_pre_sos'),
        ),
        isTrue,
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPacket(),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(Duration.zero);

      expect(sosRepository.triggerCallCount, 1);
      expect((await sdk.getCurrentSosIncident())?.id, incident.id);
    });

    test(
        'device activation handshake timeout does not falsely report backendAndDevice',
        () async {
      final commands = <String>[];
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 80),
        countdownTick: const Duration(milliseconds: 5),
        appActivationObservationTimeout: const Duration(milliseconds: 40),
      );
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-sos-2',
            canonicalHardwareId: 'CF:82:55:66:77:88',
            paired: true,
            connected: true,
            activated: true,
          ),
        );
        await localDeviceSosController.attach(
          commandWriter: (command) async {
            commands.add(command.label);
            if (command.label == 'SOS TRIGGER APP') {
              Future<void>.delayed(const Duration(milliseconds: 5), () {
                localDeviceSosController.handleIncomingSosPacket(
                  _deviceOriginPacket(),
                  source: DeviceSosTransitionSource.device,
                );
              });
            }
          },
        );

        final incident = await localSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help'),
        );

        expect(incident.state, SosState.sent);
        expect(incident.deliveryChannel, SosDeliveryChannel.backendOnly);
        expect(commands, <String>['SOS TRIGGER APP', 'SOS CONFIRM']);
        expect(
          (await localSdk.getDeviceSosStatus()).state,
          DeviceSosState.preConfirm,
        );
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains(
                  'App SOS device activation incomplete',
                ) &&
                event.message.contains(
                  'observed device active SOS after confirm',
                ),
          ),
          isTrue,
        );
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'triggerSos with backend unavailable but device available succeeds through device only',
        () async {
      final unavailableSosRepository = _AvailabilityAwareSosRepository();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: unavailableSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-fallback-1',
            canonicalHardwareId: 'CF:82:55:66:77:88',
            paired: true,
            connected: true,
            activated: true,
          ),
        );
        await _attachObservedAppActivationWriter(localDeviceSosController);

        final incident = await localSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help'),
        );
        final diagnostics = await localSdk.getOperationalDiagnostics();

        expect(unavailableSosRepository.triggerCallCount, 0);
        expect(incident.state, SosState.sent);
        expect(incident.deliveryChannel, SosDeliveryChannel.deviceOnly);
        expect(await localSdk.getSosState(), SosState.sent);
        expect(
          (await localSdk.getCurrentSosIncident())?.deliveryChannel,
          SosDeliveryChannel.deviceOnly,
        );
        expect(
          diagnostics.lastPublicSosDeliveryChannel,
          SosDeliveryChannel.deviceOnly,
        );
        expect(diagnostics.deviceSosAvailable, isTrue);
      } finally {
        await localSdk.dispose();
        await unavailableSosRepository.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('triggerSos with backend unavailable and no device fails clearly',
        () async {
      final unavailableSosRepository = _AvailabilityAwareSosRepository();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: unavailableSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        await expectLater(
          localSdk.triggerSos(const SosTriggerPayload(message: 'Need help')),
          throwsA(
            isA<SosException>().having(
              (error) => error.code,
              'code',
              'E_SOS_NOT_AVAILABLE',
            ),
          ),
        );
      } finally {
        await localSdk.dispose();
        await unavailableSosRepository.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('backend failure does not break device-only SOS success', () async {
      final unavailableSosRepository = _AvailabilityAwareSosRepository()
        ..currentIncident = SosIncident(
          id: 'device-fallback-1',
          state: SosState.sent,
          createdAt: DateTime.utc(2026, 1, 1),
          deliveryChannel: SosDeliveryChannel.deviceOnly,
        );
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: unavailableSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-fallback-1',
            canonicalHardwareId: 'CF:82:55:66:77:88',
            paired: true,
            connected: true,
            activated: true,
          ),
        );
        await _attachObservedAppActivationWriter(localDeviceSosController);
        await localSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help'),
        );

        final cancelled = await localSdk.cancelSos();
        final diagnostics = await localSdk.getOperationalDiagnostics();

        expect(cancelled.state, SosState.cancelled);
        expect(cancelled.deliveryChannel, SosDeliveryChannel.deviceOnly);
        expect(diagnostics.lastPublicSosDeliveryChannel,
            SosDeliveryChannel.deviceOnly);
      } finally {
        await localSdk.dispose();
        await unavailableSosRepository.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'public triggerSos device sync does not introduce duplicate backend transitions',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-sos-1',
          canonicalHardwareId: 'CF:82:11:22:33:44',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      await _attachObservedAppActivationWriter(deviceSosController);

      await sdk.triggerSos(const SosTriggerPayload(message: 'Need help'));
      await sdk.confirmDeviceSos();

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.cancelCallCount, 0);
      expect(sosRepository.resolveCallCount, 0);
    });

    test(
        'exposed SOS delivery channel reports backend_only and backend_and_device',
        () async {
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
      );

      final backendOnlyIncident = await sdk.triggerSos(
        const SosTriggerPayload(message: 'Need help'),
      );
      final backendOnlyDiagnostics = await sdk.getOperationalDiagnostics();

      expect(
          backendOnlyIncident.deliveryChannel, SosDeliveryChannel.backendOnly);
      expect(
        backendOnlyDiagnostics.lastPublicSosDeliveryChannel,
        SosDeliveryChannel.backendOnly,
      );
      expect(backendOnlyDiagnostics.backendSosAvailable, isTrue);
      expect(backendOnlyDiagnostics.deviceSosAvailable, isFalse);
      expect(backendOnlyDiagnostics.canActivateSos, isTrue);

      final localSosRepository = FakeSosRepository();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSdk = EixamConnectSdkImpl(
        sosRepository: localSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        await localSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
          ),
        );
        deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-sos-1',
            canonicalHardwareId: 'CF:82:11:22:33:44',
            paired: true,
            connected: true,
            activated: true,
          ),
        );
        await _attachObservedAppActivationWriter(localDeviceSosController);

        final bothIncident = await localSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help again'),
        );
        final bothDiagnostics = await localSdk.getOperationalDiagnostics();

        expect(
          bothIncident.deliveryChannel,
          SosDeliveryChannel.backendAndDevice,
        );
        expect(
          bothDiagnostics.lastPublicSosDeliveryChannel,
          SosDeliveryChannel.backendAndDevice,
        );
        expect(bothDiagnostics.deviceSosAvailable, isTrue);
        expect(bothDiagnostics.canActivateSos, isTrue);
      } finally {
        await localSdk.dispose();
        await localSosRepository.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'android native owner app-triggered SOS reaches observed preConfirm and active through forwarded packets',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-native-trigger',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.activated,
        ),
      );
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          protectedDeviceId: 'device-native-trigger',
          activeDeviceId: 'device-native-trigger',
          runtimeActive: true,
          serviceRunning: true,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
        platformEvents: events.stream,
        commandResult: const ProtectionPlatformCommandResult(
          success: true,
          route: 'androidService',
          result: 'SOS TRIGGER APP native write succeeded via androidService.',
        ),
        onSendCommand: (request) {
          if (request.label == 'SOS TRIGGER APP') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(
                ProtectionPlatformEvent(
                  type: ProtectionPlatformEventType.sosEventReceived,
                  timestamp: DateTime.utc(2026, 4, 19, 10, 0, 0),
                  reason: '34120000000000000040',
                ),
              );
            });
          }
          if (request.label == 'SOS CONFIRM') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(
                ProtectionPlatformEvent(
                  type: ProtectionPlatformEventType.sosEventReceived,
                  timestamp: DateTime.utc(2026, 4, 19, 10, 0, 1),
                  reason: _deviceOriginPacket().rawHex,
                ),
              );
            });
          }
        },
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(
          appActivationObservationTimeout: const Duration(milliseconds: 80),
        ),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        final incident = await runtimeSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help'),
        );

        expect(incident.deliveryChannel, SosDeliveryChannel.backendAndDevice);
        expect(localAdapter.sendCommandCallCount, 2);
        expect(
          localAdapter.commandRequests.map((request) => request.label),
          <String>['SOS TRIGGER APP', 'SOS CONFIRM'],
        );
        expect(localAdapter.commandRequests.first.bytes, <int>[0x06]);
        expect(localAdapter.commandRequests.last.bytes, <int>[0x05]);
        expect(
          (await runtimeSdk.getDeviceSosStatus()).state,
          DeviceSosState.active,
        );
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains(
              'Protection SOS payload forwarded -> type=sosMeshPacket',
            ),
          ),
          isTrue,
        );
      } finally {
        await events.close();
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'android native-owner triggerSos falls back to backend-only when the native command is rejected',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-native-trigger-fail',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.activated,
        ),
      );
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          protectedDeviceId: 'device-native-trigger-fail',
          activeDeviceId: 'device-native-trigger-fail',
          runtimeActive: true,
          serviceRunning: true,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
        queuedCommandResults: <ProtectionPlatformCommandResult>[
          const ProtectionPlatformCommandResult(
            success: true,
            route: 'androidService',
            result:
                'SOS TRIGGER APP native write succeeded via androidService.',
          ),
          const ProtectionPlatformCommandResult(
            success: false,
            route: 'androidService',
            error: 'native write rejected',
          ),
        ],
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        final incident = await runtimeSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help'),
        );

        expect(incident.deliveryChannel, SosDeliveryChannel.backendOnly);
        expect(localAdapter.sendCommandCallCount, 2);
        expect(
          localAdapter.commandRequests.map((request) => request.label),
          <String>['SOS TRIGGER APP', 'SOS CONFIRM'],
        );
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains(
              'Native owner command rejected -> owner=native_protection command=SOS CONFIRM',
            ),
          ),
          isTrue,
        );
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains(
                  'App SOS device activation incomplete',
                ) &&
                event.message.contains('device_stayed_in_pre_sos'),
          ),
          isTrue,
        );
      } finally {
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'android native owner cancel and resolve reach observed close ack through forwarded packets',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-native-close',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.activated,
        ),
      );
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          protectedDeviceId: 'device-native-close',
          activeDeviceId: 'device-native-close',
          runtimeActive: true,
          serviceRunning: true,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
        platformEvents: events.stream,
        onSendCommand: (request) {
          if (request.label == 'SOS TRIGGER APP') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(
                ProtectionPlatformEvent(
                  type: ProtectionPlatformEventType.sosEventReceived,
                  timestamp: DateTime.utc(2026, 4, 19, 10, 1, 0),
                  reason: '34120000000000000040',
                ),
              );
            });
          }
          if (request.label == 'SOS CONFIRM') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(
                ProtectionPlatformEvent(
                  type: ProtectionPlatformEventType.sosEventReceived,
                  timestamp: DateTime.utc(2026, 4, 19, 10, 1, 1),
                  reason: _deviceOriginPacket().rawHex,
                ),
              );
            });
          }
          if (request.label == 'SOS CANCEL') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(
                ProtectionPlatformEvent(
                  type: ProtectionPlatformEventType.sosEventReceived,
                  timestamp: DateTime.utc(2026, 4, 19, 10, 1, 2),
                  reason: 'e1023412',
                ),
              );
            });
          }
        },
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(
          appActivationObservationTimeout: const Duration(milliseconds: 80),
        ),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        final incident = await runtimeSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help'),
        );
        final cancelled = await runtimeSdk.cancelSos();

        expect(cancelled.id, incident.id);
        expect(cancelled.deliveryChannel, SosDeliveryChannel.backendAndDevice);
        expect((await runtimeSdk.getDeviceSosStatus()).state,
            DeviceSosState.resolved);

        await runtimeSdk.triggerSos(
          const SosTriggerPayload(message: 'Need help again'),
        );
        await runtimeSdk.resolveSos();

        expect(sosRepository.resolveCallCount, 1);
        expect((await runtimeSdk.getDeviceSosStatus()).state,
            DeviceSosState.resolved);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains(
              'Protection SOS payload forwarded -> type=sosDeviceEvent',
            ),
          ),
          isTrue,
        );
      } finally {
        await events.close();
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'android native owner unrecognized SOS payload is logged and ignored safely',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-native-unrecognized',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.activated,
        ),
      );
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          protectedDeviceId: 'device-native-unrecognized',
          activeDeviceId: 'device-native-unrecognized',
          runtimeActive: true,
          serviceRunning: true,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
        platformEvents: events.stream,
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        events.add(
          ProtectionPlatformEvent(
            type: ProtectionPlatformEventType.sosEventReceived,
            timestamp: DateTime.utc(2026, 4, 19, 10, 2, 0),
            reason: '010203040506',
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect((await runtimeSdk.getDeviceSosStatus()).state,
            DeviceSosState.inactive);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) => event.message.contains(
              'Protection SOS payload ignored -> reason=unrecognized_payload',
            ),
          ),
          isTrue,
        );
      } finally {
        await events.close();
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'android native owner routes trigger confirm acknowledge and cancel through protection commands',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      );
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'device-native-sequence',
          connected: false,
          paired: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.activated,
        ),
      );
      final events = StreamController<ProtectionPlatformEvent>.broadcast();
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          protectedDeviceId: 'device-native-sequence',
          activeDeviceId: 'device-native-sequence',
          runtimeActive: true,
          serviceRunning: true,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
        platformEvents: events.stream,
        onSendCommand: (request) {
          if (request.label == 'SOS TRIGGER APP') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(
                ProtectionPlatformEvent(
                  type: ProtectionPlatformEventType.sosEventReceived,
                  timestamp: DateTime.utc(2026, 4, 19, 10, 3, 0),
                  reason: '34120000000000000040',
                ),
              );
            });
          }
          if (request.label == 'SOS CONFIRM') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(
                ProtectionPlatformEvent(
                  type: ProtectionPlatformEventType.sosEventReceived,
                  timestamp: DateTime.utc(2026, 4, 19, 10, 3, 1),
                  reason: _deviceOriginPacket().rawHex,
                ),
              );
            });
          }
          if (request.label == 'SOS CANCEL') {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              events.add(
                ProtectionPlatformEvent(
                  type: ProtectionPlatformEventType.sosEventReceived,
                  timestamp: DateTime.utc(2026, 4, 19, 10, 3, 2),
                  reason: 'e1023412',
                ),
              );
            });
          }
        },
      );
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final runtimeSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        await runtimeSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await runtimeSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
            canonicalExternalUserId: 'canonical-user',
          ),
        );
        await runtimeSdk.enterProtectionMode();

        await runtimeSdk.triggerDeviceSos();
        await runtimeSdk.confirmDeviceSos();
        await runtimeSdk.acknowledgeDeviceSos();
        await runtimeSdk.cancelDeviceSos();

        expect(
          localAdapter.commandRequests.map((request) => request.label),
          <String>[
            'SOS TRIGGER APP',
            'SOS CONFIRM',
            'SOS ACK',
            'SOS CANCEL',
          ],
        );
      } finally {
        await events.close();
        await runtimeSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test(
        'operational diagnostics refresh when device connectivity and command path change',
        () async {
      final disconnectedDiagnostics = await sdk.getOperationalDiagnostics();
      expect(disconnectedDiagnostics.deviceSosAvailable, isFalse);
      expect(disconnectedDiagnostics.currentSosCapabilityLabel, 'backend only');

      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-diag-1',
          canonicalHardwareId: 'CF:82:11:22:33:99',
          paired: true,
          connected: true,
          activated: false,
          lifecycleState: DeviceLifecycleState.paired,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await sdk.getDeviceStatus();

      final connectedWithoutCommand = await sdk.getOperationalDiagnostics();
      expect(connectedWithoutCommand.deviceSosAvailable, isFalse);
      expect(
        connectedWithoutCommand.currentSosCapabilityChannel,
        SosDeliveryChannel.backendOnly,
      );

      await deviceSosController.attach(
        commandWriter: (command) async {},
      );
      await Future<void>.delayed(Duration.zero);

      final connectedWithCommand = await sdk.getOperationalDiagnostics();
      expect(connectedWithCommand.deviceSosAvailable, isTrue);
      expect(
        connectedWithCommand.currentSosCapabilityChannel,
        SosDeliveryChannel.backendAndDevice,
      );
      expect(
        connectedWithCommand.currentSosCapabilityLabel,
        'backend + device',
      );
    });

    test(
        'getOperationalDiagnostics stays passive and does not trigger device-status emissions when nothing changed',
        () async {
      final emittedStatuses = <DeviceStatus>[];
      final subscription =
          deviceRepository.watchDeviceStatus().listen(emittedStatuses.add);

      try {
        await sdk.getOperationalDiagnostics();
        await sdk.getOperationalDiagnostics();
        await Future<void>.delayed(Duration.zero);

        expect(deviceRepository.refreshCallCount, 0);
        expect(emittedStatuses, isEmpty);
      } finally {
        await subscription.cancel();
      }
    });

    test('watchOperationalDiagnostics does not trigger a refresh loop',
        () async {
      final diagnosticsQueue = StreamQueue<SdkOperationalDiagnostics>(
        sdk.watchOperationalDiagnostics(),
      );

      try {
        final initial = await diagnosticsQueue.next;

        expect(initial.deviceSosAvailable, isFalse);
        expect(deviceRepository.refreshCallCount, 0);

        await Future<void>.delayed(Duration.zero);
        expect(deviceRepository.refreshCallCount, 0);
      } finally {
        await diagnosticsQueue.cancel();
      }
    });

    test(
        'passive SOS capability reads keep the last live connected device capability instead of rebuilding from a stale repository snapshot',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-passive-capability-1',
          canonicalHardwareId: 'CF:82:11:22:33:90',
          paired: true,
          connected: true,
          activated: true,
          lifecycleState: DeviceLifecycleState.ready,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await deviceSosController.attach(
        commandWriter: (command) async {},
      );
      await Future<void>.delayed(Duration.zero);

      final liveDiagnostics = await sdk.getOperationalDiagnostics();
      expect(
        liveDiagnostics.currentSosCapabilityChannel,
        SosDeliveryChannel.backendAndDevice,
      );

      deviceRepository.setCurrentStatusSilently(
        buildDeviceStatus(
          deviceId: 'ble-passive-capability-1',
          canonicalHardwareId: 'CF:82:11:22:33:90',
          paired: true,
          connected: false,
          activated: true,
          lifecycleState: DeviceLifecycleState.activated,
        ),
      );

      final passiveDiagnostics = await sdk.getOperationalDiagnostics();
      final passiveSosState = await sdk.getSosState();
      final watchedDiagnostics = await sdk.watchOperationalDiagnostics().first;

      expect(
        passiveDiagnostics.currentSosCapabilityChannel,
        SosDeliveryChannel.backendAndDevice,
      );
      expect(
        watchedDiagnostics.currentSosCapabilityChannel,
        SosDeliveryChannel.backendAndDevice,
      );
      expect(passiveSosState, SosState.idle);
      expect(deviceRepository.refreshCallCount, 0);
    });

    test(
        'operational diagnostics keep backend and device capability stable while the native protection runtime owns BLE',
        () async {
      final localRealtimeClient = FakeRealtimeClient()
        ..stateToEmitOnConnect = RealtimeConnectionState.connected;
      final localDeviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(
          deviceId: 'ble-native-owner-1',
          canonicalHardwareId: 'CF:82:11:22:33:91',
          paired: true,
          connected: false,
          activated: true,
          lifecycleState: DeviceLifecycleState.activated,
        ),
      );
      final localAdapter = _FakeProtectionPlatformAdapter(
        snapshot: const ProtectionPlatformSnapshot(
          backgroundCapabilityReady: true,
          platformRuntimeConfigured: true,
          platform: ProtectionPlatform.android,
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: true,
          serviceBleReady: true,
          coverageLevel: ProtectionCoverageLevel.full,
          runtimeState: ProtectionRuntimeState.active,
        ),
        startResult: const ProtectionPlatformStartResult(success: true),
      );
      final localSdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: localDeviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        protectionPlatformAdapter: localAdapter,
      );

      try {
        permissionsRepository.permissionState = const PermissionState(
          location: SdkPermissionStatus.granted,
          notifications: SdkPermissionStatus.granted,
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        );
        await localSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await localSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
          ),
        );
        final enterResult = await localSdk.enterProtectionMode();
        final initialDiagnostics = await localSdk.getOperationalDiagnostics();
        final watchedDiagnostics =
            await localSdk.watchOperationalDiagnostics().first;

        expect(enterResult.success, isTrue);
        expect(
          initialDiagnostics.currentSosCapabilityChannel,
          SosDeliveryChannel.backendAndDevice,
        );
        expect(
          watchedDiagnostics.currentSosCapabilityChannel,
          SosDeliveryChannel.backendAndDevice,
        );
        expect(initialDiagnostics.deviceSosAvailable, isTrue);
        expect(localDeviceRepository.refreshCallCount, 0);
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
        await localDeviceRepository.dispose();
      }
    });

    test(
        'triggerSos re-evaluates live device availability before choosing delivery channel',
        () async {
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
      );
      final disconnected = buildDeviceStatus(
        deviceId: 'ble-stale-trigger-1',
        canonicalHardwareId: 'CF:82:11:22:33:56',
        paired: true,
        connected: false,
        activated: true,
        lifecycleState: DeviceLifecycleState.activated,
      );
      final connected = disconnected.copyWith(
        connected: true,
        lifecycleState: DeviceLifecycleState.ready,
      );
      final commands = <String>[];

      deviceRepository.emitStatus(disconnected);
      await Future<void>.delayed(Duration.zero);
      deviceRepository.setCurrentStatusSilently(connected);
      await _attachObservedAppActivationWriter(
        deviceSosController,
        commandLabels: commands,
      );
      await Future<void>.delayed(Duration.zero);

      final incident = await sdk.triggerSos(
        const SosTriggerPayload(message: 'Need help'),
      );

      expect(deviceRepository.refreshCallCount, greaterThanOrEqualTo(1));
      expect(commands, contains('SOS TRIGGER APP'));
      expect(incident.deliveryChannel, SosDeliveryChannel.backendAndDevice);
    });

    test(
        'historical SOS delivery channel remains separate from current capability',
        () async {
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        ),
      );

      final backendOnlyIncident = await sdk.triggerSos(
        const SosTriggerPayload(message: 'Need help'),
      );
      expect(
        backendOnlyIncident.deliveryChannel,
        SosDeliveryChannel.backendOnly,
      );

      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-history-1',
          canonicalHardwareId: 'CF:82:11:22:33:AA',
          paired: true,
          connected: true,
          activated: false,
          lifecycleState: DeviceLifecycleState.paired,
        ),
      );
      await sdk.getDeviceStatus();
      await deviceSosController.attach(
        commandWriter: (command) async {},
      );
      await Future<void>.delayed(Duration.zero);

      final diagnostics = await sdk.getOperationalDiagnostics();
      expect(
        diagnostics.currentSosCapabilityChannel,
        SosDeliveryChannel.backendAndDevice,
      );
      expect(
        diagnostics.lastPublicSosDeliveryChannel,
        SosDeliveryChannel.backendOnly,
      );
    });

    test(
        'mqtt-backed cancel settles immediately from backend cancel response and emits cancelled event',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..cancelResult = SosIncidentDto(
          id: 'sos-1',
          state: 'cancelled',
          createdAt: '2026-03-30T12:00:00.000Z',
        );
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
        deviceRegistryRepository: deviceRegistryRepository,
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
        await repository.triggerSos(
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
        await Future<void>.delayed(Duration.zero);

        expect(cancelResult.state, SosState.cancelled);
        expect(events.whereType<SOSCancelledEvent>(), hasLength(1));

        expect(
          events.whereType<SOSCancelledEvent>().single.incidentId,
          cancelResult.id,
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
        deviceRegistryRepository: deviceRegistryRepository,
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
        deviceRegistryRepository: deviceRegistryRepository,
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
        expect(
            localRealtimeClient.disconnectCallCount, greaterThanOrEqualTo(1));
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
      }
    });

    test('initialize rehydrates SOS state from backend-backed runtime state',
        () async {
      final localSessionStore =
          SdkSessionStore(localStore: MemorySharedPrefsSdkStore());
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSosRepository = FakeRehydratingSosRepository()
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.hydratedFromBackend,
          resultingState: SosState.acknowledged,
        );
      final localSdk = EixamConnectSdkImpl(
        sosRepository: localSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
        sessionStore: localSessionStore,
      );

      try {
        await localSessionStore.save(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
          ),
        );

        await localSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );

        expect(localSosRepository.rehydrateCallCount, 1);
        expect(await localSdk.getSosState(), SosState.acknowledged);
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
        await localSosRepository.dispose();
      }
    });

    test(
        'setSession bootstraps and stores canonical external user id from /v1/sdk/me',
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
        deviceRegistryRepository: deviceRegistryRepository,
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
        expect(
            capturedRequest.url.toString(), 'https://example.test/v1/sdk/me');
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
        'setSession clears stale local SOS state when backend reports no incident',
        () async {
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSosRepository = FakeRehydratingSosRepository()
        ..currentIncident = _testSosIncident(state: SosState.sent)
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
        );
      final localSdk = EixamConnectSdkImpl(
        sosRepository: localSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        await localSdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'external-123',
            userHash: 'deadbeef',
          ),
        );

        expect(localSosRepository.rehydrateCallCount, 1);
        expect(await localSdk.getSosState(), SosState.idle);
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
        await localSosRepository.dispose();
      }
    });

    test('refreshCanonicalIdentity updates the current canonical identity',
        () async {
      final localStore = MemorySharedPrefsSdkStore();
      final localSessionStore = SdkSessionStore(localStore: localStore);
      final localSessionContext = SdkSessionContext();
      late http.Request capturedRequest;
      final client = _RecordingClient(
        handler: (request) async {
          capturedRequest = request;
          return http.Response(
            '{"user":{"id":"sdk-user-99","external_user_id":"canonical-user-99"}}',
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
        deviceRegistryRepository: deviceRegistryRepository,
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
            canonicalExternalUserId: 'stale-canonical',
          ),
        );

        final refreshed = await localSdk.refreshCanonicalIdentity();
        final persisted = await localSessionStore.load();

        expect(
            capturedRequest.url.toString(), 'https://example.test/v1/sdk/me');
        expect(refreshed.canonicalExternalUserId, 'canonical-user-99');
        expect(localSessionContext.currentSession?.sdkUserId, 'sdk-user-99');
        expect(persisted?.canonicalExternalUserId, 'canonical-user-99');
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

    test(
        'mqtt realtime composes username/password auth and canonical encoded event topics',
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

        expect(capturedRequest.username, 'sdk:app-demo:external-123');
        expect(capturedRequest.password, 'deadbeef');
        expect(capturedRequest.cleanSession, isTrue);
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
          deviceId: 'hw-1',
        );

        expect(incident.state, SosState.sent);
        expect(realtimeClient.publishedRequests, hasLength(1));
        expect(realtimeClient.publishedRequests.single.deviceId, 'hw-1');
        final envelope = SdkMqttContract.buildOperationalSosEnvelope(
          realtimeClient.publishedRequests.single,
        );
        expect(envelope.topic, SdkMqttTopics.sosAlerts);
        expect(envelope.payload, contains('"deviceId":"hw-1"'));
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test('http trigger path includes deviceId when paired hardware id exists',
        () async {
      late http.Request capturedRequest;
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient(
            handler: (request) async {
              capturedRequest = request;
              return http.Response(
                '{"incident":{"id":"sos-1","state":"sent","createdAt":"2026-03-30T12:00:00.000Z"}}',
                200,
              );
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

      await dataSource.triggerSos(
        triggerSource: 'button_ui',
        positionSnapshot: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          altitude: 8,
          timestamp: DateTime.utc(2026, 3, 30, 12),
        ),
        deviceId: 'hw-1',
      );

      expect(capturedRequest.method, 'POST');
      expect(capturedRequest.url.toString(),
          'https://api.example.test/v1/sdk/sos');
      expect(capturedRequest.body, contains('"deviceId":"hw-1"'));
      expect(capturedRequest.headers['Authorization'], 'Bearer deadbeef');
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

    test(
        'http resolve path posts to /v1/sdk/sos/resolve without a request body',
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

      await dataSource.resolveSos();

      expect(capturedRequest.method, 'POST');
      expect(
        capturedRequest.url.toString(),
        'https://api.example.test/v1/sdk/sos/resolve',
      );
      expect(capturedRequest.body, isEmpty);
      expect(capturedRequest.headers['X-App-ID'], 'app-demo');
      expect(capturedRequest.headers['X-User-ID'], 'external-123');
      expect(capturedRequest.headers['Authorization'], 'Bearer deadbeef');
    });

    test('http resolve path propagates backend failure', () async {
      final dataSource = HttpSosRemoteDataSource(
        transport: SdkHttpTransport(
          client: _RecordingClient(
            handler: (_) async => http.Response('backend exploded', 500),
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

      await expectLater(
        dataSource.resolveSos(),
        throwsA(
          isA<SosException>()
              .having(
                  (error) => error.code, 'code', 'E_HTTP_SOS_RESOLVE_FAILED')
              .having((error) => error.message, 'message', 'backend exploded'),
        ),
      );
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
        deviceRegistryRepository: deviceRegistryRepository,
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
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..cancelResult = SosIncidentDto(
          id: 'sos-1',
          state: 'cancelled',
          createdAt: '2026-03-30T12:00:00.000Z',
        );
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
      );

      try {
        await repository.triggerSos(
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
        expect(cancelled.state, SosState.cancelled);

        expect(await repository.getSosState(), SosState.cancelled);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test(
        'mqtt cancel settles from backend rehydration when cancel returns null',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..activeAfterCancelResult = SosIncidentDto(
          id: 'sos-1',
          state: 'resolved',
          createdAt: '2026-03-30T12:00:00.000Z',
        );
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
      );

      try {
        await repository.triggerSos(
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
        expect(cancelDataSource.getActiveCallCount, 1);
        expect(cancelled.state, SosState.resolved);
        expect(await repository.getSosState(), SosState.resolved);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test(
        'mqtt resolve settles from backend rehydration when resolve returns null',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..activeAfterResolveResult = SosIncidentDto(
          id: 'sos-1',
          state: 'resolved',
          createdAt: '2026-03-30T12:00:00.000Z',
        );
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
      );

      try {
        await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        final resolved = await repository.resolveSos();

        expect(cancelDataSource.resolveCallCount, 1);
        expect(cancelDataSource.getActiveCallCount, 1);
        expect(resolved.state, SosState.resolved);
        expect(await repository.getSosState(), SosState.resolved);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test(
        'mqtt resolve keeps backend-active state when resolve does not persist remotely',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..activeAfterResolveResult = SosIncidentDto(
          id: 'sos-1',
          state: 'sent',
          createdAt: '2026-03-30T12:00:00.000Z',
        );
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
      );

      try {
        await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        final resolved = await repository.resolveSos();

        expect(cancelDataSource.resolveCallCount, 1);
        expect(cancelDataSource.getActiveCallCount, 1);
        expect(resolved.state, SosState.sent);
        expect(await repository.getSosState(), SosState.sent);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test(
        'mqtt SOS keeps a recent local incident when backend is briefly inconsistent after trigger',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      var now = DateTime.utc(2026, 3, 30, 12, 0, 0);
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..backendLagAfterTriggerReads = 1;
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
        destructiveRehydrationGracePeriod: const Duration(seconds: 5),
        nowProvider: () => now,
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

        // The backend can briefly return null after the MQTT publish even
        // though the incident becomes visible shortly after.
        now = now.add(const Duration(seconds: 2));
        final current = await repository.getCurrentIncident();

        expect(current?.id, incident.id);
        expect(current?.state, SosState.sent);
        expect(await repository.getSosState(), SosState.sent);
        expect(cancelDataSource.getActiveCallCount, 1);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test(
        'mqtt cancel recovers after a refresh gap when backend incident appears on retry',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      var now = DateTime.utc(2026, 3, 30, 12, 0, 0);
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..cancelResult = SosIncidentDto(
          id: 'sos-1',
          state: 'cancelled',
          createdAt: '2026-03-30T12:00:00.000Z',
        )
        ..backendLagAfterTriggerReads = 1;
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
        destructiveRehydrationGracePeriod: Duration.zero,
        nowProvider: () => now,
      );

      try {
        await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        now = now.add(const Duration(seconds: 1));
        expect(await repository.getCurrentIncident(), isNull);

        // Cancellation retries one backend rehydrate before failing, so the
        // delayed backend incident can still recover the flow.
        final cancelled = await repository.cancelSos();

        expect(cancelled.state, SosState.cancelled);
        expect(cancelDataSource.getActiveCallCount, 2);
        expect(cancelDataSource.cancelCallCount, 1);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test(
        'mqtt SOS clears stale local state after the grace window when backend remains null',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      var now = DateTime.utc(2026, 3, 30, 12, 0, 0);
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..activeIncident = null;
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
        destructiveRehydrationGracePeriod: const Duration(seconds: 5),
        nowProvider: () => now,
      );

      try {
        await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        // After the grace window, a null backend read is treated as
        // authoritative and the runtime returns to idle.
        now = now.add(const Duration(seconds: 6));
        expect(await repository.getCurrentIncident(), isNull);
        expect(await repository.getSosState(), SosState.idle);
      } finally {
        await repository.dispose();
        await realtimeClient.dispose();
      }
    });

    test(
        'mqtt cancel throws only after recovery also confirms there is no active incident',
        () async {
      final realtimeClient = _FakeOperationalRealtimeClient();
      var now = DateTime.utc(2026, 3, 30, 12, 0, 0);
      final cancelDataSource = _FakeCancelSosRemoteDataSource()
        ..activeIncident = null;
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: cancelDataSource,
        destructiveRehydrationGracePeriod: Duration.zero,
        nowProvider: () => now,
      );

      try {
        await repository.triggerSos(
          message: 'Need help',
          triggerSource: 'button_ui',
          positionSnapshot: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            altitude: 8,
            timestamp: DateTime.utc(2026, 3, 30, 12),
          ),
        );

        now = now.add(const Duration(seconds: 1));
        expect(await repository.getCurrentIncident(), isNull);

        await expectLater(
          repository.cancelSos(),
          throwsA(
            isA<SosException>().having(
              (error) => error.code,
              'code',
              'E_SOS_CANCEL_NOT_ALLOWED',
            ),
          ),
        );
        expect(cancelDataSource.getActiveCallCount, 2);
        expect(cancelDataSource.cancelCallCount, 0);
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
      expect(envelope.payload,
          '{"timestamp":"2026-03-31T10:15:00.000Z","latitude":41.38,"longitude":2.17,"altitude":8.0,"userId":"sdk-user-42","deviceId":"device-1","deviceBattery":77.5,"deviceCoverage":4,"mobileBattery":61.0,"mobileCoverage":3}');
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

    test(
        'refreshCanonicalIdentity keeps local SOS fallback and exposes a diagnostics note when rehydration fails',
        () async {
      final localStore = MemorySharedPrefsSdkStore();
      final localSessionStore = SdkSessionStore(localStore: localStore);
      final localSessionContext = SdkSessionContext();
      final client = _RecordingClient(
        handler: (request) async {
          return http.Response(
            '{"user":{"id":"sdk-user-99","external_user_id":"canonical-user-99"}}',
            200,
            headers: const <String, String>{
              'content-type': 'application/json',
            },
          );
        },
      );
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localSosRepository = FakeRehydratingSosRepository()
        ..currentIncident = _testSosIncident(state: SosState.sent)
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
          resultingState: SosState.sent,
          diagnosticNote: 'SOS rehydration failed; kept local fallback state.',
        );
      final localSdk = EixamConnectSdkImpl(
        sosRepository: localSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
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
            canonicalExternalUserId: 'stale-canonical',
          ),
        );

        final refreshed = await localSdk.refreshCanonicalIdentity();
        final diagnostics = await localSdk.getOperationalDiagnostics();

        expect(refreshed.canonicalExternalUserId, 'canonical-user-99');
        expect(localSosRepository.rehydrateCallCount, 2);
        expect(await localSdk.getSosState(), SosState.sent);
        expect(
          diagnostics.sosRehydrationNote,
          'SOS rehydration failed; kept local fallback state.',
        );
      } finally {
        await localSdk.dispose();
        await localRealtimeClient.dispose();
        await localSosRepository.dispose();
      }
    });

    test('BLE bridge publishes telemetry from TEL position events', () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        bleEvents.add(_bridgeTelEvent(signature: 'tel-1'));
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, hasLength(1));
        expect(
          telemetryRepository.publishedPayloads.single.deviceId,
          'CF:82:99:88:77:66',
        );
        expect(
          telemetryRepository.publishedPayloads.single.deviceBattery,
          isNull,
        );
        expect(
          telemetryRepository.publishedPayloads.single.deviceCoverage,
          isNull,
        );
        expect(
          telemetryRepository.publishedPayloads.single.mobileBattery,
          isNull,
        );
        expect(
          telemetryRepository.publishedPayloads.single.mobileCoverage,
          isNull,
        );
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge omits deviceId for TEL aggregate payloads when no backend hardware id is resolved',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
        backendHardwareIdResolver: (_) async => null,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        bleEvents.add(
          _bridgeAggregateTelCompleteEvent(
            signature: 'agg-tel-1',
            canonicalHardwareId: null,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, hasLength(1));
        expect(telemetryRepository.publishedPayloads.single.deviceId, isNull);
        expect(
          telemetryRepository.publishedPayloads.single.deviceBattery,
          isNull,
        );
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge observes SOS packets without creating backend incident while runtime is still preConfirm',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        bleEvents.add(_bridgeSosEvent(signature: 'sos-1'));
        await Future<void>.delayed(Duration.zero);

        expect(sosRepository.triggerCallCount, 0);
        expect(
          bridge.currentDiagnostics.lastDecision,
          'SOS observed only: backend lifecycle now waits for device SOS status to become active',
        );
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge does not create backend incident from raw device packets even before realtime reports connected',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        bleEvents.add(_bridgeSosEvent(signature: 'sos-no-rt-1'));
        await Future<void>.delayed(Duration.zero);

        expect(sosRepository.triggerCallCount, 0);
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test('BLE bridge skips publish when minimum fields are missing', () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        bleEvents.add(_bridgeInvalidTelEvent(signature: 'tel-invalid'));
        bleEvents.add(_bridgeSosWithoutPositionEvent(signature: 'sos-min'));
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, isEmpty);
        expect(sosRepository.triggerCallCount, 0);
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test('BLE bridge does not publish incomplete TEL aggregate fragments',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        bleEvents
            .add(_bridgeAggregateTelFragmentEvent(signature: 'agg-frag-1'));
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, isEmpty);
        expect(
          bridge.currentDiagnostics.lastDecision,
          'TEL aggregate fragment buffered in BLE runtime',
        );
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge leaves an explicit diagnostic when aggregate payload is unsupported',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        bleEvents.add(
          _bridgeUnsupportedAggregateTelCompleteEvent(signature: 'agg-big-1'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, isEmpty);
        expect(
          bridge.currentDiagnostics.lastDecision,
          'TEL aggregate completed but not published: aggregate payload does not fit current telemetry contract',
        );
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge applies backend confirmations to local-origin SOS commands',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: controller,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        await controller.triggerSos();
        await controller.confirmSos();

        realtimeEvents.add(
          RealtimeEvent(
            type: 'position_confirmed',
            timestamp: DateTime.utc(2026, 3, 31, 10),
            payload: const <String, dynamic>{'type': 'position_confirmed'},
          ),
        );
        realtimeEvents.add(
          RealtimeEvent(
            type: 'sos_ack',
            timestamp: DateTime.utc(2026, 3, 31, 10, 1),
            payload: const <String, dynamic>{
              'type': 'sos_ack',
              'incidentId': 'sos-1',
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(commands.map((command) => command.opcode), contains(0x03));
        expect(commands.map((command) => command.opcode), contains(0x07));
        expect(
            commands.map((command) => command.opcode), isNot(contains(0x08)));
      } finally {
        await bridge.dispose();
        await controller.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge transforms backend SOS ack into SOS_ACK_RELAY for active relay SOS context',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: controller,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        controller.handleIncomingSosPacket(
          _relayedSosPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await Future<void>.delayed(const Duration(milliseconds: 70));

        realtimeEvents.add(
          RealtimeEvent(
            type: 'sos_ack',
            timestamp: DateTime.utc(2026, 3, 31, 10, 1),
            payload: const <String, dynamic>{
              'type': 'sos_ack',
              'incidentId': 'sos-relay-1',
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(commands.map((command) => command.opcode), contains(0x08));
        expect(
          commands.where((command) => command.opcode == 0x08).single.bytes,
          <int>[0x08, 0x34, 0x12],
        );
        expect(
          bridge.currentDiagnostics.lastDecision,
          'Backend SOS acknowledgment transformed to SOS_ACK_RELAY using active relay context',
        );
      } finally {
        await bridge.dispose();
        await controller.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge accepts explicit relay ack only when it matches the active relay SOS context',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: controller,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        controller.handleIncomingSosPacket(
          _relayedSosPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await Future<void>.delayed(const Duration(milliseconds: 70));

        realtimeEvents.add(
          RealtimeEvent(
            type: 'sos_ack_relay',
            timestamp: DateTime.utc(2026, 3, 31, 10, 2),
            payload: const <String, dynamic>{
              'type': 'sos_ack_relay',
              'relayNodeId': 0x1234,
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(commands.map((command) => command.opcode), contains(0x08));
      } finally {
        await bridge.dispose();
        await controller.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge ignores explicit relay ack when active SOS context is local-origin',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: controller,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        await controller.triggerSos();
        await controller.confirmSos();

        realtimeEvents.add(
          RealtimeEvent(
            type: 'sos_ack_relay',
            timestamp: DateTime.utc(2026, 3, 31, 10, 2),
            payload: const <String, dynamic>{
              'type': 'sos_ack_relay',
              'relayNodeId': 0x1234,
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
            commands.map((command) => command.opcode), isNot(contains(0x08)));
        expect(
          bridge.currentDiagnostics.lastDecision,
          'Backend relay acknowledgment ignored: active SOS was triggered locally by the app',
        );
      } finally {
        await bridge.dispose();
        await controller.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE bridge ignores relay ack when backend relay node id does not match the active relay SOS context',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: controller,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        controller.handleIncomingSosPacket(
          _relayedSosPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await Future<void>.delayed(const Duration(milliseconds: 70));

        realtimeEvents.add(
          RealtimeEvent(
            type: 'sos_ack_relay',
            timestamp: DateTime.utc(2026, 3, 31, 10, 2),
            payload: const <String, dynamic>{
              'type': 'sos_ack_relay',
              'relayNodeId': 0x9999,
            },
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
            commands.map((command) => command.opcode), isNot(contains(0x08)));
        expect(
          bridge.currentDiagnostics.lastDecision,
          'Backend relay acknowledgment ignored: relay node id does not match the active relay SOS context',
        );
      } finally {
        await bridge.dispose();
        await controller.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test('BLE bridge deduplicates overlapping TEL and SOS publishes', () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.connected);
        final telEvent = _bridgeTelEvent(signature: 'dup-tel');
        final sosEvent = _bridgeSosEvent(signature: 'dup-sos');
        bleEvents.add(telEvent);
        bleEvents.add(telEvent);
        bleEvents.add(sosEvent);
        bleEvents.add(sosEvent);
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, hasLength(1));
        expect(sosRepository.triggerCallCount, 0);
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE TEL while MQTT disconnected retains only the latest pending telemetry and publishes once on reconnect',
        () async {
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: sosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.disconnected);
        bleEvents.add(
          _bridgeTelEvent(
            signature: 'pending-tel-1',
            canonicalHardwareId: null,
          ),
        );
        bleEvents.add(
          _bridgeTelEvent(
            signature: 'pending-tel-2',
            canonicalHardwareId: null,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, isEmpty);

        connectionStates.add(RealtimeConnectionState.connected);
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, hasLength(1));
        expect(telemetryRepository.publishedPayloads.single.deviceId, isNull);
        expect(
          telemetryRepository.publishedPayloads.single.deviceBattery,
          isNull,
        );
        expect(
          telemetryRepository.publishedPayloads.single.timestamp,
          DateTime.utc(2026, 3, 31, 10),
        );
      } finally {
        await bridge.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'BLE SOS while MQTT disconnected remains observational and is not published from raw packets on reconnect',
        () async {
      final unavailableSosRepository = _AvailabilityAwareSosRepository();
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: unavailableSosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.reconnecting);
        bleEvents.add(_bridgeSosEvent(signature: 'pending-sos-1'));
        bleEvents.add(_bridgeSosEvent(signature: 'pending-sos-1'));
        await Future<void>.delayed(Duration.zero);

        expect(unavailableSosRepository.triggerCallCount, 0);

        unavailableSosRepository.isTriggerAvailable = true;
        connectionStates.add(RealtimeConnectionState.connected);
        await Future<void>.delayed(Duration.zero);

        expect(unavailableSosRepository.triggerCallCount, 0);
      } finally {
        await bridge.dispose();
        await unavailableSosRepository.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'clearSession-style teardown clears pending operational items and prevents replay',
        () async {
      final unavailableSosRepository = _AvailabilityAwareSosRepository();
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: unavailableSosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.disconnected);
        bleEvents.add(_bridgeTelEvent(signature: 'clear-tel'));
        bleEvents.add(_bridgeSosEvent(signature: 'clear-sos'));
        await Future<void>.delayed(Duration.zero);

        bridge.clearPendingOperationalItems();
        session = null;
        connectionStates.add(RealtimeConnectionState.connected);
        await Future<void>.delayed(Duration.zero);

        expect(telemetryRepository.publishedPayloads, isEmpty);
        expect(unavailableSosRepository.triggerCallCount, 0);
      } finally {
        await bridge.dispose();
        await unavailableSosRepository.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
      }
    });

    test(
        'session change clears old observational SOS state and does not publish raw SOS packets after reuse',
        () async {
      final unavailableSosRepository = _AvailabilityAwareSosRepository();
      final bleEvents = StreamController<BleIncomingEvent>.broadcast();
      final connectionStates =
          StreamController<RealtimeConnectionState>.broadcast();
      final realtimeEvents = StreamController<RealtimeEvent>.broadcast();
      EixamSession? session = const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final bridge = BleOperationalRuntimeBridge(
        bleIncomingEvents: bleEvents.stream,
        connectionStates: connectionStates.stream,
        realtimeEvents: realtimeEvents.stream,
        telemetryRepository: telemetryRepository,
        sosRepository: unavailableSosRepository,
        deviceSosController: deviceSosController,
        sessionProvider: () => session,
      )..start();

      try {
        connectionStates.add(RealtimeConnectionState.disconnected);
        bleEvents.add(_bridgeSosEvent(signature: 'old-session-sos'));
        await Future<void>.delayed(Duration.zero);

        bridge.resetForSessionChange();
        session = const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-999',
          userHash: 'beadfeed',
        );
        unavailableSosRepository.isTriggerAvailable = true;
        bleEvents.add(_bridgeSosEvent(signature: 'new-session-sos'));
        connectionStates.add(RealtimeConnectionState.connected);
        await Future<void>.delayed(Duration.zero);

        expect(unavailableSosRepository.triggerCallCount, 0);
      } finally {
        await bridge.dispose();
        await unavailableSosRepository.dispose();
        await bleEvents.close();
        await connectionStates.close();
        await realtimeEvents.close();
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

      expect(requests[0].url.toString(),
          'https://api.example.test/v1/sdk/devices');
      expect(
        requests[0].body,
        '{"hardware_id":"hw-1","firmware_version":"1.2.3","hardware_model":"EIXAM R1","paired_at":"2026-03-31T09:00:00.000Z"}',
      );
      expect(requests[1].url.toString(),
          'https://api.example.test/v1/sdk/devices');
      expect(requests[2].url.toString(),
          'https://api.example.test/v1/sdk/devices/device-1');
      expect(upserted.hardwareId, 'hw-1');
      expect(upserted.hardwareModel, 'EIXAM R1');
      expect(listed.single.firmwareVersion, '1.2.3');
    });

    test(
        'device registry mapper keeps backend records separate from runtime status',
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

    test(
        'contacts HTTP datasource matches OpenAPI request and response mapping',
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

      expect(requests[0].url.toString(),
          'https://api.example.test/v1/sdk/contacts');
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

    test('mqtt telemetry publish surfaces transport failures', () async {
      final sessionContext = SdkSessionContext()
        ..currentSession = const EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
          sdkUserId: 'sdk-user-42',
          canonicalExternalUserId: 'partner/user 42',
        );
      final mqttClient = MqttRealtimeClient(
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          websocketUrl: 'wss://mqtt.example.test/mqtt',
        ),
        sessionContext: sessionContext,
        transportFactory: (_) => _FakeSdkMqttTransport(
          publishError: StateError('publish failed'),
        ),
      );

      try {
        await expectLater(
          mqttClient.publishTelemetry(
            SdkTelemetryPayload(
              timestamp: DateTime.utc(2026, 3, 31, 10, 15),
              latitude: 41.38,
              longitude: 2.17,
              altitude: 8,
              deviceId: 'device-1',
            ),
          ),
          throwsA(isA<StateError>()),
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
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: localNotificationsRepository,
        realtimeClient: realtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: preferredDeviceStore,
      );

      try {
        permissionsRepository.permissionState = const PermissionState(
          location: SdkPermissionStatus.granted,
        );
        await localSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );

        localDeviceSosController.handleIncomingSosPacket(
          _deviceOriginPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(sosRepository.triggerCallCount, 0);

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

        expect(sosRepository.triggerCallCount, 1);
        expect(sosRepository.lastTriggerSource, 'ble_device_runtime_status');
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

    test(
        'confirmDeviceSos creates backend incident for a device-originated SOS cycle when none exists yet',
        () async {
      deviceRepository.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-confirm-1',
          canonicalHardwareId: 'CF:82:00:00:00:01',
          paired: true,
          connected: true,
          activated: true,
        ),
      );
      await deviceSosController.attach(
        commandWriter: (command) async {},
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPacket(),
        source: DeviceSosTransitionSource.device,
      );

      await sdk.confirmDeviceSos();

      expect(sosRepository.triggerCallCount, 1);
      expect(sosRepository.lastTriggerSource, 'ble_device_runtime_confirm');
      expect(sosRepository.lastPositionSnapshot?.latitude, 41.38);
      expect(sosRepository.lastDeviceId, 'CF:82:00:00:00:01');
      expect(sosRepository.lastDeviceId, isNot('ble-confirm-1'));
    });

    test(
        'device-originated SOS promotion buffers in bridge diagnostics when backend publish is temporarily unavailable',
        () async {
      final unavailableSosRepository = _AvailabilityAwareSosRepository();
      final localDeviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(
          connected: false,
          lifecycleState: DeviceLifecycleState.unpaired,
          paired: false,
          activated: false,
        ),
      );
      final localDeviceRegistryRepository = FakeSdkDeviceRegistryRepository();
      final localRealtimeClient = FakeRealtimeClient();
      final localDeviceSosController = DeviceSosController();
      final localPreferredStore = PreferredBleDeviceStore(
        localStore: MemorySharedPrefsSdkStore(),
      );
      final localSdk = EixamConnectSdkImpl(
        sosRepository: unavailableSosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: localDeviceRepository,
        deviceRegistryRepository: localDeviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: localRealtimeClient,
        deviceSosController: localDeviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: localPreferredStore,
      );

      try {
        localDeviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-confirm-1',
            canonicalHardwareId: 'CF:82:00:00:00:02',
            paired: true,
            connected: true,
            activated: true,
          ),
        );
        await localSdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await localDeviceSosController.attach(
          commandWriter: (command) async {},
        );

        localDeviceSosController.handleIncomingSosPacket(
          _deviceOriginPacket(),
          source: DeviceSosTransitionSource.device,
        );

        await localSdk.confirmDeviceSos();
        await Future<void>.delayed(Duration.zero);
        final diagnostics = await localSdk.getOperationalDiagnostics();

        expect(diagnostics.bridge.pendingSos, isNotNull);
        expect(
          diagnostics.bridge.lastDecision,
          'SOS buffered after publish failure',
        );
      } finally {
        await localSdk.dispose();
        await unavailableSosRepository.dispose();
        await localDeviceRepository.dispose();
      }
    });

    test(
        'confirmDeviceSos does not create a duplicate backend incident when device-originated SOS is already synced',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
      );
      await deviceSosController.attach(
        commandWriter: (command) async {},
      );
      sosRepository.currentIncident = sosRepository.currentIncident.copyWith(
        state: SosState.sent,
        triggerSource: 'ble_device_runtime',
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPacket(),
        source: DeviceSosTransitionSource.device,
      );

      await sdk.confirmDeviceSos();

      expect(sosRepository.triggerCallCount, 0);
    });

    test(
        'device-originated closure cancels backend incident automatically when status closes',
        () async {
      permissionsRepository.permissionState = const PermissionState(
        location: SdkPermissionStatus.granted,
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
      sosRepository.currentIncident = sosRepository.currentIncident.copyWith(
        state: SosState.sent,
        triggerSource: 'ble_device_runtime_status',
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPacket(),
        source: DeviceSosTransitionSource.device,
      );
      deviceSosController.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(<int>[0xE1, 0x02, 0x34, 0x12])!,
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(Duration.zero);

      expect(sosRepository.cancelCallCount, 1);
      expect(sosRepository.currentIncident.state, SosState.cancelled);
    });

    test(
        'cancelDeviceSos cancels the backend incident for a device-originated SOS cycle',
        () async {
      await deviceSosController.attach(
        commandWriter: (command) async {},
      );
      sosRepository.currentIncident = sosRepository.currentIncident.copyWith(
        state: SosState.sent,
        triggerSource: 'ble_device_runtime',
      );

      deviceSosController.handleIncomingSosPacket(
        _deviceOriginPacket(),
        source: DeviceSosTransitionSource.device,
      );

      await sdk.cancelDeviceSos();

      expect(sosRepository.cancelCallCount, 1);
      expect(sosRepository.currentIncident.state, SosState.cancelled);
    });

    test(
        'confirmDeviceSos keeps app-originated device cycles local and does not create backend SOS implicitly',
        () async {
      await deviceSosController.attach(
        commandWriter: (command) async {},
      );

      await sdk.triggerDeviceSos();
      await sdk.confirmDeviceSos();

      expect(sosRepository.triggerCallCount, 0);
      expect(sosRepository.cancelCallCount, 0);
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

class _FakeProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  _FakeProtectionPlatformAdapter({
    required this.snapshot,
    required this.startResult,
    this.platformEvents = const Stream<ProtectionPlatformEvent>.empty(),
    this.commandResult = const ProtectionPlatformCommandResult(success: true),
    List<ProtectionPlatformCommandResult>? queuedCommandResults,
    this.onSendCommand,
  }) : queuedCommandResults =
            queuedCommandResults ?? <ProtectionPlatformCommandResult>[];

  ProtectionPlatformSnapshot snapshot;
  final ProtectionPlatformStartResult startResult;
  final Stream<ProtectionPlatformEvent> platformEvents;
  ProtectionPlatformCommandResult commandResult;
  final List<ProtectionPlatformCommandResult> queuedCommandResults;
  final FutureOr<void> Function(ProtectionPlatformCommandRequest request)?
      onSendCommand;
  int startCallCount = 0;
  int stopCallCount = 0;
  int ensureActiveCallCount = 0;
  int flushCallCount = 0;
  int sendCommandCallCount = 0;
  final List<ProtectionPlatformCommandRequest> commandRequests =
      <ProtectionPlatformCommandRequest>[];
  ProtectionPlatformStartRequest? lastStartRequest;
  String? lastEnsureActiveReason;
  ProtectionPlatformCommandRequest? lastCommandRequest;

  @override
  ProtectionPlatform get platform => snapshot.platform;

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async => snapshot;

  @override
  Future<ProtectionPlatformStartResult> startProtectionRuntime({
    required ProtectionPlatformStartRequest request,
  }) async {
    startCallCount++;
    lastStartRequest = request;
    return startResult;
  }

  @override
  Future<void> stopProtectionRuntime() async {
    stopCallCount++;
  }

  @override
  Future<void> ensureProtectionRuntimeActive({
    String reason = 'app_foreground_resume',
  }) async {
    ensureActiveCallCount++;
    lastEnsureActiveReason = reason;
  }

  @override
  Future<ProtectionPlatformFlushResult> flushProtectionQueues() async {
    flushCallCount++;
    return const ProtectionPlatformFlushResult();
  }

  @override
  Future<ProtectionPlatformCommandResult> sendProtectionCommand({
    required ProtectionPlatformCommandRequest request,
  }) async {
    sendCommandCallCount++;
    lastCommandRequest = request;
    commandRequests.add(request);
    await onSendCommand?.call(request);
    if (queuedCommandResults.isNotEmpty) {
      return queuedCommandResults.removeAt(0);
    }
    return commandResult;
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

Future<void> _attachObservedAppActivationWriter(
  DeviceSosController controller, {
  List<String>? commandLabels,
  List<int>? closeAckPacket,
}) {
  return controller.attach(
    commandWriter: (command) async {
      commandLabels?.add(command.label);
      if (command.opcode == 0x06) {
        Future<void>.delayed(const Duration(milliseconds: 5), () {
          controller.handleIncomingSosPacket(
            _deviceOriginPacket(),
            source: DeviceSosTransitionSource.device,
          );
        });
      }
      if (command.opcode == 0x05) {
        Future<void>.delayed(const Duration(milliseconds: 5), () {
          controller.handleIncomingSosPacket(
            _deviceOriginPacket(),
            source: DeviceSosTransitionSource.device,
          );
        });
      }
      if (command.opcode == 0x04 && closeAckPacket != null) {
        Future<void>.delayed(const Duration(milliseconds: 5), () {
          controller.handleIncomingSosEventPacket(
            EixamSosEventPacket.tryParse(closeAckPacket)!,
            source: DeviceSosTransitionSource.device,
          );
        });
      }
    },
  );
}

class _FakeSdkMqttTransport implements SdkMqttTransport {
  _FakeSdkMqttTransport({this.connectCompleter, this.publishError});

  final Completer<void>? connectCompleter;
  final Object? publishError;
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
    if (publishError != null) {
      throw publishError!;
    }
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
  final List<SdkTelemetryPayload> publishedTelemetry = <SdkTelemetryPayload>[];
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
  int resolveCallCount = 0;
  int getActiveCallCount = 0;
  SosIncidentDto? cancelResult;
  SosIncidentDto? resolveResult;
  SosIncidentDto? activeAfterCancelResult;
  SosIncidentDto? activeAfterResolveResult;
  int backendLagAfterTriggerReads = 0;
  SosIncidentDto? activeIncident = SosIncidentDto(
    id: 'sos-1',
    state: 'sent',
    createdAt: '2026-03-30T12:00:00.000Z',
  );

  @override
  Future<SosIncidentDto?> cancelSos() async {
    cancelCallCount++;
    activeIncident = cancelResult;
    return cancelResult;
  }

  @override
  Future<SosIncidentDto?> resolveSos() async {
    resolveCallCount++;
    activeIncident = resolveResult;
    return resolveResult;
  }

  @override
  Future<SosIncidentDto?> getActiveSos() async {
    getActiveCallCount++;
    if (backendLagAfterTriggerReads > 0) {
      backendLagAfterTriggerReads--;
      return null;
    }
    return activeAfterCancelResult ??
        activeAfterResolveResult ??
        activeIncident;
  }

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
  }) async {
    activeIncident = SosIncidentDto(
      id: 'sos-1',
      state: 'sent',
      createdAt: '2026-03-30T12:00:00.000Z',
    );
    return activeIncident!;
  }
}

class _AvailabilityAwareSosRepository extends FakeSosRepository {
  bool isTriggerAvailable = false;
  bool isCancelAvailable = false;
  bool isResolveAvailable = false;

  @override
  Future<SosIncident> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
  }) async {
    if (!isTriggerAvailable) {
      throw const SosException(
        'E_MQTT_NOT_CONNECTED',
        'Operational SOS transport is not connected yet.',
      );
    }
    return super.triggerSos(
      message: message,
      triggerSource: triggerSource,
      positionSnapshot: positionSnapshot,
      deviceId: deviceId,
    );
  }

  @override
  Future<SosIncident> cancelSos() async {
    if (!isCancelAvailable) {
      throw const SosException(
        'E_SOS_CANCEL_HTTP_UNAVAILABLE',
        'SOS cancellation requires an HTTP remote data source.',
      );
    }
    return super.cancelSos();
  }

  @override
  Future<SosIncident> resolveSos() async {
    if (!isResolveAvailable) {
      throw const SosException(
        'E_SOS_RESOLVE_HTTP_UNAVAILABLE',
        'SOS resolve requires an HTTP remote data source.',
      );
    }
    return super.resolveSos();
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

EixamSosPacket _relayedSosPacket() {
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
    0x54,
  ])!;
}

BleIncomingEvent _bridgeTelEvent({
  required String signature,
  String? canonicalHardwareId = 'CF:82:99:88:77:66',
}) {
  return BleIncomingEvent(
    deviceId: 'device-1',
    canonicalHardwareId: canonicalHardwareId,
    type: BleIncomingEventType.telPosition,
    channel: EixamBleChannel.tel,
    payload: const <int>[0x01],
    payloadHex: signature,
    source: DeviceSosTransitionSource.device,
    receivedAt: DateTime.utc(2026, 3, 31, 10),
    telPacket: EixamTelPacket(
      rawBytes: const <int>[0x01],
      rawHex: signature,
      nodeId: 0x1234,
      position: const EixamPositionData(
        latitude: 41.38,
        longitude: 2.17,
        altitudeMeters: 8,
      ),
      metaWord: 0,
      batteryLevel: 3,
      gpsQuality: 2,
      packetId: 7,
      speedBucket: 0,
      headingBucket: 0,
    ),
  );
}

BleIncomingEvent _bridgeInvalidTelEvent({
  required String signature,
  String? canonicalHardwareId = 'CF:82:99:88:77:66',
}) {
  return BleIncomingEvent(
    deviceId: 'device-1',
    canonicalHardwareId: canonicalHardwareId,
    type: BleIncomingEventType.telPosition,
    channel: EixamBleChannel.tel,
    payload: const <int>[0x01],
    payloadHex: signature,
    source: DeviceSosTransitionSource.device,
    receivedAt: DateTime.utc(2026, 3, 31, 10),
    telPacket: EixamTelPacket(
      rawBytes: const <int>[0x01],
      rawHex: signature,
      nodeId: 0x1234,
      position: const EixamPositionData(
        latitude: 95,
        longitude: 2.17,
        altitudeMeters: 8,
      ),
      metaWord: 0,
      batteryLevel: 3,
      gpsQuality: 2,
      packetId: 7,
      speedBucket: 0,
      headingBucket: 0,
    ),
  );
}

BleIncomingEvent _bridgeSosEvent({
  required String signature,
  String? canonicalHardwareId = 'CF:82:99:88:77:66',
}) {
  return BleIncomingEvent(
    deviceId: 'device-1',
    canonicalHardwareId: canonicalHardwareId,
    type: BleIncomingEventType.sosMeshPacket,
    channel: EixamBleChannel.sos,
    payload: const <int>[0x01],
    payloadHex: signature,
    source: DeviceSosTransitionSource.device,
    receivedAt: DateTime.utc(2026, 3, 31, 10, 1),
    sosPacket: EixamSosPacket(
      rawBytes: const <int>[0x01],
      rawHex: signature,
      nodeId: 0x1234,
      flagsWord: 0,
      sosType: 1,
      retryCount: 0,
      relayCount: 0,
      batteryLevel: 3,
      gpsQuality: 2,
      speedEstimate: 0,
      packetId: 5,
      hasPosition: true,
      position: const EixamPositionData(
        latitude: 41.38,
        longitude: 2.17,
        altitudeMeters: 8,
      ),
    ),
  );
}

BleIncomingEvent _bridgeSosWithoutPositionEvent({
  required String signature,
  String? canonicalHardwareId = 'CF:82:99:88:77:66',
}) {
  return BleIncomingEvent(
    deviceId: 'device-1',
    canonicalHardwareId: canonicalHardwareId,
    type: BleIncomingEventType.sosMeshPacket,
    channel: EixamBleChannel.sos,
    payload: const <int>[0x01],
    payloadHex: signature,
    source: DeviceSosTransitionSource.device,
    receivedAt: DateTime.utc(2026, 3, 31, 10, 1),
    sosPacket: EixamSosPacket(
      rawBytes: const <int>[0x01],
      rawHex: signature,
      nodeId: 0x1234,
      flagsWord: 0,
      sosType: 1,
      retryCount: 0,
      relayCount: 1,
      batteryLevel: 3,
      gpsQuality: 0,
      speedEstimate: 0,
      packetId: 6,
      hasPosition: false,
      sequence: 1,
    ),
  );
}

BleIncomingEvent _bridgeAggregateTelCompleteEvent({
  required String signature,
  String? canonicalHardwareId = 'CF:82:99:88:77:66',
}) {
  return BleIncomingEvent(
    deviceId: 'device-1',
    canonicalHardwareId: canonicalHardwareId,
    type: BleIncomingEventType.telAggregateComplete,
    channel: EixamBleChannel.tel,
    payload: const <int>[0xD0, 0x0A, 0x00, 0x00, 0x00, 0x01],
    payloadHex: signature,
    source: DeviceSosTransitionSource.device,
    receivedAt: DateTime.utc(2026, 3, 31, 10),
    aggregatePayload: const <int>[
      0x34,
      0x12,
      0x01,
      0x02,
      0x03,
      0x04,
      0x05,
      0x06,
      0x87,
      0x65,
    ],
  );
}

BleIncomingEvent _bridgeAggregateTelFragmentEvent({
  required String signature,
  String? canonicalHardwareId = 'CF:82:99:88:77:66',
}) {
  return BleIncomingEvent(
    deviceId: 'device-1',
    canonicalHardwareId: canonicalHardwareId,
    type: BleIncomingEventType.telAggregateFragment,
    channel: EixamBleChannel.tel,
    payload: const <int>[0xD0, 0x14, 0x00, 0x00, 0x00, 0xAA],
    payloadHex: signature,
    source: DeviceSosTransitionSource.device,
    receivedAt: DateTime.utc(2026, 3, 31, 10),
    telFragment: EixamTelFragment.tryParse(
      const <int>[0xD0, 0x14, 0x00, 0x00, 0x00, 0xAA],
    ),
  );
}

BleIncomingEvent _bridgeUnsupportedAggregateTelCompleteEvent({
  required String signature,
}) {
  return BleIncomingEvent(
    deviceId: 'device-1',
    type: BleIncomingEventType.telAggregateComplete,
    channel: EixamBleChannel.tel,
    payload: const <int>[0xD0, 0x15, 0x00, 0x00, 0x00, 0x01],
    payloadHex: signature,
    source: DeviceSosTransitionSource.device,
    receivedAt: DateTime.utc(2026, 3, 31, 10),
    aggregatePayload: List<int>.generate(21, (index) => index),
  );
}

SosIncident _testSosIncident({required SosState state}) {
  return SosIncident(
    id: 'sos-test',
    state: state,
    createdAt: DateTime.utc(2026, 3, 31, 10),
  );
}
