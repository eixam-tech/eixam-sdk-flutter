import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/foundation.dart';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_debug_registry.dart';
import 'ble_scan_result.dart';

class RealBleClient implements BleClient {
  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, List<BluetoothService>> _servicesCache = {};
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;

  static final Guid eixamServiceUuid = Guid(
    '6ba1b218-15a8-461f-9fa8-5dcae273ea00',
  );

  static final Guid telNotifyCharUuid = Guid(
    '6ba1b218-15a8-461f-9fa8-5dcae273ea01',
  );

  static final Guid sosNotifyCharUuid = Guid(
    '6ba1b218-15a8-461f-9fa8-5dcae273ea02',
  );

  static final Guid inetWriteCharUuid = Guid(
    '6ba1b218-15a8-461f-9fa8-5dcae273ea03',
  );

  static final Guid cmdWriteCharUuid = Guid(
    '6ba1b218-15a8-461f-9fa8-5dcae273ea04',
  );

  static final Guid batteryServiceUuid = Guid(
    '0000180F-0000-1000-8000-00805F9B34FB',
  );

  static final Guid batteryLevelCharUuid = Guid(
    '00002A19-0000-1000-8000-00805F9B34FB',
  );

  static final Guid deviceInfoServiceUuid = Guid(
    '0000180A-0000-1000-8000-00805F9B34FB',
  );

  static final Guid firmwareRevisionCharUuid = Guid(
    '00002A26-0000-1000-8000-00805F9B34FB',
  );

  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (await FlutterBluePlus.isSupported == false) {
      throw Exception('BLE no suportat en aquest dispositiu');
    }
    _adapterStateSub?.cancel();
    _adapterStateSub = FlutterBluePlus.adapterState.listen((state) {
      final mapped = _mapAdapterState(state);
      BleDebugRegistry.instance.update(adapterState: mapped);
      _log('BLE adapter -> $mapped');
    });
    BleDebugRegistry.instance.update(
      adapterState: _mapAdapterState(FlutterBluePlus.adapterStateNow),
    );
    BleDebugRegistry.instance.recordEvent('Real BLE client initialized');
    _initialized = true;
  }

  @override
  Future<BleAdapterState> getAdapterState() async {
    _ensureInitialized();
    final state = _mapAdapterState(FlutterBluePlus.adapterStateNow);
    BleDebugRegistry.instance.update(adapterState: state);
    return state;
  }

  @override
  Stream<BleAdapterState> watchAdapterState() {
    _ensureInitialized();
    return FlutterBluePlus.adapterState.map((state) {
      final mapped = _mapAdapterState(state);
      BleDebugRegistry.instance.update(adapterState: mapped);
      return mapped;
    });
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

        _log(
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
    BleDebugRegistry.instance.recordEvent(
      'BLE scan completed with ${results.length} connectable candidate(s)',
    );

    return results;
  }

  @override
  Future<void> connect(String deviceId) async {
    _ensureInitialized();

    final device = _devices[deviceId];
    if (device == null) {
      throw Exception('Dispositiu no trobat: $deviceId');
    }
    BleDebugRegistry.instance.update(
      selectedDeviceId: deviceId,
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
    );
    BleDebugRegistry.instance.recordEvent('Connecting to $deviceId');

    final connectionState = await device.connectionState.first;
    if (connectionState != BluetoothConnectionState.connected) {
      await device.connect(timeout: const Duration(seconds: 10));
    }

    final services = await device.discoverServices();
    _servicesCache[deviceId] = services;

    BleDebugRegistry.instance.update(
      discoveredServices: services.map((service) => service.uuid.str).toList(),
    );
    BleDebugRegistry.instance.registerCommandWriter(
      (data) => writeCommand(deviceId, data),
    );
    _log('BLE connect -> deviceId=$deviceId services=${services.length}');
    for (final s in services) {
      _log('Service: ${s.uuid}');
      for (final c in s.characteristics) {
        _log(
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
    BleDebugRegistry.instance.clearCommandWriter();
    BleDebugRegistry.instance.update(
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
      commandWriterReady: false,
    );
    BleDebugRegistry.instance.recordEvent('Disconnected from $deviceId');
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

    final Guid targetUuid = data.length <= 4
        ? inetWriteCharUuid
        : cmdWriteCharUuid;

    final c = await _findCharacteristic(deviceId, eixamServiceUuid, targetUuid);

    if (c == null) {
      throw Exception('EIXAM write characteristic not found');
    }

    final payload = _hex(data);
    _log(
      'BLE write -> deviceId=$deviceId target=${targetUuid.str} payload=$payload',
    );
    if (c.properties.writeWithoutResponse) {
      await c.write(data, withoutResponse: true);
    } else {
      await c.write(data, withoutResponse: false);
    }
    BleDebugRegistry.instance.update(lastCommandSent: payload);
    BleDebugRegistry.instance.recordEvent(
      'Command written to $deviceId (${data.length} bytes)',
    );
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
    BleDebugRegistry.instance.update(
      telNotifySubscribed: true,
      sosNotifySubscribed: true,
    );
    BleDebugRegistry.instance.recordEvent(
      'Notify subscription enabled for $deviceId',
    );
    _log(
      'BLE notify subscribe -> deviceId=$deviceId tel=${tel.uuid.str} sos=${sos.uuid.str}',
    );

    final telStream = tel.lastValueStream.map((v) => v.toList());
    final sosStream = sos.lastValueStream.map((v) => v.toList());

    return StreamGroup.merge([telStream, sosStream]).map((packet) {
      final payload = _hex(packet);
      BleDebugRegistry.instance.update(lastPacketReceived: payload);
      BleDebugRegistry.instance.recordEvent(
        'Notify packet received from $deviceId (${packet.length} bytes)',
      );
      _log('BLE notify packet -> deviceId=$deviceId payload=$payload');
      return packet;
    });
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
      BleDebugRegistry.instance.update(eixamServiceFound: false);
      BleDebugRegistry.instance.recordEvent(
        'Compatibility check failed for $deviceId: EIXAM service not found',
      );
      return false;
    }

    bool hasTel = false;
    bool hasSos = false;
    bool hasInet = false;
    bool hasCmd = false;
    BleDebugRegistry.instance.update(eixamServiceFound: true);

    for (final c in eixamService.characteristics) {
      if (c.uuid == telNotifyCharUuid) hasTel = true;
      if (c.uuid == sosNotifyCharUuid) hasSos = true;
      if (c.uuid == inetWriteCharUuid) hasInet = true;
      if (c.uuid == cmdWriteCharUuid) hasCmd = true;
    }

    final compatible = hasTel && hasSos && hasInet && hasCmd;
    BleDebugRegistry.instance.recordEvent(
      compatible
          ? 'Compatibility check passed for $deviceId'
          : 'Compatibility check failed for $deviceId: missing required characteristics',
    );
    return compatible;
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

  void _log(String message) {
    debugPrint(message);
  }

  String _hex(List<int> data) {
    return data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
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
