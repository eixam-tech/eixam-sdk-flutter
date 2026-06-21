import 'package:eixam_connect_core/eixam_connect_core.dart';

class SosOriginDecision {
  const SosOriginDecision({
    required this.actionability,
    required this.originKind,
    required this.displaySurface,
    required this.localStateMutation,
    required this.publicIncident,
    required this.backendPublish,
    required this.reason,
  });

  final SosActionability actionability;
  final SosOriginKind originKind;
  final SosDisplaySurface displaySurface;
  final bool localStateMutation;
  final bool publicIncident;
  final bool backendPublish;
  final String reason;

  bool get isExternalOnly => actionability == SosActionability.externalOnly;
}

SosOriginDecision classifySosIncidentOrigin(
  SosIncident? incident, {
  int? boundNodeId,
  String? boundDeviceId,
  String? boundHardwareId,
  bool forBackendPublish = false,
}) {
  return classifySosOrigin(
    source: incident?.source,
    triggerSource: incident?.triggerSource,
    relaySource: incident?.relaySource,
    owner: incident?.owner,
    originatorNodeId: incident?.originatorNodeId,
    relayNodeId: incident?.relayNodeId,
    deviceId: incident?.deviceId,
    hardwareId: incident?.hardwareId,
    boundNodeId: boundNodeId,
    boundDeviceId: boundDeviceId,
    boundHardwareId: boundHardwareId,
    forBackendPublish: forBackendPublish,
  );
}

SosOriginDecision classifySosOrigin({
  String? source,
  String? triggerSource,
  String? relaySource,
  String? owner,
  int? originatorNodeId,
  int? relayNodeId,
  String? deviceId,
  String? hardwareId,
  int? boundNodeId,
  String? boundDeviceId,
  String? boundHardwareId,
  bool forBackendPublish = false,
}) {
  final normalizedSource = _normalize(source);
  final normalizedTriggerSource = _normalize(triggerSource);
  final normalizedRelaySource = _normalize(relaySource);
  final normalizedOwner = _normalize(owner);
  final normalizedDeviceId = _normalize(deviceId);
  final normalizedHardwareId = _normalize(hardwareId);
  final normalizedBoundDeviceId = _normalize(boundDeviceId);
  final normalizedBoundHardwareId = _normalize(boundHardwareId);
  final sourceTokens = <String>{
    if (normalizedSource != null) normalizedSource,
    if (normalizedTriggerSource != null) normalizedTriggerSource,
    if (normalizedRelaySource != null) normalizedRelaySource,
  };

  if (sourceTokens.contains('remote_lora_relay') ||
      sourceTokens.contains('external_lora')) {
    return _external('explicit_lora_relay_source', forBackendPublish);
  }

  final explicitLocalApp = sourceTokens.any(_isLocalAppToken);
  if (explicitLocalApp && normalizedRelaySource == null) {
    return _local('local_app_source', forBackendPublish);
  }

  final originatorMatchesBoundNode = originatorNodeId != null &&
      boundNodeId != null &&
      originatorNodeId == boundNodeId;
  final deviceMatchesBound = normalizedDeviceId != null &&
      normalizedDeviceId == normalizedBoundDeviceId;
  final hardwareMatchesBound = normalizedHardwareId != null &&
      normalizedHardwareId == normalizedBoundHardwareId;
  final explicitlyOwnDevice = originatorMatchesBoundNode ||
      deviceMatchesBound ||
      hardwareMatchesBound ||
      sourceTokens.any(_isOwnDeviceToken);

  if (explicitlyOwnDevice && !_hasStrongExternalMarker(sourceTokens)) {
    return _local('own_device_identity_match', forBackendPublish);
  }

  if (normalizedRelaySource != null &&
      !_isOwnDeviceToken(normalizedRelaySource)) {
    return _external('relay_source_present', forBackendPublish);
  }

  final remoteRelayMarker = sourceTokens.contains('remote_relay') ||
      sourceTokens.contains('remote_lora') ||
      sourceTokens.contains('external_relay');
  if (remoteRelayMarker && !explicitlyOwnDevice) {
    return _external(
        'remote_relay_marker_foreign_or_unbound', forBackendPublish);
  }

  if (originatorNodeId != null &&
      boundNodeId != null &&
      originatorNodeId != boundNodeId &&
      (relayNodeId != null || remoteRelayMarker)) {
    return _external('originator_differs_from_bound_node', forBackendPublish);
  }

  if (normalizedOwner == 'external' || normalizedOwner == 'remote') {
    return _external('external_owner', forBackendPublish);
  }

  if (normalizedOwner == 'device' && explicitlyOwnDevice) {
    return _local('device_owner_identity_match', forBackendPublish);
  }

  if (normalizedOwner == 'app' && normalizedSource == 'background_sos') {
    final hardwareLooksRelayContext = normalizedBoundHardwareId != null &&
        normalizedHardwareId != null &&
        normalizedHardwareId == normalizedBoundHardwareId &&
        (remoteRelayMarker || normalizedRelaySource != null);
    if (hardwareLooksRelayContext) {
      return _external(
          'background_sos_relay_hardware_context', forBackendPublish);
    }
  }

  return const SosOriginDecision(
    actionability: SosActionability.unknown,
    originKind: SosOriginKind.unknown,
    displaySurface: SosDisplaySurface.unknown,
    localStateMutation: false,
    publicIncident: false,
    backendPublish: false,
    reason: 'insufficient_origin_metadata',
  );
}

SosOriginDecision _local(String reason, bool forBackendPublish) {
  return SosOriginDecision(
    actionability: SosActionability.localActionable,
    originKind: reason == 'local_app_source'
        ? SosOriginKind.app
        : SosOriginKind.ownDevice,
    displaySurface: SosDisplaySurface.activeAndHistory,
    localStateMutation: true,
    publicIncident: true,
    backendPublish: forBackendPublish,
    reason: reason,
  );
}

SosOriginDecision _external(String reason, bool forBackendPublish) {
  return SosOriginDecision(
    actionability: SosActionability.externalOnly,
    originKind: reason == 'external_owner'
        ? SosOriginKind.external
        : SosOriginKind.remoteRelay,
    displaySurface: SosDisplaySurface.historyOnly,
    localStateMutation: false,
    publicIncident: false,
    backendPublish: forBackendPublish,
    reason: reason,
  );
}

String? _normalize(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed.toLowerCase().replaceAll('-', '_');
}

bool _isLocalAppToken(String value) {
  return value == 'button_ui' ||
      value == 'commercial_app' ||
      value == 'os_widget' ||
      value == 'death_man_protocol' ||
      value == 'public_sos_fallback';
}

bool _isOwnDeviceToken(String value) {
  return value == 'ble_device_runtime_status' ||
      value == 'ble_device_runtime_confirm' ||
      value == 'ble_device_runtime_countdown_elapsed' ||
      value == 'own_device' ||
      value == 'device_button';
}

bool _hasStrongExternalMarker(Set<String> tokens) {
  return tokens.contains('remote_lora_relay') ||
      tokens.contains('external_lora') ||
      tokens.contains('external_relay');
}
