import '../enums/sos_actionability.dart';
import 'sos_incident.dart';
import 'sos_capability_snapshot.dart';

/// Authoritative, SDK-owned SOS lifecycle stages.
enum SosLifecycleStage {
  idle,
  arming,
  activating,
  active,
  cancelling,
  cancelled,
  resolved,
  activationFailed,
  cancellationFailed,
  recoveryRequired,
}

enum SosLifecycleOrigin {
  localApp,
  connectedLocalDevice,
  registeredLocalDevice,
  remoteRelay,
  externalBackend,
  unknown,
}

enum SosCancellationPhase {
  none,
  requested,
  transportAccepted,
  deviceConfirmed,
  backendConfirmed,
  fullyResolved,
  failed,
}

enum SosRecoveryStatus { none, restored, reconciling, unresolved }

enum SosActivationOutcome {
  activated,
  alreadyActiveRecovered,
  alreadyActiveUnmatched,
  failed,
}

enum SosCancellationOutcome {
  cancelled,
  pendingConfirmation,
  alreadyTerminal,
  failed
}

/// The single public source of truth for an SOS generation.
final class SosLifecycleSnapshot {
  const SosLifecycleSnapshot({
    required this.stage,
    required this.lifecycleId,
    required this.generation,
    required this.origin,
    required this.localActionable,
    required this.externalOnly,
    required this.displaySurface,
    required this.lastAuthoritativeObservation,
    this.localIncidentId,
    this.backendIncidentId,
    this.deviceId,
    this.nodeId,
    this.hardwareId,
    this.triggerSource,
    this.activationTimestamp,
    this.cancellationPhase = SosCancellationPhase.none,
    this.recoveryStatus = SosRecoveryStatus.none,
    this.failureCode,
    this.incident,
  });

  factory SosLifecycleSnapshot.idle(DateTime observedAt) =>
      SosLifecycleSnapshot(
        stage: SosLifecycleStage.idle,
        lifecycleId: '',
        generation: 0,
        origin: SosLifecycleOrigin.unknown,
        localActionable: false,
        externalOnly: false,
        displaySurface: SosDisplaySurface.unknown,
        lastAuthoritativeObservation: observedAt,
      );

  final SosLifecycleStage stage;
  final String lifecycleId;
  final int generation;
  final SosLifecycleOrigin origin;
  final bool localActionable;
  final bool externalOnly;
  final SosDisplaySurface displaySurface;
  final String? localIncidentId;
  final String? backendIncidentId;
  final String? deviceId;
  final int? nodeId;
  final String? hardwareId;
  final String? triggerSource;
  final DateTime? activationTimestamp;
  final DateTime lastAuthoritativeObservation;
  final SosCancellationPhase cancellationPhase;
  final SosRecoveryStatus recoveryStatus;
  final String? failureCode;
  final SosIncident? incident;

  bool get isTerminal =>
      stage == SosLifecycleStage.cancelled ||
      stage == SosLifecycleStage.resolved;

  bool get isOpen =>
      stage == SosLifecycleStage.arming ||
      stage == SosLifecycleStage.activating ||
      stage == SosLifecycleStage.active ||
      stage == SosLifecycleStage.cancelling ||
      stage == SosLifecycleStage.cancellationFailed ||
      stage == SosLifecycleStage.recoveryRequired;

  SosLifecycleSnapshot copyWith({
    SosLifecycleStage? stage,
    SosLifecycleOrigin? origin,
    bool? localActionable,
    bool? externalOnly,
    SosDisplaySurface? displaySurface,
    Object? localIncidentId = _unset,
    Object? backendIncidentId = _unset,
    Object? deviceId = _unset,
    Object? nodeId = _unset,
    Object? hardwareId = _unset,
    Object? triggerSource = _unset,
    Object? activationTimestamp = _unset,
    DateTime? lastAuthoritativeObservation,
    SosCancellationPhase? cancellationPhase,
    SosRecoveryStatus? recoveryStatus,
    Object? failureCode = _unset,
    Object? incident = _unset,
  }) =>
      SosLifecycleSnapshot(
        stage: stage ?? this.stage,
        lifecycleId: lifecycleId,
        generation: generation,
        origin: origin ?? this.origin,
        localActionable: localActionable ?? this.localActionable,
        externalOnly: externalOnly ?? this.externalOnly,
        displaySurface: displaySurface ?? this.displaySurface,
        localIncidentId: identical(localIncidentId, _unset)
            ? this.localIncidentId
            : localIncidentId as String?,
        backendIncidentId: identical(backendIncidentId, _unset)
            ? this.backendIncidentId
            : backendIncidentId as String?,
        deviceId:
            identical(deviceId, _unset) ? this.deviceId : deviceId as String?,
        nodeId: identical(nodeId, _unset) ? this.nodeId : nodeId as int?,
        hardwareId: identical(hardwareId, _unset)
            ? this.hardwareId
            : hardwareId as String?,
        triggerSource: identical(triggerSource, _unset)
            ? this.triggerSource
            : triggerSource as String?,
        activationTimestamp: identical(activationTimestamp, _unset)
            ? this.activationTimestamp
            : activationTimestamp as DateTime?,
        lastAuthoritativeObservation:
            lastAuthoritativeObservation ?? this.lastAuthoritativeObservation,
        cancellationPhase: cancellationPhase ?? this.cancellationPhase,
        recoveryStatus: recoveryStatus ?? this.recoveryStatus,
        failureCode: identical(failureCode, _unset)
            ? this.failureCode
            : failureCode as String?,
        incident: identical(incident, _unset)
            ? this.incident
            : incident as SosIncident?,
      );

  static const Object _unset = Object();
}

final class SosActivationResult {
  const SosActivationResult({
    required this.outcome,
    required this.lifecycle,
    this.incident,
    this.selectedPath,
    this.usedPaths = const <SosActivationPath>{},
  });

  final SosActivationOutcome outcome;
  final SosLifecycleSnapshot lifecycle;
  final SosIncident? incident;
  final SosActivationPath? selectedPath;
  final Set<SosActivationPath> usedPaths;
}

final class SosCancellationResult {
  const SosCancellationResult({
    required this.outcome,
    required this.lifecycle,
    this.incident,
  });

  final SosCancellationOutcome outcome;
  final SosLifecycleSnapshot lifecycle;
  final SosIncident? incident;
}
