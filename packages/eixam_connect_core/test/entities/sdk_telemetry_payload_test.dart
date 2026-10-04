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

    test('serializes phone radio and horizontal accuracy', () {
      final json = _payload(
        horizontalAccuracyMeters: 12.5,
        radio: const SdkRadioSnapshot(
          generation: '5g',
          fiveGMode: 'nsa',
          connected: true,
        ),
      ).toJson();

      expect(json['horizontalAccuracyMeters'], 12.5);
      expect(json['radio'], <String, dynamic>{
        'generation': '5g',
        'fiveGMode': 'nsa',
        'connected': true,
      });
      expect(json.containsKey('phoneRadio'), isFalse);
    });

    test('omits radio and a negative accuracy', () {
      final json = _payload(horizontalAccuracyMeters: -1).toJson();

      expect(json.containsKey('horizontalAccuracyMeters'), isFalse);
      expect(json.containsKey('radio'), isFalse);
    });

    test('omits an unknown fiveGMode', () {
      final json = _payload(
        radio: const SdkRadioSnapshot(generation: '5g', fiveGMode: 'logo'),
      ).toJson();

      expect(json['radio'], <String, dynamic>{'generation': '5g'});
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
  double? horizontalAccuracyMeters,
  SdkRadioSnapshot? radio,
}) {
  return SdkTelemetryPayload(
    timestamp: DateTime.utc(2026, 3, 31, 10, 15),
    latitude: 41.38,
    longitude: 2.17,
    altitude: 8,
    deviceBattery: deviceBattery,
    deviceCoverage: deviceCoverage,
    mobileBattery: mobileBattery,
    horizontalAccuracyMeters: horizontalAccuracyMeters,
    radio: radio,
  );
}
