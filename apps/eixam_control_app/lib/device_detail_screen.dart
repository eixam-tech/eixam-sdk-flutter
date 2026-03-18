import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/material.dart';

class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({
    super.key,
    required this.sdk,
  });

  final EixamConnectSdk sdk;

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  DeviceStatus? _deviceStatus;
  PermissionState? _permissionState;
  BleDebugState _bleDebugState = BleDebugRegistry.instance.currentState;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<BleDebugState>? _bleDebugSub;
  bool _loadingDevice = false;
  bool _loadingScan = false;
  bool _loadingPermissions = false;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _bindStreams();
    _loadInitialState();
  }

  void _bindStreams() {
    _deviceStatusSub = widget.sdk.watchDeviceStatus().listen(
      (status) {
        if (!mounted) return;
        setState(() {
          _deviceStatus = status;
        });
      },
      onError: _handleError,
    );

    _bleDebugSub = BleDebugRegistry.instance.watch().listen(
      (state) {
        if (!mounted) return;
        setState(() {
          _bleDebugState = state;
        });
      },
    );
  }

  Future<void> _loadInitialState() async {
    try {
      final status = await widget.sdk.getDeviceStatus();
      final permissionState = await widget.sdk.getPermissionState();
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
        _permissionState = permissionState;
      });
    } catch (error) {
      _handleError(error);
    }
  }

  void _handleError(Object error) {
    if (!mounted) return;
    setState(() {
      _lastError = error.toString();
    });
  }

  Future<void> _runDeviceAction(Future<void> Function() action) async {
    setState(() {
      _loadingDevice = true;
      _lastError = null;
    });

    try {
      await action();
      final status = await widget.sdk.getDeviceStatus();
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
      });
    } catch (error) {
      _handleError(error);
    } finally {
      if (mounted) {
        setState(() {
          _loadingDevice = false;
        });
      }
    }
  }

  Future<void> _pairDevice() {
    return _runDeviceAction(() async {
      await _ensureScanPrerequisites(requestIfMissing: true);
      await widget.sdk.pairDevice(pairingCode: 'DEMO-PAIR-001');
    });
  }

  Future<void> _pairSelectedDevice(BleScanResult scan) async {
    BleDebugRegistry.instance.selectDevice(scan.deviceId);
    await _pairDevice();
  }

  Future<void> _activateDevice() {
    return _runDeviceAction(() async {
      await widget.sdk.activateDevice(activationCode: 'DEMO-ACT-001');
    });
  }

  Future<void> _refreshDevice() {
    return _runDeviceAction(() async {
      await widget.sdk.refreshDeviceStatus();
    });
  }

  Future<void> _unpairDevice() {
    return _runDeviceAction(() async {
      await widget.sdk.unpairDevice();
    });
  }

  Future<void> _sendBleCommand(List<int> data) async {
    setState(() {
      _lastError = null;
    });

    try {
      await BleDebugRegistry.instance.sendCommand(data);
    } catch (error) {
      _handleError(error);
    }
  }

  Future<bool> _ensureScanPrerequisites({
    required bool requestIfMissing,
  }) async {
    var state = await widget.sdk.getPermissionState();
    if (requestIfMissing && !state.hasBluetoothAccess) {
      state = await widget.sdk.requestBluetoothPermission();
    }
    if (requestIfMissing &&
        !state.hasLocationAccess &&
        state.location != SdkPermissionStatus.serviceDisabled) {
      state = await widget.sdk.requestLocationPermission();
    }
    if (!mounted) return false;
    setState(() {
      _permissionState = state;
    });
    return state.hasBluetoothAccess && state.bluetoothEnabled;
  }

  Future<void> _requestScanPermissions() async {
    setState(() {
      _loadingPermissions = true;
      _lastError = null;
    });
    try {
      await _ensureScanPrerequisites(requestIfMissing: true);
    } catch (error) {
      _handleError(error);
    } finally {
      if (mounted) {
        setState(() {
          _loadingPermissions = false;
        });
      }
    }
  }

  Future<void> _runScan() async {
    setState(() {
      _loadingScan = true;
      _lastError = null;
    });
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
      if (mounted) {
        setState(() {
          _loadingScan = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _deviceStatusSub?.cancel();
    _bleDebugSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _deviceStatus;
    final deviceName = status?.deviceAlias ?? status?.model ?? 'EIXAM device';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Detail'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DeviceHeader(
              deviceName: deviceName,
              statusLabel: _statusLabel(status),
              model: status?.model ?? '-',
              deviceId: status?.deviceId ?? '-',
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'Lifecycle',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _StepChip(
                          label: 'Paired', active: status?.paired ?? false),
                      _StepChip(
                        label: 'Connected',
                        active: status?.connected ?? false,
                      ),
                      _StepChip(
                        label: 'Activated',
                        active: status?.activated ?? false,
                      ),
                      _StepChip(
                        label: 'Ready',
                        active: status?.isReadyForSafety ?? false,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InfoLine(
                    label: 'Lifecycle state',
                    value: status?.lifecycleState.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Provisioning error',
                    value: status?.provisioningError ?? '-',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'Device Health',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoLine(
                    label: 'Battery',
                    value: status?.batteryLevel?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Signal',
                    value: status?.signalQuality?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Firmware',
                    value: status?.firmwareVersion ?? '-',
                  ),
                  _InfoLine(
                    label: 'Last seen',
                    value: _formatDate(status?.lastSeen),
                  ),
                  _InfoLine(
                    label: 'Last sync',
                    value: _formatDate(status?.lastSyncedAt),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'BLE Discovery',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoLine(
                    label: 'Bluetooth permission',
                    value: _permissionState?.bluetooth.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Bluetooth enabled',
                    value: _permissionState?.bluetoothEnabled.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Location permission',
                    value: _permissionState?.location.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Adapter state',
                    value: _bleDebugState.adapterState.toString(),
                  ),
                  _InfoLine(
                    label: 'Scanning',
                    value: _bleDebugState.isScanning.toString(),
                  ),
                  _InfoLine(
                    label: 'Connection status',
                    value: _bleDebugState.connectionStatus.name,
                  ),
                  _InfoLine(
                    label: 'Connection error',
                    value: _bleDebugState.connectionError ?? '-',
                  ),
                  if (_bleDebugState.connectionError != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.25),
                        ),
                      ),
                      child: SelectableText(
                        _bleDebugState.connectionError!,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(
                        onPressed: _loadingPermissions
                            ? null
                            : _requestScanPermissions,
                        child: const Text('Request BLE perms'),
                      ),
                      ElevatedButton(
                        onPressed: _loadingScan ? null : _runScan,
                        child: const Text('Scan BLE'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_bleDebugState.scanResults.isEmpty)
                    const Text('No BLE devices discovered yet.')
                  else
                    Column(
                      children: _bleDebugState.scanResults.map((scan) {
                        final title = scan.name.isEmpty ? 'Unknown' : scan.name;
                        final services = scan.advertisedServiceUuids.isEmpty
                            ? '-'
                            : scan.advertisedServiceUuids.join(', ');
                        final isSelected =
                            _bleDebugState.selectedDeviceId == scan.deviceId;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Material(
                            color: isSelected
                                ? Colors.blue.withValues(alpha: 0.06)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: _loadingDevice || !scan.connectable
                                  ? null
                                  : () => _pairSelectedDevice(scan),
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: isSelected
                                        ? Colors.blue
                                        : Colors.black.withValues(alpha: 0.12),
                                  ),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            title,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        if (isSelected)
                                          const Chip(
                                            label: Text('Selected'),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text('id: ${scan.deviceId}'),
                                    Text('rssi: ${scan.rssi}'),
                                    Text('connectable: ${scan.connectable}'),
                                    Text('advertised services: $services'),
                                    const SizedBox(height: 8),
                                    Text(
                                      scan.connectable
                                          ? 'Tap to connect and pair this device'
                                          : 'Device is not connectable',
                                      style: const TextStyle(
                                        color: Colors.black54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(growable: false),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'Actions',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: _loadingDevice ? null : _pairDevice,
                    child: const Text('Pair'),
                  ),
                  ElevatedButton(
                    onPressed: _loadingDevice ? null : _activateDevice,
                    child: const Text('Activate'),
                  ),
                  ElevatedButton(
                    onPressed: _loadingDevice ? null : _refreshDevice,
                    child: const Text('Refresh'),
                  ),
                  ElevatedButton(
                    onPressed: _loadingDevice ? null : _unpairDevice,
                    child: const Text('Unpair'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'BLE Debug',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoLine(
                    label: 'Adapter state',
                    value: _bleDebugState.adapterState.toString(),
                  ),
                  _InfoLine(
                    label: 'Selected device id',
                    value: _bleDebugState.selectedDeviceId ?? '-',
                  ),
                  _InfoLine(
                    label: 'Connection status',
                    value: _bleDebugState.connectionStatus.name,
                  ),
                  _InfoLine(
                    label: 'Connection error',
                    value: _bleDebugState.connectionError ?? '-',
                  ),
                  if (_bleDebugState.connectionError != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.25),
                        ),
                      ),
                      child: SelectableText(
                        _bleDebugState.connectionError!,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ],
                  _InfoLine(
                    label: 'EIXAM service found',
                    value: _bleDebugState.eixamServiceFound.toString(),
                  ),
                  _InfoLine(
                    label: 'TEL found',
                    value: _bleDebugState.telFound.toString(),
                  ),
                  _InfoLine(
                    label: 'SOS found',
                    value: _bleDebugState.sosFound.toString(),
                  ),
                  _InfoLine(
                    label: 'INET found',
                    value: _bleDebugState.inetFound.toString(),
                  ),
                  _InfoLine(
                    label: 'CMD found',
                    value: _bleDebugState.cmdFound.toString(),
                  ),
                  if (_bleDebugState.eixamServiceFound &&
                      _bleDebugState.telFound &&
                      _bleDebugState.sosFound &&
                      _bleDebugState.inetFound &&
                      !_bleDebugState.cmdFound) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Text(
                        'Connected to EIXAM device, but CMD characteristic (ea04) is missing. Advanced commands may be unavailable.',
                      ),
                    ),
                  ],
                  _InfoLine(
                    label: 'TEL notify subscribed',
                    value: _bleDebugState.telNotifySubscribed.toString(),
                  ),
                  _InfoLine(
                    label: 'SOS notify subscribed',
                    value: _bleDebugState.sosNotifySubscribed.toString(),
                  ),
                  _InfoLine(
                    label: 'Command channel ready',
                    value: _bleDebugState.commandWriterReady.toString(),
                  ),
                  _InfoLine(
                    label: 'Last command sent',
                    value: _bleDebugState.lastCommandSent ?? '-',
                  ),
                  _InfoLine(
                    label: 'Last packet received',
                    value: _bleDebugState.lastPacketReceived ?? '-',
                  ),
                  _InfoLine(
                    label: 'Discovered services',
                    value: _bleDebugState.discoveredServices.isEmpty
                        ? '-'
                        : _bleDebugState.discoveredServices.join(', '),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _bleDebugState.commandWriterReady
                            ? () => _sendBleCommand(const [0x01])
                            : null,
                        child: const Text('INET OK'),
                      ),
                      OutlinedButton(
                        onPressed: _bleDebugState.commandWriterReady
                            ? () => _sendBleCommand(const [0x02])
                            : null,
                        child: const Text('INET LOST'),
                      ),
                      OutlinedButton(
                        onPressed: _bleDebugState.commandWriterReady
                            ? () => _sendBleCommand(const [0x06])
                            : null,
                        child: const Text('SOS Trigger'),
                      ),
                      OutlinedButton(
                        onPressed: _bleDebugState.commandWriterReady
                            ? () => _sendBleCommand(const [0x04])
                            : null,
                        child: const Text('SOS Cancel'),
                      ),
                      OutlinedButton(
                        onPressed: _bleDebugState.commandWriterReady
                            ? () => _sendBleCommand(const [0x10])
                            : null,
                        child: const Text('Shutdown'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'Live Events',
              child: _bleDebugState.events.isEmpty
                  ? const Text('No BLE events yet.')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children:
                          _bleDebugState.events.reversed.take(10).map((event) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '${_formatDate(event.timestamp)}  ${event.message}',
                          ),
                        );
                      }).toList(growable: false),
                    ),
            ),
            if (_lastError != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.red.withValues(alpha: 0.3),
                  ),
                ),
                child: SelectableText('Last error:\n\n$_lastError'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusLabel(DeviceStatus? status) {
    if (status == null) return 'Disconnected';
    if (status.isReadyForSafety) return 'Ready';
    if (status.connected) return 'Connected';
    if (status.paired) return 'Paired';
    return 'Disconnected';
  }

  String _formatDate(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }
}

class _DeviceHeader extends StatelessWidget {
  const _DeviceHeader({
    required this.deviceName,
    required this.statusLabel,
    required this.model,
    required this.deviceId,
  });

  final String deviceName;
  final String statusLabel;
  final String model;
  final String deviceId;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              deviceName,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(label: Text(statusLabel)),
                Text('Model: $model'),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText('Device ID: $deviceId'),
          ],
        ),
      ),
    );
  }
}

class _CardSection extends StatelessWidget {
  const _CardSection({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _StepChip extends StatelessWidget {
  const _StepChip({
    required this.label,
    required this.active,
  });

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        active ? Icons.check_circle : Icons.radio_button_unchecked,
        size: 18,
        color: active ? Colors.green : Colors.grey,
      ),
      label: Text(label),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style,
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}
