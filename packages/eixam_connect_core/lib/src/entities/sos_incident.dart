import '../enums/sos_state.dart';
import '../enums/sos_delivery_channel.dart';
import 'sos_actuator_snapshot.dart';
import 'tracking_position.dart';

class SosIncident {

  const SosIncident({
    required this.id,
    required this.state,
    required this.createdAt,
    this.positionSnapshot,
    this.source,
    this.triggerSource,
    this.relaySource,
    this.originatorNodeId,
    this.relayNodeId,
    this.deviceId,
    this.hardwareId,
    this.owner,
    this.cycleKey,
    this.message,
    this.deliveryChannel,
    this.actuators,
  });
  final String id;
  final SosState state;
  final TrackingPosition? positionSnapshot;
  final DateTime createdAt;
  final String? source;
  final String? triggerSource;
  final String? relaySource;
  final int? originatorNodeId;
  final int? relayNodeId;
  final String? deviceId;
  final String? hardwareId;
  final String? owner;
  final String? cycleKey;
  final String? message;
  final SosDeliveryChannel? deliveryChannel;
  final SosActuatorSnapshot? actuators;

  SosIncident copyWith({
    SosState? state,
    TrackingPosition? positionSnapshot,
    DateTime? createdAt,
    String? source,
    String? triggerSource,
    String? relaySource,
    int? originatorNodeId,
    int? relayNodeId,
    String? deviceId,
    String? hardwareId,
    String? owner,
    String? cycleKey,
    String? message,
    Object? deliveryChannel = _unset,
    Object? actuators = _unset,
  }) {
    return SosIncident(
      id: id,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      positionSnapshot: positionSnapshot ?? this.positionSnapshot,
      source: source ?? this.source,
      triggerSource: triggerSource ?? this.triggerSource,
      relaySource: relaySource ?? this.relaySource,
      originatorNodeId: originatorNodeId ?? this.originatorNodeId,
      relayNodeId: relayNodeId ?? this.relayNodeId,
      deviceId: deviceId ?? this.deviceId,
      hardwareId: hardwareId ?? this.hardwareId,
      owner: owner ?? this.owner,
      cycleKey: cycleKey ?? this.cycleKey,
      message: message ?? this.message,
      deliveryChannel: identical(deliveryChannel, _unset)
          ? this.deliveryChannel
          : deliveryChannel as SosDeliveryChannel?,
      actuators: identical(actuators, _unset)
          ? this.actuators
          : actuators as SosActuatorSnapshot?,
    );
  }

  static const Object _unset = Object();
}
