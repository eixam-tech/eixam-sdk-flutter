import '../enums/sos_state.dart';
import '../enums/sos_actionability.dart';
import '../enums/sos_delivery_channel.dart';
import '../enums/sos_terminal_reason.dart';
import 'sos_actuator_snapshot.dart';
import 'sos_incident_progress.dart';
import 'tracking_position.dart';

class SosIncident {
  const SosIncident({
    required this.id,
    required this.state,
    required this.createdAt,
    this.positionSnapshot,
    this.source,
    this.triggerSource,
    this.relaySource,
    this.originatorNodeId,
    this.relayNodeId,
    this.deviceId,
    this.hardwareId,
    this.owner,
    this.cycleKey,
    this.message,
    this.deliveryChannel,
    this.terminalReason,
    this.originKind = SosOriginKind.unknown,
    this.actionability = SosActionability.unknown,
    this.displaySurface = SosDisplaySurface.unknown,
    this.actuators,
    this.isBackendConfirmed = false,
    this.isUsingCachedData = false,
    this.provisionalIncidentId,
    this.preservedLocalOwnership = false,
    this.isDeliveryRetrying = false,
    this.deliveryIssue,
  });
  final String id;
  final SosState state;
  final TrackingPosition? positionSnapshot;
  final DateTime createdAt;
  final String? source;
  final String? triggerSource;
  final String? relaySource;
  final int? originatorNodeId;
  final int? relayNodeId;
  final String? deviceId;
  final String? hardwareId;
  final String? owner;
  final String? cycleKey;
  final String? message;
  final SosDeliveryChannel? deliveryChannel;
  final SosTerminalReason? terminalReason;
  final SosOriginKind originKind;
  final SosActionability actionability;
  final SosDisplaySurface displaySurface;
  final SosActuatorSnapshot? actuators;
  final bool isBackendConfirmed;
  final bool isUsingCachedData;
  final String? provisionalIncidentId;
  final bool preservedLocalOwnership;

  /// The SOS is not confirmed by the backend yet and delivery is being
  /// retried ("Not sent yet, retrying"). Hosts must not present it as sent.
  final bool isDeliveryRetrying;

  /// Why delivery keeps failing while [isDeliveryRetrying], when the SDK
  /// knows it (for example [deliveryIssueDeviceNotRegistered]). Null when
  /// unknown or delivered.
  final String? deliveryIssue;

  /// The backend rejects the SOS because the paired TAG is not registered to
  /// this account and the SDK could not register it again.
  static const String deliveryIssueDeviceNotRegistered = 'device_not_registered';

  SosIncidentProgress get progress => SosIncidentProgress.fromEvidence(
        incidentId: id,
        incidentState: state,
        createdAt: createdAt,
        actuators: actuators,
        isBackendConfirmed: isBackendConfirmed,
        isUsingCachedData: isUsingCachedData,
        provisionalIncidentId: provisionalIncidentId,
        canonicalIncidentId:
            isBackendConfirmed && !id.startsWith('sos-') ? id : null,
        preservedLocalOwnership: preservedLocalOwnership,
        originKind: originKind,
        actionability: actionability,
        displaySurface: displaySurface,
        deliveryRetrying: isDeliveryRetrying,
        deliveryIssue: deliveryIssue,
      );

  SosIncident copyWith({
    SosState? state,
    TrackingPosition? positionSnapshot,
    DateTime? createdAt,
    String? source,
    String? triggerSource,
    String? relaySource,
    int? originatorNodeId,
    int? relayNodeId,
    String? deviceId,
    String? hardwareId,
    String? owner,
    String? cycleKey,
    String? message,
    Object? deliveryChannel = _unset,
    Object? terminalReason = _unset,
    SosOriginKind? originKind,
    SosActionability? actionability,
    SosDisplaySurface? displaySurface,
    Object? actuators = _unset,
    bool? isBackendConfirmed,
    bool? isUsingCachedData,
    String? provisionalIncidentId,
    bool? preservedLocalOwnership,
    bool? isDeliveryRetrying,
    Object? deliveryIssue = _unset,
  }) {
    return SosIncident(
      id: id,
      state: state ?? this.state,
      createdAt: createdAt ?? this.createdAt,
      positionSnapshot: positionSnapshot ?? this.positionSnapshot,
      source: source ?? this.source,
      triggerSource: triggerSource ?? this.triggerSource,
      relaySource: relaySource ?? this.relaySource,
      originatorNodeId: originatorNodeId ?? this.originatorNodeId,
      relayNodeId: relayNodeId ?? this.relayNodeId,
      deviceId: deviceId ?? this.deviceId,
      hardwareId: hardwareId ?? this.hardwareId,
      owner: owner ?? this.owner,
      cycleKey: cycleKey ?? this.cycleKey,
      message: message ?? this.message,
      deliveryChannel: identical(deliveryChannel, _unset)
          ? this.deliveryChannel
          : deliveryChannel as SosDeliveryChannel?,
      terminalReason: identical(terminalReason, _unset)
          ? this.terminalReason
          : terminalReason as SosTerminalReason?,
      originKind: originKind ?? this.originKind,
      actionability: actionability ?? this.actionability,
      displaySurface: displaySurface ?? this.displaySurface,
      actuators: identical(actuators, _unset)
          ? this.actuators
          : actuators as SosActuatorSnapshot?,
      isBackendConfirmed: isBackendConfirmed ?? this.isBackendConfirmed,
      isUsingCachedData: isUsingCachedData ?? this.isUsingCachedData,
      provisionalIncidentId:
          provisionalIncidentId ?? this.provisionalIncidentId,
      preservedLocalOwnership:
          preservedLocalOwnership ?? this.preservedLocalOwnership,
      isDeliveryRetrying: isDeliveryRetrying ?? this.isDeliveryRetrying,
      deliveryIssue: identical(deliveryIssue, _unset)
          ? this.deliveryIssue
          : deliveryIssue as String?,
    );
  }

  static const Object _unset = Object();
}
