import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/ble_debug_registry.dart';
import '../../device/device_runtime_provider.dart';
import '../../device/ble_device_runtime_provider.dart';
import '../../device/known_device_reconnect_repository.dart';
import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../mappers/local_state_serializers.dart';

/// Local-first device repository used by the starter project.
///
/// It persists the latest device state, delegates runtime mutations to a
/// provider and emits heartbeat updates so the host app can build UX around a
/// living device model before BLE or backend integration lands.
class InMemoryDeviceRepository
    implements DeviceRepository, KnownDeviceReconnectRepository {
  InMemoryDeviceRepository({
    required DeviceRuntimeProvider runtimeProvider,
    SharedPrefsSdkStore? localStore,
  })  : _runtimeProvider = runtimeProvider,
        _localStore = localStore {
    _runtimeStatusSub =
        _runtimeProvider.watchRuntimeStatus().listen((status) async {
      final previous = _status;
      _status = status;
      await _persistAndEmitIfChanged(
        previous: previous,
        source: 'runtime_status',
      );
    });
  }

  final DeviceRuntimeProvider _runtimeProvider;
  final SharedPrefsSdkStore? _localStore;
  final StreamController<DeviceStatus> _controller =
      StreamController<DeviceStatus>.broadcast();
  StreamSubscription<DeviceStatus>? _runtimeStatusSub;

  Timer? _heartbeatTimer;
  bool _loggedLightweightHeartbeat = false;
  DeviceStatus _status = const DeviceStatus(
    deviceId: 'demo-device',
    deviceAlias: 'Demo Beacon',
    model: 'EIXAM R1',
    paired: false,
    activated: false,
    connected: false,
    batteryLevel: null,
    batteryState: null,
    batterySource: null,
    firmwareVersion: '0.1.0-demo',
    lifecycleState: DeviceLifecycleState.unpaired,
  );

  /// Restores the last persisted device state, if any.
  Future<void> restoreState() async {
    final raw =
        await _localStore?.readJson(SharedPrefsSdkStore.deviceStatusKey);
    if (raw != null) {
      _status = _normalizeRestoredStatus(
        LocalStateSerializers.deviceStatusFromJson(raw),
      );
    }
    if (_status.connected) {
      _startHeartbeat();
    }
    _controller.add(_status);
  }

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) async {
    await _setLifecycle(DeviceLifecycleState.pairing);
    try {
      _status = await _runtimeProvider.pair(
          currentStatus: _status, pairingCode: pairingCode);
      await _persistAndEmit();
      _startHeartbeat();
      return _status;
    } on DeviceException catch (error) {
      if (_isMobileBondRequired(error)) {
        await _setMobileBondMissing(source: 'pair_mobile_bond_missing');
      } else {
        await _setFailure(error.message);
      }
      rethrow;
    }
  }

  @override
  Future<DeviceStatus> reconnectDevice(
      {required PreferredDevice device}) async {
    if (device.deviceId.trim().isEmpty) {
      throw const DeviceException(
        'E_DEVICE_INVALID_PREFERRED_DEVICE',
        'A preferred BLE device id is required before reconnecting.',
      );
    }
    final previous = _status;
    final reconnectingStatus = _status.copyWith(
      deviceId: device.deviceId,
      deviceAlias: device.displayName ?? _status.deviceAlias,
      paired: true,
      connected: false,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _status = reconnectingStatus;
    await _persistAndEmitIfChanged(
      previous: previous,
      source: 'reconnect_device_start',
    );
    try {
      _status = await _runtimeProvider.reconnect(
        currentStatus: _status,
        preferredDevice: device,
      );
      await _persistAndEmit();
      _startHeartbeat();
      return _status;
    } on DeviceException catch (error) {
      if (_isMobileBondRequired(error)) {
        await _setMobileBondMissing(source: 'mobile_bond_missing');
      } else {
        await _setReconnectUnavailable();
      }
      rethrow;
    } catch (_) {
      await _setReconnectUnavailable();
      rethrow;
    }
  }

  @override
  Future<DeviceStatus> activateDevice({required String activationCode}) async {
    await _setLifecycle(DeviceLifecycleState.activating);
    try {
      _status = await _runtimeProvider.activate(
          currentStatus: _status, activationCode: activationCode);
      await _persistAndEmit();
      _startHeartbeat();
      return _status;
    } on DeviceException catch (error) {
      await _setFailure(error.message);
      rethrow;
    }
  }

  @override
  Future<DeviceStatus> getDeviceStatus() async => _status;

  @override
  Future<DeviceStatus> refreshDeviceStatus() async {
    final previous = _status;
    _status = await _runtimeProvider.refresh(_status);
    await _persistAndEmitIfChanged(
      previous: previous,
      source: 'refresh_device_status',
    );
    return _status;
  }

  Future<DeviceStatus> markDeviceDisconnected({required String reason}) async {
    _stopHeartbeat();
    final previous = _status;
    _status = _status.copyWith(
      paired: true,
      connected: false,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
      lastSyncedAt: DateTime.now(),
    );
    await _persistAndEmitIfChanged(
      previous: previous,
      source: reason,
    );
    return _status;
  }

  Future<DeviceStatus> markMobileBondMissing({required String reason}) async {
    await _setMobileBondMissing(source: reason);
    return _status;
  }

  @override
  Future<void> unpairDevice() async {
    _stopHeartbeat();
    _status = await _runtimeProvider.unpair(_status);
    await _persistAndEmit();
  }

  @override
  Stream<DeviceStatus> watchDeviceStatus() => _controller.stream;

  @override
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot() async {
    return _runtimeProvider.getRuntimeIdentitySnapshot(_status);
  }

  Future<DeviceStatus> releaseBleOwnershipToProtectionMode({
    required String reason,
  }) async {
    final runtimeProvider = _runtimeProvider;
    if (runtimeProvider is! BleDeviceRuntimeProvider) {
      return _status;
    }
    final runtimeStatus =
        await runtimeProvider.suspendOwnership(reason: reason);
    if (runtimeStatus != null) {
      final previous = _status;
      _status = runtimeStatus;
      await _persistAndEmitIfChanged(
        previous: previous,
        source: 'release_ble_ownership',
      );
    }
    return _status;
  }

  Future<DeviceStatus> reclaimBleOwnershipFromProtectionMode({
    required String reason,
  }) async {
    final runtimeProvider = _runtimeProvider;
    if (runtimeProvider is! BleDeviceRuntimeProvider) {
      return _status;
    }
    final runtimeStatus = await runtimeProvider.resumeOwnership(reason: reason);
    if (runtimeStatus != null) {
      final previous = _status;
      _status = runtimeStatus;
      await _persistAndEmitIfChanged(
        previous: previous,
        source: 'reclaim_ble_ownership',
      );
    }
    return _status;
  }

  bool get hasCommandCapableBleRuntime {
    final runtimeProvider = _runtimeProvider;
    return runtimeProvider is BleDeviceRuntimeProvider &&
        runtimeProvider.hasCommandChannel;
  }

  Future<void> setNotificationVolume(int volume) async {
    final runtimeProvider = _runtimeProvider;
    if (runtimeProvider is! BleDeviceRuntimeProvider) {
      throw const DeviceException(
        'E_DEVICE_COMMAND_NOT_READY',
        'A command-capable BLE runtime is not available.',
      );
    }
    await runtimeProvider.setNotificationVolume(volume);
  }

  Future<void> setSosVolume(int volume) async {
    final runtimeProvider = _runtimeProvider;
    if (runtimeProvider is! BleDeviceRuntimeProvider) {
      throw const DeviceException(
        'E_DEVICE_COMMAND_NOT_READY',
        'A command-capable BLE runtime is not available.',
      );
    }
    await runtimeProvider.setSosVolume(volume);
  }

  Future<DeviceRuntimeStatus> getDeviceRuntimeStatus() async {
    final runtimeProvider = _runtimeProvider;
    if (runtimeProvider is! BleDeviceRuntimeProvider) {
      throw const DeviceException(
        'E_DEVICE_COMMAND_NOT_READY',
        'A command-capable BLE runtime is not available.',
      );
    }
    return runtimeProvider.requestDeviceRuntimeStatus();
  }

  Future<void> rebootDevice() async {
    final runtimeProvider = _runtimeProvider;
    if (runtimeProvider is! BleDeviceRuntimeProvider) {
      throw const DeviceException(
        'E_DEVICE_COMMAND_NOT_READY',
        'A command-capable BLE runtime is not available.',
      );
    }
    await runtimeProvider.rebootDevice();
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (!_status.connected) return;
      final previous = _status;
      if (!_loggedLightweightHeartbeat) {
        BleDebugRegistry.instance.recordEvent(
          '[BATTERY_FLOW] sdk_heartbeat_refresh mode=lightweight readFirmware=false readSignalQuality=false',
        );
        _loggedLightweightHeartbeat = true;
      }
      _status = await _runtimeProvider.refresh(
        _status,
        mode: DeviceRefreshMode.heartbeat,
      );
      await _persistAndEmitIfChanged(
        previous: previous,
        source: 'heartbeat',
      );
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  DeviceStatus _normalizeRestoredStatus(DeviceStatus status) {
    if (!status.connected) {
      return status;
    }
    return status.copyWith(
      connected: false,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
  }

  Future<void> _setLifecycle(DeviceLifecycleState nextState) async {
    _status = _status.copyWith(
      lifecycleState: nextState,
      clearProvisioningError: true,
      lastSyncedAt: DateTime.now(),
    );
    await _persistAndEmit();
  }

  Future<void> _setFailure(String message) async {
    _status = _status.copyWith(
      lifecycleState: DeviceLifecycleState.error,
      provisioningError: message,
      lastSyncedAt: DateTime.now(),
    );
    await _persistAndEmit();
  }

  Future<void> _setReconnectUnavailable() async {
    _stopHeartbeat();
    _status = _status.copyWith(
      paired: true,
      connected: false,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
      lastSyncedAt: DateTime.now(),
    );
    await _persistAndEmit();
  }

  Future<void> _setMobileBondMissing({required String source}) async {
    _stopHeartbeat();
    final previous = _status;
    _status = _status.copyWith(
      paired: false,
      activated: false,
      connected: false,
      lifecycleState: DeviceLifecycleState.unpaired,
      clearProvisioningError: true,
      lastSyncedAt: DateTime.now(),
    );
    await _persistAndEmitIfChanged(
      previous: previous,
      source: source,
    );
  }

  bool _isMobileBondRequired(DeviceException error) {
    return error.code == 'E_DEVICE_MOBILE_BOND_REQUIRED';
  }

  Future<void> _persistAndEmit() async {
    await _localStore?.saveJson(
      SharedPrefsSdkStore.deviceStatusKey,
      LocalStateSerializers.deviceStatusToJson(_status),
    );
    _controller.add(_status);
  }

  Future<void> _persistAndEmitIfChanged({
    required DeviceStatus previous,
    required String source,
  }) async {
    await _localStore?.saveJson(
      SharedPrefsSdkStore.deviceStatusKey,
      LocalStateSerializers.deviceStatusToJson(_status),
    );

    if (_hasEffectiveStatusChange(previous, _status)) {
      BleDebugRegistry.instance.recordEvent(
        'InMemoryDeviceRepository.$source -> effective_change=true connected=${_status.connected} previousConnected=${previous.connected} lifecycle=${_status.lifecycleState.name} hardwareId=${_status.deviceId} nodeId=${_status.nodeId?.toString() ?? "-"}',
      );
      _controller.add(_status);
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      'InMemoryDeviceRepository.$source -> effective_change=false emit_skipped hardwareId=${_status.deviceId} nodeId=${_status.nodeId?.toString() ?? "-"} connected=${_status.connected} lifecycle=${_status.lifecycleState.name}',
    );
  }

  bool _hasEffectiveStatusChange(DeviceStatus previous, DeviceStatus next) {
    return previous.deviceId != next.deviceId ||
        previous.nodeId != next.nodeId ||
        previous.canonicalHardwareId != next.canonicalHardwareId ||
        previous.deviceAlias != next.deviceAlias ||
        previous.model != next.model ||
        previous.paired != next.paired ||
        previous.activated != next.activated ||
        previous.connected != next.connected ||
        previous.batteryLevel != next.batteryLevel ||
        previous.effectiveBatteryState != next.effectiveBatteryState ||
        previous.batterySource != next.batterySource ||
        previous.firmwareVersion != next.firmwareVersion ||
        previous.signalQuality != next.signalQuality ||
        previous.lifecycleState != next.lifecycleState ||
        previous.provisioningError != next.provisioningError;
  }

  /// TODO: promote disposal to a shared repository lifecycle contract if more
  /// runtime-backed repositories need explicit cleanup.
  Future<void> dispose() async {
    _stopHeartbeat();
    await _runtimeStatusSub?.cancel();
    await _controller.close();
  }
}
