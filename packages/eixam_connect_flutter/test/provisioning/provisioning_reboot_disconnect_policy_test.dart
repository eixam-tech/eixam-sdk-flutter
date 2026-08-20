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
}
