import 'dart:async';
import 'dart:math';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_debug_registry.dart';
import 'ble_scan_result.dart';

/// Demo BLE client used by the starter project.
///
/// It behaves like a tiny BLE environment with one discoverable EIXAM device so
/// the rest of the SDK can evolve before integrating a real Bluetooth library.
class MockBleClient implements BleClient {
  final StreamController<BleAdapterState> _adapterController =
      StreamController<BleAdapterState>.broadcast();
  final Map<String, StreamController<List<int>>> _notifyControllers =
      <String, StreamController<List<int>>>{};
  final Random _random = Random();
  BleAdapterState _adapterState = BleAdapterState.poweredOn;
  final Set<String> _connectedDeviceIds = <String>{};

  static const String demoDeviceId = 'ble-demo-r1';

  @override
  Future<void> initialize() async {
    BleDebugRegistry.instance.update(adapterState: _adapterState);
    BleDebugRegistry.instance.registerScanner(scan);
    BleDebugRegistry.instance.recordEvent(
      'Mock BLE client initialized with adapter state $_adapterState',
    );
    _adapterController.add(_adapterState);
  }

  @override
  Future<BleAdapterState> getAdapterState() async => _adapterState;

  @override
  Stream<BleAdapterState> watchAdapterState() => _adapterController.stream;

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    if (_adapterState != BleAdapterState.poweredOn) {
      BleDebugRegistry.instance.recordEvent(
        'Mock BLE scan skipped because adapter is $_adapterState',
      );
      return const <BleScanResult>[];
    }

    final results = <BleScanResult>[
      BleScanResult(
        deviceId: demoDeviceId,
        name: 'EIXAM R1 Demo',
        rssi: -42 - _random.nextInt(20),
        connectable: true,
        advertisedServiceUuids: const <String>[
          '6ba1b218-15a8-461f-9fa8-5dcae273ea00',
        ],
        discoveredAt: DateTime.now(),
      ),
    ];
    BleDebugRegistry.instance.recordEvent(
      'Mock BLE scan found ${results.length} candidate(s)',
    );
    return results;
  }

  @override
  Future<void> connect(String deviceId) async {
    if (_adapterState != BleAdapterState.poweredOn) return;
    _connectedDeviceIds.add(deviceId);
    BleDebugRegistry.instance.update(
      selectedDeviceId: deviceId,
      eixamServiceFound: deviceId == demoDeviceId,
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
      discoveredServices: const <String>['mock-eixam-service'],
    );
    BleDebugRegistry.instance.registerCommandWriter(
      (data) => writeCommand(deviceId, data),
    );
    BleDebugRegistry.instance.recordEvent('Mock BLE connected to $deviceId');
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connectedDeviceIds.remove(deviceId);
    await _notifyControllers.remove(deviceId)?.close();
    BleDebugRegistry.instance.update(
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
      commandWriterReady: false,
    );
    BleDebugRegistry.instance.clearCommandWriter();
    BleDebugRegistry.instance.recordEvent(
      'Mock BLE disconnected from $deviceId',
    );
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
    BleDebugRegistry.instance.update(
      lastCommandSent: data
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(' '),
      lastWriteTargetCharacteristic: data.length <= 4
          ? '6ba1b218-15a8-461f-9fa8-5dcae273ea03'
          : '6ba1b218-15a8-461f-9fa8-5dcae273ea04',
      lastWriteResult: 'SUCCESS',
      lastWriteAt: DateTime.now(),
      lastWriteError: null,
    );
    BleDebugRegistry.instance.recordEvent(
      'Mock command written to $deviceId (${data.length} bytes)',
    );
    _emitMockSosPacket(deviceId, data.first);
  }

  @override
  Future<Stream<List<int>>> subscribeNotifications(String deviceId) async {
    return subscribeSosNotifications(deviceId);
  }

  @override
  Future<Stream<List<int>>> subscribeSosNotifications(String deviceId) async {
    if (!_connectedDeviceIds.contains(deviceId)) {
      throw Exception('Device not connected: $deviceId');
    }

    BleDebugRegistry.instance.update(
      telNotifySubscribed: true,
      sosNotifySubscribed: true,
    );
    BleDebugRegistry.instance.recordEvent(
      'Mock notify subscription enabled for $deviceId',
    );
    final controller =
        _notifyControllers[deviceId] ??
        StreamController<List<int>>.broadcast();
    _notifyControllers[deviceId] = controller;
    return controller.stream.map((packet) {
      BleDebugRegistry.instance.update(
        lastPacketReceived: packet
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(' '),
      );
      return packet;
    });
  }

  @override
  Future<bool> isEixamCompatible(String deviceId) async {
    return deviceId == demoDeviceId;
  }

  /// Allows tests or future demo screens to simulate a Bluetooth adapter change.
  Future<void> setAdapterState(BleAdapterState state) async {
    _adapterState = state;
    BleDebugRegistry.instance.update(adapterState: state);
    BleDebugRegistry.instance.recordEvent('Mock BLE adapter changed to $state');
    _adapterController.add(state);
    if (state != BleAdapterState.poweredOn) {
      _connectedDeviceIds.clear();
      BleDebugRegistry.instance.clearCommandWriter();
      BleDebugRegistry.instance.update(
        telNotifySubscribed: false,
        sosNotifySubscribed: false,
        commandWriterReady: false,
      );
    }
  }

  Future<void> dispose() async {
    for (final controller in _notifyControllers.values) {
      await controller.close();
    }
    await _adapterController.close();
  }

  void _emitMockSosPacket(String deviceId, int opcode) {
    final controller = _notifyControllers[deviceId];
    if (controller == null || controller.isClosed) {
      return;
    }

    const nodeId = <int>[0xA8, 0x1A, 0x80, 0x00];
    switch (opcode) {
      case 0x04:
        controller.add(<int>[...nodeId, 0x08, 0x00, 0x00, 0x00, 0x80, 0x12]);
        return;
      case 0x05:
        controller.add(<int>[...nodeId, 0x08, 0x00, 0x00, 0x00, 0x80, 0x42]);
        return;
      case 0x06:
        controller.add(<int>[...nodeId, 0x08, 0x00, 0x00, 0x00, 0x80, 0x32]);
        return;
      case 0x07:
      case 0x08:
        controller.add(<int>[...nodeId, 0x08, 0x00, 0x00, 0x00, 0x80, 0x52]);
        return;
      default:
        return;
    }
  }
}
