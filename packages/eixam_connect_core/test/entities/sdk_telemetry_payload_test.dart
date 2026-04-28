import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('SdkTelemetryPayload', () {
    test('serializes deviceBattery as backend object for raw values', () {
      final ranges = <double, String>{
        0: 'critical',
        1: 'low',
        2: 'medium',
        3: 'ok',
      };

      for (final entry in ranges.entries) {
        final json = _payload(deviceBattery: entry.key).toJson();

        expect(json['deviceBattery'], <String, dynamic>{
          'rawValue': entry.key.toInt(),
          'range': entry.value,
        });
      }
    });

    test('serializes deviceCoverage as backend object', () {
      final json = _payload(deviceCoverage: 4).toJson();

      expect(json['deviceCoverage'], <String, dynamic>{
        'signalStrength': 4,
        'networkType': 'ble',
        'isConnected': true,
      });
    });

    test('serializes mobileBattery as clamped integer', () {
      expect(_payload(mobileBattery: 61.6).toJson()['mobileBattery'], 62);
      expect(_payload(mobileBattery: -1).toJson()['mobileBattery'], 0);
      expect(_payload(mobileBattery: 150).toJson()['mobileBattery'], 100);
    });
  });
}

SdkTelemetryPayload _payload({
  double? deviceBattery,
  int? deviceCoverage,
  double? mobileBattery,
}) {
  return SdkTelemetryPayload(
    timestamp: DateTime.utc(2026, 3, 31, 10, 15),
    latitude: 41.38,
    longitude: 2.17,
    altitude: 8,
    deviceBattery: deviceBattery,
    deviceCoverage: deviceCoverage,
    mobileBattery: mobileBattery,
  );
}
