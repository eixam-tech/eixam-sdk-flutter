import 'dart:async';
import 'dart:typed_data';

import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/provisioning/provisioning_command_result.dart';
import 'package:eixam_connect_flutter/src/provisioning/softsim_provisioning.dart';
import 'package:eixam_connect_flutter/src/provisioning/softsim_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  SoftSimMaterial material() => buildSoftSim(
        psk: Uint8List.fromList(List<int>.generate(32, (index) => index)),
        nodeId: 305419896,
        backendUrl: 'https://api.staging.eixam.io',
        telSpreadingFactor: 9,
        sosPowerDbm: 22,
      );

  test('builds exact secret 230-byte SoftSIM and zeroes on dispose', () {
    final softSim = material();
    final bytes = softSim.bytes;
    final owned = bytes;
    final data = ByteData.sublistView(bytes);

    expect(bytes, hasLength(230));
    expect(bytes.sublist(0, 32), List<int>.generate(32, (index) => index));
    expect(String.fromCharCodes(bytes.sublist(32, 41)), '305419896');
    expect(bytes[41], 0);
    expect(bytes.sublist(42, 96), everyElement(0));
    const backendUrl = 'https://api.staging.eixam.io';
    final backendUrlEnd = 96 + backendUrl.length;
    expect(String.fromCharCodes(bytes.sublist(96, backendUrlEnd)), backendUrl);
    expect(bytes[backendUrlEnd], 0);
    expect(bytes.sublist(backendUrlEnd + 1, 224), everyElement(0));
    expect(data.getUint32(224, Endian.little), 120000);
    expect(bytes[228], 9);
    expect(data.getInt8(229), 22);

    softSim.dispose();
    expect(owned, everyElement(0));
    expect(() => softSim.bytes, throwsStateError);
  });

  test('rejects wrong PSK, node id, long/non-ASCII URL and field overflow', () {
    expect(
      () => buildSoftSim(
        psk: Uint8List(31),
        nodeId: 1,
        backendUrl: 'https://example.test',
        telSpreadingFactor: 9,
        sosPowerDbm: 22,
      ),
      throwsArgumentError,
    );
    expect(
      () => buildSoftSim(
        psk: Uint8List(32),
        nodeId: -1,
        backendUrl: 'https://example.test',
        telSpreadingFactor: 9,
        sosPowerDbm: 22,
      ),
      throwsArgumentError,
    );
    for (final url in <String>[
      List<String>.filled(128, 'x').join(),
      'https://é.example',
    ]) {
      expect(
        () => buildSoftSim(
          psk: Uint8List(32),
          nodeId: 1,
          backendUrl: url,
          telSpreadingFactor: 9,
          sosPowerDbm: 22,
        ),
        throwsArgumentError,
      );
    }
  });

  test('CRC32 matches IEEE vectors and BEGIN serializes little-endian CRC', () {
    expect(provisioningCrc32(<int>[]), 0);
    expect(provisioningCrc32('123456789'.codeUnits), 0xcbf43926);
    final softSim = material();
    final begin = encodeSoftSimBegin(softSim.bytes);
    final data = ByteData.sublistView(begin);

    expect(begin.sublist(0, 2), <int>[0x24, 1]);
    expect(data.getUint16(2, Endian.little), 230);
    expect(data.getUint32(4, Endian.little), provisioningCrc32(softSim.bytes));
    softSim.dispose();
  });

  test('chunks are ordered, contiguous, <=16 total and end partial', () {
    final softSim = material();
    final chunks = <Uint8List>[
      for (var offset = 0; offset < softSim.bytes.length; offset += 12)
        encodeSoftSimChunk(softSim.bytes, offset),
    ];

    expect(chunks, hasLength(20));
    for (var index = 0; index < chunks.length; index++) {
      final chunk = chunks[index];
      expect(chunk.length, lessThanOrEqualTo(16));
      expect(chunk.sublist(0, 2), <int>[0x24, 2]);
      expect(
          ByteData.sublistView(chunk).getUint16(2, Endian.little), index * 12);
    }
    expect(chunks.last, hasLength(6));
    expect(encodeSoftSimCommit(), <int>[0x24, 3]);
    expect(encodeSoftSimAbort(), <int>[0x24, 4]);
    softSim.dispose();
  });

  test('all 0x24 frames are secret-safe in diagnostics', () {
    final command = EixamDeviceCommand.provisioningFrame(
      label: 'SOFTSIM CHUNK',
      bytes: <int>[0x24, 2, 0, 0, 0xaa],
      secret: true,
    );
    expect(command.payloadSensitivity, BleCommandPayloadSensitivity.secret);
    expect(command.encodedHex, isNot(contains('AA')));
    expect(command.encodedHex.toLowerCase(), contains('redacted'));
    expect(command.diagnosticPayload, isNot(contains('AA')));
    expect(command.diagnosticPayload.toLowerCase(), contains('redacted'));
    expect(
      EixamDeviceCommand.provisioningFrame(
        label: 'SOFTSIM COMMIT',
        bytes: <int>[0x24, 3],
        secret: false,
      ).payloadSensitivity,
      BleCommandPayloadSensitivity.secret,
    );
  });

  test('uncertain chunk aborts without retrying on the same connection epoch',
      () async {
    final packets = StreamController<List<int>>.broadcast();
    final ack = ProvisioningAckCoordinator(packets: packets.stream);
    final writes = <List<int>>[];
    var failed = false;
    final transport = SoftSimProvisioningTransport(
      packets: packets.stream,
      ackCoordinator: ack,
      write: (command) async {
        final bytes = command.encode();
        writes.add(List<int>.of(bytes));
        if (!failed && bytes.length > 4 && bytes[1] == 2) {
          failed = true;
          throw StateError('uncertain write');
        }
        if (bytes.length == 2 && bytes[1] == 3) {
          scheduleMicrotask(
            () => packets.add(<int>[0xe9, 0x7a, 1, 0x24, 0, 3]),
          );
        }
      },
    );
    final softSim = material();
    await expectLater(
      transport.transfer(softSim),
      throwsA(isA<SoftSimTransportUncertainException>()),
    );

    final begins = writes.where((bytes) => bytes[1] == 1);
    expect(begins, hasLength(1));
    softSim.dispose();
    await ack.dispose();
    await packets.close();
  });

  for (final scenario in <({String name, int rejectAfterWrite})>[
    (name: 'BEGIN', rejectAfterWrite: 1),
    (name: 'middle CHUNK', rejectAfterWrite: 8),
    (name: 'final CHUNK', rejectAfterWrite: 21),
  ]) {
    test('delayed ${scenario.name} REJECT aborts before COMMIT', () async {
      final packets = StreamController<List<int>>.broadcast();
      final ack = ProvisioningAckCoordinator(packets: packets.stream);
      final writes = <List<int>>[];
      final transport = SoftSimProvisioningTransport(
        packets: packets.stream,
        ackCoordinator: ack,
        rejectionObservationInterval: const Duration(milliseconds: 20),
        write: (command) async {
          writes.add(List<int>.of(command.encode()));
          if (writes.length == scenario.rejectAfterWrite) {
            Timer(const Duration(milliseconds: 5), () {
              packets.add(<int>[0xe9, 0x7a, 1, 0x24, 2, 2]);
            });
          }
        },
      );
      final softSim = material();

      await expectLater(
        transport.transfer(softSim),
        throwsA(isA<ProvisioningCommandRejectedException>()),
      );
      expect(
          writes.where((bytes) => bytes.length == 2 && bytes[1] == 3), isEmpty);

      softSim.dispose();
      await ack.dispose();
      await packets.close();
    });
  }

  test('REJECT in final-CHUNK to COMMIT handoff cannot be missed', () async {
    final packets = StreamController<List<int>>.broadcast();
    final ack = ProvisioningAckCoordinator(packets: packets.stream);
    final writes = <List<int>>[];
    final transport = SoftSimProvisioningTransport(
      packets: packets.stream,
      ackCoordinator: ack,
      rejectionObservationInterval: const Duration(milliseconds: 4),
      write: (command) async {
        final bytes = List<int>.of(command.encode());
        writes.add(bytes);
        if (writes.length == 21) {
          Timer(const Duration(milliseconds: 5), () {
            packets.add(<int>[0xe9, 0x7a, 1, 0x24, 2, 2]);
          });
        }
      },
    );
    final softSim = material();

    await expectLater(
      transport.transfer(softSim),
      throwsA(isA<ProvisioningCommandRejectedException>()),
    );
    expect(writes.where((bytes) => bytes.length == 2 && bytes[1] == 3),
        hasLength(1));

    softSim.dispose();
    await ack.dispose();
    await packets.close();
  });

  test('secret frame and command copies are zeroed after write exception',
      () async {
    final packets = StreamController<List<int>>.broadcast();
    final ack = ProvisioningAckCoordinator(packets: packets.stream);
    List<int>? retainedCommandBytes;
    final transport = SoftSimProvisioningTransport(
      packets: packets.stream,
      ackCoordinator: ack,
      write: (command) async {
        retainedCommandBytes = command.bytes;
        throw StateError('write failed');
      },
    );
    final softSim = material();

    await expectLater(
      transport.transfer(softSim),
      throwsA(isA<SoftSimTransportUncertainException>()),
    );
    expect(retainedCommandBytes, everyElement(0));

    softSim.dispose();
    await ack.dispose();
    await packets.close();
  });

  test('secret command copies are zeroed when COMMIT ACK times out', () async {
    final packets = StreamController<List<int>>.broadcast();
    final ack = ProvisioningAckCoordinator(
      packets: packets.stream,
      timeout: const Duration(milliseconds: 15),
    );
    final retainedCommandBytes = <List<int>>[];
    final transport = SoftSimProvisioningTransport(
      packets: packets.stream,
      ackCoordinator: ack,
      rejectionObservationInterval: const Duration(milliseconds: 1),
      write: (command) async => retainedCommandBytes.add(command.bytes),
    );
    final softSim = material();

    await expectLater(
      transport.transfer(softSim),
      throwsA(isA<ProvisioningCommandTimeoutException>()),
    );
    expect(
      retainedCommandBytes.every(
        (bytes) => bytes.every((byte) => byte == 0),
      ),
      isTrue,
    );

    softSim.dispose();
    await ack.dispose();
    await packets.close();
  });
}
