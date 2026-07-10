import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_state.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public BLE scan result does not expose advertised service UUIDs', () {
    final internal = BleScanResult(
      deviceId: 'device-1',
      canonicalHardwareId: 'hardware-1',
      name: 'Sentinel',
      rssi: -61,
      connectable: true,
      advertisedServiceUuids: const <String>[EixamBleProtocol.serviceUuid],
      discoveredAt: DateTime.utc(2026, 1, 1),
    );

    final public = internal.toPublic();

    expect(public, isA<EixamBleScanResult>());
    expect(public.deviceId, 'device-1');
    expect(public.canonicalHardwareId, 'hardware-1');
    expect(public.isEixamDevice, isTrue);
    expect(
      EixamBleScanResult(
        deviceId: public.deviceId,
        canonicalHardwareId: public.canonicalHardwareId,
        name: public.name,
        rssi: public.rssi,
        connectable: public.connectable,
        brandClassification: public.brandClassification,
        isEixamDevice: public.isEixamDevice,
        discoveredAt: public.discoveredAt,
      ),
      isA<EixamBleScanResult>(),
    );
  });

  test('public command-channel readiness is typed and protocol neutral', () {
    const status = BleCommandChannelStatus(
      readiness: BleCommandChannelReadiness.ready,
      hasSelectedDevice: true,
      serviceConnected: true,
      commandWriterReady: true,
    );

    expect(status.isReady, isTrue);
    expect(BleCommandChannelStatus.capabilityLabel, 'command channel');
  });

  test('public BLE diagnostics expose coarse readiness only', () {
    const diagnostics = EixamBleDiagnostics(
      adapterState: 'poweredOn',
      isScanning: false,
      hasSelectedDevice: true,
      eixamServiceDetected: true,
      commandChannelStatus: BleCommandChannelStatus(
        readiness: BleCommandChannelReadiness.ready,
        hasSelectedDevice: true,
        serviceConnected: true,
        commandWriterReady: true,
      ),
    );

    expect(diagnostics.adapterState, 'poweredOn');
    expect(diagnostics.commandChannelStatus.isReady, isTrue);
    expect(
        diagnostics.toString(), isNot(contains(EixamBleProtocol.serviceUuid)));
  });

  test('SDK debug state can be represented by public diagnostics shape', () {
    const state = BleDebugState(
      selectedDeviceId: 'device-1',
      eixamServiceFound: true,
      cmdFound: true,
      commandWriterReady: true,
    );
    final publicStatus = BleCommandChannelStatus(
      readiness: state.cmdFound
          ? BleCommandChannelReadiness.ready
          : BleCommandChannelReadiness.unavailable,
      hasSelectedDevice: state.selectedDeviceId != null,
      serviceConnected: state.eixamServiceFound,
      commandWriterReady: state.commandWriterReady,
    );

    expect(publicStatus.isReady, isTrue);
    expect(publicStatus.serviceConnected, isTrue);
  });
}
