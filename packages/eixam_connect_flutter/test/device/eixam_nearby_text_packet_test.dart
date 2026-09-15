import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_nearby_text_packet.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> nearbyRxBlob({
  int from = 0x12345678,
  int dest = 0xFFFFFFFF,
  int packetId = 1,
  int groupId = 0,
  int flags = 0,
  List<int> utf8 = const <int>[0x6F, 0x6B],
  int pad = 0,
}) {
  return <int>[
    0xD8,
    from & 0xFF,
    (from >> 8) & 0xFF,
    (from >> 16) & 0xFF,
    (from >> 24) & 0xFF,
    dest & 0xFF,
    (dest >> 8) & 0xFF,
    (dest >> 16) & 0xFF,
    (dest >> 24) & 0xFF,
    packetId & 0xFF,
    (packetId >> 8) & 0xFF,
    (packetId >> 16) & 0xFF,
    (packetId >> 24) & 0xFF,
    groupId & 0xFF,
    (groupId >> 8) & 0xFF,
    (groupId >> 16) & 0xFF,
    (groupId >> 24) & 0xFF,
    (groupId >> 32) & 0xFF,
    (groupId >> 40) & 0xFF,
    (groupId >> 48) & 0xFF,
    (groupId >> 56) & 0xFF,
    flags,
    ...utf8,
    ...List<int>.filled(pad, 0xFF),
  ];
}

void main() {
  test('frames nearby TX as 0x40 fragments of ≤20 bytes', () {
    final utf8Bytes = List<int>.filled(20, 0x61);
    final frames = EixamNearbyTextFramer.txFragments(
      packetId: 0x11223344,
      utf8Bytes: utf8Bytes,
    );

    expect(frames, hasLength(3));
    expect(frames.first.first, 0x40);
    expect(frames.first.length, 20);
    expect(frames.first[1] | (frames.first[2] << 8), 36);
    expect(frames.first[5], 0xFF);
    expect(frames.first[9], 0x44);
  });

  test('frames a PKI DM with dest and 200 B cap header', () {
    final frames = EixamNearbyTextFramer.txFragments(
      packetId: 1,
      utf8Bytes: const <int>[0x68, 0x69],
      destNodeId: 0xA68E6171,
    );
    expect(frames.first[5], 0x71);
    expect(frames.first[6], 0x61);
    expect(frames.first[7], 0x8E);
    expect(frames.first[8], 0xA6);
  });

  test('parses 0xD8 nearby RX with dest and flags', () {
    final packet = EixamNearbyTextPacket.tryParse(
      nearbyRxBlob(flags: 0x01, utf8: const <int>[0x6F, 0x6B]),
    );

    expect(packet?.fromNodeId, 0x12345678);
    expect(packet?.destNodeId, 0xFFFFFFFF);
    expect(packet?.packetId, 1);
    expect(packet?.groupId, 0);
    expect(packet?.pkiEncrypted, isTrue);
    expect(packet?.text, 'ok');
  });

  test('does not parse 12-byte 0xD8 as nearby; that size is SOS/TEL', () {
    expect(
      EixamNearbyTextPacket.tryParse(const <int>[
        0xD8,
        0x12,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0x05,
        0x06,
        0x00,
        0x40,
      ]),
      isNull,
    );
  });

  test('strips 0xFF length pad', () {
    final packet = EixamNearbyTextPacket.tryParse(
      nearbyRxBlob(
        from: 1,
        packetId: 0x11,
        utf8: const <int>[0x68, 0x65, 0x79],
        pad: 2,
      ),
    );

    expect(packet?.text, 'hey');
    expect(packet?.fromNodeId, 1);
    expect(packet?.packetId, 0x11);
  });

  test('frames a group set blob as 0x41 fragments', () {
    final frames = EixamNearbyTextFramer.groupFragments(
      action: 1,
      groupId: 0x11,
      psk: List<int>.filled(32, 0xAB),
    );
    expect(frames.first.first, 0x41);
    expect(frames.first[1] | (frames.first[2] << 8), 41);
    expect(frames.first[5], 1);
    expect(frames.first[6], 0x11);
  });

  test('frames a group replace blob with action 2', () {
    final frames = EixamNearbyTextFramer.groupFragments(
      action: EixamBleProtocol.nearbyTextGroupSetReplace,
      groupId: 0x11,
      psk: List<int>.filled(32, 0xAB),
    );
    expect(frames.first[5], 2);
  });

  test('nearby TX cap is 231 (Data protobuf overhead); RX 233; direct 200', () {
    // Data = portnum(3) + payload tag/len(3) + bitfield(2) + text, plus the
    // 16 B LoRa header must fit 255. PKI adds 12 B on top.
    expect(EixamBleProtocol.nearbyTextPayloadMaxBytes, 231);
    expect(EixamBleProtocol.nearbyTextPayloadMaxBytes + 8 + 16, 255);
    expect(EixamBleProtocol.nearbyTextRxPayloadMaxBytes, 233);
    expect(EixamBleProtocol.nearbyTextDirectPayloadMaxBytes, 200);
    expect(
      EixamBleProtocol.nearbyTextDirectPayloadMaxBytes + 8 + 16 + 12,
      lessThanOrEqualTo(255),
    );
    expect(EixamBleProtocol.nearbyTextMeshPort, 262);
    expect(EixamBleProtocol.nearbyTextRxHeaderLength, 22);
    expect(EixamBleProtocol.nearbyTextTxHeaderLength, 16);
  });

  test('RX still parses a 233 B text from a non-Eixam node', () {
    final text = List<int>.filled(233, 0x61);
    final bytes = <int>[
      EixamBleProtocol.nearbyTextRxOpcode,
      0x01, 0x00, 0x00, 0x00, // from
      0xFF, 0xFF, 0xFF, 0xFF, // dest broadcast
      0x10, 0x00, 0x00, 0x00, // packetId
      0, 0, 0, 0, 0, 0, 0, 0, // groupId
      0x00, // flags
      ...text,
    ];
    final parsed = EixamNearbyTextPacket.tryParse(bytes);
    expect(parsed, isNotNull);
    expect(parsed!.text.length, 233);
  });

  test('frames owner name as 0x42 fragments of ≤20 bytes', () {
    final frames = EixamNearbyTextFramer.ownerNameFragments(
      List<int>.filled(16, 0x61),
    );
    expect(frames, hasLength(2));
    expect(frames.first.first, 0x42);
    expect(frames.first.length, 20);
    expect(frames.first[1] | (frames.first[2] << 8), 16);
  });

  test('parses 0xDB owner name', () {
    final packet = EixamNearbyOwnerNamePacket.tryParse(const <int>[
      0xDB,
      0x78,
      0x56,
      0x34,
      0x12,
      0x41,
      0x6C,
      0x69,
      0x63,
      0x65,
    ]);
    expect(packet?.nodeId, 0x12345678);
    expect(packet?.name, 'Alice');
  });

  test('rejects empty and oversize 0xDB names', () {
    expect(
      EixamNearbyOwnerNamePacket.tryParse(const <int>[0xDB, 1, 0, 0, 0]),
      isNull,
    );
    expect(
      EixamNearbyOwnerNamePacket.tryParse(<int>[
        0xDB,
        1,
        0,
        0,
        0,
        ...List<int>.filled(40, 0x61),
      ]),
      isNull,
    );
  });
}
