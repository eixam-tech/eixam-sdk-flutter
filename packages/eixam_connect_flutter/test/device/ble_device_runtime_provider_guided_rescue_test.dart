import 'package:async/async.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';

void main() {
  group('BleDeviceRuntimeProvider guided rescue wiring', () {
    late MockBleClient bleClient;
    late BleDeviceRuntimeProvider runtimeProvider;

    setUp(() async {
      BleDebugRegistry.instance.reset();
      bleClient = MockBleClient();
      await bleClient.initialize();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
    });

    tearDown(() async {
      await runtimeProvider.dispose();
      await bleClient.dispose();
    });

    test('keeps runtime support explicit when no session or device is ready',
        () async {
      final initialState = await runtimeProvider.getCurrentState();

      expect(initialState.hasRuntimeSupport, isTrue);
      expect(initialState.hasSession, isFalse);
      expect(initialState.availableActions, isEmpty);

      final configuredState = await runtimeProvider.setSession(
        targetNodeId: 0x1001,
        rescueNodeId: 0x2002,
      );

      expect(configuredState.hasSession, isTrue);
      expect(configuredState.availableActions, isEmpty);
      expect(configuredState.unavailableReason, contains('Connect'));

      await expectLater(
        runtimeProvider.requestStatus(),
        throwsA(
          isA<RescueException>().having(
            (error) => error.code,
            'code',
            'E_RESCUE_DEVICE_NOT_READY',
          ),
        ),
      );
    });

    test('routes guided rescue commands through the device layer', () async {
      await _pairDemoDevice(runtimeProvider);
      await runtimeProvider.setSession(
        targetNodeId: 0x1001,
        rescueNodeId: 0x2002,
      );

      await runtimeProvider.requestPosition();
      await runtimeProvider.requestStatus();
      await runtimeProvider.acknowledgeSos();
      await runtimeProvider.enableBuzzer();
      await runtimeProvider.disableBuzzer();

      expect(bleClient.writtenCommands, hasLength(5));
      expect(bleClient.writtenCommands[0].bytes,
          <int>[0x01, 0x10, 0x02, 0x20, 0x01]);
      expect(bleClient.writtenCommands[1].bytes,
          <int>[0x01, 0x10, 0x02, 0x20, 0x05]);
      expect(bleClient.writtenCommands[2].bytes,
          <int>[0x01, 0x10, 0x02, 0x20, 0x02]);
      expect(bleClient.writtenCommands[3].bytes,
          <int>[0x01, 0x10, 0x02, 0x20, 0x03]);
      expect(bleClient.writtenCommands[4].bytes,
          <int>[0x01, 0x10, 0x02, 0x20, 0x04]);
      expect(
        bleClient.writtenCommands
            .every((command) => command.usesCmdCharacteristic),
        isTrue,
      );
    });

    test('updates rescue state from STATUS_RESP and TEL position responses',
        () async {
      await _pairDemoDevice(runtimeProvider);
      await runtimeProvider.setSession(
        targetNodeId: 0x1001,
        rescueNodeId: 0x2002,
      );

      final stateQueue =
          StreamQueue<GuidedRescueState>(runtimeProvider.watchState());

      final positionStateFuture = _nextMatchingState(
        stateQueue,
        (state) => state.lastKnownTargetPosition != null,
      );
      await runtimeProvider.requestPosition();
      final positionState = await positionStateFuture;

      expect(positionState.lastKnownTargetPosition, isNotNull);
      expect(positionState.lastKnownTargetPosition!.latitude, -90.0);
      expect(positionState.lastKnownTargetPosition!.longitude, -180.0);
      expect(positionState.lastKnownTargetPosition!.source, DeliveryMode.mesh);

      final statusStateFuture = _nextMatchingState(
        stateQueue,
        (state) => state.lastStatusSnapshot != null,
      );
      await runtimeProvider.requestStatus();
      final statusState = await statusStateFuture;

      expect(statusState.lastStatusSnapshot, isNotNull);
      expect(
        statusState.lastStatusSnapshot!.targetState,
        GuidedRescueTargetState.active,
      );
      expect(
          statusState.lastStatusSnapshot!.batteryLevel, DeviceBatteryLevel.ok);
      expect(statusState.lastStatusSnapshot!.internetAvailable, isTrue);
      expect(statusState.canRun(GuidedRescueAction.requestStatus), isTrue);

      await stateQueue.cancel();
    });
  });
}

Future<void> _pairDemoDevice(BleDeviceRuntimeProvider runtimeProvider) async {
  BleDebugRegistry.instance
      .update(selectedDeviceId: MockBleClient.demoDeviceId);
  await runtimeProvider.pair(
    currentStatus: buildDeviceStatus(
      paired: false,
      activated: false,
      connected: false,
      lifecycleState: DeviceLifecycleState.unpaired,
    ),
    pairingCode: '1234',
  );
}

Future<GuidedRescueState> _nextMatchingState(
  StreamQueue<GuidedRescueState> queue,
  bool Function(GuidedRescueState state) matches,
) async {
  while (await queue.hasNext) {
    final state = await queue.next;
    if (matches(state)) {
      return state;
    }
  }
  throw StateError('Expected a matching guided rescue state update.');
}
