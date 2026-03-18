import 'dart:async';
import 'dart:math';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_scan_result.dart';

/// Demo BLE client used by the starter project.
///
/// It behaves like a tiny BLE environment with one discoverable EIXAM device so
/// the rest of the SDK can evolve before integrating a real Bluetooth library.
class MockBleClient implements BleClient {
  final StreamController<BleAdapterState> _adapterController =
      StreamController<BleAdapterState>.broadcast();
  final Random _random = Random();
  BleAdapterState _adapterState = BleAdapterState.poweredOn;
  final Set<String> _connectedDeviceIds = <String>{};

  static const String demoDeviceId = 'ble-demo-r1';

  @override
  Future<void> initialize() async {
    _adapterController.add(_adapterState);
  }

  @override
  Future<BleAdapterState> getAdapterState() async => _adapterState;

  @override
  Stream<BleAdapterState> watchAdapterState() => _adapterController.stream;

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (_adapterState != BleAdapterState.poweredOn) {
      return const <BleScanResult>[];
    }

    return <BleScanResult>[
      BleScanResult(
        deviceId: demoDeviceId,
        name: 'EIXAM R1 Demo',
        rssi: -42 - _random.nextInt(20),
        connectable: true,
        discoveredAt: DateTime.now(),
      ),
    ];
  }

  @override
  Future<void> connect(String deviceId) async {
    if (_adapterState != BleAdapterState.poweredOn) return;
    _connectedDeviceIds.add(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connectedDeviceIds.remove(deviceId);
  }

  @override
  Future<bool> isConnected(String deviceId) async =>
      _connectedDeviceIds.contains(deviceId);

  @override
  Future<int?> readBatteryLevel(String deviceId) async =>
      _connectedDeviceIds.contains(deviceId) ? 72 + _random.nextInt(18) : null;

  @override
  Future<int?> readSignalQuality(String deviceId) async =>
      _connectedDeviceIds.contains(deviceId) ? 2 + _random.nextInt(3) : null;

  @override
  Future<String?> readFirmwareVersion(String deviceId) async =>
      _connectedDeviceIds.contains(deviceId) ? '2.7.21-mock' : null;

  @override
  Future<void> writeCommand(String deviceId, List<int> data) async {
    if (!_connectedDeviceIds.contains(deviceId)) {
      throw Exception('Device not connected: $deviceId');
    }
    if (data.isEmpty) {
      throw Exception('Command payload cannot be empty');
    }
  }

  @override
  Future<Stream<List<int>>> subscribeNotifications(String deviceId) async {
    if (!_connectedDeviceIds.contains(deviceId)) {
      throw Exception('Device not connected: $deviceId');
    }

    return const Stream<List<int>>.empty();
  }

  @override
  Future<bool> isEixamCompatible(String deviceId) async {
    return _connectedDeviceIds.contains(deviceId);
  }

  /// Allows tests or future demo screens to simulate a Bluetooth adapter change.
  Future<void> setAdapterState(BleAdapterState state) async {
    _adapterState = state;
    _adapterController.add(state);
    if (state != BleAdapterState.poweredOn) {
      _connectedDeviceIds.clear();
    }
  }

  Future<void> dispose() async {
    await _adapterController.close();
  }
}