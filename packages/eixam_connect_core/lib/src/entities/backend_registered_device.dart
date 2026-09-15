class BackendRegisteredDevice {
  const BackendRegisteredDevice({
    required this.id,
    required this.hardwareId,
    required this.firmwareVersion,
    required this.hardwareModel,
    required this.pairedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String hardwareId;
  final String firmwareVersion;
  final String hardwareModel;
  final DateTime pairedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  BackendRegisteredDevice copyWith({
    String? id,
    String? hardwareId,
    String? firmwareVersion,
    String? hardwareModel,
    DateTime? pairedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return BackendRegisteredDevice(
      id: id ?? this.id,
      hardwareId: hardwareId ?? this.hardwareId,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      hardwareModel: hardwareModel ?? this.hardwareModel,
      pairedAt: pairedAt ?? this.pairedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
