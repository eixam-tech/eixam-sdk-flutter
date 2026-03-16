/// Contact used by the SDK for emergency escalation flows.
///
/// The model intentionally stays UI-agnostic so it can be reused by host
/// applications, backend adapters and internal SDK workflows.
class EmergencyContact {
  final String id;
  final String name;
  final String? phone;
  final String? email;
  final int priority;
  final bool active;

  const EmergencyContact({
    required this.id,
    required this.name,
    this.phone,
    this.email,
    this.priority = 1,
    this.active = true,
  });

  EmergencyContact copyWith({
    String? id,
    String? name,
    String? phone,
    String? email,
    int? priority,
    bool? active,
  }) {
    return EmergencyContact(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      priority: priority ?? this.priority,
      active: active ?? this.active,
    );
  }
}
