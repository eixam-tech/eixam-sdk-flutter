/// DTO representation of an SOS incident returned by the backend layer.
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
      state: json['state'] as String,
      createdAt: json['createdAt'] as String,
      triggerSource: json['triggerSource'] as String? ?? json['trigger_source'] as String?,
      message: json['message'] as String?,
      positionSnapshot: json['positionSnapshot'] as Map<String, dynamic>? ?? json['position_snapshot'] as Map<String, dynamic>?,
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
}
