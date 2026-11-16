import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('TagAlertSettings', () {
    test('defaults are battery on and 5 minutes', () {
      final settings = TagAlertSettings(deviceId: 'tag-1');
      expect(settings.batteryAlerts, isTrue);
      expect(settings.disconnectAfter, const Duration(minutes: 5));
    });

    test('accepts exactly never, 5, 15, 30 and 60 minutes', () {
      for (final value in <Duration?>[
        null,
        const Duration(minutes: 5),
        const Duration(minutes: 15),
        const Duration(minutes: 30),
        const Duration(minutes: 60),
      ]) {
        expect(
          TagAlertSettings(
            deviceId: 'tag-1',
            disconnectAfter: value,
          ).disconnectAfter,
          value,
        );
      }
    });

    test('rejects any other duration and empty device ids', () {
      for (final minutes in <int>[0, 1, 4, 6, 10, 45, 61, 120]) {
        expect(
          () => TagAlertSettings(
            deviceId: 'tag-1',
            disconnectAfter: Duration(minutes: minutes),
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => TagAlertSettings(
          deviceId: 'tag-1',
          disconnectAfter: const Duration(minutes: 5, seconds: 1),
        ),
        throwsArgumentError,
      );
      expect(() => TagAlertSettings(deviceId: ' '), throwsArgumentError);
    });

    test('copyWith keeps, changes and clears disconnectAfter', () {
      final base = TagAlertSettings(deviceId: 'tag-1');
      expect(
        base.copyWith(batteryAlerts: false).disconnectAfter,
        const Duration(minutes: 5),
      );
      expect(base.copyWith(disconnectAfter: null).disconnectAfter, isNull);
      expect(
        base
            .copyWith(disconnectAfter: const Duration(minutes: 30))
            .disconnectAfter,
        const Duration(minutes: 30),
      );
      expect(
        () => base.copyWith(disconnectAfter: const Duration(minutes: 7)),
        throwsArgumentError,
      );
    });

    test('equality and hashCode', () {
      final a = TagAlertSettings(deviceId: 'tag-1', disconnectAfter: null);
      final b = TagAlertSettings(deviceId: 'tag-1', disconnectAfter: null);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(TagAlertSettings(deviceId: 'tag-1')));
    });

    test('JSON round-trip, including never', () {
      for (final value in TagAlertSettings.allowedDisconnectAfter) {
        final original = TagAlertSettings(
          deviceId: 'tag-1',
          batteryAlerts: false,
          disconnectAfter: value,
        );
        expect(TagAlertSettings.fromJson(original.toJson()), original);
      }
      expect(TagAlertSettings(deviceId: 'a').toJson()['v'], 1);
    });

    test('fromJson rejects malformed, newer and out-of-set data', () {
      final good = TagAlertSettings(deviceId: 'tag-1').toJson();
      final bad = <Object?>[
        null,
        'x',
        <String, Object?>{...good, 'v': 2},
        <String, Object?>{...good, 'v': '1'},
        <String, Object?>{...good}..remove('v'),
        <String, Object?>{...good, 'deviceId': ''},
        <String, Object?>{...good, 'deviceId': 3},
        <String, Object?>{...good, 'batteryAlerts': 'yes'},
        <String, Object?>{...good, 'disconnectAfterMinutes': 7},
        <String, Object?>{...good, 'disconnectAfterMinutes': '5'},
        <String, Object?>{...good}..remove('disconnectAfterMinutes'),
      ];
      for (final json in bad) {
        expect(
          () => TagAlertSettings.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });
  });
}
