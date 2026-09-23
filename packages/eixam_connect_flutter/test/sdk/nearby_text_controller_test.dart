import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_nearby_text_packet.dart';
import 'package:eixam_connect_flutter/src/provisioning/provisioning_command_result.dart';
import 'package:eixam_connect_flutter/src/sdk/nearby_text_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sendBroadcast waits for 0xDA on-air', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final commands = <EixamDeviceCommand>[];
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async => commands.add(command),
      packetIdFactory: () => 0x22,
    );
    addTearDown(controller.dispose);

    final future = controller.sendBroadcast('hi');
    await Future<void>.delayed(Duration.zero);
    expect(commands, isNotEmpty);
    expect(commands.first.opcode, 0x40);

    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0x22, 0, 0, 0, 0],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0x22, 0, 0, 0, 0],
        ),
      ),
    );

    final result = await future;
    expect(result.packetId, 0x22);
    expect(result.status, NearbyTextTxStatus.onAir);
  });

  test('rejects empty and oversize locally', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {},
    );
    addTearDown(controller.dispose);

    expect(
      (await controller.sendBroadcast('   ')).status,
      NearbyTextTxStatus.empty,
    );
    expect(
      (await controller.sendBroadcast('a' * 232)).status,
      NearbyTextTxStatus.tooLong,
    );
    expect(
      (await controller.sendGroup('a' * 232, groupId: 7)).status,
      NearbyTextTxStatus.tooLong,
    );
    expect(
      (await controller.sendDirect('a' * 201, destNodeId: 2)).status,
      NearbyTextTxStatus.tooLong,
    );
  });

  test('231 B plaza text is framed and written', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final commands = <EixamDeviceCommand>[];
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async => commands.add(command),
      packetIdFactory: () => 5,
      txTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);

    final result = await controller.sendBroadcast('a' * 231);
    expect(result.status, NearbyTextTxStatus.timeout);
    expect(commands, isNotEmpty);
    final total =
        commands.first.encode()[1] | (commands.first.encode()[2] << 8);
    expect(total, EixamBleProtocol.nearbyTextTxHeaderLength + 231);
  });

  test(
    'native protection owner still writes Nearby over the active command path',
    () async {
      final incoming = StreamController<BleIncomingEvent>.broadcast();
      addTearDown(incoming.close);
      final commands = <EixamDeviceCommand>[];
      final controller = NearbyTextController(
        incomingEvents: incoming.stream,
        writeCommand: (command) async => commands.add(command),
        packetIdFactory: () => 9,
        txTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(controller.dispose);
      controller.markConnected();

      final text = controller.sendBroadcast('hi');
      await Future<void>.delayed(Duration.zero);
      expect(commands.where((c) => c.opcode == 0x40), isNotEmpty);
      incoming.add(
        BleIncomingEvent(
          deviceId: 'tag',
          type: BleIncomingEventType.nearbyTextTxStatus,
          channel: EixamBleChannel.tel,
          payload: const <int>[0xDA, 9, 0, 0, 0, 0],
          payloadHex: '',
          source: DeviceSosTransitionSource.device,
          receivedAt: DateTime.now(),
          nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
            const <int>[0xDA, 9, 0, 0, 0, 0],
          ),
        ),
      );
      expect((await text).status, NearbyTextTxStatus.onAir);

      commands.clear();
      final group = controller.setGroup(
        groupId: 1,
        psk: List<int>.filled(32, 3),
      );
      await Future<void>.delayed(Duration.zero);
      expect(commands.where((c) => c.opcode == 0x41), isNotEmpty);
      incoming.add(
        BleIncomingEvent(
          deviceId: 'tag',
          type: BleIncomingEventType.provisioningCommandResult,
          channel: EixamBleChannel.tel,
          payload: const <int>[0xE9, 0x7A, 0x01, 0x41, 0x01, 0x01],
          payloadHex: '',
          source: DeviceSosTransitionSource.device,
          receivedAt: DateTime.now(),
          provisioningCommandResult: ProvisioningCommandResult.tryParse(
            const <int>[0xE9, 0x7A, 0x01, 0x41, 0x01, 0x01],
          ),
        ),
      );
      expect((await group).accepted, isTrue);
    },
  );

  test('times out when firmware never answers 0xDA', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {},
      packetIdFactory: () => 1,
      txTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);

    final result = await controller.sendBroadcast('hi');
    expect(result.status, NearbyTextTxStatus.timeout);
  });

  test(
    'group writer miss stays retryable while the tag stays connected',
    () async {
      final incoming = StreamController<BleIncomingEvent>.broadcast();
      addTearDown(incoming.close);
      var writes = 0;
      final controller = NearbyTextController(
        incomingEvents: incoming.stream,
        writeCommand: (_) async {
          writes++;
          if (writes == 1) {
            throw const DeviceException(
              'E_BLE_COMMAND_WRITER_NOT_READY',
              'E_BLE_COMMAND_WRITER_NOT_READY',
            );
          }
        },
      );
      addTearDown(controller.dispose);

      final first = await controller.setGroup(
        groupId: 1,
        psk: List<int>.filled(32, 3),
      );
      expect(first.commandChannelUnavailable, isTrue);

      final retry = controller.setGroup(
        groupId: 1,
        psk: List<int>.filled(32, 3),
      );
      await Future<void>.delayed(Duration.zero);
      incoming.add(
        BleIncomingEvent(
          deviceId: 'tag',
          type: BleIncomingEventType.provisioningCommandResult,
          channel: EixamBleChannel.tel,
          payload: const <int>[0xE9, 0x7A, 0x01, 0x41, 0x00, 0x01],
          payloadHex: '',
          source: DeviceSosTransitionSource.device,
          receivedAt: DateTime.now(),
          provisioningCommandResult: ProvisioningCommandResult.tryParse(
            const <int>[0xE9, 0x7A, 0x01, 0x41, 0x00, 0x01],
          ),
        ),
      );
      expect((await retry).accepted, isTrue);
      expect(writes, greaterThan(1));
    },
  );

  test('sendBroadcast retries a writer miss then waits for 0xDA', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    var writes = 0;
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {
        writes++;
        if (writes == 1) {
          throw const DeviceException(
            'E_BLE_COMMAND_WRITER_NOT_READY',
            'E_BLE_COMMAND_WRITER_NOT_READY',
          );
        }
      },
      packetIdFactory: () => 0x22,
      txTimeout: const Duration(milliseconds: 80),
    );
    addTearDown(controller.dispose);

    final future = controller.sendBroadcast('hi');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(writes, greaterThanOrEqualTo(2));
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0x22, 0, 0, 0, 0],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0x22, 0, 0, 0, 0],
        ),
      ),
    );
    final result = await future;
    expect(result.status, NearbyTextTxStatus.onAir);
    expect(result.packetId, 0x22);
  });

  test('serializes overlapping sendBroadcast writes', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final commands = <EixamDeviceCommand>[];
    var nextId = 1;
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async => commands.add(command),
      packetIdFactory: () => nextId++,
    );
    addTearDown(controller.dispose);

    final first = controller.sendBroadcast('aa');
    await Future<void>.delayed(Duration.zero);
    final second = controller.sendBroadcast('bb');
    await Future<void>.delayed(Duration.zero);
    expect(commands, hasLength(2));

    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0x01, 0, 0, 0, 0],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0x01, 0, 0, 0, 0],
        ),
      ),
    );
    expect((await first).status, NearbyTextTxStatus.onAir);
    await Future<void>.delayed(Duration.zero);
    expect(commands, hasLength(4));

    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0x02, 0, 0, 0, 0],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0x02, 0, 0, 0, 0],
        ),
      ),
    );
    expect((await second).status, NearbyTextTxStatus.onAir);
  });

  test('0xDA with packetId 0 completes the in-flight waiter', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {},
      packetIdFactory: () => 0x22,
    );
    addTearDown(controller.dispose);

    final future = controller.sendBroadcast('hi');
    await Future<void>.delayed(Duration.zero);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0, 0, 0, 0, 2],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0, 0, 0, 0, 2],
        ),
      ),
    );

    final result = await future;
    expect(result.status, NearbyTextTxStatus.rateLimited);
  });

  test('sendDirect writes dest into the 0x40 blob', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final commands = <EixamDeviceCommand>[];
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async => commands.add(command),
      packetIdFactory: () => 1,
    );
    addTearDown(controller.dispose);

    final future = controller.sendDirect('hi', destNodeId: 0xA68E6171);
    await Future<void>.delayed(Duration.zero);
    expect(commands.first.bytes[5], 0x71);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 1, 0, 0, 0, 0],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 1, 0, 0, 0, 0],
        ),
      ),
    );
    expect((await future).status, NearbyTextTxStatus.onAir);
  });

  test('setGroup surfaces slots-full REJECT detail 0xFF', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async {},
    );
    addTearDown(controller.dispose);

    final future = controller.setGroup(
      groupId: 1,
      psk: List<int>.filled(32, 7),
    );
    await Future<void>.delayed(Duration.zero);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.provisioningCommandResult,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xe9, 0x7a, 1, 0x41, 2, 0xFF],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        provisioningCommandResult: ProvisioningCommandResult.tryParse(
          const <int>[0xe9, 0x7a, 1, 0x41, 2, 0xFF],
        ),
      ),
    );
    final result = await future;
    expect(result.accepted, isFalse);
    expect(result.slotsFull, isTrue);
  });

  test('BLE drop completes in-flight TX as disconnected', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {},
      packetIdFactory: () => 0x22,
    );
    addTearDown(controller.dispose);

    final future = controller.sendBroadcast('hi');
    await Future<void>.delayed(Duration.zero);
    controller.markDisconnected();

    final result = await future;
    expect(result.status, NearbyTextTxStatus.disconnected);
  });

  test('zero or short group key is REJECT 0xFE without a BLE write', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final commands = <EixamDeviceCommand>[];
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async => commands.add(command),
    );
    addTearDown(controller.dispose);

    final zero = await controller.setGroup(
      groupId: 1,
      psk: List<int>.filled(32, 0),
    );
    expect(zero.accepted, isFalse);
    expect(zero.badKey, isTrue);
    expect(commands, isEmpty);

    final short = await controller.setGroup(groupId: 1, psk: const <int>[1]);
    expect(short.badKey, isTrue);
    expect(commands, isEmpty);
  });

  test('group timeout then late ACK does not complete a retry', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    var writes = 0;
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {
        writes++;
      },
      txTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);

    final first = await controller.setGroup(
      groupId: 1,
      psk: List<int>.filled(32, 7),
    );
    expect(first.accepted, isFalse);
    expect(writes, greaterThan(0));

    final retry = controller.setGroup(groupId: 1, psk: List<int>.filled(32, 7));
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.provisioningCommandResult,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        provisioningCommandResult: ProvisioningCommandResult.tryParse(
          const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        ),
      ),
    );
    final retried = await retry;
    expect(retried.accepted, isFalse);

    controller.markDisconnected();
    controller.markConnected();
    final afterReconnect = controller.setGroup(
      groupId: 1,
      psk: List<int>.filled(32, 7),
    );
    await Future<void>.delayed(Duration.zero);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.provisioningCommandResult,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        provisioningCommandResult: ProvisioningCommandResult.tryParse(
          const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        ),
      ),
    );
    expect((await afterReconnect).accepted, isTrue);
  });

  test('group timeout while connected allows a drained retry', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    var writes = 0;
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {
        writes++;
      },
      txTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);
    controller.markConnected();

    final first = await controller.setGroup(
      groupId: 1,
      psk: List<int>.filled(32, 7),
    );
    expect(first.accepted, isFalse);

    final retry = controller.setGroup(groupId: 1, psk: List<int>.filled(32, 7));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.provisioningCommandResult,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        provisioningCommandResult: ProvisioningCommandResult.tryParse(
          const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        ),
      ),
    );
    expect((await retry).accepted, isTrue);
    expect(writes, greaterThan(1));
  });

  test('group timeout while connected retries once inside setGroup', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    var attempts = 0;
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async {
        final bytes = command.bytes;
        if (bytes.length >= 5 &&
            bytes[0] == 0x41 &&
            bytes[3] == 0 &&
            bytes[4] == 0) {
          attempts++;
        }
      },
      txTimeout: const Duration(milliseconds: 20),
    );
    addTearDown(controller.dispose);
    controller.markConnected();

    final future = controller.setGroup(
      groupId: 1,
      psk: List<int>.filled(32, 7),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (attempts < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(attempts, 2);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.provisioningCommandResult,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        provisioningCommandResult: ProvisioningCommandResult.tryParse(
          const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        ),
      ),
    );
    expect((await future).accepted, isTrue);
    expect(attempts, 2);
  });

  test('setGroup replace writes action 2', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final commands = <EixamDeviceCommand>[];
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async => commands.add(command),
    );
    addTearDown(controller.dispose);

    final future = controller.setGroup(
      groupId: 1,
      psk: List<int>.filled(32, 9),
      replace: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(commands, isNotEmpty);
    expect(commands.first.bytes[5], 2);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.provisioningCommandResult,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        provisioningCommandResult: ProvisioningCommandResult.tryParse(
          const <int>[0xe9, 0x7a, 1, 0x41, 0, 1],
        ),
      ),
    );
    expect((await future).accepted, isTrue);
  });

  test('plaza isBroadcast is false for group traffic', () {
    final group = NearbyIncomingText(
      fromNodeId: 1,
      destNodeId: 0xFFFFFFFF,
      packetId: 1,
      groupId: 9,
      text: 'hi',
      receivedAt: DateTime.now(),
    );
    expect(group.isBroadcast, isFalse);
    expect(group.isGroup, isTrue);
    expect(group.isDirect, isFalse);

    final plaza = NearbyIncomingText(
      fromNodeId: 1,
      destNodeId: 0xFFFFFFFF,
      packetId: 1,
      groupId: 0,
      text: 'hi',
      receivedAt: DateTime.now(),
    );
    expect(plaza.isBroadcast, isTrue);
    expect(plaza.isDirect, isFalse);
  });

  test('caches owner name and writes 0x42 once connected', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final commands = <EixamDeviceCommand>[];
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (command) async => commands.add(command),
      txTimeout: const Duration(milliseconds: 40),
    );
    addTearDown(controller.dispose);

    await controller.setOwnerDisplayName('  ');
    await controller.setOwnerDisplayName('Alice');
    expect(commands, isEmpty);

    controller.markConnected();
    await Future<void>.delayed(Duration.zero);
    expect(commands, isNotEmpty);
    expect(commands.first.opcode, 0x42);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.provisioningCommandResult,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xE9, 0x7A, 0x01, 0x42, 0x01, 0x01],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        provisioningCommandResult: ProvisioningCommandResult.tryParse(
          const <int>[0xE9, 0x7A, 0x01, 0x42, 0x01, 0x01],
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
  });

  test('emits NearbyNodeName from 0xDB and ignores empty names', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {},
    );
    addTearDown(controller.dispose);
    final names = <NearbyNodeName>[];
    final sub = controller.nodeNames.listen(names.add);
    addTearDown(sub.cancel);

    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyOwnerName,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDB, 0xAA, 0, 0, 0, 0x42, 0x6F, 0x62],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.utc(2026, 1, 1),
        nearbyOwnerNamePacket: EixamNearbyOwnerNamePacket.tryParse(const <int>[
          0xDB,
          0xAA,
          0,
          0,
          0,
          0x42,
          0x6F,
          0x62,
        ]),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(names, hasLength(1));
    expect(names.single.nodeId, 0xAA);
    expect(names.single.name, 'Bob');
  });

  test('replays Nearby RX received before the first subscriber', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {},
    );
    addTearDown(controller.dispose);
    const payload = <int>[
      0xD8,
      0x78,
      0x56,
      0x34,
      0x12,
      0xFF,
      0xFF,
      0xFF,
      0xFF,
      0x01,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0x6F,
      0x6B,
    ];
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextRx,
        channel: EixamBleChannel.tel,
        payload: payload,
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.utc(2026, 9, 21),
        nearbyTextPacket: EixamNearbyTextPacket.tryParse(payload),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final received = <NearbyIncomingText>[];
    final sub = controller.incoming.listen(received.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));
    expect(received.single.text, 'ok');
    expect(received.single.fromNodeId, 0x12345678);
  });

  test('delivery 0xDA does not complete the on-air waiter', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {},
      packetIdFactory: () => 0x22,
    );
    addTearDown(controller.dispose);

    final future = controller.sendBroadcast('hi');
    await Future<void>.delayed(Duration.zero);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0x22, 0, 0, 0, 12],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0x22, 0, 0, 0, 12],
        ),
      ),
    );
    var completed = false;
    unawaited(future.then((_) => completed = true));
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0x22, 0, 0, 0, 0],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0x22, 0, 0, 0, 0],
        ),
      ),
    );
    expect((await future).status, NearbyTextTxStatus.onAir);
  });

  test('watchNearbyTextTxStatus emits on-air then recipient ACK', () async {
    final incoming = StreamController<BleIncomingEvent>.broadcast();
    addTearDown(incoming.close);
    final controller = NearbyTextController(
      incomingEvents: incoming.stream,
      writeCommand: (_) async {},
      packetIdFactory: () => 0x22,
    );
    addTearDown(controller.dispose);

    final updates = <NearbyTextTxResult>[];
    final sub = controller.txStatus.listen(updates.add);
    addTearDown(sub.cancel);

    final future = controller.sendDirect('hi', destNodeId: 9);
    await Future<void>.delayed(Duration.zero);
    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0x22, 0, 0, 0, 0],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0x22, 0, 0, 0, 0],
        ),
      ),
    );
    expect((await future).status, NearbyTextTxStatus.onAir);

    incoming.add(
      BleIncomingEvent(
        deviceId: 'tag',
        type: BleIncomingEventType.nearbyTextTxStatus,
        channel: EixamBleChannel.tel,
        payload: const <int>[0xDA, 0x22, 0, 0, 0, 13],
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.now(),
        nearbyTextTxStatusPacket: EixamNearbyTextTxStatusPacket.tryParse(
          const <int>[0xDA, 0x22, 0, 0, 0, 13],
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(updates.map((item) => item.status), [
      NearbyTextTxStatus.onAir,
      NearbyTextTxStatus.recipientAck,
    ]);
  });
}
