import 'package:eixam_connect_core/eixam_connect_core.dart';

class DeviceViewState {
  const DeviceViewState({
    required this.deviceName,
    required this.statusLabel,
    required this.connectionSummary,
    required this.readinessSummary,
    required this.batterySummary,
    required this.lifecycleLabel,
    required this.pairedLabel,
    required this.connectedLabel,
    required this.activatedLabel,
    required this.readyForSafetyLabel,
    required this.modelLabel,
    required this.aliasLabel,
    required this.signalLabel,
    required this.firmwareLabel,
    required this.lastSeenLabel,
    required this.provisioningErrorLabel,
  });

  factory DeviceViewState.fromStatus(DeviceStatus? status) {
    final batteryState = status?.effectiveBatteryState;

    return DeviceViewState(
      deviceName: status?.deviceAlias ?? status?.model ?? 'EIXAM device',
      statusLabel: _statusLabel(status),
      connectionSummary: _connectionSummary(status),
      readinessSummary: _readinessSummary(status),
      batterySummary: batteryState == null
          ? '-'
          : '${batteryState.label} (~${batteryState.approximatePercentage}% UI est.)',
      lifecycleLabel: status?.lifecycleState.toString() ?? '-',
      pairedLabel: status?.paired.toString() ?? '-',
      connectedLabel: status?.connected.toString() ?? '-',
      activatedLabel: status?.activated.toString() ?? '-',
      readyForSafetyLabel: status?.isReadyForSafety.toString() ?? '-',
      modelLabel: status?.model ?? '-',
      aliasLabel: status?.deviceAlias ?? '-',
      signalLabel: status?.signalQuality?.toString() ?? '-',
      firmwareLabel: status?.firmwareVersion ?? '-',
      lastSeenLabel: _formatDate(status?.lastSeen),
      provisioningErrorLabel: status?.provisioningError ?? '-',
    );
  }

  final String deviceName;
  final String statusLabel;
  final String connectionSummary;
  final String readinessSummary;
  final String batterySummary;
  final String lifecycleLabel;
  final String pairedLabel;
  final String connectedLabel;
  final String activatedLabel;
  final String readyForSafetyLabel;
  final String modelLabel;
  final String aliasLabel;
  final String signalLabel;
  final String firmwareLabel;
  final String lastSeenLabel;
  final String provisioningErrorLabel;

  static String _statusLabel(DeviceStatus? status) {
    if (status == null) return 'Disconnected';
    if (status.isReadyForSafety) return 'Ready';
    if (status.connected) return 'Connected';
    if (status.paired) return 'Paired';
    return 'Disconnected';
  }

  static String _connectionSummary(DeviceStatus? status) {
    if (status == null) return 'Disconnected';
    if (status.connected) return 'Connected';
    if (status.paired) return 'Paired, not connected';
    return 'Not connected';
  }

  static String _readinessSummary(DeviceStatus? status) {
    if (status == null) {
      return 'No active device connection';
    }
    if (status.isReadyForSafety) {
      return 'Connected and ready for safety workflows';
    }
    if (status.connected) {
      return 'Connected, but setup is not complete';
    }
    if (status.paired) {
      return 'Device is paired but currently offline';
    }
    return 'Device is not paired';
  }

  static String _formatDate(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}
