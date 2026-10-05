/// Internal transport facts. Canonical hardware identity is never a BLE handle.
class BleTransportObservation {
  const BleTransportObservation({
    required this.transportId,
    required this.connected,
    required this.servicePresent,
    required this.commandCharacteristicPresent,
    this.shortCommandCharacteristicPresent = false,
    this.canonicalHardwareId,
    this.nodeId,
    this.writerAttached = false,
    this.nativeOwned = false,
    this.targetIdentityMatched = false,
    this.queueHealthy = true,
  });

  final String? transportId;
  final bool connected;
  final bool servicePresent;
  final bool commandCharacteristicPresent;
  final bool shortCommandCharacteristicPresent;
  final String? canonicalHardwareId;
  final int? nodeId;
  final bool writerAttached;
  final bool nativeOwned;
  final bool targetIdentityMatched;
  final bool queueHealthy;
}

/// Optional internal adapter contract; no new host API or lifecycle coordinator.
abstract interface class BleTransportObservationSource {
  BleTransportObservation transportObservation(String deviceId);
  Stream<String> get serviceResets;
}
