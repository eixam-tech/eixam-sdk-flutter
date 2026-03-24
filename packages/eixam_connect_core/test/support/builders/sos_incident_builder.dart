import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'tracking_position_builder.dart';

SosIncident buildSosIncident({
  String id = 'sos-1',
  SosState state = SosState.sent,
  DateTime? createdAt,
  TrackingPosition? positionSnapshot,
  String? triggerSource = 'button_ui',
  String? message = 'Need help',
}) {
  return SosIncident(
    id: id,
    state: state,
    createdAt: createdAt ?? DateTime.utc(2026, 1, 1, 12),
    positionSnapshot: positionSnapshot ?? buildTrackingPosition(),
    triggerSource: triggerSource,
    message: message,
  );
}
