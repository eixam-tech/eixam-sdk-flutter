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
    Future<PermissionState> Function()? permissionStateProvider,
    bool Function()? isIosPlatform,
    Future<void> Function(Duration delay)? preferredReconnectDelay,
    List<Duration>? preferredReconnectRetryDelays,
    Duration? readinessMonitorInterval,
  })  : _deviceRepository = deviceRepository,
        _preferredDeviceStore = preferredDeviceStore,
        _permissionStateProvider = permissionStateProvider,
        _preferredReconnectDelay = preferredReconnectDelay,
        _preferredReconnectRetryDelays =
            preferredReconnectRetryDelays ?? _preferredReconnectBackoff,
        _readinessMonitorInterval =
            readinessMonitorInterval ?? const Duration(seconds: 2),
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
  static const int _preferredReconnectMaxAttempts = 10;
  static const List<Duration> _preferredReconnectBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 3),
    Duration(seconds: 4),
    Duration(seconds: 5),
  ];

  final DeviceRepository _deviceRepository;
  final PreferredBleDeviceStore _preferredDeviceStore;
  final Future<PermissionState> Function()? _permissionStateProvider;
  final Future<void> Function(Duration delay)? _preferredReconnectDelay;
  final List<Duration> _preferredReconnectRetryDelays;
  final Duration _readinessMonitorInterval;
  final String autoReconnectPairingCode;
  final bool Function() _isIosPlatform;

  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<PermissionState>? _readinessReconnectSub;
  Timer? _retryTimer;
  Timer? _readinessReconnectTimer;
  Future<PreferredDeviceReconnectResult>? _preferredReconnectCampaign;
  Completer<void>? _preferredReconnectCancellation;
  DeviceStatus? _lastStatus;
  PermissionState? _lastReadinessForReconnectMonitor;
  bool _readinessReconnectPollInFlight = false;
  bool _manualDisconnectRequested = false;
  bool _isConnectionAttemptInProgress = false;
  bool _isAppForeground = true;
  bool _dfuTransferSuppressed = false;
  bool _provisioningReconnectOwned = false;
  bool _disposed = false;
  int _retryAttempt = 0;
  int _preferredReconnectCampaignToken = 0;

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
    try {
      return await _runConnectionAttempt(
        reason: 'manual_connect',
        status: BleConnectionStatus.connecting,
        action: () => _deviceRepository.pairDevice(pairingCode: pairingCode),
        allowSingleTransientDisconnectRetry: true,
      );
    } catch (error) {
      if (_isMobileBondRequired(error)) {
        await _handleMissingMobileBond(
          _manualConnectFailureDeviceId(),
          reason: _mobileBondStopReason(error),
        );
      }
      rethrow;
    }
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

  Future<void> startBleReadinessReconnectMonitor({
    String trigger = 'ble_ready',
    Stream<PermissionState>? readinessStream,
  }) async {
    if (_disposed) {
      return;
    }
    await stopBleReadinessReconnectMonitor();
    _lastReadinessForReconnectMonitor = null;
    final stream = readinessStream;
    if (stream != null) {
      _readinessReconnectSub = stream.listen(
        (readiness) =>
            unawaited(_handleBleReadinessChanged(readiness, trigger: trigger)),
        onError: (Object error) {
          _traceReconnect(
            'sdk_ble_ready_reconnect_skipped reason=readiness_stream_error '
            'error=$error',
          );
        },
      );
      return;
    }
    if (_permissionStateProvider == null) {
      _traceReconnect(
        'sdk_ble_ready_reconnect_skipped reason=no_readiness_provider',
      );
      return;
    }
    unawaited(_pollBleReadinessForReconnect(trigger: trigger));
    _readinessReconnectTimer = Timer.periodic(_readinessMonitorInterval, (_) {
      unawaited(_pollBleReadinessForReconnect(trigger: trigger));
    });
  }

  Future<void> stopBleReadinessReconnectMonitor() async {
    _readinessReconnectTimer?.cancel();
    _readinessReconnectTimer = null;
    _readinessReconnectPollInFlight = false;
    await _readinessReconnectSub?.cancel();
    _readinessReconnectSub = null;
    _lastReadinessForReconnectMonitor = null;
  }

  Future<PreferredDeviceReconnectResult> tryAutoConnectForHandoff({
    required String trigger,
    String? attemptId,
    String? platformRemoteId,
  }) {
    return _tryAutoConnect(
      trigger: trigger,
      attemptId: attemptId,
      platformRemoteId: platformRemoteId,
    );
  }

  /// Gives provisioning exclusive ownership of reconnect across its reboot
  /// boundary. Suppression is set before an existing campaign is cancelled so
  /// no lifecycle, readiness, startup, or retry trigger can replace it while
  /// the in-flight native connection attempt is being drained.
  Future<void> acquireProvisioningReconnectOwnership() async {
    _provisioningReconnectOwned = true;
    _cancelPreferredReconnectCampaign(reason: 'provisioning_reboot');
    _retryTimer?.cancel();
    _retryTimer = null;
    final campaign = _preferredReconnectCampaign;
    if (campaign != null) {
      try {
        await campaign;
      } catch (_) {
        // Only settlement matters. Provisioning will perform the sole allowed
        // reconnect after the reboot disconnect has been validated.
      }
    }
    BleDebugRegistry.instance.recordEvent(
      'PROVISIONING_REBOOT reconnect_ownership_acquired=true',
    );
    BleDebugRegistry.instance.recordEvent(
      'PROVISIONING_REBOOT generic_reconnect_suppressed=true',
    );
  }

  void releaseProvisioningReconnectOwnership() {
    _provisioningReconnectOwned = false;
    BleDebugRegistry.instance.recordEvent(
      'PROVISIONING_REBOOT reconnect_ownership_acquired=false',
    );
  }

  Future<PreferredDeviceReconnectResult> reconnectForProvisioningReboot({
    required String platformRemoteId,
  }) {
    return _tryAutoConnect(
      trigger: 'device_provisioning_reboot',
      platformRemoteId: platformRemoteId,
      allowDuringProvisioningOwnership: true,
    );
  }

  /// Hard-suppresses every auto-reconnect path for the duration of a firmware
  /// DFU transfer. The foreground flag is NOT a safe gate for this: the Android
  /// bonding dialog (or any notification interaction) bounces the activity
  /// through inactive->resumed mid-transfer, which restores the foreground flag
  /// and would immediately fire a reconnect that races the native DFU library
  /// for the device — leaving it stranded in the bootloader at 0%.
  ///
  /// Awaits any connection attempt that is ALREADY awaiting the native stack:
  /// cancelling the campaign only stops the next iteration, so a connect
  /// resolving after this returns would otherwise hold an untracked GATT link
  /// straight into the DFU window. Draining it here lets the ownership handoff
  /// that follows tear down whatever it established.
  Future<void> suspendForDfuTransfer({required String reason}) async {
    _dfuTransferSuppressed = true;
    _cancelPreferredReconnectCampaign(reason: 'dfu_transfer');
    _retryTimer?.cancel();
    _retryTimer = null;
    BleDebugRegistry.instance.recordEvent(
      'BLE_AUTO_RECONNECT_SUSPENDED_FOR_DFU reason=$reason',
    );
    final campaign = _preferredReconnectCampaign;
    if (campaign != null) {
      try {
        await campaign;
      } catch (_) {
        // A failed/cancelled in-flight attempt is fine; we only need it to have
        // settled so no connect resolves after the ownership handoff.
      }
    }
  }

  /// Lifts the DFU suppression once the transfer (or its failure handling) is
  /// over, so post-DFU verification can reconnect to the device again.
  void resumeAfterDfuTransfer({required String reason}) {
    _dfuTransferSuppressed = false;
    BleDebugRegistry.instance.recordEvent(
      'BLE_AUTO_RECONNECT_RESUMED_AFTER_DFU reason=$reason',
    );
  }

  void onUnexpectedDisconnect() {
    if (_provisioningReconnectOwned) {
      _recordProvisioningReconnectSuppressed(trigger: 'unexpected_disconnect');
      return;
    }
    if (_dfuTransferSuppressed) {
      BleDebugRegistry.instance.recordEvent(
        'Reconnect skipped because a firmware DFU transfer is in progress',
      );
      return;
    }
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
    _cancelPreferredReconnectCampaign(reason: 'manual_disconnect');
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
    _cancelPreferredReconnectCampaign(reason: 'manual_connect_requested');
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
    _disposed = true;
    _cancelPreferredReconnectCampaign(reason: 'dispose');
    _retryTimer?.cancel();
    await stopBleReadinessReconnectMonitor();
    await _deviceStatusSub?.cancel();
  }

  Future<void> _pollBleReadinessForReconnect({required String trigger}) async {
    if (_disposed || _readinessReconnectPollInFlight) {
      return;
    }
    _readinessReconnectPollInFlight = true;
    try {
      final readiness = await _readReconnectReadiness();
      if (readiness != null) {
        await _handleBleReadinessChanged(readiness, trigger: trigger);
      }
    } finally {
      _readinessReconnectPollInFlight = false;
    }
  }

  Future<void> _handleBleReadinessChanged(
    PermissionState readiness, {
    required String trigger,
  }) async {
    if (_disposed) {
      return;
    }
    final previous = _lastReadinessForReconnectMonitor;
    _lastReadinessForReconnectMonitor = readiness;
    final previousReady = previous?.canUseBluetooth == true;
    final currentReady = readiness.canUseBluetooth;
    _traceReconnect(
      'sdk_ble_readiness_changed '
      'previousReadiness=${_readinessTraceLabel(previous)} '
      'currentReadiness=${_readinessTraceLabel(readiness)} '
      'hasPermission=${_hasReconnectPermission(readiness)} '
      'bluetoothReady=${_isReconnectBluetoothReady(readiness)}',
    );
    if (!currentReady) {
      _traceReconnect(
        'sdk_ble_ready_reconnect_skipped '
        'reason=${readiness.bluetoothEnabled ? 'permission_missing' : 'bluetooth_not_ready'}',
      );
      return;
    }
    if (previousReady) {
      _traceReconnect('sdk_ble_ready_reconnect_skipped reason=already_ready');
      return;
    }
    await _triggerBleReadyReconnect(trigger: trigger);
  }

  Future<void> _triggerBleReadyReconnect({required String trigger}) async {
    if (_provisioningReconnectOwned) {
      _recordProvisioningReconnectSuppressed(trigger: trigger);
      return;
    }
    if (_preferredReconnectCampaign != null || _isConnectionAttemptInProgress) {
      _traceReconnect('sdk_ble_ready_reconnect_skipped reason=inflight');
      return;
    }
    if (_manualDisconnectRequested) {
      _traceReconnect(
        'sdk_ble_ready_reconnect_skipped reason=manual_disconnect',
      );
      return;
    }
    if (!_isAppForeground) {
      _traceReconnect(
        'sdk_ble_ready_reconnect_skipped reason=app_not_foreground',
      );
      return;
    }
    final reconnectRepository = _deviceRepository;
    if (reconnectRepository is! KnownDeviceReconnectRepository) {
      _traceReconnect(
        'sdk_ble_ready_reconnect_skipped reason=unsupported_repository',
      );
      return;
    }
    final currentStatus = await _deviceRepository.getDeviceStatus();
    if (currentStatus.connected &&
        await _isCommandChannelAvailableForConnectedDevice()) {
      _traceReconnect(
        'sdk_ble_ready_reconnect_skipped reason=already_connected',
      );
      return;
    }
    final preferredDevice = await _preferredDeviceStore.getPreferredDevice() ??
        _preferredDeviceFromStatus(currentStatus);
    if (preferredDevice == null) {
      _traceReconnect(
        'sdk_ble_ready_reconnect_skipped reason=no_preferred_device',
      );
      return;
    }
    _traceReconnect('sdk_ble_ready_reconnect_trigger source=$trigger');
    unawaited(_tryAutoConnect(trigger: trigger));
  }

  Future<PreferredDeviceReconnectResult> _tryAutoConnect({
    required String trigger,
    String? attemptId,
    String? platformRemoteId,
    bool allowDuringProvisioningOwnership = false,
  }) async {
    if (_provisioningReconnectOwned && !allowDuringProvisioningOwnership) {
      _recordProvisioningReconnectSuppressed(trigger: trigger);
      _recordNoProviderCall(
        attemptId: attemptId,
        reason: 'provisioning_reconnect_owned',
      );
      return const PreferredDeviceReconnectResult.failed(
        reason: 'provisioning_reconnect_owned',
      );
    }
    if (_dfuTransferSuppressed) {
      _traceReconnect(
        'sdk_campaign_cancelled reason=dfu_transfer_in_progress '
        'source=$trigger',
      );
      _recordNoProviderCall(
        attemptId: attemptId,
        reason: 'dfu_transfer_in_progress',
      );
      return const PreferredDeviceReconnectResult.failed(
        reason: 'dfu_transfer_in_progress',
      );
    }
    final activeCampaign = _preferredReconnectCampaign;
    _traceReconnect(
      'sdk_bootstrap_called source=$trigger '
      'alreadyInFlight=${activeCampaign != null} '
      'connectedKnown=${_lastStatus?.connected == true}',
    );
    if (activeCampaign != null) {
      _traceReconnect(
        'sdk_inflight_changed value=true reason=duplicate_bootstrap',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_PREFERRED_RECONNECT_ALREADY_IN_PROGRESS trigger=$trigger',
      );
      _recordNoProviderCall(attemptId: attemptId, reason: 'inflight_blocked');
      return const PreferredDeviceReconnectResult.reconnecting(
        reason: 'inflight',
      );
    }
    final cancellation = Completer<void>();
    final token = ++_preferredReconnectCampaignToken;
    _preferredReconnectCancellation = cancellation;
    _traceReconnect('sdk_inflight_changed value=true reason=campaign_created');
    final campaign = _runPreferredReconnectCampaign(
      trigger: trigger,
      attemptId: attemptId,
      platformRemoteId: platformRemoteId,
      token: token,
    );
    _preferredReconnectCampaign = campaign;
    try {
      return await campaign;
    } finally {
      if (identical(_preferredReconnectCampaign, campaign)) {
        _preferredReconnectCampaign = null;
        _traceReconnect(
          'sdk_inflight_changed value=false reason=campaign_completed',
        );
      }
      if (identical(_preferredReconnectCancellation, cancellation)) {
        _preferredReconnectCancellation = null;
      }
    }
  }

  Future<PreferredDeviceReconnectResult> _runPreferredReconnectCampaign({
    required String trigger,
    required String? attemptId,
    required String? platformRemoteId,
    required int token,
  }) async {
    _traceReconnect(
      'sdk_campaign_start source=$trigger '
      'maxAttempts=$_preferredReconnectMaxAttempts',
    );
    BleDebugRegistry.instance.recordEvent(
      'BLE_PREFERRED_RECONNECT_CAMPAIGN_STARTED '
      'trigger=$trigger maxAttempts=$_preferredReconnectMaxAttempts',
    );
    PreferredDeviceReconnectResult lastResult =
        const PreferredDeviceReconnectResult.failed(reason: 'not_started');
    for (var attempt = 1;
        attempt <= _preferredReconnectMaxAttempts;
        attempt++) {
      if (!_isPreferredReconnectCampaignCurrent(token)) {
        _traceReconnect('sdk_campaign_cancelled reason=disposed');
        return const PreferredDeviceReconnectResult.failed(
          reason: 'campaign_cancelled',
        );
      }
      _traceReconnect(
        'sdk_campaign_attempt attemptNumber=$attempt '
        'maxAttempts=$_preferredReconnectMaxAttempts',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_PREFERRED_RECONNECT_ATTEMPT_STARTED '
        'trigger=$trigger attempt=$attempt '
        'maxAttempts=$_preferredReconnectMaxAttempts',
      );
      lastResult = await _tryPreferredReconnectAttempt(
        trigger: trigger,
        attemptId: attemptId,
        platformRemoteId: platformRemoteId,
      );
      if (lastResult.connected) {
        _traceReconnect(
          'sdk_campaign_attempt_result attemptNumber=$attempt '
          'result=${lastResult.status.name} '
          'reason=${lastResult.reason ?? 'none'} retryable=false',
        );
        _traceReconnect('sdk_campaign_success attemptNumber=$attempt');
        BleDebugRegistry.instance.recordEvent(
          'BLE_PREFERRED_RECONNECT_ATTEMPT_SUCCEEDED '
          'trigger=$trigger attempt=$attempt',
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE_PREFERRED_RECONNECT_CAMPAIGN_CONNECTED '
          'trigger=$trigger attempt=$attempt',
        );
        return lastResult;
      }
      final retryable = _shouldRetryPreferredReconnectResult(lastResult);
      _traceReconnect(
        'sdk_campaign_attempt_result attemptNumber=$attempt '
        'result=${lastResult.status.name} '
        'reason=${lastResult.reason ?? 'none'} retryable=$retryable',
      );
      if (!retryable) {
        _traceReconnect(
          'sdk_campaign_cancelled '
          'reason=${_campaignCancelledReason(lastResult)}',
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE_PREFERRED_RECONNECT_CAMPAIGN_CANCELLED '
          'trigger=$trigger attempt=$attempt '
          'reason=${lastResult.reason ?? lastResult.status.name}',
        );
        return lastResult;
      }
      BleDebugRegistry.instance.recordEvent(
        'BLE_PREFERRED_RECONNECT_ATTEMPT_FAILED '
        'trigger=$trigger attempt=$attempt '
        'result=${lastResult.status.name} '
        'reason=${lastResult.reason ?? 'none'}',
      );
      if (attempt == _preferredReconnectMaxAttempts) {
        break;
      }
      final delay = _preferredReconnectDelayForAttempt(attempt);
      _traceReconnect(
        'sdk_campaign_retry_delay nextAttemptNumber=${attempt + 1} '
        'delayMs=${delay.inMilliseconds}',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_PREFERRED_RECONNECT_RETRY_WAIT '
        'trigger=$trigger attempt=$attempt '
        'nextAttempt=${attempt + 1} delayMs=${delay.inMilliseconds}',
      );
      await _waitForPreferredReconnectDelay(delay);
      if (!_isPreferredReconnectCampaignCurrent(token)) {
        _traceReconnect('sdk_campaign_cancelled reason=disposed');
        return const PreferredDeviceReconnectResult.failed(
          reason: 'campaign_cancelled',
        );
      }
    }
    _traceReconnect(
      'sdk_campaign_exhausted attempts=$_preferredReconnectMaxAttempts',
    );
    BleDebugRegistry.instance.recordEvent(
      'BLE_PREFERRED_RECONNECT_CAMPAIGN_EXHAUSTED '
      'trigger=$trigger attempts=$_preferredReconnectMaxAttempts '
      'lastResult=${lastResult.status.name}',
    );
    return const PreferredDeviceReconnectResult.exhausted(
      reason: 'preferred_reconnect_attempts_exhausted',
    );
  }

  Future<PreferredDeviceReconnectResult> _tryPreferredReconnectAttempt({
    required String trigger,
    String? attemptId,
    String? platformRemoteId,
  }) async {
    if (_dfuTransferSuppressed) {
      _traceReconnect(
        'sdk_campaign_cancelled reason=dfu_transfer_in_progress '
        'source=$trigger',
      );
      _recordNoProviderCall(
        attemptId: attemptId,
        reason: 'dfu_transfer_in_progress',
      );
      return const PreferredDeviceReconnectResult.failed(
        reason: 'dfu_transfer_in_progress',
      );
    }
    if (_manualDisconnectRequested) {
      _traceReconnect(
        'sdk_preflight hasPermission=unknown bluetoothReady=unknown '
        'hasPreferredDevice=unknown hasRemoteIdentity=unknown '
        'alreadyConnected=${_lastStatus?.connected == true} '
        'unsupportedRepository=false canStartCampaign=false',
      );
      _traceReconnect('sdk_campaign_cancelled reason=manual_disconnect');
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because manual disconnect is active',
      );
      _recordNoProviderCall(
        attemptId: attemptId,
        reason: 'connect_guard_blocked',
      );
      return const PreferredDeviceReconnectResult.failed(
        reason: 'manual_disconnect_requested',
      );
    }
    if (!_isAppForeground && trigger != 'startup') {
      _traceReconnect(
        'sdk_preflight hasPermission=unknown bluetoothReady=unknown '
        'hasPreferredDevice=unknown hasRemoteIdentity=unknown '
        'alreadyConnected=${_lastStatus?.connected == true} '
        'unsupportedRepository=false canStartCampaign=false',
      );
      _traceReconnect('sdk_campaign_cancelled reason=unknown');
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because app is not in foreground',
      );
      _recordNoProviderCall(
        attemptId: attemptId,
        reason: 'connect_guard_blocked',
      );
      return const PreferredDeviceReconnectResult.failed(
        reason: 'app_not_foreground',
      );
    }
    if (_isConnectionAttemptInProgress) {
      _traceReconnect(
        'sdk_preflight hasPermission=unknown bluetoothReady=unknown '
        'hasPreferredDevice=unknown hasRemoteIdentity=unknown '
        'alreadyConnected=${_lastStatus?.connected == true} '
        'unsupportedRepository=false canStartCampaign=false',
      );
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because connection is already in progress',
      );
      _recordNoProviderCall(attemptId: attemptId, reason: 'inflight_blocked');
      return const PreferredDeviceReconnectResult.reconnecting(
        reason: 'inflight',
      );
    }

    final readiness = await _readReconnectReadiness();
    if (readiness != null && !readiness.canUseBluetooth) {
      _traceReconnect(
        'sdk_preflight '
        'hasPermission=${readiness.bluetooth == SdkPermissionStatus.granted} '
        'bluetoothReady=${readiness.bluetoothEnabled} '
        'hasPreferredDevice=unknown hasRemoteIdentity=unknown '
        'alreadyConnected=${_lastStatus?.connected == true} '
        'unsupportedRepository=false canStartCampaign=false',
      );
      if (_isRetryableIosReadinessWarmup(readiness)) {
        _traceReconnect(
          'sdk_campaign_attempt_transient '
          'reason=ios_readiness_warmup_retry',
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE_READINESS_PENDING_IOS reason=adapter_state_warmup',
        );
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'runtime_not_ready',
        );
        return const PreferredDeviceReconnectResult.bluetoothOff(
          reason: 'ios_readiness_warmup_retry',
        );
      }
      if (readiness.bluetoothEnabled) {
        _traceReconnect('sdk_campaign_cancelled reason=permission_missing');
        BleDebugRegistry.instance.recordEvent(
          'BLE_READINESS_BLOCKED permissionMissing',
        );
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'permission_missing',
        );
        return const PreferredDeviceReconnectResult.permissionMissing(
          reason: 'bluetooth_permission_missing',
        );
      }
      _traceReconnect('sdk_campaign_cancelled reason=bluetooth_not_ready');
      BleDebugRegistry.instance.recordEvent(
        'BLE_READINESS_BLOCKED bluetoothOff',
      );
      _recordNoProviderCall(attemptId: attemptId, reason: 'runtime_not_ready');
      return const PreferredDeviceReconnectResult.bluetoothOff(
        reason: 'bluetooth_off',
      );
    }

    final currentStatus = await _deviceRepository.getDeviceStatus();
    if (currentStatus.connected) {
      final refreshedStatus = await _deviceRepository.refreshDeviceStatus();
      if (refreshedStatus.connected &&
          await _isCommandChannelAvailableForConnectedDevice()) {
        _traceReconnect(
          'sdk_preflight '
          'hasPermission=${_hasReconnectPermission(readiness)} '
          'bluetoothReady=${_isReconnectBluetoothReady(readiness)} '
          'hasPreferredDevice=unknown hasRemoteIdentity=unknown '
          'alreadyConnected=true unsupportedRepository=false '
          'canStartCampaign=false',
        );
        _traceReconnect('sdk_campaign_cancelled reason=connected');
        BleDebugRegistry.instance.recordEvent(
          'BLE_AUTO_CONNECT_SKIPPED trigger=$trigger reason=command_channel_ready',
        );
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'unsupported_state',
        );
        return const PreferredDeviceReconnectResult.connected(
          reason: 'already_connected',
        );
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
      _traceReconnect(
        'sdk_preflight '
        'hasPermission=${_hasReconnectPermission(readiness)} '
        'bluetoothReady=${_isReconnectBluetoothReady(readiness)} '
        'hasPreferredDevice=false hasRemoteIdentity=false '
        'alreadyConnected=${currentStatus.connected} '
        'unsupportedRepository=false canStartCampaign=false',
      );
      _traceReconnect('sdk_campaign_cancelled reason=no_preferred_device');
      if (attemptId != null && _isIosPlatform()) {
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_RECONNECT_ID_MISSING_AT_SDK attemptId=$attemptId',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because no preferred device is stored',
      );
      _recordNoProviderCall(attemptId: attemptId, reason: 'missing_remote_id');
      return const PreferredDeviceReconnectResult.noKnownDevice(
        reason: 'missing_preferred_device',
      );
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
    } else if (_isIosPlatform()) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_IDENTITY_RESOLVED platform=ios '
        'logicalId=${currentStatus.deviceId} remoteIdPresent=true',
      );
      BleDebugRegistry.instance.recordEvent(
        'SDK_RECONNECT_REMOTE_ID_RESOLVED '
        'attemptId=${attemptId ?? 'none'} platform=ios '
        'remote_identity_present=${remoteId.trim().isNotEmpty} '
        'length=${remoteId.length} '
        'validCoreBluetoothUuid=${_isValidIosBleRemoteId(remoteId)}',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_RECONNECT_ALLOWED '
        'platform=ios reason=${_allowedReconnectReason(trigger)}',
      );
    }

    BleDebugRegistry.instance.recordEvent(
      'BLE_AUTO_RECONNECT_STARTED trigger=$trigger '
      'device_identity_present=${reconnectDevice.deviceId.trim().isNotEmpty}',
    );
    BleDebugRegistry.instance.selectDevice(reconnectDevice.deviceId);
    final reconnectRepository = _deviceRepository;
    final unsupportedRepository =
        reconnectRepository is! KnownDeviceReconnectRepository;
    _traceReconnect(
      'sdk_preflight '
      'hasPermission=${_hasReconnectPermission(readiness)} '
      'bluetoothReady=${_isReconnectBluetoothReady(readiness)} '
      'hasPreferredDevice=true hasRemoteIdentity=${remoteId.isNotEmpty} '
      'alreadyConnected=${currentStatus.connected} '
      'unsupportedRepository=$unsupportedRepository '
      'canStartCampaign=${!unsupportedRepository}',
    );
    if (reconnectRepository is! KnownDeviceReconnectRepository) {
      _traceReconnect('sdk_campaign_cancelled reason=unsupported_repository');
      BleDebugRegistry.instance.recordEvent(
        '$trigger auto-connect skipped because repository cannot restore known devices',
      );
      _recordNoProviderCall(attemptId: attemptId, reason: 'unsupported_state');
      return const PreferredDeviceReconnectResult.failed(
        reason: 'unsupported_repository',
      );
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
      return const PreferredDeviceReconnectResult.connected(
        reason: 'reconnect_succeeded',
      );
    } catch (error) {
      if (_isMobileBondRequired(error)) {
        await _handleMissingMobileBond(
          reconnectDevice.deviceId,
          reason: _mobileBondStopReason(error),
        );
        _traceReconnect('sdk_campaign_cancelled reason=no_preferred_device');
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'unsupported_state',
        );
        return const PreferredDeviceReconnectResult.noKnownDevice(
          reason: 'mobile_bond_missing',
        );
      }
      if (_isInvalidBleRemoteId(error)) {
        _traceReconnect('sdk_campaign_cancelled reason=no_preferred_device');
        BleDebugRegistry.instance.recordEvent(
          'BLE_RECONNECT_DEFERRED reason=screen_not_visible_or_not_user_initiated',
        );
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'missing_remote_id',
        );
        return const PreferredDeviceReconnectResult.noKnownDevice(
          reason: 'invalid_remote_id',
        );
      }
      if (_isRuntimeNotReady(error)) {
        _traceReconnect(
          'sdk_campaign_attempt_transient '
          'reason=attempt_bluetooth_off_transient_retry',
        );
        _recordNoProviderCall(
          attemptId: attemptId,
          reason: 'runtime_not_ready',
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE_READINESS_BLOCKED bluetoothOff',
        );
        return const PreferredDeviceReconnectResult.bluetoothOff(
          reason: 'attempt_bluetooth_off_transient_retry',
        );
      }
      return const PreferredDeviceReconnectResult.reconnecting(
        reason: 'attempt_failed',
      );
    }
  }

  bool _isPreferredReconnectCampaignCurrent(int token) {
    return !_disposed && token == _preferredReconnectCampaignToken;
  }

  bool _shouldRetryPreferredReconnectResult(
    PreferredDeviceReconnectResult result,
  ) {
    if (_isTransientAttemptBluetoothOff(result)) {
      return true;
    }
    if (_isRetryableIosReadinessWarmupResult(result)) {
      return true;
    }
    if (result.connected || result.blocked) {
      return false;
    }
    if (result.status == PreferredDeviceReconnectResultStatus.noKnownDevice) {
      return result.reason != 'missing_preferred_device' &&
          result.reason != 'missing_valid_remote_id' &&
          result.reason != 'mobile_bond_missing' &&
          result.reason != 'invalid_remote_id';
    }
    if (result.status == PreferredDeviceReconnectResultStatus.failed) {
      return result.reason != 'manual_disconnect_requested' &&
          result.reason != 'app_not_foreground' &&
          result.reason != 'unsupported_repository' &&
          result.reason != 'campaign_cancelled' &&
          result.reason != 'dfu_transfer_in_progress';
    }
    return true;
  }

  bool _isTransientAttemptBluetoothOff(PreferredDeviceReconnectResult result) {
    return result.status == PreferredDeviceReconnectResultStatus.bluetoothOff &&
        result.reason == 'attempt_bluetooth_off_transient_retry';
  }

  bool _isRetryableIosReadinessWarmup(PermissionState readiness) {
    if (!_isIosPlatform() || readiness.bluetoothEnabled) {
      return false;
    }
    return readiness.bluetooth == SdkPermissionStatus.unknown ||
        readiness.bluetooth == SdkPermissionStatus.denied;
  }

  bool _isRetryableIosReadinessWarmupResult(
    PreferredDeviceReconnectResult result,
  ) {
    return result.status == PreferredDeviceReconnectResultStatus.bluetoothOff &&
        result.reason == 'ios_readiness_warmup_retry';
  }

  Duration _preferredReconnectDelayForAttempt(int completedAttempt) {
    if (_preferredReconnectRetryDelays.isEmpty) {
      return Duration.zero;
    }
    final index = (completedAttempt - 1).clamp(
      0,
      _preferredReconnectRetryDelays.length - 1,
    );
    return _preferredReconnectRetryDelays[index];
  }

  Future<void> _waitForPreferredReconnectDelay(Duration delay) {
    final delayFuture = _preferredReconnectDelay?.call(delay) ??
        (delay == Duration.zero
            ? Future<void>.value()
            : Future<void>.delayed(delay));
    final cancellationFuture = _preferredReconnectCancellation?.future;
    if (cancellationFuture == null) {
      return delayFuture;
    }
    return Future.any(<Future<void>>[delayFuture, cancellationFuture]);
  }

  void _cancelPreferredReconnectCampaign({required String reason}) {
    if (_preferredReconnectCampaign == null) {
      return;
    }
    _preferredReconnectCampaignToken++;
    final cancellation = _preferredReconnectCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    BleDebugRegistry.instance.recordEvent(
      'BLE_PREFERRED_RECONNECT_CAMPAIGN_CANCELLED reason=$reason',
    );
    _traceReconnect(
      'sdk_campaign_cancelled reason=${_traceCancellationReason(reason)}',
    );
    _traceReconnect('sdk_inflight_changed value=false reason=$reason');
  }

  bool _hasReconnectPermission(PermissionState? readiness) {
    return readiness == null ||
        readiness.bluetooth == SdkPermissionStatus.granted;
  }

  bool _isReconnectBluetoothReady(PermissionState? readiness) {
    return readiness == null || readiness.bluetoothEnabled;
  }

  String _readinessTraceLabel(PermissionState? readiness) {
    if (readiness == null) {
      return 'unknown';
    }
    if (readiness.canUseBluetooth) {
      return 'ready';
    }
    if (readiness.bluetoothEnabled) {
      return 'blocked';
    }
    return 'notReady';
  }

  String _campaignCancelledReason(PreferredDeviceReconnectResult result) {
    return switch (result.status) {
      PreferredDeviceReconnectResultStatus.connected => 'connected',
      PreferredDeviceReconnectResultStatus.bluetoothOff =>
        'bluetooth_not_ready',
      PreferredDeviceReconnectResultStatus.permissionMissing =>
        'permission_missing',
      PreferredDeviceReconnectResultStatus.noKnownDevice =>
        'no_preferred_device',
      PreferredDeviceReconnectResultStatus.failed =>
        result.reason == 'manual_disconnect_requested'
            ? 'manual_disconnect'
            : result.reason == 'unsupported_repository'
                ? 'unsupported_repository'
                : 'unknown',
      PreferredDeviceReconnectResultStatus.reconnecting ||
      PreferredDeviceReconnectResultStatus.exhausted =>
        'unknown',
    };
  }

  String _traceCancellationReason(String reason) {
    return switch (reason) {
      'manual_disconnect' || 'manual_connect_requested' => 'manual_disconnect',
      'dispose' => 'disposed',
      'dfu_transfer' => 'dfu_transfer_in_progress',
      'provisioning_reboot' => 'provisioning_reconnect_owned',
      _ => 'unknown',
    };
  }

  void _recordProvisioningReconnectSuppressed({required String trigger}) {
    BleDebugRegistry.instance.recordEvent(
      'PROVISIONING_REBOOT generic_reconnect_suppressed=true trigger=$trigger',
    );
    _traceReconnect(
      'sdk_campaign_cancelled reason=provisioning_reconnect_owned '
      'source=$trigger',
    );
  }

  void _traceReconnect(String message) {
    BleDebugRegistry.instance.recordEvent('EIXAM_RECONNECT_TRACE $message');
  }

  Future<PermissionState?> _readReconnectReadiness() async {
    final provider = _permissionStateProvider;
    if (provider == null) {
      return null;
    }
    try {
      return await provider();
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE_READINESS_CHECK_FAILED error=$error',
      );
      return null;
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
        (error.code == 'E_DEVICE_MOBILE_BOND_REQUIRED' ||
            error.code == DeviceException.bleIosPairingInformationRemovedCode);
  }

  String _mobileBondStopReason(Object error) {
    if (error is DeviceException &&
        error.code == DeviceException.bleIosPairingInformationRemovedCode) {
      return 'ios_pairing_information_removed';
    }
    return 'android_bond_missing';
  }

  String _manualConnectFailureDeviceId() {
    final selectedDeviceId =
        BleDebugRegistry.instance.currentState.selectedDeviceId;
    if (selectedDeviceId != null && selectedDeviceId.trim().isNotEmpty) {
      return selectedDeviceId.trim();
    }
    final statusDeviceId = _lastStatus?.deviceId.trim();
    if (statusDeviceId != null && statusDeviceId.isNotEmpty) {
      return statusDeviceId;
    }
    return 'unknown';
  }

  bool _isInvalidBleRemoteId(Object error) {
    return error is DeviceException &&
        error.code == 'E_DEVICE_INVALID_BLE_REMOTE_ID';
  }

  bool _isRuntimeNotReady(Object error) {
    if (error is DeviceException) {
      return _isRuntimeNotReadyCode(error.code) ||
          _isRuntimeNotReadyCode(error.message);
    }
    if (error is PlatformException) {
      return _isRuntimeNotReadyCode(error.code) ||
          _isRuntimeNotReadyCode(error.message);
    }
    return _isRuntimeNotReadyCode(error.toString());
  }

  bool _isRuntimeNotReadyCode(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == 'e_device_bluetooth_off' ||
        normalized == 'e_bluetooth_off' ||
        normalized == 'bluetooth_off' ||
        normalized == 'bluetoothoff' ||
        normalized == 'adapter_not_powered_on' ||
        normalized == 'adapter_not_ready' ||
        normalized == 'scanner_not_ready';
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

  void _recordNoProviderCall({
    required String? attemptId,
    required String reason,
  }) {
    if (attemptId == null) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'BLE_RECONNECT_FAILED_NO_PROVIDER_CALL '
      'reason=$reason attemptId=$attemptId',
    );
  }

  Future<void> _handleMissingMobileBond(
    String deviceId, {
    String reason = 'android_bond_missing',
  }) async {
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
      'BLE_AUTO_RECONNECT_STOPPED reason=$reason hardwareId=$deviceId',
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
