import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/preferred_ble_device_store.dart';
import '../device/ble_connection_status.dart';
import '../device/ble_debug_registry.dart';
import '../device/preferred_ble_device.dart';

class BleAutoReconnectCoordinator {
  BleAutoReconnectCoordinator({
    required DeviceRepository deviceRepository,
    required PreferredBleDeviceStore preferredDeviceStore,
    this.autoReconnectPairingCode = 'AUTO-RECONNECT',
  }) : _deviceRepository = deviceRepository,
       _preferredDeviceStore = preferredDeviceStore;

  static const List<Duration> _retryBackoff = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
  ];

  final DeviceRepository _deviceRepository;
  final PreferredBleDeviceStore _preferredDeviceStore;
  final String autoReconnectPairingCode;

  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  Timer? _retryTimer;
  DeviceStatus? _lastStatus;
  bool _manualDisconnectRequested = false;
  bool _isConnectionAttemptInProgress = false;
  bool _isAppForeground = true;
  int _retryAttempt = 0;

  Future<void> initialize({
    required DeviceStatus initialStatus,
    required Stream<DeviceStatus> deviceStatusStream,
  }) async {
    _lastStatus = initialStatus;
    _manualDisconnectRequested = await _preferredDeviceStore
        .readManualDisconnectRequested();
    await _deviceStatusSub?.cancel();
    _deviceStatusSub = deviceStatusStream.listen(_handleDeviceStatus);
  }

  Future<DeviceStatus> pairDeviceManually({required String pairingCode}) async {
    await onManualConnectRequested();
    return _runConnectionAttempt(
      reason: 'manual_connect',
      status: BleConnectionStatus.connecting,
      action: () => _deviceRepository.pairDevice(pairingCode: pairingCode),
    );
  }

  Future<void> unpairDeviceManually(Future<void> Function() action) async {
    await onManualDisconnect();
    await action();
    await _preferredDeviceStore.clearPreferredDevice();
    BleDebugRegistry.instance.recordEvent(
      'Preferred BLE device cleared after manual unpair',
    );
  }

  Future<void> tryAutoConnectOnStartup() async {
    await _tryAutoConnect(trigger: 'startup');
  }

  Future<void> tryAutoConnectOnResume() async {
    await _tryAutoConnect(trigger: 'resume');
  }

  void onUnexpectedDisconnect() {
    if (_manualDisconnectRequested) {
      BleDebugRegistry.instance.recordEvent(
        'Reconnect skipped because manual disconnect is active',
      );
      return;
    }
    if (!_isAppForeground) {
      BleDebugRegistry.instance.recordEvent(
        'Reconnect skipped because app is not in foreground',
      );
      return;
    }
    if (_isConnectionAttemptInProgress) {
      BleDebugRegistry.instance.recordEvent(
        'Reconnect skipped because another connection attempt is already in progress',
      );
      return;
    }
    if (_retryTimer != null) {
      BleDebugRegistry.instance.recordEvent(
        'Reconnect already scheduled; skipping duplicate request',
      );
      return;
    }

    final backoffIndex = _retryAttempt.clamp(0, _retryBackoff.length - 1);
    final delay = _retryBackoff[backoffIndex];
    _retryAttempt++;
    BleDebugRegistry.instance.update(
      connectionStatus: BleConnectionStatus.reconnectScheduled,
      connectionError: null,
    );
    BleDebugRegistry.instance.recordEvent(
      'Reconnect scheduled in ${delay.inSeconds}s',
    );
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_tryAutoConnect(trigger: 'retry'));
    });
  }

  Future<void> onManualDisconnect() async {
    _manualDisconnectRequested = true;
    await _preferredDeviceStore.saveManualDisconnectRequested(true);
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    BleDebugRegistry.instance.update(
      connectionStatus: BleConnectionStatus.disconnectedManual,
      connectionError: null,
    );
    BleDebugRegistry.instance.recordEvent(
      'Manual disconnect requested; auto-reconnect disabled',
    );
  }

  Future<void> onManualConnectRequested() async {
    _manualDisconnectRequested = false;
    await _preferredDeviceStore.saveManualDisconnectRequested(false);
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    BleDebugRegistry.instance.recordEvent(
      'Manual connect requested; auto-reconnect re-enabled',
    );
  }

  void setAppForeground(bool isForeground) {
    _isAppForeground = isForeground;
    if (!isForeground) {
      _retryTimer?.cancel();
      _retryTimer = null;
    }
  }

  Future<void> dispose() async {
    _retryTimer?.cancel();
    await _deviceStatusSub?.cancel();
  }

  Future<void> _tryAutoConnect({required String trigger}) async {
    if (_manualDisconnectRequested) {
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because manual disconnect is active',
      );
      return;
    }
    if (!_isAppForeground && trigger != 'startup') {
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because app is not in foreground',
      );
      return;
    }
    if (_isConnectionAttemptInProgress) {
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because connection is already in progress',
      );
      return;
    }

    final currentStatus = await _deviceRepository.getDeviceStatus();
    if (currentStatus.connected) {
      final refreshedStatus = await _deviceRepository.refreshDeviceStatus();
      if (refreshedStatus.connected) {
        BleDebugRegistry.instance.recordEvent(
          '$trigger auto-connect skipped because device is already connected',
        );
        return;
      }
    }

    final preferredDevice = await _preferredDeviceStore.getPreferredDevice();
    if (preferredDevice == null) {
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because no preferred device is stored',
      );
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      '$trigger auto-connect started for ${preferredDevice.deviceId}',
    );
    BleDebugRegistry.instance.selectDevice(preferredDevice.deviceId);
    try {
      await _runConnectionAttempt(
        reason: '${trigger}_auto_connect',
        status: BleConnectionStatus.reconnecting,
        action: () => _deviceRepository.pairDevice(
          pairingCode: autoReconnectPairingCode,
        ),
      );
    } catch (_) {
      onUnexpectedDisconnect();
    }
  }

  Future<DeviceStatus> _runConnectionAttempt({
    required String reason,
    required BleConnectionStatus status,
    required Future<DeviceStatus> Function() action,
  }) async {
    if (_isConnectionAttemptInProgress) {
      throw StateError('BLE connection attempt already in progress.');
    }

    _isConnectionAttemptInProgress = true;
    BleDebugRegistry.instance.update(
      connectionStatus: status,
      connectionError: null,
    );
    try {
      final result = await action();
      _retryAttempt = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
      BleDebugRegistry.instance.recordEvent('Reconnect success -> $reason');
      return result;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Reconnect failed -> $reason error=$error',
      );
      rethrow;
    } finally {
      _isConnectionAttemptInProgress = false;
    }
  }

  Future<void> _handleDeviceStatus(DeviceStatus status) async {
    final previousStatus = _lastStatus;
    _lastStatus = status;

    if (status.connected) {
      _retryAttempt = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
      final becameConnected = previousStatus?.connected != true;
      final deviceChanged = previousStatus?.deviceId != status.deviceId;
      if (becameConnected || deviceChanged) {
        final preferredDevice = PreferredBleDevice(
          deviceId: status.deviceId,
          displayName: status.deviceAlias,
          lastConnectedAt: DateTime.now(),
        );
        await _preferredDeviceStore.savePreferredDevice(preferredDevice);
        BleDebugRegistry.instance.recordEvent(
          'Preferred BLE device saved -> ${preferredDevice.deviceId}',
        );
      }
      return;
    }

    if (previousStatus?.connected == true) {
      if (_manualDisconnectRequested) {
        BleDebugRegistry.instance.update(
          connectionStatus: BleConnectionStatus.disconnectedManual,
          connectionError: null,
        );
        return;
      }

      BleDebugRegistry.instance.update(
        connectionStatus: BleConnectionStatus.disconnectedUnexpected,
        connectionError: 'Unexpected BLE disconnect',
      );
      BleDebugRegistry.instance.recordEvent(
        'Unexpected disconnect detected for ${status.deviceId}',
      );
      onUnexpectedDisconnect();
    }
  }
}
