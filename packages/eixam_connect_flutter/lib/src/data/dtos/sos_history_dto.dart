import 'sos_incident_dto.dart';

/// DTO for one SOS history item from the backend.
class SosHistoryItemDto {
  const SosHistoryItemDto({
    required this.incident,
    this.creationTelemetry,
    this.trail = const [],
  });

  final SosIncidentDto incident;
  final SosHistoryTelemetryDto? creationTelemetry;
  final List<SosHistoryTrailPointDto> trail;

  factory SosHistoryItemDto.fromJson(Map<String, dynamic> json) {
    final incidentJson = json['incident'] as Map<String, dynamic>? ?? json;
    return SosHistoryItemDto(
      incident: SosIncidentDto.fromJson(incidentJson),
      creationTelemetry: json['creationTelemetry'] != null
          ? SosHistoryTelemetryDto.fromJson(
              json['creationTelemetry'] as Map<String, dynamic>)
          : null,
      trail: (json['trail'] as List<dynamic>?)
              ?.map((e) => SosHistoryTrailPointDto.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
    );
  }
}

/// DTO for creation telemetry inline in a history item.
class SosHistoryTelemetryDto {
  const SosHistoryTelemetryDto({
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
  final String occurredAt;
  final double? latitude;
  final double? longitude;
  final double? altitude;
  final int? deviceBattery;
  final int? deviceCoverage;
  final int? mobileBattery;
  final int? mobileCoverage;

  factory SosHistoryTelemetryDto.fromJson(Map<String, dynamic> json) {
    return SosHistoryTelemetryDto(
      id: json['id'] as String,
      occurredAt: (json['occurredAt'] as String?) ??
          (json['occurred_at'] as String?) ??
          DateTime.now().toIso8601String(),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      deviceBattery: (json['deviceBattery']?['rawValue'] as num?)?.round() ??
          (json['device_battery'] as num?)?.round(),
      deviceCoverage: (json['deviceCoverage']?['signalStrength'] as num?)?.round() ??
          (json['device_coverage'] as num?)?.round(),
      mobileBattery: (json['mobileBattery'] as num?)?.round(),
      mobileCoverage: (json['mobileCoverage']?['signalStrength'] as num?)?.round() ??
          (json['mobile_coverage'] as num?)?.round(),
    );
  }
}

/// DTO for one trail point in a history item.
class SosHistoryTrailPointDto {
  const SosHistoryTrailPointDto({
    required this.occurredAt,
    required this.latitude,
    required this.longitude,
    this.altitude,
  });

  final String occurredAt;
  final double latitude;
  final double longitude;
  final double? altitude;

  factory SosHistoryTrailPointDto.fromJson(Map<String, dynamic> json) {
    return SosHistoryTrailPointDto(
      occurredAt: (json['occurredAt'] as String?) ??
          (json['occurred_at'] as String?) ??
          DateTime.now().toIso8601String(),
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
    );
  }
}

/// DTO for the paginated history response.
class SosHistoryPageDto {
  const SosHistoryPageDto({
    required this.items,
    this.nextCursor,
    required this.hasMore,
  });

  final List<SosHistoryItemDto> items;
  final String? nextCursor;
  final bool hasMore;

  factory SosHistoryPageDto.fromJson(Map<String, dynamic> json) {
    final incidents = (json['incidents'] as List<dynamic>?)
            ?.map((e) => SosHistoryItemDto.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [];
    final pagination = json['pagination'] as Map<String, dynamic>?;
    return SosHistoryPageDto(
      items: incidents,
      nextCursor: pagination?['next_cursor'] as String?,
      hasMore: pagination?['has_more'] as bool? ?? false,
    );
  }
}
