import 'package:eixam_connect_core/eixam_connect_core.dart';

class DeviceSosPacket {
  const DeviceSosPacket({
    required this.rawBytes,
    required this.rawHex,
    required this.nodeId,
    required this.flags,
    required this.counter,
    required this.marker,
    required this.statusByte,
    required this.derivedState,
    required this.decoderNote,
  });

  final List<int> rawBytes;
  final String rawHex;
  final int nodeId;
  final int flags;
  final int counter;
  final int marker;
  final int statusByte;
  final DeviceSosState derivedState;
  final String decoderNote;

  static DeviceSosPacket? tryParse(
    List<int> packet, {
    required DeviceSosState previousState,
  }) {
    if (packet.length != 10) {
      return null;
    }

    final nodeId =
        packet[0] |
        (packet[1] << 8) |
        (packet[2] << 16) |
        (packet[3] << 24);
    final flags = packet[4];
    final counter = packet[5] | (packet[6] << 8) | (packet[7] << 16);
    final marker = packet[8];
    final statusByte = packet[9];
    final rawHex = _hex(packet);

    final derivation = _deriveState(
      statusByte: statusByte,
      flags: flags,
      marker: marker,
      previousState: previousState,
    );

    return DeviceSosPacket(
      rawBytes: List<int>.unmodifiable(packet),
      rawHex: rawHex,
      nodeId: nodeId,
      flags: flags,
      counter: counter,
      marker: marker,
      statusByte: statusByte,
      derivedState: derivation.state,
      decoderNote: derivation.note,
    );
  }

  static ({DeviceSosState state, String note}) _deriveState({
    required int statusByte,
    required int flags,
    required int marker,
    required DeviceSosState previousState,
  }) {
    const knownStates = <int, DeviceSosState>{
      0x02: DeviceSosState.inactive,
      0x12: DeviceSosState.resolved,
      0x32: DeviceSosState.preConfirm,
      0x42: DeviceSosState.active,
      0x52: DeviceSosState.acknowledged,
      0x62: DeviceSosState.resolved,
    };

    final exact = knownStates[statusByte];
    if (exact != null) {
      return (
        state: exact,
        note:
            'Derived from exact status byte 0x${statusByte.toRadixString(16).padLeft(2, '0')}. '
            '0x42 and 0x52 are confirmed from current device captures; the other mappings are best-effort protocol placeholders.',
      );
    }

    final stateNibble = (statusByte >> 4) & 0x0F;
    switch (stateNibble) {
      case 0x0:
        return (
          state: DeviceSosState.inactive,
          note: 'Derived from status high nibble 0x0 as inactive.',
        );
      case 0x1:
        return (
          state: DeviceSosState.resolved,
          note: 'Derived from status high nibble 0x1 as resolved/inactive terminal state.',
        );
      case 0x3:
        return (
          state: DeviceSosState.preConfirm,
          note: 'Derived from status high nibble 0x3 as pre-confirm countdown.',
        );
      case 0x4:
        return (
          state: DeviceSosState.active,
          note: 'Derived from status high nibble 0x4 as active SOS.',
        );
      case 0x5:
        return (
          state: DeviceSosState.acknowledged,
          note: 'Derived from status high nibble 0x5 as acknowledged SOS.',
        );
      case 0x6:
        return (
          state: DeviceSosState.resolved,
          note: 'Derived from status high nibble 0x6 as resolved SOS.',
        );
    }

    if ((flags & 0x08) != 0 || marker == 0x80) {
      return (
        state: previousState == DeviceSosState.inactive
            ? DeviceSosState.active
            : previousState,
        note:
            'Fallback derivation: packet matches the observed SOS notify shape '
            '(flags 0x${flags.toRadixString(16).padLeft(2, '0')}, marker 0x${marker.toRadixString(16).padLeft(2, '0')}) '
            'but status byte 0x${statusByte.toRadixString(16).padLeft(2, '0')} is not mapped yet.',
      );
    }

    return (
      state: DeviceSosState.unknown,
      note:
          'Unable to infer SOS state from status byte 0x${statusByte.toRadixString(16).padLeft(2, '0')}.',
    );
  }

  static String _hex(List<int> data) {
    return data
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(' ');
  }
}
