import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_connection_status.dart';
import 'ble_debug_registry.dart';
import 'ble_incoming_event.dart';
import 'ble_scan_result.dart';
import 'device_sos_controller.dart';
import 'device_runtime_provider.dart';

/// BLE-oriented runtime provider that keeps device provisioning logic isolated
/// from repositories and controllers.
///
/// The current implementation is intentionally simple and can run on top of the
/// mock BLE client. Replacing the client with a real BLE adapter should not
/// require changes in the repository or in the public SDK contract.
class BleDeviceRuntimeProvider implements DeviceRuntimeProvider {
  BleDeviceRuntimeProvider({
    required BleClient bleClient,
    DeviceSosController? deviceSosController,
  })  : _bleClient = bleClient,
        _deviceSosController = deviceSosController ?? DeviceSosController();

  final BleClient _bleClient;
  String? _connectedDeviceId;
  String? _connectedDeviceAlias;
  final DeviceSosController _deviceSosController;
  StreamSubscription<List<int>>? _notificationSubscription;
  final StreamController<BleIncomingEvent> _incomingEventsController =
      StreamController<BleIncomingEvent>.broadcast();
  DateTime? _lastAppCommandAt;

  DeviceSosController get deviceSosController => _deviceSosController;
  Stream<BleIncomingEvent> watchIncomingEvents() =>
      _incomingEventsController.stream;

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

      BleDebugRegistry.instance.recordEvent(
        'Discover services succeeded for ${candidate.deviceId}',
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
      BleDebugRegistry.instance.recordEvent(
        'Pairing succeeded for ${candidate.deviceId}',
      );

      return currentStatus.copyWith(
        deviceId: candidate.deviceId,
        deviceAlias: candidate.name,
        model: 'EIXAM R1',
        paired: true,
        connected: true,
        lifecycleState: DeviceLifecycleState.paired,
        batteryLevel: await _bleClient.readBatteryLevel(candidate.deviceId),
        firmwareVersion: await _bleClient.readFirmwareVersion(
          candidate.deviceId,
        ),
        signalQuality: await _bleClient.readSignalQuality(candidate.deviceId),
        lastSeen: DateTime.now(),
        lastSyncedAt: DateTime.now(),
        clearProvisioningError: true,
      );
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

  List<BleScanResult> _sortCandidates(List<BleScanResult> scanResults) {
    final candidates = scanResults.where((d) => d.connectable).toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return candidates;
  }

  Future<bool> _resolveConnection(String deviceId) async {
    final id = _connectedDeviceId ?? deviceId;
    return _bleClient.isConnected(id);
  }

  Future<void> _bindNotifications(String deviceId) async {
    await _notificationSubscription?.cancel();
    final commandWriter = (List<int> data) {
      _lastAppCommandAt = DateTime.now();
      BleDebugRegistry.instance.recordEvent(
        'BLE app command tracked -> deviceId=$deviceId payload=${_hex(data)}',
      );
      return _bleClient.writeCommand(deviceId, data);
    };
    BleDebugRegistry.instance.registerCommandWriter(commandWriter);
    final stream = await _bleClient.subscribeNotifications(deviceId);
    _notificationSubscription = stream.listen(
      (packet) {
        final payloadHex = _hex(packet);
        final source = _inferPacketSource();
        final eventType = _eventTypeFor(packet);
        _log(
          'BLE runtime packet -> deviceId=$deviceId type=$eventType source=${source.name} bytes=${packet.length} payload=$payloadHex',
        );
        BleDebugRegistry.instance.recordEvent(
          'BLE incoming event -> deviceId=$deviceId type=$eventType source=${source.name} payload=$payloadHex',
        );
        _incomingEventsController.add(
          BleIncomingEvent(
            deviceId: deviceId,
            deviceAlias: _connectedDeviceAlias,
            eventType: eventType,
            payload: List<int>.unmodifiable(packet),
            payloadHex: payloadHex,
            source: source,
            receivedAt: DateTime.now(),
          ),
        );
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'Notify subscription error for $deviceId: $error',
        );
      },
    );
    final sosStream = await _bleClient.subscribeSosNotifications(deviceId);
    await _deviceSosController.attach(
      notifications: sosStream,
      commandWriter: commandWriter,
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
    return currentStatus.copyWith(
      activated: true,
      connected: await _resolveConnection(currentStatus.deviceId),
      lifecycleState: DeviceLifecycleState.ready,
      batteryLevel: await _bleClient.readBatteryLevel(currentStatus.deviceId),
      firmwareVersion: await _bleClient.readFirmwareVersion(
        currentStatus.deviceId,
      ),
      signalQuality: await _bleClient.readSignalQuality(currentStatus.deviceId),
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      clearProvisioningError: true,
    );
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
    return currentStatus.copyWith(
      connected: connected,
      batteryLevel: connected
          ? await _bleClient.readBatteryLevel(currentStatus.deviceId)
          : currentStatus.batteryLevel,
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
  }

  @override
  Future<DeviceStatus> unpair(DeviceStatus currentStatus) async {
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    await _deviceSosController.detach();
    if (_connectedDeviceId != null) {
      await _bleClient.disconnect(_connectedDeviceId!);
    }
    _connectedDeviceId = null;
    _connectedDeviceAlias = null;
    _lastAppCommandAt = null;
    BleDebugRegistry.instance.recordEvent('Device unpaired');

    return currentStatus.copyWith(
      paired: false,
      activated: false,
      connected: false,
      lifecycleState: DeviceLifecycleState.unpaired,
      provisioningError: null,
      lastSeen: DateTime.now(),
      lastSyncedAt: DateTime.now(),
      signalQuality: null,
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

  String _eventTypeFor(List<int> packet) {
    if (packet.length == 10) {
      return 'sos_packet';
    }
    return 'notify_packet';
  }

  String _hex(List<int> data) {
    return data.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
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

  Future<void> dispose() async {
    await _notificationSubscription?.cancel();
    await _incomingEventsController.close();
  }
}
