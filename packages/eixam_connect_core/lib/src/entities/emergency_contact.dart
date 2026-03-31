/// Contact used by the SDK for emergency escalation flows.
///
/// The model intentionally stays UI-agnostic so it can be reused by host
/// applications, backend adapters and internal SDK workflows.
class EmergencyContact {
  final String id;
  final String name;
  final String phone;
  final String email;
  final int priority;
  final DateTime createdAt;
  final DateTime updatedAt;

  const EmergencyContact({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    this.priority = 1,
    required this.createdAt,
    required this.updatedAt,
  });

  EmergencyContact copyWith({
    String? id,
    String? name,
    String? phone,
    String? email,
    int? priority,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return EmergencyContact(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      priority: priority ?? this.priority,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
