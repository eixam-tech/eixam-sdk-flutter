import 'dart:async';
import 'dart:math';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_debug_registry.dart';
import 'ble_scan_result.dart';
import 'eixam_ble_command.dart';
import 'eixam_ble_notification.dart';
import 'eixam_ble_protocol.dart';

class MockBleClient implements BleClient {
  final StreamController<BleAdapterState> _adapterController =
      StreamController<BleAdapterState>.broadcast();
  final Map<String, StreamController<EixamBleNotification>> _notifyControllers =
      <String, StreamController<EixamBleNotification>>{};
  final Map<String, StreamController<bool>> _connectionControllers =
      <String, StreamController<bool>>{};
  final Random _random = Random();
  BleAdapterState _adapterState = BleAdapterState.poweredOn;
  final Set<String> _connectedDeviceIds = <String>{};
  final List<EixamDeviceCommand> writtenCommands = <EixamDeviceCommand>[];
  List<int> runtimeStatusPayload = <int>[
    0xE9,
    0x78,
    0x01,
    0x02,
    0x03,
    0x07,
    0x1F,
    0x34,
    0x12,
    88,
    0x3C,
    0x00,
  ];

  static const String demoDeviceId = 'ble-demo-r1';
  static const String demoCanonicalHardwareId = 'CF:82:00:00:00:01';

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
        canonicalHardwareId: demoCanonicalHardwareId,
        name: 'EIXAM R1 Demo',
        rssi: -42 - _random.nextInt(20),
        connectable: true,
        advertisedServiceUuids: const <String>[EixamBleProtocol.serviceUuid],
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
    _connectionController(deviceId).add(true);
    BleDebugRegistry.instance.update(
      selectedDeviceId: deviceId,
      eixamServiceFound: deviceId == demoDeviceId,
      telFound: deviceId == demoDeviceId,
      sosFound: deviceId == demoDeviceId,
      inetFound: deviceId == demoDeviceId,
      cmdFound: deviceId == demoDeviceId,
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
      discoveredServices: const <String>[EixamBleProtocol.serviceUuid],
    );
    BleDebugRegistry.instance.registerCommandWriter(
      (command) => writeDeviceCommand(deviceId, command),
    );
    BleDebugRegistry.instance.recordEvent('Mock BLE connected to $deviceId');
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _connectedDeviceIds.remove(deviceId);
    _connectionController(deviceId).add(false);
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
  Stream<bool> watchConnection(String deviceId) =>
      _connectionController(deviceId).stream;

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
  Future<void> writeDeviceCommand(
    String deviceId,
    EixamDeviceCommand command,
  ) async {
    if (!_connectedDeviceIds.contains(deviceId)) {
      throw Exception('Device not connected: $deviceId');
    }
    final data = command.encode();
    if (data.isEmpty) {
      throw Exception('Command payload cannot be empty');
    }

    BleDebugRegistry.instance.update(
      lastCommandSent: command.encodedHex,
      lastWriteTargetCharacteristic: command.targetCharacteristicUuid,
      lastWriteResult: 'SUCCESS',
      lastWriteAt: DateTime.now(),
      lastWriteError: null,
    );
    BleDebugRegistry.instance.recordEvent(
      'Mock command written to $deviceId (${command.label})',
    );
    writtenCommands.add(command);
    _emitMockPackets(deviceId, command);
  }

  @override
  Future<Stream<EixamBleNotification>> subscribeEixamNotifications(
    String deviceId,
  ) async {
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
    final controller = _notifyControllers[deviceId] ??
        StreamController<EixamBleNotification>.broadcast();
    _notifyControllers[deviceId] = controller;
    return controller.stream.map((notification) {
      BleDebugRegistry.instance.update(
        lastPacketReceived: notification.payloadHex,
      );
      return notification;
    });
  }

  @override
  Future<bool> isEixamCompatible(String deviceId) async {
    return deviceId == demoDeviceId;
  }

  Future<void> setAdapterState(BleAdapterState state) async {
    _adapterState = state;
    BleDebugRegistry.instance.update(adapterState: state);
    BleDebugRegistry.instance.recordEvent('Mock BLE adapter changed to $state');
    _adapterController.add(state);
    if (state != BleAdapterState.poweredOn) {
      for (final deviceId in _connectedDeviceIds.toList()) {
        _connectionController(deviceId).add(false);
      }
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
    for (final controller in _connectionControllers.values) {
      await controller.close();
    }
    await _adapterController.close();
  }

  StreamController<bool> _connectionController(String deviceId) {
    return _connectionControllers.putIfAbsent(
      deviceId,
      () => StreamController<bool>.broadcast(),
    );
  }

  void _emitMockPackets(String deviceId, EixamDeviceCommand command) {
    final controller = _notifyControllers[deviceId];
    if (controller == null || controller.isClosed) {
      return;
    }

    void emit(EixamBleChannel channel, List<int> payload) {
      controller.add(
        EixamBleNotification(
          channel: channel,
          payload: payload,
          receivedAt: DateTime.now(),
        ),
      );
    }

    switch (command.opcode) {
      case 0x01:
        if (command.bytes.length == 5) {
          final targetNodeId = command.bytes[0] | (command.bytes[1] << 8);
          emit(EixamBleChannel.tel, <int>[
            targetNodeId & 0xFF,
            (targetNodeId >> 8) & 0xFF,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x01,
            0x21,
          ]);
          return;
        }
        emit(EixamBleChannel.tel, <int>[
          0xA8,
          0x1A,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x21,
        ]);
        return;
      case 0x05:
        if (command.bytes.length == 5) {
          final targetNodeId = command.bytes[0] | (command.bytes[1] << 8);
          final rescueNodeId = command.bytes[2] | (command.bytes[3] << 8);
          emit(EixamBleChannel.tel, <int>[
            rescueNodeId & 0xFF,
            (rescueNodeId >> 8) & 0xFF,
            targetNodeId & 0xFF,
            (targetNodeId >> 8) & 0xFF,
            0x85,
            0x02,
            0x03,
            0x03,
            0x01,
            0x03,
          ]);
          return;
        }
        emit(EixamBleChannel.sos, <int>[
          0xA8,
          0x1A,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x02,
          0x80,
        ]);
        return;
      case 0x02:
      case 0x03:
      case 0x04:
        if (command.bytes.length == 5) {
          return;
        }
        emit(EixamBleChannel.tel, <int>[
          0xA8,
          0x1A,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x21,
        ]);
        return;
      case 0x06:
        emit(EixamBleChannel.sos, <int>[
          0xA8,
          0x1A,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x00,
          0x01,
          0x40,
        ]);
        return;
      case 0x23:
        emit(EixamBleChannel.tel, runtimeStatusPayload);
        return;
      default:
        return;
    }
  }
}
