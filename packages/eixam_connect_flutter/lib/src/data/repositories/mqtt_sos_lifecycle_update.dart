import 'package:eixam_connect_core/eixam_connect_core.dart';

class MqttSosLifecycleUpdate {
  const MqttSosLifecycleUpdate({
    required this.incidentId,
    this.state,
    this.actuators,
    this.clientIncidentId,
    this.correlationId,
    this.cycleKey,
    this.source,
    this.triggerSource,
    this.relaySource,
    this.owner,
    this.actionability,
    this.displaySurface,
  });

  final String incidentId;
  final SosState? state;
  final SosActuatorSnapshot? actuators;
  final String? clientIncidentId;
  final String? correlationId;
  final String? cycleKey;
  final String? source;
  final String? triggerSource;
  final String? relaySource;
  final String? owner;
  final String? actionability;
  final String? displaySurface;

  static MqttSosLifecycleUpdate? fromRealtimeEvent(RealtimeEvent event) {
    final payload = event.payload;
    if (payload == null) {
      return null;
    }

    final incidentId = _incidentIdFrom(payload);
    final state = _stateFrom(payload);
    final actuators = _actuatorsFrom(payload);
    if (incidentId == null || (state == null && actuators == null)) {
      return null;
    }

    return MqttSosLifecycleUpdate(
      incidentId: incidentId,
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
    );
  }

  static String? _incidentIdFrom(Map<String, dynamic> payload) {
    final direct = payload['incidentId'] ?? payload['id'];
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

  static SosState? _stateFrom(Map<String, dynamic> payload) {
    final eventType = payload['type'];
    if (eventType is String &&
        eventType.trim().toLowerCase() == 'sos.actuator_update') {
      return null;
    }

    final raw = payload['status'] ?? payload['state'] ?? payload['type'];
    if (raw is! String) {
      return null;
    }

    final normalized = raw.trim().toLowerCase();
    return switch (normalized) {
      'triggered' || 'opened' || 'active' || 'sent' => SosState.sent,
      'acknowledged' ||
      'sos_acknowledged' ||
      'sos.acknowledged' =>
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

  static String? _stringFromMap(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return null;
  }
}
