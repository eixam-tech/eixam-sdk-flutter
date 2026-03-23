import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

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
import 'eixam_sos_event_packet.dart';
import 'eixam_sos_packet.dart';
import 'eixam_tel_fragment.dart';
import 'eixam_tel_packet.dart';
import 'eixam_tel_reassembler.dart';

class BleDeviceRuntimeProvider implements DeviceRuntimeProvider {
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
  final EixamTelReassembler _telReassembler = EixamTelReassembler();

  String? _connectedDeviceId;
  String? _connectedDeviceAlias;
  StreamSubscription<EixamBleNotification>? _notificationSubscription;
  StreamSubscription<bool>? _connectionStateSubscription;
  DateTime? _lastAppCommandAt;
  DeviceStatus? _lastRuntimeStatus;
  int? _lastTelBatteryLevel;
  int? _lastSosBatteryLevel;
  final Map<String, DateTime> _recentSosPacketSignatures = <String, DateTime>{};

  static const Duration _recentSosDedupWindow = Duration(seconds: 2);

  DeviceSosController get deviceSosController => _deviceSosController;
  Stream<BleIncomingEvent> watchIncomingEvents() =>
      _incomingEventsController.stream;
  @override
  Stream<DeviceStatus> watchRuntimeStatus() => _runtimeStatusController.stream;

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
    return nextStatus;
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

  Future<void> _handleUnexpectedDisconnect(String deviceId) async {
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
  }

  void _handleTelNotification(
    String deviceId,
    EixamBleNotification notification,
  ) {
    BleDebugRegistry.instance.recordEvent(
      'TEL raw payload (ea01) -> ${notification.payloadHex}',
    );

    final isClassicCandidate =
        notification.payload.length == EixamBleProtocol.telPacketLength &&
        notification.payload.first !=
            EixamBleProtocol.telAggregateFragmentOpcode;
    final telPacket = isClassicCandidate
        ? EixamTelPacket.tryParse(notification.payload)
        : null;
    if (telPacket != null) {
      BleDebugRegistry.instance.recordEvent(
        'TEL packet decoded -> nodeId=${_formatNodeId(telPacket.nodeId)} packetId=${telPacket.packetId} batt=${telPacket.batteryLevel} gps=${telPacket.gpsQuality}',
      );
      _handleTelBatteryUpdate(telPacket);
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
        currentStatus.effectiveBatteryState == nextStatus.effectiveBatteryState &&
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

  void _publishRuntimeStatus(DeviceStatus nextStatus, {required String reason}) {
    _lastRuntimeStatus = nextStatus;
    BleDebugRegistry.instance.recordEvent(
      'Final battery value sent to UI -> source=${nextStatus.batterySource?.name ?? "-"} raw=${nextStatus.batteryLevel?.toString() ?? "-"} state=${nextStatus.effectiveBatteryState?.label ?? "-"} approx=${nextStatus.approximateBatteryPercentage?.toString() ?? "-"} changed=true reason=$reason',
    );
    _runtimeStatusController.add(nextStatus);
  }

  Future<void> dispose() async {
    await _connectionStateSubscription?.cancel();
    await _notificationSubscription?.cancel();
    await _runtimeStatusController.close();
    await _incomingEventsController.close();
  }
}
