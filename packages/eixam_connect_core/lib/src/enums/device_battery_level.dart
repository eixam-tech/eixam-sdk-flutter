enum DeviceBatteryLevel {
  critical(protocolValue: 0, label: 'Critical', approximatePercentage: 10),
  low(protocolValue: 1, label: 'Low', approximatePercentage: 35),
  medium(protocolValue: 2, label: 'Medium', approximatePercentage: 65),
  ok(protocolValue: 3, label: 'OK', approximatePercentage: 90);

  const DeviceBatteryLevel({
    required this.protocolValue,
    required this.label,
    required this.approximatePercentage,
  });

  final int protocolValue;
  final String label;

  /// UI-only approximation derived from the 2-bit EIXAM battery protocol.
  final int approximatePercentage;

  static DeviceBatteryLevel? fromProtocolValue(int? value) {
    if (value == null) {
      return null;
    }

    for (final level in DeviceBatteryLevel.values) {
      if (level.protocolValue == value) {
        return level;
      }
    }
    return null;
  }
}
