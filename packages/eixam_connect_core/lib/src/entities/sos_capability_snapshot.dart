/// Existing SOS paths that the SDK can observe or select.
enum SosActivationPath {
  appBackend,
  connectedDevice,
  physicalDevice,
  restoredActiveLifecycle,
}

/// Typed reason why a new SOS cannot currently be activated.
enum SosCapabilityBlockingReason {
  initializing,
  authenticationRequired,
  lifecycleDoesNotAllowActivation,
  appTransportUnavailable,
  noActivationPath,
}

/// Non-blocking loss of redundancy or emergency context.
enum SosCapabilityDegradedReason {
  deviceNotRegistered,
  deviceDisconnected,
  commandChannelUnavailable,
  locationUnavailable,
}

/// SDK-owned SOS readiness, independent from the active SOS lifecycle.
final class SosCapabilitySnapshot {
  const SosCapabilitySnapshot({
    required this.canTriggerAppSos,
    required this.canTriggerDeviceSos,
    required this.canCancelCurrentSos,
    required this.appTransportReady,
    required this.deviceTransportReady,
    required this.hasAuthenticatedSession,
    required this.hasRegisteredDevice,
    required this.hasConnectedDevice,
    required this.commandChannelReady,
    required this.locationAvailable,
    required this.lifecycleAllowsActivation,
    required this.availableActivationPaths,
    required this.degradedReasons,
    required this.transient,
    required this.retryable,
    this.preferredActivationPath,
    this.blockingReason,
  });

  final bool canTriggerAppSos;
  final bool canTriggerDeviceSos;
  final bool canCancelCurrentSos;
  final bool appTransportReady;
  final bool deviceTransportReady;
  final bool hasAuthenticatedSession;
  final bool hasRegisteredDevice;
  final bool hasConnectedDevice;
  final bool commandChannelReady;
  final bool locationAvailable;
  final bool lifecycleAllowsActivation;
  final Set<SosActivationPath> availableActivationPaths;
  final SosActivationPath? preferredActivationPath;
  final SosCapabilityBlockingReason? blockingReason;
  final Set<SosCapabilityDegradedReason> degradedReasons;
  final bool transient;
  final bool retryable;

  bool get canTriggerSos => canTriggerAppSos || canTriggerDeviceSos;
}
