//// DTO representation of an SOS incident returned by the backend layer.
import 'package:eixam_connect_core/eixam_connect_core.dart';

class SosIncidentDto {
  final String id;
  final String state;
  final String createdAt;
  final String? triggerSource;
  final String? message;
  final Map<String, dynamic>? positionSnapshot;

  const SosIncidentDto({
    required this.id,
    required this.state,
    required this.createdAt,
    this.triggerSource,
    this.message,
    this.positionSnapshot,
  });

  factory SosIncidentDto.fromJson(Map<String, dynamic> json) {
    return SosIncidentDto(
      id: json['id'] as String,
      state:
          (json['state'] as String?) ?? (json['status'] as String?) ?? 'failed',
      createdAt: (json['createdAt'] as String?) ??
          (json['created_at'] as String?) ??
          (json['occurredAt'] as String?) ??
          (json['timestamp'] as String?) ??
          DateTime.now().toIso8601String(),
      triggerSource:
          json['triggerSource'] as String? ?? json['trigger_source'] as String?,
      message: json['message'] as String?,
      positionSnapshot: _positionSnapshotFromJson(json),
    );
  }

  SosIncidentDto copyWith({
    String? id,
    String? state,
    String? createdAt,
    String? triggerSource,
    String? message,
    Map<String, dynamic>? positionSnapshot,
  }) {
    return SosIncidentDto(
      id: id ?? this.id,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      triggerSource: triggerSource ?? this.triggerSource,
      message: message ?? this.message,
      positionSnapshot: positionSnapshot ?? this.positionSnapshot,
    );
  }

  static Map<String, dynamic>? _positionSnapshotFromJson(
    Map<String, dynamic> json,
  ) {
    final existing = json['positionSnapshot'] as Map<String, dynamic>? ??
        json['position_snapshot'] as Map<String, dynamic>?;
    if (existing != null) return existing;

    final latitude = json['latitude'];
    final longitude = json['longitude'];
    if (latitude is! num || longitude is! num) {
      return null;
    }

    return <String, dynamic>{
      'latitude': latitude.toDouble(),
      'longitude': longitude.toDouble(),
      if (json['altitude'] is num)
        'altitude': (json['altitude'] as num).toDouble(),
      'source': DeliveryMode.mobile.name,
      'timestamp': (json['timestamp'] as String?) ??
          (json['occurredAt'] as String?) ??
          (json['createdAt'] as String?) ??
          DateTime.now().toIso8601String(),
    };
  }
}
