import 'dart:async';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_debug_registry.dart';
import 'ble_scan_result.dart';
import 'eixam_ble_command.dart';
import 'eixam_ble_notification.dart';

final class LazyInitializingBleClient implements BleClient {
  LazyInitializingBleClient(this._delegate) {
    BleDebugRegistry.instance.registerScanner(scan);
  }

  final BleClient _delegate;
  Future<void>? _initializeFuture;

  Future<void> _ensureInitialized() {
    final existing = _initializeFuture;
    if (existing != null) {
      return existing;
    }
    final future = _delegate.initialize();
    _initializeFuture = future;
    return future;
  }

  @override
  Future<void> initialize() => _ensureInitialized();

  @override
  Future<BleAdapterState> getAdapterState() async {
    await _ensureInitialized();
    return _delegate.getAdapterState();
  }

  @override
  Stream<BleAdapterState> watchAdapterState() async* {
    await _ensureInitialized();
    yield* _delegate.watchAdapterState();
  }

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    await _ensureInitialized();
    return _delegate.scan(timeout: timeout);
  }

  @override
  Future<void> connect(String deviceId) async {
    await _ensureInitialized();
    return _delegate.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    await _ensureInitialized();
    return _delegate.disconnect(deviceId);
  }

  @override
  Future<bool> isConnected(String deviceId) async {
    await _ensureInitialized();
    return _delegate.isConnected(deviceId);
  }

  @override
  Future<bool> hasSystemAssociation(String deviceId) async {
    await _ensureInitialized();
    return _delegate.hasSystemAssociation(deviceId);
  }

  @override
  Future<bool> removeSystemAssociation(String deviceId) async {
    await _ensureInitialized();
    return _delegate.removeSystemAssociation(deviceId);
  }

  @override
  Future<List<BleScanResult>> listSystemAssociatedDevices() async {
    await _ensureInitialized();
    return _delegate.listSystemAssociatedDevices();
  }

  @override
  Stream<bool> watchConnection(String deviceId) async* {
    await _ensureInitialized();
    yield* _delegate.watchConnection(deviceId);
  }

  @override
  Future<int?> readBatteryLevel(String deviceId) async {
    await _ensureInitialized();
    return _delegate.readBatteryLevel(deviceId);
  }

  @override
  Future<int?> readSignalQuality(String deviceId) async {
    await _ensureInitialized();
    return _delegate.readSignalQuality(deviceId);
  }

  @override
  Future<String?> readFirmwareVersion(String deviceId) async {
    await _ensureInitialized();
    return _delegate.readFirmwareVersion(deviceId);
  }

  @override
  Future<void> writeDeviceCommand(
    String deviceId,
    EixamDeviceCommand command,
  ) async {
    await _ensureInitialized();
    return _delegate.writeDeviceCommand(deviceId, command);
  }

  @override
  Future<Stream<EixamBleNotification>> subscribeEixamNotifications(
    String deviceId,
  ) async {
    await _ensureInitialized();
    return _delegate.subscribeEixamNotifications(deviceId);
  }

  @override
  Future<bool> isEixamCompatible(String deviceId) async {
    await _ensureInitialized();
    return _delegate.isEixamCompatible(deviceId);
  }
}
