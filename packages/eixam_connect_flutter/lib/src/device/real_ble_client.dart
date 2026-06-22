import 'dart:async';

import 'package:async/async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'canonical_hardware_id.dart';
import 'ble_debug_registry.dart';
import 'ble_security_policy.dart';
import 'ble_scan_result.dart';
import 'ble_scan_result_brand_classifier.dart';
import 'eixam_ble_command.dart';
import 'eixam_ble_mesh_port_inference.dart';
import 'eixam_ble_notification.dart';
import 'eixam_ble_protocol.dart';

typedef NativeBleStartScan = Future<void> Function(Duration timeout);
typedef NativeBleStopScan = Future<void> Function();

final class _SdkDiscoveryPrecheck {
  const _SdkDiscoveryPrecheck({
    required this.supported,
    required this.adapterState,
    required this.scannerReady,
    required this.allowed,
    required this.reason,
  });

  final bool supported;
  final BleAdapterState adapterState;
  final String scannerReady;
  final bool allowed;
  final String reason;
}

class RealBleClient implements BleClient {
  RealBleClient({
    int? Function(EixamBleChannel channel, List<int> payload)? meshPortResolver,
    @visibleForTesting Future<bool> Function()? isSupportedProvider,
    @visibleForTesting BluetoothAdapterState Function()? adapterStateProvider,
    @visibleForTesting bool Function()? isScanningProvider,
    @visibleForTesting
    Stream<BluetoothAdapterState> Function()? adapterStateStreamProvider,
    @visibleForTesting Stream<List<ScanResult>> Function()? scanResultsProvider,
    @visibleForTesting NativeBleStartScan? startScan,
    @visibleForTesting NativeBleStopScan? stopScan,
  })  : _meshPortResolver = meshPortResolver,
        _isSupportedProvider =
            isSupportedProvider ?? (() => FlutterBluePlus.isSupported),
        _adapterStateProvider =
            adapterStateProvider ?? (() => FlutterBluePlus.adapterStateNow),
        _isScanningProvider =
            isScanningProvider ?? (() => FlutterBluePlus.isScanningNow),
        _adapterStateStreamProvider =
            adapterStateStreamProvider ?? (() => FlutterBluePlus.adapterState),
        _scanResultsProvider =
            scanResultsProvider ?? (() => FlutterBluePlus.scanResults),
        _startScan = startScan ??
            ((timeout) => FlutterBluePlus.startScan(
                  timeout: timeout,
                  androidScanMode: AndroidScanMode.lowLatency,
                  androidUsesFineLocation: true,
                  androidCheckLocationServices: true,
                )),
        _stopScan = stopScan ?? (() => FlutterBluePlus.stopScan());

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
  final Future<bool> Function() _isSupportedProvider;
  final BluetoothAdapterState Function() _adapterStateProvider;
  final bool Function() _isScanningProvider;
  final Stream<BluetoothAdapterState> Function() _adapterStateStreamProvider;
  final Stream<List<ScanResult>> Function() _scanResultsProvider;
  final NativeBleStartScan _startScan;
  final NativeBleStopScan _stopScan;

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
    if (await _isSupportedProvider() == false) {
      throw Exception('E_BLE_UNSUPPORTED');
    }
    _adapterStateSub?.cancel();
    _adapterStateSub = _adapterStateStreamProvider().listen((state) {
      final mapped = _mapAdapterState(state);
      BleDebugRegistry.instance.update(adapterState: mapped);
      if (mapped == BleAdapterState.poweredOn) {
        debugPrint(
          'IOS_BLE_POWERED_CACHE_UPDATED '
          'source=adapter_state value=poweredOn',
        );
      }
      _log('BLE adapter -> $mapped');
    });
    final initialAdapterState = _mapAdapterState(_adapterStateProvider());
    BleDebugRegistry.instance.update(adapterState: initialAdapterState);
    if (initialAdapterState == BleAdapterState.poweredOn) {
      debugPrint(
        'IOS_BLE_POWERED_CACHE_UPDATED '
        'source=adapter_state value=poweredOn',
      );
    }
    BleDebugRegistry.instance.registerScanner(scan);
    BleDebugRegistry.instance.recordEvent('Real BLE client initialized');
    _initialized = true;
  }

  @override
  Future<BleAdapterState> getAdapterState() async {
    _ensureInitialized();
    final state = _mapAdapterState(_adapterStateProvider());
    BleDebugRegistry.instance.update(adapterState: state);
    if (state == BleAdapterState.poweredOn) {
      debugPrint(
        'IOS_BLE_POWERED_CACHE_UPDATED '
        'source=adapter_state value=poweredOn',
      );
    }
    return state;
  }

  @override
  Stream<BleAdapterState> watchAdapterState() {
    _ensureInitialized();
    return _adapterStateStreamProvider().map((state) {
      final mapped = _mapAdapterState(state);
      BleDebugRegistry.instance.update(adapterState: mapped);
      if (mapped == BleAdapterState.poweredOn) {
        debugPrint(
          'IOS_BLE_POWERED_CACHE_UPDATED '
          'source=adapter_state value=poweredOn',
        );
      }
      return mapped;
    });
  }

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _ensureInitialized();
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    debugPrint(
      'SDK_DISCOVERY_START_ENTRY '
      'source=ble_client_scan platform=${isIos ? 'ios' : 'other'}',
    );
    final precheck = await _precheckNativeScanStart();
    if (isIos) {
      debugPrint(
        'SDK_DISCOVERY_PRECHECK '
        'adapterState=${precheck.adapterState.name} '
        'supported=${precheck.supported} '
        'scannerReady=${precheck.scannerReady}',
      );
      if (!precheck.allowed) {
        debugPrint(
          'SDK_DISCOVERY_PRECHECK_BLOCKED reason=${precheck.reason}',
        );
        throw StateError('E_BLE_SCANNER_NOT_READY');
      }
      if (precheck.scannerReady == 'unknown') {
        debugPrint(
          'SDK_DISCOVERY_PRECHECK_ALLOW_UNKNOWN '
          'reason=adapter_powered_on_supported',
        );
      }
    }

    final Map<String, BleScanResult> deduped = {};
    BleDebugRegistry.instance.update(isScanning: true, scanResults: const []);

    final sub = _scanResultsProvider().listen((scanResults) {
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

    try {
      debugPrint('SDK_DISCOVERY_NATIVE_START_SCAN_CALL_BEGIN');
      await _startScan(timeout);
      debugPrint('SDK_DISCOVERY_NATIVE_START_SCAN_CALL_DONE');
      await Future.delayed(timeout);
      await _stopScan();
      await sub.cancel();
    } catch (error) {
      debugPrint('SDK_DISCOVERY_NATIVE_START_SCAN_CALL_FAILED error=$error');
      debugPrint(
        'SDK_DISCOVERY_ERROR_ORIGIN '
        'origin=flutter_blue_plus_native error=$error',
      );
      BleDebugRegistry.instance.update(isScanning: false);
      await sub.cancel();
      rethrow;
    }

    final results = deduped.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    BleDebugRegistry.instance.recordEvent(
      'BLE scan completed with ${results.length} discovered device(s)',
    );
    BleDebugRegistry.instance.update(isScanning: false, scanResults: results);

    return results;
  }

  Future<_SdkDiscoveryPrecheck> _precheckNativeScanStart() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return const _SdkDiscoveryPrecheck(
        supported: true,
        adapterState: BleAdapterState.unknown,
        scannerReady: 'unknown',
        allowed: true,
        reason: 'non_ios',
      );
    }
    final supported = await _isSupportedProvider();
    final adapterState = _mapAdapterState(_adapterStateProvider());
    final scannerReady = _isScanningProvider()
        ? 'ready'
        : supported && adapterState == BleAdapterState.poweredOn
            ? 'unknown'
            : 'false';
    if (!supported) {
      return _SdkDiscoveryPrecheck(
        supported: supported,
        adapterState: adapterState,
        scannerReady: scannerReady,
        allowed: false,
        reason: 'unsupported',
      );
    }
    if (adapterState != BleAdapterState.poweredOn) {
      return _SdkDiscoveryPrecheck(
        supported: supported,
        adapterState: adapterState,
        scannerReady: scannerReady,
        allowed: false,
        reason: 'adapter_not_powered_on',
      );
    }
    if (scannerReady == 'false') {
      return _SdkDiscoveryPrecheck(
        supported: supported,
        adapterState: adapterState,
        scannerReady: scannerReady,
        allowed: false,
        reason: 'scanner_not_ready',
      );
    }
    return _SdkDiscoveryPrecheck(
      supported: supported,
      adapterState: adapterState,
      scannerReady: scannerReady,
      allowed: true,
      reason: 'adapter_powered_on_supported',
    );
  }

  @override
  Future<void> connect(String deviceId) async {
    _ensureInitialized();

    final device = await _resolveKnownDevice(deviceId);
    if (device == null) {
      BleDebugRegistry.instance.recordEvent(
        'BLE connect selected device missing -> hardwareId=$deviceId',
      );
      throw Exception('E_BLE_DEVICE_NOT_FOUND');
    }
    BleDebugRegistry.instance.update(
      selectedDeviceId: deviceId,
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
    );
    BleDebugRegistry.instance.recordEvent(
      'Connecting to hardwareId=$deviceId',
    );
    BleDebugRegistry.instance.recordEvent(
      'BLE connect selected device found -> hardwareId=$deviceId platformName="${device.platformName}"',
    );

    try {
      final initialConnectionState = await _readConnectionState(device);
      BleDebugRegistry.instance.recordEvent(
        'BLE connect initial connectionState -> hardwareId=$deviceId state=${initialConnectionState.name}',
      );
      _log(
        'BLE connect initial connectionState -> hardwareId=$deviceId state=${initialConnectionState.name}',
      );

      if (initialConnectionState != BluetoothConnectionState.connected) {
        BleDebugRegistry.instance.recordEvent(
          'BLE connect() start -> hardwareId=$deviceId',
        );
        _log('BLE connect() start -> hardwareId=$deviceId');
        try {
          await device.connect(timeout: _connectTimeout);
          BleDebugRegistry.instance.recordEvent(
            'BLE connect() success -> hardwareId=$deviceId',
          );
          _log('BLE connect() success -> hardwareId=$deviceId');
        } catch (error) {
          BleDebugRegistry.instance.recordEvent(
            'BLE connect() failure -> hardwareId=$deviceId error=$error',
          );
          _log('BLE connect() failure -> hardwareId=$deviceId error=$error');
          rethrow;
        }
      } else {
        BleDebugRegistry.instance.recordEvent(
          'BLE connect() success -> hardwareId=$deviceId skipped=already_connected',
        );
        _log(
          'BLE connect() success -> hardwareId=$deviceId skipped=already_connected',
        );
      }

      final postConnectState = await _waitForStableConnectedState(
        device,
        deviceId: deviceId,
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE connect post-connect connectionState -> hardwareId=$deviceId state=${postConnectState.name}',
      );
      _log(
        'BLE connect post-connect connectionState -> hardwareId=$deviceId state=${postConnectState.name}',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_CONNECTED hardwareId=$deviceId',
      );

      _servicesCache.remove(deviceId);
      final services = await _discoverServicesWithReconnectRetry(
        deviceId: deviceId,
        device: device,
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
        'BLE_DISCOVER_SERVICES_SUCCESS hardwareId=$deviceId services=${services.length}',
      );
      _log('BLE connect -> hardwareId=$deviceId services=${services.length}');
      for (final s in services) {
        _log('Service: ${s.uuid}');
        for (final c in s.characteristics) {
          _log(
            '  Characteristic: ${c.uuid} read=${c.properties.read} write=${c.properties.write} writeWithoutResponse=${c.properties.writeWithoutResponse} notify=${c.properties.notify}',
          );
        }
      }
    } catch (error) {
      final transientDisconnect = _isTransientDisconnectError(error);
      if (transientDisconnect) {
        BleDebugRegistry.instance.recordEvent(
          'BLE connect/discover transient disconnect -> hardwareId=$deviceId error=$error',
        );
      } else {
        BleDebugRegistry.instance.recordEvent(
          'BLE connect/discover generic failure -> hardwareId=$deviceId error=$error',
        );
      }
      await _clearTransientConnectionState(deviceId, device);
      BleDebugRegistry.instance.recordEvent(
        'BLE_CONNECT_DISCOVER_FAILED hardwareId=$deviceId error=$error',
      );
      debugPrint(
        'BLE connect/discoverServices failed -> hardwareId=$deviceId error=$error',
      );

      rethrow;
    }
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _ensureInitialized();

    final device = await _resolveKnownDevice(deviceId);
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
    BleDebugRegistry.instance.recordEvent(
      'BLE_DISCONNECTED hardwareId=$deviceId',
    );
  }

  @override
  Future<bool> isConnected(String deviceId) async {
    _ensureInitialized();

    final device = await _resolveKnownDevice(deviceId);
    if (device == null) return false;

    try {
      final state = await device.connectionState.first;
      return state == BluetoothConnectionState.connected;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> hasSystemAssociation(String deviceId) async {
    _ensureInitialized();
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    final normalized = deviceId.trim();
    if (normalized.isEmpty) {
      return false;
    }
    try {
      final bondedDevices = await FlutterBluePlus.bondedDevices;
      if (_firstDeviceWithId(bondedDevices, normalized) != null) {
        return true;
      }
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE Android bond association lookup failed -> hardwareId=$normalized error=$error',
      );
      return true;
    }
    BleDebugRegistry.instance.recordEvent(
      'BLE known device has no Android system bond -> hardwareId=$normalized',
    );
    return false;
  }

  @override
  Future<bool> removeSystemAssociation(String deviceId) async {
    _ensureInitialized();
    if (defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final normalized = deviceId.trim();
    if (normalized.isEmpty) {
      return false;
    }
    final device = await _resolveKnownDevice(normalized);
    if (device == null) {
      return false;
    }
    try {
      await device.removeBond();
      BleDebugRegistry.instance.recordEvent(
        'BLE Android system bond removed -> hardwareId=$normalized',
      );
      return true;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE Android system bond removal failed -> hardwareId=$normalized error=$error',
      );
      return false;
    }
  }

  @override
  Stream<bool> watchConnection(String deviceId) {
    _ensureInitialized();

    final existing = _devices[deviceId];
    if (existing != null) {
      return existing.connectionState
          .map((state) => state == BluetoothConnectionState.connected)
          .distinct();
    }

    final device = BluetoothDevice.fromId(deviceId);
    _devices[deviceId] = device;
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
    final securityDecision = BleSecurityPolicy.defaultPolicy.evaluate(
      criticality: command.criticality,
      capability: BleSecurityCapability.legacyUnknown,
    );
    for (final diagnostic in securityDecision.diagnostics) {
      BleDebugRegistry.instance.recordEvent(
        '$diagnostic command=${command.label} '
        'criticality=${securityDecision.criticality.name} '
        'capability=${securityDecision.capability.name} '
        'allowed=${securityDecision.allowed}',
      );
    }
    final data = command.encode();
    if (data.isEmpty) {
      throw Exception('E_BLE_COMMAND_PAYLOAD_EMPTY');
    }

    var targetUuid =
        command.usesCmdCharacteristic ? cmdWriteCharUuid : inetWriteCharUuid;
    var c = await _findCharacteristic(deviceId, eixamServiceUuid, targetUuid);
    if (c == null &&
        command.opcode == 0x04 &&
        command.usesCmdCharacteristic &&
        data.length <= EixamBleProtocol.inetMaxPayloadLength) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRACE device_terminal_command_fallback channel=inet reason=cmd_not_ready',
      );
      targetUuid = inetWriteCharUuid;
      c = await _findCharacteristic(deviceId, eixamServiceUuid, targetUuid);
    }

    if (c == null) {
      if (!command.usesCmdCharacteristic) {
        throw Exception('E_BLE_INET_CHARACTERISTIC_MISSING');
      }
      throw Exception('E_BLE_CMD_CHARACTERISTIC_MISSING');
    }

    final payload = command.encodedHex;
    _log(
      'BLE write -> hardwareId=$deviceId target=${targetUuid.str} command=${command.label} payload=$payload',
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
    if (command.opcode == 0x04) {
      final channel = targetUuid == cmdWriteCharUuid ? 'cmd' : 'inet';
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRACE device_terminal_command_sent opcode=0x04 channel=$channel',
      );
    }
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
      throw Exception('E_BLE_NOTIFY_CHARACTERISTICS_MISSING');
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
      'BLE notify subscribe -> hardwareId=$deviceId tel=${tel.uuid.str} sos=${sos.uuid.str}',
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
        'Notify packet received from hardwareId=$deviceId '
        'channel=${notification.channel.name} '
        'meshPort=${notification.meshPort?.toString() ?? "-"} '
        'bytes=${notification.payload.length}',
      );
      _log(
        'BLE notify packet -> hardwareId=$deviceId channel=${notification.channel.name} meshPort=${notification.meshPort?.toString() ?? "-"} payload=${notification.payloadHex}',
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
      'BLE_COMPATIBILITY_CHECK hardwareId=$deviceId result=${compatible ? 'passed' : 'failed'} reason=${compatible ? 'none' : 'missing_required_characteristics'}',
    );
    if (compatible && !hasCmd) {
      BleDebugRegistry.instance.recordEvent(
        'BLE_CMD_CHARACTERISTIC_MISSING hardwareId=$deviceId characteristic=ea04',
      );
    }
    return compatible;
  }

  Future<List<BluetoothService>> _services(String deviceId) async {
    if (_servicesCache.containsKey(deviceId)) {
      return _servicesCache[deviceId]!;
    }

    final device = await _resolveKnownDevice(deviceId);
    if (device == null) {
      return [];
    }

    final services = await _discoverServicesWithReconnectRetry(
      deviceId: deviceId,
      device: device,
    );
    _servicesCache[deviceId] = services;
    return services;
  }

  Future<BluetoothDevice?> _resolveKnownDevice(String deviceId) async {
    final normalized = deviceId.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final cached = _devices[normalized];
    if (cached != null) {
      return cached;
    }

    final systemDevice = await _findSystemDevice(normalized);
    if (systemDevice != null) {
      _devices[normalized] = systemDevice;
      BleDebugRegistry.instance.recordEvent(
        'BLE known device restored from system devices -> hardwareId=$normalized',
      );
      return systemDevice;
    }

    final bondedDevice = await _findBondedDevice(normalized);
    if (bondedDevice != null) {
      _devices[normalized] = bondedDevice;
      BleDebugRegistry.instance.recordEvent(
        'BLE known device restored from bonded devices -> hardwareId=$normalized',
      );
      return bondedDevice;
    }

    final restored = BluetoothDevice.fromId(normalized);
    _devices[normalized] = restored;
    BleDebugRegistry.instance.recordEvent(
      'BLE known device restored from persisted remoteId -> hardwareId=$normalized',
    );
    return restored;
  }

  Future<BluetoothDevice?> _findSystemDevice(String deviceId) async {
    try {
      final devices = await FlutterBluePlus.systemDevices([eixamServiceUuid]);
      return _firstDeviceWithId(devices, deviceId);
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE system device lookup failed -> hardwareId=$deviceId error=$error',
      );
      return null;
    }
  }

  Future<BluetoothDevice?> _findBondedDevice(String deviceId) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }
    try {
      final devices = await FlutterBluePlus.bondedDevices;
      return _firstDeviceWithId(devices, deviceId);
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE bonded device lookup failed -> hardwareId=$deviceId error=$error',
      );
      return null;
    }
  }

  BluetoothDevice? _firstDeviceWithId(
    List<BluetoothDevice> devices,
    String deviceId,
  ) {
    for (final device in devices) {
      if (device.remoteId.str == deviceId) {
        return device;
      }
    }
    return null;
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
        code: 'E_BLE_DEVICE_DISCONNECTED',
        message: 'E_BLE_DEVICE_DISCONNECTED',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE connect stabilization failed -> hardwareId=$deviceId state=${state.name} error=$error',
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

  Future<List<BluetoothService>> _discoverServicesWithReconnectRetry({
    required String deviceId,
    required BluetoothDevice device,
  }) async {
    const retryDelays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 350),
      Duration(milliseconds: 900),
    ];
    Object? lastError;
    for (var attempt = 0; attempt < retryDelays.length; attempt += 1) {
      final delay = retryDelays[attempt];
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
        final state = await _readConnectionState(device);
        if (state != BluetoothConnectionState.connected) {
          BleDebugRegistry.instance.recordEvent(
            'BLE discoverServices reconnect() start -> hardwareId=$deviceId attempt=${attempt + 1}',
          );
          await device.connect(timeout: _connectTimeout);
          await _waitForStableConnectedState(device, deviceId: deviceId);
        }
      }
      try {
        BleDebugRegistry.instance.recordEvent(
          'BLE discoverServices() start -> hardwareId=$deviceId attempt=${attempt + 1}',
        );
        _log(
          'BLE discoverServices() start -> hardwareId=$deviceId attempt=${attempt + 1}',
        );
        final services = await device.discoverServices();
        BleDebugRegistry.instance.recordEvent(
          'BLE discoverServices() success -> hardwareId=$deviceId services=${services.length} attempt=${attempt + 1}',
        );
        _log(
          'BLE discoverServices() success -> hardwareId=$deviceId services=${services.length} attempt=${attempt + 1}',
        );
        return services;
      } catch (error) {
        lastError = error;
        if (!_isTransientDisconnectError(error) ||
            attempt == retryDelays.length - 1) {
          rethrow;
        }
        BleDebugRegistry.instance.recordEvent(
          'BLE discoverServices transient disconnect -> hardwareId=$deviceId attempt=${attempt + 1} error=$error',
        );
        await _clearTransientConnectionState(deviceId, device);
      }
    }
    throw lastError ?? StateError('BLE discoverServices failed');
  }

  bool _isTransientDisconnectError(Object error) {
    if (error is PlatformException) {
      return _isTransientDisconnectCode(error.code) ||
          _isTransientDisconnectCode(error.message);
    }

    return _isTransientDisconnectCode(error.toString());
  }

  bool _isTransientDisconnectCode(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == 'e_ble_device_disconnected' ||
        normalized == 'e_device_disconnected' ||
        normalized == 'e_ble_connection_interrupted' ||
        normalized == 'devicedisconnected' ||
        normalized == 'device is disconnected' ||
        (normalized?.contains('device is disconnected') ?? false);
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

  void _log(String message) {}

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
