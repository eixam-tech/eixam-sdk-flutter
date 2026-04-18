class DeviceRuntimeStatus {
  const DeviceRuntimeStatus({
    required this.region,
    required this.modemPreset,
    required this.meshSpreadingFactor,
    required this.isProvisioned,
    required this.usePreset,
    required this.txEnabled,
    required this.inetOk,
    required this.positionConfirmed,
    required this.nodeId,
    required this.batteryPercent,
    required this.telIntervalSeconds,
    this.receivedAt,
    this.rawBytes = const <int>[],
  });

  final int region;
  final int modemPreset;
  final int meshSpreadingFactor;
  final bool isProvisioned;
  final bool usePreset;
  final bool txEnabled;
  final bool inetOk;
  final bool positionConfirmed;
  final int nodeId;
  final int batteryPercent;
  final int telIntervalSeconds;
  final DateTime? receivedAt;
  final List<int> rawBytes;
}
