/// Contact used by the SDK for emergency escalation flows.
///
/// The model intentionally stays UI-agnostic so it can be reused by host
/// applications, backend adapters and internal SDK workflows.
class EmergencyContact {

  const EmergencyContact({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    this.priority = 1,
    this.language = 'en',
    required this.createdAt,
    required this.updatedAt,
  });
  final String id;
  final String name;
  final String phone;
  final String email;
  final int priority;

  /// ISO 639-1 language code for cascade notifications (default `en`).
  final String language;
  final DateTime createdAt;
  final DateTime updatedAt;

  EmergencyContact copyWith({
    String? id,
    String? name,
    String? phone,
    String? email,
    int? priority,
    String? language,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return EmergencyContact(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      priority: priority ?? this.priority,
      language: language ?? this.language,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
