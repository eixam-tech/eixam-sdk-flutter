import 'package:eixam_connect_core/eixam_connect_core.dart';

class RescueViewState {
  const RescueViewState({
    required this.hasSdkSupport,
    required this.summary,
    required this.sessionLabel,
    required this.targetStateLabel,
    required this.deviceLabel,
    required this.lastKnownPositionLabel,
    required this.availabilityNote,
    required this.missingSdkApis,
    this.canRequestPosition = false,
    this.canAcknowledgeSos = false,
    this.canEnableBuzzer = false,
    this.canDisableBuzzer = false,
    this.canRequestStatus = false,
  });

  factory RescueViewState.fromSdkState({
    required GuidedRescueState rescueState,
    required DeviceStatus? deviceStatus,
    required TrackingPosition? lastPosition,
  }) {
    final snapshot = rescueState.lastStatusSnapshot;
    final effectivePosition =
        rescueState.lastKnownTargetPosition ?? lastPosition;
    final positionLabel = effectivePosition == null
        ? 'No tracked position available yet'
        : '${effectivePosition.latitude}, ${effectivePosition.longitude}';
    final targetStateLabel = snapshot?.targetState.name ?? 'unknown';
    final sessionLabel = rescueState.hasSession
        ? '${_formatNodeId(rescueState.targetNodeId)} -> ${_formatNodeId(rescueState.rescueNodeId)}'
        : 'No rescue session configured';

    return RescueViewState(
      hasSdkSupport: rescueState.hasRuntimeSupport,
      summary: rescueState.hasRuntimeSupport
          ? 'Guided Rescue Phase 1 is available through the SDK contract.'
          : 'Guided Rescue Phase 1 now has an SDK contract, but runtime orchestration is still pending.',
      sessionLabel: sessionLabel,
      targetStateLabel: targetStateLabel,
      deviceLabel: deviceStatus?.deviceAlias ??
          deviceStatus?.deviceId ??
          'No device selected',
      lastKnownPositionLabel: positionLabel,
      availabilityNote: rescueState.unavailableReason ??
          'Waiting for runtime support to execute rescue commands.',
      missingSdkApis: const <String>[
        'BLE/runtime implementation for Rescue port 261 command delivery',
        'Structured STATUS_RESP decoder feeding GuidedRescueStatusSnapshot',
        'Backend/app orchestration for rescue session selection and lifecycle',
      ],
      canRequestPosition:
          rescueState.canRun(GuidedRescueAction.requestPosition),
      canAcknowledgeSos: rescueState.canRun(GuidedRescueAction.acknowledgeSos),
      canEnableBuzzer: rescueState.canRun(GuidedRescueAction.buzzerOn),
      canDisableBuzzer: rescueState.canRun(GuidedRescueAction.buzzerOff),
      canRequestStatus: rescueState.canRun(GuidedRescueAction.requestStatus),
    );
  }

  final bool hasSdkSupport;
  final String summary;
  final String sessionLabel;
  final String targetStateLabel;
  final String deviceLabel;
  final String lastKnownPositionLabel;
  final String availabilityNote;
  final List<String> missingSdkApis;
  final bool canRequestPosition;
  final bool canAcknowledgeSos;
  final bool canEnableBuzzer;
  final bool canDisableBuzzer;
  final bool canRequestStatus;

  static String _formatNodeId(int? nodeId) {
    if (nodeId == null) {
      return '-';
    }
    return '0x${(nodeId & 0xFFFF).toRadixString(16).padLeft(4, '0')}';
  }
}
