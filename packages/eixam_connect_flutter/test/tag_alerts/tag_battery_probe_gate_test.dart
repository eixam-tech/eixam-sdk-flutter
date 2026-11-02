import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_battery_probe_gate.dart';
import 'package:flutter_test/flutter_test.dart';

bool blocked({
  bool provisioningBusy = false,
  bool firmwareUpdateActive = false,
  bool migrationOwnsBle = false,
  bool preSosActive = false,
  SosLifecycleStage sosStage = SosLifecycleStage.idle,
  DeviceSosState deviceSosState = DeviceSosState.inactive,
}) => TagBatteryProbeGate.isBlocked(
  provisioningBusy: provisioningBusy,
  firmwareUpdateActive: firmwareUpdateActive,
  migrationOwnsBle: migrationOwnsBle,
  preSosActive: preSosActive,
  sosStage: sosStage,
  deviceSosState: deviceSosState,
);

void main() {
  test('an idle TAG may be probed', () => expect(blocked(), isFalse));

  test('provisioning, firmware update, migration and pre-SOS block', () {
    expect(blocked(provisioningBusy: true), isTrue);
    expect(blocked(firmwareUpdateActive: true), isTrue);
    expect(blocked(migrationOwnsBle: true), isTrue);
    expect(blocked(preSosActive: true), isTrue);
  });

  test('every non-terminal SOS lifecycle stage blocks', () {
    const free = {
      SosLifecycleStage.idle,
      SosLifecycleStage.cancelled,
      SosLifecycleStage.resolved,
      SosLifecycleStage.activationFailed,
      SosLifecycleStage.cancellationFailed,
    };
    for (final stage in SosLifecycleStage.values) {
      expect(blocked(sosStage: stage), !free.contains(stage), reason: '$stage');
    }
  });

  test('every non-quiet device SOS state blocks (unknown fails safe)', () {
    const free = {DeviceSosState.inactive, DeviceSosState.resolved};
    for (final state in DeviceSosState.values) {
      expect(
        blocked(deviceSosState: state),
        !free.contains(state),
        reason: '$state',
      );
    }
  });
}
