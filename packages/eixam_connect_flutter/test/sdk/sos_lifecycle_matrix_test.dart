import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_event_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_location_ownership_orchestrator.dart';
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

    test('incident progress stream deduplicates equivalent repository states',
        () async {
      final harness = _SdkSosHarness();
      harness.sosRepository.currentIncident = SosIncident(
        id: 'b5c38ed3-40be-4565-b55a-bf49753861a1',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 7, 20, 10),
        originKind: SosOriginKind.app,
        actionability: SosActionability.localActionable,
        displaySurface: SosDisplaySurface.activeAndHistory,
        isBackendConfirmed: true,
        provisionalIncidentId: 'sos-1784553184064842',
        preservedLocalOwnership: true,
      );
      final progress = <SosIncidentProgress?>[];
      final subscription = harness.sdk.currentSosIncidentProgressStream.listen(
        progress.add,
      );
      try {
        await pumpEventQueue(times: 2);
        harness.sosRepository.stateController.add(SosState.sent);
        harness.sosRepository.stateController.add(SosState.sent);
        await pumpEventQueue(times: 2);

        expect(progress, hasLength(1));
      } finally {
        await harness.dispose();
        await subscription.cancel();
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
        'typed pending cancellation invalidates countdown generation without backend calls',
        () async {
      final harness = _SdkSosHarness();
      final stages = <SosLifecycleStage>[];
      final subscription =
          harness.sdk.sosLifecycleStream.map((value) => value.stage).listen(
                stages.add,
              );
      try {
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 15));

        final result = await harness.sdk.cancelSosAuthoritatively();
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(
          result.outcome,
          SosCancellationOutcome.pendingActivationCancelled,
        );
        expect(result.lifecycle.stage, SosLifecycleStage.cancelled);
        expect(result.lifecycle.localIncidentId, isNull);
        expect(harness.sosRepository.triggerCallCount, 0);
        expect(harness.sosRepository.cancelCallCount, 0);
        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(stages, isNot(contains(SosLifecycleStage.activating)));
        expect(stages, isNot(contains(SosLifecycleStage.active)));
        expect(
          (await harness.sdk.getSosCapability()).lifecycleAllowsActivation,
          isTrue,
        );
      } finally {
        await subscription.cancel();
        await harness.dispose();
      }
    });

    test('cancelled generation cannot affect an immediately-started generation',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 1));
        final first = await harness.sdk.cancelSosAuthoritatively();
        expect(
          first.outcome,
          SosCancellationOutcome.pendingActivationCancelled,
        );

        await harness.sdk.startPreSos(
          countdown: const Duration(milliseconds: 60),
        );
        await Future<void>.delayed(const Duration(milliseconds: 180));

        expect(harness.sosRepository.triggerCallCount, 1);
        expect(
          (await harness.sdk.getSosLifecycle()).stage,
          SosLifecycleStage.active,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('duplicate pending cancellation is idempotent', () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.startPreSos(countdown: const Duration(seconds: 15));

        final first = await harness.sdk.cancelSosAuthoritatively();
        final second = await harness.sdk.cancelSosAuthoritatively();

        expect(
          first.outcome,
          SosCancellationOutcome.pendingActivationCancelled,
        );
        expect(
          second.outcome,
          SosCancellationOutcome.noActionableLifecycle,
        );
        expect(second.lifecycle.stage, SosLifecycleStage.cancelled);
        expect(harness.sosRepository.triggerCallCount, 0);
        expect(harness.sosRepository.cancelCallCount, 0);
      } finally {
        await harness.dispose();
      }
    });

    test('process recreation after pending cancellation never restores active',
        () async {
      final store = MemorySharedPrefsSdkStore();
      final secureStore = InMemorySecureKeyValueStore();
      final repository = FakeSosRepository();
      final first = _SdkSosHarness(
        sosRepository: repository,
        localStore: store,
        sosLifecycleSecureStore: secureStore,
      );
      await first.sdk.startPreSos(countdown: const Duration(seconds: 15));
      final cancelled = await first.sdk.cancelSosAuthoritatively();
      expect(
        cancelled.outcome,
        SosCancellationOutcome.pendingActivationCancelled,
      );
      await first.dispose(disposeSosRepository: false);
      await pumpEventQueue();

      final restored = _SdkSosHarness(
        sosRepository: repository,
        localStore: store,
        sosLifecycleSecureStore: secureStore,
      );
      try {
        await restored.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://api.example.com'),
        );

        final lifecycle = await restored.sdk.getSosLifecycle();
        expect(lifecycle.stage, SosLifecycleStage.idle);
        expect(lifecycle.recoveryStatus, SosRecoveryStatus.none);
        expect(await restored.sdk.getPreSosStatus(), isNull);
        expect(repository.triggerCallCount, 0);
        expect(repository.cancelCallCount, 0);
      } finally {
        await restored.dispose();
      }
    });

    test(
        'dispatch commit wins boundary and cancellation waits before backend cancel',
        () async {
      final repository = _BlockingTriggerSosRepository();
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.sdk.startPreSos(
          countdown: const Duration(milliseconds: 60),
        );
        await repository.triggerStarted.future.timeout(
          const Duration(seconds: 2),
        );

        final cancellation = harness.sdk.cancelSosAuthoritatively();
        await pumpEventQueue();

        expect(
          (await harness.sdk.getSosLifecycle()).stage,
          SosLifecycleStage.cancelling,
        );
        expect(repository.cancelCallCount, 0);

        repository.releaseTrigger();
        final result = await cancellation;

        expect(
          result.outcome,
          SosCancellationOutcome.activeCancellationConfirmed,
        );
        expect(result.lifecycle.stage, SosLifecycleStage.cancelled);
        expect(repository.triggerCallCount, 1);
        expect(repository.cancelCallCount, 1);
      } finally {
        repository.releaseTrigger();
        await harness.dispose();
      }
    });

    test(
        'characterization: locally actionable lifecycle mutations feed the '
        'public SOS state', () async {
      final harness = _SdkSosHarness(
        connectedBle: true,
        deviceCountdown: const Duration(milliseconds: 35),
      );
      final states = <SosState>[];
      final subscription = harness.sdk.currentSosStateStream.listen(states.add);
      final lifecycles = <SosLifecycleSnapshot>[];
      final lifecycleSubscription =
          harness.sdk.sosLifecycleStream.listen(lifecycles.add);
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
        final acceptedLifecycle = await harness.sdk.getSosLifecycle();
        expect(acceptedLifecycle.stage, SosLifecycleStage.active);
        expect(acceptedLifecycle.origin, SosLifecycleOrigin.localApp);
        expect(acceptedLifecycle.localActionable, isTrue);
        expect(acceptedLifecycle.generation, greaterThan(0));
        expect(acceptedLifecycle.revision, greaterThan(0));
        expect(acceptedLifecycle.lifecycleId, isNot('4660:0'));
        expect(
          lifecycles.map((snapshot) => snapshot.stage),
          containsAllInOrder(<SosLifecycleStage>[
            SosLifecycleStage.arming,
            SosLifecycleStage.activating,
            SosLifecycleStage.active,
          ]),
        );

        harness.sosRepository.currentIncident =
            harness.sosRepository.currentIncident.copyWith(
          state: SosState.idle,
        );
        harness.sosRepository.stateController.add(SosState.idle);
        await pumpEventQueue(times: 3);

        expect(await harness.sdk.getSosState(), SosState.sent);
        expect(states.last, SosState.sent);
        final lifecycleAfterStaleIdle = await harness.sdk.getSosLifecycle();
        expect(lifecycleAfterStaleIdle.stage, SosLifecycleStage.active);
        expect(lifecycleAfterStaleIdle.localActionable, isTrue);
        expect(
          lifecycleAfterStaleIdle.lifecycleId,
          acceptedLifecycle.lifecycleId,
        );
        expect(
          lifecycleAfterStaleIdle.generation,
          acceptedLifecycle.generation,
        );
        expect(
          lifecycleAfterStaleIdle.revision,
          acceptedLifecycle.revision,
        );
      } finally {
        await lifecycleSubscription.cancel();
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

    test('MQTT reconnect rehydrates remote terminal state', () async {
      final repository = FakeRehydratingSosRepository()
        ..currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'button_ui',
        )
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
        );
      final realtime = FakeRealtimeClient();
      final harness = _SdkSosHarness(
        sosRepository: repository,
        realtimeClient: realtime,
      );
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await harness.setSession();
        final beforeReconnect = repository.rehydrateCallCount;

        realtime.emitConnectionState(RealtimeConnectionState.reconnecting);
        realtime.emitConnectionState(RealtimeConnectionState.connected);
        await pumpEventQueue(times: 4);

        expect(repository.rehydrateCallCount, greaterThan(beforeReconnect));
        expect(await harness.sdk.getSosState(), SosState.idle);
      } finally {
        await harness.dispose();
      }
    });

    test('app resume clears an incident resolved remotely', () async {
      final repository = FakeRehydratingSosRepository()
        ..currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'button_ui',
        )
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.hydratedFromBackend,
          resultingState: SosState.sent,
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();
        repository.rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
        );

        harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 4);

        expect(await harness.sdk.getSosState(), SosState.idle);
      } finally {
        await harness.dispose();
      }
    });

    test('switching authenticated users clears prior incident progress',
        () async {
      final repository = FakeRehydratingSosRepository()
        ..currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'button_ui',
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();

        await harness.sdk.setSession(
          const EixamSession.signed(
            appId: 'app-demo',
            externalUserId: 'different-user',
            userHash: 'new-hash',
          ),
        );

        expect(repository.clearForSessionChangeCallCount, 1);
      } finally {
        await harness.dispose();
      }
    });

    test('logout clears repository-owned incident observation', () async {
      final repository = FakeRehydratingSosRepository()
        ..currentIncident = _incident(
          state: SosState.sent,
          triggerSource: 'button_ui',
        );
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();

        await harness.sdk.clearSession();

        expect(repository.clearForSessionChangeCallCount, 1);
        expect(repository.currentIncident.state, SosState.idle);
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

    test(
        'characterization: external-only relay incident does not become a '
        'locally owned authoritative lifecycle', () async {
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
        final lifecycle = await harness.sdk.getSosLifecycle();
        expect(lifecycle.localActionable, isFalse);
        expect(lifecycle.stage, SosLifecycleStage.idle);
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
      await first.sdk.startPreSos(countdown: const Duration(milliseconds: 50));
      expect(await first.sdk.getPreSosStatus(), isNotNull);
      await first.dispose(disposeSosRepository: false);
      await Future<void>.delayed(const Duration(milliseconds: 70));

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

    test('SDK runtime owns one shadow across initialization and activation',
        () async {
      final harness = _SdkSosHarness();
      final shadow = harness.sdk.debugSosLocationOwnershipOrchestrator;
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://api.example.com'),
        );
        await harness.setSession();

        expect(
          harness.sdk.debugSosLocationOwnershipOrchestrator,
          same(shadow),
        );
        final acceptedBefore = shadow.shadowState.acceptedSnapshotCount;
        final trackingStartsBefore = harness.trackingRepository.startCallCount;
        final trackingStopsBefore = harness.trackingRepository.stopCallCount;
        final telemetryBefore = harness.telemetryRepository.publishCallCount;

        final result = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );

        expect(result.lifecycle.stage, SosLifecycleStage.active);
        expect(await harness.sdk.getSosState(), SosState.sent);
        expect(
          shadow.shadowState.lastAcceptedLifecycleRevision,
          result.lifecycle.revision,
        );
        expect(
          shadow.shadowState.acceptedSnapshotCount,
          acceptedBefore + 3,
        );
        expect(shadow.shadowState.activateTransitionCount, 1);
        expect(shadow.shadowState.desiredSosOwnership, isTrue);
        expect(harness.trackingRepository.startCallCount, trackingStartsBefore);
        expect(harness.trackingRepository.stopCallCount, trackingStopsBefore);
        expect(harness.telemetryRepository.publishCallCount, telemetryBefore);
      } finally {
        await harness.dispose();
      }
    });

    test('shadow terminal does not add tracking or telemetry side effects',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.setSession();
        await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        final shadow = harness.sdk.debugSosLocationOwnershipOrchestrator;
        final trackingStartsBefore = harness.trackingRepository.startCallCount;
        final trackingStopsBefore = harness.trackingRepository.stopCallCount;
        final telemetryBefore = harness.telemetryRepository.publishCallCount;

        final result = await harness.sdk.cancelSosAuthoritatively();

        expect(result.lifecycle.stage, SosLifecycleStage.cancelled);
        expect(shadow.shadowState.deactivateTransitionCount, 1);
        expect(shadow.shadowState.desiredSosOwnership, isFalse);
        expect(harness.trackingRepository.startCallCount, trackingStartsBefore);
        expect(harness.trackingRepository.stopCallCount, trackingStopsBefore);
        expect(harness.telemetryRepository.publishCallCount, telemetryBefore);
      } finally {
        await harness.dispose();
      }
    });

    test('arming remains shadow-retain while public arming is unchanged',
        () async {
      final harness = _SdkSosHarness();
      try {
        await harness.setSession();
        final shadow = harness.sdk.debugSosLocationOwnershipOrchestrator;
        final activateBefore = shadow.shadowState.activateTransitionCount;
        final trackingStartsBefore = harness.trackingRepository.startCallCount;

        await harness.sdk.startPreSos(
          countdown: const Duration(seconds: 20),
        );

        expect(await harness.sdk.getSosState(), SosState.arming);
        expect(
          shadow.shadowState.lastDirective,
          SosLocationOwnershipDirective.retain,
        );
        expect(shadow.shadowState.activateTransitionCount, activateBefore);
        expect(harness.trackingRepository.startCallCount, trackingStartsBefore);
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

    test(
        'already-active current app incident reconciles without optimistic active publication',
        () async {
      final repository = _AlreadyActiveLookupRepository(
        authoritativeActive: _incident(
          state: SosState.sent,
          triggerSource: 'commercial_app',
        ),
      );
      final harness = _SdkSosHarness(sdkSosRepository: repository);
      final observed = <SosLifecycleStage>[];
      final subscription = harness.sdk.sosLifecycleStream
          .map((snapshot) => snapshot.stage)
          .listen(observed.add);
      try {
        await harness.setSession();
        final resultFuture = harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        await pumpEventQueue(times: 3);

        expect(observed, contains(SosLifecycleStage.activating));
        expect(observed, isNot(contains(SosLifecycleStage.active)));

        repository.completeTriggerWithAlreadyActive();
        final result = await resultFuture;
        await pumpEventQueue();

        expect(result.outcome, SosActivationOutcome.alreadyActiveRecovered);
        expect(result.lifecycle.stage, SosLifecycleStage.active);
        expect(
          observed.where((stage) => stage == SosLifecycleStage.active),
          hasLength(1),
        );
        final capability = await harness.sdk.getSosCapability();
        expect(capability.revision, result.lifecycle.revision);
        expect(capability.canTriggerSos, isFalse);
        expect(capability.lifecycleAllowsActivation, isFalse);
        expect(capability.canCancelCurrentSos, isTrue);
        expect(
          capability.preferredActivationPath,
          SosActivationPath.restoredActiveLifecycle,
        );
      } finally {
        await subscription.cancel();
        await harness.dispose(disposeSosRepository: false);
        await repository.dispose();
      }
    });

    test('already-active authoritative foreign incident requires recovery',
        () async {
      final repository = _AlreadyActiveLookupRepository(
        authoritativeActive: _incident(
          state: SosState.sent,
          triggerSource: 'external_backend',
          owner: 'external',
        ),
      )..completeTriggerWithAlreadyActive();
      final harness = _SdkSosHarness(sdkSosRepository: repository);
      try {
        await harness.setSession();
        final result = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );

        expect(result.outcome, SosActivationOutcome.alreadyActiveUnmatched);
        expect(result.lifecycle.stage, SosLifecycleStage.recoveryRequired);
        expect(result.lifecycle.backendIncidentId, isNotNull);
        expect(result.lifecycle.localActionable, isFalse);
        final capability = await harness.sdk.getSosCapability();
        expect(capability.canTriggerSos, isFalse);
        expect(capability.lifecycleAllowsActivation, isFalse);
        expect(capability.canCancelCurrentSos, isTrue);
      } finally {
        await harness.dispose(disposeSosRepository: false);
        await repository.dispose();
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

        expect(
          result.outcome,
          SosCancellationOutcome.activeCancellationConfirmed,
        );
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

    test(
        'disconnected MQTT remains app-ready because activation connects on demand',
        () async {
      final realtimeClient = _OnDemandOperationalRealtimeClient();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
      );
      final harness = _SdkSosHarness(
        sdkSosRepository: repository,
        realtimeClient: realtimeClient,
      );
      final transitions = <SosCapabilitySnapshot>[];
      final subscription = harness.sdk.watchSosCapability().listen(
            transitions.add,
          );
      try {
        final initializing = await harness.sdk.getSosCapability();

        expect(initializing.canTriggerSos, isFalse);
        expect(
          initializing.blockingReason,
          SosCapabilityBlockingReason.initializing,
        );
        expect(initializing.transient, isTrue);

        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://api.example.com'),
        );
        await harness.setSession();
        await pumpEventQueue(times: 3);

        final capability = await harness.sdk.getSosCapability();

        expect(realtimeClient.connected, isFalse);
        expect(capability.appTransportReady, isTrue);
        expect(capability.deviceTransportReady, isFalse);
        expect(capability.canTriggerAppSos, isTrue);
        expect(capability.canTriggerDeviceSos, isFalse);
        expect(capability.canTriggerSos, isTrue);
        expect(
          capability.preferredActivationPath,
          SosActivationPath.appBackend,
        );
        expect(
          transitions,
          contains(
            isA<SosCapabilitySnapshot>()
                .having(
                  (value) => value.blockingReason,
                  'blockingReason',
                  SosCapabilityBlockingReason.initializing,
                )
                .having((value) => value.transient, 'transient', isTrue),
          ),
        );
        expect(
          transitions.last,
          isA<SosCapabilitySnapshot>()
              .having(
                (value) => value.canTriggerAppSos,
                'canTriggerAppSos',
                isTrue,
              )
              .having(
                (value) => value.preferredActivationPath,
                'preferredActivationPath',
                SosActivationPath.appBackend,
              ),
        );

        final result = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );

        expect(result.outcome, SosActivationOutcome.activated);
        expect(realtimeClient.publishedSos, hasLength(1));
      } finally {
        await subscription.cancel();
        await harness.dispose(disposeSosRepository: false);
        await repository.dispose();
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
    SosRepository? sdkSosRepository,
    FakeRealtimeClient? realtimeClient,
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
        realtimeClient = realtimeClient ?? FakeRealtimeClient(),
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
      sosRepository: sdkSosRepository ?? this.sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: telemetryRepository,
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deviceRegistryRepository: deviceRegistryRepository,
      deathManRepository: deathManRepository,
      permissionsRepository: permissionsRepository,
      notificationsRepository: notificationsRepository,
      realtimeClient: this.realtimeClient,
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

final class _OnDemandOperationalRealtimeClient extends FakeRealtimeClient
    implements OperationalRealtimeClient {
  bool connected = false;

  @override
  Future<void> connect() async {
    connectCallCount++;
  }

  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    publishedSos.add(request);
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {}

  @override
  Future<void> reconnectIfSessionChanged(EixamSession session) => connect();
}

final class _AlreadyActiveLookupRepository extends FakeSosRepository
    implements AuthoritativeActiveSosLookup {
  _AlreadyActiveLookupRepository({required this.authoritativeActive});

  final SosIncident authoritativeActive;
  final Completer<void> _triggerResponse = Completer<void>();

  void completeTriggerWithAlreadyActive() {
    if (!_triggerResponse.isCompleted) {
      _triggerResponse.complete();
    }
  }

  @override
  Future<SosIncident?> getAuthoritativeActiveSos() async => authoritativeActive;

  @override
  Future<SosIncident> triggerSos({
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
    await _triggerResponse.future;
    throw const SosException(
      'E_SOS_ALREADY_ACTIVE',
      'E_SOS_ALREADY_ACTIVE',
    );
  }
}

final class _BlockingTriggerSosRepository extends FakeSosRepository {
  final Completer<void> triggerStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void releaseTrigger() {
    if (!_release.isCompleted) {
      _release.complete();
    }
  }

  @override
  Future<SosIncident> triggerSos({
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
    if (!triggerStarted.isCompleted) {
      triggerStarted.complete();
    }
    await _release.future;
    return super.triggerSos(
      message: message,
      triggerSource: triggerSource,
      positionSnapshot: positionSnapshot,
      deviceId: deviceId,
      hardwareId: hardwareId,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      relayDeviceId: relayDeviceId,
      relayHardwareId: relayHardwareId,
      relaySource: relaySource,
      incidentId: incidentId,
      cycleKey: cycleKey,
      osWidgetActivation: osWidgetActivation,
      deviceBattery: deviceBattery,
      deviceCoverage: deviceCoverage,
      mobileBattery: mobileBattery,
      mobileCoverage: mobileCoverage,
    );
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
  String? owner,
}) {
  return SosIncident(
    id: 'sos-${triggerSource.replaceAll('_', '-')}',
    state: state,
    createdAt: DateTime.utc(2026, 3, 31, 10),
    triggerSource: triggerSource,
    owner: owner,
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
