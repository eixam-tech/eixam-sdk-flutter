import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
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
  const backgroundTelemetryMethodChannel = MethodChannel(
    'dev.eixam.connect_flutter/background_telemetry/methods',
  );

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
        case 'flushProtectionQueues':
          return <String, dynamic>{
            'flushedSosCount': 0,
            'flushedTelemetryCount': 0,
            'success': true,
          };
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
  });

  tearDown(() {
    BleDebugRegistry.instance.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(protectionMethodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(backgroundTelemetryMethodChannel, null);
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

    test('terminal notification intent includes typed terminal reason only',
        () async {
      final harness = _SdkSosHarness();
      final notificationIntents = <EixamNotificationIntent>[];
      final subscription = harness.sdk
          .watchNotificationIntents()
          .listen(notificationIntents.add);
      try {
        await harness.sdk.triggerSos(const SosTriggerPayload());
        await harness.sdk.cancelSos();
        await pumpEventQueue(times: 2);

        final terminalIntent = notificationIntents
            .where((intent) =>
                intent.type == EixamNotificationIntentType.sosCancelled)
            .single;

        expect(
          terminalIntent.payload['terminalReason'],
          SosTerminalReason.cancelledByUser.name,
        );
        expect(terminalIntent.payload, isNot(contains('userHash')));
        expect(terminalIntent.payload, isNot(contains('externalUserId')));
      } finally {
        await subscription.cancel();
        await harness.dispose();
      }
    });

    test(
        'public SOS stream blocks raw repository open transition rejected by machine',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        harness.sosRepository.currentIncident = _incident(
          state: SosState.acknowledged,
          triggerSource: 'button_ui',
        );

        harness.sosRepository.stateController.add(SosState.acknowledged);
        await pumpEventQueue(times: 2);

        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(
          _hasDebugMessage('SDK_SOS_STATE_MACHINE_TRANSITION_REJECTED'),
          isTrue,
        );
        expect(
          _hasDebugMessage('SDK_SOS_STATE_MACHINE_BYPASS_BLOCKED'),
          isTrue,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('public SOS stream accepts canonical sent acknowledge resolve chain',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.triggerSos(const SosTriggerPayload());
        expect(await harness.sdk.getSosState(), SosState.sent);

        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.acknowledged,
        );
        harness.sosRepository.stateController.add(SosState.acknowledged);
        await pumpEventQueue(times: 2);

        expect(await harness.sdk.getSosState(), SosState.acknowledged);

        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.resolved,
        );
        harness.sosRepository.stateController.add(SosState.resolved);
        await pumpEventQueue(times: 2);

        expect(await harness.sdk.getSosState(), SosState.resolved);
        expect(
          _hasDebugMessage('SDK_SOS_STATE_MACHINE_TRANSITION_ACCEPTED'),
          isTrue,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('authoritative terminal cancelled state still wins', () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.triggerSos(const SosTriggerPayload());
        expect(await harness.sdk.getSosState(), SosState.sent);

        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.cancelled,
        );
        harness.sosRepository.stateController.add(SosState.cancelled);
        await pumpEventQueue(times: 2);

        expect(await harness.sdk.getSosState(), SosState.cancelled);
        expect(
          _hasDebugMessage('SDK_SOS_STATE_MACHINE_TRANSITION_REJECTED'),
          isTrue,
        );
        expect(
          _hasDebugMessage('SDK_SOS_STATE_MACHINE_BYPASS_RETAINED'),
          isTrue,
        );
        expect(
          _hasDebugMessage(
            'SDK_SOS_STATE_MACHINE_BYPASS_RETAINED '
            'source=sos_state_stream from=sent to=cancelled '
            'reason=repository_terminal_stream authority=repository '
            'origin=backend_repository policy=authoritative_terminal',
          ),
          isTrue,
        );
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
        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(await harness.sdk.getCurrentSosIncident(), isNull);
      } finally {
        await harness.dispose();
      }
    });

    test('backend unavailable with device available returns device-only SOS',
        () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        harness.deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-1',
            nodeId: 0x1234,
            canonicalHardwareId: 'CF:82:00:00:00:01',
            connected: true,
            paired: true,
            activated: true,
          ),
        );
        await harness.attachObservedAppActivation();
        harness.sosRepository.triggerError =
            const NetworkException('E_NETWORK', 'offline');

        final stateStreamExpectation = expectLater(
          harness.sdk.currentSosStateStream,
          emitsThrough(SosState.sent),
        );
        final incident = await harness.sdk.triggerSos(
          const SosTriggerPayload(),
        );
        await stateStreamExpectation;

        expect(incident.state, SosState.sent);
        expect(incident.deliveryChannel, SosDeliveryChannel.deviceOnly);
        expect(incident.id, startsWith('public-sos-fallback:'));
        expect(incident.triggerSource, 'public_sos_fallback');
        expect(incident.actionability, SosActionability.localActionable);
        expect(incident.displaySurface, SosDisplaySurface.activeAndHistory);
        expect(await harness.sdk.getSosState(), SosState.sent);
        final currentIncident = await harness.sdk.getCurrentSosIncident();
        expect(currentIncident?.state, SosState.sent);
        expect(currentIncident?.deliveryChannel, SosDeliveryChannel.deviceOnly);
        expect(_hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_SUCCESS'), isTrue);
        expect(
          _hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_SUCCESS_RETURNED'),
          isTrue,
        );
        expect(
          _hasDebugMessage('SOS_TRIGGER_FAILURE_BLOCKED_DEVICE_SUCCESS'),
          isTrue,
        );
        expect(
          _hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_BACKEND_PENDING'),
          isTrue,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('device activation plus MQTT publish failure returns device-only SOS',
        () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        harness.deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-1',
            nodeId: 0x1234,
            canonicalHardwareId: 'CF:82:00:00:00:01',
            connected: true,
            paired: true,
            activated: true,
          ),
        );
        await harness.attachObservedAppActivation();
        harness.sosRepository.triggerError = const SosException(
          'E_MQTT_NOT_CONNECTED',
          'mqtt offline',
        );

        final incident = await harness.sdk.triggerSos(
          const SosTriggerPayload(message: 'device wins'),
        );

        expect(incident.state, SosState.sent);
        expect(incident.deliveryChannel, SosDeliveryChannel.deviceOnly);
        expect(incident.id, startsWith('public-sos-fallback:'));
        expect(await harness.sdk.getSosState(), SosState.sent);
        expect(
          _hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_BACKEND_FAILED_NON_FATAL'),
          isTrue,
        );
        expect(
          _hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_SUCCESS_RETURNED'),
          isTrue,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('device-only SOS can later adopt backend confirmation', () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        harness.deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-1',
            nodeId: 0x1234,
            canonicalHardwareId: 'CF:82:00:00:00:01',
            connected: true,
            paired: true,
            activated: true,
          ),
        );
        await harness.attachObservedAppActivation();
        harness.sosRepository.triggerError =
            const NetworkException('E_NETWORK', 'offline');

        final provisional = await harness.sdk.triggerSos(
          const SosTriggerPayload(),
        );
        harness.sosRepository.triggerError = null;
        harness.sosRepository.currentIncident = SosIncident(
          id: 'backend-confirmed-sos',
          state: SosState.sent,
          createdAt: DateTime.utc(2026, 1, 1, 10, 1),
          triggerSource: 'button_ui',
          deliveryChannel: SosDeliveryChannel.backendOnly,
        );

        final current = await harness.sdk.getCurrentSosIncident();

        expect(provisional.deliveryChannel, SosDeliveryChannel.deviceOnly);
        expect(current?.id, 'backend-confirmed-sos');
        expect(current?.deliveryChannel, SosDeliveryChannel.backendAndDevice);
        expect(
          _hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_BACKEND_CONFIRMED'),
          isTrue,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('device activation failure plus backend failure still throws',
        () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        harness.deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-1',
            nodeId: 0x1234,
            canonicalHardwareId: 'CF:82:00:00:00:01',
            connected: true,
            paired: true,
            activated: true,
          ),
        );
        await harness.deviceSosController.attach(
          commandWriter: (_) async {
            throw const DeviceException(
                'E_DEVICE_WRITE_FAILED', 'write failed');
          },
        );
        harness.sosRepository.triggerError =
            const NetworkException('E_NETWORK', 'offline');

        await expectLater(
          harness.sdk.triggerSos(const SosTriggerPayload()),
          throwsA(isA<NetworkException>()),
        );

        expect(await harness.sdk.getSosState(), SosState.failed);
        expect(
          await harness.sdk.getCurrentSosTerminalReason(),
          SosTerminalReason.deliveryFailed,
        );
        expect(_hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_SUCCESS'), isFalse);
      } finally {
        await harness.dispose();
      }
    });

    test('backend unavailable with device unavailable throws SOS failure',
        () async {
      final harness = _SdkSosHarness();
      try {
        harness.sosRepository.triggerError =
            const NetworkException('E_NETWORK', 'offline');
        final failedState = harness.sdk.currentSosStateStream.firstWhere(
          (state) => state == SosState.failed,
        );

        await expectLater(
          harness.sdk.triggerSos(const SosTriggerPayload()),
          throwsA(
            isA<SosException>().having(
              (error) => error.code,
              'code',
              'E_SOS_NOT_AVAILABLE',
            ),
          ),
        );
        expect(await harness.sdk.getSosState(), SosState.failed);
        expect(await failedState, SosState.failed);
        expect(
          await harness.sdk.getCurrentSosTerminalReason(),
          SosTerminalReason.notAvailable,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('backend validation failure exposes typed terminal reason', () async {
      final harness = _SdkSosHarness();
      try {
        harness.sosRepository.triggerError = const SosHttpException(
          'E_HTTP_SOS_TRIGGER_FAILED',
          'validation failed',
          statusCode: 422,
        );

        await expectLater(
          harness.sdk.triggerSos(const SosTriggerPayload()),
          throwsA(isA<SosHttpException>()),
        );

        expect(await harness.sdk.getSosState(), SosState.failed);
        expect(
          await harness.sdk.getCurrentSosTerminalReason(),
          SosTerminalReason.backendValidationFailed,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('backend rejection exposes typed terminal reason', () async {
      final harness = _SdkSosHarness();
      try {
        harness.sosRepository.triggerError = const SosHttpException(
          'E_HTTP_SOS_TRIGGER_FAILED',
          'backend rejected SOS',
          statusCode: 409,
        );

        await expectLater(
          harness.sdk.triggerSos(const SosTriggerPayload()),
          throwsA(isA<SosHttpException>()),
        );

        expect(
          await harness.sdk.getCurrentSosTerminalReason(),
          SosTerminalReason.backendRejected,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('backend available with device unavailable returns backend SOS',
        () async {
      final harness = _SdkSosHarness();
      try {
        final incident = await harness.sdk.triggerSos(
          const SosTriggerPayload(),
        );

        expect(incident.state, SosState.sent);
        expect(incident.deliveryChannel, SosDeliveryChannel.backendOnly);
        expect(harness.sosRepository.triggerCallCount, 1);
        expect(_hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_SUCCESS'), isFalse);
      } finally {
        await harness.dispose();
      }
    });

    test('external remote relay public trigger remains non-actionable',
        () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await expectLater(
          harness.sdk.triggerSos(
            const SosTriggerPayload(triggerSource: 'remote_lora_relay'),
          ),
          throwsA(
            isA<SosException>().having(
              (error) => error.code,
              'code',
              'E_EXTERNAL_SOS_NOT_LOCAL_ACTIONABLE',
            ),
          ),
        );

        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(harness.sosRepository.triggerCallCount, 0);
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

    test(
        'SOS-03b app-origin BLE countdown success is not cleared by stale idle',
        () async {
      final harness = _SdkSosHarness(
        connectedBle: true,
        deviceCountdown: const Duration(milliseconds: 35),
      );
      final states = <SosState>[];
      final subscription = harness.sdk.currentSosStateStream.listen(states.add);
      try {
        harness.deviceRepository.emitStatus(
          buildDeviceStatus(
            deviceId: 'ble-1',
            nodeId: 0x1234,
            canonicalHardwareId: 'CF:82:00:00:00:01',
            connected: true,
            paired: true,
            activated: true,
          ),
        );
        harness.trackingRepository.emitPosition(
          TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.now().toUtc(),
            source: DeliveryMode.mobile,
          ),
        );
        await harness.attachObservedAppActivation();

        await harness.sdk.startPreSos(
          countdown: const Duration(milliseconds: 35),
        );
        await Future<void>.delayed(const Duration(milliseconds: 140));

        expect(harness.sosRepository.triggerCallCount, 1);
        expect(harness.sosRepository.lastOriginatorNodeId, 0x1234);
        expect(harness.sosRepository.lastPositionSnapshot?.latitude, 41.38);
        expect(harness.sosRepository.lastPositionSnapshot?.longitude, 2.17);
        expect(states, contains(SosState.arming));
        expect(states, contains(SosState.sent));
        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.sent);

        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.idle,
        );
        harness.sosRepository.stateController.add(SosState.idle);
        await pumpEventQueue(times: 3);

        expect(await harness.sdk.getSosState(), SosState.sent);
        expect(states.last, SosState.sent);
        expect(
          _hasDebugMessage('SOS_APP_ORIGIN_ACTIVE_BRIDGE_REGISTERED'),
          isTrue,
        );
      } finally {
        await subscription.cancel();
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
        expect(await harness.sdk.getSosState(), SosState.idle);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-04b BLE active cancel ignores residual preConfirm status',
        () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.deviceSosController.attach(commandWriter: (_) async {});
        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginCountdownPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 2);
        await harness.sdk.triggerSos(const SosTriggerPayload());

        expect(await harness.sdk.getSosState(), SosState.sent);

        final cancelled = await harness.sdk.cancelSos();

        expect(cancelled.state, SosState.cancelled);
        expect(harness.sosRepository.cancelCallCount, 1);
        expect(await harness.sdk.getSosState(), SosState.idle);
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
        expect(
          await harness.sdk.getCurrentSosTerminalReason(),
          SosTerminalReason.cancelledByDevice,
        );
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
      final harness = _SdkSosHarness(
        connectedBle: true,
        deviceCountdown: const Duration(milliseconds: 5),
      );
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
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(
          (await harness.deviceSosController.getStatus()).state,
          DeviceSosState.active,
        );

        await harness.sdk.cancelSos();
        await pumpEventQueue(times: 2);

        expect(harness.sosRepository.cancelCallCount, 1);
        expect(
          <SosState>[SosState.idle, SosState.cancelled],
          contains(await harness.sdk.getSosState()),
        );
        expect(
          await harness.sdk.getCurrentSosTerminalReason(),
          SosTerminalReason.cancelledByUser,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('device ACK timeout forced terminal exposes typed reason', () async {
      final harness = _SdkSosHarness(
        connectedBle: true,
        deviceCountdown: const Duration(milliseconds: 5),
        appActivationObservationTimeout: const Duration(milliseconds: 10),
      );
      try {
        await harness.deviceSosController.attach(commandWriter: (_) async {});
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
        await Future<void>.delayed(const Duration(milliseconds: 15));

        await harness.sdk.cancelSos();
        await pumpEventQueue(times: 2);

        expect(
          await harness.sdk.getCurrentSosTerminalReason(),
          SosTerminalReason.deviceAckTimeout,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-09 BLE device-origin active can be resolved by app', () async {
      final harness = _SdkSosHarness(
        connectedBle: true,
        deviceCountdown: const Duration(milliseconds: 5),
      );
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
        await Future<void>.delayed(const Duration(milliseconds: 15));
        expect(
          (await harness.deviceSosController.getStatus()).state,
          DeviceSosState.active,
        );

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

    test('SOS-12 backend idle rehydration does not cancel active PRE-SOS',
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

        expect(await harness.sdk.getPreSosStatus(), isNotNull);
        expect(await harness.sdk.getSosState(), SosState.arming);
      } finally {
        await harness.dispose();
      }
    });

    test('session refresh does not reset app-origin PRE-SOS countdown',
        () async {
      final repository = FakeRehydratingSosRepository()
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));
        final before = await harness.sdk.getPreSosStatus();

        await harness.sdk.refreshCanonicalIdentity();

        final after = await harness.sdk.getPreSosStatus();
        expect(after, isNotNull);
        expect(after!.cycleKey, before!.cycleKey);
        expect(after.expectedActivationAt, before.expectedActivationAt);
        expect(await harness.sdk.getSosState(), SosState.arming);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-13 LoRa/backend foreground active stays external-only idle',
        () async {
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

        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(await harness.sdk.getCurrentSosIncident(), isNull);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-14 LoRa/backend terminal leaves SDK local state idle', () async {
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
        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(await harness.sdk.getCurrentSosIncident(), isNull);
      } finally {
        await harness.dispose();
      }
    });

    test('SOS-15 resume ignores active LoRa/backend SOS as local state',
        () async {
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

        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(await harness.sdk.getCurrentSosIncident(), isNull);
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
        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(await harness.sdk.getCurrentSosIncident(), isNull);
      } finally {
        await harness.dispose();
      }
    });

    test('app-origin countdown survives repository idle reads', () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

        final firstStatus = await harness.sdk.getPreSosStatus();
        expect(firstStatus, isNotNull);
        expect(await harness.sdk.getSosState(), SosState.arming);

        final secondStatus = await harness.sdk.getPreSosStatus();
        expect(secondStatus, isNotNull);
        expect(secondStatus!.cycleKey, firstStatus!.cycleKey);
        expect(secondStatus.expectedActivationAt,
            firstStatus.expectedActivationAt);
        expect(await harness.sdk.getSosState(), SosState.arming);
        expect(harness.sosRepository.triggerCallCount, 0);
      } finally {
        await harness.dispose();
      }
    });

    test('app-origin countdown survives SDK restart and promotes on restore',
        () async {
      final store = MemorySharedPrefsSdkStore();
      final repository = FakeSosRepository();
      final first = _SdkSosHarness(
        sosRepository: repository,
        localStore: store,
      );
      await first.sdk.startPreSos(countdown: const Duration(milliseconds: 5));
      expect(await first.sdk.getPreSosStatus(), isNotNull);
      await first.dispose(disposeSosRepository: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final restored = _SdkSosHarness(
        sosRepository: repository,
        localStore: store,
      );
      try {
        await restored.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://api.example.com'),
        );

        expect(repository.triggerCallCount, 1);
        expect(await restored.sdk.getPreSosStatus(), isNull);
        expect(await restored.sdk.getSosState(), SosState.sent);
      } finally {
        await restored.dispose();
      }
    });

    test('typed already-active recovers matching persisted local ownership',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.setSession();
        final first = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        harness.sosRepository.triggerError = const SosException(
          'E_SOS_ALREADY_ACTIVE',
          'E_SOS_ALREADY_ACTIVE',
        );
        final recovered = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );

        expect(first.outcome, SosActivationOutcome.activated);
        expect(
          recovered.outcome,
          SosActivationOutcome.alreadyActiveRecovered,
        );
        expect(recovered.lifecycle.lifecycleId, first.lifecycle.lifecycleId);
        expect(recovered.lifecycle.localActionable, isTrue);
      } finally {
        await harness.dispose();
      }
    });

    test('typed already-active without local proof remains unmatched',
        () async {
      final repository = FakeSosRepository()
        ..currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'external_backend',
        )
        ..triggerError = const SosException(
          'E_SOS_ALREADY_ACTIVE',
          'E_SOS_ALREADY_ACTIVE',
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();
        final result = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );

        expect(result.outcome, SosActivationOutcome.alreadyActiveUnmatched);
        expect(result.lifecycle.stage, SosLifecycleStage.recoveryRequired);
        expect(result.lifecycle.localActionable, isFalse);
        expect(result.lifecycle.localIncidentId, isNull);
      } finally {
        await harness.dispose();
      }
    });

    test('typed cancellation publishes cancelling before terminal cleanup',
        () async {
      final harness = _SdkSosHarness();
      final observed = <SosLifecycleStage>[];
      final subscription = harness.sdk.sosLifecycleStream
          .map((snapshot) => snapshot.stage)
          .listen(observed.add);
      try {
        await harness.setSession();
        await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        final result = await harness.sdk.cancelSosAuthoritatively();
        await pumpEventQueue();

        expect(result.outcome, SosCancellationOutcome.cancelled);
        expect(result.lifecycle.stage, SosLifecycleStage.cancelled);
        expect(observed, contains(SosLifecycleStage.cancelling));
        expect(
          observed.indexOf(SosLifecycleStage.cancelling),
          lessThan(observed.indexOf(SosLifecycleStage.cancelled)),
        );
      } finally {
        await subscription.cancel();
        await harness.dispose();
      }
    });

    test('process recreation restores the same actionable generation',
        () async {
      final secureStore = InMemorySecureKeyValueStore();
      final repository = FakeSosRepository();
      final first = _SdkSosHarness(
        sosRepository: repository,
        sosLifecycleSecureStore: secureStore,
      );
      await first.setSession();
      final activated = await first.sdk.triggerSosAuthoritatively(
        const SosTriggerPayload(triggerSource: 'commercial_app'),
      );
      await first.dispose(disposeSosRepository: false);

      final restored = _SdkSosHarness(
        sosRepository: repository,
        sosLifecycleSecureStore: secureStore,
      );
      try {
        await restored.setSession();
        final lifecycle = await restored.sdk.getSosLifecycle();

        expect(lifecycle.lifecycleId, activated.lifecycle.lifecycleId);
        expect(lifecycle.stage, SosLifecycleStage.recoveryRequired);
        expect(lifecycle.localActionable, isTrue);
      } finally {
        await restored.dispose();
      }
    });

    test('app SOS capability stays available without a registered device',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://api.example.com'),
        );
        await harness.setSession();

        final capability = await harness.sdk.getSosCapability();

        expect(capability.canTriggerAppSos, isTrue);
        expect(capability.canTriggerDeviceSos, isFalse);
        expect(capability.canTriggerSos, isTrue);
        expect(capability.hasRegisteredDevice, isFalse);
        expect(capability.hasConnectedDevice, isFalse);
        expect(
          capability.availableActivationPaths,
          contains(SosActivationPath.appBackend),
        );
      } finally {
        await harness.dispose();
      }
    });

    test('missing location degrades but does not block app SOS', () async {
      final harness = _SdkSosHarness(hasLocation: false);
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://api.example.com'),
        );
        await harness.setSession();

        final capability = await harness.sdk.getSosCapability();
        final result = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );

        expect(capability.locationAvailable, isFalse);
        expect(capability.canTriggerAppSos, isTrue);
        expect(
          capability.degradedReasons,
          contains(SosCapabilityDegradedReason.locationUnavailable),
        );
        expect(result.outcome, SosActivationOutcome.activated);
        expect(result.usedPaths, contains(SosActivationPath.appBackend));
      } finally {
        await harness.dispose();
      }
    });

    test('unauthenticated runtime reports a typed blocking reason', () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://api.example.com'),
        );

        final capability = await harness.sdk.getSosCapability();

        expect(capability.canTriggerSos, isFalse);
        expect(
          capability.blockingReason,
          SosCapabilityBlockingReason.authenticationRequired,
        );
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
    Duration appActivationObservationTimeout = const Duration(seconds: 3),
    MemorySharedPrefsSdkStore? localStore,
    SecureKeyValueStore? sosLifecycleSecureStore,
    bool hasLocation = true,
  })  : sosRepository = sosRepository ?? FakeSosRepository(),
        trackingRepository = FakeTrackingRepository(
          currentPosition: hasLocation
              ? TrackingPosition(
                  latitude: 41.38,
                  longitude: 2.17,
                  timestamp: DateTime.utc(2026, 1, 1, 10),
                  source: DeliveryMode.mobile,
                )
              : null,
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
          appActivationObservationTimeout: appActivationObservationTimeout,
        ),
        localStore = localStore ?? MemorySharedPrefsSdkStore(),
        preferredBleDeviceStore = PreferredBleDeviceStore(
          localStore: localStore ?? MemorySharedPrefsSdkStore(),
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
      localStore: this.localStore,
      sosLifecycleSecureStore: sosLifecycleSecureStore,
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
  final MemorySharedPrefsSdkStore localStore;
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

  Future<void> attachObservedAppActivation() {
    return deviceSosController.attach(
      commandWriter: (command) async {
        if (command.opcode == 0x06) {
          Future<void>.delayed(const Duration(milliseconds: 5), () {
            deviceSosController.handleIncomingSosPacket(
              _deviceOriginCountdownPacket(),
              source: DeviceSosTransitionSource.device,
            );
          });
        }
        if (command.opcode == 0x05) {
          Future<void>.delayed(const Duration(milliseconds: 5), () {
            deviceSosController.handleIncomingSosPacket(
              _deviceOriginActivePacket(),
              source: DeviceSosTransitionSource.device,
            );
          });
        }
      },
    );
  }

  Future<void> dispose({bool disposeSosRepository = true}) async {
    await sdk.dispose();
    if (disposeSosRepository) {
      await sosRepository.dispose();
    }
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

bool _hasDebugMessage(String token) {
  return BleDebugRegistry.instance.currentState.events.any(
    (event) => event.message.contains(token),
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
