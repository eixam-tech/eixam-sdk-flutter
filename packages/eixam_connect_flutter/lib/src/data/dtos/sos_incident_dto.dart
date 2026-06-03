/// DTO representation of an SOS incident returned by the backend layer.
import 'package:eixam_connect_core/eixam_connect_core.dart';

class SosIncidentDto {
  final String id;
  final String state;
  final String createdAt;
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
  final Map<String, dynamic>? positionSnapshot;
  final SosActuatorSnapshot? actuators;
  final int? statusCode;

  /// References the telemetry row inserted when this incident was first opened.
  final String? creationTelemetryId;

  const SosIncidentDto({
    required this.id,
    required this.state,
    required this.createdAt,
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
    this.positionSnapshot,
    this.actuators,
    this.statusCode,
    this.creationTelemetryId,
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
      source: _stringFromJson(json, const ['source']),
      triggerSource:
          _stringFromJson(json, const ['triggerSource', 'trigger_source']),
      relaySource: _stringFromJson(json, const ['relaySource', 'relay_source']),
      originatorNodeId: _intFromJson(
        json,
        const ['originatorNodeId', 'originator_node_id'],
      ),
      relayNodeId: _intFromJson(json, const ['relayNodeId', 'relay_node_id']),
      deviceId: _stringFromJson(json, const ['deviceId', 'device_id']),
      hardwareId: _stringFromJson(json, const ['hardwareId', 'hardware_id']),
      owner: _stringFromJson(json, const ['owner']),
      cycleKey: _stringFromJson(json, const ['cycleKey', 'cycle_key']),
      message: json['message'] as String?,
      positionSnapshot: _positionSnapshotFromJson(json),
      actuators: _actuatorsFromJson(json['actuators']),
      creationTelemetryId: json['creationTelemetryId'] as String? ??
          json['creation_telemetry_id'] as String?,
    );
  }

  SosIncidentDto copyWith({
    String? id,
    String? state,
    String? createdAt,
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
    Map<String, dynamic>? positionSnapshot,
    Object? actuators = _unset,
    int? statusCode,
    String? creationTelemetryId,
  }) {
    return SosIncidentDto(
      id: id ?? this.id,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
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
      positionSnapshot: positionSnapshot ?? this.positionSnapshot,
      actuators: identical(actuators, _unset)
          ? this.actuators
          : actuators as SosActuatorSnapshot?,
      statusCode: statusCode ?? this.statusCode,
      creationTelemetryId: creationTelemetryId ?? this.creationTelemetryId,
    );
  }

  static const Object _unset = Object();

  static String? _stringFromJson(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = json[key];
      if (value == null) {
        continue;
      }
      final normalized = value.toString().trim();
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return null;
  }

  static int? _intFromJson(Map<String, dynamic> json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) {
          return parsed;
        }
      }
    }
    return null;
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

  static SosActuatorSnapshot? _actuatorsFromJson(Object? value) {
    if (value is Map<String, dynamic>) {
      return SosActuatorSnapshot.fromJson(value);
    }
    if (value is Map) {
      return SosActuatorSnapshot.fromJson(Map<String, dynamic>.from(value));
    }
    return null;
  }
}
