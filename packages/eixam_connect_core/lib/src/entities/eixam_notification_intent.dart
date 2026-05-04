enum EixamNotificationIntentType {
  preSos,
  sosActive,
  sosResolved,
  sosCancelled,
  externalSosSent,
}

enum EixamNotificationIntentSeverity {
  info,
  warning,
  critical,
  success,
}

class EixamNotificationIntent {
  const EixamNotificationIntent({
    required this.id,
    required this.type,
    required this.dedupeKey,
    required this.createdAt,
    required this.severity,
    this.incidentId,
    this.deviceId,
    this.deviceAlias,
    this.nodeId,
    this.originatorNodeId,
    this.relayNodeId,
    this.titleKey,
    this.bodyKey,
    this.fallbackTitle,
    this.fallbackBody,
    this.payload = const <String, String>{},
    this.shouldClearSosNotifications = false,
  });

  final String id;
  final EixamNotificationIntentType type;
  final String dedupeKey;
  final DateTime createdAt;
  final EixamNotificationIntentSeverity severity;

  final String? incidentId;
  final String? deviceId;
  final String? deviceAlias;
  final int? nodeId;
  final int? originatorNodeId;
  final int? relayNodeId;

  /// Semantic localization keys suggested by the SDK.
  ///
  /// Host apps own localization and may ignore these.
  final String? titleKey;
  final String? bodyKey;

  /// Human-readable fallback copy for host apps that do not localize intents.
  final String? fallbackTitle;
  final String? fallbackBody;

  /// Generic serializable payload for routing or notification metadata.
  final Map<String, String> payload;

  /// True when the host app may want to clear currently displayed SOS alerts.
  final bool shouldClearSosNotifications;
}
