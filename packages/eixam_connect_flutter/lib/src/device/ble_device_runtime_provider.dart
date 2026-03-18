import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'ble_adapter_state.dart';
import 'ble_client.dart';
import 'ble_scan_result.dart';
import 'device_runtime_provider.dart';

/// BLE-oriented runtime provider that keeps device provisioning logic isolated
/// from repositories and controllers.
///
/// The current implementation is intentionally simple and can run on top of the
/// mock BLE client. Replacing the client with a real BLE adapter should not
/// require changes in the repository or in the public SDK contract.
class BleDeviceRuntimeProvider implements DeviceRuntimeProvider {
  BleDeviceRuntimeProvider({required BleClient bleClient})
      : _bleClient = bleClient;

  final BleClient _bleClient;
  String? _connectedDeviceId;

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

    final candidates = _sortCandidates(scanResults);

    for (final candidate in candidates) {
      try {
        await _bleClient.connect(candidate.deviceId);

        final compatible =
            await _bleClient.isEixamCompatible(candidate.deviceId);
        if (!compatible) {
          await _bleClient.disconnect(candidate.deviceId);
          continue;
        }

        _connectedDeviceId = candidate.deviceId;

        return currentStatus.copyWith(
          deviceId: candidate.deviceId,
          deviceAlias: candidate.name,
          model: 'EIXAM R1',
          paired: true,
          connected: true,
          lifecycleState: DeviceLifecycleState.paired,
          batteryLevel: await _bleClient.readBatteryLevel(candidate.deviceId),
          firmwareVersion:
              await _bleClient.readFirmwareVersion(candidate.deviceId),
          signalQuality:
              await _bleClient.readSignalQuality(candidate.deviceId),
          lastSeen: DateTime.now(),
          lastSyncedAt: DateTime.now(),
          clearProvisioningError: true,
        );
      } catch (_) {
        try {
          await _bleClient.disconnect(candidate.deviceId);
        } catch (_) {}
      }
    }

    throw const DeviceException(
      'E_DEVICE_NOT_FOUND',
      'No compatible EIXAM device was found nearby.',
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

    return currentStatus.copyWith(
      activated: true,
      connected: await _resolveConnection(currentStatus.deviceId),
      lifecycleState: DeviceLifecycleState.ready,
      batteryLevel: await _bleClient.readBatteryLevel(currentStatus.deviceId),
      firmwareVersion:
          await _bleClient.readFirmwareVersion(currentStatus.deviceId),
      signalQuality:
          await _bleClient.readSignalQuality(currentStatus.deviceId),
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
    if (_connectedDeviceId != null) {
      await _bleClient.disconnect(_connectedDeviceId!);
    }
    _connectedDeviceId = null;

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

  List<BleScanResult> _sortCandidates(List<BleScanResult> scanResults) {
    final candidates = scanResults.where((d) => d.connectable).toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return candidates;
  }

  Future<bool> _resolveConnection(String deviceId) async {
    final id = _connectedDeviceId ?? deviceId;
    return _bleClient.isConnected(id);
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
}