import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_scan_result.dart';

class RealBleClient implements BleClient {
  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, List<BluetoothService>> _servicesCache = {};

  static final Guid eixamServiceUuid =
      Guid('6ba1b218-15a8-461f-9fa8-5dcae273ea00');

  static final Guid telNotifyCharUuid =
      Guid('6ba1b218-15a8-461f-9fa8-5dcae273ea01');

  static final Guid sosNotifyCharUuid =
      Guid('6ba1b218-15a8-461f-9fa8-5dcae273ea02');

  static final Guid inetWriteCharUuid =
      Guid('6ba1b218-15a8-461f-9fa8-5dcae273ea03');

  static final Guid cmdWriteCharUuid =
      Guid('6ba1b218-15a8-461f-9fa8-5dcae273ea04');

  static final Guid batteryServiceUuid =
      Guid('0000180F-0000-1000-8000-00805F9B34FB');

  static final Guid batteryLevelCharUuid =
      Guid('00002A19-0000-1000-8000-00805F9B34FB');

  static final Guid deviceInfoServiceUuid =
      Guid('0000180A-0000-1000-8000-00805F9B34FB');

  static final Guid firmwareRevisionCharUuid =
      Guid('00002A26-0000-1000-8000-00805F9B34FB');

  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (await FlutterBluePlus.isSupported == false) {
      throw Exception('BLE no suportat en aquest dispositiu');
    }
    _initialized = true;
  }

  @override
  Future<BleAdapterState> getAdapterState() async {
    _ensureInitialized();
    return _mapAdapterState(FlutterBluePlus.adapterStateNow);
  }

  @override
  Stream<BleAdapterState> watchAdapterState() {
    _ensureInitialized();
    return FlutterBluePlus.adapterState.map(_mapAdapterState);
  }

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    _ensureInitialized();

    final Map<String, BleScanResult> deduped = {};

    final sub = FlutterBluePlus.scanResults.listen((scanResults) {
      for (final r in scanResults) {
        final id = r.device.remoteId.str;
        _devices[id] = r.device;

        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : (r.device.platformName.isNotEmpty
                ? r.device.platformName
                : 'Unknown');

        print(
          'BLE scan -> id=$id name="$name" rssi=${r.rssi} '
          'connectable=${r.advertisementData.connectable} '
          'serviceUuids=${r.advertisementData.serviceUuids}',
        );

        if (!r.advertisementData.connectable) {
          continue;
        }

        deduped[id] = BleScanResult(
          deviceId: id,
          name: name,
          rssi: r.rssi,
          connectable: r.advertisementData.connectable,
          discoveredAt: DateTime.now(),
        );
      }
    });

    await FlutterBluePlus.startScan(timeout: timeout);
    await Future.delayed(timeout);
    await FlutterBluePlus.stopScan();
    await sub.cancel();

    final results = deduped.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));

    return results;
  }

  @override
  Future<void> connect(String deviceId) async {
    _ensureInitialized();

    final device = _devices[deviceId];
    if (device == null) {
      throw Exception('Dispositiu no trobat: $deviceId');
    }

    final connectionState = await device.connectionState.first;
    if (connectionState != BluetoothConnectionState.connected) {
      await device.connect(timeout: const Duration(seconds: 10));
    }

    final services = await device.discoverServices();
    _servicesCache[deviceId] = services;

    print('BLE connect -> deviceId=$deviceId services=${services.length}');
    for (final s in services) {
      print('Service: ${s.uuid}');
      for (final c in s.characteristics) {
        print(
          '  Characteristic: ${c.uuid} '
          'read=${c.properties.read} '
          'write=${c.properties.write} '
          'writeWithoutResponse=${c.properties.writeWithoutResponse} '
          'notify=${c.properties.notify}',
        );
      }
    }
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _ensureInitialized();

    final device = _devices[deviceId];
    if (device != null) {
      await device.disconnect();
    }
    _servicesCache.remove(deviceId);
  }

  @override
  Future<bool> isConnected(String deviceId) async {
    _ensureInitialized();

    final device = _devices[deviceId];
    if (device == null) return false;

    final state = await device.connectionState.first;
    return state == BluetoothConnectionState.connected;
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
    final device = _devices[deviceId];
    if (device == null) return null;

    try {
      final rssi = await device.readRssi();
      if (rssi >= -60) return 4;
      if (rssi >= -75) return 3;
      if (rssi >= -90) return 2;
      return 1;
    } catch (_) {
      return null;
    }
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
    if (data.isEmpty) {
      throw Exception('Command payload cannot be empty');
    }

    final Guid targetUuid =
        data.length <= 4 ? inetWriteCharUuid : cmdWriteCharUuid;

    final c = await _findCharacteristic(
      deviceId,
      eixamServiceUuid,
      targetUuid,
    );

    if (c == null) {
      throw Exception('EIXAM write characteristic not found');
    }

    if (c.properties.writeWithoutResponse) {
      await c.write(data, withoutResponse: true);
    } else {
      await c.write(data, withoutResponse: false);
    }
  }

  @override
  Future<Stream<List<int>>> subscribeNotifications(String deviceId) async {
    final tel = await _findCharacteristic(
      deviceId,
      eixamServiceUuid,
      telNotifyCharUuid,
    );
    final sos = await _findCharacteristic(
      deviceId,
      eixamServiceUuid,
      sosNotifyCharUuid,
    );

    if (tel == null || sos == null) {
      throw Exception('EIXAM notify characteristics not found');
    }

    await tel.setNotifyValue(true);
    await sos.setNotifyValue(true);

    final telStream = tel.lastValueStream.map((v) => v.toList());
    final sosStream = sos.lastValueStream.map((v) => v.toList());

    return StreamGroup.merge([telStream, sosStream]);
  }

  @override
  Future<bool> isEixamCompatible(String deviceId) async {
    final services = await _services(deviceId);

    BluetoothService? eixamService;
    for (final s in services) {
      if (s.uuid == eixamServiceUuid) {
        eixamService = s;
        break;
      }
    }

    if (eixamService == null) {
      return false;
    }

    bool hasTel = false;
    bool hasSos = false;
    bool hasInet = false;
    bool hasCmd = false;

    for (final c in eixamService.characteristics) {
      if (c.uuid == telNotifyCharUuid) hasTel = true;
      if (c.uuid == sosNotifyCharUuid) hasSos = true;
      if (c.uuid == inetWriteCharUuid) hasInet = true;
      if (c.uuid == cmdWriteCharUuid) hasCmd = true;
    }

    return hasTel && hasSos && hasInet && hasCmd;
  }

  Future<List<BluetoothService>> _services(String deviceId) async {
    if (_servicesCache.containsKey(deviceId)) {
      return _servicesCache[deviceId]!;
    }

    final device = _devices[deviceId];
    if (device == null) {
      return [];
    }

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

  void _ensureInitialized() {
    if (!_initialized) {
      throw Exception('RealBleClient not initialized');
    }
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