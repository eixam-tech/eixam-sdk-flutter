import 'sdk_telemetry_payload.dart';
import 'tracking_position.dart';

class PendingTelemetryDiagnostics {
  const PendingTelemetryDiagnostics({
    required this.signature,
    required this.payload,
  });

  final String signature;
  final SdkTelemetryPayload payload;
}

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

class SdkBridgeDiagnostics {
  const SdkBridgeDiagnostics({
    this.isActive = false,
    this.lastBleTelemetryEventSummary,
    this.lastBleSosEventSummary,
    this.lastDecision,
    this.lastDeviceCommandSent,
    this.pendingTelemetry,
    this.pendingSos,
  });

  final bool isActive;
  final String? lastBleTelemetryEventSummary;
  final String? lastBleSosEventSummary;
  final String? lastDecision;
  final String? lastDeviceCommandSent;
  final PendingTelemetryDiagnostics? pendingTelemetry;
  final PendingSosDiagnostics? pendingSos;

  SdkBridgeDiagnostics copyWith({
    bool? isActive,
    Object? lastBleTelemetryEventSummary = _unset,
    Object? lastBleSosEventSummary = _unset,
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
