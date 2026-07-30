import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eixam_connect_flutter/src/mappers/local_state_serializers.dart';

void main() {
  group('LocalStateSerializers', () {
    test('round-trips a tracking position', () {
      final position = TrackingPosition(
        latitude: 41.3874,
        longitude: 2.1686,
        altitude: 12.5,
        accuracy: 4.2,
        speed: 1.5,
        heading: 270,
        source: DeliveryMode.mobile,
        timestamp: DateTime.utc(2026, 3, 24, 10, 30),
      );

      final json = LocalStateSerializers.trackingPositionToJson(position);
      final restored = LocalStateSerializers.trackingPositionFromJson(json);

      expect(restored.latitude, position.latitude);
      expect(restored.longitude, position.longitude);
      expect(restored.altitude, position.altitude);
      expect(restored.accuracy, position.accuracy);
      expect(restored.speed, position.speed);
      expect(restored.heading, position.heading);
      expect(restored.source, position.source);
      expect(restored.timestamp, position.timestamp);
    });

    test('round-trips an SOS incident with a position snapshot', () {
      final incident = SosIncident(
        id: 'sos-42',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 3, 24, 10, 45),
        triggerSource: 'button_ui',
        message: 'Need rescue',
        positionSnapshot: TrackingPosition(
          latitude: 41.4,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 3, 24, 10, 44),
        ),
      );

      final json = LocalStateSerializers.sosIncidentToJson(incident);
      final restored = LocalStateSerializers.sosIncidentFromJson(json);

      expect(restored.id, incident.id);
      expect(restored.state, incident.state);
      expect(restored.triggerSource, incident.triggerSource);
      expect(restored.message, incident.message);
      expect(restored.createdAt, incident.createdAt);
      expect(restored.positionSnapshot?.latitude,
          incident.positionSnapshot?.latitude);
      expect(restored.positionSnapshot?.longitude,
          incident.positionSnapshot?.longitude);
    });

    test('round-trips actuator evidence and cached-data marker', () {
      final incident = SosIncident(
        id: 'sos-cached',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 7, 20),
        isBackendConfirmed: true,
        isUsingCachedData: true,
        actuators: SosActuatorSnapshot.fromJson(<String, dynamic>{
          'snapshotVersion': 5,
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'emergency_contacts',
              'type': 'emergency_contacts',
              'status': 'delivered',
              'outcome': 'success',
            },
          ],
        }),
      );

      final restored = LocalStateSerializers.sosIncidentFromJson(
        LocalStateSerializers.sosIncidentToJson(incident),
      );

      expect(restored.isUsingCachedData, isTrue);
      expect(restored.isBackendConfirmed, isTrue);
      expect(restored.actuators?.snapshotVersion, 5);
      expect(restored.progress.steps.first.state, SosProgressState.succeeded);
    });

    test('restores battery state from stored name before protocol fallback',
        () {
      final restored =
          LocalStateSerializers.deviceStatusFromJson(<String, dynamic>{
        'deviceId': 'device-1',
        'paired': true,
        'activated': true,
        'connected': true,
        'batteryLevel': 0,
        'batteryState': 'ok',
        'batterySource': 'telPacket',
        'lifecycleState': 'ready',
      });

      expect(restored.effectiveBatteryState, DeviceBatteryLevel.ok);
      expect(restored.batterySource, DeviceBatterySource.telPacket);
      expect(restored.lifecycleState, DeviceLifecycleState.ready);
    });

    test('round-trips exact battery percentage including zero', () {
      const status = DeviceStatus(
        deviceId: 'device-1',
        paired: true,
        activated: true,
        connected: true,
        batteryPercent: 0,
        batteryLevel: 0,
        batteryState: DeviceBatteryLevel.critical,
        batterySource: DeviceBatterySource.deviceStatus,
        lifecycleState: DeviceLifecycleState.ready,
      );

      final restored = LocalStateSerializers.deviceStatusFromJson(
        LocalStateSerializers.deviceStatusToJson(status),
      );

      expect(restored.batteryPercent, 0);
      expect(restored.approximateBatteryPercentage, 0);
      expect(restored.batterySource, DeviceBatterySource.deviceStatus);
    });

    test('rejects invalid persisted exact battery percentage', () {
      final restored =
          LocalStateSerializers.deviceStatusFromJson(<String, dynamic>{
        'deviceId': 'device-1',
        'paired': true,
        'activated': true,
        'connected': true,
        'batteryPercent': 255,
        'lifecycleState': 'ready',
      });

      expect(restored.batteryPercent, isNull);
      expect(restored.approximateBatteryPercentage, isNull);
    });
  });
}
