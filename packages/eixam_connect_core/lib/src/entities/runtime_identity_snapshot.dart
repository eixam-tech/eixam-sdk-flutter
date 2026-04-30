enum RuntimeIdentityReadinessReason {
  ready,
  noConnectedDevice,
  commandPathNotReady,
  connectedIdentityUnknown,
}

extension RuntimeIdentityReadinessReasonDiagnostics
    on RuntimeIdentityReadinessReason {
  String get diagnosticName {
    switch (this) {
      case RuntimeIdentityReadinessReason.ready:
        return 'ready';
      case RuntimeIdentityReadinessReason.noConnectedDevice:
        return 'no_connected_device';
      case RuntimeIdentityReadinessReason.commandPathNotReady:
        return 'command_path_not_ready';
      case RuntimeIdentityReadinessReason.connectedIdentityUnknown:
        return 'connected_identity_unknown';
    }
  }
}

class RuntimeIdentitySnapshot {
  const RuntimeIdentitySnapshot({
    required this.connectedBleNodeId,
    required this.deviceId,
    required this.serviceBleConnected,
    required this.commandCapable,
    required this.readinessReason,
    this.lastUpdatedAt,
  });

  final int? connectedBleNodeId;
  final String? deviceId;
  final bool serviceBleConnected;
  final bool commandCapable;
  final RuntimeIdentityReadinessReason readinessReason;
  final DateTime? lastUpdatedAt;

  bool get hasKnownConnectedBleIdentity =>
      serviceBleConnected && connectedBleNodeId != null;
}
