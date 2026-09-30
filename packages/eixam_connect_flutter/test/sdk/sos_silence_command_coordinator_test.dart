import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/provisioning/provisioning_command_result.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_silence_command_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('SOS_SILENCE encodes exactly one byte 0x09 on CMD', () {
    final command = EixamDeviceCommand.sosSilence();

    expect(command.opcode, 0x09);
    expect(command.encode(), <int>[0x09]);
    expect(command.usesCmdCharacteristic, isTrue);
  });

  test('accepts OK as silence applied', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    final result = harness.coordinator.run(write: harness.recordWrite);
    harness.emit(opcode: 0x09, result: 0x00);

    expect(await result, SosSilenceOutcome.silenceApplied);
    expect(harness.writes, 1);
  });

  test('accepts OK_NOCHANGE as already silent', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    final result = harness.coordinator.run(write: harness.recordWrite);
    harness.emit(opcode: 0x09, result: 0x01);

    expect(await result, SosSilenceOutcome.alreadySilent);
  });

  test('ignores a mismatched opcode before accepting 0x09', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    final result = harness.coordinator.run(write: harness.recordWrite);
    harness.emit(opcode: 0x20, result: 0x00);
    await pumpEventQueue();
    harness.emit(opcode: 0x09, result: 0x00);

    expect(await result, SosSilenceOutcome.silenceApplied);
  });

  test('reject result fails the typed operation', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    final result = harness.coordinator.run(write: harness.recordWrite);
    harness.emit(opcode: 0x09, result: 0x02);

    await expectLater(
      result,
      throwsA(
        isA<DeviceException>().having(
          (error) => error.code,
          'code',
          'E_DEVICE_SOS_SILENCE_REJECTED',
        ),
      ),
    );
  });

  test('duplicate callers join one in-flight command', () async {
    final harness = _Harness();
    addTearDown(harness.dispose);

    final first = harness.coordinator.run(write: harness.recordWrite);
    final second = harness.coordinator.run(write: harness.recordWrite);
    harness.emit(opcode: 0x09, result: 0x01);

    expect(await first, SosSilenceOutcome.alreadySilent);
    expect(await second, SosSilenceOutcome.alreadySilent);
    expect(harness.writes, 1);
  });
}

final class _Harness {
  _Harness() {
    coordinator = SosSilenceCommandCoordinator(
      incomingEvents: _events.stream,
      timeout: const Duration(milliseconds: 100),
    );
  }

  final StreamController<BleIncomingEvent> _events =
      StreamController<BleIncomingEvent>.broadcast();

  late final SosSilenceCommandCoordinator coordinator;
  int writes = 0;

  Future<void> recordWrite() async {
    writes++;
  }

  void emit({required int opcode, required int result}) {
    final payload = <int>[0xE9, 0x7A, 0x01, opcode, result, 0x00];
    _events.add(
      BleIncomingEvent(
        deviceId: 'device-1',
        type: BleIncomingEventType.provisioningCommandResult,
        channel: EixamBleChannel.tel,
        payload: payload,
        payloadHex: EixamBleProtocol.hex(payload),
        source: DeviceSosTransitionSource.device,
        receivedAt: DateTime.utc(2026, 9, 30),
        provisioningCommandResult: ProvisioningCommandResult.tryParse(payload),
      ),
    );
  }

  Future<void> dispose() async {
    await coordinator.dispose();
    await _events.close();
  }
}
