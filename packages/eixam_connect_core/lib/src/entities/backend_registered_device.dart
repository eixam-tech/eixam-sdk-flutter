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
}
