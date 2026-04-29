import 'sdk_telemetry_payload.dart';
import 'tracking_position.dart';

/// Buffered telemetry item retained by the SDK bridge for later retry.
class PendingTelemetryDiagnostics {
  const PendingTelemetryDiagnostics({
    required this.signature,
    required this.payload,
  });

  final String signature;
  final SdkTelemetryPayload payload;
}

/// Buffered SOS item retained by the SDK bridge for later retry.
class PendingSosDiagnostics {
  const PendingSosDiagnostics({
    required this.signature,
    required this.message,
    required this.positionSnapshot,
  });

  final String signature;
  final String message;
  final TrackingPosition positionSnapshot;
}

/// Integration-facing diagnostics for relay ingest and bridge decisions.
///
/// These fields are descriptive support signals, not the primary source of
/// truth for host control flow.
class SdkBridgeDiagnostics {
  const SdkBridgeDiagnostics({
    this.isActive = false,
    this.lastBleTelemetryEventSummary,
    this.lastBleSosEventSummary,
    this.lastRelayRemoteDeviceId,
    this.lastRelayTelemetryPublishAttempt,
    this.lastRelayTelemetryPublishResult,
    this.lastRelaySosPublishAttempt,
    this.lastRelaySosPublishResult,
    this.lastRelayTerminalErrorCode,
    this.lastRelayTerminalErrorMessage,
    this.lastDecision,
    this.lastDeviceCommandSent,
    this.pendingTelemetry,
    this.pendingSos,
  });

  final bool isActive;
  final String? lastBleTelemetryEventSummary;
  final String? lastBleSosEventSummary;
  final String? lastRelayRemoteDeviceId;
  final String? lastRelayTelemetryPublishAttempt;
  final String? lastRelayTelemetryPublishResult;
  final String? lastRelaySosPublishAttempt;
  final String? lastRelaySosPublishResult;

  /// Terminal relay ingest rejection remembered by the SDK, typically caused
  /// by a backend `422`/unprocessable response.
  final String? lastRelayTerminalErrorCode;
  final String? lastRelayTerminalErrorMessage;
  final String? lastDecision;
  final String? lastDeviceCommandSent;
  final PendingTelemetryDiagnostics? pendingTelemetry;
  final PendingSosDiagnostics? pendingSos;

  SdkBridgeDiagnostics copyWith({
    bool? isActive,
    Object? lastBleTelemetryEventSummary = _unset,
    Object? lastBleSosEventSummary = _unset,
    Object? lastRelayRemoteDeviceId = _unset,
    Object? lastRelayTelemetryPublishAttempt = _unset,
    Object? lastRelayTelemetryPublishResult = _unset,
    Object? lastRelaySosPublishAttempt = _unset,
    Object? lastRelaySosPublishResult = _unset,
    Object? lastRelayTerminalErrorCode = _unset,
    Object? lastRelayTerminalErrorMessage = _unset,
    Object? lastDecision = _unset,
    Object? lastDeviceCommandSent = _unset,
    Object? pendingTelemetry = _unset,
    Object? pendingSos = _unset,
  }) {
    return SdkBridgeDiagnostics(
      isActive: isActive ?? this.isActive,
      lastBleTelemetryEventSummary:
          identical(lastBleTelemetryEventSummary, _unset)
              ? this.lastBleTelemetryEventSummary
              : lastBleTelemetryEventSummary as String?,
      lastBleSosEventSummary: identical(lastBleSosEventSummary, _unset)
          ? this.lastBleSosEventSummary
          : lastBleSosEventSummary as String?,
      lastRelayRemoteDeviceId: identical(lastRelayRemoteDeviceId, _unset)
          ? this.lastRelayRemoteDeviceId
          : lastRelayRemoteDeviceId as String?,
      lastRelayTelemetryPublishAttempt:
          identical(lastRelayTelemetryPublishAttempt, _unset)
              ? this.lastRelayTelemetryPublishAttempt
              : lastRelayTelemetryPublishAttempt as String?,
      lastRelayTelemetryPublishResult:
          identical(lastRelayTelemetryPublishResult, _unset)
              ? this.lastRelayTelemetryPublishResult
              : lastRelayTelemetryPublishResult as String?,
      lastRelaySosPublishAttempt: identical(lastRelaySosPublishAttempt, _unset)
          ? this.lastRelaySosPublishAttempt
          : lastRelaySosPublishAttempt as String?,
      lastRelaySosPublishResult: identical(lastRelaySosPublishResult, _unset)
          ? this.lastRelaySosPublishResult
          : lastRelaySosPublishResult as String?,
      lastRelayTerminalErrorCode: identical(lastRelayTerminalErrorCode, _unset)
          ? this.lastRelayTerminalErrorCode
          : lastRelayTerminalErrorCode as String?,
      lastRelayTerminalErrorMessage:
          identical(lastRelayTerminalErrorMessage, _unset)
              ? this.lastRelayTerminalErrorMessage
              : lastRelayTerminalErrorMessage as String?,
      lastDecision: identical(lastDecision, _unset)
          ? this.lastDecision
          : lastDecision as String?,
      lastDeviceCommandSent: identical(lastDeviceCommandSent, _unset)
          ? this.lastDeviceCommandSent
          : lastDeviceCommandSent as String?,
      pendingTelemetry: identical(pendingTelemetry, _unset)
          ? this.pendingTelemetry
          : pendingTelemetry as PendingTelemetryDiagnostics?,
      pendingSos: identical(pendingSos, _unset)
          ? this.pendingSos
          : pendingSos as PendingSosDiagnostics?,
    );
  }

  static const Object _unset = Object();
}
