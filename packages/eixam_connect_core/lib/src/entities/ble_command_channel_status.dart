enum BleCommandChannelReadiness {
  ready,
  unavailable,
}

/// Public command-channel capability state.
///
/// This intentionally describes capability only; it does not expose the
/// underlying BLE characteristic or protocol literal.
class BleCommandChannelStatus {
  const BleCommandChannelStatus({
    required this.readiness,
    this.hasSelectedDevice = false,
    this.serviceConnected = false,
    this.commandWriterReady = false,
  });

  final BleCommandChannelReadiness readiness;
  final bool hasSelectedDevice;
  final bool serviceConnected;
  final bool commandWriterReady;

  bool get isReady => readiness == BleCommandChannelReadiness.ready;

  static const String capabilityLabel = 'command channel';

  static const BleCommandChannelStatus unavailable = BleCommandChannelStatus(
    readiness: BleCommandChannelReadiness.unavailable,
  );
}
