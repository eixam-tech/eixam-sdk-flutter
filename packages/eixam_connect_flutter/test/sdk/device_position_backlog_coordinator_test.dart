import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_backlog_packet.dart';
import 'package:eixam_connect_flutter/src/sdk/device_position_backlog_coordinator.dart';
import 'package:eixam_connect_flutter/src/sdk/device_position_batch_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('START, META, CHUNK, ACK, END emits recovered samples', () async {
    final harness = _Harness();
    final future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(harness.commands.single.encode().first, 0x30);

    await harness.send(_meta(7, 2, 4, 5));
    await harness.send(_chunk(7, 4, 1787486400, 1));
    await harness.send(_chunk(7, 5, 1787486460, 2));
    await harness.send(_end(7, 2, 5));
    final result = await future;

    expect(result.completed, isTrue);
    expect(result.recoveredCount, 2);
    expect(harness.batches.expand((batch) => batch.samples), hasLength(2));
    expect(harness.commands.map((command) => command.opcode),
        <int>[0x30, 0x31, 0x31]);
    expect(harness.commands[1].encode(), <int>[0x31, 7, 5, 0, 0, 0]);
  });

  test('wrong session/index aborts and closes ownership', () async {
    final harness = _Harness();
    final future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(seconds: 1),
    );
    await harness.send(_meta(7, 1, 4, 4));
    await harness.send(_chunk(8, 4, 1787486400, 1));
    final result = await future;

    expect(result.completed, isFalse);
    expect(harness.commands.last.opcode, 0x32);
    expect(harness.coordinator.isActive, isFalse);
  });

  test('timeout aborts, returns typed result, and permits restart', () async {
    final harness = _Harness();
    final future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(milliseconds: 10),
    );
    await harness.send(_meta(7, 1, 4, 4));
    final result = await future;
    expect(result.timedOut, isTrue);
    expect(harness.commands.last.opcode, 0x32);

    final restarted = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(seconds: 1),
    );
    await harness.send(_meta(8, 0, 0, 0));
    await harness.send(_end(8, 0, 0));
    expect((await restarted).completed, isTrue);
  });

  test('disconnect and cancellation complete partial sessions safely',
      () async {
    final harness = _Harness();
    var future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(seconds: 1),
    );
    await harness.send(_meta(7, 1, 0, 0));
    await harness.coordinator.disconnected();
    expect((await future).completed, isFalse);

    future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(seconds: 1),
    );
    await harness.send(_meta(8, 1, 0, 0));
    await harness.coordinator.cancel();
    expect((await future).completed, isFalse);
  });

  test('until rejects out-of-window data without blocking progression',
      () async {
    final harness = _Harness();
    final future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      timeout: const Duration(seconds: 1),
    );
    await harness.send(_meta(7, 2, 0, 1));
    await harness.send(_chunk(7, 0, 1787486400, 1));
    await harness.send(_chunk(7, 1, 1787486460, 2));
    await harness.send(_end(7, 2, 1));
    final result = await future;
    expect(result.recoveredCount, 1);
    expect(result.rejectedCount, 1);
  });

  test('full ring with a later first timestamp does not prove retention loss',
      () async {
    final harness = _Harness();
    final future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(milliseconds: 20),
    );
    await harness.send(_meta(7, 4095, 0, 4094));
    await harness.send(_chunk(7, 0, 1787486460, 1));

    final result = await future;
    expect(result.retentionGapDetected, isFalse);
  });

  test('a stuck START write cannot delay timeout or retain ownership',
      () async {
    final never = Completer<void>();
    final harness = _Harness(
      writer: (_) => never.future,
      abortTimeout: const Duration(milliseconds: 5),
    );

    final result = await harness.coordinator
        .sync(
          since:
              DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
          until: null,
          timeout: const Duration(milliseconds: 20),
        )
        .timeout(const Duration(milliseconds: 150));

    expect(result.timedOut, isTrue);
    expect(harness.coordinator.isActive, isFalse);
  });

  test('a stuck ACK and ABORT cannot delay authoritative timeout', () async {
    final never = Completer<void>();
    final harness = _Harness(
      writer: (command) {
        if (command.opcode == 0x31 || command.opcode == 0x32) {
          return never.future;
        }
        return Future<void>.value();
      },
      abortTimeout: const Duration(milliseconds: 5),
    );
    final future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(milliseconds: 20),
    );
    await harness.send(_meta(7, 1, 0, 0));
    await harness.send(_chunk(7, 0, 1787486400, 1));

    final result = await future.timeout(const Duration(milliseconds: 150));
    expect(result.timedOut, isTrue);
    expect(result.partial, isTrue);
    expect(harness.coordinator.isActive, isFalse);
  });

  test('failure completes before an unavailable ABORT transport', () async {
    final harness = _Harness(
      writer: (command) async {
        if (command.opcode == 0x32) throw StateError('disconnected');
      },
    );
    final future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(seconds: 1),
    );
    await harness.send(_meta(7, 1, 0, 0));
    await harness.send(_chunk(8, 0, 1787486400, 1));

    expect((await future).completed, isFalse);
    expect(harness.coordinator.isActive, isFalse);
  });

  test('disconnect releases ownership while START transport is pending',
      () async {
    final never = Completer<void>();
    final harness = _Harness(writer: (_) => never.future);
    final future = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    await harness.coordinator.disconnected();

    expect((await future).completed, isFalse);
    expect(harness.coordinator.isActive, isFalse);
  });

  test('late old START completion cannot mutate replacement ownership',
      () async {
    final oldStart = Completer<void>();
    var startWrites = 0;
    final harness = _Harness(
      writer: (command) {
        if (command.opcode == 0x30 && startWrites++ == 0) {
          return oldStart.future;
        }
        return Future<void>.value();
      },
    );
    final first = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(milliseconds: 20),
    );
    expect((await first).timedOut, isTrue);

    final replacement = harness.coordinator.sync(
      since: DateTime.fromMillisecondsSinceEpoch(1787486400000, isUtc: true),
      until: null,
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    expect(harness.coordinator.isActive, isTrue);
    oldStart.complete();
    await Future<void>.delayed(Duration.zero);
    expect(harness.coordinator.isActive, isTrue);

    await harness.send(_meta(8, 0, 0, 0));
    await harness.send(_end(8, 0, 0));
    expect((await replacement).completed, isTrue);
    expect(harness.coordinator.isActive, isFalse);
  });
}

class _Harness {
  _Harness({
    Future<void> Function(EixamDeviceCommand command)? writer,
    Duration abortTimeout = const Duration(milliseconds: 250),
  }) {
    coordinator = DevicePositionBacklogCoordinator(
      writeCommand: (command) {
        commands.add(command);
        return writer?.call(command) ?? Future<void>.value();
      },
      normalizer: DevicePositionBatchNormalizer(),
      emitBatch: batches.add,
      abortTimeout: abortTimeout,
    );
  }

  final commands = <EixamDeviceCommand>[];
  final batches = <EixamDevicePositionBatch>[];
  late final DevicePositionBacklogCoordinator coordinator;
  final receivedAt = DateTime.utc(2026, 8, 23, 12);

  Future<void> send(List<int> bytes) async {
    final packet = EixamPositionBacklogPacket.tryParse(
      bytes,
      receivedAt: receivedAt,
    );
    await coordinator.handleEvent(
      BleIncomingEvent(
        deviceId: 'device',
        canonicalHardwareId: 'hardware',
        type: BleIncomingEventType.telPositionBacklog,
        channel: EixamBleChannel.tel,
        payload: bytes,
        payloadHex: '',
        source: DeviceSosTransitionSource.device,
        receivedAt: receivedAt,
        positionBacklogPacket: packet,
      ),
    );
  }
}

List<int> _meta(int sid, int total, int start, int end) =>
    <int>[0xD1, 1, sid, 1, ..._u16(total), ..._u32(start), ..._u32(end)];
List<int> _chunk(int sid, int index, int timestamp, int packetId) => <int>[
      0xD1,
      2,
      sid,
      ..._u32(index),
      1,
      ..._u32(timestamp),
      ..._wire(packetId),
    ];
List<int> _end(int sid, int sent, int last) =>
    <int>[0xD1, 3, sid, ..._u16(sent), ..._u32(last), 0];
List<int> _u16(int value) => <int>[value & 0xFF, (value >> 8) & 0xFF];
List<int> _u32(int value) => <int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ];
List<int> _wire(int packetId) => <int>[
      0x78,
      0x56,
      0x34,
      0x12,
      1,
      2,
      3,
      4,
      5,
      6,
      0x80 | packetId,
      0x25,
    ];
