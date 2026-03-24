import 'package:eixam_connect_core/eixam_connect_core.dart';

class RescueViewState {
  const RescueViewState({
    required this.hasSdkSupport,
    required this.summary,
    required this.sosStateLabel,
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

  factory RescueViewState.fromAvailableState({
    required SosState? sosState,
    required DeviceStatus? deviceStatus,
    required TrackingPosition? lastPosition,
  }) {
    final positionLabel = lastPosition == null
        ? 'No tracked position available yet'
        : '${lastPosition.latitude}, ${lastPosition.longitude}';

    return RescueViewState(
      hasSdkSupport: false,
      summary:
          'Guided Rescue Phase 1 is prepared as an operational validation surface, but the rescue command/state contract is not yet exposed by the public SDK.',
      sosStateLabel: sosState?.name ?? 'unknown',
      deviceLabel:
          deviceStatus?.deviceAlias ?? deviceStatus?.deviceId ?? 'No device selected',
      lastKnownPositionLabel: positionLabel,
      availabilityNote:
          'Waiting for SDK APIs for rescue commands, status responses, and presentation-ready rescue state.',
      missingSdkApis: const <String>[
        'sendRescueRequestPosition(targetNodeId, rescueNodeId)',
        'sendRescueAcknowledgeSos(targetNodeId, rescueNodeId)',
        'sendRescueBuzzerOn(targetNodeId, rescueNodeId)',
        'sendRescueBuzzerOff(targetNodeId, rescueNodeId)',
        'requestRescueStatus(targetNodeId, rescueNodeId)',
        'watchRescueViewState() / getRescueViewState()',
        'Structured STATUS_RESP model for Guided Rescue Phase 1',
      ],
    );
  }

  final bool hasSdkSupport;
  final String summary;
  final String sosStateLabel;
  final String deviceLabel;
  final String lastKnownPositionLabel;
  final String availabilityNote;
  final List<String> missingSdkApis;
  final bool canRequestPosition;
  final bool canAcknowledgeSos;
  final bool canEnableBuzzer;
  final bool canDisableBuzzer;
  final bool canRequestStatus;
}
