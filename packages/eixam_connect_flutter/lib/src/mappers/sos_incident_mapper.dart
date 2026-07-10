import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/dtos/sos_incident_dto.dart';
import '../sdk/sos_origin_classifier.dart';
import 'local_state_serializers.dart';

/// Maps SOS DTOs from the data layer into domain entities used by the SDK.
class SosIncidentMapper {
  const SosIncidentMapper();

  SosIncident toDomain(SosIncidentDto dto) {
    final originDecision = classifySosOrigin(
      source: dto.source,
      triggerSource: dto.triggerSource,
      relaySource: dto.relaySource,
      owner: dto.owner,
      originatorNodeId: dto.originatorNodeId,
      relayNodeId: dto.relayNodeId,
      deviceId: dto.deviceId,
      hardwareId: dto.hardwareId,
    );
    return SosIncident(
      id: dto.id,
      state: _mapState(dto.state),
      createdAt: DateTime.parse(dto.createdAt),
      source: dto.source,
      triggerSource: dto.triggerSource,
      relaySource: dto.relaySource,
      originatorNodeId: dto.originatorNodeId,
      relayNodeId: dto.relayNodeId,
      deviceId: dto.deviceId,
      hardwareId: dto.hardwareId,
      owner: dto.owner,
      cycleKey: dto.cycleKey,
      message: dto.message,
      originKind:
          _originKindFromRaw(dto.originKind) ?? originDecision.originKind,
      actionability: _actionabilityFromRaw(dto.actionability) ??
          originDecision.actionability,
      displaySurface: _displaySurfaceFromRaw(dto.displaySurface) ??
          originDecision.displaySurface,
      actuators: dto.actuators,
      positionSnapshot: dto.positionSnapshot == null
          ? null
          : LocalStateSerializers.trackingPositionFromJson(
              dto.positionSnapshot!),
    );
  }

  SosOriginKind? _originKindFromRaw(String? value) {
    final normalized = _normalizeEnumName(value);
    if (normalized == null) {
      return null;
    }
    return SosOriginKind.values.firstWhere(
      (candidate) => candidate.name.toLowerCase() == normalized,
      orElse: () => SosOriginKind.unknown,
    );
  }

  SosActionability? _actionabilityFromRaw(String? value) {
    final normalized = _normalizeEnumName(value);
    if (normalized == null) {
      return null;
    }
    return SosActionability.values.firstWhere(
      (candidate) => candidate.name.toLowerCase() == normalized,
      orElse: () => SosActionability.unknown,
    );
  }

  SosDisplaySurface? _displaySurfaceFromRaw(String? value) {
    final normalized = _normalizeEnumName(value);
    if (normalized == null) {
      return null;
    }
    return SosDisplaySurface.values.firstWhere(
      (candidate) => candidate.name.toLowerCase() == normalized,
      orElse: () => SosDisplaySurface.unknown,
    );
  }

  String? _normalizeEnumName(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed.replaceAll('-', '').replaceAll('_', '').toLowerCase();
  }

  SosState _mapState(String value) {
    return switch (value) {
      'active' => SosState.sent,
      'acknowledged' => SosState.acknowledged,
      'cancelled' => SosState.cancelled,
      'resolved' => SosState.resolved,
      _ => SosState.values.firstWhere(
          (candidate) => candidate.name == value,
          orElse: () => SosState.failed,
        ),
    };
  }
}
