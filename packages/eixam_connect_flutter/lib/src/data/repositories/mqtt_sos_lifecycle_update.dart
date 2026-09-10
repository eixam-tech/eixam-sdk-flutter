import 'package:eixam_connect_core/eixam_connect_core.dart';

class MqttSosLifecycleUpdate {
  const MqttSosLifecycleUpdate({
    required this.incidentId,
    required this.eventType,
    required this.eventTimestamp,
    required this.authenticatedUserScoped,
    this.state,
    this.actuators,
    this.clientIncidentId,
    this.correlationId,
    this.cycleKey,
    this.incidentOccurredAt,
    this.source,
    this.triggerSource,
    this.relaySource,
    this.owner,
    this.actionability,
    this.displaySurface,
    this.terminalReason,
    this.topicCategory,
    this.userId,
    this.eventId,
  });

  final String incidentId;
  final String eventType;
  final DateTime eventTimestamp;
  final bool authenticatedUserScoped;
  final SosState? state;
  final SosActuatorSnapshot? actuators;
  final String? clientIncidentId;
  final String? correlationId;
  final String? cycleKey;
  final DateTime? incidentOccurredAt;
  final String? source;
  final String? triggerSource;
  final String? relaySource;
  final String? owner;
  final String? actionability;
  final String? displaySurface;
  final SosTerminalReason? terminalReason;
  final String? topicCategory;
  final String? userId;
  final String? eventId;

  static MqttSosLifecycleUpdate? fromRealtimeEvent(RealtimeEvent event) {
    final payload = event.payload;
    if (payload == null) {
      return null;
    }

    final incidentId = _incidentIdFrom(payload);
    final state = _stateFrom(event, payload);
    final actuators = _actuatorsFrom(payload);
    if (incidentId == null || (state == null && actuators == null)) {
      return null;
    }

    return MqttSosLifecycleUpdate(
      incidentId: incidentId,
      eventType: _eventTypeFrom(event, payload),
      eventTimestamp: event.timestamp.toUtc(),
      authenticatedUserScoped: payload['_mqttAuthenticatedUserScoped'] == true,
      state: state,
      actuators: actuators,
      clientIncidentId: _stringFromPayload(
        payload,
        const ['clientIncidentId', 'client_incident_id'],
      ),
      correlationId: _stringFromPayload(
        payload,
        const ['correlationId', 'correlation_id'],
      ),
      cycleKey: _stringFromPayload(payload, const ['cycleKey', 'cycle_key']),
      incidentOccurredAt: _dateTimeFromPayload(
        payload,
        const ['occurredAt', 'occurred_at'],
      ),
      source: _stringFromPayload(payload, const ['source']),
      triggerSource: _stringFromPayload(
        payload,
        const ['triggerSource', 'trigger_source'],
      ),
      relaySource: _stringFromPayload(
        payload,
        const ['relaySource', 'relay_source'],
      ),
      owner: _stringFromPayload(payload, const ['owner']),
      actionability: _stringFromPayload(
        payload,
        const ['actionability', 'sosActionability'],
      ),
      displaySurface: _stringFromPayload(
        payload,
        const ['displaySurface', 'display_surface', 'sosDisplaySurface'],
      ),
      terminalReason: _terminalReasonFromPayload(payload),
      topicCategory: _stringFromPayload(
        payload,
        const ['_mqttTopicCategory'],
      ),
      userId: _stringFromPayload(payload, const ['userId', 'user_id']),
      eventId: _stringFromPayload(payload, const ['eventId', 'event_id']),
    );
  }

  static String _eventTypeFrom(
    RealtimeEvent event,
    Map<String, dynamic> payload,
  ) {
    final payloadType = payload['type'];
    final raw = payloadType is String ? payloadType : event.type;
    return raw.trim().toLowerCase();
  }

  static String? _incidentIdFrom(Map<String, dynamic> payload) {
    final direct =
        payload['incidentId'] ?? payload['incident_id'] ?? payload['id'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct.trim();
    }

    final incident = payload['incident'];
    if (incident is Map<String, dynamic>) {
      final nested = incident['id'];
      if (nested is String && nested.trim().isNotEmpty) {
        return nested.trim();
      }
    }

    return null;
  }

  static SosState? _stateFrom(
    RealtimeEvent event,
    Map<String, dynamic> payload,
  ) {
    final eventType = _eventTypeFrom(event, payload);
    if (eventType == 'sos.actuator_update') {
      return null;
    }

    // Portal ACK keeps the incident `active`/`opened` while the event type is
    // `sos_ack`. Acknowledgement aliases must win over that leftover status.
    for (final candidate in <String?>[
      eventType,
      _stringFromPayload(payload, const ['type']),
      event.type,
    ]) {
      if (_mapNormalizedState(candidate) == SosState.acknowledged) {
        return SosState.acknowledged;
      }
    }

    for (final candidate in <String?>[
      _stringFromPayload(payload, const ['status', 'state']),
      _stringFromPayload(payload, const ['type']),
      event.type,
    ]) {
      final mapped = _mapNormalizedState(candidate);
      if (mapped != null) {
        return mapped;
      }
    }
    return null;
  }

  static SosState? _mapNormalizedState(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    return switch (raw.trim().toLowerCase()) {
      'triggered' || 'opened' || 'active' || 'sent' => SosState.sent,
      'acknowledged' ||
      'sos_acknowledged' ||
      'sos.acknowledged' ||
      'sos_ack' ||
      'sos.ack' ||
      'ack' =>
        SosState.acknowledged,
      'cancelled' ||
      'canceled' ||
      'sos_cancelled' ||
      'sos.cancelled' =>
        SosState.cancelled,
      'resolved' ||
      'closed' ||
      'sos_resolved' ||
      'sos.resolved' =>
        SosState.resolved,
      _ => null,
    };
  }

  static SosActuatorSnapshot? _actuatorsFrom(Map<String, dynamic> payload) {
    final direct = _snapshotFromEnvelope(
      actuators: payload['actuators'],
      snapshotVersion:
          payload['snapshotVersion'] ?? payload['snapshot_version'],
    );
    if (direct != null) {
      return direct;
    }

    final incident = payload['incident'];
    if (incident is Map) {
      return _snapshotFromEnvelope(
        actuators: incident['actuators'],
        snapshotVersion:
            incident['snapshotVersion'] ?? incident['snapshot_version'],
      );
    }
    return null;
  }

  static SosActuatorSnapshot? _snapshotFromEnvelope({
    required Object? actuators,
    required Object? snapshotVersion,
  }) {
    if (actuators is List) {
      return SosActuatorSnapshot.fromJson(<String, dynamic>{
        'snapshotVersion': snapshotVersion,
        'items': actuators,
      });
    }
    if (actuators is Map<String, dynamic>) {
      return SosActuatorSnapshot.fromJson(<String, dynamic>{
        if (snapshotVersion != null) 'snapshotVersion': snapshotVersion,
        ...actuators,
      });
    }
    if (actuators is Map) {
      return SosActuatorSnapshot.fromJson(<String, dynamic>{
        if (snapshotVersion != null) 'snapshotVersion': snapshotVersion,
        ...Map<String, dynamic>.from(actuators),
      });
    }
    return null;
  }

  static String? _stringFromPayload(
    Map<String, dynamic> payload,
    List<String> keys,
  ) {
    final direct = _stringFromMap(payload, keys);
    if (direct != null) {
      return direct;
    }
    final incident = payload['incident'];
    if (incident is Map<String, dynamic>) {
      return _stringFromMap(incident, keys);
    }
    if (incident is Map) {
      return _stringFromMap(Map<String, dynamic>.from(incident), keys);
    }
    return null;
  }

  static DateTime? _dateTimeFromPayload(
    Map<String, dynamic> payload,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = payload[key];
      if (value is String) {
        final parsed = DateTime.tryParse(value.trim());
        if (parsed != null) {
          return parsed.toUtc();
        }
      }
    }
    return null;
  }

  static String? _stringFromMap(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }

  static SosTerminalReason? _terminalReasonFromPayload(
    Map<String, dynamic> payload,
  ) {
    final raw = _stringFromPayload(
      payload,
      const ['terminalReason', 'terminal_reason', 'reason'],
    );
    if (raw == null) {
      return null;
    }
    final normalized =
        raw.replaceAll('-', '').replaceAll('_', '').toLowerCase();
    return SosTerminalReason.values.firstWhere(
      (candidate) => candidate.name.toLowerCase() == normalized,
      orElse: () => SosTerminalReason.unknown,
    );
  }
}
