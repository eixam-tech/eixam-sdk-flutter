import '../enums/sos_state.dart';
import 'tracking_position.dart';

class SosIncident {
  final String id;
  final SosState state;
  final TrackingPosition? positionSnapshot;
  final DateTime createdAt;
  final String? triggerSource;
  final String? message;

  const SosIncident({
    required this.id,
    required this.state,
    required this.createdAt,
    this.positionSnapshot,
    this.triggerSource,
    this.message,
  });

  SosIncident copyWith({
    SosState? state,
    TrackingPosition? positionSnapshot,
    DateTime? createdAt,
    String? triggerSource,
    String? message,
  }) {
    return SosIncident(
      id: id,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      positionSnapshot: positionSnapshot ?? this.positionSnapshot,
      triggerSource: triggerSource ?? this.triggerSource,
      message: message ?? this.message,
    );
  }
}
