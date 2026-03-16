import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/dtos/sos_incident_dto.dart';
import 'local_state_serializers.dart';

/// Maps SOS DTOs from the data layer into domain entities used by the SDK.
class SosIncidentMapper {
  const SosIncidentMapper();

  SosIncident toDomain(SosIncidentDto dto) {
    return SosIncident(
      id: dto.id,
      state: SosState.values.firstWhere(
        (value) => value.name == dto.state,
        orElse: () => SosState.failed,
      ),
      createdAt: DateTime.parse(dto.createdAt),
      triggerSource: dto.triggerSource,
      message: dto.message,
      positionSnapshot: dto.positionSnapshot == null
          ? null
          : LocalStateSerializers.trackingPositionFromJson(dto.positionSnapshot!),
    );
  }
}
