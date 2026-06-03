import '../enums/sos_delivery_channel.dart';
import '../enums/sos_state.dart';
import 'sos_actuator_snapshot.dart';
import 'tracking_position.dart';

/// Telemetry snapshot attached to an SOS history item.
class SosHistoryTelemetry {
  const SosHistoryTelemetry({
    required this.id,
    required this.occurredAt,
    this.latitude,
    this.longitude,
    this.altitude,
    this.deviceBattery,
    this.deviceCoverage,
    this.mobileBattery,
    this.mobileCoverage,
  });

  final String id;
  final DateTime occurredAt;
  final double? latitude;
  final double? longitude;
  final double? altitude;
  final int? deviceBattery;
  final int? deviceCoverage;
  final int? mobileBattery;
  final int? mobileCoverage;
}

/// One SOS incident in the paginated history list.
/// Includes the creation telemetry and a downsampled positional trail.
class SosHistoryItem {
  const SosHistoryItem({
    required this.id,
    required this.state,
    required this.createdAt,
    this.positionSnapshot,
    this.triggerSource,
    this.message,
    this.deliveryChannel,
    this.actuators,
    this.creationTelemetry,
    this.trail = const [],
  });

  final String id;
  final SosState state;
  final DateTime createdAt;
  final TrackingPosition? positionSnapshot;
  final String? triggerSource;
  final String? message;
  final SosDeliveryChannel? deliveryChannel;
  final SosActuatorSnapshot? actuators;
  final SosHistoryTelemetry? creationTelemetry;
  final List<TrackingPosition> trail;
}

/// Paginated response from [SosRepository.listSosHistory].
class SosHistoryPage {
  const SosHistoryPage({
    required this.items,
    this.nextCursor,
    required this.hasMore,
  });

  final List<SosHistoryItem> items;
  final String? nextCursor;
  final bool hasMore;
}
