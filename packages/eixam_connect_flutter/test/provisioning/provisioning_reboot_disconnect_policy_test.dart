import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/provisioning/device_provisioning_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DeviceStatus status(bool connected) => DeviceStatus(
        deviceId: 'device-1',
        paired: true,
        activated: false,
        connected: connected,
      );

  test('premature reboot disconnect is rejected', () async {
    final statuses = StreamController<DeviceStatus>.broadcast();
    var now = DateTime.utc(2026);
    final policy = ProvisioningRebootDisconnectPolicy(
      minimumDelay: const Duration(milliseconds: 900),
      maximumDelay: const Duration(seconds: 5),
      clock: () => now,
    );
    final diagnostics = <String>[];
    final result = policy.writeAndAwait(
      writeReboot: () async {
        Timer(Duration.zero, () {
          now = now.add(const Duration(milliseconds: 899));
          statuses.add(status(false));
        });
      },
      statuses: statuses.stream,
      diagnosticLog: diagnostics.add,
    );
    await expectLater(result, throwsA(isA<ProvisioningRebootException>()));
    expect(
      diagnostics,
      containsAllInOrder(<String>[
        'PROVISIONING_REBOOT command_write_started=true',
        'PROVISIONING_REBOOT command_write_completed=true',
        'PROVISIONING_REBOOT disconnect_observed=true',
        'PROVISIONING_REBOOT disconnect_timing_bucket=too_early',
      ]),
    );
    await statuses.close();
  });

  test('expected and lower-bound reboot disconnects are accepted', () async {
    for (final delay in <Duration>[
      const Duration(milliseconds: 900),
      const Duration(milliseconds: 1500),
    ]) {
      final statuses = StreamController<DeviceStatus>.broadcast();
      var now = DateTime.utc(2026);
      final policy = ProvisioningRebootDisconnectPolicy(
        clock: () => now,
      );
      final result = policy.writeAndAwait(
        writeReboot: () async {
          Timer(Duration.zero, () {
            now = now.add(delay);
            statuses.add(status(false));
          });
        },
        statuses: statuses.stream,
      );
      await result;
      await statuses.close();
    }
  });

  test('disconnect during the 0x22 write is accepted when past the floor',
      () async {
    final statuses = StreamController<DeviceStatus>.broadcast();
    var now = DateTime.utc(2026);
    final policy = ProvisioningRebootDisconnectPolicy(
      clock: () => now,
    );
    final result = policy.writeAndAwait(
      writeReboot: () async {
        now = now.add(const Duration(milliseconds: 1500));
        statuses.add(status(false));
      },
      statuses: statuses.stream,
    );
    await result;
    await statuses.close();
  });

  test('missing reboot disconnect is a typed reboot failure', () async {
    final statuses = StreamController<DeviceStatus>.broadcast();
    final policy = ProvisioningRebootDisconnectPolicy(
      minimumDelay: Duration.zero,
      maximumDelay: const Duration(milliseconds: 10),
    );
    final diagnostics = <String>[];
    await expectLater(
      policy.writeAndAwait(
        writeReboot: () async {},
        statuses: statuses.stream,
        diagnosticLog: diagnostics.add,
      ),
      throwsA(isA<ProvisioningRebootException>()),
    );
    expect(
      diagnostics,
      contains('PROVISIONING_REBOOT disconnect_timing_bucket=timeout'),
    );
    await statuses.close();
  });

  test('timeout is success when raw GATT is already down', () async {
    final statuses = StreamController<DeviceStatus>.broadcast();
    final policy = ProvisioningRebootDisconnectPolicy(
      minimumDelay: Duration.zero,
      maximumDelay: const Duration(milliseconds: 10),
    );
    final diagnostics = <String>[];
    await policy.writeAndAwait(
      writeReboot: () async {},
      statuses: statuses.stream,
      alreadyDisconnected: () => true,
      diagnosticLog: diagnostics.add,
    );
    expect(
      diagnostics,
      contains('PROVISIONING_REBOOT disconnect_timing_bucket=valid_unobserved'),
    );
    expect(
      diagnostics,
      isNot(contains('PROVISIONING_REBOOT disconnect_timing_bucket=timeout')),
    );
    await statuses.close();
  });

  test('lost reboot write ACK is success when disconnect is in window',
      () async {
    final statuses = StreamController<DeviceStatus>.broadcast();
    var now = DateTime.utc(2026);
    final policy = ProvisioningRebootDisconnectPolicy(
      clock: () => now,
    );
    final diagnostics = <String>[];
    final result = policy.writeAndAwait(
      writeReboot: () async {
        Timer(Duration.zero, () {
          now = now.add(const Duration(milliseconds: 1500));
          statuses.add(status(false));
        });
        throw const DeviceException(
          'E_BLE_DEVICE_DISCONNECTED',
          'E_BLE_DEVICE_DISCONNECTED',
        );
      },
      statuses: statuses.stream,
      diagnosticLog: diagnostics.add,
    );
    await result;
    expect(
      diagnostics,
      containsAllInOrder(<String>[
        'PROVISIONING_REBOOT command_write_started=true',
        'PROVISIONING_REBOOT command_write_failed=true',
        'PROVISIONING_REBOOT disconnect_observed=true',
        'PROVISIONING_REBOOT disconnect_timing_bucket=valid',
      ]),
    );
    await statuses.close();
  });
}
