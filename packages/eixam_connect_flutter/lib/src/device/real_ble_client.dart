import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'canonical_hardware_id.dart';
import 'ble_debug_registry.dart';
import 'ble_scan_result.dart';
import 'ble_scan_result_brand_classifier.dart';
import 'eixam_ble_command.dart';
import 'eixam_ble_mesh_port_inference.dart';
import 'eixam_ble_notification.dart';
import 'eixam_ble_protocol.dart';

class RealBleClient implements BleClient {
  RealBleClient({
    int? Function(EixamBleChannel channel, List<int> payload)? meshPortResolver,
  }) : _meshPortResolver = meshPortResolver;

  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _postConnectStabilizationDelay =
      Duration(milliseconds: 350);
  static const Duration _connectedStateConfirmationTimeout =
      Duration(seconds: 2);

  final Map<String, BluetoothDevice> _devices = {};
  final Map<String, List<BluetoothService>> _servicesCache = {};
  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
  final int? Function(EixamBleChannel channel, List<int> payload)?
      _meshPortResolver;

  static final Guid eixamServiceUuid = Guid(EixamBleProtocol.serviceUuid);
  static final Guid telNotifyCharUuid =
      Guid(EixamBleProtocol.telNotifyCharacteristicUuid);
  static final Guid sosNotifyCharUuid =
      Guid(EixamBleProtocol.sosNotifyCharacteristicUuid);
  static final Guid inetWriteCharUuid =
      Guid(EixamBleProtocol.inetWriteCharacteristicUuid);
  static final Guid cmdWriteCharUuid =
      Guid(EixamBleProtocol.cmdWriteCharacteristicUuid);

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
  bool _reportedAmbiguousTelMeshPort = false;

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
    BleDebugRegistry.instance.registerScanner(scan);
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
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _ensureInitialized();

    final Map<String, BleScanResult> deduped = {};
    BleDebugRegistry.instance.update(isScanning: true, scanResults: const []);

    final sub = FlutterBluePlus.scanResults.listen((scanResults) {
      for (final r in scanResults) {
        final id = r.device.remoteId.str;
        _devices[id] = r.device;
        final advertisedServiceUuids = r.advertisementData.serviceUuids
            .map((uuid) => uuid.str)
            .toList(growable: false);

        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : (r.device.platformName.isNotEmpty
                ? r.device.platformName
                : 'Unknown');

        _log(
          'BLE scan -> id=$id name="$name" rssi=${r.rssi} connectable=${r.advertisementData.connectable} serviceUuids=$advertisedServiceUuids',
        );

        deduped[id] = BleScanResult(
          deviceId: id,
          canonicalHardwareId: normalizeCanonicalHardwareId(id),
          name: name,
          rssi: r.rssi,
          connectable: r.advertisementData.connectable,
          advertisedServiceUuids: advertisedServiceUuids,
          brandClassification: classifyBleDiscoveredDeviceBrand(
            name: name,
            advertisedServiceUuids: advertisedServiceUuids,
          ),
          discoveredAt: DateTime.now(),
        );
        BleDebugRegistry.instance.update(
          scanResults: deduped.values.toList()
            ..sort((a, b) => b.rssi.compareTo(a.rssi)),
        );
      }
    });

    await FlutterBluePlus.startScan(
      timeout: timeout,
      androidScanMode: AndroidScanMode.lowLatency,
      androidUsesFineLocation: true,
      androidCheckLocationServices: true,
    );
    await Future.delayed(timeout);
    await FlutterBluePlus.stopScan();
    await sub.cancel();

    final results = deduped.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    BleDebugRegistry.instance.recordEvent(
      'BLE scan completed with ${results.length} discovered device(s)',
    );
    BleDebugRegistry.instance.update(isScanning: false, scanResults: results);

    return results;
  }

  @override
  Future<void> connect(String deviceId) async {
    _ensureInitialized();

    final device = _devices[deviceId];
    if (device == null) {
      BleDebugRegistry.instance.recordEvent(
        'BLE connect selected device missing -> deviceId=$deviceId',
      );
      throw Exception('Dispositiu no trobat: $deviceId');
    }
    BleDebugRegistry.instance.update(
      selectedDeviceId: deviceId,
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
    );
    BleDebugRegistry.instance.recordEvent('Connecting to $deviceId');
    BleDebugRegistry.instance.recordEvent(
      'BLE connect selected device found -> deviceId=$deviceId platformName="${device.platformName}"',
    );

    try {
      final initialConnectionState = await _readConnectionState(device);
      BleDebugRegistry.instance.recordEvent(
        'BLE connect initial connectionState -> deviceId=$deviceId state=${initialConnectionState.name}',
      );
      _log(
        'BLE connect initial connectionState -> deviceId=$deviceId state=${initialConnectionState.name}',
      );

      if (initialConnectionState != BluetoothConnectionState.connected) {
        BleDebugRegistry.instance.recordEvent(
          'BLE connect() start -> deviceId=$deviceId',
        );
        _log('BLE connect() start -> deviceId=$deviceId');
        try {
          await device.connect(timeout: _connectTimeout);
          BleDebugRegistry.instance.recordEvent(
            'BLE connect() success -> deviceId=$deviceId',
          );
          _log('BLE connect() success -> deviceId=$deviceId');
        } catch (error) {
          BleDebugRegistry.instance.recordEvent(
            'BLE connect() failure -> deviceId=$deviceId error=$error',
          );
          _log('BLE connect() failure -> deviceId=$deviceId error=$error');
          rethrow;
        }
      } else {
        BleDebugRegistry.instance.recordEvent(
          'BLE connect() success -> deviceId=$deviceId skipped=already_connected',
        );
        _log(
          'BLE connect() success -> deviceId=$deviceId skipped=already_connected',
        );
      }

      final postConnectState = await _waitForStableConnectedState(
        device,
        deviceId: deviceId,
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE connect post-connect connectionState -> deviceId=$deviceId state=${postConnectState.name}',
      );
      _log(
        'BLE connect post-connect connectionState -> deviceId=$deviceId state=${postConnectState.name}',
      );
      BleDebugRegistry.instance.recordEvent('Connected to $deviceId');

      _servicesCache.remove(deviceId);
      BleDebugRegistry.instance.recordEvent(
        'BLE discoverServices() start -> deviceId=$deviceId',
      );
      _log('BLE discoverServices() start -> deviceId=$deviceId');
      final services = await device.discoverServices();
      BleDebugRegistry.instance.recordEvent(
        'BLE discoverServices() success -> deviceId=$deviceId services=${services.length}',
      );
      _log(
        'BLE discoverServices() success -> deviceId=$deviceId services=${services.length}',
      );
      _servicesCache[deviceId] = services;

      BleDebugRegistry.instance.update(
        discoveredServices:
            services.map((service) => service.uuid.str).toList(),
      );
      BleDebugRegistry.instance.registerCommandWriter(
        (command) => writeDeviceCommand(deviceId, command),
      );
      BleDebugRegistry.instance.recordEvent(
        'discoverServices succeeded for $deviceId with ${services.length} service(s)',
      );
      _log('BLE connect -> deviceId=$deviceId services=${services.length}');
      for (final s in services) {
        _log('Service: ${s.uuid}');
        for (final c in s.characteristics) {
          _log(
            '  Characteristic: ${c.uuid} read=${c.properties.read} write=${c.properties.write} writeWithoutResponse=${c.properties.writeWithoutResponse} notify=${c.properties.notify}',
          );
        }
      }
    } catch (error, stackTrace) {
      final transientDisconnect = _isTransientDisconnectError(error);
      if (transientDisconnect) {
        BleDebugRegistry.instance.recordEvent(
          'BLE connect/discover transient disconnect -> deviceId=$deviceId error=$error',
        );
      } else {
        BleDebugRegistry.instance.recordEvent(
          'BLE connect/discover generic failure -> deviceId=$deviceId error=$error',
        );
      }
      await _clearTransientConnectionState(deviceId, device);
      BleDebugRegistry.instance.recordEvent(
        'Connection/discoverServices failed for $deviceId: $error',
      );
      debugPrint(
        'BLE connect/discoverServices failed -> deviceId=$deviceId error=$error',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
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
  Stream<bool> watchConnection(String deviceId) {
    _ensureInitialized();

    final device = _devices[deviceId];
    if (device == null) {
      return const Stream<bool>.empty();
    }

    return device.connectionState
        .map((state) => state == BluetoothConnectionState.connected)
        .distinct();
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
  Future<void> writeDeviceCommand(
    String deviceId,
    EixamDeviceCommand command,
  ) async {
    final data = command.encode();
    if (data.isEmpty) {
      throw Exception('Command payload cannot be empty');
    }

    final targetUuid =
        command.usesCmdCharacteristic ? cmdWriteCharUuid : inetWriteCharUuid;
    final c = await _findCharacteristic(deviceId, eixamServiceUuid, targetUuid);

    if (c == null) {
      if (!command.usesCmdCharacteristic) {
        throw Exception(
          'INET characteristic (ea03) not found on connected device',
        );
      }
      throw Exception(
        'CMD characteristic (ea04) is missing on this connected EIXAM device. Advanced commands requiring CMD are unavailable.',
      );
    }

    final payload = command.encodedHex;
    _log(
      'BLE write -> deviceId=$deviceId target=${targetUuid.str} command=${command.label} payload=$payload',
    );
    BleDebugRegistry.instance.update(
      lastCommandSent: payload,
      lastWriteTargetCharacteristic: targetUuid.str,
      lastWriteResult: 'PENDING',
      lastWriteAt: DateTime.now(),
      lastWriteError: null,
    );
    try {
      if (c.properties.writeWithoutResponse) {
        await c.write(data, withoutResponse: true);
      } else {
        await c.write(data, withoutResponse: false);
      }
    } catch (error) {
      BleDebugRegistry.instance.update(
        lastWriteTargetCharacteristic: targetUuid.str,
        lastWriteResult: 'FAILED: $error',
        lastWriteAt: DateTime.now(),
        lastWriteError: error.toString(),
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE write failed -> target=${targetUuid.str} payload=$payload error=$error',
      );
      rethrow;
    }
    BleDebugRegistry.instance.update(
      lastCommandSent: payload,
      lastWriteTargetCharacteristic: targetUuid.str,
      lastWriteResult: 'SUCCESS',
      lastWriteAt: DateTime.now(),
      lastWriteError: null,
    );
    BleDebugRegistry.instance.recordEvent(
      'Command written to $deviceId (${command.label}) target=${targetUuid.str}',
    );
  }

  @override
  Future<Stream<EixamBleNotification>> subscribeEixamNotifications(
    String deviceId,
  ) async {
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

    final telStream = tel.lastValueStream.map(
      (v) {
        final payload = v.toList();
        return EixamBleNotification(
          channel: EixamBleChannel.tel,
          payload: payload,
          receivedAt: DateTime.now(),
          meshPort: _meshPortForLiveNotification(
            channel: EixamBleChannel.tel,
            payload: payload,
          ),
        );
      },
    );
    final sosStream = sos.lastValueStream.map(
      (v) {
        final payload = v.toList();
        return EixamBleNotification(
          channel: EixamBleChannel.sos,
          payload: payload,
          receivedAt: DateTime.now(),
          meshPort: _meshPortForLiveNotification(
            channel: EixamBleChannel.sos,
            payload: payload,
          ),
        );
      },
    );

    return StreamGroup.merge([telStream, sosStream]).map((notification) {
      BleDebugRegistry.instance.update(
        lastPacketReceived: notification.payloadHex,
      );
      BleDebugRegistry.instance.recordEvent(
        'Notify packet received from $deviceId channel=${notification.channel.name} meshPort=${notification.meshPort?.toString() ?? "-"} (${notification.payload.length} bytes)',
      );
      _log(
        'BLE notify packet -> deviceId=$deviceId channel=${notification.channel.name} meshPort=${notification.meshPort?.toString() ?? "-"} payload=${notification.payloadHex}',
      );
      return notification;
    });
  }

  int? _meshPortForLiveNotification({
    required EixamBleChannel channel,
    required List<int> payload,
  }) {
    final explicitMeshPort = _meshPortResolver?.call(channel, payload);
    final inferredMeshPort = inferMeshPortForLiveNotification(
      channel: channel,
      payload: payload,
      explicitMeshPort: explicitMeshPort,
    );
    if (channel == EixamBleChannel.tel &&
        inferredMeshPort == null &&
        explicitMeshPort == null &&
        payload.length == EixamBleProtocol.telPacketLength &&
        !_reportedAmbiguousTelMeshPort) {
      _reportedAmbiguousTelMeshPort = true;
      BleDebugRegistry.instance.recordEvent(
        'BLE live TEL notify has no mesh port metadata; leaving ambiguous 12-byte payload untagged to avoid unsafe TEL-vs-heartbeat inference',
      );
    }
    return inferredMeshPort;
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
      BleDebugRegistry.instance.update(
        eixamServiceFound: false,
        telFound: false,
        sosFound: false,
        inetFound: false,
        cmdFound: false,
      );
      BleDebugRegistry.instance.recordEvent(
        'Compatibility check failed for $deviceId: EIXAM service not found',
      );
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

    BleDebugRegistry.instance.update(
      eixamServiceFound: true,
      telFound: hasTel,
      sosFound: hasSos,
      inetFound: hasInet,
      cmdFound: hasCmd,
    );

    final compatible = hasTel && hasSos && hasInet;
    BleDebugRegistry.instance.recordEvent(
      compatible
          ? 'Compatibility check passed for $deviceId'
          : 'Compatibility check failed for $deviceId: missing required characteristics',
    );
    if (compatible && !hasCmd) {
      BleDebugRegistry.instance.recordEvent(
        'Connected to EIXAM device, but CMD characteristic (ea04) is missing. Advanced commands may be unavailable.',
      );
    }
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

  Future<BluetoothConnectionState> _readConnectionState(
    BluetoothDevice device,
  ) async {
    return device.connectionState.first.timeout(
      _connectedStateConfirmationTimeout,
      onTimeout: () => BluetoothConnectionState.disconnected,
    );
  }

  Future<BluetoothConnectionState> _waitForStableConnectedState(
    BluetoothDevice device, {
    required String deviceId,
  }) async {
    await Future.delayed(_postConnectStabilizationDelay);
    final state = await _readConnectionState(device);
    if (state != BluetoothConnectionState.connected) {
      final error = PlatformException(
        code: 'deviceDisconnected',
        message:
            'deviceDisconnected while waiting for a stable BLE connection before discoverServices',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE connect stabilization failed -> deviceId=$deviceId state=${state.name} error=$error',
      );
      throw error;
    }
    return state;
  }

  Future<void> _clearTransientConnectionState(
    String deviceId,
    BluetoothDevice device,
  ) async {
    _servicesCache.remove(deviceId);
    BleDebugRegistry.instance.clearCommandWriter();
    BleDebugRegistry.instance.update(
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
      commandWriterReady: false,
      discoveredServices: const <String>[],
    );
    try {
      await device.disconnect();
    } catch (_) {}
  }

  bool _isTransientDisconnectError(Object error) {
    if (error is PlatformException) {
      final code = error.code.toLowerCase();
      final message = (error.message ?? '').toLowerCase();
      if (code.contains('devicedisconnected') ||
          message.contains('devicedisconnected')) {
        return true;
      }
    }

    final text = error.toString().toLowerCase();
    return text.contains('devicedisconnected') ||
        text.contains('device disconnected') ||
        text.contains('disconnected during discoverservices') ||
        text.contains('disconnected during connection');
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
