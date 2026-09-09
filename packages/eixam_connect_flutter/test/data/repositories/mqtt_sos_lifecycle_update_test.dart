import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_sos_lifecycle_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MqttSosLifecycleUpdate', () {
    test('maps payload state acknowledged', () {
      final update = MqttSosLifecycleUpdate.fromRealtimeEvent(
        RealtimeEvent(
          type: 'sos.lifecycle',
          timestamp: DateTime.utc(2026, 9, 9),
          payload: const <String, dynamic>{
            'incidentId': 'backend-sos-1',
            'state': 'acknowledged',
          },
        ),
      );

      expect(update, isNotNull);
      expect(update!.state, SosState.acknowledged);
    });

    test('portal sos_ack wins over leftover active status', () {
      final update = MqttSosLifecycleUpdate.fromRealtimeEvent(
        RealtimeEvent(
          type: 'sos.lifecycle',
          timestamp: DateTime.utc(2026, 9, 9),
          payload: const <String, dynamic>{
            'incidentId': 'backend-sos-1',
            'type': 'sos_ack',
            'status': 'active',
          },
        ),
      );

      expect(update, isNotNull);
      expect(update!.state, SosState.acknowledged);
      expect(update.eventType, 'sos_ack');
    });

    test('maps portal sos_ack aliases from payload type or event type', () {
      final fromPayloadType = MqttSosLifecycleUpdate.fromRealtimeEvent(
        RealtimeEvent(
          type: 'sos.lifecycle',
          timestamp: DateTime.utc(2026, 9, 9),
          payload: const <String, dynamic>{
            'incidentId': 'backend-sos-1',
            'type': 'sos_ack',
          },
        ),
      );
      final fromEventType = MqttSosLifecycleUpdate.fromRealtimeEvent(
        RealtimeEvent(
          type: 'sos.acknowledged',
          timestamp: DateTime.utc(2026, 9, 9),
          payload: const <String, dynamic>{
            'incidentId': 'backend-sos-1',
            'type': 'sos.lifecycle',
          },
        ),
      );

      expect(fromPayloadType?.state, SosState.acknowledged);
      expect(fromEventType?.state, SosState.acknowledged);
    });
  });
}
