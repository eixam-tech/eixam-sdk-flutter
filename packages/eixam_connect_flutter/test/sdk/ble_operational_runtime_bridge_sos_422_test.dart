import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/ble_operational_runtime_bridge.dart';
import 'package:eixam_connect_flutter/src/sdk/relay_ingest_context.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  group('BleOperationalRuntimeBridge SOS backend 422 classification', () {
    late _BridgeHarness harness;

    setUp(() {
      BleDebugRegistry.instance.reset();
      harness = _BridgeHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('relay-context backend 422 is terminal and is not buffered or retried',
        () async {
      harness.sosRepository.triggerError = const SosException(
        'E_HTTP_422_UNPROCESSABLE',
        'unprocessable relay SOS',
      );

      final published = await harness.bridge.promoteDeviceOriginatedSos(
        signature: 'relay-sos-422',
        triggerSource: 'remote_lora_relay',
        message: 'relay SOS',
        positionSnapshot: _position(),
        deviceId: '16909060',
        hardwareId: 'remote-hardware',
        originatorNodeId: 16909060,
        relayNodeId: 168496141,
        relayDeviceId: '168496141',
        relayHardwareId: 'relay-hardware',
        incidentId: 'device-runtime-relay-sos-422',
        cycleKey: 'sos-cycle:relay-sos-422',
        relayContext: const RelayIngestContext(
          kind: RelayIngestKind.sos,
          remoteDeviceId: '16909060',
          gatewayRuntimeDeviceId: 'relay-tag',
          gatewayCanonicalHardwareId: 'relay-hardware',
          payloadSignature: 'relay-sos-422',
          relayCount: 1,
        ),
      );

      final diagnostics = harness.bridge.currentDiagnostics;
      final deviceStatus = await harness.deviceSosController.getStatus();

      expect(published, isFalse);
      expect(harness.retryCallCount, 0);
      expect(harness.sosRepository.triggerCallCount, 0);
      expect(diagnostics.pendingSos, isNull);
      expect(
          diagnostics.lastRelayTerminalErrorCode, 'E_HTTP_422_UNPROCESSABLE');
      expect(
          diagnostics.lastRelayTerminalErrorMessage, 'unprocessable relay SOS');
      expect(diagnostics.lastRelaySosPublishResult,
          'terminal_failure remote=16909060');
      expect(diagnostics.lastDecision,
          'Relay SOS rejected: E_HTTP_422_UNPROCESSABLE');
      expect(deviceStatus.state, DeviceSosState.inactive);
      expect(
        _debugMessagesContaining('SOS_RUNTIME_BACKEND_DELIVERY_FAILED'),
        isEmpty,
      );
      expect(
        _debugMessagesContaining('SOS_BACKEND_RETRY_AFTER_DEVICE_REGISTER'),
        isEmpty,
      );
    });

    test(
        'non-relay backend 422 preserves validation retry and pending fallback',
        () async {
      harness.sosRepository.triggerError = const SosException(
        'E_HTTP_422_VALIDATION',
        'referenced device does not exist',
      );

      final published = await harness.bridge.promoteDeviceOriginatedSos(
        signature: 'local-sos-422',
        triggerSource: 'ble_device_runtime_status',
        message: 'local SOS',
        positionSnapshot: _position(),
        deviceId: '1498094248',
        hardwareId: 'local-hardware',
        originatorNodeId: 1498094248,
        incidentId: 'device-runtime-local-sos-422',
        cycleKey: 'sos-cycle:local-sos-422',
      );

      final diagnostics = harness.bridge.currentDiagnostics;

      expect(published, isFalse);
      expect(harness.retryCallCount, 1);
      expect(harness.lastRetrySignature, 'local-sos-422');
      expect(diagnostics.pendingSos, isNotNull);
      expect(diagnostics.pendingSos!.signature, 'local-sos-422');
      expect(diagnostics.lastDecision,
          'SOS backendDelivery=failed failure=backend_validation_error');
      expect(diagnostics.lastRelayTerminalErrorCode, isNull);
      expect(diagnostics.lastRelaySosPublishResult, isNull);
      expect(
        _debugMessagesContaining('SOS_RUNTIME_BACKEND_DELIVERY_FAILED').single,
        allOf(
          contains('status=422'),
          contains('failure=backend_validation_error'),
          contains('pendingSos=1'),
        ),
      );
    });
  });
}

TrackingPosition _position() {
  return TrackingPosition(
    latitude: 41.38,
    longitude: 2.17,
    timestamp: DateTime.utc(2026, 6, 29, 12),
    source: DeliveryMode.mobile,
  );
}

List<String> _debugMessagesContaining(String token) {
  return BleDebugRegistry.instance.currentState.events
      .map((event) => event.message)
      .where((message) => message.contains(token))
      .toList();
}

class _BridgeHarness {
  _BridgeHarness()
      : bleEvents = StreamController<BleIncomingEvent>.broadcast(),
        connectionStates =
            StreamController<RealtimeConnectionState>.broadcast(),
        realtimeEvents = StreamController<RealtimeEvent>.broadcast(),
        telemetryRepository = FakeTelemetryRepository(),
        sosRepository = FakeSosRepository(),
        deviceSosController = DeviceSosController() {
    bridge = BleOperationalRuntimeBridge(
      bleIncomingEvents: bleEvents.stream,
      connectionStates: connectionStates.stream,
      realtimeEvents: realtimeEvents.stream,
      telemetryRepository: telemetryRepository,
      sosRepository: sosRepository,
      deviceSosController: deviceSosController,
      sessionProvider: () => null,
      sosBackendAssignmentVerifiedRetry: ({
        required originalCorrelationId,
        required retryCorrelationId,
        required signature,
        required triggerSource,
        required message,
        required positionSnapshot,
        required deviceId,
        required hardwareId,
        required originatorNodeId,
        required relayNodeId,
        required relayDeviceId,
        required relayHardwareId,
        required incidentId,
        required cycleKey,
      }) async {
        retryCallCount++;
        lastRetrySignature = signature;
        return false;
      },
    );
  }

  final StreamController<BleIncomingEvent> bleEvents;
  final StreamController<RealtimeConnectionState> connectionStates;
  final StreamController<RealtimeEvent> realtimeEvents;
  final FakeTelemetryRepository telemetryRepository;
  final FakeSosRepository sosRepository;
  final DeviceSosController deviceSosController;
  late final BleOperationalRuntimeBridge bridge;

  int retryCallCount = 0;
  String? lastRetrySignature;

  Future<void> dispose() async {
    await bridge.dispose();
    await bleEvents.close();
    await connectionStates.close();
    await realtimeEvents.close();
    await sosRepository.dispose();
  }
}
