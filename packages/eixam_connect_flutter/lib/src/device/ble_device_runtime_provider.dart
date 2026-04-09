import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import '../sdk/guided_rescue_runtime.dart';
import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_connection_status.dart';
import 'ble_debug_registry.dart';
import 'ble_incoming_event.dart';
import 'ble_scan_result.dart';
import 'device_runtime_provider.dart';
import 'device_sos_controller.dart';
import 'eixam_ble_command.dart';
import 'eixam_ble_notification.dart';
import 'eixam_ble_protocol.dart';
import 'eixam_guided_rescue_status_packet.dart';
import 'eixam_sos_event_packet.dart';
import 'eixam_sos_packet.dart';
import 'eixam_tel_fragment.dart';
import 'eixam_tel_packet.dart';
import 'eixam_tel_reassembler.dart';

class BleDeviceRuntimeProvider
    implements DeviceRuntimeProvider, GuidedRescueRuntime {
  BleDeviceRuntimeProvider({
    required BleClient bleClient,
    DeviceSosController? deviceSosController,
  })  : _bleClient = bleClient,
        _deviceSosController = deviceSosController ?? DeviceSosController();

  final BleClient _bleClient;
  final DeviceSosController _deviceSosController;
  final StreamController<BleIncomingEvent> _incomingEventsController =
      StreamController<BleIncomingEvent>.broadcast();
  final StreamController<DeviceStatus> _runtimeStatusController =
      StreamController<DeviceStatus>.broadcast();
  final StreamController<GuidedRescueState> _guidedRescueStateController =
      StreamController<GuidedRescueState>.broadcast();
  final EixamTelReassembler _telReassembler = EixamTelReassembler();

  String? _connectedDeviceId;
  String? _connectedDeviceAlias;
  StreamSubscription<EixamBleNotification>? _notificationSubscription;
  StreamSubscription<bool>? _connectionStateSubscription;
  DateTime? _lastAppCommandAt;
  DeviceStatus? _lastRuntimeStatus;
  GuidedRescueState _guidedRescueState = const GuidedRescueState(
    hasRuntimeSupport: true,
    availableActions: <GuidedRescueAction>{},
    unavailableReason:
        'Configure a guided rescue session before issuing rescue commands.',
  );
  int? _lastTelBatteryLevel;
  int? _lastSosBatteryLevel;
  final Map<String, DateTime> _recentSosPacketSignatures = <String, DateTime>{};
  bool _ownershipSuspended = false;

  static const Duration _recentSosDedupWindow = Duration(seconds: 2);
  static const String _rescueDeviceNotReadyCode = 'E_RESCUE_DEVICE_NOT_READY';

  DeviceSosController get deviceSosController => _deviceSosController;
  Stream<BleIncomingEvent> watchIncomingEvents() =>
      _incomingEventsController.stream;
  @override
  Stream<DeviceStatus> watchRuntimeStatus() => _runtimeStatusController.stream;
  @override
  Stream<GuidedRescueState> watchState() => _guidedRescueStateController.stream;

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
        'Bluetooth must be enabled before pairing.',
      );
    }

    final scanResults = await _bleClient.scan();
    if (scanResults.isEmpty) {
      throw const DeviceException(
        'E_DEVICE_NOT_FOUND',
        'No BLE devices were found nearby.',
      );
    }

    final selectedDeviceId =
        BleDebugRegistry.instance.currentState.selectedDeviceId;
    if (selectedDeviceId == null || selectedDeviceId.isEmpty) {
      throw const DeviceException(
        'E_DEVICE_NOT_SELECTED',
        'Select a BLE device before pairing.',
      );
    }

    final candidate = _findSelectedCandidate(scanResults, selectedDeviceId);
    if (candidate == null) {
      throw const DeviceException(
        'E_DEVICE_NOT_FOUND',
        'Selected BLE device was not found in the latest scan results.',
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
          connectionError:
              'Connected, but required EIXAM service/characteristics were not found.',
        );
        await _bleClient.disconnect(candidate.deviceId);
        throw const DeviceException(
          'E_DEVICE_INCOMPATIBLE',
          'Selected device is not compatible with the EIXAM BLE protocol.',
        );
      }

      _connectedDeviceId = candidate.deviceId;
      _connectedDeviceAlias = candidate.name;
      await _bindNotifications(candidate.deviceId);
      await _bindConnectionMonitor(candidate.deviceId);
      BleDebugRegistry.instance.recordEvent(
        'Pairing succeeded for ${candidate.deviceId}',
      );

      final nextStatus = currentStatus.copyWith(
        deviceId: candidate.deviceId,
        deviceAlias: candidate.name,
        model: 'EIXAM R1',
        paired: true,
        connected: true,
        lifecycleState: DeviceLifecycleState.paired,
        batteryLevel: _effectiveBatteryLevel(currentStatus),
        batteryState: _effectiveBatteryState(currentStatus),
        batterySource: _effectiveBatterySource(currentStatus),
        firmwareVersion: await _bleClient.readFirmwareVersion(
          candidate.deviceId,
        ),
        signalQuality: await _bleClient.readSignalQuality(candidate.deviceId),
        lastSeen: DateTime.now(),
        lastSyncedAt: DateTime.now(),
        clearProvisioningError: true,
      );
      _publishRuntimeStatus(nextStatus, reason: 'pair_completed');
      _publishGuidedRescueState(
        _guidedRescueState.copyWith(
          availableActions: _resolvedGuidedRescueActions(),
          unavailableReason: _resolvedGuidedRescueUnavailableReason(),
          lastUpdatedAt: DateTime.now(),
          clearLastError: true,
        ),
      );
      return nextStatus;
    } catch (error, stackTrace) {
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
      debugPrint(
        'BLE pair failed -> deviceId=${candidate.deviceId} error=$error',
      );
      debugPrintStack(stackTrace: stackTrace);
      try {
        await _bleClient.disconnect(candidate.deviceId);
      } catch (_) {}
      rethrow;
    }
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

  Future<bool> _resolveConnection(String deviceId) async {
    final id = _connectedDeviceId ?? deviceId;
    return _bleClient.isConnected(id);
  }

  Future<void> _bindNotifications(String deviceId) async {
    await _notificationSubscription?.cancel();
    final commandWriter = (EixamDeviceCommand command) {
      _lastAppCommandAt = DateTime.now();
      BleDebugRegistry.instance.recordEvent(
        'BLE app command tracked -> deviceId=$deviceId command=${command.label} payload=${command.encodedHex}',
      );
      return _bleClient.writeDeviceCommand(deviceId, command);
    };
    BleDebugRegistry.instance.registerCommandWriter(commandWriter);
    await _deviceSosController.attach(commandWriter: commandWriter);

    final stream = await _bleClient.subscribeEixamNotifications(deviceId);
    _notificationSubscription = stream.listen(
      (notification) {
        switch (notification.channel) {
          case EixamBleChannel.tel:
            _handleTelNotification(deviceId, notification);
            break;
          case EixamBleChannel.sos:
            _handleSosNotification(deviceId, notification);
            break;
        }
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'Notify subscription error for $deviceId: $error',
        );
      },
    );
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
      lifecycleState: _resolveLifecycle(currentStatus, false),
      lastSyncedAt: DateTime.now(),
      provisioningError: 'Flutter BLE ownership released: $reason',
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
      provisioningError: 'Flutter BLE ownership restored: $reason',
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
      connected: await _resolveConnection(currentStatus.deviceId),
      lifecycleState: DeviceLifecycleState.ready,
      batteryLevel: _effectiveBatteryLevel(currentStatus),
      batteryState: _effectiveBatteryState(currentStatus),
      batterySource: _effectiveBatterySource(currentStatus),
      firmwareVersion: await _bleClient.readFirmwareVersion(
        currentStatus.deviceId,
      ),
      signalQuality: await _bleClient.readSignalQuality(currentStatus.deviceId),
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );
    _publishRuntimeStatus(nextStatus, reason: 'activate_completed');
    _publishGuidedRescueState(
      _guidedRescueState.copyWith(
        availableActions: _resolvedGuidedRescueActions(),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(),
        lastUpdatedAt: DateTime.now(),
        clearLastError: true,
      ),
    );
    return nextStatus;
  }

  @override
  Future<DeviceStatus> refresh(DeviceStatus currentStatus) async {
    if (!currentStatus.paired) return currentStatus;

    final adapterState = await _bleClient.getAdapterState();
    final connected = adapterState == BleAdapterState.poweredOn &&
        await _resolveConnection(currentStatus.deviceId);

    BleDebugRegistry.instance.recordEvent(
      'Refreshed device status for ${currentStatus.deviceId}',
    );
    final nextStatus = currentStatus.copyWith(
      connected: connected,
      batteryLevel: connected
          ? _effectiveBatteryLevel(currentStatus)
          : currentStatus.batteryLevel,
      batteryState: connected
          ? _effectiveBatteryState(currentStatus)
          : currentStatus.effectiveBatteryState,
      batterySource: connected
          ? _effectiveBatterySource(currentStatus)
          : currentStatus.batterySource,
      firmwareVersion: connected
          ? await _bleClient.readFirmwareVersion(currentStatus.deviceId)
          : currentStatus.firmwareVersion,
      signalQuality: connected
          ? await _bleClient.readSignalQuality(currentStatus.deviceId)
          : currentStatus.signalQuality,
      lifecycleState: _resolveLifecycle(currentStatus, connected),
      lastSeen: connected ? DateTime.now() : currentStatus.lastSeen,
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );
    _publishRuntimeStatus(nextStatus, reason: 'refresh_completed');
    _publishGuidedRescueState(
      _guidedRescueState.copyWith(
        availableActions: _resolvedGuidedRescueActions(),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(),
        lastUpdatedAt: DateTime.now(),
      ),
    );
    return nextStatus;
  }

  @override
  Future<DeviceStatus> unpair(DeviceStatus currentStatus) async {
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _deviceSosController.detach();
    if (_connectedDeviceId != null) {
      await _bleClient.disconnect(_connectedDeviceId!);
    }
    _connectedDeviceId = null;
    _connectedDeviceAlias = null;
    _lastAppCommandAt = null;
    _lastTelBatteryLevel = null;
    _lastSosBatteryLevel = null;
    _recentSosPacketSignatures.clear();
    _telReassembler.reset();
    BleDebugRegistry.instance.update(
      connectionStatus: BleConnectionStatus.disconnectedManual,
      connectionError: null,
    );
    BleDebugRegistry.instance.recordEvent('Device unpaired');

    final nextStatus = DeviceStatus(
      deviceId: currentStatus.deviceId,
      deviceAlias: currentStatus.deviceAlias,
      model: currentStatus.model,
      paired: false,
      activated: false,
      connected: false,
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
    _publishGuidedRescueState(
      _guidedRescueState.copyWith(
        availableActions: _resolvedGuidedRescueActions(),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(),
        lastUpdatedAt: DateTime.now(),
      ),
    );
    return nextStatus;
  }

  @override
  Future<GuidedRescueState> getCurrentState() async => _guidedRescueState;

  @override
  Future<GuidedRescueState> setSession({
    required int targetNodeId,
    required int rescueNodeId,
  }) async {
    final nextState = GuidedRescueState(
      hasRuntimeSupport: true,
      targetNodeId: targetNodeId,
      rescueNodeId: rescueNodeId,
      availableActions: _resolvedGuidedRescueActions(
        hasSession: true,
        deviceReady: _isGuidedRescueDeviceReady,
      ),
      unavailableReason: _resolvedGuidedRescueUnavailableReason(
        hasSession: true,
        deviceReady: _isGuidedRescueDeviceReady,
      ),
      lastUpdatedAt: DateTime.now(),
    );
    _publishGuidedRescueState(nextState);
    return nextState;
  }

  @override
  Future<void> clearSession() async {
    _publishGuidedRescueState(
      GuidedRescueState(
        hasRuntimeSupport: true,
        availableActions: _resolvedGuidedRescueActions(
          hasSession: false,
          deviceReady: _isGuidedRescueDeviceReady,
        ),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(
          hasSession: false,
          deviceReady: _isGuidedRescueDeviceReady,
        ),
        lastUpdatedAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> requestPosition() {
    return _runGuidedRescueCommand(
      command: EixamDeviceCommand.guidedRescue(
        targetNodeId: _requireGuidedRescueTargetNodeId(),
        rescueNodeId: _requireGuidedRescueRescueNodeId(),
        commandCode: 0x01,
        label: 'GUIDED RESCUE REQUEST POS',
      ),
    );
  }

  @override
  Future<void> acknowledgeSos() {
    return _runGuidedRescueCommand(
      command: EixamDeviceCommand.guidedRescue(
        targetNodeId: _requireGuidedRescueTargetNodeId(),
        rescueNodeId: _requireGuidedRescueRescueNodeId(),
        commandCode: 0x02,
        label: 'GUIDED RESCUE ACK SOS',
      ),
    );
  }

  @override
  Future<void> enableBuzzer() {
    return _runGuidedRescueCommand(
      command: EixamDeviceCommand.guidedRescue(
        targetNodeId: _requireGuidedRescueTargetNodeId(),
        rescueNodeId: _requireGuidedRescueRescueNodeId(),
        commandCode: 0x03,
        label: 'GUIDED RESCUE BUZZER ON',
      ),
    );
  }

  @override
  Future<void> disableBuzzer() {
    return _runGuidedRescueCommand(
      command: EixamDeviceCommand.guidedRescue(
        targetNodeId: _requireGuidedRescueTargetNodeId(),
        rescueNodeId: _requireGuidedRescueRescueNodeId(),
        commandCode: 0x04,
        label: 'GUIDED RESCUE BUZZER OFF',
      ),
    );
  }

  @override
  Future<void> requestStatus() {
    return _runGuidedRescueCommand(
      command: EixamDeviceCommand.guidedRescue(
        targetNodeId: _requireGuidedRescueTargetNodeId(),
        rescueNodeId: _requireGuidedRescueRescueNodeId(),
        commandCode: 0x05,
        label: 'GUIDED RESCUE STATUS REQ',
      ),
    );
  }

  void _log(String message) {
    debugPrint(message);
  }

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
    final normalized = nodeId & 0xFFFF;
    return '0x${normalized.toRadixString(16).padLeft(4, '0')}';
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
        'Unexpected disconnect ignored because Flutter BLE ownership is suspended',
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
      lifecycleState: _resolveLifecycle(currentStatus, false),
      lastSyncedAt: DateTime.now(),
      provisioningError: 'Unexpected BLE disconnect',
    );
    _publishRuntimeStatus(nextStatus, reason: 'unexpected_disconnect');
    _publishGuidedRescueState(
      _guidedRescueState.copyWith(
        availableActions: _resolvedGuidedRescueActions(),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(),
        lastUpdatedAt: DateTime.now(),
      ),
    );
  }

  void _handleTelNotification(
    String deviceId,
    EixamBleNotification notification,
  ) {
    BleDebugRegistry.instance.recordIncomingNotification(
      channel: notification.channel.name,
      characteristic: _characteristicLabelForChannel(notification.channel),
      payloadHex: notification.payloadHex,
      receivedAt: notification.receivedAt,
    );
    BleDebugRegistry.instance.recordEvent(
      'TEL raw payload (ea01) -> ${notification.payloadHex}',
    );

    final isClassicCandidate =
        notification.payload.length == EixamBleProtocol.telPacketLength &&
            notification.payload.first !=
                EixamBleProtocol.telAggregateFragmentOpcode;
    final rescueStatusPacket = isClassicCandidate
        ? EixamGuidedRescueStatusPacket.tryParse(
            notification.payload,
            receivedAt: notification.receivedAt,
          )
        : null;
    if (rescueStatusPacket != null) {
      BleDebugRegistry.instance.recordEvent(
        'Guided rescue status decoded -> rescueId=${_formatNodeId(rescueStatusPacket.rescueNodeId)} victimId=${_formatNodeId(rescueStatusPacket.victimNodeId)} state=${rescueStatusPacket.targetState.name}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.guidedRescueStatus.name,
        outcome: BleIncomingEventType.guidedRescueStatus.name,
        receivedAt: notification.receivedAt,
      );
      _handleGuidedRescueStatusPacket(rescueStatusPacket);
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.guidedRescueStatus,
          channel: notification.channel,
          payload: List<int>.unmodifiable(notification.payload),
          payloadHex: notification.payloadHex,
          source: DeviceSosTransitionSource.device,
          receivedAt: notification.receivedAt,
          guidedRescueStatusPacket: rescueStatusPacket,
        ),
      );
      return;
    }
    final telPacket = isClassicCandidate
        ? EixamTelPacket.tryParse(notification.payload)
        : null;
    if (telPacket != null) {
      BleDebugRegistry.instance.recordEvent(
        'TEL packet decoded -> nodeId=${_formatNodeId(telPacket.nodeId)} packetId=${telPacket.packetId} batt=${telPacket.batteryLevel} gps=${telPacket.gpsQuality}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.telPosition.name,
        outcome: BleIncomingEventType.telPosition.name,
        receivedAt: notification.receivedAt,
      );
      _handleTelBatteryUpdate(telPacket);
      _handleGuidedRescueTelPacket(telPacket, notification.receivedAt);
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.telPosition,
          channel: notification.channel,
          payload: List<int>.unmodifiable(notification.payload),
          payloadHex: notification.payloadHex,
          source: DeviceSosTransitionSource.device,
          receivedAt: notification.receivedAt,
          telPacket: telPacket,
        ),
      );
      return;
    }

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
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.telAggregateFragment,
          channel: notification.channel,
          payload: List<int>.unmodifiable(notification.payload),
          payloadHex: notification.payloadHex,
          source: DeviceSosTransitionSource.device,
          receivedAt: notification.receivedAt,
          telFragment: telFragment,
        ),
      );

      final completedPayload = _telReassembler.addFragment(telFragment);
      if (completedPayload != null) {
        BleDebugRegistry.instance.recordEvent(
          'TEL aggregate completed -> totalLen=${completedPayload.length}',
        );
        BleDebugRegistry.instance.recordDecodedIncomingEvent(
          eventType: BleIncomingEventType.telAggregateComplete.name,
          outcome: BleIncomingEventType.telAggregateComplete.name,
          receivedAt: notification.receivedAt,
        );
        _incomingEventsController.add(
          BleIncomingEvent(
            deviceId: deviceId,
            deviceAlias: _connectedDeviceAlias,
            type: BleIncomingEventType.telAggregateComplete,
            channel: notification.channel,
            payload: List<int>.unmodifiable(notification.payload),
            payloadHex: notification.payloadHex,
            source: DeviceSosTransitionSource.device,
            receivedAt: notification.receivedAt,
            telFragment: telFragment,
            aggregatePayload: completedPayload,
          ),
        );
      }
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      'TEL packet rejected -> len=${notification.payload.length} payload=${notification.payloadHex}',
    );
    BleDebugRegistry.instance.recordDecodedIncomingEvent(
      eventType: BleIncomingEventType.unknownProtocolPacket.name,
      outcome: 'rejected',
      receivedAt: notification.receivedAt,
    );
    _incomingEventsController.add(
      BleIncomingEvent(
        deviceId: deviceId,
        deviceAlias: _connectedDeviceAlias,
        type: BleIncomingEventType.unknownProtocolPacket,
        channel: notification.channel,
        payload: List<int>.unmodifiable(notification.payload),
        payloadHex: notification.payloadHex,
        source: DeviceSosTransitionSource.device,
        receivedAt: notification.receivedAt,
      ),
    );
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

  void _handleSosNotification(
    String deviceId,
    EixamBleNotification notification,
  ) {
    final source = _inferPacketSource();
    BleDebugRegistry.instance.recordIncomingNotification(
      channel: notification.channel.name,
      characteristic: _characteristicLabelForChannel(notification.channel),
      payloadHex: notification.payloadHex,
      receivedAt: notification.receivedAt,
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS raw payload (ea02) -> ${notification.payloadHex}',
    );

    final sosEventPacket = notification.payload.length == 4
        ? EixamSosEventPacket.tryParse(notification.payload)
        : null;
    if (sosEventPacket != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS device event decoded -> nodeId=${_formatNodeId(sosEventPacket.nodeId)} opcode=0x${sosEventPacket.opcode.toRadixString(16).padLeft(2, '0')} subcode=0x${sosEventPacket.subcode.toRadixString(16).padLeft(2, '0')}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.sosDeviceEvent.name,
        outcome: BleIncomingEventType.sosDeviceEvent.name,
        receivedAt: notification.receivedAt,
      );
      if (_shouldProcessSosPacket(
        nodeId: sosEventPacket.nodeId,
        packetId: null,
        rawHex: sosEventPacket.rawHex,
      )) {
        _deviceSosController.handleIncomingSosEventPacket(
          sosEventPacket,
          source: source,
        );
      } else {
        BleDebugRegistry.instance.recordEvent(
          'SOS duplicate suppressed -> ${sosEventPacket.rawHex}',
        );
      }
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.sosDeviceEvent,
          channel: notification.channel,
          payload: List<int>.unmodifiable(notification.payload),
          payloadHex: notification.payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          sosEventPacket: sosEventPacket,
        ),
      );
      return;
    }

    final sosPacket = EixamSosPacket.tryParse(notification.payload);
    if (sosPacket != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS packet decoded -> nodeId=${_formatNodeId(sosPacket.nodeId)} sosType=${sosPacket.sosType} packetId=${sosPacket.packetId} relayCount=${sosPacket.relayCount}',
      );
      BleDebugRegistry.instance.recordDecodedIncomingEvent(
        eventType: BleIncomingEventType.sosMeshPacket.name,
        outcome: BleIncomingEventType.sosMeshPacket.name,
        receivedAt: notification.receivedAt,
      );
      _handleSosBatteryUpdate(sosPacket);
      _handleGuidedRescueSosPacket(sosPacket, notification.receivedAt);
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
      _incomingEventsController.add(
        BleIncomingEvent(
          deviceId: deviceId,
          deviceAlias: _connectedDeviceAlias,
          type: BleIncomingEventType.sosMeshPacket,
          channel: notification.channel,
          payload: List<int>.unmodifiable(notification.payload),
          payloadHex: notification.payloadHex,
          source: source,
          receivedAt: notification.receivedAt,
          sosPacket: sosPacket,
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
        deviceAlias: _connectedDeviceAlias,
        type: BleIncomingEventType.unknownProtocolPacket,
        channel: notification.channel,
        payload: List<int>.unmodifiable(notification.payload),
        payloadHex: notification.payloadHex,
        source: source,
        receivedAt: notification.receivedAt,
      ),
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
      'Final battery value sent to UI -> source=${nextStatus.batterySource?.name ?? "-"} raw=${nextStatus.batteryLevel?.toString() ?? "-"} state=${nextStatus.effectiveBatteryState?.label ?? "-"} approx=${nextStatus.approximateBatteryPercentage?.toString() ?? "-"} changed=true reason=$reason',
    );
    _runtimeStatusController.add(nextStatus);
  }

  bool get _isGuidedRescueDeviceReady =>
      _connectedDeviceId != null && (_lastRuntimeStatus?.connected ?? true);

  Set<GuidedRescueAction> _resolvedGuidedRescueActions({
    bool? hasSession,
    bool? deviceReady,
  }) {
    final effectiveHasSession = hasSession ?? _guidedRescueState.hasSession;
    final effectiveDeviceReady = deviceReady ??
        (_connectedDeviceId != null && _isGuidedRescueDeviceReady);
    if (!effectiveHasSession || !effectiveDeviceReady) {
      return const <GuidedRescueAction>{};
    }
    return const <GuidedRescueAction>{
      GuidedRescueAction.requestPosition,
      GuidedRescueAction.acknowledgeSos,
      GuidedRescueAction.buzzerOn,
      GuidedRescueAction.buzzerOff,
      GuidedRescueAction.requestStatus,
    };
  }

  String? _resolvedGuidedRescueUnavailableReason({
    bool? hasSession,
    bool? deviceReady,
  }) {
    final effectiveHasSession = hasSession ?? _guidedRescueState.hasSession;
    final effectiveDeviceReady = deviceReady ?? _isGuidedRescueDeviceReady;
    if (!effectiveHasSession) {
      return 'Configure a guided rescue session before issuing rescue commands.';
    }
    if (!effectiveDeviceReady) {
      return 'Connect a compatible EIXAM device before issuing guided rescue commands.';
    }
    return null;
  }

  int _requireGuidedRescueTargetNodeId() {
    final targetNodeId = _guidedRescueState.targetNodeId;
    if (targetNodeId == null) {
      throw const RescueException.missingSession();
    }
    return targetNodeId;
  }

  int _requireGuidedRescueRescueNodeId() {
    final rescueNodeId = _guidedRescueState.rescueNodeId;
    if (rescueNodeId == null) {
      throw const RescueException.missingSession();
    }
    return rescueNodeId;
  }

  Future<void> _runGuidedRescueCommand({
    required EixamDeviceCommand command,
  }) async {
    final deviceId = _connectedDeviceId;
    if (deviceId == null || !await _bleClient.isConnected(deviceId)) {
      final message =
          'A compatible connected device is required before issuing guided rescue commands.';
      _publishGuidedRescueState(
        _guidedRescueState.copyWith(
          availableActions: _resolvedGuidedRescueActions(
            deviceReady: false,
          ),
          unavailableReason: _resolvedGuidedRescueUnavailableReason(
            deviceReady: false,
          ),
          lastError: message,
          lastUpdatedAt: DateTime.now(),
        ),
      );
      throw const RescueException(
        _rescueDeviceNotReadyCode,
        'A compatible connected device is required before issuing guided rescue commands.',
      );
    }

    await _bleClient.writeDeviceCommand(deviceId, command);
    _publishGuidedRescueState(
      _guidedRescueState.copyWith(
        availableActions: _resolvedGuidedRescueActions(deviceReady: true),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(
          deviceReady: true,
        ),
        lastUpdatedAt: DateTime.now(),
        clearLastError: true,
      ),
    );
  }

  void _handleGuidedRescueStatusPacket(EixamGuidedRescueStatusPacket packet) {
    if (!_matchesGuidedRescueSession(
      targetNodeId: packet.victimNodeId,
      rescueNodeId: packet.rescueNodeId,
    )) {
      return;
    }

    _publishGuidedRescueState(
      _guidedRescueState.copyWith(
        availableActions: _resolvedGuidedRescueActions(),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(),
        lastStatusSnapshot: packet.toSnapshot(),
        lastUpdatedAt: packet.receivedAt,
        clearLastError: true,
      ),
    );
  }

  void _handleGuidedRescueTelPacket(
    EixamTelPacket packet,
    DateTime receivedAt,
  ) {
    if (!_matchesGuidedRescueSession(targetNodeId: packet.nodeId)) {
      return;
    }

    _publishGuidedRescueState(
      _guidedRescueState.copyWith(
        availableActions: _resolvedGuidedRescueActions(),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(),
        lastKnownTargetPosition: TrackingPosition(
          latitude: packet.position.latitude,
          longitude: packet.position.longitude,
          altitude: packet.position.altitudeMeters.toDouble(),
          timestamp: receivedAt,
          source: DeliveryMode.mesh,
        ),
        lastUpdatedAt: receivedAt,
        clearLastError: true,
      ),
    );
  }

  void _handleGuidedRescueSosPacket(
    EixamSosPacket packet,
    DateTime receivedAt,
  ) {
    if (!_matchesGuidedRescueSession(targetNodeId: packet.nodeId) ||
        packet.position == null) {
      return;
    }

    _publishGuidedRescueState(
      _guidedRescueState.copyWith(
        availableActions: _resolvedGuidedRescueActions(),
        unavailableReason: _resolvedGuidedRescueUnavailableReason(),
        lastKnownTargetPosition: TrackingPosition(
          latitude: packet.position!.latitude,
          longitude: packet.position!.longitude,
          altitude: packet.position!.altitudeMeters.toDouble(),
          timestamp: receivedAt,
          source: DeliveryMode.mesh,
        ),
        lastUpdatedAt: receivedAt,
        clearLastError: true,
      ),
    );
  }

  bool _matchesGuidedRescueSession({
    required int targetNodeId,
    int? rescueNodeId,
  }) {
    if (!_guidedRescueState.hasSession) {
      return false;
    }
    if (_guidedRescueState.targetNodeId != targetNodeId) {
      return false;
    }
    if (rescueNodeId != null &&
        _guidedRescueState.rescueNodeId != rescueNodeId) {
      return false;
    }
    return true;
  }

  void _publishGuidedRescueState(GuidedRescueState nextState) {
    _guidedRescueState = nextState;
    _guidedRescueStateController.add(nextState);
  }

  Future<void> dispose() async {
    await _connectionStateSubscription?.cancel();
    await _notificationSubscription?.cancel();
    await _runtimeStatusController.close();
    await _incomingEventsController.close();
    await _guidedRescueStateController.close();
  }
}
