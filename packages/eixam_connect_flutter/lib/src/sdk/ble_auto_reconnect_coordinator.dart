import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';

import '../data/datasources_local/preferred_ble_device_store.dart';
import '../device/ble_connection_status.dart';
import '../device/ble_debug_registry.dart';
import '../device/known_device_reconnect_repository.dart';
import '../device/preferred_ble_device.dart';

class BleAutoReconnectCoordinator {
  BleAutoReconnectCoordinator({
    required DeviceRepository deviceRepository,
    required PreferredBleDeviceStore preferredDeviceStore,
    this.autoReconnectPairingCode = 'AUTO-RECONNECT',
    bool Function()? isIosPlatform,
  })  : _deviceRepository = deviceRepository,
        _preferredDeviceStore = preferredDeviceStore,
        _isIosPlatform = isIosPlatform ?? (() => Platform.isIOS);

  // The first retry waits longer than flutter_blue_plus's internal 2 s
  // disconnect-gap so that the previous BluetoothGatt has fully closed
  // before we issue a new connect; reconnecting too soon races Android's
  // duplicate onConnectionStateChange callback and FBP rejects it as an
  // "[unexpected connection]".
  static const List<Duration> _retryBackoff = <Duration>[
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  final DeviceRepository _deviceRepository;
  final PreferredBleDeviceStore _preferredDeviceStore;
  final String autoReconnectPairingCode;
  final bool Function() _isIosPlatform;

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
    _manualDisconnectRequested =
        await _preferredDeviceStore.readManualDisconnectRequested();
    await _deviceStatusSub?.cancel();
    _deviceStatusSub = deviceStatusStream.listen(_handleDeviceStatus);
  }

  Future<DeviceStatus> pairDeviceManually({required String pairingCode}) async {
    await onManualConnectRequested();
    return _runConnectionAttempt(
      reason: 'manual_connect',
      status: BleConnectionStatus.connecting,
      action: () => _deviceRepository.pairDevice(pairingCode: pairingCode),
      allowSingleTransientDisconnectRetry: true,
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

  Future<void> tryAutoConnect({required String trigger}) async {
    await _tryAutoConnect(trigger: trigger);
  }

  Future<bool> tryAutoConnectForHandoff({
    required String trigger,
    required String attemptId,
    String? platformRemoteId,
  }) {
    return _tryAutoConnect(
      trigger: trigger,
      attemptId: attemptId,
      platformRemoteId: platformRemoteId,
    );
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
      unawaited(_tryAutoConnect(trigger: 'retry').then<void>((_) {}));
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
    final wasForeground = _isAppForeground;
    _isAppForeground = isForeground;
    if (!isForeground) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    if (!wasForeground) {
      unawaited(_tryAutoConnect(trigger: 'foreground').then<void>((_) {}));
    }
  }

  Future<void> dispose() async {
    _retryTimer?.cancel();
    await _deviceStatusSub?.cancel();
  }

  Future<bool> _tryAutoConnect({
    required String trigger,
    String? attemptId,
    String? platformRemoteId,
  }) async {
    if (_manualDisconnectRequested) {
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because manual disconnect is active',
      );
      _recordNoProviderCall(
        attemptId: attemptId,
        reason: 'connect_guard_blocked',
      );
      return false;
    }
    if (!_isAppForeground && trigger != 'startup') {
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because app is not in foreground',
      );
      _recordNoProviderCall(
        attemptId: attemptId,
        reason: 'connect_guard_blocked',
      );
      return false;
    }
    if (_isConnectionAttemptInProgress) {
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because connection is already in progress',
      );
      _recordNoProviderCall(attemptId: attemptId, reason: 'inflight_blocked');
      return false;
    }

    final currentStatus = await _deviceRepository.getDeviceStatus();
    if (currentStatus.connected) {
      final refreshedStatus = await _deviceRepository.refreshDeviceStatus();
      if (refreshedStatus.connected &&
          await _isCommandChannelAvailableForConnectedDevice()) {
        BleDebugRegistry.instance.recordEvent(
          'BLE_AUTO_CONNECT_SKIPPED trigger=$trigger reason=command_channel_ready',
        );
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'unsupported_state',
        );
        return false;
      }
      if (refreshedStatus.connected) {
        BleDebugRegistry.instance.recordEvent(
          'BLE_AUTO_CONNECT_REBIND trigger=$trigger reason=command_channel_not_ready',
        );
      }
    }

    final preferredDevice = await _preferredDeviceStore.getPreferredDevice() ??
        _preferredDeviceFromStatus(currentStatus);
    final overrideRemoteId = platformRemoteId?.trim();
    final reconnectDevice = _preferredDeviceWithPlatformRemoteId(
      preferredDevice: preferredDevice,
      platformRemoteId: overrideRemoteId,
    );
    if (reconnectDevice == null) {
      if (attemptId != null && _isIosPlatform()) {
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_RECONNECT_ID_MISSING_AT_SDK attemptId=$attemptId',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because no preferred device is stored',
      );
      _recordNoProviderCall(attemptId: attemptId, reason: 'missing_remote_id');
      return false;
    }
    final remoteId = reconnectDevice.deviceId.trim();
    if (_isIosPlatform() && !_isValidIosBleRemoteId(reconnectDevice.deviceId)) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_IDENTITY_RESOLVED platform=ios '
        'logicalId=${reconnectDevice.deviceId} remoteIdPresent=false',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_RECONNECT_ID_DROPPED source=sdk_preferred_device_store '
        'attemptId=${attemptId ?? 'none'} length=${remoteId.length} '
        'uuidShape=${_isValidIosBleRemoteId(remoteId)}',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_RECONNECT_REQUIRES_SCAN '
        'platform=ios reason=${_missingRemoteIdReconnectReason(trigger)}',
      );
      _recordNoProviderCall(attemptId: attemptId, reason: 'missing_remote_id');
      return false;
    }
    if (_isIosPlatform()) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_IDENTITY_RESOLVED platform=ios '
        'logicalId=${currentStatus.deviceId} remoteIdPresent=true',
      );
      BleDebugRegistry.instance.recordEvent(
        'SDK_RECONNECT_REMOTE_ID_RESOLVED '
        'attemptId=${attemptId ?? 'none'} platform=ios '
        'remoteId=${_redactedReconnectId(remoteId)} '
        'length=${remoteId.length} '
        'validCoreBluetoothUuid=${_isValidIosBleRemoteId(remoteId)}',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_RECONNECT_ALLOWED '
        'platform=ios reason=${_allowedReconnectReason(trigger)}',
      );
    }

    BleDebugRegistry.instance.recordEvent(
      '$trigger auto-connect started for ${reconnectDevice.deviceId}',
    );
    BleDebugRegistry.instance.selectDevice(reconnectDevice.deviceId);
    final reconnectRepository = _deviceRepository;
    if (reconnectRepository is! KnownDeviceReconnectRepository) {
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because repository cannot restore known devices',
      );
      _recordNoProviderCall(
        attemptId: attemptId,
        reason: 'unsupported_state',
      );
      return false;
    }
    final knownDeviceReconnectRepository =
        reconnectRepository as KnownDeviceReconnectRepository;
    try {
      await _runConnectionAttempt(
        reason: '${trigger}_auto_connect',
        status: BleConnectionStatus.reconnecting,
        action: () => knownDeviceReconnectRepository.reconnectDevice(
          device: reconnectDevice,
          attemptId: attemptId,
        ),
      );
      return true;
    } catch (error) {
      if (_isMobileBondRequired(error)) {
        await _handleMissingMobileBond(reconnectDevice.deviceId);
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'unsupported_state',
        );
        return false;
      }
      if (_isInvalidBleRemoteId(error)) {
        BleDebugRegistry.instance.recordEvent(
          'BLE_RECONNECT_DEFERRED reason=screen_not_visible_or_not_user_initiated',
        );
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'missing_remote_id',
        );
        return false;
      }
      if (_isRuntimeNotReady(error)) {
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'runtime_not_ready',
        );
        return false;
      }
      onUnexpectedDisconnect();
      return true;
    }
  }

  PreferredBleDevice? _preferredDeviceFromStatus(DeviceStatus status) {
    if (!status.paired || status.deviceId.trim().isEmpty) {
      return null;
    }
    return PreferredBleDevice(
      deviceId: status.deviceId,
      displayName: status.deviceAlias,
      lastConnectedAt: status.lastSyncedAt ?? status.lastSeen ?? DateTime.now(),
    );
  }

  PreferredBleDevice? _preferredDeviceWithPlatformRemoteId({
    required PreferredBleDevice? preferredDevice,
    required String? platformRemoteId,
  }) {
    if (platformRemoteId == null || platformRemoteId.isEmpty) {
      return preferredDevice;
    }
    return PreferredBleDevice(
      deviceId: platformRemoteId,
      displayName: preferredDevice?.displayName,
      lastConnectedAt: preferredDevice?.lastConnectedAt ?? DateTime.now(),
    );
  }

  Future<bool> _isCommandChannelAvailableForConnectedDevice() async {
    try {
      final identity = await _deviceRepository.getRuntimeIdentitySnapshot();
      return identity.serviceBleConnected && identity.commandCapable;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE_CONNECTED_DEVICE_COMMAND_READINESS_CHECK_FAILED error=$error',
      );
      return false;
    }
  }

  Future<DeviceStatus> _runConnectionAttempt({
    required String reason,
    required BleConnectionStatus status,
    required Future<DeviceStatus> Function() action,
    bool allowSingleTransientDisconnectRetry = false,
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
      DeviceStatus result;
      try {
        result = await action();
      } catch (error) {
        if (!allowSingleTransientDisconnectRetry ||
            !_isTransientDisconnectError(error)) {
          rethrow;
        }
        BleDebugRegistry.instance.recordEvent(
          'manual_connect_transient_disconnect_detected error=$error',
        );
        BleDebugRegistry.instance.recordEvent('manual_connect_retry_start');
        try {
          result = await action();
        } catch (retryError) {
          BleDebugRegistry.instance.recordEvent(
            'manual_connect_retry_failed error=$retryError',
          );
          rethrow;
        }
        BleDebugRegistry.instance.recordEvent('manual_connect_retry_success');
      }
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

  bool _isTransientDisconnectError(Object error) {
    if (error is DeviceException) {
      return _isTransientDisconnectCode(error.code);
    }
    if (error is PlatformException) {
      return _isTransientDisconnectCode(error.code) ||
          _isTransientDisconnectCode(error.message);
    }
    return false;
  }

  bool _isTransientDisconnectCode(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == 'e_ble_device_disconnected' ||
        normalized == 'e_device_disconnected' ||
        normalized == 'e_ble_connection_interrupted' ||
        normalized == 'devicedisconnected';
  }

  bool _isMobileBondRequired(Object error) {
    return error is DeviceException &&
        error.code == 'E_DEVICE_MOBILE_BOND_REQUIRED';
  }

  bool _isInvalidBleRemoteId(Object error) {
    return error is DeviceException &&
        error.code == 'E_DEVICE_INVALID_BLE_REMOTE_ID';
  }

  bool _isRuntimeNotReady(Object error) {
    return error is DeviceException && error.code == 'E_DEVICE_BLUETOOTH_OFF';
  }

  bool _isValidIosBleRemoteId(String value) {
    return RegExp(
      r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
    ).hasMatch(value.trim());
  }

  String _allowedReconnectReason(String trigger) {
    if (trigger == 'user_action') {
      return 'user_action_valid_remote_id';
    }
    if (trigger == 'readiness_became_ready_devices_visible') {
      return 'readiness_became_ready_devices_visible';
    }
    return 'valid_remote_id_devices_visible';
  }

  String _missingRemoteIdReconnectReason(String trigger) {
    if (trigger == 'user_action') {
      return 'user_action_missing_valid_remote_id';
    }
    return 'missing_valid_remote_id';
  }

  void _recordNoProviderCall(
      {required String? attemptId, required String reason}) {
    if (attemptId == null) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'BLE_RECONNECT_FAILED_NO_PROVIDER_CALL '
      'reason=$reason attemptId=$attemptId',
    );
  }

  String _redactedReconnectId(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 8) {
      return trimmed.isEmpty ? 'none' : 'redacted:${trimmed.length}';
    }
    return '${trimmed.substring(0, 4)}...${trimmed.substring(trimmed.length - 4)}';
  }

  Future<void> _handleMissingMobileBond(String deviceId) async {
    _manualDisconnectRequested = true;
    await _preferredDeviceStore.saveManualDisconnectRequested(true);
    await _preferredDeviceStore.clearPreferredDevice();
    _retryAttempt = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
    BleDebugRegistry.instance.update(
      connectionStatus: BleConnectionStatus.disconnectedManual,
      connectionError: null,
    );
    BleDebugRegistry.instance.recordEvent(
      'BLE_AUTO_RECONNECT_STOPPED reason=android_bond_missing hardwareId=$deviceId',
    );
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
