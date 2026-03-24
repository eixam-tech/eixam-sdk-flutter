import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import '../device/ble_debug_registry.dart';
import '../device/ble_debug_state.dart';
import '../device/ble_scan_result.dart';
import 'ble_diagnostics_view_state.dart';
import 'device_view_state.dart';
import 'sos_view_state.dart';

class DeviceDebugController extends ChangeNotifier {
  DeviceDebugController({required this.sdk});

  final EixamConnectSdk sdk;

  DeviceStatus? status;
  DeviceSosStatus deviceSosStatus = DeviceSosStatus.initial();
  PermissionState? permissionState;
  BleDebugState bleDebugState = BleDebugRegistry.instance.currentState;
  String? lastError;
  bool loadingDevice = false;
  bool loadingSos = false;
  bool loadingScan = false;
  bool loadingPermissions = false;
  bool loadingNotifications = false;

  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<DeviceSosStatus>? _deviceSosSub;
  StreamSubscription<BleDebugState>? _bleDebugSub;

  DeviceViewState get deviceViewState => DeviceViewState.fromStatus(status);
  SosViewState get deviceSosViewState => SosViewState.fromDeviceStatus(
        status: deviceSosStatus,
        isBusy: loadingSos,
      );
  BleDiagnosticsViewState get diagnosticsViewState =>
      BleDiagnosticsViewState.fromState(bleDebugState);

  Future<void> initialize() async {
    _bindStreams();
    await refreshAll();
  }

  void _bindStreams() {
    _deviceStatusSub ??= sdk.watchDeviceStatus().listen(
      (next) {
        status = next;
        notifyListeners();
      },
      onError: _handleError,
    );

    _deviceSosSub ??= sdk.watchDeviceSosStatus().listen(
      (next) {
        deviceSosStatus = next;
        notifyListeners();
      },
      onError: _handleError,
    );

    _bleDebugSub ??= BleDebugRegistry.instance.watch().listen(
      (next) {
        bleDebugState = next;
        notifyListeners();
      },
    );
  }

  Future<void> refreshAll() async {
    try {
      status = await sdk.getDeviceStatus();
      deviceSosStatus = await sdk.getDeviceSosStatus();
      permissionState = await sdk.getPermissionState();
      notifyListeners();
    } catch (error) {
      _handleError(error);
    }
  }

  Future<void> pairDevice() {
    return _runDeviceAction(() async {
      await _ensureScanPrerequisites(requestIfMissing: true);
      await sdk.pairDevice(pairingCode: 'DEMO-PAIR-001');
    });
  }

  Future<void> pairSelectedDevice(BleScanResult scan) async {
    BleDebugRegistry.instance.selectDevice(scan.deviceId);
    await pairDevice();
  }

  Future<void> activateDevice() {
    return _runDeviceAction(
      () => sdk.activateDevice(activationCode: 'DEMO-ACT-001'),
    );
  }

  Future<void> refreshDevice() {
    return _runDeviceAction(sdk.refreshDeviceStatus);
  }

  Future<void> unpairDevice() {
    return _runDeviceAction(() async {
      await sdk.unpairDevice();
    });
  }

  Future<void> triggerDeviceSos() => _runSosAction(sdk.triggerDeviceSos);
  Future<void> confirmDeviceSos() => _runSosAction(sdk.confirmDeviceSos);
  Future<void> cancelDeviceSos() => _runSosAction(sdk.cancelDeviceSos);
  Future<void> acknowledgeDeviceSos() =>
      _runSosAction(sdk.acknowledgeDeviceSos);

  Future<void> requestScanPermissions() async {
    loadingPermissions = true;
    lastError = null;
    notifyListeners();
    try {
      await _ensureScanPrerequisites(requestIfMissing: true);
    } catch (error) {
      _handleError(error);
    } finally {
      loadingPermissions = false;
      notifyListeners();
    }
  }

  Future<void> refreshPermissions() async {
    loadingPermissions = true;
    lastError = null;
    notifyListeners();
    try {
      permissionState = await sdk.getPermissionState();
    } catch (error) {
      _handleError(error);
    } finally {
      loadingPermissions = false;
      notifyListeners();
    }
  }

  Future<void> requestNotificationPermission() async {
    loadingPermissions = true;
    lastError = null;
    notifyListeners();
    try {
      permissionState = await sdk.requestNotificationPermission();
    } catch (error) {
      _handleError(error);
    } finally {
      loadingPermissions = false;
      notifyListeners();
    }
  }

  Future<void> initializeNotifications() async {
    loadingNotifications = true;
    lastError = null;
    notifyListeners();
    try {
      await sdk.initializeNotifications();
    } catch (error) {
      _handleError(error);
    } finally {
      loadingNotifications = false;
      notifyListeners();
    }
  }

  Future<void> showTestNotification() async {
    loadingNotifications = true;
    lastError = null;
    notifyListeners();
    try {
      await sdk.showLocalNotification(
        title: 'EIXAM test notification',
        body: 'Local notifications are working in the technical lab.',
      );
    } catch (error) {
      _handleError(error);
    } finally {
      loadingNotifications = false;
      notifyListeners();
    }
  }

  Future<void> runScan() async {
    loadingScan = true;
    lastError = null;
    notifyListeners();
    try {
      final ready = await _ensureScanPrerequisites(requestIfMissing: true);
      if (!ready) {
        throw StateError(
          'Bluetooth permission or adapter state is not ready for scanning.',
        );
      }
      await BleDebugRegistry.instance.startScan();
    } catch (error) {
      _handleError(error);
    } finally {
      loadingScan = false;
      notifyListeners();
    }
  }

  Future<void> sendInetOk() => _runCommandAction(sdk.sendInetOkToDevice);
  Future<void> sendInetLost() => _runCommandAction(sdk.sendInetLostToDevice);
  Future<void> sendPositionConfirmed() =>
      _runCommandAction(sdk.sendPositionConfirmedToDevice);
  Future<void> sendShutdown() => _runCommandAction(sdk.sendShutdownToDevice);

  Future<void> sendAckRelay(String rawNodeId) async {
    final raw = rawNodeId.trim();
    if (raw.isEmpty) {
      _handleError(StateError('Enter a nodeId for SOS_ACK_RELAY.'));
      return;
    }

    final nodeId = _parseNodeId(raw);
    if (nodeId == null) {
      _handleError(
          StateError('Invalid nodeId. Use decimal or hex like 0x1AA8.'));
      return;
    }
    if (nodeId < 0 || nodeId > 0xFFFF) {
      _handleError(
        StateError('SOS_ACK_RELAY expects a 16-bit nodeId (0 to 65535).'),
      );
      return;
    }

    await _runCommandAction(() => sdk.sendSosAckRelayToDevice(nodeId: nodeId));
  }

  Future<void> _runDeviceAction(Future<dynamic> Function() action) async {
    loadingDevice = true;
    lastError = null;
    notifyListeners();
    try {
      await action();
      status = await sdk.getDeviceStatus();
    } catch (error) {
      _handleError(error);
    } finally {
      loadingDevice = false;
      notifyListeners();
    }
  }

  Future<void> _runSosAction(Future<DeviceSosStatus> Function() action) async {
    loadingSos = true;
    lastError = null;
    notifyListeners();
    try {
      deviceSosStatus = await action();
    } catch (error) {
      _handleError(error);
    } finally {
      loadingSos = false;
      notifyListeners();
    }
  }

  Future<void> _runCommandAction(Future<void> Function() action) async {
    lastError = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      _handleError(error);
    }
  }

  Future<bool> _ensureScanPrerequisites({
    required bool requestIfMissing,
  }) async {
    var next = await sdk.getPermissionState();
    if (requestIfMissing && !next.hasBluetoothAccess) {
      next = await sdk.requestBluetoothPermission();
    }
    if (requestIfMissing &&
        !next.hasLocationAccess &&
        next.location != SdkPermissionStatus.serviceDisabled) {
      next = await sdk.requestLocationPermission();
    }
    permissionState = next;
    notifyListeners();
    return next.hasBluetoothAccess && next.bluetoothEnabled;
  }

  int? _parseNodeId(String raw) {
    if (raw.startsWith('0x') || raw.startsWith('0X')) {
      return int.tryParse(raw.substring(2), radix: 16);
    }
    return int.tryParse(raw);
  }

  void _handleError(Object error) {
    lastError = error.toString();
    notifyListeners();
  }

  @override
  void dispose() {
    _deviceStatusSub?.cancel();
    _deviceSosSub?.cancel();
    _bleDebugSub?.cancel();
    super.dispose();
  }
}
