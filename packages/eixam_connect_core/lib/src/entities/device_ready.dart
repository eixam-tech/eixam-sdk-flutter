import 'device_status.dart';

enum DeviceProvisioningPhase {
  idle,
  checkingDevice,
  provisionedAssignmentUnverified,
  firmwareUpdateRequired,
  fetchingConfiguration,
  provisioning,
  applyingRadioConfiguration,
  rebooting,
  reconnecting,
  verifying,
  ready,
  failed,
}

enum DeviceReadyFailureCode {
  notConnected,
  firmwareUpdateRequired,
  configurationUnavailable,
  configurationInvalid,
  backendTimeout,
  deviceCommunicationTimeout,
  deviceCommunicationInterrupted,
  deviceConfigurationRejected,
  rebootFailed,
  reconnectFailed,
  identityMismatch,
  verificationFailed,
  internal,
}

enum DeviceReadyDisposition { ready, provisionedAssignmentUnverified, failed }

class DeviceReadyFailure {
  const DeviceReadyFailure({
    required this.code,
    required this.retryable,
  });

  final DeviceReadyFailureCode code;
  final bool retryable;
}

class DeviceProvisioningState {
  const DeviceProvisioningState({
    required this.phase,
    this.progress,
    this.failure,
  });

  const DeviceProvisioningState.idle()
      : this(phase: DeviceProvisioningPhase.idle);

  final DeviceProvisioningPhase phase;

  /// Monotonic in the inclusive range 0..1 during one operation. It is reset
  /// when the coordinator returns to [DeviceProvisioningPhase.idle].
  final double? progress;
  final DeviceReadyFailure? failure;
}

class DeviceReadyResult {
  const DeviceReadyResult.ready(this.deviceStatus)
      : disposition = DeviceReadyDisposition.ready,
        failure = null;

  const DeviceReadyResult.provisionedAssignmentUnverified(this.deviceStatus)
      : disposition = DeviceReadyDisposition.provisionedAssignmentUnverified,
        failure = null;

  const DeviceReadyResult.failed(this.failure)
      : disposition = DeviceReadyDisposition.failed,
        deviceStatus = null;

  final DeviceReadyDisposition disposition;
  final DeviceStatus? deviceStatus;
  final DeviceReadyFailure? failure;

  bool get isReady => disposition == DeviceReadyDisposition.ready;
}
