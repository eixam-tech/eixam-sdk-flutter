import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

TagAlertPosition _position({SdkLocationSource? source}) => TagAlertPosition(
  latitude: 42.5,
  longitude: 1.5,
  timestamp: DateTime.utc(2026, 1, 1),
  source: source ?? SdkLocationSource.connectedDevice,
);

void main() {
  group('TagAlertPosition', () {
    test('accepts only the connected TAG as source', () {
      expect(_position().source, SdkLocationSource.connectedDevice);
      for (final source in SdkLocationSource.values) {
        if (source == SdkLocationSource.connectedDevice) continue;
        expect(
          () => _position(source: source),
          throwsArgumentError,
          reason: '$source',
        );
      }
    });

    test('rejects invalid coordinates and 0,0', () {
      TagAlertPosition make(double lat, double lng) => TagAlertPosition(
        latitude: lat,
        longitude: lng,
        timestamp: DateTime.utc(2026),
        source: SdkLocationSource.connectedDevice,
      );
      expect(() => make(0, 0), throwsArgumentError);
      expect(() => make(91, 0), throwsArgumentError);
      expect(() => make(0, 181), throwsArgumentError);
      expect(() => make(double.nan, 1), throwsArgumentError);
    });
  });

  group('TagAlert', () {
    test('battery alerts need a threshold and nothing else', () {
      final alert = TagAlert(
        kind: TagAlertKind.batteryLow,
        deviceId: 'tag-1',
        batteryThreshold: TagAlertBatteryThreshold.below10,
      );
      expect(alert.batteryThreshold, TagAlertBatteryThreshold.below10);
      expect(
        () => TagAlert(kind: TagAlertKind.batteryLow, deviceId: 'tag-1'),
        throwsArgumentError,
      );
      expect(
        () => TagAlert(
          kind: TagAlertKind.bluetoothOff,
          deviceId: 'tag-1',
          batteryThreshold: TagAlertBatteryThreshold.below30,
        ),
        throwsArgumentError,
      );
      expect(
        () => TagAlert(
          kind: TagAlertKind.batteryLow,
          deviceId: 'tag-1',
          batteryThreshold: TagAlertBatteryThreshold.below30,
          elapsed: const Duration(minutes: 5),
        ),
        throwsArgumentError,
      );
    });

    test('disconnect alerts need a positive elapsed', () {
      expect(
        () => TagAlert(kind: TagAlertKind.tagDisconnected, deviceId: 'a'),
        throwsArgumentError,
      );
      expect(
        () => TagAlert(
          kind: TagAlertKind.tagDisconnected,
          deviceId: 'a',
          elapsed: Duration.zero,
        ),
        throwsArgumentError,
      );
      final alert = TagAlert(
        kind: TagAlertKind.tagDisconnected,
        deviceId: 'a',
        elapsed: const Duration(minutes: 15),
        lastTagPosition: _position(),
      );
      expect(alert.lastTagPosition, _position());
    });

    test('equality', () {
      TagAlert make() =>
          TagAlert(kind: TagAlertKind.bluetoothOff, deviceId: 'a');
      expect(make(), make());
      expect(make().hashCode, make().hashCode);
    });
  });

  group('defaultTagAlertText', () {
    test('is neutral: no SOS or emergency wording, no coordinates', () {
      final alerts = <TagAlert>[
        TagAlert(
          kind: TagAlertKind.batteryLow,
          deviceId: 'a',
          deviceAlias: 'Roger TAG',
          batteryThreshold: TagAlertBatteryThreshold.below30,
        ),
        TagAlert(
          kind: TagAlertKind.batteryLow,
          deviceId: 'a',
          batteryThreshold: TagAlertBatteryThreshold.below10,
        ),
        TagAlert(
          kind: TagAlertKind.tagDisconnected,
          deviceId: 'a',
          elapsed: const Duration(minutes: 15),
          lastTagPosition: _position(),
        ),
        TagAlert(kind: TagAlertKind.bluetoothOff, deviceId: 'a'),
      ];
      for (final alert in alerts) {
        final text = defaultTagAlertText(alert);
        final all = '${text.title} ${text.body}'.toLowerCase();
        expect(text.title, isNotEmpty);
        expect(text.body, isNotEmpty);
        expect(all, isNot(contains('sos')));
        expect(all, isNot(contains('emergency')));
        expect(all, isNot(contains('guarantee')));
        expect(all, isNot(contains('42.5')));
      }
      expect(defaultTagAlertText(alerts[0]).body, contains('Roger TAG'));
      expect(defaultTagAlertText(alerts[0]).body, contains('30'));
      expect(defaultTagAlertText(alerts[1]).body, contains('10'));
      expect(defaultTagAlertText(alerts[2]).body, contains('15'));
    });
  });

  group('tagAlertDeviceKey', () {
    DeviceStatus status({String? hw, int? node, String id = 'ble-id'}) =>
        DeviceStatus(
          deviceId: id,
          canonicalHardwareId: hw,
          nodeId: node,
          paired: true,
          activated: true,
          connected: false,
        );

    test('is the hardware id, else the device id, and never the node id', () {
      expect(tagAlertDeviceKey(status(hw: ' HW-1 ', node: 7)), 'HW-1');
      expect(tagAlertDeviceKey(status(hw: ' ', node: 7)), 'ble-id');
      expect(tagAlertDeviceKey(status(node: 7)), 'ble-id');
      expect(tagAlertDeviceKey(status()), 'ble-id');
    });

    test(
      'does not change when the node id arrives (iOS pair-time hydrate)',
      () {
        final before = status(id: 'UUID-1');
        final after = status(id: 'UUID-1', node: 0x12345678);
        expect(tagAlertDeviceKey(after), tagAlertDeviceKey(before));
      },
    );

    test('tagAlertKeyFor matches the status rule', () {
      expect(tagAlertKeyFor(canonicalHardwareId: 'AA', deviceId: 'x'), 'AA');
      expect(tagAlertKeyFor(canonicalHardwareId: null, deviceId: 'x'), 'x');
      expect(tagAlertKeyFor(canonicalHardwareId: '  ', deviceId: 'x'), 'x');
    });
  });
}
