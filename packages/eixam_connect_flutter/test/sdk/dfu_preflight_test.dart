import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_adapter_state.dart';
import 'package:eixam_connect_flutter/src/sdk/dfu_preflight.dart';
import 'package:flutter_test/flutter_test.dart';

Future<PhoneBatteryReading?> battery(int? percent, bool? charging) async =>
    PhoneBatteryReading(percent: percent, charging: charging);

Future<void> expectBlocked(
  Future<Object?> Function() action,
  DfuPreflightFailure failure,
) async {
  await expectLater(
    action(),
    throwsA(
      isA<FirmwareUpdateException>().having(
        (e) => e.code,
        'code',
        failure.name,
      ),
    ),
  );
}

void main() {
  group('runDfuPreflight', () {
    test('passes with no warnings when everything is read and fine', () async {
      final warnings = await runDfuPreflight(
        adapterState: () async => BleAdapterState.poweredOn,
        appForeground: () => true,
        screenAwake: () async => true,
        phoneBattery: () => battery(80, false),
      );
      expect(warnings, isEmpty);
    });

    test('Bluetooth off blocks', () async {
      await expectBlocked(
        () => runDfuPreflight(
          adapterState: () async => BleAdapterState.poweredOff,
        ),
        DfuPreflightFailure.bluetoothOff,
      );
    });

    test('app in background blocks', () async {
      await expectBlocked(
        () => runDfuPreflight(appForeground: () => false),
        DfuPreflightFailure.appNotForeground,
      );
    });

    test('screen off blocks', () async {
      await expectBlocked(
        () => runDfuPreflight(screenAwake: () async => false),
        DfuPreflightFailure.screenNotAwake,
      );
    });

    test('phone battery below threshold blocks, boundary passes', () async {
      await expectBlocked(
        () => runDfuPreflight(phoneBattery: () => battery(29, false)),
        DfuPreflightFailure.phoneBatteryLow,
      );
      expect(
        await runDfuPreflight(phoneBattery: () => battery(30, false)),
        isEmpty,
      );
    });

    test('charging lowers the threshold to its own boundary', () async {
      await expectBlocked(
        () => runDfuPreflight(phoneBattery: () => battery(9, true)),
        DfuPreflightFailure.phoneBatteryLow,
      );
      expect(
        await runDfuPreflight(phoneBattery: () => battery(10, true)),
        isEmpty,
      );
      // 20 % passes only because the phone is charging.
      expect(
        await runDfuPreflight(phoneBattery: () => battery(20, true)),
        isEmpty,
      );
      await expectBlocked(
        () => runDfuPreflight(phoneBattery: () => battery(20, false)),
        DfuPreflightFailure.phoneBatteryLow,
      );
    });

    test('unreadable values are warnings and never block', () async {
      final warnings = await runDfuPreflight(
        adapterState: () async => BleAdapterState.unknown,
        appForeground: () => null,
        screenAwake: () async => null,
        phoneBattery: () async => null,
      );
      expect(
        warnings,
        containsAll(<DfuPreflightWarning>[
          DfuPreflightWarning.bluetoothStateUnknown,
          DfuPreflightWarning.appForegroundUnknown,
          DfuPreflightWarning.screenStateUnknown,
          DfuPreflightWarning.phoneBatteryUnknown,
        ]),
      );
    });

    test(
      'phone level known but charging unknown warns and is lenient',
      () async {
        final warnings = await runDfuPreflight(
          phoneBattery: () => battery(20, null),
        );
        expect(warnings, [DfuPreflightWarning.phoneChargingUnknown]);
      },
    );

    test('level unreadable with charging known still only warns', () async {
      final warnings = await runDfuPreflight(
        phoneBattery: () => battery(null, true),
      );
      expect(warnings, [DfuPreflightWarning.phoneBatteryUnknown]);
    });
  });
}
