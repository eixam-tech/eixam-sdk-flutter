import 'device_status.dart';

enum DeviceUnprovisionDisposition {
  unprovisioned,
  alreadyUnprovisioned,
  failed,
}

enum DeviceUnprovisionFailureCode {
  notConnected,
  busy,
  safetyActive,
  firmwareUpdateRequired,
  deviceCommunicationTimeout,
  deviceCommunicationInterrupted,
  deviceConfigurationRejected,
  rebootFailed,
  reconnectFailed,
  identityMismatch,
  verificationFailed,
  internal,
}

class DeviceUnprovisionFailure {
  const DeviceUnprovisionFailure({
    required this.code,
    required this.retryable,
  });

  final DeviceUnprovisionFailureCode code;
  final bool retryable;
}

class DeviceUnprovisionResult {
  const DeviceUnprovisionResult.unprovisioned(this.deviceStatus)
      : disposition = DeviceUnprovisionDisposition.unprovisioned,
        failure = null;

  const DeviceUnprovisionResult.alreadyUnprovisioned(this.deviceStatus)
      : disposition = DeviceUnprovisionDisposition.alreadyUnprovisioned,
        failure = null;

  const DeviceUnprovisionResult.failed(this.failure)
      : disposition = DeviceUnprovisionDisposition.failed,
        deviceStatus = null;

  final DeviceUnprovisionDisposition disposition;
  final DeviceStatus? deviceStatus;
  final DeviceUnprovisionFailure? failure;

  bool get succeeded =>
      disposition == DeviceUnprovisionDisposition.unprovisioned ||
      disposition == DeviceUnprovisionDisposition.alreadyUnprovisioned;
}
