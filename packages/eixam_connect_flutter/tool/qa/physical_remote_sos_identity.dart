// QA-only identity extraction. Protocol interpretation stays with the existing
// SDK decoder; this tool cannot transmit, trigger or mutate an SOS.
import 'dart:convert';
import 'dart:io';

import '../../lib/src/device/eixam_sos_packet.dart';
import '../../lib/src/device/eixam_ble_protocol.dart';

Map<String, Object> physicalRemoteSosIdentity(Map<String, dynamic> input) {
  final values = input['raw_payload'];
  if (values is! List || values.any((v) => v is! int || v < 0 || v > 255)) {
    throw const FormatException('SDK remote payload must contain bytes');
  }
  final packet = EixamSosPacket.tryParse(values.cast<int>());
  final channel = input['remote_source'] == 'sosNotify'
      ? EixamBleChannel.sos
      : EixamBleChannel.tel;
  if (packet == null || !packet.isActiveOnChannel(channel)) {
    throw const FormatException('SDK payload is not an open remote SOS');
  }
  if (packet.nodeId != input['origin_device'] ||
      packet.nodeId == input['relay_device']) {
    throw const FormatException('SDK remote origin/relay identity mismatch');
  }
  return <String, Object>{
    'origin_device': packet.nodeId,
    'packet_id': packet.packetId,
    'wire_cycle_correlation': '${packet.nodeId}:${packet.packetId}',
    'sos_type': packet.sosType,
    'source': 'existing_sdk_sos_packet_decoder',
  };
}

Future<void> main() async {
  try {
    final input = jsonDecode(await stdin.transform(utf8.decoder).join());
    if (input is! Map<String, dynamic>) {
      throw const FormatException(
        'SDK physical identity input must be an object',
      );
    }
    stdout.writeln(jsonEncode(physicalRemoteSosIdentity(input)));
  } on FormatException catch (error) {
    stderr.writeln('BLOCKED: ${error.message}');
    exitCode = 1;
  }
}
