import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Whether the foreground battery probe (`0x23`) must stay silent because
/// another flow owns the TAG link. SOS, firmware update, provisioning and
/// device migration are never given extra traffic.
abstract final class TagBatteryProbeGate {
  static bool isBlocked({
    required bool provisioningBusy,
    required bool firmwareUpdateActive,
    required bool migrationOwnsBle,
    required bool preSosActive,
    required SosLifecycleStage sosStage,
    required DeviceSosState deviceSosState,
  }) {
    if (provisioningBusy || firmwareUpdateActive || migrationOwnsBle) {
      return true;
    }
    return isSosActive(
      preSosActive: preSosActive,
      sosStage: sosStage,
      deviceSosState: deviceSosState,
    );
  }

  /// Whether an SOS (pre-SOS, app lifecycle or TAG state) is in progress or
  /// cannot be ruled out. An unknown device SOS state fails safe.
  static bool isSosActive({
    required bool preSosActive,
    required SosLifecycleStage sosStage,
    required DeviceSosState deviceSosState,
  }) {
    if (preSosActive) return true;
    switch (sosStage) {
      case SosLifecycleStage.idle:
      case SosLifecycleStage.cancelled:
      case SosLifecycleStage.resolved:
      case SosLifecycleStage.activationFailed:
      case SosLifecycleStage.cancellationFailed:
        break;
      case SosLifecycleStage.arming:
      case SosLifecycleStage.activating:
      case SosLifecycleStage.active:
      case SosLifecycleStage.cancelling:
      case SosLifecycleStage.recoveryRequired:
        return true;
    }
    switch (deviceSosState) {
      case DeviceSosState.inactive:
      case DeviceSosState.resolved:
        return false;
      case DeviceSosState.preConfirm:
      case DeviceSosState.active:
      case DeviceSosState.acknowledged:
      case DeviceSosState.unknown:
        return true;
    }
  }
}
