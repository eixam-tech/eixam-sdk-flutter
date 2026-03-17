import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_scan_result.dart';

class RealBleClient implements BleClient {
  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, List<BluetoothService>> _servicesCache = {};

  // PLACEHOLDERS fins tenir UUIDs reals del firmware
  static final Guid commandServiceUuid =
      Guid('0000FFF0-0000-1000-8000-00805F9B34FB');
  static final Guid commandWriteCharUuid =
      Guid('0000FFF1-0000-1000-8000-00805F9B34FB');
  static final Guid notifyCharUuid =
      Guid('0000FFF2-0000-1000-8000-00805F9B34FB');

  static final Guid batteryServiceUuid =
      Guid('0000180F-0000-1000-8000-00805F9B34FB');
  static final Guid batteryLevelCharUuid =
      Guid('00002A19-0000-1000-8000-00805F9B34FB');
  static final Guid deviceInfoServiceUuid =
      Guid('0000180A-0000-1000-8000-00805F9B34FB');
  static final Guid firmwareRevisionCharUuid =
      Guid('00002A26-0000-1000-8000-00805F9B34FB');

    @override
    Future<void> initialize() async {
        try {
            if (await FlutterBluePlus.isSupported == false) {
             throw Exception('BLE no suportat en aquest dispositiu');
            }
        } catch (e) {
            rethrow;
        }
    }

  @override
  Future<BleAdapterState> getAdapterState() async {
    final state = FlutterBluePlus.adapterStateNow;
    return _mapAdapterState(state);
  }

  @override
  Stream<BleAdapterState> watchAdapterState() {
    return FlutterBluePlus.adapterState.map(_mapAdapterState);
  }

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final results = <BleScanResult>[];

    await FlutterBluePlus.startScan(timeout: timeout);

    final sub = FlutterBluePlus.scanResults.listen((scanResults) {
      for (final r in scanResults) {
        final id = r.device.remoteId.str;
        _devices[id] = r.device;

        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : (r.device.platformName.isNotEmpty ? r.device.platformName : 'Unknown');

        results.removeWhere((e) => e.deviceId == id);
        results.add(
          BleScanResult(
            deviceId: id,
            name: name,
            rssi: r.rssi,
            connectable: r.advertisementData.connectable,
            discoveredAt: DateTime.now(),
          ),
        );
      }
    });

    await Future.delayed(timeout);
    await FlutterBluePlus.stopScan();
    await sub.cancel();

    return results;
  }

  @override
  Future<void> connect(String deviceId) async {
    final device = _devices[deviceId];
    if (device == null) {
      throw Exception('Dispositiu no trobat: $deviceId');
    }

    await device.connect(timeout: const Duration(seconds: 10));
    _servicesCache[deviceId] = await device.discoverServices();
  }

  @override
  Future<void> disconnect(String deviceId) async {
    final device = _devices[deviceId];
    if (device != null) {
      await device.disconnect();
    }
  }

  @override
  Future<bool> isConnected(String deviceId) async {
    final device = _devices[deviceId];
    if (device == null) return false;
    return device.isConnected;
  }

  @override
  Future<int?> readBatteryLevel(String deviceId) async {
    final c = await _findCharacteristic(
      deviceId,
      batteryServiceUuid,
      batteryLevelCharUuid,
    );
    if (c == null) return null;

    final data = await c.read();
    if (data.isEmpty) return null;
    return data.first;
  }

  @override
  Future<int?> readSignalQuality(String deviceId) async {
    return null;
  }

  @override
  Future<String?> readFirmwareVersion(String deviceId) async {
    final c = await _findCharacteristic(
      deviceId,
      deviceInfoServiceUuid,
      firmwareRevisionCharUuid,
    );
    if (c == null) return null;

    final data = await c.read();
    if (data.isEmpty) return null;
    return String.fromCharCodes(data);
  }

  @override
  Future<void> writeCommand(String deviceId, List<int> data) async {
    final c = await _findCharacteristic(
      deviceId,
      commandServiceUuid,
      commandWriteCharUuid,
    );

    if (c == null) {
      throw Exception('Characteristic d’escriptura no trobada');
    }

    await c.write(data, withoutResponse: false);
  }

  @override
  Future<Stream<List<int>>> subscribeNotifications(String deviceId) async {
    final c = await _findCharacteristic(
      deviceId,
      commandServiceUuid,
      notifyCharUuid,
    );

    if (c == null) {
      throw Exception('Characteristic de notificacions no trobada');
    }

    await c.setNotifyValue(true);
    return c.onValueReceived.map((value) => value.toList());
  }

  Future<List<BluetoothService>> _services(String deviceId) async {
    if (_servicesCache.containsKey(deviceId)) {
      return _servicesCache[deviceId]!;
    }

    final device = _devices[deviceId];
    if (device == null) return [];

    final services = await device.discoverServices();
    _servicesCache[deviceId] = services;
    return services;
  }

  Future<BluetoothCharacteristic?> _findCharacteristic(
    String deviceId,
    Guid serviceUuid,
    Guid characteristicUuid,
  ) async {
    final services = await _services(deviceId);

    for (final s in services) {
      if (s.uuid == serviceUuid) {
        for (final c in s.characteristics) {
          if (c.uuid == characteristicUuid) {
            return c;
          }
        }
      }
    }
    return null;
  }

  BleAdapterState _mapAdapterState(BluetoothAdapterState state) {
    switch (state) {
    case BluetoothAdapterState.on:
      return BleAdapterState.poweredOn;
    case BluetoothAdapterState.off:
      return BleAdapterState.poweredOff;
    case BluetoothAdapterState.unauthorized:
      return BleAdapterState.unauthorized;
    case BluetoothAdapterState.unavailable:
      return BleAdapterState.unsupported;
    default:
      return BleAdapterState.unknown;
    }
  }
}