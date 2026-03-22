import '../enums/device_sos_state.dart';
import '../enums/device_sos_transition_source.dart';
import '../enums/device_battery_level.dart';

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
  final String? lastPacketSignature;
  final int? nodeId;
  final int? flags;
  final int? sosType;
  final int? retryCount;
  final int? relayCount;
  final int? batteryLevel;
  final DeviceBatteryLevel? batteryState;
  final int? gpsQuality;
  final int? packetId;
  final bool? hasLocation;
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
    this.lastPacketSignature,
    this.nodeId,
    this.flags,
    this.sosType,
    this.retryCount,
    this.relayCount,
    this.batteryLevel,
    this.batteryState,
    this.gpsQuality,
    this.packetId,
    this.hasLocation,
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
    String? lastPacketSignature,
    int? nodeId,
    int? flags,
    int? sosType,
    int? retryCount,
    int? relayCount,
    int? batteryLevel,
    DeviceBatteryLevel? batteryState,
    int? gpsQuality,
    int? packetId,
    bool? hasLocation,
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
      lastPacketSignature: lastPacketSignature ?? this.lastPacketSignature,
      nodeId: nodeId ?? this.nodeId,
      flags: flags ?? this.flags,
      sosType: sosType ?? this.sosType,
      retryCount: retryCount ?? this.retryCount,
      relayCount: relayCount ?? this.relayCount,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      batteryState: batteryState ?? this.batteryState,
      gpsQuality: gpsQuality ?? this.gpsQuality,
      packetId: packetId ?? this.packetId,
      hasLocation: hasLocation ?? this.hasLocation,
      decoderNote: decoderNote ?? this.decoderNote,
    );
  }
}
