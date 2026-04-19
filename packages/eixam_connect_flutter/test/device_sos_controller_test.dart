import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_event_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_sos_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DeviceSosController countdown flows', () {
    test('app trigger -> preConfirm -> cancel -> inactive', () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );

      final preConfirm = await controller.triggerSos();
      final inactive = await controller.cancelSos();

      expect(commands.map((command) => command.opcode), <int>[0x06, 0x04]);
      expect(preConfirm.state, DeviceSosState.preConfirm);
      expect(preConfirm.triggerOrigin, DeviceSosTransitionSource.app);
      expect(preConfirm.countdownStartedAt, isNotNull);
      expect(preConfirm.expectedActivationAt, isNotNull);
      expect(preConfirm.countdownRemainingSeconds, greaterThan(0));
      expect(inactive.state, DeviceSosState.inactive);
      expect(inactive.previousState, DeviceSosState.preConfirm);
      expect(inactive.countdownStartedAt, isNull);
      expect(inactive.expectedActivationAt, isNull);
      expect(inactive.countdownRemainingSeconds, isNull);
    });

    test('app trigger -> preConfirm -> confirm -> active', () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );

      await controller.triggerSos();
      final active = await controller.confirmSos();

      expect(commands.map((command) => command.opcode), <int>[0x06, 0x05]);
      expect(active.state, DeviceSosState.active);
      expect(active.previousState, DeviceSosState.preConfirm);
      expect(active.triggerOrigin, DeviceSosTransitionSource.app);
      expect(active.countdownStartedAt, isNull);
      expect(active.expectedActivationAt, isNull);
      expect(active.countdownRemainingSeconds, isNull);
    });

    test('app activate helper sends trigger then confirm and becomes active',
        () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );

      final active = await controller.activateSosFromApp();

      expect(commands.map((command) => command.opcode), <int>[0x06, 0x05]);
      expect(active.state, DeviceSosState.active);
      expect(active.previousState, DeviceSosState.preConfirm);
      expect(active.triggerOrigin, DeviceSosTransitionSource.app);
    });

    test(
        'app activate helper logs incomplete activation when confirm fails after trigger',
        () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
          if (command.opcode == 0x05) {
            throw StateError('confirm failed');
          }
        },
      );

      await expectLater(
        controller.activateSosFromApp(),
        throwsA(isA<StateError>()),
      );

      expect(commands.map((command) => command.opcode), <int>[0x06, 0x05]);
      expect(controller.currentStatus.state, DeviceSosState.preConfirm);
    });

    test('app trigger -> preConfirm -> timeout -> active', () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(commandWriter: (_) async {});

      await controller.triggerSos();
      await Future<void>.delayed(const Duration(milliseconds: 70));

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.active);
      expect(status.previousState, DeviceSosState.preConfirm);
      expect(status.triggerOrigin, DeviceSosTransitionSource.app);
      expect(status.countdownStartedAt, isNotNull);
      expect(status.expectedActivationAt, isNotNull);
      expect(status.countdownRemainingSeconds, 0);
      expect(status.decoderNote, contains('20-second countdown'));
    });

    test(
        'app-originated cycle keeps app trigger origin when later BLE SOS packets arrive',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(commandWriter: (_) async {});

      await controller.activateSosFromApp();

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.active);
      expect(status.transitionSource, DeviceSosTransitionSource.device);
      expect(status.triggerOrigin, DeviceSosTransitionSource.app);
      expect(status.nodeId, 0x1234);
    });

    test('device trigger -> preConfirm -> cancel -> inactive', () {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );
      controller.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(<int>[0xE1, 0x01, 0x34, 0x12])!,
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.inactive);
      expect(status.previousState, DeviceSosState.preConfirm);
      expect(status.nodeId, 0x1234);
      expect(status.triggerOrigin, DeviceSosTransitionSource.device);
      expect(status.countdownStartedAt, isNull);
      expect(status.expectedActivationAt, isNull);
      expect(status.countdownRemainingSeconds, isNull);
    });

    test('device trigger -> preConfirm -> timeout -> active', () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 70));

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.active);
      expect(status.previousState, DeviceSosState.preConfirm);
      expect(status.triggerOrigin, DeviceSosTransitionSource.device);
      expect(status.countdownRemainingSeconds, 0);
      expect(
        status.decoderNote,
        contains('countdown-finished BLE packet was observed'),
      );
    });

    test('device packet with retry metadata still starts in preConfirm', () {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.preConfirm);
      expect(status.previousState, DeviceSosState.inactive);
      expect(status.triggerOrigin, DeviceSosTransitionSource.device);
      expect(status.countdownStartedAt, isNotNull);
      expect(status.expectedActivationAt, isNotNull);
      expect(status.countdownRemainingSeconds, greaterThan(0));
      expect(status.state, isNot(DeviceSosState.active));
      expect(
        status.decoderNote,
        allOf(
          contains('treats the first SOS packet in a new cycle as preConfirm'),
          contains('owns the 20-second timeout locally'),
        ),
      );
    });

    test('active -> ack -> acknowledged', () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 70));
      final acknowledged = await controller.acknowledgeSos();

      expect(commands.map((command) => command.opcode), <int>[0x07]);
      expect(acknowledged.state, DeviceSosState.acknowledged);
      expect(acknowledged.previousState, DeviceSosState.active);
      expect(acknowledged.triggerOrigin, DeviceSosTransitionSource.device);
    });
  });
}

EixamSosPacket _countdownPacket() {
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
    0x40,
  ])!;
}

EixamSosPacket _activePacket() {
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
