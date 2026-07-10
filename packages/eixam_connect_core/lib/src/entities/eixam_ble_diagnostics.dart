import 'ble_command_channel_status.dart';

/// Public BLE readiness diagnostics for host-app UI and retry gates.
///
/// Values are coarse and protocol-neutral: no service UUIDs, characteristic
/// names, packet payloads, or device identifiers are exposed here.
class EixamBleDiagnostics {
  const EixamBleDiagnostics({
    required this.adapterState,
    required this.isScanning,
    required this.hasSelectedDevice,
    required this.eixamServiceDetected,
    required this.commandChannelStatus,
  });

  final String adapterState;
  final bool isScanning;
  final bool hasSelectedDevice;
  final bool eixamServiceDetected;
  final BleCommandChannelStatus commandChannelStatus;
}
