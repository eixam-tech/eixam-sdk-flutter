import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/device_runtime_provider.dart';
import '../../device/ble_device_runtime_provider.dart';
import '../datasources_local/shared_prefs_sdk_store.dart';
import '../../mappers/local_state_serializers.dart';

/// Local-first device repository used by the starter project.
///
/// It persists the latest device state, delegates runtime mutations to a
/// provider and emits heartbeat updates so the host app can build UX around a
/// living device model before BLE or backend integration lands.
class InMemoryDeviceRepository implements DeviceRepository {
  InMemoryDeviceRepository({
    required DeviceRuntimeProvider runtimeProvider,
    SharedPrefsSdkStore? localStore,
  })  : _runtimeProvider = runtimeProvider,
        _localStore = localStore {
    _runtimeStatusSub =
        _runtimeProvider.watchRuntimeStatus().listen((status) async {
      _status = status;
      await _persistAndEmit();
    });
  }

  final DeviceRuntimeProvider _runtimeProvider;
  final SharedPrefsSdkStore? _localStore;
  final StreamController<DeviceStatus> _controller =
      StreamController<DeviceStatus>.broadcast();
  StreamSubscription<DeviceStatus>? _runtimeStatusSub;

  Timer? _heartbeatTimer;
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
      _status = LocalStateSerializers.deviceStatusFromJson(raw);
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
      await _setFailure(error.message);
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
    _status = await _runtimeProvider.refresh(_status);
    await _persistAndEmit();
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
      _status = runtimeStatus;
      await _persistAndEmit();
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
      _status = runtimeStatus;
      await _persistAndEmit();
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
      _status = await _runtimeProvider.refresh(_status);
      await _persistAndEmit();
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
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

  Future<void> _persistAndEmit() async {
    await _localStore?.saveJson(
      SharedPrefsSdkStore.deviceStatusKey,
      LocalStateSerializers.deviceStatusToJson(_status),
    );
    _controller.add(_status);
  }

  /// TODO: promote disposal to a shared repository lifecycle contract if more
  /// runtime-backed repositories need explicit cleanup.
  Future<void> dispose() async {
    _stopHeartbeat();
    await _runtimeStatusSub?.cancel();
    await _controller.close();
  }
}
