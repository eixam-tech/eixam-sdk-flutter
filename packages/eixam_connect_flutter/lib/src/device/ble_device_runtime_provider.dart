import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_connection_status.dart';
import 'ble_debug_registry.dart';
import 'ble_incoming_event.dart';
import 'ble_incoming_payload_classifier.dart';
import 'ble_scan_result.dart';
import 'device_runtime_provider.dart';
import 'device_sos_controller.dart';
import 'eixam_ble_command.dart';
import 'eixam_ble_notification.dart';
import 'eixam_ble_protocol.dart';
import 'eixam_cluster_heartbeat_packet.dart';
import 'eixam_device_runtime_status_packet.dart';
import 'eixam_sos_event_packet.dart';
import 'eixam_sos_packet.dart';
import 'eixam_tel_fragment.dart';
import 'eixam_tel_packet.dart';
import 'eixam_tel_live_batch_packet.dart';
import 'eixam_tel_relay_cluster_packet.dart';
import 'eixam_tel_reassembler.dart';
import 'eixam_tel_relay_rx_packet.dart';
import '../provisioning/provisioning_command_result.dart';

class BleDeviceRuntimeProvider implements DeviceRuntimeProvider {
  BleDeviceRuntimeProvider({
    required BleClient bleClient,
    DeviceSosController? deviceSosController,
    @visibleForTesting bool Function()? isIosPlatform,
  })  : _bleClient = bleClient,
        _deviceSosController = deviceSosController ?? DeviceSosController(),
        _isIosPlatform = isIosPlatform ?? (() => Platform.isIOS);

  final BleClient _bleClient;
  final DeviceSosController _deviceSosController;
  final bool Function() _isIosPlatform;
  final StreamController<BleIncomingEvent> _incomingEventsController =
      StreamController<BleIncomingEvent>.broadcast();
  final StreamController<DeviceStatus> _runtimeStatusController =
      StreamController<DeviceStatus>.broadcast();
  final EixamTelReassembler _telReassembler = EixamTelReassembler();
  final BleIncomingPayloadClassifier _payloadClassifier =
      const BleIncomingPayloadClassifier();

  String? _connectedDeviceId;
  String? _connectedDeviceAlias;
  String? _connectedCanonicalHardwareId;
  StreamSubscription<EixamBleNotification>? _notificationSubscription;
  StreamSubscription<bool>? _connectionStateSubscription;
  DateTime? _lastAppCommandAt;
  DeviceStatus? _lastRuntimeStatus;
  int? _lastTelBatteryLevel;
  int? _lastSosBatteryLevel;
  int? _connectedBleTagNodeId;
  final Map<String, DateTime> _recentSosPacketSignatures = <String, DateTime>{};
  bool _ownershipSuspended = false;
  Completer<DeviceRuntimeStatus>? _pendingRuntimeStatusRequest;
  bool _disposed = false;
  bool _loggedHeartbeatFirmwareSkip = false;
  bool _loggedHeartbeatSignalSkip = false;
  DateTime? _lastIosSignalQualityReadAt;
  int? _lastIosSignalQuality;
  String? _lastIosSignalQualityThrottleLog;
  final Map<String, String> _iosResolvedReconnectRemoteIds = <String, String>{};

  static const Duration _recentSosDedupWindow = Duration(seconds: 2);
  static const Duration _iosSignalQualityThrottleWindow = Duration(seconds: 5);
  static const Duration _iosReconnectScanTimeout = Duration(seconds: 4);
  static const String _deviceCommandNotReadyCode = 'E_DEVICE_COMMAND_NOT_READY';
  static const String _deviceStatusTimeoutCode = 'E_DEVICE_STATUS_TIMEOUT';
  static const String _mobileBondRequiredCode = 'E_DEVICE_MOBILE_BOND_REQUIRED';

  DeviceSosController get deviceSosController => _deviceSosController;
  Stream<BleIncomingEvent> watchIncomingEvents() =>
      _incomingEventsController.stream;

  Future<PreferredDevice?> recoverPreferredFromSystemAssociation() async {
    try {
      final associated = await _bleClient.listSystemAssociatedDevices();
      if (associated.isEmpty) {
        return null;
      }
      associated.sort((a, b) {
        final aName = a.name.toLowerCase();
        final bName = b.name.toLowerCase();
        final aScore = aName.contains('eixam') ? 0 : 1;
        final bScore = bName.contains('eixam') ? 0 : 1;
        if (aScore != bScore) {
          return aScore.compareTo(bScore);
        }
        return a.deviceId.compareTo(b.deviceId);
      });
      final candidate = associated.first;
      BleDebugRegistry.instance.recordEvent(
        'BLE preferred candidate recovered from system association -> '
        'hardwareId=${candidate.deviceId} name=${candidate.name}',
      );
      return PreferredDevice(
        deviceId: candidate.deviceId,
        displayName: candidate.name.trim().isEmpty ? null : candidate.name,
        lastConnectedAt: DateTime.now(),
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE system association recovery failed -> error=$error',
      );
      return null;
    }
  }

  @override
  Stream<DeviceStatus> watchRuntimeStatus() => _runtimeStatusController.stream;
  bool get hasCommandChannel =>
      _connectedDeviceId != null &&
      BleDebugRegistry.instance.currentState.cmdFound;
  bool get hasShortCommandChannel =>
      _connectedDeviceId != null &&
      BleDebugRegistry.instance.currentState.inetFound;

  @override
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot(
    DeviceStatus currentStatus,
  ) async {
    final deviceId = _connectedDeviceId ??
        (currentStatus.connected ? currentStatus.deviceId : null);
    final serviceBleConnected = deviceId != null;
    final commandCapable = hasCommandChannel;
    final connectedBleNodeId =
        serviceBleConnected ? _connectedBleTagNodeId : null;
    final readinessReason = !serviceBleConnected
        ? RuntimeIdentityReadinessReason.noConnectedDevice
        : connectedBleNodeId == null
            ? RuntimeIdentityReadinessReason.connectedIdentityUnknown
            : commandCapable
                ? RuntimeIdentityReadinessReason.ready
                : RuntimeIdentityReadinessReason.commandPathNotReady;

    return RuntimeIdentitySnapshot(
      connectedBleNodeId: connectedBleNodeId,
      deviceId: deviceId,
      serviceBleConnected: serviceBleConnected,
      commandCapable: commandCapable,
      readinessReason: readinessReason,
      lastUpdatedAt: _lastRuntimeStatus?.lastSyncedAt ??
          currentStatus.lastSyncedAt ??
          currentStatus.lastSeen,
    );
  }

  @override
  Future<DeviceStatus> pair({
    required DeviceStatus currentStatus,
    required String pairingCode,
  }) async {
    if (pairingCode.trim().length < 4) {
      throw const DeviceException.invalidPairingCode();
    }

    final adapterState = await _bleClient.getAdapterState();
    if (adapterState != BleAdapterState.poweredOn) {
      throw const DeviceException(
        'E_DEVICE_BLUETOOTH_OFF',
        'E_DEVICE_BLUETOOTH_OFF',
      );
    }

    final scanResults = await _bleClient.scan();
    if (scanResults.isEmpty) {
      throw const DeviceException(
        'E_DEVICE_NOT_FOUND',
        'E_DEVICE_NOT_FOUND',
      );
    }

    final selectedDeviceId =
        BleDebugRegistry.instance.currentState.selectedDeviceId;
    if (selectedDeviceId == null || selectedDeviceId.isEmpty) {
      throw const DeviceException(
        'E_DEVICE_NOT_SELECTED',
        'E_DEVICE_NOT_SELECTED',
      );
    }

    final candidate = _findSelectedCandidate(scanResults, selectedDeviceId);
    if (candidate == null) {
      throw const DeviceException(
        'E_DEVICE_NOT_FOUND',
        'E_DEVICE_NOT_FOUND',
      );
    }
    try {
      _log(
        'BLE selected candidate -> id=${candidate.deviceId} name=${candidate.name} rssi=${candidate.rssi}',
      );
      BleDebugRegistry.instance.update(
        selectedDeviceId: candidate.deviceId,
        connectionStatus: BleConnectionStatus.connecting,
        connectionError: null,
      );
      BleDebugRegistry.instance.recordEvent(
        'Connection started for ${candidate.deviceId}',
      );
      await _bleClient.connect(candidate.deviceId);
      BleDebugRegistry.instance.update(
        connectionStatus: BleConnectionStatus.connected,
        connectionError: null,
      );
      BleDebugRegistry.instance.recordEvent(
        'Connection succeeded for ${candidate.deviceId}',
      );

      final compatible = await _bleClient.isEixamCompatible(candidate.deviceId);
      BleDebugRegistry.instance.recordEvent(
        'Compatibility result for ${candidate.deviceId}: $compatible',
      );
      if (!compatible) {
        BleDebugRegistry.instance.update(
          connectionStatus: BleConnectionStatus.incompatible,
          connectionError: 'E_DEVICE_INCOMPATIBLE',
        );
        await _bleClient.disconnect(candidate.deviceId);
        throw const DeviceException(
          'E_DEVICE_INCOMPATIBLE',
          'E_DEVICE_INCOMPATIBLE',
        );
      }

      _connectedDeviceId = candidate.deviceId;
      _connectedDeviceAlias = candidate.name;
      _connectedCanonicalHardwareId = candidate.canonicalHardwareId;
      await _bindNotifications(candidate.deviceId);
      await _bindConnectionMonitor(candidate.deviceId);
      BleDebugRegistry.instance.recordEvent(
        'Pairing succeeded for ${candidate.deviceId}',
      );

      final runtimeStatus = await _readRuntimeStatusAfterConnection(
        deviceId: candidate.deviceId,
        reason: 'pairing',
      );
      final runtimeBatteryState = _batteryStateFromPercent(
        runtimeStatus?.batteryPercent,
      );
      final runtimeBatteryPercent = runtimeStatus == null
          ? currentStatus.batteryPercent
          : runtimeStatus.batteryPercent;
      final activated = currentStatus.activated;

      final nextStatus = currentStatus.copyWith(
        deviceId: candidate.deviceId,
        nodeId: runtimeStatus?.nodeId,
        canonicalHardwareId: candidate.canonicalHardwareId,
        deviceAlias: candidate.name,
        model: 'EIXAM R1',
        paired: true,
        activated: activated,
        connected: true,
        provisioningStatus: _provisioningStatusFromRuntime(runtimeStatus),
        batteryPercent: runtimeBatteryPercent,
        lifecycleState: activated
            ? DeviceLifecycleState.ready
            : DeviceLifecycleState.paired,
        batteryLevel: runtimeStatus == null
            ? _effectiveBatteryLevel(currentStatus)
            : runtimeBatteryState?.protocolValue,
        batteryState: runtimeStatus == null
            ? _effectiveBatteryState(currentStatus)
            : runtimeBatteryState,
        batterySource: runtimeStatus == null
            ? _effectiveBatterySource(currentStatus)
            : runtimeStatus.batteryPercent != null
                ? DeviceBatterySource.deviceStatus
                : DeviceBatterySource.unknown,
        firmwareVersion: await _readFirmwareMetadata(
          candidate.deviceId,
          currentFirmwareVersion: null,
          reason: 'pairing',
          force: true,
        ),
        signalQuality: await _readSignalQuality(
          candidate.deviceId,
          reason: 'pairing',
        ),
        lastSeen: DateTime.now(),
        lastSyncedAt: DateTime.now(),
        clearProvisioningError: true,
      );
      _publishRuntimeStatus(nextStatus, reason: 'pair_completed');
      return nextStatus;
    } catch (error) {
      final currentStatus =
          BleDebugRegistry.instance.currentState.connectionStatus;
      if (currentStatus != BleConnectionStatus.incompatible) {
        BleDebugRegistry.instance.update(
          connectionStatus: BleConnectionStatus.failed,
          connectionError: error.toString(),
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'Connection failed for ${candidate.deviceId}: $error',
      );

      await _resetFailedPairingAttempt(candidate.deviceId);
      try {
        await _bleClient.disconnect(candidate.deviceId);
      } catch (_) {}
      if (_isMobilePairingRequiredError(error)) {
        throw _mobilePairingRequiredExceptionFor(error);
      }
      rethrow;
    }
  }

  @override
  Future<DeviceStatus> reconnect({
    required DeviceStatus currentStatus,
    required PreferredDevice preferredDevice,
    String? attemptId,
  }) async {
    var deviceId = preferredDevice.deviceId.trim();
    if (deviceId.isEmpty) {
      throw const DeviceException(
        'E_DEVICE_INVALID_PREFERRED_DEVICE',
        'E_DEVICE_INVALID_PREFERRED_DEVICE',
      );
    }

    final adapterState = await _bleClient.getAdapterState();
    if (adapterState != BleAdapterState.poweredOn) {
      BleDebugRegistry.instance.recordEvent(
        'BLE_RECONNECT_FAILED_NO_PROVIDER_CALL '
        'reason=runtime_not_ready attemptId=${attemptId ?? 'none'}',
      );
      throw const DeviceException(
        'E_DEVICE_BLUETOOTH_OFF',
        'E_DEVICE_BLUETOOTH_OFF',
      );
    }
    deviceId = await _resolveIosReconnectDeviceIdIfNeeded(
      deviceId: deviceId,
      currentStatus: currentStatus,
      preferredDevice: preferredDevice,
      attemptId: attemptId,
    );
    if (!await _bleClient.hasSystemAssociation(deviceId)) {
      BleDebugRegistry.instance.recordEvent(
        'BLE_RECONNECT_FAILED_NO_PROVIDER_CALL '
        'reason=unsupported_state attemptId=${attemptId ?? 'none'}',
      );
      throw const DeviceException(
        _mobileBondRequiredCode,
        _mobileBondRequiredCode,
      );
    }

    try {
      BleDebugRegistry.instance.update(
        selectedDeviceId: deviceId,
        connectionStatus: BleConnectionStatus.reconnecting,
        connectionError: null,
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_RECONNECT_STARTED device_identity_present=true',
      );
      BleDebugRegistry.instance.recordEvent(
        'SDK_RECONNECT_CONNECT_CALL_BEGIN '
        'attemptId=${attemptId ?? 'none'}',
      );
      try {
        await _bleClient.connect(deviceId);
        BleDebugRegistry.instance.recordEvent(
          'SDK_RECONNECT_CONNECT_CALL_DONE '
          'attemptId=${attemptId ?? 'none'} connected=true',
        );
      } catch (error) {
        BleDebugRegistry.instance.recordEvent(
          'SDK_RECONNECT_CONNECT_CALL_FAILED '
          'attemptId=${attemptId ?? 'none'} error=$error',
        );
        rethrow;
      }
      BleDebugRegistry.instance.update(
        connectionStatus: BleConnectionStatus.connected,
        connectionError: null,
      );

      final compatible = await _bleClient.isEixamCompatible(deviceId);
      BleDebugRegistry.instance.recordEvent(
        'Reconnect compatibility result for $deviceId: $compatible',
      );
      if (!compatible) {
        BleDebugRegistry.instance.update(
          connectionStatus: BleConnectionStatus.incompatible,
          connectionError: 'E_DEVICE_INCOMPATIBLE',
        );
        await _bleClient.disconnect(deviceId);
        throw const DeviceException(
          'E_DEVICE_INCOMPATIBLE',
          'E_DEVICE_INCOMPATIBLE',
        );
      }

      _connectedDeviceId = deviceId;
      _connectedDeviceAlias =
          preferredDevice.displayName ?? currentStatus.deviceAlias;
      _connectedCanonicalHardwareId = currentStatus.canonicalHardwareId;
      await _bindNotifications(deviceId);
      await _bindConnectionMonitor(deviceId);
      BleDebugRegistry.instance.recordEvent(
        'Reconnect succeeded for known BLE device $deviceId',
      );

      final runtimeStatus = await _readRuntimeStatusAfterConnection(
        deviceId: deviceId,
        reason: 'reconnect',
      );
      final runtimeBatteryState = _batteryStateFromPercent(
        runtimeStatus?.batteryPercent,
      );
      final runtimeBatteryPercent = runtimeStatus == null
          ? currentStatus.batteryPercent
          : runtimeStatus.batteryPercent;
      final activated = currentStatus.activated;

      final nextStatus = currentStatus.copyWith(
        deviceId: deviceId,
        nodeId: runtimeStatus?.nodeId,
        deviceAlias: _connectedDeviceAlias,
        // Pairing sets a hardware model; reconnect must too or OTA eligibility
        // treats the device as unsupportedHardware ("update incompatible").
        model: currentStatus.model?.trim().isNotEmpty == true
            ? currentStatus.model
            : 'EIXAM R1',
        paired: true,
        activated: activated,
        connected: true,
        provisioningStatus: _provisioningStatusFromRuntime(runtimeStatus),
        batteryPercent: runtimeBatteryPercent,
        lifecycleState: activated
            ? DeviceLifecycleState.ready
            : DeviceLifecycleState.paired,
        batteryLevel: runtimeStatus == null
            ? _effectiveBatteryLevel(currentStatus)
            : runtimeBatteryState?.protocolValue,
        batteryState: runtimeStatus == null
            ? _effectiveBatteryState(currentStatus)
            : runtimeBatteryState,
        batterySource: runtimeStatus == null
            ? _effectiveBatterySource(currentStatus)
            : runtimeStatus.batteryPercent != null
                ? DeviceBatterySource.deviceStatus
                : DeviceBatterySource.unknown,
        firmwareVersion: await _readFirmwareMetadata(
          deviceId,
          currentFirmwareVersion: currentStatus.firmwareVersion,
          reason: 'reconnect',
          force: currentStatus.firmwareVersion == null,
        ),
        signalQuality: await _readSignalQuality(deviceId, reason: 'reconnect'),
        lastSeen: DateTime.now(),
        lastSyncedAt: DateTime.now(),
        clearProvisioningError: true,
      );
      _publishRuntimeStatus(nextStatus, reason: 'reconnect_completed');
      return nextStatus;
    } catch (error) {
      if (_isMobilePairingRequiredError(error)) {
        BleDebugRegistry.instance.recordEvent(
          'BLE_RECONNECT_STOPPED reason=mobile_bond_missing hardwareId=$deviceId',
        );
        await _resetFailedPairingAttempt(deviceId);
        try {
          await _bleClient.disconnect(deviceId);
        } catch (_) {}
        throw _mobilePairingRequiredExceptionFor(error);
      }
      final currentConnectionStatus =
          BleDebugRegistry.instance.currentState.connectionStatus;
      if (currentConnectionStatus != BleConnectionStatus.incompatible) {
        BleDebugRegistry.instance.update(
          connectionStatus: BleConnectionStatus.failed,
          connectionError: error.toString(),
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'Reconnect failed for known BLE device hardwareId=$deviceId '
        'error=$error',
      );
      if (kDebugMode) {
        safeSdkDebugPrint(
            'BLE reconnect failed -> hardwareId=$deviceId error=$error');
      }

      await _resetFailedPairingAttempt(deviceId);
      try {
        await _bleClient.disconnect(deviceId);
      } catch (_) {}
      rethrow;
    }
  }

  bool _isValidIosBleRemoteId(String value) {
    return RegExp(
      r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$',
    ).hasMatch(value);
  }

  bool _isMobilePairingRequiredError(Object error) {
    if (error is DeviceException) {
      return error.code == _mobileBondRequiredCode ||
          error.code == DeviceException.bleIosPairingInformationRemovedCode;
    }
    if (error is PlatformException) {
      return error.code == _mobileBondRequiredCode ||
          error.code == 'bondRequired' ||
          error.code == 'pairingRequired' ||
          error.code == 'insufficientAuthentication';
    }
    return false;
  }

  DeviceException _mobilePairingRequiredExceptionFor(Object error) {
    if (error is DeviceException &&
        error.code == DeviceException.bleIosPairingInformationRemovedCode) {
      return error;
    }
    return const DeviceException(
      _mobileBondRequiredCode,
      _mobileBondRequiredCode,
    );
  }

  BleScanResult? _findSelectedCandidate(
    List<BleScanResult> scanResults,
    String selectedDeviceId,
  ) {
    for (final scanResult in scanResults) {
      if (scanResult.deviceId == selectedDeviceId) {
        return scanResult;
      }
    }
    return null;
  }

  Future<String> _resolveIosReconnectDeviceIdIfNeeded({
    required String deviceId,
    required DeviceStatus currentStatus,
    required PreferredDevice preferredDevice,
    required String? attemptId,
  }) async {
    if (!_isIosPlatform() || _isValidIosBleRemoteId(deviceId)) {
      return deviceId;
    }
    final cacheKey = _iosReconnectCacheKey(
      deviceId: deviceId,
      currentStatus: currentStatus,
      preferredDevice: preferredDevice,
    );
    final cached = _iosResolvedReconnectRemoteIds[cacheKey];
    if (cached != null && _isValidIosBleRemoteId(cached)) {
      BleDebugRegistry.instance.recordEvent(
        'IOS_RECONNECT_REMOTE_ID_CACHE_HIT '
        'attemptId=${attemptId ?? 'none'} '
        'remoteId=${_redactedBleIdentifier(cached)}',
      );
      return cached;
    }

    final hardwareId =
        currentStatus.canonicalHardwareId?.trim().isNotEmpty == true
            ? currentStatus.canonicalHardwareId!.trim()
            : currentStatus.deviceId;
    BleDebugRegistry.instance.recordEvent(
      'BLE_RECONNECT_SKIPPED_INVALID_REMOTE_ID '
      'platform=ios hardwareId=${_redactedBleIdentifier(hardwareId)} '
      'remoteId=${_redactedBleIdentifier(deviceId)}',
    );
    BleDebugRegistry.instance.recordEvent(
      'BLE_RECONNECT_ID_DROPPED source=ble_runtime_provider '
      'attemptId=${attemptId ?? 'none'} length=${deviceId.length} '
      'uuidShape=${_isValidIosBleRemoteId(deviceId)}',
    );
    BleDebugRegistry.instance.recordEvent(
      'IOS_RECONNECT_SCAN_RESOLVE_BEGIN '
      'attemptId=${attemptId ?? 'none'}',
    );
    final scans = await _bleClient.scan(timeout: _iosReconnectScanTimeout);
    final candidate = _selectIosReconnectCandidate(
      scans,
      currentStatus: currentStatus,
      preferredDevice: preferredDevice,
    );
    if (candidate == null) {
      BleDebugRegistry.instance.recordEvent(
        'IOS_RECONNECT_SCAN_RESOLVE_FAILED '
        'reason=no_unique_eixam_candidate attemptId=${attemptId ?? 'none'}',
      );
      BleDebugRegistry.instance.recordEvent(
        'BLE_RECONNECT_FAILED_NO_PROVIDER_CALL '
        'reason=missing_remote_id attemptId=${attemptId ?? 'none'}',
      );
      throw const DeviceException(
        'E_DEVICE_INVALID_BLE_REMOTE_ID',
        'E_DEVICE_INVALID_BLE_REMOTE_ID',
      );
    }
    final resolvedId = candidate.scan.deviceId.trim();
    _iosResolvedReconnectRemoteIds[cacheKey] = resolvedId;
    BleDebugRegistry.instance.recordEvent(
      'IOS_RECONNECT_SCAN_RESOLVE_DONE '
      'reason=${candidate.reason} attemptId=${attemptId ?? 'none'} '
      'remoteId=${_redactedBleIdentifier(resolvedId)}',
    );
    return resolvedId;
  }

  _IosReconnectCandidate? _selectIosReconnectCandidate(
    List<BleScanResult> scans, {
    required DeviceStatus currentStatus,
    required PreferredDevice preferredDevice,
  }) {
    final candidates = <_IosReconnectCandidate>[];
    for (final scan in scans) {
      if (!scan.connectable ||
          !_isValidIosBleRemoteId(scan.deviceId.trim()) ||
          !_isEixamScanCandidate(scan)) {
        continue;
      }
      final identityMatch = _iosReconnectScanHasIdentityMatch(
        scan,
        currentStatus: currentStatus,
        preferredDevice: preferredDevice,
      );
      final nameMatch = _normalizedReconnectText(scan.name).isNotEmpty &&
          _normalizedReconnectText(scan.name) ==
              _normalizedReconnectText(
                preferredDevice.displayName ?? currentStatus.deviceAlias ?? '',
              );
      candidates.add(
        _IosReconnectCandidate(
          scan: scan,
          rank: identityMatch ? 0 : (nameMatch ? 1 : 2),
          reason: identityMatch
              ? 'known_identity_match'
              : nameMatch
                  ? 'display_name_match'
                  : 'single_eixam_candidate',
        ),
      );
    }
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) {
      final byRank = a.rank.compareTo(b.rank);
      if (byRank != 0) {
        return byRank;
      }
      return b.scan.rssi.compareTo(a.scan.rssi);
    });
    final bestRank = candidates.first.rank;
    final bestRankCount =
        candidates.where((candidate) => candidate.rank == bestRank).length;
    if (bestRankCount != 1) {
      return null;
    }
    if (bestRank == 2 && candidates.length != 1) {
      return null;
    }
    return candidates.first;
  }

  bool _iosReconnectScanHasIdentityMatch(
    BleScanResult scan, {
    required DeviceStatus currentStatus,
    required PreferredDevice preferredDevice,
  }) {
    final scanKeys = _normalizedReconnectKeys(<String?>[
      scan.deviceId,
      scan.canonicalHardwareId,
    ]);
    final knownKeys = _normalizedReconnectKeys(<String?>[
      preferredDevice.deviceId,
      currentStatus.deviceId,
      currentStatus.canonicalHardwareId,
    ]);
    return scanKeys.any(knownKeys.contains);
  }

  bool _isEixamScanCandidate(BleScanResult scan) {
    final hasEixamService = scan.advertisedServiceUuids.any(
      (uuid) =>
          uuid.trim().toLowerCase() ==
          EixamBleProtocol.serviceUuid.toLowerCase(),
    );
    return hasEixamService ||
        scan.brandClassification.name == 'eixam' ||
        scan.name.trim().toLowerCase().contains('eixam');
  }

  Set<String> _normalizedReconnectKeys(Iterable<String?> values) {
    return values
        .map(_normalizedReconnectText)
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  String _normalizedReconnectText(String? value) {
    return value?.trim().toLowerCase() ?? '';
  }

  String _iosReconnectCacheKey({
    required String deviceId,
    required DeviceStatus currentStatus,
    required PreferredDevice preferredDevice,
  }) {
    final keys = _normalizedReconnectKeys(<String?>[
      deviceId,
      preferredDevice.displayName,
      currentStatus.deviceId,
      currentStatus.canonicalHardwareId,
      currentStatus.deviceAlias,
    ]).toList()
      ..sort();
    return keys.join('|');
  }

  String _redactedBleIdentifier(String value) {
    final trimmed = value.trim();
    if (trimmed.length <= 8) {
      return trimmed;
    }
    return '${trimmed.substring(0, 4)}...${trimmed.substring(trimmed.length - 4)}';
  }

  Future<bool> _resolveConnection(String deviceId) async {
    final id = _connectedDeviceId ?? deviceId;
    return _bleClient.isConnected(id);
  }

  Future<void> _bindNotifications(String deviceId) async {
    await _notificationSubscription?.cancel();
    Future<void> commandWriter(EixamDeviceCommand command) {
      _lastAppCommandAt = DateTime.now();
      BleDebugRegistry.instance.recordEvent(
        'BLE app command tracked -> hardwareId=$deviceId command=${command.label} payload=${command.diagnosticPayload}',
      );
      return _bleClient.writeDeviceCommand(deviceId, command);
    }

    BleDebugRegistry.instance.registerCommandWriter(commandWriter);
    BleDebugRegistry.instance.recordEvent(
      'BLE SOS runtime attach requested -> hardwareId=$deviceId inetAvailable=${BleDebugRegistry.instance.currentState.inetFound} cmdAvailable=${BleDebugRegistry.instance.currentState.cmdFound}',
    );
    await _deviceSosController.attach(
      commandWriter: commandWriter,
      shortCommandAvailable: BleDebugRegistry.instance.currentState.inetFound,
      longCommandAvailable: BleDebugRegistry.instance.currentState.cmdFound,
    );
    BleDebugRegistry.instance.recordEvent(
      'BLE SOS runtime attached -> hardwareId=$deviceId inetAvailable=${BleDebugRegistry.instance.currentState.inetFound} cmdAvailable=${BleDebugRegistry.instance.currentState.cmdFound}',
    );

    final stream = await _bleClient.subscribeEixamNotifications(deviceId);
    _notificationSubscription = stream.listen(
      (notification) {
        unawaited(_handleNotification(deviceId, notification));
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'Notify subscription error for $deviceId: $error',
        );
      },
    );
  }

  Future<void> _handleNotification(
    String deviceId,
    EixamBleNotification notification,
  ) async {
    try {
      switch (notification.channel) {
        case EixamBleChannel.tel:
          await _handleTelNotification(deviceId, notification);
          break;
        case EixamBleChannel.sos:
          await _handleSosNotification(deviceId, notification);
          break;
      }
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Notify processing error for $deviceId channel=${notification.channel.name}: $error',
      );
    }
  }

  Future<void> _resetFailedPairingAttempt(String deviceId) async {
    if (_connectedDeviceId != deviceId) {
      return;
    }
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    BleDebugRegistry.instance.clearCommandWriter();
    BleDebugRegistry.instance.update(
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
      commandWriterReady: false,
    );
    await _deviceSosController.detach();
    _connectedDeviceId = null;
    _connectedDeviceAlias = null;
    _connectedCanonicalHardwareId = null;
    _lastAppCommandAt = null;
    _lastTelBatteryLevel = null;
    _lastSosBatteryLevel = null;
    _connectedBleTagNodeId = null;
    _recentSosPacketSignatures.clear();
    _telReassembler.reset();
  }

  Future<DeviceStatus?> suspendOwnership({
    required String reason,
  }) async {
    _ownershipSuspended = true;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    BleDebugRegistry.instance.clearCommandWriter();
    BleDebugRegistry.instance.recordEvent(
      'BLE SOS runtime detach requested -> hardwareId=${_connectedDeviceId ?? "-"} inetAvailable=${BleDebugRegistry.instance.currentState.inetFound} cmdAvailable=${BleDebugRegistry.instance.currentState.cmdFound}',
    );
    await _deviceSosController.detach();
    final deviceId = _connectedDeviceId;
    if (deviceId != null) {
      try {
        await _bleClient.disconnect(deviceId);
      } catch (_) {}
    }
    final currentStatus = _lastRuntimeStatus;
    if (currentStatus == null) {
      return null;
    }
    final nextStatus = currentStatus.copyWith(
      connected: false,
      canonicalHardwareId: currentStatus.canonicalHardwareId,
      lifecycleState: _resolveLifecycle(currentStatus, false),
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );
    _publishRuntimeStatus(nextStatus, reason: 'ownership_released');
    return nextStatus;
  }

  Future<DeviceStatus?> resumeOwnership({
    required String reason,
  }) async {
    _ownershipSuspended = false;
    final currentStatus = _lastRuntimeStatus;
    if (currentStatus == null) {
      return null;
    }
    final nextStatus = currentStatus.copyWith(
      canonicalHardwareId: currentStatus.canonicalHardwareId,
      clearProvisioningError: true,
      lastSyncedAt: DateTime.now(),
    );
    _publishRuntimeStatus(nextStatus, reason: 'ownership_restored');
    return nextStatus;
  }

  @override
  Future<DeviceStatus> activate({
    required DeviceStatus currentStatus,
    required String activationCode,
  }) async {
    if (!currentStatus.paired) {
      throw const DeviceException.notPaired();
    }
    if (activationCode.trim().length < 4) {
      throw const DeviceException.invalidActivationCode();
    }

    BleDebugRegistry.instance.recordEvent(
      'Activation succeeded for ${currentStatus.deviceId}',
    );
    final nextStatus = currentStatus.copyWith(
      activated: true,
      canonicalHardwareId: currentStatus.canonicalHardwareId,
      connected: await _resolveConnection(currentStatus.deviceId),
      lifecycleState: DeviceLifecycleState.ready,
      batteryLevel: _effectiveBatteryLevel(currentStatus),
      batteryState: _effectiveBatteryState(currentStatus),
      batterySource: _effectiveBatterySource(currentStatus),
      firmwareVersion: await _readFirmwareMetadata(
        currentStatus.deviceId,
        currentFirmwareVersion: currentStatus.firmwareVersion,
        reason: 'activation',
      ),
      signalQuality: await _readSignalQuality(
        currentStatus.deviceId,
        reason: 'activation',
      ),
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );
    _publishRuntimeStatus(nextStatus, reason: 'activate_completed');
    return nextStatus;
  }

  @override
  Future<DeviceStatus> refresh(
    DeviceStatus currentStatus, {
    DeviceRefreshMode mode = DeviceRefreshMode.manual,
    bool forceFirmwareRead = false,
  }) async {
    if (!currentStatus.paired) return currentStatus;

    final adapterState = await _bleClient.getAdapterState();
    final connected = adapterState == BleAdapterState.poweredOn &&
        await _resolveConnection(currentStatus.deviceId);
    final readFirmware = mode != DeviceRefreshMode.heartbeat;
    final readSignalQuality = mode != DeviceRefreshMode.heartbeat;
    final firmwareVersion = connected
        ? await _resolveFirmwareForRefresh(
            currentStatus,
            readFirmware: readFirmware,
            forceFirmwareRead: forceFirmwareRead,
            mode: mode,
          )
        : currentStatus.firmwareVersion;
    final signalQuality = connected
        ? await _resolveSignalQualityForRefresh(
            currentStatus,
            readSignalQuality: readSignalQuality,
            mode: mode,
          )
        : currentStatus.signalQuality;
    final runtimeStatus = connected && mode != DeviceRefreshMode.heartbeat
        ? await _readRuntimeStatusAfterConnection(
            deviceId: currentStatus.deviceId,
            reason: 'refresh',
          )
        : null;
    final runtimeBatteryState = _batteryStateFromPercent(
      runtimeStatus?.batteryPercent,
    );
    final runtimeBatteryPercent = runtimeStatus == null
        ? currentStatus.batteryPercent
        : runtimeStatus.batteryPercent;

    BleDebugRegistry.instance.recordEvent(
      'Refreshed device status for ${currentStatus.deviceId}',
    );
    final nextStatus = currentStatus.copyWith(
      connected: connected,
      canonicalHardwareId: currentStatus.canonicalHardwareId,
      provisioningStatus: mode == DeviceRefreshMode.heartbeat
          ? currentStatus.provisioningStatus
          : _provisioningStatusFromRuntime(runtimeStatus),
      batteryPercent: runtimeBatteryPercent,
      batteryLevel: connected && runtimeStatus != null
          ? runtimeBatteryState?.protocolValue
          : _effectiveBatteryLevel(currentStatus),
      batteryState: connected && runtimeStatus != null
          ? runtimeBatteryState
          : _effectiveBatteryState(currentStatus),
      batterySource: connected && runtimeStatus != null
          ? runtimeStatus.batteryPercent != null
              ? DeviceBatterySource.deviceStatus
              : DeviceBatterySource.unknown
          : _effectiveBatterySource(currentStatus),
      firmwareVersion: firmwareVersion,
      signalQuality: signalQuality,
      lifecycleState: _resolveLifecycle(currentStatus, connected),
      lastSeen: connected ? DateTime.now() : currentStatus.lastSeen,
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );
    _publishRuntimeStatus(nextStatus, reason: 'refresh_completed');
    return nextStatus;
  }

  Future<String?> _resolveFirmwareForRefresh(
    DeviceStatus currentStatus, {
    required bool readFirmware,
    required bool forceFirmwareRead,
    required DeviceRefreshMode mode,
  }) async {
    final hasFirmwareCache = _hasFirmwareCache(currentStatus.firmwareVersion);
    if (!readFirmware) {
      if (mode == DeviceRefreshMode.heartbeat &&
          hasFirmwareCache &&
          !_loggedHeartbeatFirmwareSkip) {
        BleDebugRegistry.instance.recordEvent(
          '[BATTERY_FLOW] ble_metadata_read action=skip type=firmware reason=heartbeat_cached',
        );
        _loggedHeartbeatFirmwareSkip = true;
      }
      return currentStatus.firmwareVersion;
    }
    if (!forceFirmwareRead && hasFirmwareCache) {
      return currentStatus.firmwareVersion;
    }
    final reason = hasFirmwareCache ? mode.name : 'missing_cache';
    return _readFirmwareMetadata(
      currentStatus.deviceId,
      currentFirmwareVersion: currentStatus.firmwareVersion,
      reason: reason,
      force: forceFirmwareRead,
    );
  }

  Future<int?> _resolveSignalQualityForRefresh(
    DeviceStatus currentStatus, {
    required bool readSignalQuality,
    required DeviceRefreshMode mode,
  }) async {
    if (!readSignalQuality) {
      if (mode == DeviceRefreshMode.heartbeat && !_loggedHeartbeatSignalSkip) {
        BleDebugRegistry.instance.recordEvent(
          '[BATTERY_FLOW] ble_signal_read action=skip reason=heartbeat',
        );
        _loggedHeartbeatSignalSkip = true;
      }
      return currentStatus.signalQuality;
    }
    return _readSignalQuality(
      currentStatus.deviceId,
      reason: mode.name,
    );
  }

  Future<String?> _readFirmwareMetadata(
    String deviceId, {
    required String? currentFirmwareVersion,
    required String reason,
    bool force = false,
  }) async {
    if (!force && _hasFirmwareCache(currentFirmwareVersion)) {
      return currentFirmwareVersion;
    }
    BleDebugRegistry.instance.recordEvent(
      '[BATTERY_FLOW] ble_metadata_read type=firmware reason=$reason',
    );
    return _bleClient.readFirmwareVersion(deviceId);
  }

  Future<int?> _readSignalQuality(
    String deviceId, {
    required String reason,
  }) async {
    if (_isIosPlatform() && !_shouldReadIosSignalQuality(reason)) {
      _logIosSignalQualityThrottle(reason);
      return _lastIosSignalQuality;
    }
    BleDebugRegistry.instance.recordEvent(
      '[BATTERY_FLOW] ble_signal_read reason=$reason',
    );
    final signalQuality = await _bleClient.readSignalQuality(deviceId);
    if (_isIosPlatform()) {
      _lastIosSignalQualityReadAt = DateTime.now();
      _lastIosSignalQuality = signalQuality;
    }
    return signalQuality;
  }

  bool _shouldReadIosSignalQuality(String reason) {
    if (reason == 'activation' ||
        reason == 'connect' ||
        reason == 'reconnect') {
      return true;
    }
    final lastRead = _lastIosSignalQualityReadAt;
    if (lastRead == null) {
      return true;
    }
    return DateTime.now().difference(lastRead) >=
        _iosSignalQualityThrottleWindow;
  }

  void _logIosSignalQualityThrottle(String reason) {
    final signature = 'platform=ios reason=$reason';
    if (_lastIosSignalQualityThrottleLog == signature) {
      return;
    }
    _lastIosSignalQualityThrottleLog = signature;
    BleDebugRegistry.instance.recordEvent(
      'PERF_RSSI_THROTTLED $signature',
    );
  }

  Future<DeviceRuntimeStatus?> _readRuntimeStatusAfterConnection({
    required String deviceId,
    required String reason,
  }) async {
    try {
      final status = await requestDeviceRuntimeStatus(
        timeout: const Duration(seconds: 2),
      );
      _connectedBleTagNodeId = status.nodeId;
      BleDebugRegistry.instance.recordEvent(
        'Runtime status resolved after $reason -> hardwareId=$deviceId '
        'nodeId=${_formatNodeId(status.nodeId)} '
        'battery=${status.batteryPercent}',
      );
      return status;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Runtime status unavailable after $reason -> hardwareId=$deviceId '
        'error=$error',
      );
      return null;
    }
  }

  DeviceBatteryLevel? _batteryStateFromPercent(int? percent) {
    return DeviceBatteryLevel.fromPercentage(percent);
  }

  bool _hasFirmwareCache(String? firmwareVersion) {
    final normalized = firmwareVersion?.trim().toLowerCase();
    return normalized != null &&
        normalized.isNotEmpty &&
        normalized != 'unknown';
  }

  @override
  Future<DeviceStatus> unpair(DeviceStatus currentStatus) async {
    final systemAssociationDeviceId =
        _connectedDeviceId?.trim().isNotEmpty == true
            ? _connectedDeviceId!
            : currentStatus.deviceId.trim();
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    BleDebugRegistry.instance.recordEvent(
      'BLE SOS runtime detach requested -> hardwareId=${_connectedDeviceId ?? "-"} reason=unpair inetAvailable=${BleDebugRegistry.instance.currentState.inetFound} cmdAvailable=${BleDebugRegistry.instance.currentState.cmdFound}',
    );
    await _deviceSosController.detach();
    if (_connectedDeviceId != null) {
      await _bleClient.disconnect(_connectedDeviceId!);
    }
    if (systemAssociationDeviceId.isNotEmpty) {
      final removed =
          await _bleClient.removeSystemAssociation(systemAssociationDeviceId);
      BleDebugRegistry.instance.recordEvent(
        removed
            ? 'Device system association removed'
            : 'Device system association removal skipped',
      );
    }
    _connectedDeviceId = null;
    _connectedDeviceAlias = null;
    _connectedCanonicalHardwareId = null;
    _lastAppCommandAt = null;
    _lastTelBatteryLevel = null;
    _lastSosBatteryLevel = null;
    _connectedBleTagNodeId = null;
    _recentSosPacketSignatures.clear();
    _telReassembler.reset();
    BleDebugRegistry.instance.update(
      connectionStatus: BleConnectionStatus.disconnectedManual,
      connectionError: null,
    );
    BleDebugRegistry.instance.recordEvent('Device unpaired');

    final nextStatus = DeviceStatus(
      deviceId: currentStatus.deviceId,
      nodeId: currentStatus.nodeId,
      canonicalHardwareId: currentStatus.canonicalHardwareId,
      deviceAlias: currentStatus.deviceAlias,
      model: currentStatus.model,
      paired: false,
      activated: false,
      connected: false,
      provisioningStatus: DeviceProvisioningStatus.unknown,
      batteryLevel: null,
      batteryState: null,
      batterySource: null,
      firmwareVersion: currentStatus.firmwareVersion,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: null,
      lifecycleState: DeviceLifecycleState.unpaired,
      provisioningError: null,
    );
    _publishRuntimeStatus(nextStatus, reason: 'unpair_completed');
    return nextStatus;
  }

  Future<void> setNotificationVolume(int volume) {
    _validateVolume(volume);
    return _runDeviceCommand(
      command: EixamDeviceCommand.notificationVolume(volume),
      missingDeviceMessage: _deviceCommandNotReadyCode,
      missingDeviceError: const DeviceException(
        _deviceCommandNotReadyCode,
        _deviceCommandNotReadyCode,
      ),
    );
  }

  Future<void> setSosVolume(int volume) {
    _validateVolume(volume);
    return _runDeviceCommand(
      command: EixamDeviceCommand.sosVolume(volume),
      missingDeviceMessage: _deviceCommandNotReadyCode,
      missingDeviceError: const DeviceException(
        _deviceCommandNotReadyCode,
        _deviceCommandNotReadyCode,
      ),
    );
  }

  Future<void> rebootDevice() {
    return _runDeviceCommand(
      command: EixamDeviceCommand.reboot(),
      missingDeviceMessage: _deviceCommandNotReadyCode,
      missingDeviceError: const DeviceException(
        _deviceCommandNotReadyCode,
        _deviceCommandNotReadyCode,
      ),
    );
  }

  Future<DeviceRuntimeStatus> requestDeviceRuntimeStatus({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_pendingRuntimeStatusRequest != null) {
      throw const DeviceException(
        _deviceStatusTimeoutCode,
        _deviceStatusTimeoutCode,
      );
    }
    final completer = Completer<DeviceRuntimeStatus>();
    _pendingRuntimeStatusRequest = completer;
    try {
      await _runDeviceCommand(
        command: EixamDeviceCommand.getDeviceStatus(),
        missingDeviceMessage: _deviceCommandNotReadyCode,
        missingDeviceError: const DeviceException(
          _deviceCommandNotReadyCode,
          _deviceCommandNotReadyCode,
        ),
      );
      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw const DeviceException(
          _deviceStatusTimeoutCode,
          _deviceStatusTimeoutCode,
        ),
      );
    } finally {
      if (identical(_pendingRuntimeStatusRequest, completer)) {
        _pendingRuntimeStatusRequest = null;
      }
    }
  }

  void _log(String message) {}

  DeviceSosTransitionSource _inferPacketSource() {
    final lastAppCommandAt = _lastAppCommandAt;
    if (lastAppCommandAt == null) {
      return DeviceSosTransitionSource.device;
    }
    final elapsed = DateTime.now().difference(lastAppCommandAt);
    if (elapsed <= const Duration(milliseconds: 1200)) {
      return DeviceSosTransitionSource.app;
    }
    return DeviceSosTransitionSource.device;
  }

  String _formatNodeId(int nodeId) {
    final normalized = nodeId & 0xFFFFFFFF;
    return '0x${normalized.toRadixString(16).padLeft(8, '0')} ($nodeId)';
  }

  void _logRawIncomingSosPacket({
    required String source,
    required List<int> payload,
    required String payloadHex,
    required EixamBleChannel channel,
    required String classificationBefore,
  }) {
    if (!_isSosLikePayload(payload)) {
      return;
    }
    final sosPacket = EixamSosPacket.tryParse(payload);
    final eventPacket =
        payload.length == 6 ? EixamSosEventPacket.tryParse(payload) : null;
    final decodedNodeId = sosPacket?.nodeId ?? eventPacket?.nodeId;
    BleDebugRegistry.instance.recordEvent(
      'BLE_SOS_PACKET_RAW source=$source raw=$payloadHex '
      'length=${payload.length} channel=${channel.name} '
      'connectedNodeId=${_connectedBleTagNodeId?.toString() ?? "none"} '
      'decodedNodeId=${decodedNodeId?.toString() ?? "none"} '
      'relayNodeId=${_connectedBleTagNodeId?.toString() ?? "none"} '
      'classificationBefore=$classificationBefore '
      'packetTypeByte=${_packetTypeByte(payload)} '
      'statusByte=${_statusByte(payload)} '
      'lastByte=${_lastByte(payload)} '
      'sequenceByte=${_sequenceByte(payload)} '
      'flagsWord=${sosPacket == null ? "none" : _hexWord(sosPacket.flagsWord)} '
      'sosType=${sosPacket?.sosType.toString() ?? "none"} '
      'retryCount=${sosPacket?.retryCount.toString() ?? "none"} '
      'relayCount=${sosPacket?.relayCount.toString() ?? "none"} '
      'packetId=${sosPacket?.packetId.toString() ?? "none"} '
      'eventOpcode=${eventPacket == null ? "none" : _hexByte(eventPacket.opcode)} '
      'eventSubcode=${eventPacket == null ? "none" : _hexByte(eventPacket.subcode)}',
    );
  }

  void _logIncomingSosClassifyDecision({
    required List<int> payload,
    required String payloadHex,
    required BleIncomingPayloadClassification classification,
    required String source,
  }) {
    if (!_isSosLikePayload(payload)) {
      return;
    }
    final sosPacket =
        classification.sosPacket ?? EixamSosPacket.tryParse(payload);
    final eventPacket = classification.sosEventPacket ??
        (payload.length == 6 ? EixamSosEventPacket.tryParse(payload) : null);
    final nodeId = sosPacket?.nodeId ?? eventPacket?.nodeId;
    final remoteSnapshot = classification.remoteRelaySosSnapshot;
    final terminalFlag = eventPacket != null ||
        classification.kind == BleIncomingPayloadKind.sosCancel ||
        classification.kind == BleIncomingPayloadKind.sosClear ||
        remoteSnapshot?.kind == RemoteRelaySosKind.cancel ||
        remoteSnapshot?.kind == RemoteRelaySosKind.clear;
    final cancelFlag =
        classification.kind == BleIncomingPayloadKind.sosCancel ||
            classification.kind == BleIncomingPayloadKind.sosClear ||
            remoteSnapshot?.kind == RemoteRelaySosKind.cancel ||
            remoteSnapshot?.kind == RemoteRelaySosKind.clear;
    BleDebugRegistry.instance.recordEvent(
      'BLE_SOS_CLASSIFY_DECISION raw=$payloadHex '
      'packetType=${eventPacket != null ? "sos_event" : sosPacket != null ? "sos" : _packetTypeByte(payload)} '
      'classification=${classification.kind.name} '
      'reason=${_classificationReason(classification)} '
      'source=$source nodeId=${nodeId?.toString() ?? "none"} '
      'relayNodeId=${remoteSnapshot?.relayNodeId?.toString() ?? _connectedBleTagNodeId?.toString() ?? "none"} '
      'statusByte=${_statusByte(payload)} terminalFlag=$terminalFlag '
      'cancelFlag=$cancelFlag',
    );
  }

  String _classificationReason(
      BleIncomingPayloadClassification classification) {
    switch (classification.kind) {
      case BleIncomingPayloadKind.ownDeviceSos:
        return 'originator_matches_connected_ble_node';
      case BleIncomingPayloadKind.remoteRelaySos:
        return classification.remoteRelaySosSnapshot?.relayNodeId == null
            ? 'fallback_remote_relay_connected_node_unknown'
            : 'originator_differs_from_connected_ble_node';
      case BleIncomingPayloadKind.unknownOriginSos:
        return 'connected_ble_node_unknown';
      case BleIncomingPayloadKind.sosCancel:
      case BleIncomingPayloadKind.sosClear:
        return classification.remoteRelaySosSnapshot == null
            ? 'terminal_event_local'
            : 'terminal_event_remote_relay';
      case BleIncomingPayloadKind.telPosition:
        return 'tel_packet';
      case BleIncomingPayloadKind.telRelayRx:
        return 'tel_relay_packet';
      case BleIncomingPayloadKind.unknown:
        return 'unknown_or_ignored';
    }
  }

  bool _isSosLikePayload(List<int> payload) {
    return payload.length == 6 ||
        payload.length == EixamBleProtocol.sosPacketLengthMinimal ||
        payload.length == EixamBleProtocol.sosPacketLengthWithPosition ||
        payload.length == EixamBleProtocol.sosPacketLengthMinimal + 6 ||
        payload.length == EixamBleProtocol.sosPacketLengthWithPosition + 6 ||
        _looksLikeTerminalOpcode(payload);
  }

  bool _looksLikeTerminalOpcode(List<int> payload) {
    if (payload.isEmpty) {
      return false;
    }
    return payload.first == EixamBleProtocol.sosEventUserDeactivatedOpcode ||
        payload.first == EixamBleProtocol.sosEventAppCancelAckOpcode;
  }

  String _packetTypeByte(List<int> payload) {
    if (payload.isEmpty) {
      return 'none';
    }
    return _hexByte(payload.first);
  }

  String _statusByte(List<int> payload) {
    if (payload.length == 6) {
      return _hexByte(payload[1]);
    }
    if (payload.length >= EixamBleProtocol.sosPacketLengthWithPosition) {
      return _hexByte(payload[11]);
    }
    if (payload.length >= EixamBleProtocol.sosPacketLengthMinimal) {
      return _hexByte(payload[5]);
    }
    return 'none';
  }

  String _lastByte(List<int> payload) {
    if (payload.isEmpty) {
      return 'none';
    }
    return _hexByte(payload.last);
  }

  String _sequenceByte(List<int> payload) {
    if (payload.length == EixamBleProtocol.sosPacketLengthMinimal) {
      return _hexByte(payload[6]);
    }
    final packet = EixamSosPacket.tryParse(payload);
    return packet == null ? 'none' : packet.packetId.toString();
  }

  String _hexByte(int value) {
    return '0x${(value & 0xFF).toRadixString(16).padLeft(2, '0')}';
  }

  String _hexWord(int value) {
    return '0x${(value & 0xFFFF).toRadixString(16).padLeft(4, '0')}';
  }

  String _characteristicLabelForChannel(EixamBleChannel channel) {
    switch (channel) {
      case EixamBleChannel.tel:
        return 'ea01';
      case EixamBleChannel.sos:
        return 'ea02';
    }
  }

  Future<void> _handleUnexpectedDisconnect(String deviceId) async {
    if (_ownershipSuspended) {
      BleDebugRegistry.instance.recordEvent(
        'BLE_UNEXPECTED_DISCONNECT_IGNORED reason=flutter_ble_ownership_suspended',
      );
      return;
    }
    final currentStatus = _lastRuntimeStatus;
    if (currentStatus == null || !currentStatus.connected) {
      return;
    }

    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    BleDebugRegistry.instance.clearCommandWriter();
    BleDebugRegistry.instance.update(
      telNotifySubscribed: false,
      sosNotifySubscribed: false,
      commandWriterReady: false,
      connectionStatus: BleConnectionStatus.disconnectedUnexpected,
      connectionError: 'Unexpected BLE disconnect',
    );
    BleDebugRegistry.instance.recordEvent(
      'Unexpected disconnect detected for $deviceId',
    );

    final nextStatus = currentStatus.copyWith(
      connected: false,
      canonicalHardwareId: currentStatus.canonicalHardwareId,
      lifecycleState: _resolveLifecycle(currentStatus, false),
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );
    _publishRuntimeStatus(nextStatus, reason: 'unexpected_disconnect');
  }

  Future<void> _handleTelNotification(
    String deviceId,
    EixamBleNotification notification,
  ) async {
    final source = DeviceSosTransitionSource.device;
    BleDebugRegistry.instance.recordIncomingNotification(
      channel: notification.channel.name,
      characteristic: _characteristicLabelForChannel(notification.channel),
      payloadHex: notification.payloadHex,
      receivedAt: notification.receivedAt,
    );
    BleDebugRegistry.instance.recordEvent(
      'TEL raw payload (ea01) -> len=${notification.payload.length} payload=${notification.payloadHex}',
    );

    final telFragment = EixamTelFragment.tryParse(notification.payload);
    if (telFragment != null) {
      BleDebugRegistry.instance.recordEvent(
        'TEL aggregate fragment decoded -> totalLen=${telFragment.totalLength} offset=${telFragment.offset} fragmentLen=${telFragment.fragmentLength}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.telAggregateFragment.name,
        outcome: BleIncomingEventType.telAggregateFragment.name,
        receivedAt: notification.receivedAt,
      );
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.telAggregateFragment,
          channel: notification.channel,
          payload: List<int>.unmodifiable(notification.payload),
          payloadHex: notification.payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          telFragment: telFragment,
        ),
      );

      final completedPayload = _telReassembler.addFragment(telFragment);
      if (completedPayload != null) {
        BleDebugRegistry.instance.recordEvent(
          'TEL aggregate completed -> totalLen=${completedPayload.length} payload=${EixamBleProtocol.hex(completedPayload)}',
        );
        await _dispatchClassifiedTelPayload(
          deviceId: deviceId,
          notification: notification,
          payload: completedPayload,
          payloadHex: EixamBleProtocol.hex(completedPayload),
          source: source,
          telFragment: telFragment,
          aggregatePayload: completedPayload,
        );
      }
      return;
    }

    await _dispatchClassifiedTelPayload(
      deviceId: deviceId,
      notification: notification,
      payload: notification.payload,
      payloadHex: notification.payloadHex,
      source: source,
    );
  }

  Future<void> _dispatchClassifiedTelPayload({
    required String deviceId,
    required EixamBleNotification notification,
    required List<int> payload,
    required String payloadHex,
    required DeviceSosTransitionSource source,
    EixamTelFragment? telFragment,
    List<int>? aggregatePayload,
  }) async {
    _logRawIncomingSosPacket(
      source: 'ble_device_runtime_provider_tel_entry',
      payload: payload,
      payloadHex: payloadHex,
      channel: notification.channel,
      classificationBefore: 'before_tel_dispatch',
    );
    final provisioningResult = ProvisioningCommandResult.tryParse(payload);
    if (provisioningResult != null) {
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.provisioningCommandResult.name,
        outcome: BleIncomingEventType.provisioningCommandResult.name,
        receivedAt: notification.receivedAt,
      );
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.provisioningCommandResult,
          channel: notification.channel,
          payload: List<int>.unmodifiable(payload),
          payloadHex: payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          provisioningCommandResult: provisioningResult,
        ),
      );
      return;
    }

    if (payload.isNotEmpty && payload.first == EixamTelLiveBatchPacket.opcode) {
      final liveBatch = EixamTelLiveBatchPacket.tryParse(
        payload,
        receivedAt: notification.receivedAt,
      );
      if (liveBatch == null) {
        BleDebugRegistry.instance.recordEvent(
          'SDK_TEL_LIVE_BATCH claimed=false malformed_or_collision=true',
        );
      } else {
        final invalidTimestampCount = liveBatch.batch.samples
            .where((sample) => !sample.timestampValid)
            .length;
        BleDebugRegistry.instance.recordEvent(
          'SDK_TEL_LIVE_BATCH received_count=${liveBatch.batch.samples.length} '
          'timestamp_invalid_count=$invalidTimestampCount',
        );
        _incomingEventsController.add(
          BleIncomingEvent(
            deviceId: deviceId,
            canonicalHardwareId: _connectedCanonicalHardwareId,
            deviceAlias: _connectedDeviceAlias,
            type: BleIncomingEventType.telLivePositionBatch,
            channel: notification.channel,
            payload: List<int>.unmodifiable(payload),
            payloadHex: payloadHex,
            source: source,
            receivedAt: notification.receivedAt,
            meshPort: notification.meshPort,
            telFragment: telFragment,
            aggregatePayload:
                aggregatePayload ?? List<int>.unmodifiable(payload),
            telLiveBatchPacket: liveBatch,
          ),
        );
        BleDebugRegistry.instance.recordEvent(
          'SDK_TEL_LIVE_BATCH published_count=${liveBatch.batch.samples.length}',
        );
        return;
      }
    }

    final runtimeStatusPacket = EixamDeviceRuntimeStatusPacket.tryParse(
      payload,
      receivedAt: notification.receivedAt,
    );
    if (runtimeStatusPacket != null) {
      _connectedBleTagNodeId = runtimeStatusPacket.status.nodeId;
      _publishDeviceRuntimeStatus(runtimeStatusPacket.status);
      BleDebugRegistry.instance.recordEvent(
        'TEL classified -> type=device_status len=${payload.length} nodeId=${_formatNodeId(runtimeStatusPacket.status.nodeId)} battery=${runtimeStatusPacket.status.batteryPercent} telInterval=${runtimeStatusPacket.status.telIntervalSeconds}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.deviceRuntimeStatus.name,
        outcome: BleIncomingEventType.deviceRuntimeStatus.name,
        receivedAt: notification.receivedAt,
      );
      _pendingRuntimeStatusRequest?.complete(runtimeStatusPacket.status);
      _pendingRuntimeStatusRequest = null;
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.deviceRuntimeStatus,
          channel: notification.channel,
          payload: List<int>.unmodifiable(payload),
          payloadHex: payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          telFragment: telFragment,
          aggregatePayload: aggregatePayload,
          deviceRuntimeStatusPacket: runtimeStatusPacket,
        ),
      );
      return;
    }

    if (payload.length == EixamTelRelayRxPacket.payloadLength &&
        payload.first == EixamTelRelayRxPacket.opcode) {
      final relayPacket = EixamTelRelayRxPacket.tryParse(
        payload,
        receivedAt: notification.receivedAt,
      );
      final peerPayload = payload.sublist(1, 13);
      final selfPayload = payload.sublist(15, 27);
      final selfTelPacket = EixamTelPacket.tryParse(selfPayload);
      BleDebugRegistry.instance.recordEvent(
        'TEL classified -> type=relay len=${payload.length} peerType=${_classifyEmbeddedWireType(peerPayload)} selfType=${_classifyEmbeddedWireType(selfPayload)} peerNode=${_nodeIdForEmbeddedWire(peerPayload) ?? "-"} selfNode=${_nodeIdForEmbeddedWire(selfPayload) ?? "-"}',
      );
      if (relayPacket != null) {
        _connectedBleTagNodeId ??= relayPacket.selfPacket.nodeId;
      } else if (selfTelPacket != null) {
        _connectedBleTagNodeId ??= selfTelPacket.nodeId;
      }
      final d2RelayClassification = _classifyD2RelayPeerPayload(
        payload: peerPayload,
        payloadHex: EixamBleProtocol.hex(peerPayload),
        receivedAt: notification.receivedAt,
      );
      final d2SosPacket = d2RelayClassification.sosPacket;
      if (d2SosPacket != null) {
        _logSosIdentityDecision(
          originatorNodeId: d2SosPacket.nodeId,
          connectedBleNodeId: _connectedBleTagNodeId,
          relayNodeId: _connectedBleTagNodeId,
          sourceChannel: 'd2Relay',
          platformEventType: null,
          decision:
              d2RelayClassification.kind == BleIncomingPayloadKind.ownDeviceSos
                  ? 'own_device'
                  : d2RelayClassification.kind ==
                          BleIncomingPayloadKind.remoteRelaySos
                      ? 'remote_relay'
                      : 'unknown_hold',
          reason:
              d2RelayClassification.kind == BleIncomingPayloadKind.ownDeviceSos
                  ? 'originator_matches_connected_ble_node'
                  : _connectedBleTagNodeId == null
                      ? 'connected_ble_node_unknown'
                      : 'originator_differs_from_connected_ble_node',
        );
      }
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.telRelayRx.name,
        outcome: BleIncomingEventType.telRelayRx.name,
        receivedAt: notification.receivedAt,
      );
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.telRelayRx,
          channel: notification.channel,
          payload: List<int>.unmodifiable(payload),
          payloadHex: payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          telFragment: telFragment,
          aggregatePayload: aggregatePayload,
          telRelayRxPacket: relayPacket,
          classification: d2RelayClassification,
          remoteRelaySosSnapshot: d2RelayClassification.remoteRelaySosSnapshot,
        ),
      );
      return;
    }

    if (payload.isNotEmpty &&
        payload.first == EixamTelRelayClusterPacket.opcode) {
      final clusterPacket = EixamTelRelayClusterPacket.tryParse(payload);
      BleDebugRegistry.instance.recordEvent(
        'TEL classified -> type=cluster_aggregate len=${payload.length} clusterId=${clusterPacket?.clusterId ?? "-"} members=${clusterPacket?.members.length ?? "-"}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.telAggregateComplete.name,
        outcome: BleIncomingEventType.telAggregateComplete.name,
        receivedAt: notification.receivedAt,
      );
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.telAggregateComplete,
          channel: notification.channel,
          payload: List<int>.unmodifiable(payload),
          payloadHex: payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          telFragment: telFragment,
          aggregatePayload: aggregatePayload ?? List<int>.unmodifiable(payload),
        ),
      );
      return;
    }

    if (notification.meshPort == 260) {
      final heartbeatPacket = EixamClusterHeartbeatPacket.tryParse(payload);
      if (heartbeatPacket != null) {
        BleDebugRegistry.instance.recordEvent(
          'TEL classified -> type=cluster_heartbeat len=${payload.length} nodeId=${_formatNodeId(heartbeatPacket.nodeId)} clusterId=${heartbeatPacket.clusterId} aggId=0x${heartbeatPacket.aggId.toRadixString(16).padLeft(8, '0')} score=${heartbeatPacket.score} members=${heartbeatPacket.memberCount} aggSf=${heartbeatPacket.aggSpreadingFactor}',
        );
        BleDebugRegistry.instance.recordDecodedIncomingEvent(
          eventType: BleIncomingEventType.clusterHeartbeat.name,
          outcome: BleIncomingEventType.clusterHeartbeat.name,
          receivedAt: notification.receivedAt,
        );
        _incomingEventsController.add(
          BleIncomingEvent(
            deviceId: deviceId,
            canonicalHardwareId: _connectedCanonicalHardwareId,
            deviceAlias: _connectedDeviceAlias,
            type: BleIncomingEventType.clusterHeartbeat,
            channel: notification.channel,
            payload: List<int>.unmodifiable(payload),
            payloadHex: payloadHex,
            source: source,
            receivedAt: notification.receivedAt,
            meshPort: notification.meshPort,
            telFragment: telFragment,
            aggregatePayload: aggregatePayload,
            clusterHeartbeatPacket: heartbeatPacket,
          ),
        );
        return;
      }
    }

    _logRawIncomingSosPacket(
      source: 'ble_device_runtime_provider',
      payload: payload,
      payloadHex: payloadHex,
      channel: notification.channel,
      classificationBefore: 'before_payload_classifier',
    );

    var classification = _payloadClassifier.classifySosPayload(
      payload: payload,
      payloadHex: payloadHex,
      receivedAt: notification.receivedAt,
      source: source,
      channel: notification.channel,
      connectedBleTagNodeId: _connectedBleTagNodeId,
      fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
        kind: BleIncomingPayloadKind.unknownOriginSos,
      ),
    );
    classification = await _resolveUnknownOriginSosClassification(
      classification: classification,
      payload: payload,
      payloadHex: payloadHex,
      receivedAt: notification.receivedAt,
      source: source,
      channel: notification.channel,
      reason: 'tel_sos_unknown_origin',
    );
    _logIncomingSosClassifyDecision(
      payload: payload,
      payloadHex: payloadHex,
      classification: classification,
      source: 'ble_device_runtime_provider_post_resolve',
    );
    if (classification.kind == BleIncomingPayloadKind.ownDeviceSos ||
        classification.kind == BleIncomingPayloadKind.remoteRelaySos) {
      final sosPacket = classification.sosPacket!;
      _logSosIdentityDecision(
        originatorNodeId: sosPacket.nodeId,
        connectedBleNodeId: _connectedBleTagNodeId,
        relayNodeId: _connectedBleTagNodeId,
        sourceChannel: notification.channel.name,
        platformEventType: null,
        decision: classification.kind == BleIncomingPayloadKind.ownDeviceSos
            ? 'own_device'
            : 'remote_relay',
        reason: classification.kind == BleIncomingPayloadKind.ownDeviceSos
            ? 'originator_matches_connected_ble_node'
            : 'originator_differs_from_connected_ble_node',
      );
      BleDebugRegistry.instance.recordEvent(
        'TEL classified -> type=sos role=${classification.kind.name} len=${payload.length} nodeId=${_formatNodeId(sosPacket.nodeId)} sosType=${sosPacket.sosType} packetId=${sosPacket.packetId} relayCount=${sosPacket.relayCount}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.sosMeshPacket.name,
        outcome: BleIncomingEventType.sosMeshPacket.name,
        receivedAt: notification.receivedAt,
      );
      if (classification.kind == BleIncomingPayloadKind.ownDeviceSos) {
        _handleSosBatteryUpdate(sosPacket);
        if (_shouldProcessSosPacket(
          nodeId: sosPacket.nodeId,
          packetId: sosPacket.packetId,
          rawHex: sosPacket.rawHex,
        )) {
          _deviceSosController.handleIncomingSosPacket(
            sosPacket,
            source: source,
          );
        } else {
          BleDebugRegistry.instance.recordEvent(
            'SOS duplicate suppressed -> ${sosPacket.rawHex}',
          );
        }
      }
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.sosMeshPacket,
          channel: notification.channel,
          payload: List<int>.unmodifiable(payload),
          payloadHex: payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          telFragment: telFragment,
          aggregatePayload: aggregatePayload,
          sosPacket: sosPacket,
          classification: classification,
          remoteRelaySosSnapshot: classification.remoteRelaySosSnapshot,
        ),
      );
      return;
    }

    final unknownOriginSosPacket = classification.sosPacket;
    if (classification.kind == BleIncomingPayloadKind.unknownOriginSos &&
        unknownOriginSosPacket != null) {
      _logSosIdentityDecision(
        originatorNodeId: unknownOriginSosPacket.nodeId,
        connectedBleNodeId: _connectedBleTagNodeId,
        relayNodeId: _connectedBleTagNodeId,
        sourceChannel: notification.channel.name,
        platformEventType: null,
        decision: 'unknown_hold',
        reason: 'connected_ble_node_unknown',
      );
    }

    final telPacket = classification.telPacket;
    if (telPacket != null) {
      BleDebugRegistry.instance.recordEvent(
        'TEL classified -> type=tel len=${payload.length} nodeId=${_formatNodeId(telPacket.nodeId)} packetId=${telPacket.packetId} batt=${telPacket.batteryLevel} gps=${telPacket.gpsQuality}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.telPosition.name,
        outcome: BleIncomingEventType.telPosition.name,
        receivedAt: notification.receivedAt,
      );
      _handleTelBatteryUpdate(telPacket);
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.telPosition,
          channel: notification.channel,
          payload: List<int>.unmodifiable(payload),
          payloadHex: payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          telFragment: telFragment,
          aggregatePayload: aggregatePayload,
          telPacket: telPacket,
          classification: classification,
        ),
      );
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      'TEL classified -> type=unknown len=${payload.length} payload=$payloadHex',
    );
    BleDebugRegistry.instance.recordDecodedIncomingEvent(
      eventType: BleIncomingEventType.unknownProtocolPacket.name,
      outcome: 'ignored_unknown',
      receivedAt: notification.receivedAt,
    );
    _incomingEventsController.add(
      BleIncomingEvent(
        deviceId: deviceId,
        canonicalHardwareId: _connectedCanonicalHardwareId,
        deviceAlias: _connectedDeviceAlias,
        type: BleIncomingEventType.unknownProtocolPacket,
        channel: notification.channel,
        payload: List<int>.unmodifiable(payload),
        payloadHex: payloadHex,
        source: source,
        receivedAt: notification.receivedAt,
        meshPort: notification.meshPort,
        telFragment: telFragment,
        aggregatePayload: aggregatePayload,
        classification: classification,
      ),
    );
  }

  String _classifyEmbeddedWireType(List<int> payload) {
    final sosPacket = EixamSosPacket.tryParse(payload);
    if (sosPacket != null && sosPacket.sosType != 0) {
      return 'sos';
    }
    if (EixamTelPacket.tryParse(payload) != null) {
      return 'tel';
    }
    return 'unknown';
  }

  String? _nodeIdForEmbeddedWire(List<int> payload) {
    final sosPacket = EixamSosPacket.tryParse(payload);
    if (sosPacket != null) {
      return _formatNodeId(sosPacket.nodeId);
    }
    final telPacket = EixamTelPacket.tryParse(payload);
    if (telPacket != null) {
      return _formatNodeId(telPacket.nodeId);
    }
    return null;
  }

  BleIncomingPayloadClassification _classifyD2RelayPeerPayload({
    required List<int> payload,
    required String payloadHex,
    required DateTime receivedAt,
  }) {
    _logRawIncomingSosPacket(
      source: 'ble_device_runtime_provider_d2_relay_peer',
      payload: payload,
      payloadHex: payloadHex,
      channel: EixamBleChannel.tel,
      classificationBefore: 'before_d2_peer_classifier',
    );
    final sosPacket = EixamSosPacket.tryParse(payload);
    if (sosPacket == null || sosPacket.sosType == 0) {
      const classification = BleIncomingPayloadClassification(
        kind: BleIncomingPayloadKind.telRelayRx,
      );
      _logIncomingSosClassifyDecision(
        payload: payload,
        payloadHex: payloadHex,
        classification: classification,
        source: 'ble_device_runtime_provider_d2_relay_peer',
      );
      return classification;
    }
    final connectedNodeId = _connectedBleTagNodeId;
    final kind = connectedNodeId == null
        ? BleIncomingPayloadKind.unknownOriginSos
        : sosPacket.nodeId == connectedNodeId
            ? BleIncomingPayloadKind.ownDeviceSos
            : BleIncomingPayloadKind.remoteRelaySos;
    if (kind != BleIncomingPayloadKind.remoteRelaySos) {
      final classification =
          BleIncomingPayloadClassification(kind: kind, sosPacket: sosPacket);
      _logIncomingSosClassifyDecision(
        payload: payload,
        payloadHex: payloadHex,
        classification: classification,
        source: 'ble_device_runtime_provider_d2_relay_peer',
      );
      return classification;
    }
    final classification = BleIncomingPayloadClassification(
      kind: BleIncomingPayloadKind.remoteRelaySos,
      sosPacket: sosPacket,
      remoteRelaySosSnapshot: RemoteRelaySosSnapshot(
        kind: RemoteRelaySosKind.sos,
        originatorNodeId: sosPacket.nodeId,
        relayNodeId: connectedNodeId,
        source: RemoteRelaySosSource.d2Relay,
        sosType: sosPacket.sosType,
        location: sosPacket.position == null
            ? null
            : TrackingPosition(
                latitude: sosPacket.position!.latitude,
                longitude: sosPacket.position!.longitude,
                altitude: sosPacket.position!.altitudeMeters.toDouble(),
                timestamp: receivedAt,
                source: DeliveryMode.mesh,
              ),
        receivedAt: receivedAt,
        rawPayload: List<int>.unmodifiable(payload),
        payloadHex: payloadHex,
        relayCount: sosPacket.relayCount,
      ),
    );
    _logIncomingSosClassifyDecision(
      payload: payload,
      payloadHex: payloadHex,
      classification: classification,
      source: 'ble_device_runtime_provider_d2_relay_peer',
    );
    return classification;
  }

  Future<void> _bindConnectionMonitor(String deviceId) async {
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = _bleClient.watchConnection(deviceId).listen(
      (isConnected) {
        if (isConnected) {
          return;
        }
        unawaited(_handleUnexpectedDisconnect(deviceId));
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'Connection monitor error for $deviceId: $error',
        );
      },
    );
  }

  Future<void> _handleSosNotification(
    String deviceId,
    EixamBleNotification notification,
  ) async {
    final source = _inferPacketSource();
    BleDebugRegistry.instance.recordIncomingNotification(
      channel: notification.channel.name,
      characteristic: _characteristicLabelForChannel(notification.channel),
      payloadHex: notification.payloadHex,
      receivedAt: notification.receivedAt,
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS raw payload (ea02) -> len=${notification.payload.length} payload=${notification.payloadHex}',
    );
    _logRawIncomingSosPacket(
      source: 'ble_device_runtime_provider_sos_notify',
      payload: notification.payload,
      payloadHex: notification.payloadHex,
      channel: notification.channel,
      classificationBefore: 'before_sos_notify_classifier',
    );

    var sosEventPacket = notification.payload.length == 6
        ? _payloadClassifier.classifySosPayload(
            payload: notification.payload,
            payloadHex: notification.payloadHex,
            receivedAt: notification.receivedAt,
            source: source,
            channel: notification.channel,
            connectedBleTagNodeId: _connectedBleTagNodeId,
            fallbackOnUnknownConnectedNode:
                const BleIncomingPayloadClassification(
              kind: BleIncomingPayloadKind.remoteRelaySos,
            ),
          )
        : null;
    sosEventPacket = await _resolveUnknownOriginSosEventClassification(
      classification: sosEventPacket,
      receivedAt: notification.receivedAt,
      reason: 'sos_event_unknown_origin',
    );
    if (sosEventPacket != null) {
      _logIncomingSosClassifyDecision(
        payload: notification.payload,
        payloadHex: notification.payloadHex,
        classification: sosEventPacket,
        source: 'ble_device_runtime_provider_sos_event_post_resolve',
      );
    }
    if (sosEventPacket?.sosEventPacket != null) {
      final packet = sosEventPacket!.sosEventPacket!;
      final isLocalEvent = packet.nodeId == _connectedBleTagNodeId;
      _logSosIdentityDecision(
        originatorNodeId: packet.nodeId,
        connectedBleNodeId: _connectedBleTagNodeId,
        relayNodeId: _connectedBleTagNodeId,
        sourceChannel: notification.channel.name,
        platformEventType: null,
        decision: isLocalEvent
            ? 'own_device'
            : _connectedBleTagNodeId == null
                ? 'unknown_hold'
                : 'remote_relay',
        reason: isLocalEvent
            ? 'originator_matches_connected_ble_node'
            : _connectedBleTagNodeId == null
                ? 'connected_ble_node_unknown'
                : 'originator_differs_from_connected_ble_node',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS device event decoded -> role=${isLocalEvent ? "connected_tag" : "remote_relay"} nodeId=${_formatNodeId(packet.nodeId)} opcode=0x${packet.opcode.toRadixString(16).padLeft(2, '0')} subcode=0x${packet.subcode.toRadixString(16).padLeft(2, '0')}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.sosDeviceEvent.name,
        outcome: BleIncomingEventType.sosDeviceEvent.name,
        receivedAt: notification.receivedAt,
      );
      if (isLocalEvent) {
        if (_shouldProcessSosPacket(
          nodeId: packet.nodeId,
          packetId: null,
          rawHex: packet.rawHex,
        )) {
          _deviceSosController.handleIncomingSosEventPacket(
            packet,
            source: source,
          );
        } else {
          BleDebugRegistry.instance.recordEvent(
            'SOS duplicate suppressed -> ${packet.rawHex}',
          );
        }
      }
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.sosDeviceEvent,
          channel: notification.channel,
          payload: List<int>.unmodifiable(notification.payload),
          payloadHex: notification.payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          sosEventPacket: packet,
          classification: sosEventPacket,
          remoteRelaySosSnapshot: sosEventPacket.remoteRelaySosSnapshot,
        ),
      );
      return;
    }

    var sosClassification = _payloadClassifier.classifySosPayload(
      payload: notification.payload,
      payloadHex: notification.payloadHex,
      receivedAt: notification.receivedAt,
      source: source,
      channel: notification.channel,
      connectedBleTagNodeId: _connectedBleTagNodeId,
      fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
        kind: BleIncomingPayloadKind.unknownOriginSos,
      ),
    );
    sosClassification = await _resolveUnknownOriginSosClassification(
      classification: sosClassification,
      payload: notification.payload,
      payloadHex: notification.payloadHex,
      receivedAt: notification.receivedAt,
      source: source,
      channel: notification.channel,
      reason: 'sos_notify_unknown_origin',
    );
    _logIncomingSosClassifyDecision(
      payload: notification.payload,
      payloadHex: notification.payloadHex,
      classification: sosClassification,
      source: 'ble_device_runtime_provider_sos_notify_post_resolve',
    );
    if (sosClassification.sosPacket != null) {
      final sosPacket = sosClassification.sosPacket!;
      _logSosIdentityDecision(
        originatorNodeId: sosPacket.nodeId,
        connectedBleNodeId: _connectedBleTagNodeId,
        relayNodeId: _connectedBleTagNodeId,
        sourceChannel: notification.channel.name,
        platformEventType: null,
        decision: sosClassification.kind == BleIncomingPayloadKind.ownDeviceSos
            ? 'own_device'
            : sosClassification.kind == BleIncomingPayloadKind.remoteRelaySos
                ? 'remote_relay'
                : 'unknown_hold',
        reason: sosClassification.kind == BleIncomingPayloadKind.ownDeviceSos
            ? 'originator_matches_connected_ble_node'
            : _connectedBleTagNodeId == null
                ? 'connected_ble_node_unknown'
                : 'originator_differs_from_connected_ble_node',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS packet decoded -> role=${sosClassification.kind.name} nodeId=${_formatNodeId(sosPacket.nodeId)} sosType=${sosPacket.sosType} packetId=${sosPacket.packetId} relayCount=${sosPacket.relayCount}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.sosMeshPacket.name,
        outcome: BleIncomingEventType.sosMeshPacket.name,
        receivedAt: notification.receivedAt,
      );
      if (sosClassification.kind == BleIncomingPayloadKind.ownDeviceSos) {
        _handleSosBatteryUpdate(sosPacket);
        if (_shouldProcessSosPacket(
          nodeId: sosPacket.nodeId,
          packetId: sosPacket.packetId,
          rawHex: sosPacket.rawHex,
        )) {
          _deviceSosController.handleIncomingSosPacket(
            sosPacket,
            source: source,
          );
        } else {
          BleDebugRegistry.instance.recordEvent(
            'SOS duplicate suppressed -> ${sosPacket.rawHex}',
          );
        }
      }
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          canonicalHardwareId: _connectedCanonicalHardwareId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.sosMeshPacket,
          channel: notification.channel,
          payload: List<int>.unmodifiable(notification.payload),
          payloadHex: notification.payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          meshPort: notification.meshPort,
          sosPacket: sosPacket,
          classification: sosClassification,
          remoteRelaySosSnapshot: sosClassification.remoteRelaySosSnapshot,
        ),
      );
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      'SOS packet rejected -> len=${notification.payload.length} payload=${notification.payloadHex}',
    );
    BleDebugRegistry.instance.recordDecodedIncomingEvent(
      eventType: BleIncomingEventType.unknownProtocolPacket.name,
      outcome: 'rejected',
      receivedAt: notification.receivedAt,
    );
    _incomingEventsController.add(
      BleIncomingEvent(
        deviceId: deviceId,
        canonicalHardwareId: _connectedCanonicalHardwareId,
        deviceAlias: _connectedDeviceAlias,
        type: BleIncomingEventType.unknownProtocolPacket,
        channel: notification.channel,
        payload: List<int>.unmodifiable(notification.payload),
        payloadHex: notification.payloadHex,
        source: source,
        receivedAt: notification.receivedAt,
        meshPort: notification.meshPort,
      ),
    );
  }

  Future<BleIncomingPayloadClassification?>
      _resolveUnknownOriginSosEventClassification({
    required BleIncomingPayloadClassification? classification,
    required DateTime receivedAt,
    required String reason,
  }) async {
    final packet = classification?.sosEventPacket;
    if (classification == null ||
        packet == null ||
        _connectedBleTagNodeId != null) {
      return classification;
    }

    final resolvedNodeId = await _refreshConnectedBleNodeIdForSosEventPacket(
      packet: packet,
      reason: reason,
    );
    if (resolvedNodeId == null) {
      return classification;
    }

    final isLocalEvent = packet.nodeId == resolvedNodeId;
    final isExternalBackendCancel =
        packet.opcode == EixamBleProtocol.sosEventUserDeactivatedOpcode &&
            packet.subcode == 0x02 &&
            !isLocalEvent;
    final resolved = BleIncomingPayloadClassification(
      kind: packet.isAppCancelAck
          ? BleIncomingPayloadKind.unknown
          : BleIncomingPayloadKind.sosCancel,
      sosEventPacket: packet,
      remoteRelaySosSnapshot: !isExternalBackendCancel
          ? null
          : RemoteRelaySosSnapshot(
              kind: RemoteRelaySosKind.cancel,
              originatorNodeId: packet.nodeId,
              relayNodeId: resolvedNodeId,
              source: RemoteRelaySosSource.sosNotify,
              sosType: 0,
              receivedAt: receivedAt,
              rawPayload: packet.rawBytes,
              payloadHex: packet.rawHex,
              eventOpcode: packet.opcode,
              eventSubcode: packet.subcode,
            ),
    );
    BleDebugRegistry.instance.recordEvent(
      'REMOTE_RELAY_CANCEL_DETECT source=ble_runtime_unknown_origin_resolve '
      'rawType=sos_event nodeId=${packet.nodeId} '
      'originatorNodeId=${packet.nodeId} relayNodeId=$resolvedNodeId '
      'relayHardwareId=${_connectedCanonicalHardwareId ?? "none"} '
      'classifiedAs=${isExternalBackendCancel ? "remoteRelay" : isLocalEvent ? "ownDevice" : "unknown"} '
      'action=${isExternalBackendCancel ? "emit_remote_cancel_snapshot" : isLocalEvent ? "local_terminal" : "non_backend_event"}',
    );
    if (isExternalBackendCancel) {
      BleDebugRegistry.instance.recordEvent(
        'REMOTE_RELAY_CANCEL_DETECT source=ble_sos_event_e1_02 '
        'classifiedAs=remoteRelay '
        'originatorNodeId=${packet.nodeId} '
        'relayNodeId=$resolvedNodeId',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS event unknown origin reclassified -> reason=$reason '
      'connectedNodeId=${_formatNodeId(resolvedNodeId)} '
      'originatorNodeId=${_formatNodeId(packet.nodeId)} '
      'role=${isExternalBackendCancel ? "remoteRelayEvent" : isLocalEvent ? "ownDeviceEvent" : "nonBackendEvent"}',
    );
    return resolved;
  }

  Future<BleIncomingPayloadClassification>
      _resolveUnknownOriginSosClassification({
    required BleIncomingPayloadClassification classification,
    required List<int> payload,
    required String payloadHex,
    required DateTime receivedAt,
    required DeviceSosTransitionSource source,
    required EixamBleChannel channel,
    required String reason,
  }) async {
    final packet = classification.sosPacket;
    if (classification.kind != BleIncomingPayloadKind.unknownOriginSos ||
        packet == null ||
        _connectedBleTagNodeId != null) {
      return classification;
    }

    final resolvedNodeId = await _refreshConnectedBleNodeIdForSosPacket(
      packet: packet,
      reason: reason,
    );
    if (resolvedNodeId == null) {
      final fallback = _payloadClassifier.classifySosPayload(
        payload: payload,
        payloadHex: payloadHex,
        receivedAt: receivedAt,
        source: source,
        channel: channel,
        connectedBleTagNodeId: null,
        fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
          kind: BleIncomingPayloadKind.remoteRelaySos,
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS unknown origin fallback -> reason=$reason '
        'originatorNodeId=${_formatNodeId(packet.nodeId)} '
        'role=${fallback.kind.name}',
      );
      return fallback;
    }

    final resolved = _payloadClassifier.classifySosPayload(
      payload: payload,
      payloadHex: payloadHex,
      receivedAt: receivedAt,
      source: source,
      channel: channel,
      connectedBleTagNodeId: resolvedNodeId,
      fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
        kind: BleIncomingPayloadKind.remoteRelaySos,
      ),
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS unknown origin reclassified -> reason=$reason '
      'connectedNodeId=${_formatNodeId(resolvedNodeId)} '
      'originatorNodeId=${_formatNodeId(packet.nodeId)} '
      'role=${resolved.kind.name}',
    );
    return resolved;
  }

  Future<int?> _refreshConnectedBleNodeIdForSosPacket({
    required EixamSosPacket packet,
    required String reason,
  }) async {
    final existing = _connectedBleTagNodeId;
    if (existing != null) {
      return existing;
    }
    if (_connectedDeviceId == null) {
      return null;
    }

    try {
      final status = await _requestOrAwaitRuntimeStatusForSosIdentity(
        reason: reason,
      );
      _connectedBleTagNodeId = status.nodeId;
      BleDebugRegistry.instance.recordEvent(
        'SOS identity refresh succeeded -> reason=$reason '
        'connectedNodeId=${_formatNodeId(status.nodeId)} '
        'originatorNodeId=${_formatNodeId(packet.nodeId)}',
      );
      return status.nodeId;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'SOS identity refresh failed -> reason=$reason '
        'originatorNodeId=${_formatNodeId(packet.nodeId)} error=$error',
      );
      return null;
    }
  }

  Future<int?> _refreshConnectedBleNodeIdForSosEventPacket({
    required EixamSosEventPacket packet,
    required String reason,
  }) async {
    final existing = _connectedBleTagNodeId;
    if (existing != null) {
      return existing;
    }
    if (_connectedDeviceId == null) {
      return null;
    }

    try {
      final status = await _requestOrAwaitRuntimeStatusForSosIdentity(
        reason: reason,
      );
      _connectedBleTagNodeId = status.nodeId;
      BleDebugRegistry.instance.recordEvent(
        'SOS event identity refresh succeeded -> reason=$reason '
        'connectedNodeId=${_formatNodeId(status.nodeId)} '
        'originatorNodeId=${_formatNodeId(packet.nodeId)}',
      );
      return status.nodeId;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'SOS event identity refresh failed -> reason=$reason '
        'originatorNodeId=${_formatNodeId(packet.nodeId)} error=$error',
      );
      return null;
    }
  }

  Future<DeviceRuntimeStatus> _requestOrAwaitRuntimeStatusForSosIdentity({
    required String reason,
  }) async {
    final pending = _pendingRuntimeStatusRequest;
    if (pending != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS identity refresh awaiting pending runtime status -> reason=$reason',
      );
      return pending.future.timeout(
        const Duration(milliseconds: 1500),
        onTimeout: () => throw const DeviceException(
          _deviceStatusTimeoutCode,
          _deviceStatusTimeoutCode,
        ),
      );
    }
    return requestDeviceRuntimeStatus(
      timeout: const Duration(milliseconds: 1500),
    );
  }

  bool _shouldProcessSosPacket({
    required int nodeId,
    required int? packetId,
    required String rawHex,
  }) {
    final now = DateTime.now();
    _recentSosPacketSignatures.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _recentSosDedupWindow,
    );

    final signature = '$nodeId:${packetId ?? 'na'}:$rawHex';
    final previousSeenAt = _recentSosPacketSignatures[signature];
    if (previousSeenAt != null &&
        now.difference(previousSeenAt) <= _recentSosDedupWindow) {
      return false;
    }

    _recentSosPacketSignatures[signature] = now;
    return true;
  }

  void _logSosIdentityDecision({
    required int originatorNodeId,
    required int? connectedBleNodeId,
    required int? relayNodeId,
    required String sourceChannel,
    required String? platformEventType,
    required String decision,
    required String reason,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'sos_identity_decision '
      'originatorNodeId=${_formatNodeId(originatorNodeId)} '
      'connectedBleNodeId=${connectedBleNodeId == null ? "-" : _formatNodeId(connectedBleNodeId)} '
      'relayNodeId=${relayNodeId == null ? "-" : _formatNodeId(relayNodeId)} '
      'sourceChannel=$sourceChannel '
      'platformEventType=${platformEventType ?? "-"} '
      'decision=$decision '
      'reason=$reason',
    );
  }

  DeviceLifecycleState _resolveLifecycle(
    DeviceStatus currentStatus,
    bool connected,
  ) {
    if (!currentStatus.paired) return DeviceLifecycleState.unpaired;
    if (!currentStatus.activated) return DeviceLifecycleState.paired;
    if (connected) return DeviceLifecycleState.ready;
    return DeviceLifecycleState.activated;
  }

  void _handleTelBatteryUpdate(EixamTelPacket packet) {
    _lastTelBatteryLevel = packet.batteryLevel;
    BleDebugRegistry.instance.recordEvent(
      'Decoded TEL battery -> nodeId=${_formatNodeId(packet.nodeId)} raw=${packet.batteryLevel} state=${DeviceBatteryLevel.fromProtocolValue(packet.batteryLevel)?.label ?? "-"}',
    );
    _publishPacketDerivedBattery(reason: 'tel_packet');
  }

  void _handleSosBatteryUpdate(EixamSosPacket packet) {
    _lastSosBatteryLevel = packet.batteryLevel;
    BleDebugRegistry.instance.recordEvent(
      'Decoded SOS battery -> nodeId=${_formatNodeId(packet.nodeId)} raw=${packet.batteryLevel} state=${DeviceBatteryLevel.fromProtocolValue(packet.batteryLevel)?.label ?? "-"}',
    );
    _publishPacketDerivedBattery(reason: 'sos_packet');
  }

  void _publishPacketDerivedBattery({required String reason}) {
    final currentStatus = _lastRuntimeStatus;
    if (currentStatus == null) {
      BleDebugRegistry.instance.recordEvent(
        'Battery update deferred -> reason=$reason status=uninitialized',
      );
      return;
    }

    final rawBatteryLevel = _effectiveBatteryLevel(currentStatus);
    final batteryState = _effectiveBatteryState(currentStatus);
    final batterySource = _effectiveBatterySource(currentStatus);
    final nextStatus = currentStatus.copyWith(
      batteryLevel: rawBatteryLevel,
      batteryState: batteryState,
      batterySource: batterySource,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );

    final unchanged = currentStatus.batteryLevel == nextStatus.batteryLevel &&
        currentStatus.effectiveBatteryState ==
            nextStatus.effectiveBatteryState &&
        currentStatus.batterySource == nextStatus.batterySource;
    if (unchanged) {
      BleDebugRegistry.instance.recordEvent(
        'Final battery value sent to UI -> source=${batterySource?.name ?? "-"} raw=${rawBatteryLevel?.toString() ?? "-"} state=${batteryState?.label ?? "-"} approx=${batteryState?.approximatePercentage.toString() ?? "-"} changed=false',
      );
      return;
    }

    _publishRuntimeStatus(nextStatus, reason: reason);
  }

  void _publishDeviceRuntimeStatus(DeviceRuntimeStatus runtimeStatus) {
    final currentStatus = _lastRuntimeStatus;
    if (currentStatus == null) {
      return;
    }
    final batteryState = _batteryStateFromPercent(runtimeStatus.batteryPercent);
    final nextStatus = currentStatus.copyWith(
      nodeId: runtimeStatus.nodeId,
      provisioningStatus: _provisioningStatusFromRuntime(runtimeStatus),
      batteryPercent: runtimeStatus.batteryPercent,
      batteryLevel: batteryState?.protocolValue,
      batteryState: batteryState,
      batterySource: runtimeStatus.batteryPercent != null
          ? DeviceBatterySource.deviceStatus
          : DeviceBatterySource.unknown,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );
    final unchanged = currentStatus.nodeId == nextStatus.nodeId &&
        currentStatus.provisioningStatus == nextStatus.provisioningStatus &&
        currentStatus.batteryPercent == nextStatus.batteryPercent &&
        currentStatus.batteryLevel == nextStatus.batteryLevel &&
        currentStatus.batterySource == nextStatus.batterySource;
    if (unchanged) {
      return;
    }
    _publishRuntimeStatus(
      nextStatus,
      reason: 'device_runtime_status_updated',
    );
  }

  DeviceProvisioningStatus _provisioningStatusFromRuntime(
    DeviceRuntimeStatus? runtimeStatus,
  ) {
    if (runtimeStatus == null) {
      return DeviceProvisioningStatus.unknown;
    }
    return runtimeStatus.isProvisioned
        ? DeviceProvisioningStatus.provisioned
        : DeviceProvisioningStatus.unprovisioned;
  }

  int? _effectiveBatteryLevel(DeviceStatus currentStatus) {
    return _lastTelBatteryLevel ??
        _lastSosBatteryLevel ??
        currentStatus.batteryLevel;
  }

  DeviceBatteryLevel? _effectiveBatteryState(DeviceStatus currentStatus) {
    return DeviceBatteryLevel.fromProtocolValue(
          _effectiveBatteryLevel(currentStatus),
        ) ??
        currentStatus.effectiveBatteryState;
  }

  DeviceBatterySource? _effectiveBatterySource(DeviceStatus currentStatus) {
    if (currentStatus.batteryPercent != null) {
      return currentStatus.batterySource ?? DeviceBatterySource.deviceStatus;
    }
    if (_lastTelBatteryLevel != null) {
      return DeviceBatterySource.telPacket;
    }
    if (_lastSosBatteryLevel != null) {
      return DeviceBatterySource.sosPacket;
    }
    return currentStatus.batterySource;
  }

  void _publishRuntimeStatus(DeviceStatus nextStatus,
      {required String reason}) {
    _lastRuntimeStatus = nextStatus;
    BleDebugRegistry.instance.recordEvent(
      'Final battery value sent to UI -> source=${nextStatus.batterySource?.name ?? "-"} exact=${nextStatus.batteryPercent?.toString() ?? "-"} raw=${nextStatus.batteryLevel?.toString() ?? "-"} state=${nextStatus.effectiveBatteryState?.label ?? "-"} displayed=${nextStatus.approximateBatteryPercentage?.toString() ?? "-"} changed=true reason=$reason',
    );
    _runtimeStatusController.add(nextStatus);
  }

  Future<void> _runDeviceCommand({
    required EixamDeviceCommand command,
    required String missingDeviceMessage,
    required EixamSdkException missingDeviceError,
  }) async {
    final deviceId = _connectedDeviceId;
    if (deviceId == null ||
        !await _bleClient.isConnected(deviceId) ||
        (command.usesCmdCharacteristic && !hasCommandChannel)) {
      throw missingDeviceError;
    }

    await _bleClient.writeDeviceCommand(deviceId, command);
  }

  void _validateVolume(int volume) {
    if (volume < 0 || volume > 100) {
      throw const DeviceException(
        'E_DEVICE_INVALID_VOLUME',
        'E_DEVICE_INVALID_VOLUME',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final pendingRuntimeStatusRequest = _pendingRuntimeStatusRequest;
    if (pendingRuntimeStatusRequest != null &&
        !pendingRuntimeStatusRequest.isCompleted) {
      pendingRuntimeStatusRequest.completeError(
        const DeviceException(
          _deviceStatusTimeoutCode,
          _deviceStatusTimeoutCode,
        ),
      );
    }
    _pendingRuntimeStatusRequest = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _runtimeStatusController.close();
    await _incomingEventsController.close();
  }
}

final class _IosReconnectCandidate {
  const _IosReconnectCandidate({
    required this.scan,
    required this.rank,
    required this.reason,
  });

  final BleScanResult scan;
  final int rank;
  final String reason;
}
