class PreferredBleDevice {
  const PreferredBleDevice({
    required this.deviceId,
    this.displayName,
    required this.lastConnectedAt,
  });

  final String deviceId;
  final String? displayName;
  final DateTime lastConnectedAt;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'deviceId': deviceId,
      'displayName': displayName,
      'lastConnectedAt': lastConnectedAt.toIso8601String(),
    };
  }

  static PreferredBleDevice? fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return null;
    }

    final deviceId = json['deviceId'] as String?;
    final lastConnectedAtRaw = json['lastConnectedAt'] as String?;
    if (deviceId == null ||
        deviceId.trim().isEmpty ||
        lastConnectedAtRaw == null) {
      return null;
    }

    final lastConnectedAt = DateTime.tryParse(lastConnectedAtRaw);
    if (lastConnectedAt == null) {
      return null;
    }

    return PreferredBleDevice(
      deviceId: deviceId,
      displayName: json['displayName'] as String?,
      lastConnectedAt: lastConnectedAt,
    );
  }
}
