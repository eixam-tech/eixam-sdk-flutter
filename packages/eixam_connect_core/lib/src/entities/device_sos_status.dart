import '../enums/device_sos_state.dart';
import '../enums/device_sos_transition_source.dart';

class DeviceSosStatus {
  final DeviceSosState state;
  final DeviceSosState? previousState;
  final DeviceSosTransitionSource transitionSource;
  final String lastEvent;
  final DateTime updatedAt;
  final bool optimistic;
  final bool derivedFromBlePacket;
  final int? lastOpcode;
  final String? lastPacketHex;
  final int? lastPacketLength;
  final DateTime? lastPacketAt;
  final int? nodeId;
  final int? flags;
  final int? marker;
  final int? statusByte;
  final String? decoderNote;

  const DeviceSosStatus({
    required this.state,
    this.previousState,
    this.transitionSource = DeviceSosTransitionSource.unknown,
    required this.lastEvent,
    required this.updatedAt,
    this.optimistic = false,
    this.derivedFromBlePacket = false,
    this.lastOpcode,
    this.lastPacketHex,
    this.lastPacketLength,
    this.lastPacketAt,
    this.nodeId,
    this.flags,
    this.marker,
    this.statusByte,
    this.decoderNote,
  });

  factory DeviceSosStatus.initial() {
    return DeviceSosStatus(
      state: DeviceSosState.inactive,
      previousState: null,
      transitionSource: DeviceSosTransitionSource.unknown,
      lastEvent: 'Device SOS inactive',
      updatedAt: DateTime.now(),
    );
  }

  DeviceSosStatus copyWith({
    DeviceSosState? state,
    DeviceSosState? previousState,
    DeviceSosTransitionSource? transitionSource,
    String? lastEvent,
    DateTime? updatedAt,
    bool? optimistic,
    bool? derivedFromBlePacket,
    int? lastOpcode,
    String? lastPacketHex,
    int? lastPacketLength,
    DateTime? lastPacketAt,
    int? nodeId,
    int? flags,
    int? marker,
    int? statusByte,
    String? decoderNote,
  }) {
    return DeviceSosStatus(
      state: state ?? this.state,
      previousState: previousState ?? this.previousState,
      transitionSource: transitionSource ?? this.transitionSource,
      lastEvent: lastEvent ?? this.lastEvent,
      updatedAt: updatedAt ?? this.updatedAt,
      optimistic: optimistic ?? this.optimistic,
      derivedFromBlePacket: derivedFromBlePacket ?? this.derivedFromBlePacket,
      lastOpcode: lastOpcode ?? this.lastOpcode,
      lastPacketHex: lastPacketHex ?? this.lastPacketHex,
      lastPacketLength: lastPacketLength ?? this.lastPacketLength,
      lastPacketAt: lastPacketAt ?? this.lastPacketAt,
      nodeId: nodeId ?? this.nodeId,
      flags: flags ?? this.flags,
      marker: marker ?? this.marker,
      statusByte: statusByte ?? this.statusByte,
      decoderNote: decoderNote ?? this.decoderNote,
    );
  }
}
