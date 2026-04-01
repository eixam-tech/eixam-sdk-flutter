import 'package:eixam_connect_core/eixam_connect_core.dart';

class MqttSosLifecycleUpdate {
  const MqttSosLifecycleUpdate({
    required this.incidentId,
    required this.state,
  });

  final String incidentId;
  final SosState state;

  static MqttSosLifecycleUpdate? fromRealtimeEvent(RealtimeEvent event) {
    final payload = event.payload;
    if (payload == null) {
      return null;
    }

    final incidentId = _incidentIdFrom(payload);
    final state = _stateFrom(payload);
    if (incidentId == null || state == null) {
      return null;
    }

    return MqttSosLifecycleUpdate(
      incidentId: incidentId,
      state: state,
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
}
