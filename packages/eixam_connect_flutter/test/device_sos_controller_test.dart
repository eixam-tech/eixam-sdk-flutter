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
        appActivationObservationTimeout: const Duration(milliseconds: 60),
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

    test('app cancel applies local close without waiting for device ACK',
        () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
        appActivationObservationTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
        },
      );

      await controller.triggerSos();

      final status = await controller.cancelSos();

      expect(commands.map((command) => command.opcode), <int>[0x06, 0x04]);
      expect(status.state, DeviceSosState.inactive);
      expect(controller.currentStatus.state, DeviceSosState.inactive);
    });

    test('short command path allows SOS cancel without long CMD', () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
        appActivationObservationTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        shortCommandAvailable: true,
        longCommandAvailable: false,
        commandWriter: (command) async {
          commands.add(command);
        },
      );

      await controller.triggerSos();
      final inactive = await controller.cancelSos();

      expect(controller.shortCommandAvailable, isTrue);
      expect(controller.longCommandAvailable, isFalse);
      expect(commands.map((command) => command.opcode), <int>[0x06, 0x04]);
      expect(commands.last.usesCmdCharacteristic, isFalse);
      expect(inactive.state, DeviceSosState.inactive);
    });

    test('device E2 cancel ACK is informational and does not change state', () {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );
      controller.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(
          <int>[0xE2, 0x02, 0x34, 0x12, 0x00, 0x00],
        )!,
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.preConfirm);
      expect(status.lastOpcode, isNull);
      expect(status.decoderNote, contains('ACTIVE_PACKET_STARTED_PRE_CONFIRM'));
    });

    test('app cancel keeps suppressing late SOS packets after ignored E2 ACK',
        () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async => commands.add(command),
      );

      await controller.triggerSos();
      final cancelled = await controller.cancelSos();
      controller.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(
          <int>[0xE2, 0x02, 0x34, 0x12, 0x00, 0x00],
        )!,
        source: DeviceSosTransitionSource.device,
      );
      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(
        commands.map((command) => command.opcode),
        <int>[0x06, 0x04, 0x04],
      );
      expect(cancelled.state, DeviceSosState.inactive);
      expect(status.state, DeviceSosState.inactive);
      expect(status.decoderNote, isNot(contains('PACKET_EXPLICIT_ACTIVE')));
    });

    test('device PRE-SOS after app cancel starts a fresh countdown', () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async => commands.add(command),
      );

      await controller.triggerSos();
      final cancelled = await controller.cancelSos();
      controller.handleIncomingSosPacket(
        _countdownPacket(retryCountBits: 2),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(commands.map((command) => command.opcode), <int>[0x06, 0x04]);
      expect(cancelled.state, DeviceSosState.inactive);
      expect(status.state, DeviceSosState.preConfirm);
      expect(status.previousState, DeviceSosState.inactive);
      expect(status.triggerOrigin, DeviceSosTransitionSource.device);
      expect(status.countdownStartedAt, isNotNull);
      expect(status.expectedActivationAt, isNotNull);
      expect(status.decoderNote, contains('PRE_CONFIRM_STARTED_COUNTDOWN'));
    });

    test('SOS ACK relay remains long-command only', () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController();
      addTearDown(controller.dispose);
      await controller.attach(
        shortCommandAvailable: true,
        longCommandAvailable: false,
        commandWriter: (command) async => commands.add(command),
      );

      await expectLater(
        controller.sendAckRelay(nodeId: 0x1234),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('longCommandAvailable=false'),
          ),
        ),
      );

      expect(
          EixamDeviceCommand.sosAckRelay(nodeId: 0x1234).usesCmdCharacteristic,
          isTrue);
      expect(commands, isEmpty);
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
        appActivationObservationTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
          if (command.opcode == 0x06) {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              controller.handleIncomingSosPacket(
                _countdownPacket(),
                source: DeviceSosTransitionSource.device,
              );
            });
          }
          if (command.opcode == 0x05) {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              controller.handleIncomingSosPacket(
                _activePacket(),
                source: DeviceSosTransitionSource.device,
              );
            });
          }
        },
      );

      final active = await controller.activateSosFromApp();

      expect(commands.map((command) => command.opcode), <int>[0x06, 0x05]);
      expect(active.state, DeviceSosState.active);
      expect(active.previousState, DeviceSosState.preConfirm);
      expect(active.triggerOrigin, DeviceSosTransitionSource.app);
    });

    test(
        'app activate helper waits for observed preConfirm before confirm to avoid early confirm race',
        () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
        appActivationObservationTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
          if (command.opcode == 0x05) {
            expect(
              controller.currentStatus.state,
              DeviceSosState.preConfirm,
            );
            expect(controller.currentStatus.derivedFromBlePacket, isTrue);
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              controller.handleIncomingSosPacket(
                _activePacket(),
                source: DeviceSosTransitionSource.device,
              );
            });
          }
          if (command.opcode == 0x06) {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              controller.handleIncomingSosPacket(
                _countdownPacket(),
                source: DeviceSosTransitionSource.device,
              );
            });
          }
        },
      );

      final active = await controller.activateSosFromApp();

      expect(commands.map((command) => command.opcode), <int>[0x06, 0x05]);
      expect(active.state, DeviceSosState.active);
      expect(active.optimistic, isFalse);
      expect(active.derivedFromBlePacket, isTrue);
    });

    test(
        'first observed BLE preConfirm preserves app trigger origin for app-triggered SOS',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 80),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(commandWriter: (_) async {});

      await controller.triggerSos();
      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.preConfirm);
      expect(status.transitionSource, DeviceSosTransitionSource.device);
      expect(status.triggerOrigin, DeviceSosTransitionSource.app);
      expect(status.derivedFromBlePacket, isTrue);
    });

    test(
        'app activate helper fails when no observed active transition arrives after confirm',
        () async {
      final commands = <EixamDeviceCommand>[];
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 80),
        countdownTick: const Duration(milliseconds: 5),
        appActivationObservationTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          commands.add(command);
          if (command.opcode == 0x06) {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              controller.handleIncomingSosPacket(
                _countdownPacket(),
                source: DeviceSosTransitionSource.device,
              );
            });
          }
        },
      );

      await expectLater(
        controller.activateSosFromApp(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('DEVICE_SOS_ACTIVE_OBSERVED_AFTER_CONFIRM'),
          ),
        ),
      );

      expect(commands.map((command) => command.opcode), <int>[0x06, 0x05]);
      expect(controller.currentStatus.state, DeviceSosState.preConfirm);
      expect(controller.currentStatus.derivedFromBlePacket, isTrue);
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
      expect(status.decoderNote, contains('PROMOTED_AFTER_COUNTDOWN'));
    });

    test(
        'app-originated cycle keeps app trigger origin when later BLE SOS packets arrive',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
        appActivationObservationTimeout: const Duration(milliseconds: 60),
      );
      addTearDown(controller.dispose);
      await controller.attach(
        commandWriter: (command) async {
          if (command.opcode == 0x06) {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              controller.handleIncomingSosPacket(
                _countdownPacket(),
                source: DeviceSosTransitionSource.device,
              );
            });
          }
          if (command.opcode == 0x05) {
            Future<void>.delayed(const Duration(milliseconds: 5), () {
              controller.handleIncomingSosPacket(
                _activePacket(),
                source: DeviceSosTransitionSource.device,
              );
            });
          }
        },
      );

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
        EixamSosEventPacket.tryParse(
          <int>[0xE1, 0x01, 0x34, 0x12, 0x00, 0x00],
        )!,
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

    test('device trigger compensates observed BLE countdown start skew', () {
      final observedAt = DateTime.utc(2026, 5, 12, 12, 0);
      final controller = DeviceSosController(
        countdownDuration: const Duration(seconds: 20),
        now: () => observedAt,
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.preConfirm);
      expect(
        status.countdownStartedAt,
        observedAt.subtract(const Duration(seconds: 2)),
      );
      expect(
        status.expectedActivationAt,
        observedAt.add(const Duration(seconds: 18)),
      );
      expect(status.countdownRemainingSeconds, 18);
    });

    test(
        'active SOS + incoming device cancel packet keeps terminal cancelled and does not reopen preConfirm',
        () {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );
      controller.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(
          <int>[0xE1, 0x01, 0x34, 0x12, 0x00, 0x00],
        )!,
        source: DeviceSosTransitionSource.device,
      );

      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.inactive);
      expect(status.packetId, 0);
      expect(status.countdownStartedAt, isNull);
      expect(status.expectedActivationAt, isNull);
      expect(status.countdownRemainingSeconds, isNull);
      expect(
        status.decoderNote,
        contains('REOPEN_SUPPRESSED_AFTER_TERMINAL'),
      );
    });

    test(
        'terminal cancel suppresses late same-node SOS packets even when packet id changes',
        () {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _activePacket(packetId: 0),
        source: DeviceSosTransitionSource.device,
      );
      controller.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(
          <int>[0xE1, 0x01, 0x34, 0x12, 0x00, 0x00],
        )!,
        source: DeviceSosTransitionSource.device,
      );

      controller.handleIncomingSosPacket(
        _countdownPacket(packetId: 2),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.inactive);
      expect(status.packetId, 0);
      expect(status.countdownStartedAt, isNull);
      expect(status.expectedActivationAt, isNull);
      expect(status.decoderNote, contains('SAME_NODE_REOPEN_SUPPRESSED'));
    });

    test(
        'active SOS + incoming device E1 02 packet keeps terminal cancelled and does not reopen preConfirm',
        () {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );
      controller.handleIncomingSosEventPacket(
        EixamSosEventPacket.tryParse(
          <int>[0xE1, 0x02, 0x34, 0x12, 0x00, 0x00],
        )!,
        source: DeviceSosTransitionSource.device,
      );

      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.inactive);
      expect(status.packetId, 0);
      expect(status.countdownStartedAt, isNull);
      expect(status.expectedActivationAt, isNull);
      expect(status.countdownRemainingSeconds, isNull);
      expect(
        status.decoderNote,
        contains('REOPEN_SUPPRESSED_AFTER_TERMINAL'),
      );
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
        contains('PROMOTED_AFTER_COUNTDOWN'),
      );
    });

    test(
        'device packet received after countdown expiry stays active instead of restarting preConfirm',
        () async {
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

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.active);
      expect(status.previousState, DeviceSosState.active);
      expect(status.triggerOrigin, DeviceSosTransitionSource.device);
      expect(status.state, isNot(DeviceSosState.preConfirm));
    });

    test(
        'sosType 1 packet after countdown deadline promotes to active even with a new packet id',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _countdownPacket(packetId: 0),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 70));

      controller.handleIncomingSosPacket(
        _countdownPacket(packetId: 3),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.active);
      expect(status.sosType, 1);
      expect(status.packetId, 0);
      expect(status.previousState, DeviceSosState.active);
      expect(status.decoderNote, contains('PRESERVED_OPEN_CYCLE'));
    });

    test(
        'duplicate PRE-SOS packet with a new packet id keeps the first countdown deadline',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 80),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _countdownPacket(packetId: 0),
        source: DeviceSosTransitionSource.device,
      );
      final first = controller.currentStatus;

      await Future<void>.delayed(const Duration(milliseconds: 30));
      controller.handleIncomingSosPacket(
        _countdownPacket(packetId: 1),
        source: DeviceSosTransitionSource.device,
      );
      final duplicate = controller.currentStatus;

      expect(duplicate.state, DeviceSosState.preConfirm);
      expect(duplicate.countdownStartedAt, first.countdownStartedAt);
      expect(duplicate.expectedActivationAt, first.expectedActivationAt);
      expect(duplicate.packetId, 1);

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final elapsed = controller.currentStatus;
      expect(elapsed.state, DeviceSosState.active);
      expect(elapsed.countdownStartedAt, first.countdownStartedAt);
      expect(elapsed.expectedActivationAt, first.expectedActivationAt);
      expect(elapsed.countdownRemainingSeconds, 0);
    });

    test('device active packet as first observed packet starts PRE-SOS', () {
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
      expect(
        status.decoderNote,
        contains('ACTIVE_PACKET_STARTED_PRE_CONFIRM'),
      );
    });

    test('realistic PRE-SOS packet then early active packet keeps countdown',
        () {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );
      final preConfirm = controller.currentStatus;

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );
      final active = controller.currentStatus;

      expect(preConfirm.state, DeviceSosState.preConfirm);
      expect(active.state, DeviceSosState.preConfirm);
      expect(active.previousState, DeviceSosState.preConfirm);
      expect(active.packetId, preConfirm.packetId);
      expect(active.nodeId, preConfirm.nodeId);
      expect(active.expectedActivationAt, preConfirm.expectedActivationAt);
      expect(
          active.decoderNote, contains('ACTIVE_PACKET_HELD_UNTIL_COUNTDOWN'));
    });

    test(
        'sosType 1 countdown packet maps to preConfirm without retryCount guess',
        () {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.preConfirm);
      expect(status.retryCount, greaterThan(0));
      expect(status.sosType, 1);
      expect(status.decoderNote, contains('PRE_CONFIRM_STARTED_COUNTDOWN'));
    });

    test('app-triggered PRE-SOS is not upgraded by first device notify',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 80),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(commandWriter: (_) async {});

      await controller.triggerSos();
      controller.handleIncomingSosPacket(
        _countdownPacket(retryCountBits: 0),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.preConfirm);
      expect(status.triggerOrigin, DeviceSosTransitionSource.app);
      expect(status.derivedFromBlePacket, isTrue);
      expect(
        status.decoderNote,
        contains('PRE_CONFIRM_KEEP_COUNTDOWN'),
      );
    });

    test('explicit active sosType from idle is held until PRE-SOS elapses',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );

      final preConfirm = controller.currentStatus;
      expect(preConfirm.state, DeviceSosState.preConfirm);
      expect(preConfirm.sosType, 2);
      expect(
        preConfirm.decoderNote,
        contains('ACTIVE_PACKET_STARTED_PRE_CONFIRM'),
      );

      await Future<void>.delayed(const Duration(milliseconds: 60));

      final active = controller.currentStatus;
      expect(active.state, DeviceSosState.active);
      expect(active.previousState, DeviceSosState.preConfirm);
    });

    test(
        'later PRE-SOS-like packet for the same active cycle is ignored as a downgrade',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _activePacket(),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      controller.handleIncomingSosPacket(
        _countdownPacket(),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.active);
      expect(status.previousState, DeviceSosState.active);
      expect(status.countdownStartedAt, isNull);
      expect(status.countdownRemainingSeconds, isNull);
      expect(
        status.decoderNote,
        contains('PRE_CONFIRM_RESTART_SUPPRESSED_AFTER_PROMOTION'),
      );
    });

    test(
        'repeated PRE-SOS packet for promoted cycle starts countdown after detach',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 35),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);
      await controller.attach(commandWriter: (_) async {});

      controller.handleIncomingSosPacket(
        _countdownPacket(retryCountBits: 0),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(controller.currentStatus.state, DeviceSosState.active);

      await controller.detach();
      expect(controller.currentStatus.state, DeviceSosState.inactive);

      controller.handleIncomingSosPacket(
        _countdownPacket(retryCountBits: 3),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.preConfirm);
      expect(status.previousState, DeviceSosState.inactive);
      expect(status.countdownStartedAt, isNotNull);
      expect(status.countdownRemainingSeconds, greaterThan(0));
      expect(
        status.decoderNote,
        contains('PRE_CONFIRM_STARTED_COUNTDOWN'),
      );
    });

    test(
        'later PRE-SOS-like packet with a new packet id cannot restart an active SOS',
        () async {
      final controller = DeviceSosController(
        countdownDuration: const Duration(milliseconds: 40),
        countdownTick: const Duration(milliseconds: 5),
      );
      addTearDown(controller.dispose);

      controller.handleIncomingSosPacket(
        _activePacket(packetId: 0),
        source: DeviceSosTransitionSource.device,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      controller.handleIncomingSosPacket(
        _countdownPacket(packetId: 1),
        source: DeviceSosTransitionSource.device,
      );

      final status = controller.currentStatus;
      expect(status.state, DeviceSosState.active);
      expect(status.previousState, DeviceSosState.active);
      expect(status.countdownStartedAt, isNull);
      expect(status.expectedActivationAt, isNull);
      expect(status.countdownRemainingSeconds, isNull);
      expect(
        status.decoderNote,
        contains('PRESERVED_OPEN_CYCLE'),
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

EixamSosPacket _countdownPacket({
  int retryCountBits = 1,
  int packetId = 0,
}) {
  final flagsWord =
      0x4000 | ((retryCountBits & 0x03) << 12) | (packetId & 0x0F);
  return EixamSosPacket.tryParse(<int>[
    0x34,
    0x12,
    0x00,
    0x00,
    flagsWord & 0xFF,
    (flagsWord >> 8) & 0xFF,
    0x00,
  ])!;
}

EixamSosPacket _activePacket({int packetId = 0}) {
  final flagsWord = 0x8000 | (packetId & 0x0F);
  return EixamSosPacket.tryParse(<int>[
    0x34,
    0x12,
    0x00,
    0x00,
    flagsWord & 0xFF,
    (flagsWord >> 8) & 0xFF,
    0x00,
  ])!;
}
