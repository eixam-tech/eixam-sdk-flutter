import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_history_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_state.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_event_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:eixam_connect_flutter/src/mappers/local_state_serializers.dart';
import 'package:eixam_connect_flutter/src/sdk/authoritative_sos_lifecycle_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
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
        .setMockMethodCallHandler(backgroundTelemetryMethodChannel, (
          call,
        ) async {
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
    test('terminal receive sequence rejects equal and older evidence', () {
      expect(
        isStrictlyNewerSosReceiveSequence(
          incomingSequence: 41,
          terminalBoundarySequence: 42,
        ),
        isFalse,
      );
      expect(
        isStrictlyNewerSosReceiveSequence(
          incomingSequence: 42,
          terminalBoundarySequence: 42,
        ),
        isFalse,
      );
      expect(
        isStrictlyNewerSosReceiveSequence(
          incomingSequence: 43,
          terminalBoundarySequence: 42,
        ),
        isTrue,
      );
    });

    test(
      'SOS-01 app-origin resolve during countdown resolves and clears',
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
          expect(
            harness.sosRepository.currentIncident.state,
            SosState.resolved,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'resolved summary remains until acknowledged, then returns idle',
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
      },
    );

    test(
      'terminal notification intent includes typed terminal reason only',
      () async {
        final harness = _SdkSosHarness();
        final notificationIntents = <EixamNotificationIntent>[];
        final subscription = harness.sdk.watchNotificationIntents().listen(
          notificationIntents.add,
        );
        try {
          await harness.sdk.triggerSos(const SosTriggerPayload());
          await harness.sdk.cancelSos();
          await pumpEventQueue(times: 2);

          final terminalIntent = notificationIntents
              .where(
                (intent) =>
                    intent.type == EixamNotificationIntentType.sosCancelled,
              )
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
      },
    );

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
      },
    );

    test(
      'public SOS stream accepts canonical sent acknowledge resolve chain',
      () async {
        final harness = _SdkSosHarness();
        try {
          await harness.sdk.triggerSos(const SosTriggerPayload());
          expect(await harness.sdk.getSosState(), SosState.sent);

          harness.sosRepository.currentIncident = harness
              .sosRepository
              .currentIncident
              .copyWith(state: SosState.acknowledged);
          harness.sosRepository.stateController.add(SosState.acknowledged);
          await pumpEventQueue(times: 2);

          expect(await harness.sdk.getSosState(), SosState.acknowledged);

          harness.sosRepository.currentIncident = harness
              .sosRepository
              .currentIncident
              .copyWith(state: SosState.resolved);
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
      },
    );

    test(
      'incident progress stream deduplicates equivalent repository states',
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
        final subscription = harness.sdk.currentSosIncidentProgressStream
            .listen(progress.add);
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
      },
    );

    test('authoritative terminal cancelled state still wins', () async {
      final harness = _SdkSosHarness();
      try {
        await harness.sdk.triggerSos(const SosTriggerPayload());
        expect(await harness.sdk.getSosState(), SosState.sent);

        harness.sosRepository.currentIncident = harness
            .sosRepository
            .currentIncident
            .copyWith(state: SosState.cancelled);
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

    for (final terminalState in <SosState>[
      SosState.cancelled,
      SosState.resolved,
    ]) {
      test('correlated ${terminalState.name} terminal suppresses repeated '
          'same-cycle physical ACTIVE and permits a new packet cycle', () async {
        final secureStore = InMemorySecureKeyValueStore();
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: secureStore,
        );
        final commands = <int>[];
        final observedDebugMessages = <String>[];
        StreamSubscription<BleDebugState>? debugSubscription;
        try {
          await harness.deviceSosController.attach(
            commandWriter: (command) async {
              commands.add(command.opcode);
            },
          );
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          debugSubscription = BleDebugRegistry.instance.watch().listen((state) {
            if (state.events.isNotEmpty) {
              observedDebugMessages.add(state.events.last.message);
            }
          });
          final first = await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await harness.deviceSosController.triggerSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await harness.deviceSosController.confirmSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);

          expect(first.lifecycle.stage, SosLifecycleStage.active);
          expect(
            harness.deviceSosController.currentStatus.state,
            DeviceSosState.active,
          );

          harness.sosRepository.currentIncident = harness
              .sosRepository
              .currentIncident
              .copyWith(state: terminalState, isBackendConfirmed: true);
          if (terminalState == SosState.cancelled) {
            // The MQTT repository's valid ACKNOWLEDGED -> CANCELLED path emits
            // this intermediate state before its terminal state.
            harness.sosRepository.stateController.add(SosState.cancelRequested);
          }
          harness.sosRepository.stateController.add(terminalState);
          await pumpEventQueue(times: 8);

          final terminal = await harness.sdk.getSosLifecycle();
          expect(
            terminal.stage,
            terminalState == SosState.cancelled
                ? SosLifecycleStage.cancelled
                : SosLifecycleStage.resolved,
          );
          expect(terminal.isOpen, isFalse);
          expect(terminal.deviceCycleKey, isNotNull);
          expect(terminal.displaySurface, SosDisplaySurface.historyOnly);
          expect(await harness.sdk.getPreSosStatus(), isNull);
          expect(await harness.sdk.getSosState(), terminalState);
          expect(commands, contains(0x04));
          expect(
            observedDebugMessages.any(
              (message) => message.contains('SOS_TERMINAL_HANDOFF'),
            ),
            isTrue,
          );

          final terminalHandoffIndex = observedDebugMessages.lastIndexWhere(
            (message) => message.contains('SOS_TERMINAL_HANDOFF'),
          );
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);

          // A different packet id is still ambiguous without an observed
          // inactive boundary and cannot silently manufacture lifecycle B.
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);

          // A different node alone is not an authorized third path to B. The
          // device path still requires the physical inactive boundary.
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(packetId: 2, nodeId: 0x5678),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);

          expect((await harness.sdk.getSosLifecycle()).isTerminal, isTrue);
          expect(await harness.sdk.getSosState(), terminalState);
          expect(
            BleDebugRegistry.instance.currentState.events.any(
              (event) =>
                  event.message.contains(
                    'DEVICE_SOS_ACTIVE_SUPPRESSED '
                    'reason=authoritative_terminal_same_cycle',
                  ) ||
                  event.message.contains(
                    'DEVICE_SOS_SAME_CYCLE_REOPEN_SUPPRESSED_AFTER_TERMINAL',
                  ),
            ),
            isTrue,
          );
          final messagesAfterTerminal = observedDebugMessages.skip(
            terminalHandoffIndex + 1,
          );
          expect(
            messagesAfterTerminal.any(
              (message) =>
                  message.contains('SOS_APP_ORIGIN_BLE_ACTIVE_SURFACED'),
            ),
            isFalse,
          );

          harness.sosRepository.currentIncident = SosIncident(
            id: 'sos-new-generation-${terminalState.name}',
            state: SosState.idle,
            createdAt: DateTime.utc(2026, 9, 9, 12),
          );
          final second = await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          expect(second.lifecycle.generation, greaterThan(terminal.generation));
          expect(second.lifecycle.stage, SosLifecycleStage.active);
          await debugSubscription.cancel();
          debugSubscription = null;
          await BleDebugRegistry.instance.resetForLifecycle();

          // A's command was already sent. Its later physical terminal ACK is
          // cleanup evidence for A only and cannot close or replace B.
          harness.deviceSosController.handleIncomingSosEventPacket(
            _deviceResolveAckPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);
          final afterOldAck = await harness.sdk.getSosLifecycle();
          expect(afterOldAck.generation, second.lifecycle.generation);
          expect(afterOldAck.stage, SosLifecycleStage.active);
          expect(await harness.sdk.getSosState(), SosState.sent);
          expect(
            _hasDebugMessage(
              'DEVICE_TERMINAL_ACK_CONSUMED '
              'reason=authoritative_terminal_cleanup',
            ),
            isTrue,
          );
          expect(
            _hasDebugMessage('SOS_DEVICE_ONLY_INCIDENT_RECORDED'),
            isFalse,
          );

          // Old cycle retries remain stale even after generation B starts.
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);
          expect(
            (await harness.sdk.getSosLifecycle()).generation,
            second.lifecycle.generation,
          );

          // A new packet identity is independent cycle evidence and is not
          // rejected merely because it comes from the same TAG.
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);
          final afterNewPacket = await harness.sdk.getSosLifecycle();
          expect(afterNewPacket.generation, second.lifecycle.generation);
          expect(afterNewPacket.stage, SosLifecycleStage.active);
          expect(await harness.sdk.getSosState(), SosState.sent);
        } finally {
          await debugSubscription?.cancel();
          await harness.dispose();
        }
      });
    }

    test(
      'migrated connected TAG starts N+1 from a new packet cycle after restored cancelled N',
      () async {
        final terminalAt = DateTime.now().toUtc();
        var deviceNow = terminalAt.add(const Duration(seconds: 1));
        final secureStore = InMemorySecureKeyValueStore();
        await _seedTerminalDeviceLifecycle(
          secureStore: secureStore,
          terminalAt: terminalAt,
          deviceCycleKey: 'sos:4660:0',
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: secureStore,
          deviceClock: () => deviceNow,
        );
        final observed = <SosLifecycleSnapshot>[];
        final subscription = harness.sdk.sosLifecycleStream.listen(
          observed.add,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          harness.deviceRepository.emitStatus(
            buildDeviceStatus(
              deviceId: 'ble-1',
              nodeId: 0x1234,
              canonicalHardwareId: 'CF:82:00:00:00:01',
            ),
          );
          await pumpEventQueue(times: 2);

          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 6);

          final next = await harness.sdk.getSosLifecycle();
          expect(next.generation, 2);
          expect(next.stage, SosLifecycleStage.arming);
          expect(next.origin, SosLifecycleOrigin.connectedLocalDevice);
          expect(await harness.sdk.getSosState(), SosState.arming);
          expect((await harness.sdk.getPreSosStatus())?.packetId, 1);
          expect(
            observed,
            contains(
              isA<SosLifecycleSnapshot>()
                  .having((value) => value.generation, 'generation', 2)
                  .having(
                    (value) => value.stage,
                    'stage',
                    SosLifecycleStage.arming,
                  ),
            ),
          );
          expect(
            secureStore.values.values.single,
            contains('"stage":"cancelled"'),
          );
        } finally {
          await subscription.cancel();
          await harness.dispose();
        }
      },
    );

    test('restored terminal rejects the same cancelled packet cycle', () async {
      final terminalAt = DateTime.now().toUtc();
      final secureStore = InMemorySecureKeyValueStore();
      await _seedTerminalDeviceLifecycle(
        secureStore: secureStore,
        terminalAt: terminalAt,
        deviceCycleKey: 'sos:4660:0',
      );
      final harness = _SdkSosHarness(
        connectedBle: true,
        sosLifecycleSecureStore: secureStore,
        deviceClock: () => terminalAt.add(const Duration(seconds: 1)),
      );
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await harness.setSession();

        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacketForCycle(packetId: 0),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 4);
        var lifecycle = await harness.sdk.getSosLifecycle();
        expect(lifecycle.generation, 1);
        expect(lifecycle.stage, SosLifecycleStage.cancelled);
        expect(
          _hasDebugMessage('SOS_REPLAY_REJECTED reason=same_cycle'),
          isTrue,
        );
      } finally {
        await harness.dispose();
      }
    });

    test(
      'post-terminal device E1 boundary admits a later reused packet cycle',
      () async {
        final terminalAt = DateTime.now().toUtc();
        var deviceNow = terminalAt.add(const Duration(seconds: 1));
        final secureStore = InMemorySecureKeyValueStore();
        await _seedTerminalDeviceLifecycle(
          secureStore: secureStore,
          terminalAt: terminalAt,
          deviceCycleKey: 'sos:4660:0',
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: secureStore,
          deviceClock: () => deviceNow,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          harness.deviceRepository.emitStatus(
            buildDeviceStatus(
              deviceId: 'ble-1',
              nodeId: 0x1234,
              canonicalHardwareId: 'CF:82:00:00:00:01',
            ),
          );
          await pumpEventQueue(times: 2);

          // Backend terminal handling has already closed the local controller.
          // This real E1 is still the authoritative physical inactive edge.
          expect(
            harness.deviceSosController.currentStatus.state,
            DeviceSosState.inactive,
          );
          harness.deviceSosController.handleIncomingSosEventPacket(
            _deviceCancelPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 4);
          expect(
            _hasDebugMessage('SOS_DEVICE_INACTIVE_BOUNDARY_RECORDED'),
            isTrue,
          );
          expect(_hasDebugMessage('ordering=after_terminal'), isTrue);

          deviceNow = deviceNow.add(const Duration(seconds: 6));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(packetId: 0),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 6);

          final arming = await harness.sdk.getSosLifecycle();
          expect(arming.generation, 2);
          expect(arming.stage, SosLifecycleStage.arming);
          expect(arming.origin, SosLifecycleOrigin.connectedLocalDevice);
          expect((await harness.sdk.getPreSosStatus())?.packetId, 0);

          deviceNow = deviceNow.add(const Duration(seconds: 21));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 0),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 6);
          final active = await harness.sdk.getSosLifecycle();
          expect(active.generation, arming.generation);
          expect(active.stage, SosLifecycleStage.active);

          deviceNow = deviceNow.add(const Duration(seconds: 1));
          harness.deviceSosController.handleIncomingSosEventPacket(
            _devicePostFireCancelPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 6);
          final cancelled = await harness.sdk.getSosLifecycle();
          expect(cancelled.generation, arming.generation);
          expect(cancelled.stage, SosLifecycleStage.cancelled);
        } finally {
          await harness.dispose();
        }
      },
    );

    for (final retryDelay in <Duration>[
      const Duration(milliseconds: 500),
      const Duration(seconds: 11),
    ]) {
      test(
        'physical retry reuses raw identity after ${retryDelay.inMilliseconds}ms without a cooldown',
        () async {
          final terminalAt = DateTime.now().toUtc();
          var deviceNow = terminalAt.add(const Duration(seconds: 1));
          final secureStore = InMemorySecureKeyValueStore();
          await _seedTerminalDeviceLifecycle(
            secureStore: secureStore,
            terminalAt: terminalAt,
            deviceCycleKey: 'sos:4660:1',
            generation: 5,
          );
          final harness = _SdkSosHarness(
            connectedBle: true,
            sosLifecycleSecureStore: secureStore,
            deviceClock: () => deviceNow,
          );
          try {
            await harness.sdk.initialize(
              const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
            );
            await harness.setSession();
            harness.deviceRepository.emitStatus(
              buildDeviceStatus(
                deviceId: 'ble-1',
                nodeId: 0x1234,
                canonicalHardwareId: 'CF:82:00:00:00:01',
              ),
            );
            await pumpEventQueue(times: 2);

            final generationPacket = _deviceOriginActivePacketForCycle(
              packetId: 0,
            );
            harness.deviceSosController.handleIncomingSosPacket(
              generationPacket,
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 6);
            expect((await harness.sdk.getSosLifecycle()).generation, 6);

            deviceNow = deviceNow.add(const Duration(seconds: 21));
            harness.deviceSosController.handleIncomingSosPacket(
              generationPacket,
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 6);
            expect(
              (await harness.sdk.getSosLifecycle()).stage,
              SosLifecycleStage.active,
            );

            deviceNow = deviceNow.add(const Duration(seconds: 1));
            harness.deviceSosController.handleIncomingSosEventPacket(
              _devicePostFireCancelPacket(),
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 6);
            final terminal = await harness.sdk.getSosLifecycle();
            expect(terminal.generation, 6);
            expect(terminal.stage, SosLifecycleStage.cancelled);

            // An exact notification from N remains a replay even with no delay.
            harness.deviceSosController.handleIncomingSosPacket(
              generationPacket,
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 4);
            expect((await harness.sdk.getSosLifecycle()).generation, 6);
            expect(
              (await harness.sdk.getSosLifecycle()).stage,
              SosLifecycleStage.cancelled,
            );

            deviceNow = deviceNow.add(retryDelay);
            final retryPacket = _deviceOriginActivePacketForCycle(
              packetId: 0,
              batteryLevel: 1,
            );
            harness.deviceSosController.handleIncomingSosPacket(
              retryPacket,
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 6);

            final arming = await harness.sdk.getSosLifecycle();
            expect(arming.generation, 7);
            expect(arming.stage, SosLifecycleStage.arming);
            expect(arming.origin, SosLifecycleOrigin.connectedLocalDevice);
            expect((await harness.sdk.getPreSosStatus())?.packetId, 0);
            expect(
              _hasDebugMessage(
                'SOS_TERMINAL_FENCE_FRESH_PHYSICAL_EDGE_ACCEPTED',
              ),
              isTrue,
            );
            expect(
              BleDebugRegistry.instance.currentState.events.any(
                (event) =>
                    event.message.contains(
                      'admission=direct_device_rising_edge',
                    ) ||
                    event.message.contains('admission=inactive_boundary'),
              ),
              isTrue,
            );
            expect(_hasDebugMessage('SOS_NEW_GENERATION_ACCEPTED'), isTrue);

            // The same N+1 notification remains in generation 7.
            harness.deviceSosController.handleIncomingSosPacket(
              retryPacket,
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 3);
            expect((await harness.sdk.getSosLifecycle()).generation, 7);
            expect(
              (await harness.sdk.getSosLifecycle()).stage,
              SosLifecycleStage.arming,
            );
          } finally {
            await harness.dispose();
          }
        },
      );
    }

    test(
      'relay packet cannot reuse a terminal own-device cycle identity',
      () async {
        final terminalAt = DateTime.now().toUtc();
        final secureStore = InMemorySecureKeyValueStore();
        await _seedTerminalDeviceLifecycle(
          secureStore: secureStore,
          terminalAt: terminalAt,
          deviceCycleKey: 'sos:4660:0',
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: secureStore,
          deviceClock: () => terminalAt.add(const Duration(seconds: 11)),
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          harness.deviceRepository.emitStatus(
            buildDeviceStatus(
              deviceId: 'ble-1',
              nodeId: 0x1234,
              canonicalHardwareId: 'CF:82:00:00:00:01',
            ),
          );
          await pumpEventQueue(times: 2);

          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 0, relayCount: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);

          final lifecycle = await harness.sdk.getSosLifecycle();
          expect(lifecycle.generation, 1);
          expect(lifecycle.stage, SosLifecycleStage.cancelled);
          expect(_hasDebugMessage('SOS_REPLAY_REJECTED'), isTrue);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'restored terminal rejects a new cycle with weak device identity',
      () async {
        final terminalAt = DateTime.now().toUtc();
        final secureStore = InMemorySecureKeyValueStore();
        await _seedTerminalDeviceLifecycle(
          secureStore: secureStore,
          terminalAt: terminalAt,
          deviceCycleKey: 'sos:4660:0',
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: secureStore,
          deviceClock: () => terminalAt.add(const Duration(seconds: 1)),
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();

          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 4);

          final lifecycle = await harness.sdk.getSosLifecycle();
          expect(lifecycle.generation, 1);
          expect(lifecycle.stage, SosLifecycleStage.cancelled);
          expect(
            _hasDebugMessage('SOS_REPLAY_REJECTED reason=weak_identity'),
            isTrue,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'wall-clock skew does not block a monotonic new physical cycle',
      () async {
        final terminalAt = DateTime.now().toUtc();
        final secureStore = InMemorySecureKeyValueStore();
        await _seedTerminalDeviceLifecycle(
          secureStore: secureStore,
          terminalAt: terminalAt,
          deviceCycleKey: 'sos:4660:0',
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: secureStore,
          deviceClock: () => terminalAt.subtract(const Duration(seconds: 1)),
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          harness.deviceRepository.emitStatus(
            buildDeviceStatus(
              deviceId: 'ble-1',
              nodeId: 0x1234,
              canonicalHardwareId: 'CF:82:00:00:00:01',
            ),
          );
          await pumpEventQueue(times: 2);

          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 4);

          final lifecycle = await harness.sdk.getSosLifecycle();
          expect(lifecycle.generation, 2);
          expect(lifecycle.stage, SosLifecycleStage.arming);
          expect(_hasDebugMessage('wallClockAfterTerminal=false'), isTrue);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'device cancel after restored terminal closes only accepted N+1',
      () async {
        final terminalAt = DateTime.now().toUtc();
        var deviceNow = terminalAt.add(const Duration(seconds: 1));
        final secureStore = InMemorySecureKeyValueStore();
        await _seedTerminalDeviceLifecycle(
          secureStore: secureStore,
          terminalAt: terminalAt,
          deviceCycleKey: 'sos:4660:0',
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: secureStore,
          deviceClock: () => deviceNow,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          harness.deviceRepository.emitStatus(
            buildDeviceStatus(
              deviceId: 'ble-1',
              nodeId: 0x1234,
              canonicalHardwareId: 'CF:82:00:00:00:01',
            ),
          );
          await pumpEventQueue(times: 2);
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);
          expect((await harness.sdk.getSosLifecycle()).generation, 2);

          deviceNow = deviceNow.add(const Duration(seconds: 1));
          harness.deviceSosController.handleIncomingSosEventPacket(
            _deviceCancelPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 6);

          final cancelled = await harness.sdk.getSosLifecycle();
          expect(cancelled.generation, 2);
          expect(cancelled.stage, SosLifecycleStage.cancelled);
          expect(await harness.sdk.getPreSosStatus(), isNull);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'late backend terminal for N cannot close N+1 but matching N+1 terminal does',
      () async {
        final terminalAt = DateTime.now().toUtc();
        var deviceNow = terminalAt.add(const Duration(seconds: 1));
        final secureStore = InMemorySecureKeyValueStore();
        await _seedTerminalDeviceLifecycle(
          secureStore: secureStore,
          terminalAt: terminalAt,
          deviceCycleKey: 'sos:4660:0',
        );
        final realtime = _OnDemandOperationalRealtimeClient();
        final repository = _ControllableMqttOperationalSosRepository(realtime);
        final harness = _SdkSosHarness(
          sdkSosRepository: repository,
          realtimeClient: realtime,
          connectedBle: true,
          sosLifecycleSecureStore: secureStore,
          deviceClock: () => deviceNow,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          harness.deviceRepository.emitStatus(
            buildDeviceStatus(
              deviceId: 'ble-1',
              nodeId: 0x1234,
              canonicalHardwareId: 'CF:82:00:00:00:01',
            ),
          );
          await pumpEventQueue(times: 2);
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);
          deviceNow = deviceNow.add(const Duration(seconds: 21));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 8);

          final active = await harness.sdk.getSosLifecycle();
          final activeIncident = await repository.getCurrentIncident();
          expect(active.generation, 2);
          expect(active.stage, SosLifecycleStage.active);
          expect(activeIncident, isNotNull);
          expect(active.localIncidentId, isNotNull);

          repository.emitTerminal(
            SosIncident(
              id: 'old-generation-terminal',
              state: SosState.cancelled,
              createdAt: terminalAt,
              originatorNodeId: 0x1234,
              deviceId: 'ble-1',
              hardwareId: 'CF:82:00:00:00:01',
              cycleKey: 'sos:4660:0',
              isBackendConfirmed: true,
            ),
          );
          await pumpEventQueue(times: 6);

          var current = await harness.sdk.getSosLifecycle();
          expect(current.generation, 2);
          expect(current.stage, SosLifecycleStage.active);
          expect(
            harness.deviceSosController.currentStatus.state,
            DeviceSosState.active,
          );
          expect(await harness.sdk.getSosState(), SosState.sent);

          repository.emitTerminal(
            SosIncident(
              id: active.localIncidentId!,
              state: SosState.resolved,
              createdAt: active.activationTimestamp!,
              originatorNodeId: 0x1234,
              deviceId: 'ble-1',
              hardwareId: 'CF:82:00:00:00:01',
              isBackendConfirmed: true,
            ),
          );
          await pumpEventQueue(times: 6);

          current = await harness.sdk.getSosLifecycle();
          expect(current.generation, 2);
          expect(current.stage, SosLifecycleStage.resolved);
        } finally {
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'physical inactive boundary permits a fresh device SOS generation',
      () async {
        var deviceNow = DateTime.now();
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
          deviceClock: () => deviceNow,
        );
        try {
          await harness.deviceSosController.attach(commandWriter: (_) async {});
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          final first = await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await harness.deviceSosController.triggerSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await harness.deviceSosController.confirmSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);

          harness.sosRepository.currentIncident = harness
              .sosRepository
              .currentIncident
              .copyWith(state: SosState.resolved, isBackendConfirmed: true);
          harness.sosRepository.stateController.add(SosState.resolved);
          await pumpEventQueue(times: 6);
          final terminal = await harness.sdk.getSosLifecycle();
          expect(terminal.stage, SosLifecycleStage.resolved);

          deviceNow = deviceNow.add(const Duration(seconds: 1));
          harness.deviceSosController.handleIncomingSosEventPacket(
            _deviceResolveAckPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);
          expect(
            _hasDebugMessage('SOS_TERMINAL_FENCE_DEVICE_CLEANUP_PRESERVED'),
            isTrue,
          );
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );

          deviceNow = deviceNow.add(const Duration(milliseconds: 500));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(batteryLevel: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 4);
          deviceNow = deviceNow.add(const Duration(seconds: 21));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 0),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 6);

          final second = await harness.sdk.getSosLifecycle();
          expect(second.generation, greaterThan(first.lifecycle.generation));
          expect(second.stage, SosLifecycleStage.active);
          expect(second.origin, SosLifecycleOrigin.connectedLocalDevice);
        } finally {
          await harness.dispose();
        }
      },
    );

    for (final terminalState in <SosState>[
      SosState.cancelled,
      SosState.resolved,
    ]) {
      test(
        'inactive before ${terminalState.name} publication allows reused TAG identity and active promotion',
        () async {
          var deviceNow = DateTime.now();
          final harness = _SdkSosHarness(
            connectedBle: true,
            sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
            deviceClock: () => deviceNow,
          );
          try {
            await harness.deviceSosController.attach(
              commandWriter: (command) async {
                if (command.opcode == 0x04) {
                  scheduleMicrotask(() {
                    deviceNow = deviceNow.add(const Duration(seconds: 1));
                    harness.deviceSosController.handleIncomingSosEventPacket(
                      _deviceResolveAckPacket(),
                      source: DeviceSosTransitionSource.device,
                    );
                  });
                }
              },
            );
            await harness.sdk.initialize(
              const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
            );
            await harness.setSession();
            final first = await harness.sdk.triggerSosAuthoritatively(
              const SosTriggerPayload(triggerSource: 'commercial_app'),
            );
            await harness.deviceSosController.triggerSos();
            harness.deviceSosController.handleIncomingSosPacket(
              _deviceOriginCountdownPacket(),
              source: DeviceSosTransitionSource.device,
            );
            await harness.deviceSosController.confirmSos();
            harness.deviceSosController.handleIncomingSosPacket(
              _deviceOriginActivePacket(),
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 5);

            if (terminalState == SosState.cancelled) {
              final result = await harness.sdk.cancelSosAuthoritatively();
              expect(
                result.outcome,
                SosCancellationOutcome.activeCancellationConfirmed,
              );
            } else {
              await harness.sdk.resolveSos();
            }
            await pumpEventQueue(times: 8);

            final terminal = await harness.sdk.getSosLifecycle();
            expect(terminal.generation, first.lifecycle.generation);
            expect(terminal.isTerminal, isTrue);

            deviceNow = deviceNow.add(const Duration(milliseconds: 500));
            harness.deviceSosController.handleIncomingSosPacket(
              _deviceOriginCountdownPacket(batteryLevel: 1),
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 5);

            final arming = await harness.sdk.getSosLifecycle();
            expect(arming.generation, terminal.generation + 1);
            expect(arming.stage, SosLifecycleStage.arming);
            expect(arming.origin, SosLifecycleOrigin.connectedLocalDevice);
            expect((await harness.sdk.getPreSosStatus())?.packetId, 0);
            expect(
              _hasDebugMessage(
                'SOS_TERMINAL_FENCE_FRESH_PHYSICAL_EDGE_ACCEPTED',
              ),
              isTrue,
            );
            expect(_hasDebugMessage('rawIdentityReused=true'), isTrue);

            // The same accepted TAG generation still promotes through the full
            // device-originated activation path.
            deviceNow = deviceNow.add(const Duration(seconds: 21));
            harness.deviceSosController.handleIncomingSosPacket(
              _deviceOriginActivePacketForCycle(packetId: 0),
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 6);
            final active = await harness.sdk.getSosLifecycle();
            expect(active.generation, arming.generation);
            expect(active.stage, SosLifecycleStage.active);
          } finally {
            await harness.dispose();
          }
        },
      );
    }

    test(
      'delayed old preConfirm and active remain fenced while incremented identity opens after the boundary',
      () async {
        var deviceNow = DateTime.now();
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
          deviceClock: () => deviceNow,
        );
        try {
          await harness.deviceSosController.attach(
            commandWriter: (command) async {
              if (command.opcode == 0x04) {
                scheduleMicrotask(() {
                  deviceNow = deviceNow.add(const Duration(seconds: 1));
                  harness.deviceSosController.handleIncomingSosEventPacket(
                    _deviceResolveAckPacket(),
                    source: DeviceSosTransitionSource.device,
                  );
                });
              }
            },
          );
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await harness.deviceSosController.triggerSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await harness.deviceSosController.confirmSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);

          final result = await harness.sdk.cancelSosAuthoritatively();
          expect(
            result.outcome,
            SosCancellationOutcome.activeCancellationConfirmed,
          );
          await pumpEventQueue(times: 8);
          final terminal = await harness.sdk.getSosLifecycle();
          expect(terminal.stage, SosLifecycleStage.cancelled);

          // These arrive inside the controller's terminal-cycle freshness
          // window. Their receive order/time identifies them as delayed N
          // traffic; packet identity is not the sole discriminator.
          deviceNow = deviceNow.add(const Duration(seconds: 1));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(),
            source: DeviceSosTransitionSource.device,
          );
          deviceNow = deviceNow.add(const Duration(seconds: 1));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacketForCycle(packetId: 0),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 6);

          expect(
            (await harness.sdk.getSosLifecycle()).generation,
            terminal.generation,
          );
          expect((await harness.sdk.getSosLifecycle()).isTerminal, isTrue);
          expect(
            harness.deviceSosController.currentStatus.state,
            DeviceSosState.inactive,
          );
          expect(
            _hasDebugMessage('SOS_DEVICE_TERMINAL_PACKET_REPLAY_REJECTED'),
            isTrue,
          );

          deviceNow = deviceNow.add(const Duration(seconds: 6));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(packetId: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 6);

          final next = await harness.sdk.getSosLifecycle();
          expect(next.generation, terminal.generation + 1);
          expect(next.stage, SosLifecycleStage.arming);
          expect((await harness.sdk.getPreSosStatus())?.packetId, 1);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'new TAG countdown can be app-cancelled before immediate app retry',
      () async {
        var deviceNow = DateTime.now();
        final harness = _SdkSosHarness(
          connectedBle: true,
          sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
          deviceClock: () => deviceNow,
        );
        try {
          await harness.deviceSosController.attach(
            commandWriter: (command) async {
              if (command.opcode == 0x04) {
                scheduleMicrotask(() {
                  deviceNow = deviceNow.add(const Duration(seconds: 1));
                  harness.deviceSosController.handleIncomingSosEventPacket(
                    _deviceResolveAckPacket(),
                    source: DeviceSosTransitionSource.device,
                  );
                });
              }
            },
          );
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          final first = await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await harness.deviceSosController.triggerSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await harness.deviceSosController.confirmSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);

          final firstCancelled = await harness.sdk.cancelSosAuthoritatively();
          expect(
            firstCancelled.outcome,
            SosCancellationOutcome.activeCancellationConfirmed,
          );
          await pumpEventQueue(times: 8);

          deviceNow = deviceNow.add(const Duration(milliseconds: 500));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(batteryLevel: 1),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);
          final deviceArming = await harness.sdk.getSosLifecycle();
          expect(deviceArming.generation, first.lifecycle.generation + 1);
          expect(deviceArming.stage, SosLifecycleStage.arming);
          expect((await harness.sdk.getPreSosStatus())?.packetId, 0);

          final cancelled = await harness.sdk.cancelSosAuthoritatively();
          expect(
            cancelled.outcome,
            SosCancellationOutcome.activeCancellationConfirmed,
          );
          expect(cancelled.lifecycle.generation, deviceArming.generation);
          expect(cancelled.lifecycle.stage, SosLifecycleStage.cancelled);
          expect(await harness.sdk.getPreSosStatus(), isNull);

          harness.sosRepository.currentIncident = SosIncident(
            id: 'ready-for-immediate-app-retry',
            state: SosState.idle,
            createdAt: DateTime.now().toUtc(),
          );
          final retry = await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          expect(retry.lifecycle.generation, deviceArming.generation + 1);
          expect(retry.lifecycle.stage, SosLifecycleStage.active);
        } finally {
          await harness.dispose();
        }
      },
    );

    test('terminal fence rejects a stale repository sent projection', () async {
      final harness = _SdkSosHarness(
        sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
      );
      try {
        await harness.setSession();
        await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        final canonical = harness.sosRepository.currentIncident.copyWith(
          state: SosState.resolved,
          isBackendConfirmed: true,
        );
        harness.sosRepository.currentIncident = canonical;
        harness.sosRepository.stateController.add(SosState.resolved);
        await pumpEventQueue(times: 5);
        expect(
          (await harness.sdk.getSosLifecycle()).stage,
          SosLifecycleStage.resolved,
        );

        harness.sosRepository.currentIncident = canonical.copyWith(
          state: SosState.sent,
        );
        harness.sosRepository.stateController.add(SosState.sent);
        await pumpEventQueue(times: 5);

        expect(
          (await harness.sdk.getSosLifecycle()).stage,
          SosLifecycleStage.resolved,
        );
        expect(await harness.sdk.getSosState(), SosState.resolved);
        expect(
          _hasDebugMessage(
            'SOS_TERMINAL_FENCE_SUPPRESSED_OPEN source=repository_sent '
            'reason=authoritative_backend_terminal',
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

    test(
      'backend unavailable with device available returns device-only SOS',
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
          harness.sosRepository.triggerError = const NetworkException(
            'E_NETWORK',
            'offline',
          );

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
          expect(
            currentIncident?.deliveryChannel,
            SosDeliveryChannel.deviceOnly,
          );
          expect(
            currentIncident?.progress.steps.first.state,
            SosProgressState.pending,
          );
          expect(
            currentIncident?.progress.steps.first.detailCode,
            'awaiting_backend_confirmation',
          );
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
      },
    );

    test(
      'device activation plus MQTT publish failure returns device-only SOS',
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
            _hasDebugMessage(
              'SOS_TRIGGER_DEVICE_ONLY_BACKEND_FAILED_NON_FATAL',
            ),
            isTrue,
          );
          expect(
            _hasDebugMessage('SOS_TRIGGER_DEVICE_ONLY_SUCCESS_RETURNED'),
            isTrue,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

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
        harness.sosRepository.triggerError = const NetworkException(
          'E_NETWORK',
          'offline',
        );

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

    test(
      'device activation failure plus backend failure still throws',
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
                'E_DEVICE_WRITE_FAILED',
                'write failed',
              );
            },
          );
          harness.sosRepository.triggerError = const NetworkException(
            'E_NETWORK',
            'offline',
          );

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
      },
    );

    test(
      'backend unavailable with device unavailable throws SOS failure',
      () async {
        final harness = _SdkSosHarness();
        try {
          harness.sosRepository.triggerError = const NetworkException(
            'E_NETWORK',
            'offline',
          );
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
      },
    );

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

    test(
      'backend available with device unavailable returns backend SOS',
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
      },
    );

    test(
      'external remote relay public trigger remains non-actionable',
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
      },
    );

    test(
      'SOS-03 app-origin cancel during countdown stops before send',
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
      },
    );

    test(
      'app pre-SOS write completion awaits real TAG evidence before mirror confirmation',
      () async {
        var deviceNow = DateTime.now();
        final harness = _SdkSosHarness(
          connectedBle: true,
          deviceClock: () => deviceNow,
        );
        final commands = <EixamDeviceCommand>[];
        StreamSubscription<BleDebugState>? debugSubscription;
        try {
          await harness.deviceSosController.attach(
            commandWriter: (command) async => commands.add(command),
          );
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          final capability = await harness.sdk.getSosCapability();
          expect(
            capability.preferredActivationPath,
            SosActivationPath.appBackend,
          );
          expect(capability.canTriggerDeviceSos, isTrue);
          await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

          var preSos = await harness.sdk.getPreSosStatus();
          expect(commands, hasLength(1));
          expect(commands.single.opcode, 0x06);
          expect(commands.single.encode(), <int>[0x06]);
          expect(
            commands.single.targetCharacteristicUuid,
            EixamBleProtocol.cmdWriteCharacteristicUuid,
          );
          expect(preSos, isNotNull);
          expect(preSos!.mirroredOnDevice, isFalse);
          expect(harness.deviceSosController.currentStatus.optimistic, isTrue);
          expect(_hasDebugMessage('SOS_DEVICE_COMMAND_ACK_MISSING'), isTrue);

          final generation = (await harness.sdk.getSosLifecycle()).generation;
          final observedMessages = <String>[];
          debugSubscription = BleDebugRegistry.instance.watch().listen((state) {
            if (state.events.isNotEmpty) {
              observedMessages.add(state.events.last.message);
            }
          });
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);

          preSos = await harness.sdk.getPreSosStatus();
          expect(preSos, isNotNull);
          expect(preSos!.mirroredOnDevice, isTrue);
          expect((await harness.sdk.getSosLifecycle()).generation, generation);
          expect(
            observedMessages.any(
              (message) => message.contains('SOS_DEVICE_COMMAND_ACK_OBSERVED'),
            ),
            isTrue,
          );
          expect(
            observedMessages.any(
              (message) => message.contains(
                'SOS_DEVICE_STATE_OBSERVED state=preConfirm',
              ),
            ),
            isTrue,
          );

          deviceNow = deviceNow.add(const Duration(seconds: 21));
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await pumpEventQueue(times: 6);
          expect((await harness.sdk.getSosLifecycle()).generation, generation);
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.active,
          );
        } finally {
          await debugSubscription?.cancel();
          await harness.dispose();
        }
      },
    );

    test(
      'app pre-SOS without a ready command channel never claims device mirroring',
      () async {
        final harness = _SdkSosHarness(connectedBle: true);
        try {
          await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

          final preSos = await harness.sdk.getPreSosStatus();
          expect(preSos, isNotNull);
          expect(preSos!.mirroredOnDevice, isFalse);
          expect(
            _hasDebugMessage('reason=pre_sos_device_path_unavailable'),
            isTrue,
          );
          expect(
            _hasDebugMessage(
              'SOS_DEVICE_MIRROR_DECISION attempt=false '
              'reason=command_channel_not_ready',
            ),
            isTrue,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'native SOS command targets the exact connected TAG and awaits its packet',
      () async {
        final adapter = _SnapshotProtectionPlatformAdapter(
          const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.androidService,
            serviceBleConnected: true,
            serviceBleReady: true,
            protectedDeviceId: 'CF:82:00:00:00:01',
            activeDeviceId: 'CF:82:00:00:00:01',
          ),
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          protectionPlatformAdapter: adapter,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

          expect(adapter.commands, hasLength(1));
          expect(adapter.commands.single.label, 'SOS TRIGGER APP');
          expect(adapter.commands.single.bytes, <int>[0x06]);
          expect(adapter.commands.single.forceCmdCharacteristic, isTrue);
          expect(
            (await harness.sdk.getPreSosStatus())?.mirroredOnDevice,
            isFalse,
          );
          expect(
            _hasDebugMessage('SOS_DEVICE_COMMAND_TARGET_CONFIRMED'),
            isTrue,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'native takeover refreshes authoritative command readiness without Flutter reconnect',
      () async {
        final adapter = _SnapshotProtectionPlatformAdapter(
          const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.flutter,
          ),
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          protectionPlatformAdapter: adapter,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          await harness.sdk.rehydrateProtectionState();

          adapter.snapshot = const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.androidService,
            serviceBleConnected: true,
            protectedDeviceId: 'CF:82:00:00:00:01',
            activeDeviceId: 'CF:82:00:00:00:01',
          );
          await harness.sdk.rehydrateProtectionState();

          adapter.snapshot = const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.androidService,
            serviceBleConnected: true,
            serviceBleReady: false,
            protectedDeviceId: 'CF:82:00:00:00:01',
            activeDeviceId: 'CF:82:00:00:00:01',
          );
          await harness.sdk.rehydrateProtectionState();
          expect(
            (await harness.sdk.getProtectionStatus()).bleOwner,
            ProtectionBleOwner.androidService,
          );

          // The subscriptionsActive event was missed, but the native store
          // contains the authoritative, command-ready snapshot.
          adapter.snapshot = const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.androidService,
            serviceBleConnected: true,
            serviceBleReady: true,
            protectedDeviceId: 'CF:82:00:00:00:01',
            activeDeviceId: 'CF:82:00:00:00:01',
          );

          final capability = await harness.sdk.getSosCapability();
          expect(capability.deviceTransportReady, isTrue);
          expect(capability.commandChannelReady, isTrue);
          expect(capability.canTriggerDeviceSos, isTrue);

          await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));
          expect(adapter.commands, hasLength(1));
          expect(adapter.commands.single.bytes, <int>[0x06]);
          expect(adapter.commands.single.forceCmdCharacteristic, isTrue);
          expect(_hasDebugMessage('action=reclaim'), isFalse);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'native command-ready event makes immediate App SOS mirror available before subscriptions finish',
      () async {
        final adapter = _SnapshotProtectionPlatformAdapter(
          const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.flutter,
          ),
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          protectionPlatformAdapter: adapter,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          await harness.sdk.rehydrateProtectionState();

          adapter.snapshot = const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.androidService,
            serviceBleConnected: true,
            serviceBleReady: false,
            nativeCommandServiceReady: true,
            nativeCommandEa04Ready: true,
            nativeCommandIdentityReady: true,
            nativeCommandQueueHealthy: true,
            nativeCommandReady: true,
            protectedDeviceId: 'CF:82:00:00:00:01',
            activeDeviceId: 'CF:82:00:00:00:01',
          );
          adapter.emit(
            ProtectionPlatformEvent(
              type: ProtectionPlatformEventType.nativeCommandReadinessChanged,
              timestamp: DateTime.now().toUtc(),
              reason: 'eixam_service_and_ea04_discovered',
              gattConnected: true,
              serviceReady: true,
              cmdEa04Ready: true,
              identityReady: true,
              queueHealthy: true,
              nativeCommandReady: true,
              previousNativeCommandReady: false,
            ),
          );
          await pumpEventQueue(times: 5);

          final capability = await harness.sdk.getSosCapability();
          expect(capability.deviceTransportReady, isTrue);
          expect(capability.commandChannelReady, isTrue);
          expect(capability.canTriggerDeviceSos, isTrue);
          expect(
            _hasDebugMessage('SOS_NATIVE_COMMAND_READINESS_INPUT'),
            isTrue,
          );
          expect(
            _hasDebugMessage('SOS_NATIVE_COMMAND_READINESS_CHANGED'),
            isTrue,
          );
          expect(
            _hasDebugMessage('SOS_NATIVE_COMMAND_READINESS_PROPAGATED'),
            isTrue,
          );

          await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));
          expect(adapter.commands, hasLength(1));
          expect(adapter.commands.single.bytes, <int>[0x06]);
          expect(
            (await harness.sdk.getProtectionStatus()).bleOwner,
            ProtectionBleOwner.androidService,
          );
          expect(_hasDebugMessage('action=reclaim'), isFalse);
        } finally {
          await harness.dispose();
          await adapter.dispose();
        }
      },
    );

    test(
      'native raw SOS diagnostic precedes classifier with matching receive marker',
      () async {
        const payloadHex = 'a81a4b5948cd1b34442800c0';
        final adapter = _SnapshotProtectionPlatformAdapter(
          const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.androidService,
            serviceBleConnected: true,
            nativeCommandServiceReady: true,
            nativeCommandEa04Ready: true,
            nativeCommandIdentityReady: true,
            nativeCommandQueueHealthy: true,
            nativeCommandReady: true,
            protectedDeviceId: 'CF:82:00:00:00:01',
            activeDeviceId: 'CF:82:00:00:00:01',
          ),
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          connectedNodeId: 0x594B1AA8,
          protectionPlatformAdapter: adapter,
        );
        StreamSubscription<BleDebugState>? debugSubscription;
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          await harness.sdk.rehydrateProtectionState();
          final observedMessages = <String>[];
          debugSubscription = BleDebugRegistry.instance.watch().listen((state) {
            if (state.events.isNotEmpty) {
              observedMessages.add(state.events.last.message);
            }
          });

          final observedAt = DateTime.now().toUtc();
          adapter.emit(
            ProtectionPlatformEvent(
              type: ProtectionPlatformEventType.bleNotificationReceived,
              timestamp: observedAt,
              payloadHex: payloadHex,
              source: 'sos_notify',
              characteristicUuid: '6ba1b218-15a8-461f-9fa8-5dcae273ea02',
              byteLength: 12,
              packetType: 'sos',
              firstOpcode: '0xa8',
              receiveSequence: 41,
              receiveCorrelation: 'native-41',
              connectedDeviceMarker: 'CF:82:...:01',
            ),
          );
          await pumpEventQueue(times: 3);
          expect(
            _hasDebugMessage(
              'EIXAM_BLE_NOTIFICATION_RX owner=native_protection '
              'correlation=native-41',
            ),
            isTrue,
          );

          adapter.emit(
            ProtectionPlatformEvent(
              type: ProtectionPlatformEventType.ownDeviceSosLifecycleObserved,
              timestamp: observedAt,
              reason: 'own:sos:$payloadHex',
              classification: 'own_device',
            ),
          );
          await pumpEventQueue(times: 8);

          final rawIndex = observedMessages.indexWhere(
            (message) =>
                message.contains('EIXAM_BLE_NOTIFICATION_RX') &&
                message.contains('correlation=native-41'),
          );
          final classifierIndex = observedMessages.indexWhere(
            (message) =>
                message.contains('BLE_SOS_CLASSIFY_DECISION') &&
                message.contains('correlation=native-41') &&
                message.contains('receiveSequence=41'),
          );
          expect(rawIndex, greaterThanOrEqualTo(0));
          expect(classifierIndex, greaterThan(rawIndex));
        } finally {
          await debugSubscription?.cancel();
          await harness.dispose();
          await adapter.dispose();
        }
      },
    );

    test(
      'native SOS command rejects a stale owner bound to another TAG',
      () async {
        final adapter = _SnapshotProtectionPlatformAdapter(
          const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.androidService,
            serviceBleConnected: true,
            serviceBleReady: true,
            protectedDeviceId: 'CF:82:00:00:00:99',
            activeDeviceId: 'CF:82:00:00:00:99',
          ),
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          protectionPlatformAdapter: adapter,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          final capability = await harness.sdk.getSosCapability();
          expect(capability.commandChannelReady, isFalse);
          expect(capability.canTriggerDeviceSos, isFalse);
          await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

          expect(adapter.commands, isEmpty);
          expect(
            (await harness.sdk.getPreSosStatus())?.mirroredOnDevice,
            isFalse,
          );
          expect(
            _hasDebugMessage('nativeReadinessFailure=targetIdentityMismatch'),
            isTrue,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'native SOS dispatch completes only after the native GATT result',
      () async {
        final gattResult = Completer<ProtectionPlatformCommandResult>();
        final adapter = _SnapshotProtectionPlatformAdapter(
          const ProtectionPlatformSnapshot(
            backgroundCapabilityReady: true,
            serviceRunning: true,
            runtimeActive: true,
            platform: ProtectionPlatform.android,
            bleOwner: ProtectionBleOwner.androidService,
            serviceBleConnected: true,
            serviceBleReady: true,
            protectedDeviceId: 'CF:82:00:00:00:01',
            activeDeviceId: 'CF:82:00:00:00:01',
          ),
          commandResult: gattResult,
        );
        final harness = _SdkSosHarness(
          connectedBle: true,
          protectionPlatformAdapter: adapter,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          var completed = false;
          final start = harness.sdk
              .startPreSos(countdown: const Duration(seconds: 20))
              .whenComplete(() => completed = true);
          await pumpEventQueue(times: 3);

          expect(adapter.commands, hasLength(1));
          expect(completed, isFalse);
          expect(
            (await harness.sdk.getPreSosStatus())?.mirroredOnDevice,
            isNot(isTrue),
          );

          gattResult.complete(
            const ProtectionPlatformCommandResult(
              success: true,
              route: 'androidService',
              result: 'SOS TRIGGER APP native GATT status 0',
            ),
          );
          await start;

          expect(completed, isTrue);
          expect(
            (await harness.sdk.getPreSosStatus())?.mirroredOnDevice,
            isFalse,
          );
          expect(_hasDebugMessage('SOS_DEVICE_COMMAND_ACK_MISSING'), isTrue);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'typed pending cancellation invalidates countdown generation without backend calls',
      () async {
        final harness = _SdkSosHarness();
        final stages = <SosLifecycleStage>[];
        final subscription = harness.sdk.sosLifecycleStream
            .map((value) => value.stage)
            .listen(stages.add);
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
      },
    );

    test(
      'app-originated retry starts immediately without a terminal cooldown',
      () async {
        final harness = _SdkSosHarness();
        try {
          await harness.sdk.startPreSos(countdown: const Duration(seconds: 1));
          final first = await harness.sdk.cancelSosAuthoritatively();
          expect(
            first.outcome,
            SosCancellationOutcome.pendingActivationCancelled,
          );
          final firstGeneration = first.lifecycle.generation;

          await harness.sdk.startPreSos(
            countdown: const Duration(milliseconds: 60),
          );
          await Future<void>.delayed(const Duration(milliseconds: 180));

          expect(harness.sosRepository.triggerCallCount, 1);
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.active,
          );
          expect(
            (await harness.sdk.getSosLifecycle()).generation,
            firstGeneration + 1,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

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
        expect(second.outcome, SosCancellationOutcome.noActionableLifecycle);
        expect(second.lifecycle.stage, SosLifecycleStage.cancelled);
        expect(harness.sosRepository.triggerCallCount, 0);
        expect(harness.sosRepository.cancelCallCount, 0);
      } finally {
        await harness.dispose();
      }
    });

    test(
      'process recreation after pending cancellation never restores active',
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
      },
    );

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
      },
    );

    test('characterization: locally actionable lifecycle mutations feed the '
        'public SOS state', () async {
      final harness = _SdkSosHarness(
        connectedBle: true,
        deviceCountdown: const Duration(milliseconds: 35),
      );
      final states = <SosState>[];
      final subscription = harness.sdk.currentSosStateStream.listen(states.add);
      final lifecycles = <SosLifecycleSnapshot>[];
      final lifecycleSubscription = harness.sdk.sosLifecycleStream.listen(
        lifecycles.add,
      );
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

        harness.sosRepository.currentIncident = harness
            .sosRepository
            .currentIncident
            .copyWith(state: SosState.idle);
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
        expect(lifecycleAfterStaleIdle.revision, acceptedLifecycle.revision);
      } finally {
        await lifecycleSubscription.cancel();
        await subscription.cancel();
        await harness.dispose();
      }
    });

    test(
      'SOS-04 BLE app-origin cancel requests backend and clears state',
      () async {
        final harness = _SdkSosHarness(connectedBle: true);
        final commands = <int>[];
        try {
          await harness.deviceSosController.attach(
            commandWriter: (command) async {
              commands.add(command.opcode);
            },
          );
          await harness.sdk.triggerSos(const SosTriggerPayload());

          await harness.sdk.cancelSos();

          expect(harness.sosRepository.cancelCallCount, 1);
          expect(commands, contains(0x04));
          expect(
            _hasDebugMessage('primitive=terminatePhysicalSosOnCurrentDevice'),
            isTrue,
          );
          expect(await harness.sdk.getSosState(), SosState.idle);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'SOS-04b BLE active cancel ignores residual preConfirm status',
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
      },
    );

    test(
      'SOS-05 BLE app-origin resolve requests backend and clears state',
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
      },
    );

    test('SOS-06 BLE device cancel clears app-origin active SOS', () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.attachObservedDeviceCloseAck();
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        harness.sosRepository.currentIncident = harness
            .sosRepository
            .currentIncident
            .copyWith(state: SosState.sent, triggerSource: 'app');

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
        final terminalLifecycle = await harness.sdk.getSosLifecycle();
        expect(terminalLifecycle.stage, SosLifecycleStage.cancelled);
      } finally {
        await harness.dispose();
      }
    });

    test(
      'SOS-07 BLE device-origin countdown cancel clears countdown',
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
      },
    );

    test(
      'app pre-SOS cancel terminalizes generation and permits immediate re-arm',
      () async {
        final harness = _SdkSosHarness();
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          await harness.sdk.startPreSos();
          final first = await harness.sdk.getSosLifecycle();

          await harness.sdk.cancelPreSos();

          final cancelled = await harness.sdk.getSosLifecycle();
          final capability = await harness.sdk.getSosCapability();
          expect(cancelled.lifecycleId, first.lifecycleId);
          expect(cancelled.generation, first.generation);
          expect(cancelled.stage, SosLifecycleStage.cancelled);
          expect(cancelled.isOpen, isFalse);
          expect(capability.canTriggerSos, isTrue);

          await harness.sdk.startPreSos();
          final second = await harness.sdk.getSosLifecycle();
          expect(second.stage, SosLifecycleStage.arming);
          expect(second.generation, greaterThan(first.generation));
          expect(second.lifecycleId, isNot(first.lifecycleId));
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'backend-only app terminal does not poison a later physical TAG edge',
      () async {
        final harness = _SdkSosHarness(
          connectedBle: true,
          connectedNodeId: 0x1234,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();

          await harness.sdk.startPreSos();
          final appGeneration = await harness.sdk.getSosLifecycle();
          expect(
            (await harness.sdk.getPreSosStatus())?.mirroredOnDevice,
            isFalse,
          );
          expect(
            _hasDebugMessage(
              'SOS_DEVICE_MIRROR_DECISION attempt=false '
              'reason=command_channel_not_ready',
            ),
            isTrue,
          );

          await harness.sdk.cancelPreSos();
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.cancelled,
          );

          final generationDiagnostics = <String>[];
          final diagnosticsSubscription = BleDebugRegistry.instance
              .watch()
              .listen((state) {
                if (state.events.isNotEmpty) {
                  generationDiagnostics.add(state.events.last.message);
                }
              });
          try {
            harness.deviceSosController.handleIncomingSosPacket(
              _deviceOriginCountdownPacket(packetId: 0),
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue();
          } finally {
            await diagnosticsSubscription.cancel();
          }

          final physicalGeneration = await harness.sdk.getSosLifecycle();
          expect(physicalGeneration.generation, appGeneration.generation + 1);
          expect(physicalGeneration.stage, SosLifecycleStage.arming);
          expect(
            physicalGeneration.origin,
            SosLifecycleOrigin.connectedLocalDevice,
          );
          expect(
            generationDiagnostics.any(
              (message) => message.contains(
                'admission=backend_only_app_then_physical_edge',
              ),
            ),
            isTrue,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'device pre-SOS app cancel terminalizes generation and permits app re-arm',
      () async {
        final harness = _SdkSosHarness(connectedBle: true);
        try {
          await harness.deviceSosController.attach(commandWriter: (_) async {});
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);
          final first = await harness.sdk.getSosLifecycle();
          expect(first.stage, SosLifecycleStage.arming);

          await harness.sdk.cancelPreSos();

          final cancelled = await harness.sdk.getSosLifecycle();
          expect(cancelled.stage, SosLifecycleStage.cancelled);
          expect(cancelled.generation, first.generation);
          expect((await harness.sdk.getSosCapability()).canTriggerSos, isTrue);

          await harness.sdk.startPreSos();
          final second = await harness.sdk.getSosLifecycle();
          expect(second.stage, SosLifecycleStage.arming);
          expect(second.generation, greaterThan(first.generation));
        } finally {
          await harness.dispose();
        }
      },
    );

    test('physical E1 closes matching app-origin pre-SOS generation', () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.deviceSosController.attach(commandWriter: (_) async {});
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await harness.setSession();
        await harness.sdk.startPreSos();
        final arming = await harness.sdk.getSosLifecycle();

        harness.deviceSosController.handleIncomingSosEventPacket(
          _deviceCancelPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 4);

        final terminal = await harness.sdk.getSosLifecycle();
        expect(terminal.lifecycleId, arming.lifecycleId);
        expect(terminal.generation, arming.generation);
        expect(terminal.stage, SosLifecycleStage.cancelled);
        expect(terminal.isOpen, isFalse);
        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(
          await harness.sdk.getSosState(),
          isNot(anyOf(SosState.arming, SosState.sent, SosState.acknowledged)),
        );
        expect(harness.sosRepository.cancelCallCount, 0);

        await harness.sdk.startPreSos();
        final restarted = await harness.sdk.getSosLifecycle();
        expect(restarted.stage, SosLifecycleStage.arming);
        expect(restarted.generation, greaterThan(arming.generation));
      } finally {
        await harness.dispose();
      }
    });

    test('E2 command echo does not cancel app-origin pre-SOS', () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.deviceSosController.attach(commandWriter: (_) async {});
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await harness.setSession();
        await harness.sdk.startPreSos();
        final arming = await harness.sdk.getSosLifecycle();

        harness.deviceSosController.handleIncomingSosEventPacket(
          _deviceCancelAckPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 3);

        final afterEcho = await harness.sdk.getSosLifecycle();
        expect(afterEcho.lifecycleId, arming.lifecycleId);
        expect(afterEcho.generation, arming.generation);
        expect(afterEcho.stage, SosLifecycleStage.arming);
        expect(await harness.sdk.getPreSosStatus(), isNotNull);
        expect(harness.sosRepository.cancelCallCount, 0);
        expect(
          _hasDebugMessage('device_terminal_command_ack_ignored event=0xE2'),
          isTrue,
        );
      } finally {
        await harness.dispose();
      }
    });

    test('old pre-SOS E1 cannot close a newer active generation', () async {
      final harness = _SdkSosHarness(connectedBle: true);
      try {
        await harness.deviceSosController.attach(commandWriter: (_) async {});
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await harness.setSession();
        await harness.sdk.startPreSos();
        final first = await harness.sdk.getSosLifecycle();
        await harness.sdk.cancelPreSos();

        final second = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        expect(second.lifecycle.generation, greaterThan(first.generation));
        expect(second.lifecycle.stage, SosLifecycleStage.active);

        harness.deviceSosController.handleIncomingSosEventPacket(
          _deviceCancelPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 4);

        final afterStaleE1 = await harness.sdk.getSosLifecycle();
        expect(afterStaleE1.lifecycleId, second.lifecycle.lifecycleId);
        expect(afterStaleE1.generation, second.lifecycle.generation);
        expect(afterStaleE1.stage, SosLifecycleStage.active);
        expect(harness.sosRepository.cancelCallCount, 0);
        expect(
          _hasDebugMessage('SOS_PHYSICAL_PRE_SOS_CANCEL_REJECTED'),
          isTrue,
        );
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
        harness.sosRepository.currentIncident = harness
            .sosRepository
            .currentIncident
            .copyWith(
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
        expect(<SosState>[
          SosState.idle,
          SosState.cancelled,
        ], contains(await harness.sdk.getSosState()));
        expect(
          await harness.sdk.getCurrentSosTerminalReason(),
          SosTerminalReason.cancelledByUser,
        );
      } finally {
        await harness.dispose();
      }
    });

    test(
      'device-origin 0xE1 post-fire cancel closes authoritative lifecycle',
      () async {
        final harness = _SdkSosHarness(
          connectedBle: true,
          deviceCountdown: const Duration(milliseconds: 5),
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          harness.sosRepository.currentIncident = harness
              .sosRepository
              .currentIncident
              .copyWith(
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
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.active,
          );

          harness.deviceSosController.handleIncomingSosEventPacket(
            _devicePostFireCancelPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);

          expect(harness.sosRepository.cancelCallCount, 1);
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.cancelled,
          );
          expect(await harness.sdk.getSosState(), SosState.cancelled);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'device-origin 0xE1 still closes lifecycle when backend cancel fails',
      () async {
        final harness = _SdkSosHarness(
          connectedBle: true,
          deviceCountdown: const Duration(milliseconds: 5),
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          harness.sosRepository.cancelError = const SosException(
            'E_SOS_CANCEL_FAILED',
            'E_SOS_CANCEL_FAILED',
          );
          harness.sosRepository.currentIncident = harness
              .sosRepository
              .currentIncident
              .copyWith(
                state: SosState.sent,
                triggerSource: 'ble_device_runtime',
              );
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await Future<void>.delayed(const Duration(milliseconds: 15));
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.active,
          );

          harness.deviceSosController.handleIncomingSosEventPacket(
            _devicePostFireCancelPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 3);

          expect(harness.sosRepository.cancelCallCount, 1);
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.cancelled,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'app cancel of provisional sos-* confirms cancelled when HTTP fails',
      () async {
        final harness = _SdkSosHarness();
        try {
          await harness.setSession();
          harness.sosRepository.cancelError = const SosException(
            'E_SOS_CANCEL_FAILED',
            'E_SOS_CANCEL_FAILED',
          );
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );

          final result = await harness.sdk.cancelSosAuthoritatively();

          expect(
            result.outcome,
            SosCancellationOutcome.activeCancellationConfirmed,
          );
          expect(result.lifecycle.stage, SosLifecycleStage.cancelled);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'device-only cancelRequested of provisional sos-* confirms cancelled',
      () async {
        final repository = _PendingCancellationSosRepository(
          initialIncident: SosIncident(
            id: 'sos-1784553184064842',
            state: SosState.sent,
            createdAt: DateTime.utc(2026, 9, 5),
          ),
        );
        final harness = _SdkSosHarness(sosRepository: repository);
        try {
          await harness.setSession();
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          repository.cancelResult = SosIncident(
            id: 'sos-1784553184064842',
            state: SosState.cancelRequested,
            createdAt: DateTime.utc(2026, 9, 5),
            deliveryChannel: SosDeliveryChannel.deviceOnly,
          );

          final result = await harness.sdk.cancelSosAuthoritatively();

          expect(
            result.outcome,
            SosCancellationOutcome.activeCancellationConfirmed,
          );
          expect(result.lifecycle.stage, SosLifecycleStage.cancelled);
        } finally {
          await harness.dispose();
        }
      },
    );

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
        harness.sosRepository.currentIncident = harness
            .sosRepository
            .currentIncident
            .copyWith(
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
        harness.sosRepository.currentIncident = harness
            .sosRepository
            .currentIncident
            .copyWith(
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

    test(
      'authenticated uncorrelated terminal closes only after no-active lookup',
      () async {
        final repository = FakeRejectedTerminalRehydratingSosRepository()
          ..rehydrationResult = const SosRuntimeRehydrationResult(
            outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
            resultingState: SosState.idle,
          );
        final harness = _SdkSosHarness(sosRepository: repository);
        try {
          await harness.setSession();
          await harness.sdk.triggerSos(const SosTriggerPayload());
          final beforeRequest = repository.rehydrateCallCount;

          repository.emitRejectedTerminal(SosState.cancelled);
          await pumpEventQueue(times: 4);

          expect(repository.rehydrateCallCount, greaterThan(beforeRequest));
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.cancelled,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test('real backend RESOLVED JSON rejection reaches authenticated absence '
        'and terminal lifecycle', () async {
      final realtime = _OnDemandOperationalRealtimeClient();
      final remote = _NoActiveSosRemoteDataSource();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtime,
        remoteDataSource: remote,
        cancelRemoteDataSource: remote,
      );
      final harness = _SdkSosHarness(
        sdkSosRepository: repository,
        realtimeClient: realtime,
      );
      try {
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await harness.setSession();
        await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        final lookupsBeforeTerminal = remote.getActiveSosCalls;
        final parsed = SdkMqttContract.parseRealtimeEvent(
          topic: 'sos/events/external-123',
          payload: jsonEncode(const <String, dynamic>{
            'type': 'resolved',
            'appId': '550e8400-e29b-41d4-a716-446655440001',
            'userId': 'external-123',
            'incidentId': '7c9e6679-7425-40de-944b-e07fc1f90ae7',
            'status': 'resolved',
            'occurredAt': '2026-09-09T10:00:00.000Z',
            'openedAt': '2026-09-09T09:55:00.000Z',
            'updatedAt': '2026-09-09T10:00:00.000Z',
            'resolvedAt': '2026-09-09T10:00:00.000Z',
          }),
        );
        realtime.emitEvent(
          RealtimeEvent(
            type: parsed.type,
            timestamp: parsed.timestamp,
            payload: <String, dynamic>{
              ...?parsed.payload,
              '_mqttAuthenticatedUserScoped': true,
              '_mqttTopicCategory': 'legacy_alias',
            },
          ),
        );
        await pumpEventQueue(times: 6);

        expect(remote.getActiveSosCalls, greaterThan(lookupsBeforeTerminal));
        expect(await repository.getSosState(), SosState.idle);
        expect(await repository.getCurrentIncident(), isNull);
        expect(
          (await harness.sdk.getSosLifecycle()).stage,
          SosLifecycleStage.resolved,
        );
        expect(await harness.sdk.getSosState(), SosState.idle);
      } finally {
        await harness.dispose(disposeSosRepository: false);
        await repository.dispose();
      }
    });

    test('production MQTT processed handoff stays backend-confirmed when the '
        'provisional activation return resumes later', () async {
      final localStore = _DelayedSosIncidentStore();
      final realtime = _OnDemandOperationalRealtimeClient();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtime,
        localStore: localStore,
      );
      final harness = _SdkSosHarness(
        sdkSosRepository: repository,
        realtimeClient: realtime,
        localStore: localStore,
        sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
      );
      try {
        await harness.setSession();
        localStore.delayNextSosIncidentWrite();
        final activation = harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        await localStore.sosIncidentWriteStarted;
        final provisionalIncident = await repository.getCurrentIncident();
        expect(provisionalIncident, isNotNull);
        final publishedAt = realtime.publishedSos.single.timestamp.toUtc();

        const canonicalIncidentId = '7c9e6679-7425-40de-944b-e07fc1f90ab1';
        realtime.emitEvent(
          RealtimeEvent(
            type: 'processed',
            timestamp: publishedAt.add(const Duration(seconds: 1)),
            payload: <String, dynamic>{
              'type': 'processed',
              'status': 'active',
              'incidentId': canonicalIncidentId,
              'userId': 'external-123',
              'occurredAt': publishedAt.toIso8601String(),
              'openedAt': publishedAt.toIso8601String(),
              'updatedAt': publishedAt
                  .add(const Duration(seconds: 1))
                  .toIso8601String(),
              '_mqttAuthenticatedUserScoped': true,
              '_mqttTopicCategory': 'legacy_alias',
            },
          ),
        );
        await pumpEventQueue(times: 8);

        localStore.completeSosIncidentWrite();
        final result = await activation;
        await pumpEventQueue(times: 4);

        expect(result.lifecycle.backendIncidentId, canonicalIncidentId);
        expect(result.lifecycle.incident?.id, canonicalIncidentId);
        expect(result.lifecycle.incident?.isBackendConfirmed, isTrue);
        final lifecycle = await harness.sdk.getSosLifecycle();
        expect(lifecycle.backendIncidentId, canonicalIncidentId);
        expect(lifecycle.incident?.id, canonicalIncidentId);
        expect(lifecycle.incident?.isBackendConfirmed, isTrue);
        expect(
          _hasDebugMessage(
            'SOS_MQTT_EVENT_AUTHORITY_ACCEPTED '
            'reason=processed_publish_timestamp_match',
          ),
          isTrue,
        );
      } finally {
        localStore.completeSosIncidentWriteIfPending();
        await harness.dispose(disposeSosRepository: false);
        await repository.dispose();
      }
    });

    test(
      'production MQTT processed handoff survives stale repository sent callback',
      () async {
        final realtime = _OnDemandOperationalRealtimeClient();
        final repository = _DelayableMqttOperationalSosRepository(realtime);
        final harness = _SdkSosHarness(
          sdkSosRepository: repository,
          realtimeClient: realtime,
          sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
        );
        try {
          await harness.setSession();
          repository.delayLookupAfter();
          final activation = harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await repository.delayedLookupStarted;
          final activationResult = await activation;
          final provisionalIncident = activationResult.incident!;
          final publishedAt = realtime.publishedSos.single.timestamp.toUtc();

          const canonicalIncidentId = '7c9e6679-7425-40de-944b-e07fc1f90ab2';
          realtime.emitEvent(
            _processedEvent(
              canonicalIncidentId: canonicalIncidentId,
              publishedAt: publishedAt,
            ),
          );
          await pumpEventQueue(times: 8);
          expect(
            (await harness.sdk.getSosLifecycle()).incident?.isBackendConfirmed,
            isTrue,
          );

          repository.releaseDelayedLookup();
          await pumpEventQueue(times: 8);

          final lifecycle = await harness.sdk.getSosLifecycle();
          expect(lifecycle.localIncidentId, provisionalIncident.id);
          expect(lifecycle.backendIncidentId, canonicalIncidentId);
          expect(lifecycle.incident?.id, canonicalIncidentId);
          expect(lifecycle.incident?.isBackendConfirmed, isTrue);
        } finally {
          repository.releaseDelayedLookupIfPending();
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'production app-device ACTIVE race preserves canonical ownership through terminal clear',
      () async {
        final realtime = _OnDemandOperationalRealtimeClient();
        final repository = _DelayableMqttOperationalSosRepository(realtime);
        final harness = _SdkSosHarness(
          sdkSosRepository: repository,
          realtimeClient: realtime,
          connectedBle: true,
          sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
          appTriggeredSosBridgeWindow: const Duration(milliseconds: 500),
        );
        final commands = <int>[];
        try {
          await harness.deviceSosController.attach(
            commandWriter: (command) async {
              commands.add(command.opcode);
              if (command.opcode == 0x06) {
                scheduleMicrotask(() {
                  harness.deviceSosController.handleIncomingSosPacket(
                    _deviceOriginCountdownPacket(),
                    source: DeviceSosTransitionSource.device,
                  );
                });
              } else if (command.opcode == 0x05) {
                scheduleMicrotask(() {
                  harness.deviceSosController.handleIncomingSosPacket(
                    _deviceOriginActivePacket(),
                    source: DeviceSosTransitionSource.device,
                  );
                });
              }
            },
          );
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          final activation = await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await harness.deviceSosController.triggerSos();
          await pumpEventQueue(times: 3);
          await harness.deviceSosController.confirmSos();
          await pumpEventQueue(times: 8);
          expect(
            harness.deviceSosController.currentStatus.state,
            DeviceSosState.active,
          );
          final provisionalIncident = activation.incident!;
          final publishedAt = realtime.publishedSos.single.timestamp.toUtc();

          // The first lookup checks terminal suppression. The second is the
          // ACTIVE lifecycle reconciliation whose provisional snapshot is held
          // until after the processed callback installs canonical identity.
          repository.delayLookupAfter(immediateLookups: 1);
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await repository.delayedLookupStarted;
          await BleDebugRegistry.instance.resetForLifecycle();

          const canonicalIncidentId = '7c9e6679-7425-40de-944b-e07fc1f90ab3';
          realtime.emitEvent(
            _processedEvent(
              canonicalIncidentId: canonicalIncidentId,
              publishedAt: publishedAt,
            ),
          );
          await pumpEventQueue(times: 8);
          repository.releaseDelayedLookup();
          await pumpEventQueue(times: 10);

          var lifecycle = await harness.sdk.getSosLifecycle();
          expect(lifecycle.origin, SosLifecycleOrigin.localApp);
          expect(lifecycle.localIncidentId, provisionalIncident.id);
          expect(lifecycle.backendIncidentId, canonicalIncidentId);
          expect(lifecycle.incident?.id, canonicalIncidentId);
          expect(lifecycle.incident?.isBackendConfirmed, isTrue);
          expect(
            _hasDebugMessage('SOS_APP_ORIGIN_DEVICE_OWNERSHIP_CAPTURED'),
            isTrue,
          );

          realtime.emitEvent(
            RealtimeEvent(
              type: 'sos.actuator_update',
              timestamp: publishedAt.add(const Duration(seconds: 2)),
              payload: <String, dynamic>{
                'type': 'sos.actuator_update',
                'incidentId': canonicalIncidentId,
                'userId': 'external-123',
                'snapshotVersion': 4,
                'updatedAt': publishedAt
                    .add(const Duration(seconds: 2))
                    .toIso8601String(),
                '_mqttAuthenticatedUserScoped': true,
                '_mqttTopicCategory': 'internal',
                'actuators': const <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'contacts',
                    'type': 'emergency_contacts',
                    'status': 'delivered',
                    'outcome': 'success',
                  },
                ],
              },
            ),
          );
          await pumpEventQueue(times: 8);
          lifecycle = await harness.sdk.getSosLifecycle();
          expect(lifecycle.incident?.isBackendConfirmed, isTrue);
          expect(lifecycle.incident?.id, canonicalIncidentId);
          expect(lifecycle.incident?.actuators?.snapshotVersion, 4);

          // Hold the ACTIVE device callback after it captured open repository
          // evidence. The terminal must fence its eventual continuation.
          repository.delayLookupAfter(immediateLookups: 1);
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await repository.delayedLookupStarted;

          // Durable ownership must outlive the short-lived correlation bridge.
          await Future<void>.delayed(const Duration(milliseconds: 550));
          realtime.emitEvent(
            RealtimeEvent(
              type: 'resolved',
              timestamp: publishedAt.add(const Duration(seconds: 3)),
              payload: <String, dynamic>{
                'type': 'resolved',
                'status': 'resolved',
                'incidentId': canonicalIncidentId,
                'userId': 'external-123',
                '_mqttAuthenticatedUserScoped': true,
                '_mqttTopicCategory': 'internal',
              },
            ),
          );
          await pumpEventQueue(times: 10);

          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
          repository.releaseDelayedLookup();
          await pumpEventQueue(times: 10);
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
          expect(commands, contains(0x04));
          expect(
            _hasDebugMessage('SOS_REMOTE_TERMINAL_DEVICE_CLEAR_DISPATCHED'),
            isTrue,
          );

          realtime.emitEvent(
            _processedEvent(
              canonicalIncidentId: canonicalIncidentId,
              publishedAt: publishedAt.add(const Duration(seconds: 4)),
            ),
          );
          realtime.emitEvent(
            RealtimeEvent(
              type: 'sos.actuator_update',
              timestamp: publishedAt.add(const Duration(seconds: 5)),
              payload: <String, dynamic>{
                'type': 'sos.actuator_update',
                'incidentId': canonicalIncidentId,
                'userId': 'external-123',
                'snapshotVersion': 5,
                'updatedAt': publishedAt
                    .add(const Duration(seconds: 5))
                    .toIso8601String(),
                '_mqttAuthenticatedUserScoped': true,
                '_mqttTopicCategory': 'internal',
                'actuators': const <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'contacts',
                    'type': 'emergency_contacts',
                    'status': 'delivered',
                    'outcome': 'success',
                  },
                ],
              },
            ),
          );
          await pumpEventQueue(times: 10);
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
        } finally {
          repository.releaseDelayedLookupIfPending();
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'production missed processed uses authenticated actuator plus active lookup before resolved',
      () async {
        final realtime = _OnDemandOperationalRealtimeClient();
        final remote = _NoActiveSosRemoteDataSource();
        final repository = MqttOperationalSosRepository(
          realtimeClient: realtime,
          remoteDataSource: remote,
          mqttConfirmationWarningDelay: const Duration(milliseconds: 200),
        );
        final harness = _SdkSosHarness(
          sdkSosRepository: repository,
          realtimeClient: realtime,
          sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          final activation = await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          final localIncident = activation.incident!;
          expect(localIncident.isBackendConfirmed, isFalse);

          const canonicalIncidentId = '7c9e6679-7425-40de-944b-e07fc1f90af1';
          remote.active = SosIncidentDto(
            id: canonicalIncidentId,
            state: 'active',
            createdAt: localIncident.createdAt.toIso8601String(),
            triggerSource: 'commercial_app',
            owner: 'app',
            originKind: SosOriginKind.app.name,
            actionability: SosActionability.localActionable.name,
            displaySurface: SosDisplaySurface.activeAndHistory.name,
          );
          final actuatorAt = localIncident.createdAt.add(
            const Duration(seconds: 1),
          );
          realtime.emitEvent(
            RealtimeEvent(
              type: 'sos.actuator_update',
              timestamp: actuatorAt,
              payload: <String, dynamic>{
                'type': 'sos.actuator_update',
                'incidentId': canonicalIncidentId,
                'userId': 'external-123',
                'snapshotVersion': 3,
                'updatedAt': actuatorAt.toIso8601String(),
                '_mqttAuthenticatedUserScoped': true,
                '_mqttTopicCategory': 'internal',
                'actuators': const <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': 'contacts',
                    'type': 'emergency_contacts',
                    'status': 'delivered',
                    'outcome': 'success',
                  },
                ],
              },
            ),
          );
          await pumpEventQueue(times: 4);
          expect(
            (await harness.sdk.getSosLifecycle()).incident?.isBackendConfirmed,
            isFalse,
          );

          await Future<void>.delayed(const Duration(milliseconds: 250));
          await pumpEventQueue(times: 8);

          final confirmed = await harness.sdk.getSosLifecycle();
          expect(confirmed.stage, SosLifecycleStage.active);
          expect(confirmed.backendIncidentId, canonicalIncidentId);
          expect(confirmed.incident?.id, canonicalIncidentId);
          expect(confirmed.incident?.isBackendConfirmed, isTrue);
          expect(confirmed.incident?.actuators?.snapshotVersion, 3);
          expect(
            _hasDebugMessage(
              'SOS_BACKEND_CONFIRMATION_REST_ACCEPTED '
              'reason=authenticated_actuator_canonical_match',
            ),
            isTrue,
          );

          realtime.emitEvent(
            RealtimeEvent(
              type: 'resolved',
              timestamp: actuatorAt.add(const Duration(seconds: 1)),
              payload: const <String, dynamic>{
                'type': 'resolved',
                'status': 'resolved',
                'incidentId': canonicalIncidentId,
                'userId': 'external-123',
                '_mqttAuthenticatedUserScoped': true,
                '_mqttTopicCategory': 'internal',
              },
            ),
          );
          await pumpEventQueue(times: 8);

          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
          expect(await harness.sdk.getSosState(), SosState.resolved);
        } finally {
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    for (final testCase
        in <
          ({
            SosState terminalState,
            bool failDeviceClear,
            bool hardwareOnlyInDeviceId,
          })
        >[
          (
            terminalState: SosState.cancelled,
            failDeviceClear: false,
            hardwareOnlyInDeviceId: false,
          ),
          (
            terminalState: SosState.resolved,
            failDeviceClear: false,
            hardwareOnlyInDeviceId: false,
          ),
          (
            terminalState: SosState.resolved,
            failDeviceClear: true,
            hardwareOnlyInDeviceId: false,
          ),
          (
            terminalState: SosState.cancelled,
            failDeviceClear: false,
            hardwareOnlyInDeviceId: true,
          ),
          (
            terminalState: SosState.resolved,
            failDeviceClear: false,
            hardwareOnlyInDeviceId: true,
          ),
        ]) {
      final terminalState = testCase.terminalState;
      final failDeviceClear = testCase.failDeviceClear;
      final hardwareOnlyInDeviceId = testCase.hardwareOnlyInDeviceId;
      test(
        'production MQTT processed handoff then accepted '
        '${terminalState.name} blocks physical ACTIVE retry'
        '${failDeviceClear ? " when device clear fails" : ""}'
        '${hardwareOnlyInDeviceId ? " with Android MAC only in deviceId" : ""}',
        () async {
          final realtime = _OnDemandOperationalRealtimeClient();
          final cancelRemote = _DelayedCancelSosRemoteDataSource();
          final repository = MqttOperationalSosRepository(
            realtimeClient: realtime,
            remoteDataSource: cancelRemote,
            cancelRemoteDataSource: cancelRemote,
          );
          final harness = _SdkSosHarness(
            sdkSosRepository: repository,
            realtimeClient: realtime,
            connectedBle: true,
            connectedDeviceId: hardwareOnlyInDeviceId
                ? 'cf:82:00:00:00:01'
                : 'ble-1',
            connectedCanonicalHardwareId: hardwareOnlyInDeviceId
                ? null
                : 'CF:82:00:00:00:01',
            sosLifecycleSecureStore: InMemorySecureKeyValueStore(),
            appTriggeredSosBridgeWindow: const Duration(milliseconds: 100),
          );
          final commands = <int>[];
          final observedDebugMessages = <String>[];
          StreamSubscription<BleDebugState>? terminalDebugSubscription;
          bool observedDebugMessage(String value) =>
              observedDebugMessages.any((message) => message.contains(value));
          try {
            await harness.deviceSosController.attach(
              commandWriter: (command) async {
                commands.add(command.opcode);
                if (command.opcode == 0x06) {
                  scheduleMicrotask(() {
                    harness.deviceSosController.handleIncomingSosPacket(
                      _deviceOriginCountdownPacket(),
                      source: DeviceSosTransitionSource.device,
                    );
                  });
                } else if (command.opcode == 0x05) {
                  scheduleMicrotask(() {
                    harness.deviceSosController.handleIncomingSosPacket(
                      _deviceOriginActivePacket(),
                      source: DeviceSosTransitionSource.device,
                    );
                  });
                } else if (command.opcode == 0x04) {
                  if (failDeviceClear) {
                    throw StateError('simulated terminal command failure');
                  }
                }
              },
            );
            await harness.sdk.initialize(
              const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
            );
            await harness.setSession();
            await harness.sdk.triggerSosAuthoritatively(
              const SosTriggerPayload(triggerSource: 'commercial_app'),
            );
            await harness.deviceSosController.triggerSos();
            await pumpEventQueue(times: 3);
            await harness.deviceSosController.confirmSos();
            await pumpEventQueue(times: 5);
            final provisionalIncident = await repository.getCurrentIncident();
            expect(provisionalIncident, isNotNull);
            final publishedAt = realtime.publishedSos.single.timestamp.toUtc();

            final canonicalIncidentId = terminalState == SosState.cancelled
                ? '7c9e6679-7425-40de-944b-e07fc1f90ac1'
                : '7c9e6679-7425-40de-944b-e07fc1f90ae1';
            realtime.emitEvent(
              RealtimeEvent(
                type: 'processed',
                timestamp: publishedAt.add(const Duration(seconds: 1)),
                payload: <String, dynamic>{
                  'type': 'processed',
                  'status': 'active',
                  'incidentId': canonicalIncidentId,
                  'userId': 'external-123',
                  'occurredAt': publishedAt.toIso8601String(),
                  'openedAt': publishedAt.toIso8601String(),
                  'updatedAt': publishedAt
                      .add(const Duration(seconds: 1))
                      .toIso8601String(),
                  '_mqttAuthenticatedUserScoped': true,
                  '_mqttTopicCategory': 'legacy_alias',
                },
              ),
            );
            await pumpEventQueue(times: 8);

            final canonicalIncident = await repository.getCurrentIncident();
            expect(canonicalIncident?.id, canonicalIncidentId);
            expect(canonicalIncident?.isBackendConfirmed, isTrue);
            final confirmedLifecycle = await harness.sdk.getSosLifecycle();
            expect(confirmedLifecycle.backendIncidentId, canonicalIncidentId);
            expect(confirmedLifecycle.incident?.isBackendConfirmed, isTrue);
            if (hardwareOnlyInDeviceId) {
              expect(confirmedLifecycle.hardwareId, 'CF:82:00:00:00:01');
            }
            expect(_hasDebugMessage('SOS_MQTT_PROCESSED_ACCEPTED'), isTrue);
            expect(
              _hasDebugMessage('SOS_CANONICAL_INCIDENT_HANDOFF source=mqtt'),
              isTrue,
            );
            harness.deviceSosController.handleIncomingSosPacket(
              _deviceOriginActivePacket(),
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: 8);
            final lifecycleAfterDeviceActive = await harness.sdk
                .getSosLifecycle();
            expect(lifecycleAfterDeviceActive.stage, SosLifecycleStage.active);
            expect(
              lifecycleAfterDeviceActive.incident?.isBackendConfirmed,
              isTrue,
            );
            expect(
              lifecycleAfterDeviceActive.backendIncidentId,
              canonicalIncidentId,
            );
            await Future<void>.delayed(const Duration(milliseconds: 150));
            await BleDebugRegistry.instance.resetForLifecycle();
            terminalDebugSubscription = BleDebugRegistry.instance
                .watch()
                .listen((state) {
                  if (state.events.isNotEmpty) {
                    observedDebugMessages.add(state.events.last.message);
                  }
                });

            final terminalEvent = RealtimeEvent(
              type: terminalState.name,
              timestamp: DateTime.utc(2026, 9, 9, 11, 32, 42),
              payload: <String, dynamic>{
                'type': terminalState.name,
                'status': terminalState.name,
                'incidentId': canonicalIncidentId,
                'userId': 'external-123',
                '_mqttAuthenticatedUserScoped': true,
                '_mqttTopicCategory': 'legacy_alias',
              },
            );
            StreamSubscription<SosState>? terminalInjectionSubscription;
            Future<SosIncident>? cancellation;
            if (terminalState == SosState.cancelled) {
              var terminalInjected = false;
              terminalInjectionSubscription = repository.watchSosState().listen(
                (state) {
                  if (state == SosState.cancelRequested && !terminalInjected) {
                    terminalInjected = true;
                    realtime.emitEvent(terminalEvent);
                  }
                },
              );
              cancellation = repository.cancelSos();
              await cancelRemote.cancelStarted;
            } else {
              realtime.emitEvent(terminalEvent);
            }
            await pumpEventQueue(times: 8);

            final terminalLifecycle = await harness.sdk.getSosLifecycle();
            expect(
              terminalLifecycle.stage,
              terminalState == SosState.cancelled
                  ? SosLifecycleStage.cancelled
                  : SosLifecycleStage.resolved,
            );
            expect(terminalLifecycle.deviceCycleKey, 'sos:4660:0');
            expect(await harness.sdk.getSosState(), terminalState);
            expect(commands, contains(0x04));
            expect(
              _hasDebugMessage('SOS_REMOTE_TERMINAL_DEVICE_CLEAR_REQUESTED'),
              isTrue,
            );
            expect(
              observedDebugMessage('SOS_TERMINAL_LIFECYCLE_PUBLISHED'),
              isTrue,
            );
            expect(
              observedDebugMessage(
                'SOS_APP_ORIGIN_BLE_ACTIVE_SURFACED '
                'source=repository_stream:${terminalState.name}',
              ),
              isFalse,
            );
            expect(
              _hasDebugMessage('primitive=terminatePhysicalSosOnCurrentDevice'),
              isTrue,
            );
            if (failDeviceClear) {
              expect(
                harness.deviceSosController.currentStatus.state,
                DeviceSosState.active,
              );
              expect(
                _hasDebugMessage('SOS_REMOTE_TERMINAL_DEVICE_CLEAR_DEFERRED'),
                isTrue,
              );
            } else {
              expect(
                _hasDebugMessage('SOS_REMOTE_TERMINAL_DEVICE_CLEAR_DISPATCHED'),
                isTrue,
              );
            }
            await BleDebugRegistry.instance.resetForLifecycle();
            if (failDeviceClear) {
              await Future<void>.delayed(const Duration(milliseconds: 5100));
            }

            harness.deviceSosController.handleIncomingSosPacket(
              _deviceOriginActivePacket(packetId: failDeviceClear ? 1 : 0),
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: failDeviceClear ? 20 : 4);
            harness.deviceSosController.handleIncomingSosPacket(
              _deviceOriginActivePacket(packetId: failDeviceClear ? 1 : 0),
              source: DeviceSosTransitionSource.device,
            );
            await pumpEventQueue(times: failDeviceClear ? 20 : 4);

            expect(
              (await harness.sdk.getSosLifecycle()).stage,
              terminalState == SosState.cancelled
                  ? SosLifecycleStage.cancelled
                  : SosLifecycleStage.resolved,
            );
            expect(await harness.sdk.getSosState(), terminalState);
            expect(
              BleDebugRegistry.instance.currentState.events.any(
                (event) =>
                    event.message.contains(
                      'DEVICE_SOS_ACTIVE_SUPPRESSED '
                      'reason=authoritative_terminal_same_cycle',
                    ) ||
                    event.message.contains(
                      'DEVICE_SOS_SAME_CYCLE_REOPEN_SUPPRESSED_AFTER_TERMINAL',
                    ) ||
                    event.message.contains(
                      'SOS_TRACE device_rearm_suppressed '
                      'reason=pending_terminal_command',
                    ) ||
                    event.message.contains(
                      'DEVICE_SOS_ACTIVE_SUPPRESSED '
                      'reason=remote_terminal_device_clear_pending',
                    ),
              ),
              isTrue,
            );
            expect(
              BleDebugRegistry.instance.currentState.events.any(
                (event) => event.message.contains(
                  'SOS_APP_ORIGIN_BLE_ACTIVE_SURFACED',
                ),
              ),
              isFalse,
            );
            expect(
              BleDebugRegistry.instance.currentState.events.any(
                (event) =>
                    event.message.contains(
                      'SOS_APP_ORIGIN_BLE_ACTIVE_SURFACED '
                      'reason=app_owned_ble_runtime',
                    ) &&
                    event.message.contains(
                      'source=repository_stream:cancelRequested',
                    ),
              ),
              isFalse,
            );
            if (!failDeviceClear) {
              harness.deviceSosController.handleIncomingSosEventPacket(
                _deviceResolveAckPacket(),
                source: DeviceSosTransitionSource.device,
              );
              await pumpEventQueue(times: 8);

              expect(
                _hasDebugMessage(
                  'DEVICE_TERMINAL_ACK_CONSUMED '
                  'reason=authoritative_terminal_cleanup',
                ),
                isTrue,
              );
              expect(
                _hasDebugMessage(
                  'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_ACKNOWLEDGED',
                ),
                isTrue,
              );
              expect(
                harness.deviceSosController.currentStatus.state,
                DeviceSosState.inactive,
              );
              expect(
                _hasDebugMessage('SOS_DEVICE_ONLY_INCIDENT_RECORDED'),
                isFalse,
              );
              expect(
                _hasDebugMessage('SOS_DEVICE_ONLY_PUBLIC_STATE_EMITTED'),
                isFalse,
              );
              final commandCountBeforeIdempotentCancel = commands.length;
              final idempotentCancel = await harness.sdk.cancelSos();
              expect(idempotentCancel.state, terminalState);
              expect(commands, hasLength(commandCountBeforeIdempotentCancel));
              expect(
                _hasDebugMessage(
                  'SOS_MANUAL_CANCEL_NOOP reason=authoritative_terminal',
                ),
                isTrue,
              );
            }
            cancelRemote.completeCancel();
            await cancellation;
            await terminalInjectionSubscription?.cancel();
          } finally {
            await terminalDebugSubscription?.cancel();
            cancelRemote.completeCancelIfPending();
            await harness.dispose(disposeSosRepository: false);
            await repository.dispose();
          }
        },
      );
    }

    test('cancel after repository already observed remote terminal absence '
        'converges and stays terminal after restart', () async {
      const session = EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final localStore = MemorySharedPrefsSdkStore();
      final sessionStore = SdkSessionStore(localStore: localStore);
      final secureStore = InMemorySecureKeyValueStore();
      final realtime = _OnDemandOperationalRealtimeClient();
      final remote = _NoActiveSosRemoteDataSource();
      final repository = MqttOperationalSosRepository(
        realtimeClient: realtime,
        remoteDataSource: remote,
        cancelRemoteDataSource: remote,
        localStore: localStore,
        destructiveRehydrationGracePeriod: Duration.zero,
      );
      final first = _SdkSosHarness(
        sdkSosRepository: repository,
        realtimeClient: realtime,
        localStore: localStore,
        sosLifecycleSecureStore: secureStore,
        sessionStore: sessionStore,
      );
      await first.sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
      );
      await first.sdk.setSession(session);
      await first.sdk.triggerSosAuthoritatively(
        const SosTriggerPayload(triggerSource: 'commercial_app'),
      );

      final remoteResolution = await repository
          .rehydrateRuntimeStateFromBackend();
      expect(
        remoteResolution.outcome,
        SosRuntimeRehydrationOutcome.clearedToIdle,
      );
      expect((await first.sdk.getSosLifecycle()).isOpen, isTrue);

      final cancelled = await first.sdk.cancelSosAuthoritatively();

      expect(
        cancelled.outcome,
        SosCancellationOutcome.activeCancellationConfirmed,
      );
      expect(cancelled.lifecycle.stage, SosLifecycleStage.cancelled);
      expect(cancelled.lifecycle.failureCode, isNull);
      expect(await first.sdk.getSosState(), SosState.idle);
      await first.dispose(disposeSosRepository: false);
      await repository.dispose();

      final restartedRealtime = _OnDemandOperationalRealtimeClient();
      final restartedRemote = _NoActiveSosRemoteDataSource();
      final restartedRepository = MqttOperationalSosRepository(
        realtimeClient: restartedRealtime,
        remoteDataSource: restartedRemote,
        cancelRemoteDataSource: restartedRemote,
        localStore: localStore,
      );
      await restartedRepository.restoreState();
      final restarted = _SdkSosHarness(
        sdkSosRepository: restartedRepository,
        realtimeClient: restartedRealtime,
        localStore: localStore,
        sosLifecycleSecureStore: secureStore,
        sessionStore: sessionStore,
      );
      try {
        await restarted.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );

        final lifecycle = await restarted.sdk.getSosLifecycle();
        expect(lifecycle.stage, SosLifecycleStage.cancelled);
        expect(lifecycle.isOpen, isFalse);
        expect(await restarted.sdk.getSosState(), SosState.idle);
      } finally {
        await restarted.dispose(disposeSosRepository: false);
        await restartedRepository.dispose();
      }
    });

    test('persisted cancellation failure is superseded durably by '
        'authenticated no-active', () async {
      const session = EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-123',
        userHash: 'deadbeef',
      );
      final localStore = MemorySharedPrefsSdkStore();
      final sessionStore = SdkSessionStore(localStore: localStore);
      final secureStore = InMemorySecureKeyValueStore();
      final cached = SosIncident(
        id: 'backend-resolved-before-cancel',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 9, 9),
        triggerSource: 'commercial_app',
        isBackendConfirmed: true,
      );
      await sessionStore.save(session);
      localStore.jsonValues[SharedPrefsSdkStore.sosIncidentKey] =
          LocalStateSerializers.sosIncidentToJson(cached);
      localStore.stringValues[SharedPrefsSdkStore.sosStateKey] =
          SosState.sent.name;
      final lifecycleSeed = AuthoritativeSosLifecycleController(
        secureStore: secureStore,
      );
      await lifecycleSeed.restoreFor(session);
      await lifecycleSeed.beginActivating(
        origin: SosLifecycleOrigin.localApp,
        triggerSource: 'commercial_app',
      );
      await lifecycleSeed.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: cached.id,
        backendIncidentId: cached.id,
        triggerSource: 'commercial_app',
        incident: cached,
      );
      await lifecycleSeed.beginCancellation();
      await lifecycleSeed.cancellationFailed('E_SOS_CANCEL_NOT_ALLOWED');
      await lifecycleSeed.dispose();

      Future<void> verifyRestart({required bool expectLookup}) async {
        final realtime = _OnDemandOperationalRealtimeClient();
        final remote = _NoActiveSosRemoteDataSource();
        final repository = MqttOperationalSosRepository(
          realtimeClient: realtime,
          remoteDataSource: remote,
          localStore: localStore,
        );
        await repository.restoreState();
        final harness = _SdkSosHarness(
          sdkSosRepository: repository,
          realtimeClient: realtime,
          localStore: localStore,
          sosLifecycleSecureStore: secureStore,
          sessionStore: sessionStore,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          final lifecycle = await harness.sdk.getSosLifecycle();
          expect(lifecycle.isTerminal, isTrue);
          expect(lifecycle.isOpen, isFalse);
          expect(lifecycle.failureCode, isNull);
          expect(await harness.sdk.getSosState(), SosState.idle);
          if (expectLookup) {
            expect(remote.getActiveSosCalls, greaterThan(0));
          }
        } finally {
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      }

      await verifyRestart(expectLookup: true);
      await verifyRestart(expectLookup: false);
    });

    test(
      'cancel network failure settles provisional local SOS after non-absence lookup',
      () async {
        final repository = _FailingCancellationRehydratingRepository();
        final harness = _SdkSosHarness(sosRepository: repository);
        try {
          await harness.setSession();
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          repository.rehydrationResult = const SosRuntimeRehydrationResult(
            outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
            resultingState: SosState.sent,
            diagnosticNote: 'E_SOS_REHYDRATION_FAILED',
          );

          final result = await harness.sdk.cancelSosAuthoritatively();

          expect(
            result.outcome,
            SosCancellationOutcome.activeCancellationConfirmed,
          );
          expect(result.lifecycle.stage, SosLifecycleStage.cancelled);
          expect(result.lifecycle.isOpen, isFalse);
        } finally {
          await harness.dispose();
        }
      },
    );

    test('stale authenticated absence from SOS A cannot close SOS B', () async {
      final repository = _DelayedRejectedTerminalRepository();
      final harness = _SdkSosHarness(sosRepository: repository);
      try {
        await harness.setSession();
        final first = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        repository.delayNextRehydration();
        repository.emitRejectedTerminal(SosState.resolved);
        await repository.delayedLookupStarted.future;

        repository.currentIncident = repository.currentIncident.copyWith(
          state: SosState.resolved,
        );
        repository.stateController.add(SosState.resolved);
        await pumpEventQueue(times: 3);
        expect((await harness.sdk.getSosLifecycle()).isTerminal, isTrue);

        repository.currentIncident = SosIncident(
          id: 'sos-b',
          state: SosState.idle,
          createdAt: DateTime.utc(2026, 9, 9, 11),
        );
        final second = await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        expect(
          second.lifecycle.generation,
          greaterThan(first.lifecycle.generation),
        );

        repository.completeDelayedRehydrationWithAbsence();
        await pumpEventQueue(times: 5);

        final lifecycle = await harness.sdk.getSosLifecycle();
        expect(lifecycle.generation, second.lifecycle.generation);
        expect(lifecycle.stage, SosLifecycleStage.active);
        expect(lifecycle.localIncidentId, 'sos-b');
      } finally {
        await harness.dispose();
      }
    });

    test(
      'terminal reconciliation is not swallowed by an ordinary lookup',
      () async {
        final repository = _DelayedRejectedTerminalRepository();
        final harness = _SdkSosHarness(sosRepository: repository);
        try {
          await harness.setSession();
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          final callsBefore = repository.rehydrateCallCount;
          repository.delayNextRehydration();
          harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await repository.delayedLookupStarted.future;

          repository.emitRejectedTerminal(SosState.resolved);
          repository.completeDelayedRehydration(
            const SosRuntimeRehydrationResult(
              outcome: SosRuntimeRehydrationOutcome.keptLocalFallback,
              resultingState: SosState.sent,
            ),
          );
          await pumpEventQueue(times: 6);

          expect(repository.rehydrateCallCount, greaterThan(callsBefore + 1));
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test('backend terminal absence closes app lifecycle and dispatches the '
        'shared device convergence hook', () async {
      final repository = FakeRejectedTerminalRehydratingSosRepository()
        ..rehydrationResult = const SosRuntimeRehydrationResult(
          outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
          resultingState: SosState.idle,
        );
      final harness = _SdkSosHarness(
        sosRepository: repository,
        connectedBle: true,
        connectedDeviceId: 'cf:82:00:00:00:01',
        connectedCanonicalHardwareId: null,
        appTriggeredSosBridgeWindow: const Duration(milliseconds: 50),
      );
      final commands = <int>[];
      final terminalDiagnostics = <String>[];
      StreamSubscription<BleDebugState>? terminalDiagnosticsSubscription;
      try {
        await harness.deviceSosController.attach(
          commandWriter: (command) async {
            commands.add(command.opcode);
            if (command.opcode == 0x04) {
              scheduleMicrotask(() {
                harness.deviceSosController.handleIncomingSosEventPacket(
                  _deviceResolveAckPacket(),
                  source: DeviceSosTransitionSource.device,
                );
              });
            }
          },
        );
        await harness.sdk.initialize(
          const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
        );
        await harness.setSession();
        await harness.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );
        await harness.deviceSosController.triggerSos();
        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginCountdownPacket(),
          source: DeviceSosTransitionSource.device,
        );
        await harness.deviceSosController.confirmSos();
        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 3);
        expect(
          harness.deviceSosController.currentStatus.state,
          DeviceSosState.active,
        );
        expect(
          (await harness.sdk.getSosLifecycle()).hardwareId,
          'CF:82:00:00:00:01',
        );
        await Future<void>.delayed(const Duration(milliseconds: 75));
        commands.clear();
        await BleDebugRegistry.instance.resetForLifecycle();
        terminalDiagnosticsSubscription = BleDebugRegistry.instance
            .watch()
            .listen((state) {
              if (state.events.isNotEmpty) {
                terminalDiagnostics.add(state.events.last.message);
              }
            });

        repository.emitRejectedTerminal(SosState.resolved);
        await pumpEventQueue(times: 5);

        expect(
          (await harness.sdk.getSosLifecycle()).stage,
          SosLifecycleStage.resolved,
        );
        expect(commands, contains(0x04));
        expect(
          terminalDiagnostics.any(
            (message) =>
                message.contains('SOS_REMOTE_TERMINAL_DEVICE_CLEAR_ELIGIBLE'),
          ),
          isTrue,
        );
        expect(
          _hasDebugMessage('SOS_REMOTE_TERMINAL_DEVICE_CLEAR_DISPATCHED'),
          isTrue,
        );
        expect(
          _hasDebugMessage('SOS_REMOTE_TERMINAL_DEVICE_CLEAR_ACKNOWLEDGED'),
          isTrue,
        );
        expect(
          harness.deviceSosController.currentStatus.state,
          DeviceSosState.inactive,
        );

        harness.deviceSosController.handleIncomingSosPacket(
          _deviceOriginActivePacket(),
          source: DeviceSosTransitionSource.device,
        );
        await pumpEventQueue(times: 4);

        expect(
          (await harness.sdk.getSosLifecycle()).stage,
          SosLifecycleStage.resolved,
        );
        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(
          BleDebugRegistry.instance.currentState.events.any(
            (event) =>
                event.message.contains(
                  'DEVICE_SOS_ACTIVE_SUPPRESSED '
                  'reason=authoritative_terminal_same_cycle',
                ) ||
                event.message.contains(
                  'SOS_DEVICE_TERMINAL_PACKET_REPLAY_REJECTED',
                ),
          ),
          isTrue,
        );
      } finally {
        await terminalDiagnosticsSubscription?.cancel();
        await harness.dispose();
      }
    });

    test(
      'remote terminal skips physical clear for conflicting device ownership',
      () async {
        final harness = _SdkSosHarness(connectedBle: true);
        final commands = <int>[];
        try {
          await harness.deviceSosController.attach(
            commandWriter: (command) async {
              commands.add(command.opcode);
            },
          );
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await harness.deviceSosController.triggerSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginCountdownPacket(),
            source: DeviceSosTransitionSource.device,
          );
          await harness.deviceSosController.confirmSos();
          harness.deviceSosController.handleIncomingSosPacket(
            _deviceOriginActivePacket(),
            source: DeviceSosTransitionSource.device,
          );
          await pumpEventQueue(times: 5);

          harness.deviceRepository.emitStatus(
            buildDeviceStatus(
              deviceId: 'ble-2',
              nodeId: 0x1234,
              canonicalHardwareId: 'CF:82:00:00:00:02',
              connected: true,
              paired: true,
              activated: true,
            ),
          );
          await pumpEventQueue(times: 3);
          commands.clear();
          await BleDebugRegistry.instance.resetForLifecycle();

          harness.sosRepository.currentIncident = harness
              .sosRepository
              .currentIncident
              .copyWith(state: SosState.resolved, isBackendConfirmed: true);
          harness.sosRepository.stateController.add(SosState.resolved);
          await pumpEventQueue(times: 6);

          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
          expect(commands, isNot(contains(0x04)));
          expect(
            _hasDebugMessage(
              'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_SKIPPED '
              'reason=device_target_mismatch',
            ),
            isTrue,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

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

    test(
      'production MQTT cold start clears stale cached active before lifecycle exposure',
      () async {
        const session = EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        );
        final localStore = MemorySharedPrefsSdkStore();
        final sessionStore = SdkSessionStore(localStore: localStore);
        final secureStore = InMemorySecureKeyValueStore();
        final realtime = _OnDemandOperationalRealtimeClient();
        final cached = SosIncident(
          id: 'backend-remotely-resolved',
          state: SosState.sent,
          createdAt: DateTime.utc(2026, 9, 5),
          triggerSource: 'commercial_app',
          isBackendConfirmed: true,
        );
        await sessionStore.save(session);
        localStore.jsonValues[SharedPrefsSdkStore.sosIncidentKey] =
            LocalStateSerializers.sosIncidentToJson(cached);
        localStore.stringValues[SharedPrefsSdkStore.sosStateKey] =
            SosState.sent.name;
        final lifecycleSeed = AuthoritativeSosLifecycleController(
          secureStore: secureStore,
        );
        await lifecycleSeed.restoreFor(session);
        await lifecycleSeed.beginActivating(
          origin: SosLifecycleOrigin.localApp,
          triggerSource: 'commercial_app',
        );
        await lifecycleSeed.confirmActive(
          origin: SosLifecycleOrigin.localApp,
          localIncidentId: cached.id,
          backendIncidentId: cached.id,
          triggerSource: 'commercial_app',
          incident: cached,
        );
        await lifecycleSeed.dispose();
        final remote = _NoActiveSosRemoteDataSource();
        final repository = MqttOperationalSosRepository(
          realtimeClient: realtime,
          remoteDataSource: remote,
          localStore: localStore,
        );
        await repository.restoreState();
        final harness = _SdkSosHarness(
          sdkSosRepository: repository,
          realtimeClient: realtime,
          localStore: localStore,
          sosLifecycleSecureStore: secureStore,
          sessionStore: sessionStore,
        );
        final observed = <SosLifecycleSnapshot>[];
        final subscription = harness.sdk.sosLifecycleStream.listen(
          observed.add,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await pumpEventQueue(times: 3);

          expect(remote.getActiveSosCalls, 1);
          expect(await repository.getSosState(), SosState.idle);
          expect(await repository.getCurrentIncident(), isNull);
          expect(
            localStore.jsonValues[SharedPrefsSdkStore.sosIncidentKey],
            isNull,
          );
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
          expect(observed.where((item) => item.isOpen), isEmpty);
        } finally {
          await subscription.cancel();
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'offline cold start retains recoverable active until REST can reconcile',
      () async {
        const session = EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        );
        final localStore = MemorySharedPrefsSdkStore();
        final sessionStore = SdkSessionStore(localStore: localStore);
        final secureStore = InMemorySecureKeyValueStore();
        final realtime = _OnDemandOperationalRealtimeClient();
        final cached = SosIncident(
          id: 'backend-active-before-offline-restart',
          state: SosState.sent,
          createdAt: DateTime.utc(2026, 9, 5),
          triggerSource: 'commercial_app',
          isBackendConfirmed: true,
        );
        await sessionStore.save(session);
        localStore.jsonValues[SharedPrefsSdkStore.sosIncidentKey] =
            LocalStateSerializers.sosIncidentToJson(cached);
        localStore.stringValues[SharedPrefsSdkStore.sosStateKey] =
            SosState.sent.name;
        final lifecycleSeed = AuthoritativeSosLifecycleController(
          secureStore: secureStore,
        );
        await lifecycleSeed.restoreFor(session);
        await lifecycleSeed.beginActivating(
          origin: SosLifecycleOrigin.localApp,
          triggerSource: 'commercial_app',
        );
        await lifecycleSeed.confirmActive(
          origin: SosLifecycleOrigin.localApp,
          localIncidentId: cached.id,
          backendIncidentId: cached.id,
          triggerSource: 'commercial_app',
          incident: cached,
        );
        await lifecycleSeed.dispose();
        final remote = _NoActiveSosRemoteDataSource(
          activeLookupError: TimeoutException('offline during restart'),
        );
        final repository = MqttOperationalSosRepository(
          realtimeClient: realtime,
          remoteDataSource: remote,
          localStore: localStore,
        );
        await repository.restoreState();
        final harness = _SdkSosHarness(
          sdkSosRepository: repository,
          realtimeClient: realtime,
          localStore: localStore,
          sosLifecycleSecureStore: secureStore,
          sessionStore: sessionStore,
        );
        final observed = <SosLifecycleSnapshot>[];
        final subscription = harness.sdk.sosLifecycleStream.listen(
          observed.add,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await pumpEventQueue(times: 3);

          final offlineLifecycle = await harness.sdk.getSosLifecycle();
          expect(offlineLifecycle.stage, SosLifecycleStage.recoveryRequired);
          expect(
            offlineLifecycle.recoveryStatus,
            SosRecoveryStatus.reconciling,
          );
          expect(offlineLifecycle.isOpen, isTrue);
          expect(observed.where((item) => item.isOpen), isNotEmpty);
          expect(await repository.getSosState(), SosState.sent);
          final offlineIncident = await repository.getCurrentIncident();
          expect(offlineIncident?.id, cached.id);
          expect(offlineIncident?.isBackendConfirmed, isTrue);
          expect(offlineIncident?.isUsingCachedData, isTrue);

          remote.activeLookupError = null;
          realtime.emitConnectionState(RealtimeConnectionState.reconnecting);
          realtime.emitConnectionState(RealtimeConnectionState.connected);
          await pumpEventQueue(times: 5);

          expect(remote.getActiveSosCalls, greaterThanOrEqualTo(2));
          expect((await harness.sdk.getSosLifecycle()).isTerminal, isTrue);
          expect(await repository.getSosState(), SosState.idle);
          expect(await repository.getCurrentIncident(), isNull);
        } finally {
          await subscription.cancel();
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'restored repository terminal closes secure open lifecycle before exposure',
      () async {
        const session = EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        );
        final localStore = MemorySharedPrefsSdkStore();
        final sessionStore = SdkSessionStore(localStore: localStore);
        final secureStore = InMemorySecureKeyValueStore();
        final realtime = _OnDemandOperationalRealtimeClient();
        final terminalIncident = SosIncident(
          id: 'backend-terminal-after-process-death',
          state: SosState.resolved,
          createdAt: DateTime.utc(2026, 9, 5),
          triggerSource: 'commercial_app',
          isBackendConfirmed: true,
          provisionalIncidentId: 'local-terminal-before-process-death',
          preservedLocalOwnership: true,
        );
        await sessionStore.save(session);
        localStore.jsonValues[SharedPrefsSdkStore.sosIncidentKey] =
            LocalStateSerializers.sosIncidentToJson(terminalIncident);
        localStore.stringValues[SharedPrefsSdkStore.sosStateKey] =
            SosState.resolved.name;
        final lifecycleSeed = AuthoritativeSosLifecycleController(
          secureStore: secureStore,
        );
        await lifecycleSeed.restoreFor(session);
        await lifecycleSeed.beginActivating(
          origin: SosLifecycleOrigin.localApp,
          triggerSource: 'commercial_app',
        );
        await lifecycleSeed.confirmActive(
          origin: SosLifecycleOrigin.localApp,
          localIncidentId: terminalIncident.provisionalIncidentId!,
          backendIncidentId: terminalIncident.id,
          triggerSource: 'commercial_app',
        );
        await lifecycleSeed.dispose();
        final remote = _NoActiveSosRemoteDataSource(
          activeLookupError: StateError('offline during restart'),
        );
        final repository = MqttOperationalSosRepository(
          realtimeClient: realtime,
          remoteDataSource: remote,
          localStore: localStore,
        );
        await repository.restoreState();
        final harness = _SdkSosHarness(
          sdkSosRepository: repository,
          realtimeClient: realtime,
          localStore: localStore,
          sosLifecycleSecureStore: secureStore,
          sessionStore: sessionStore,
        );
        final observed = <SosLifecycleSnapshot>[];
        final subscription = harness.sdk.sosLifecycleStream.listen(
          observed.add,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await pumpEventQueue(times: 3);

          expect(remote.getActiveSosCalls, 1);
          expect(await repository.getSosState(), SosState.resolved);
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
          expect(observed.where((item) => item.isOpen), isEmpty);
        } finally {
          await subscription.cancel();
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'switching authenticated users clears prior incident progress',
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
      },
    );

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

    test(
      'SOS-12 backend idle rehydration does not cancel active PRE-SOS',
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
      },
    );

    test(
      'session refresh does not reset app-origin PRE-SOS countdown',
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
      },
    );

    test(
      'same-session auth restore preserves countdown dispatch through active',
      () async {
        final harness = _SdkSosHarness();
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await harness.setSession();
          await harness.sdk.startPreSos(
            countdown: const Duration(milliseconds: 50),
          );

          await harness.setSession();
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.arming,
          );

          await Future<void>.delayed(const Duration(milliseconds: 120));
          await pumpEventQueue(times: 3);

          expect(harness.sosRepository.triggerCallCount, 1);
          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.active,
          );
          expect(await harness.sdk.getSosState(), SosState.sent);
        } finally {
          await harness.dispose();
        }
      },
    );

    test('characterization: external-only relay incident does not become a '
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
        harness.sosRepository.currentIncident = harness
            .sosRepository
            .currentIncident
            .copyWith(state: SosState.cancelled);
        harness.sosRepository.stateController.add(SosState.cancelled);
        await pumpEventQueue(times: 2);

        expect(await harness.sdk.getPreSosStatus(), isNull);
        expect(await harness.sdk.getSosState(), SosState.idle);
        expect(await harness.sdk.getCurrentSosIncident(), isNull);
      } finally {
        await harness.dispose();
      }
    });

    test(
      'SOS-15 resume ignores active LoRa/backend SOS as local state',
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
      },
    );

    test(
      'SOS-16 resume does not resurrect stale countdown after LoRa cancel',
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
      },
    );

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
        expect(
          secondStatus.expectedActivationAt,
          firstStatus.expectedActivationAt,
        );
        expect(await harness.sdk.getSosState(), SosState.arming);
        expect(harness.sosRepository.triggerCallCount, 0);
      } finally {
        await harness.dispose();
      }
    });

    test(
      'app-origin countdown survives SDK restart and promotes on restore',
      () async {
        final store = MemorySharedPrefsSdkStore();
        final repository = FakeSosRepository();
        final first = _SdkSosHarness(
          sosRepository: repository,
          localStore: store,
        );
        await first.sdk.startPreSos(
          countdown: const Duration(milliseconds: 50),
        );
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
      },
    );

    test(
      'typed already-active recovers matching persisted local ownership',
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
      },
    );

    test(
      'SDK runtime owns one lifecycle and activates production tracking once',
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
          final trackingStartsBefore =
              harness.trackingRepository.startCallCount;
          final trackingStopsBefore = harness.trackingRepository.stopCallCount;
          final telemetryBefore = harness.telemetryRepository.publishCallCount;

          final result = await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await harness.sdk.debugReconcileSosLocationOwnership();

          expect(result.lifecycle.stage, SosLifecycleStage.active);
          expect(await harness.sdk.getSosState(), SosState.sent);
          expect(
            shadow.shadowState.lastAcceptedLifecycleRevision,
            result.lifecycle.revision,
          );
          expect(shadow.shadowState.acceptedSnapshotCount, acceptedBefore + 3);
          expect(shadow.shadowState.activateTransitionCount, 1);
          expect(shadow.shadowState.desiredSosOwnership, isTrue);
          expect(
            harness.trackingRepository.startCallCount,
            trackingStartsBefore + 1,
          );
          expect(harness.trackingRepository.stopCallCount, trackingStopsBefore);
          expect(harness.telemetryRepository.publishCallCount, telemetryBefore);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'authoritative terminal removes production tracking without telemetry',
      () async {
        final harness = _SdkSosHarness();
        try {
          await harness.setSession();
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          await harness.sdk.debugReconcileSosLocationOwnership();
          final shadow = harness.sdk.debugSosLocationOwnershipOrchestrator;
          final trackingStartsBefore =
              harness.trackingRepository.startCallCount;
          final trackingStopsBefore = harness.trackingRepository.stopCallCount;
          final telemetryBefore = harness.telemetryRepository.publishCallCount;

          final result = await harness.sdk.cancelSosAuthoritatively();
          await harness.sdk.debugReconcileSosLocationOwnership();

          expect(result.lifecycle.stage, SosLifecycleStage.cancelled);
          expect(shadow.shadowState.deactivateTransitionCount, 1);
          expect(shadow.shadowState.desiredSosOwnership, isFalse);
          expect(
            harness.trackingRepository.startCallCount,
            trackingStartsBefore,
          );
          expect(
            harness.trackingRepository.stopCallCount,
            trackingStopsBefore + 1,
          );
          expect(harness.telemetryRepository.publishCallCount, telemetryBefore);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'arming remains shadow-retain while public arming is unchanged',
      () async {
        final harness = _SdkSosHarness();
        try {
          await harness.setSession();
          final shadow = harness.sdk.debugSosLocationOwnershipOrchestrator;
          final activateBefore = shadow.shadowState.activateTransitionCount;
          final trackingStartsBefore =
              harness.trackingRepository.startCallCount;

          await harness.sdk.startPreSos(countdown: const Duration(seconds: 20));

          expect(await harness.sdk.getSosState(), SosState.arming);
          expect(
            shadow.shadowState.lastDirective,
            SosLocationOwnershipDirective.retain,
          );
          expect(shadow.shadowState.activateTransitionCount, activateBefore);
          expect(
            harness.trackingRepository.startCallCount,
            trackingStartsBefore,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'typed already-active without local proof remains unmatched',
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
      },
    );

    test(
      'already-active app-shaped incident without correlation remains unmatched',
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

          expect(result.outcome, SosActivationOutcome.alreadyActiveUnmatched);
          expect(result.lifecycle.stage, SosLifecycleStage.recoveryRequired);
          expect(
            observed.where((stage) => stage == SosLifecycleStage.active),
            isEmpty,
          );
          final capability = await harness.sdk.getSosCapability();
          expect(capability.revision, result.lifecycle.revision);
          expect(capability.canTriggerSos, isFalse);
          expect(capability.lifecycleAllowsActivation, isFalse);
        } finally {
          await subscription.cancel();
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'already-active authoritative foreign incident requires recovery',
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
      },
    );

    test(
      'typed cancellation publishes cancelling before terminal cleanup',
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
      },
    );

    test(
      'typed cancellation stays non-terminal until repository terminal proof',
      () async {
        final repository = _PendingCancellationSosRepository(
          initialIncident: SosIncident(
            id: 'backend-active-cancel-pending',
            state: SosState.sent,
            createdAt: DateTime.utc(2026, 9, 5),
            isBackendConfirmed: true,
          ),
        );
        final harness = _SdkSosHarness(sosRepository: repository);
        try {
          await harness.setSession();
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          repository.cancelResult = SosIncident(
            id: 'backend-active-cancel-pending',
            state: SosState.cancelRequested,
            createdAt: DateTime.utc(2026, 9, 5),
            deliveryChannel: SosDeliveryChannel.backendOnly,
            isBackendConfirmed: true,
          );

          final pending = await harness.sdk.cancelSosAuthoritatively();

          expect(pending.outcome, SosCancellationOutcome.cancellationPending);
          expect(pending.lifecycle.stage, SosLifecycleStage.cancelling);
          expect(pending.lifecycle.isTerminal, isFalse);

          repository.cancelResult = SosIncident(
            id: 'backend-active-cancel-pending',
            state: SosState.cancelled,
            createdAt: DateTime.utc(2026, 9, 5),
            deliveryChannel: SosDeliveryChannel.backendOnly,
            isBackendConfirmed: true,
          );
          await repository.cancelSos();
          await pumpEventQueue();

          expect(
            (await harness.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.cancelled,
          );
        } finally {
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'unrelated repository incident cannot mutate open lifecycle',
      () async {
        final repository = FakeSosRepository();
        final harness = _SdkSosHarness(sosRepository: repository);
        try {
          await harness.setSession();
          await harness.sdk.triggerSosAuthoritatively(
            const SosTriggerPayload(triggerSource: 'commercial_app'),
          );
          final before = await harness.sdk.getSosLifecycle();

          repository.currentIncident = SosIncident(
            id: 'unrelated-backend-incident',
            state: SosState.cancelled,
            createdAt: DateTime.utc(2026, 9, 5),
            isBackendConfirmed: true,
          );
          repository.stateController.add(SosState.cancelled);
          await pumpEventQueue();

          final after = await harness.sdk.getSosLifecycle();
          expect(after.lifecycleId, before.lifecycleId);
          expect(after.generation, before.generation);
          expect(after.stage, SosLifecycleStage.active);
          expect(after.backendIncidentId, before.backendIncidentId);
        } finally {
          await harness.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'process recreation restores the same actionable generation',
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
      },
    );

    test(
      'resolveSos persists terminal lifecycle before returning and restart',
      () async {
        final secureStore = InMemorySecureKeyValueStore();
        final repository = FakeSosRepository();
        final first = _SdkSosHarness(
          sosRepository: repository,
          sosLifecycleSecureStore: secureStore,
        );
        await first.setSession();
        await first.sdk.triggerSosAuthoritatively(
          const SosTriggerPayload(triggerSource: 'commercial_app'),
        );

        await first.sdk.resolveSos();

        expect(
          (await first.sdk.getSosLifecycle()).stage,
          SosLifecycleStage.resolved,
        );
        await first.dispose(disposeSosRepository: false);

        final restored = _SdkSosHarness(
          sosRepository: repository,
          sosLifecycleSecureStore: secureStore,
        );
        try {
          await restored.setSession();
          expect(
            (await restored.sdk.getSosLifecycle()).stage,
            SosLifecycleStage.resolved,
          );
          expect((await restored.sdk.getSosLifecycle()).isOpen, isFalse);
        } finally {
          await restored.dispose(disposeSosRepository: false);
          await repository.dispose();
        }
      },
    );

    test(
      'persisted PRE-SOS older than terminal watermark is discarded',
      () async {
        const session = EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        );
        final localStore = MemorySharedPrefsSdkStore();
        final sessionStore = SdkSessionStore(localStore: localStore);
        final secureStore = InMemorySecureKeyValueStore();
        await sessionStore.save(session);
        final lifecycleSeed = AuthoritativeSosLifecycleController(
          secureStore: secureStore,
        );
        await lifecycleSeed.restoreFor(session);
        await lifecycleSeed.beginActivating(
          origin: SosLifecycleOrigin.localApp,
        );
        await lifecycleSeed.confirmActive(
          origin: SosLifecycleOrigin.localApp,
          localIncidentId: 'pre-sos-terminal-cycle',
        );
        await lifecycleSeed.confirmTerminal(stage: SosLifecycleStage.resolved);
        await lifecycleSeed.dispose();
        localStore.jsonValues[SharedPrefsSdkStore.preSosSessionKey] =
            <String, dynamic>{
              'cycleKey': 'pre-sos-terminal-cycle',
              'owner': 'app',
              'startedAt': DateTime.utc(2025).toIso8601String(),
              'expectedActivationAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 1))
                  .toIso8601String(),
              'mirroredOnDevice': false,
            };
        final harness = _SdkSosHarness(
          localStore: localStore,
          sessionStore: sessionStore,
          sosLifecycleSecureStore: secureStore,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );

          expect(await harness.sdk.getPreSosStatus(), isNull);
          expect(
            localStore.jsonValues[SharedPrefsSdkStore.preSosSessionKey],
            isNull,
          );
          expect((await harness.sdk.getSosLifecycle()).isTerminal, isTrue);
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'persisted iOS ACTIVE snapshot cannot override terminal watermark',
      () async {
        const session = EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        );
        final terminalAt = DateTime.now().toUtc().subtract(
          const Duration(minutes: 1),
        );
        final localStore = MemorySharedPrefsSdkStore();
        final sessionStore = SdkSessionStore(localStore: localStore);
        final secureStore = InMemorySecureKeyValueStore();
        await sessionStore.save(session);
        final lifecycleSeed = AuthoritativeSosLifecycleController(
          secureStore: secureStore,
          clock: () => terminalAt,
        );
        await lifecycleSeed.restoreFor(session);
        await lifecycleSeed.beginActivating(
          origin: SosLifecycleOrigin.connectedLocalDevice,
          nodeId: 0x1234,
        );
        await lifecycleSeed.confirmActive(
          origin: SosLifecycleOrigin.connectedLocalDevice,
          localIncidentId: 'device-runtime-sos:4660:1',
          nodeId: 0x1234,
        );
        await lifecycleSeed.confirmTerminal(stage: SosLifecycleStage.resolved);
        await lifecycleSeed.dispose();
        final harness = _SdkSosHarness(
          localStore: localStore,
          sessionStore: sessionStore,
          sosLifecycleSecureStore: secureStore,
          protectionPlatformAdapter: _SnapshotProtectionPlatformAdapter(
            ProtectionPlatformSnapshot(
              backgroundCapabilityReady: true,
              platform: ProtectionPlatform.ios,
              iosBleSosSnapshotKind: 'active',
              iosBleSosReceivedAt: terminalAt.add(const Duration(seconds: 1)),
              iosBleSosNodeId: 0x1234,
              iosBleSosCycleKey: 'sos:4660:1',
            ),
          ),
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );

          expect((await harness.sdk.getSosLifecycle()).isTerminal, isTrue);
          expect(await harness.sdk.getCurrentSosIncident(), isNull);
          expect(
            _hasDebugMessage(
              'SOS_TERMINAL_WATERMARK_REJECTED source=ios_snapshot',
            ),
            isTrue,
          );
        } finally {
          await harness.dispose();
        }
      },
    );

    test(
      'native-only ACTIVE is reconciled to authoritative absence before exposure',
      () async {
        const session = EixamSession.signed(
          appId: 'app-demo',
          externalUserId: 'external-123',
          userHash: 'deadbeef',
        );
        final observedAt = DateTime.now().toUtc().subtract(
          const Duration(minutes: 2),
        );
        final localStore = MemorySharedPrefsSdkStore();
        final sessionStore = SdkSessionStore(localStore: localStore);
        final secureStore = InMemorySecureKeyValueStore();
        final repository = FakeRehydratingSosRepository()
          ..rehydrationResult = const SosRuntimeRehydrationResult(
            outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
            resultingState: SosState.idle,
          );
        await sessionStore.save(session);
        final harness = _SdkSosHarness(
          sosRepository: repository,
          localStore: localStore,
          sessionStore: sessionStore,
          sosLifecycleSecureStore: secureStore,
          protectionPlatformAdapter: _SnapshotProtectionPlatformAdapter(
            ProtectionPlatformSnapshot(
              backgroundCapabilityReady: true,
              platform: ProtectionPlatform.ios,
              iosBleSosSnapshotKind: 'active',
              iosBleSosReceivedAt: observedAt,
              iosBleSosNodeId: 0x1234,
              iosBleSosCycleKey: 'sos-cycle:4660:native-only',
            ),
          ),
        );
        final observed = <SosLifecycleSnapshot>[];
        final subscription = harness.sdk.sosLifecycleStream.listen(
          observed.add,
        );
        try {
          await harness.sdk.initialize(
            const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
          );
          await pumpEventQueue(times: 2);

          expect(repository.rehydrateCallCount, 1);
          expect((await harness.sdk.getSosLifecycle()).isTerminal, isTrue);
          expect(await harness.sdk.getCurrentSosIncident(), isNull);
          expect(observed.where((item) => item.isOpen), isEmpty);
        } finally {
          await subscription.cancel();
          await harness.dispose();
        }
      },
    );

    test(
      'app SOS capability stays available without a registered device',
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
      },
    );

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
      },
    );

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
    Duration appTriggeredSosBridgeWindow = const Duration(seconds: 15),
    DateTime Function()? deviceClock,
    String connectedDeviceId = 'ble-1',
    int? connectedNodeId,
    String? connectedCanonicalHardwareId = 'CF:82:00:00:00:01',
    MemorySharedPrefsSdkStore? localStore,
    SecureKeyValueStore? sosLifecycleSecureStore,
    SdkSessionStore? sessionStore,
    ProtectionPlatformAdapter? protectionPlatformAdapter,
    bool hasLocation = true,
  }) : sosRepository = sosRepository ?? FakeSosRepository(),
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
           deviceId: connectedBle ? connectedDeviceId : 'none',
           nodeId: connectedBle ? connectedNodeId : null,
           canonicalHardwareId: connectedBle
               ? connectedCanonicalHardwareId
               : null,
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
         now: deviceClock,
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
      appTriggeredSosBridgeWindow: appTriggeredSosBridgeWindow,
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: preferredBleDeviceStore,
      localStore: this.localStore,
      sosLifecycleSecureStore: sosLifecycleSecureStore,
      sessionStore: sessionStore,
      protectionPlatformAdapter: protectionPlatformAdapter,
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

final class _ControllableMqttOperationalSosRepository
    extends MqttOperationalSosRepository {
  _ControllableMqttOperationalSosRepository(
    OperationalRealtimeClient realtimeClient,
  ) : super(realtimeClient: realtimeClient) {
    _baseStateSubscription = super.watchSosState().listen(_stateController.add);
  }

  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();
  late final StreamSubscription<SosState> _baseStateSubscription;
  SosIncident? _forcedIncident;

  void emitTerminal(SosIncident incident) {
    _forcedIncident = incident;
    _stateController.add(incident.state);
  }

  @override
  Future<SosIncident?> getCurrentIncident() async =>
      _forcedIncident ?? await super.getCurrentIncident();

  @override
  Stream<SosState> watchSosState() => _stateController.stream;

  @override
  Future<void> dispose() async {
    await _baseStateSubscription.cancel();
    await _stateController.close();
    await super.dispose();
  }
}

final class _DelayableMqttOperationalSosRepository
    extends MqttOperationalSosRepository {
  _DelayableMqttOperationalSosRepository(OperationalRealtimeClient realtime)
    : super(realtimeClient: realtime);

  Completer<void>? _lookupStarted;
  Completer<void>? _releaseLookup;
  int _immediateLookupsRemaining = 0;
  bool _delayedLookupInFlight = false;

  Future<void> get delayedLookupStarted => _lookupStarted!.future;

  void delayLookupAfter({int immediateLookups = 0}) {
    _lookupStarted = Completer<void>();
    _releaseLookup = Completer<void>();
    _immediateLookupsRemaining = immediateLookups;
    _delayedLookupInFlight = false;
  }

  void releaseDelayedLookup() {
    _releaseLookup!.complete();
  }

  void releaseDelayedLookupIfPending() {
    final release = _releaseLookup;
    if (release != null && !release.isCompleted) {
      release.complete();
    }
  }

  @override
  Future<SosIncident?> getCurrentIncident() async {
    final snapshot = await super.getCurrentIncident();
    final release = _releaseLookup;
    if (release == null || _delayedLookupInFlight) {
      return snapshot;
    }
    if (_immediateLookupsRemaining > 0) {
      _immediateLookupsRemaining -= 1;
      return snapshot;
    }
    _delayedLookupInFlight = true;
    _lookupStarted!.complete();
    await release.future;
    _lookupStarted = null;
    _releaseLookup = null;
    _delayedLookupInFlight = false;
    return snapshot;
  }
}

final class _DelayedSosIncidentStore extends MemorySharedPrefsSdkStore {
  Completer<void>? _pendingSosIncidentWrite;
  Completer<void>? _sosIncidentWriteStarted;

  Future<void> get sosIncidentWriteStarted => _sosIncidentWriteStarted!.future;

  void delayNextSosIncidentWrite() {
    _pendingSosIncidentWrite = Completer<void>();
    _sosIncidentWriteStarted = Completer<void>();
  }

  void completeSosIncidentWrite() {
    _pendingSosIncidentWrite!.complete();
  }

  void completeSosIncidentWriteIfPending() {
    final pending = _pendingSosIncidentWrite;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
  }

  @override
  Future<void> saveJson(String key, Map<String, dynamic> value) async {
    if (key == SharedPrefsSdkStore.sosIncidentKey) {
      final pending = _pendingSosIncidentWrite;
      if (pending != null) {
        if (!_sosIncidentWriteStarted!.isCompleted) {
          _sosIncidentWriteStarted!.complete();
        }
        await pending.future;
        _pendingSosIncidentWrite = null;
      }
    }
    await super.saveJson(key, value);
  }
}

final class _FailingCancellationRehydratingRepository
    extends FakeRehydratingSosRepository {
  @override
  Future<SosIncident> cancelSos() async {
    cancelCallCount++;
    throw TimeoutException('cancel timed out');
  }
}

final class _DelayedRejectedTerminalRepository
    extends FakeRejectedTerminalRehydratingSosRepository {
  Completer<SosRuntimeRehydrationResult>? _delayedRehydration;
  Completer<void> delayedLookupStarted = Completer<void>();

  void delayNextRehydration() {
    _delayedRehydration = Completer<SosRuntimeRehydrationResult>();
    delayedLookupStarted = Completer<void>();
  }

  void completeDelayedRehydrationWithAbsence() {
    completeDelayedRehydration(
      const SosRuntimeRehydrationResult(
        outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
        resultingState: SosState.idle,
      ),
    );
  }

  void completeDelayedRehydration(SosRuntimeRehydrationResult result) {
    _delayedRehydration?.complete(result);
  }

  @override
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend({
    bool terminalAbsenceExpected = false,
  }) async {
    final delayed = _delayedRehydration;
    if (delayed == null) {
      return super.rehydrateRuntimeStateFromBackend(
        terminalAbsenceExpected: terminalAbsenceExpected,
      );
    }
    rehydrateCallCount++;
    if (!delayedLookupStarted.isCompleted) {
      delayedLookupStarted.complete();
    }
    final result = await delayed.future;
    _delayedRehydration = null;
    return result;
  }
}

class _NoActiveSosRemoteDataSource implements SosRemoteDataSource {
  _NoActiveSosRemoteDataSource({this.activeLookupError});

  Object? activeLookupError;
  SosIncidentDto? active;
  int getActiveSosCalls = 0;

  @override
  Future<SosIncidentDto?> getActiveSos() async {
    getActiveSosCalls += 1;
    if (activeLookupError case final error?) throw error;
    return active;
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
  }) async => null;

  @override
  Future<SosIncidentDto?> resolveSos() async => null;

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
  }) => throw UnimplementedError();

  @override
  Future<SosHistoryPageDto> listSosHistory({
    String? cursor,
    int limit = 20,
  }) async =>
      const SosHistoryPageDto(items: <SosHistoryItemDto>[], hasMore: false);
}

final class _DelayedCancelSosRemoteDataSource
    extends _NoActiveSosRemoteDataSource {
  final Completer<void> _cancelStarted = Completer<void>();
  final Completer<void> _completeCancel = Completer<void>();

  Future<void> get cancelStarted => _cancelStarted.future;

  void completeCancel() {
    if (!_completeCancel.isCompleted) {
      _completeCancel.complete();
    }
  }

  void completeCancelIfPending() => completeCancel();

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
    if (!_cancelStarted.isCompleted) {
      _cancelStarted.complete();
    }
    await _completeCancel.future;
    return null;
  }
}

final class _SnapshotProtectionPlatformAdapter extends Fake
    implements ProtectionPlatformAdapter {
  _SnapshotProtectionPlatformAdapter(
    this.snapshot, {
    Completer<ProtectionPlatformCommandResult>? commandResult,
  }) : _commandResult = commandResult;

  ProtectionPlatformSnapshot snapshot;
  final Completer<ProtectionPlatformCommandResult>? _commandResult;
  final List<ProtectionPlatformCommandRequest> commands =
      <ProtectionPlatformCommandRequest>[];
  final StreamController<ProtectionPlatformEvent> _events =
      StreamController<ProtectionPlatformEvent>.broadcast();

  void emit(ProtectionPlatformEvent event) => _events.add(event);

  Future<void> dispose() => _events.close();

  @override
  ProtectionPlatform get platform => snapshot.platform;

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async => snapshot;

  @override
  Future<ProtectionPlatformCommandResult> sendProtectionCommand({
    required ProtectionPlatformCommandRequest request,
  }) async {
    commands.add(request);
    final pending = _commandResult;
    if (pending != null) {
      return pending.future;
    }
    return const ProtectionPlatformCommandResult(
      success: true,
      route: 'testNativeOwner',
      result: 'write submitted',
    );
  }

  @override
  Stream<ProtectionPlatformEvent> watchPlatformEvents() => _events.stream;

  @override
  Future<List<ProtectionPendingExternalRelayCancelEvent>>
  peekPendingExternalRelayCancels() async =>
      const <ProtectionPendingExternalRelayCancelEvent>[];

  @override
  Future<ProtectionPendingNativeSosCreate?>
  peekPendingNativeSosCreate() async => null;
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
    throw const SosException('E_SOS_ALREADY_ACTIVE', 'E_SOS_ALREADY_ACTIVE');
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

final class _PendingCancellationSosRepository extends FakeSosRepository {
  _PendingCancellationSosRepository({required SosIncident initialIncident}) {
    currentIncident = initialIncident;
  }

  SosIncident? cancelResult;

  @override
  Future<SosIncident> cancelSos() async {
    cancelCallCount++;
    final result = cancelResult ?? currentIncident;
    currentIncident = result;
    stateController.add(result.state);
    return result;
  }
}

final class _HistoryFakeSosRepository extends FakeSosRepository {
  @override
  Future<SosHistoryPage> listSosHistory({
    String? cursor,
    int limit = 20,
  }) async {
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

RealtimeEvent _processedEvent({
  required String canonicalIncidentId,
  required DateTime publishedAt,
}) {
  return RealtimeEvent(
    type: 'processed',
    timestamp: publishedAt.add(const Duration(seconds: 1)),
    payload: <String, dynamic>{
      'type': 'processed',
      'status': 'active',
      'incidentId': canonicalIncidentId,
      'userId': 'external-123',
      'occurredAt': publishedAt.toIso8601String(),
      'openedAt': publishedAt.toIso8601String(),
      'updatedAt': publishedAt
          .add(const Duration(seconds: 1))
          .toIso8601String(),
      '_mqttAuthenticatedUserScoped': true,
      '_mqttTopicCategory': 'legacy_alias',
    },
  );
}

Future<void> _seedTerminalDeviceLifecycle({
  required InMemorySecureKeyValueStore secureStore,
  required DateTime terminalAt,
  required String deviceCycleKey,
  int generation = 1,
}) async {
  final controller = AuthoritativeSosLifecycleController(
    secureStore: secureStore,
    clock: () => terminalAt,
  );
  await controller.restoreFor(
    const EixamSession.signed(
      appId: 'app-demo',
      externalUserId: 'external-123',
      userHash: 'deadbeef',
    ),
  );
  for (var index = 1; index <= generation; index += 1) {
    final cycleKey = index == generation ? deviceCycleKey : 'seed-cycle-$index';
    await controller.beginActivating(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      nodeId: 0x1234,
      deviceId: 'ble-1',
      hardwareId: 'CF:82:00:00:00:01',
      startNewGenerationAfterTerminal: index > 1,
    );
    await controller.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'device-runtime-$cycleKey',
      nodeId: 0x1234,
      deviceId: 'ble-1',
      hardwareId: 'CF:82:00:00:00:01',
    );
    await controller.confirmTerminal(
      stage: SosLifecycleStage.cancelled,
      deviceCycleKey: cycleKey,
    );
  }
  await controller.dispose();
}

EixamSosPacket _deviceOriginCountdownPacket({
  int packetId = 0,
  int batteryLevel = 0,
}) {
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
    packetId & 0x0F,
    0x50 | (batteryLevel & 0x03),
  ])!;
}

EixamSosPacket _deviceOriginActivePacket({
  int packetId = 0,
  int nodeId = 0x1234,
}) {
  return EixamSosPacket.tryParse(<int>[
    nodeId & 0xFF,
    (nodeId >> 8) & 0xFF,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x80 | (packetId & 0x0F),
  ])!;
}

EixamSosPacket _deviceOriginActivePacketForCycle({
  required int packetId,
  int nodeId = 0x1234,
  int relayCount = 0,
  int batteryLevel = 0,
}) {
  return EixamSosPacket.tryParse(<int>[
    nodeId & 0xFF,
    (nodeId >> 8) & 0xFF,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    packetId & 0x0F,
    0x80 | ((relayCount & 0x03) << 2) | (batteryLevel & 0x03),
  ])!;
}

EixamSosEventPacket _deviceCancelPacket() {
  return EixamSosEventPacket.tryParse(<int>[
    0xE1,
    0x01,
    0x34,
    0x12,
    0x00,
    0x00,
  ])!;
}

EixamSosEventPacket _deviceCancelAckPacket() {
  return EixamSosEventPacket.tryParse(<int>[
    0xE2,
    0x01,
    0x34,
    0x12,
    0x00,
    0x00,
  ])!;
}

EixamSosEventPacket _devicePostFireCancelPacket() {
  return EixamSosEventPacket.tryParse(<int>[
    0xE1,
    0x02,
    0x34,
    0x12,
    0x00,
    0x00,
  ])!;
}

EixamSosEventPacket _deviceResolveAckPacket() {
  return EixamSosEventPacket.tryParse(<int>[
    0xE1,
    0x02,
    0x34,
    0x12,
    0x00,
    0x00,
  ])!;
}
