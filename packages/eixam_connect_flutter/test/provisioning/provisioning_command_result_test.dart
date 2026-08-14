import 'dart:async';

import 'package:eixam_connect_flutter/src/provisioning/provisioning_command_result.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('strictly parses OK, OK_NOCHANGE and REJECT', () {
    expect(
      ProvisioningCommandResult.tryParse(<int>[0xe9, 0x7a, 1, 0x20, 0, 0])
          ?.outcome,
      ProvisioningCommandOutcome.ok,
    );
    expect(
      ProvisioningCommandResult.tryParse(<int>[0xe9, 0x7a, 1, 0x20, 1, 0])
          ?.outcome,
      ProvisioningCommandOutcome.okNoChange,
    );
    expect(
      ProvisioningCommandResult.tryParse(<int>[0xe9, 0x7a, 1, 0x21, 2, 7])
          ?.outcome,
      ProvisioningCommandOutcome.reject,
    );
  });

  test('rejects malformed, wrong version/result and E9 78 status packets', () {
    final invalid = <List<int>>[
      <int>[0xe9, 0x7a, 1, 0x20, 0],
      <int>[0xe8, 0x7a, 1, 0x20, 0, 0],
      <int>[0xe9, 0x7a, 2, 0x20, 0, 0],
      <int>[0xe9, 0x7a, 1, 0x20, 3, 0],
      <int>[0xe9, 0x78, 2, 3, 0, 0],
    ];
    for (final packet in invalid) {
      expect(ProvisioningCommandResult.tryParse(packet), isNull);
    }
  });

  test('coordinator ignores wrong opcode and requires commit detail', () async {
    final packets = StreamController<List<int>>.broadcast();
    final coordinator = ProvisioningAckCoordinator(
      packets: packets.stream,
      timeout: const Duration(milliseconds: 80),
    );
    final result = coordinator.run(
      expectedOpcode: 0x24,
      expectedDetail: 3,
      write: () async {
        packets.add(<int>[0xe9, 0x7a, 1, 0x20, 0, 3]);
        packets.add(<int>[0xe9, 0x7a, 1, 0x24, 0, 2]);
        scheduleMicrotask(
          () => packets.add(<int>[0xe9, 0x7a, 1, 0x24, 0, 3]),
        );
      },
    );

    expect((await result).opcode, 0x24);
    await coordinator.dispose();
    await packets.close();
  });

  test('coordinator maps reject and timeout to typed failures', () async {
    final packets = StreamController<List<int>>.broadcast();
    final coordinator = ProvisioningAckCoordinator(
      packets: packets.stream,
      timeout: const Duration(milliseconds: 20),
    );

    await expectLater(
      coordinator.run(
        expectedOpcode: 0x21,
        write: () async => packets.add(
          <int>[0xe9, 0x7a, 1, 0x21, 2, 0],
        ),
      ),
      throwsA(isA<ProvisioningCommandRejectedException>()),
    );
    await expectLater(
      coordinator.run(expectedOpcode: 0x20, write: () async {}),
      throwsA(isA<ProvisioningCommandTimeoutException>()),
    );
    await coordinator.dispose();
    await packets.close();
  });

  test('coordinator serializes ACK-bearing transactions', () async {
    final packets = StreamController<List<int>>.broadcast();
    final coordinator = ProvisioningAckCoordinator(packets: packets.stream);
    final writes = <int>[];
    final first = coordinator.run(
      expectedOpcode: 0x20,
      write: () async => writes.add(0x20),
    );
    final second = coordinator.run(
      expectedOpcode: 0x21,
      write: () async => writes.add(0x21),
    );
    await Future<void>.delayed(Duration.zero);
    expect(writes, <int>[0x20]);
    packets.add(<int>[0xe9, 0x7a, 1, 0x20, 0, 0]);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(writes, <int>[0x20, 0x21]);
    packets.add(<int>[0xe9, 0x7a, 1, 0x21, 0, 0]);
    await second;
    await coordinator.dispose();
    await packets.close();
  });

  test('timeout poisons epoch and stale same-opcode ACK cannot satisfy retry',
      () async {
    final packets = StreamController<List<int>>.broadcast();
    final coordinator = ProvisioningAckCoordinator(
      packets: packets.stream,
      timeout: const Duration(milliseconds: 15),
    );
    await expectLater(
      coordinator.run(expectedOpcode: 0x20, write: () async {}),
      throwsA(isA<ProvisioningCommandTimeoutException>()),
    );
    packets.add(<int>[0xe9, 0x7a, 1, 0x20, 0, 0]);
    await expectLater(
      coordinator.run(expectedOpcode: 0x20, write: () async {}),
      throwsA(isA<ProvisioningConnectionEpochInvalidException>()),
    );

    coordinator.markDisconnected();
    coordinator.markConnected();
    final retry = coordinator.run(
      expectedOpcode: 0x20,
      write: () async => scheduleMicrotask(
        () => packets.add(<int>[0xe9, 0x7a, 1, 0x20, 0, 0]),
      ),
    );
    expect((await retry).outcome, ProvisioningCommandOutcome.ok);
    await coordinator.dispose();
    await packets.close();
  });

  test('disconnect while awaiting ACK is interruption, not timeout', () async {
    final packets = StreamController<List<int>>.broadcast();
    final coordinator = ProvisioningAckCoordinator(
      packets: packets.stream,
      timeout: const Duration(seconds: 1),
    );
    final result = coordinator.run(
      expectedOpcode: 0x21,
      write: () async => scheduleMicrotask(coordinator.markDisconnected),
    );
    await expectLater(
      result,
      throwsA(isA<ProvisioningCommunicationInterruptedException>()),
    );
    await coordinator.dispose();
    await packets.close();
  });

  test('immediate ACK after write is accepted and wrong opcode ignored',
      () async {
    final packets = StreamController<List<int>>.broadcast();
    final coordinator = ProvisioningAckCoordinator(packets: packets.stream);
    final result = coordinator.run(
      expectedOpcode: 0x21,
      write: () async {
        packets.add(<int>[0xe9, 0x7a, 1, 0x20, 0, 0]);
        packets.add(<int>[0xe9, 0x7a, 1, 0x21, 0, 0]);
      },
    );
    expect((await result).opcode, 0x21);
    await coordinator.dispose();
    await packets.close();
  });

  test('ACK just inside timeout boundary completes exactly once', () async {
    final packets = StreamController<List<int>>.broadcast();
    final coordinator = ProvisioningAckCoordinator(
      packets: packets.stream,
      timeout: const Duration(milliseconds: 40),
    );
    final result = coordinator.run(
      expectedOpcode: 0x20,
      write: () async => Timer(
        const Duration(milliseconds: 30),
        () => packets.add(<int>[0xe9, 0x7a, 1, 0x20, 0, 0]),
      ),
    );
    expect((await result).outcome, ProvisioningCommandOutcome.ok);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(coordinator.connectionEpochValid, isTrue);
    await coordinator.dispose();
    await packets.close();
  });
}
