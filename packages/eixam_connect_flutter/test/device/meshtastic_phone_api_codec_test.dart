import 'package:eixam_connect_flutter/src/device/meshtastic_phone_api_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = MeshtasticPhoneApiCodec();

  test('encodes the config-only request nonce 69420', () {
    expect(codec.encodeConfigRequest(), <int>[0x18, 0xac, 0x9e, 0x04]);
  });

  test('decodes WISMESH_TAG metadata and firmware version', () {
    final frame = codec.decodeFromRadio(
      _fromRadioMetadata(model: 105, version: '2.5.0'),
    );

    expect(frame.hardwareModel, 105);
    expect(frame.firmwareVersion, '2.5.0');
  });

  test('decodes non-allowlisted hardware models without coercion', () {
    expect(
      codec.decodeFromRadio(_fromRadioMetadata(model: 9)).hardwareModel,
      9,
    );
    expect(
      codec.decodeFromRadio(_fromRadioMetadata(model: 84)).hardwareModel,
      84,
    );
  });

  test('decodes own node number and matching hardware MAC', () {
    final myInfo = _message(3, _varintField(1, 0xa1b2c3d4));
    final user = _message(4, <int>[1, 2, 3, 4, 5, 6]);
    final nodeInfo = _message(4, <int>[
      ..._varintField(1, 0xa1b2c3d4),
      ..._message(2, user),
    ]);

    expect(codec.decodeFromRadio(myInfo).nodeNumber, 0xa1b2c3d4);
    final decodedNode = codec.decodeFromRadio(nodeInfo);
    expect(decodedNode.nodeInfoNumber, 0xa1b2c3d4);
    expect(decodedNode.nodeInfoMac, <int>[1, 2, 3, 4, 5, 6]);
  });

  test('rejects malformed metadata instead of guessing compatibility', () {
    expect(
      () => codec.decodeFromRadio(<int>[0x6a, 0x05, 0x08]),
      throwsFormatException,
    );
  });
}

List<int> _fromRadioMetadata({required int model, String? version}) {
  return _message(13, <int>[
    if (version != null) ..._message(1, version.codeUnits),
    ..._varintField(9, model),
  ]);
}

List<int> _message(int field, List<int> value) => <int>[
  ...(field << 3 | 2) < 128 ? <int>[field << 3 | 2] : _varint(field << 3 | 2),
  ..._varint(value.length),
  ...value,
];

List<int> _varintField(int field, int value) => <int>[
  ..._varint(field << 3),
  ..._varint(value),
];

List<int> _varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    var byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining != 0) byte |= 0x80;
    bytes.add(byte);
  } while (remaining != 0);
  return bytes;
}
