class SdkContactDto {
  const SdkContactDto({
    required this.id,
    required this.name,
    required this.phone,
    required this.email,
    required this.priority,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String phone;
  final String email;
  final int priority;
  final String? createdAt;
  final String? updatedAt;

  factory SdkContactDto.fromJson(Map<String, dynamic> json) {
    return SdkContactDto(
      id: json['id'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String,
      email: json['email'] as String,
      priority: json['priority'] as int,
      createdAt: json['createdAt'] as String?,
      updatedAt: json['updatedAt'] as String?,
    );
  }
}
