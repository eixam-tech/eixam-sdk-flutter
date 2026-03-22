import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/material.dart';

class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({
    super.key,
    required this.sdk,
    this.notificationContextMessage,
    this.notificationActionId,
    this.notificationNodeId,
  });

  final EixamConnectSdk sdk;
  final String? notificationContextMessage;
  final String? notificationActionId;
  final int? notificationNodeId;

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  DeviceStatus? _deviceStatus;
  DeviceSosStatus _deviceSosStatus = DeviceSosStatus.initial();
  final TextEditingController _ackRelayNodeIdController =
      TextEditingController();
  PermissionState? _permissionState;
  BleDebugState _bleDebugState = BleDebugRegistry.instance.currentState;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<DeviceSosStatus>? _deviceSosSub;
  StreamSubscription<BleDebugState>? _bleDebugSub;
  bool _loadingDevice = false;
  bool _loadingSos = false;
  bool _loadingScan = false;
  bool _loadingPermissions = false;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _bindStreams();
    _loadInitialState();
    if (widget.notificationContextMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.notificationContextMessage!)),
        );
      });
    }
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

    _deviceSosSub = widget.sdk.watchDeviceSosStatus().listen(
      (status) {
        if (!mounted) return;
        setState(() {
          _deviceSosStatus = status;
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
      final deviceSosStatus = await widget.sdk.getDeviceSosStatus();
      final permissionState = await widget.sdk.getPermissionState();
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
        _deviceSosStatus = deviceSosStatus;
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

  Future<void> _runCommandAction(Future<void> Function() action) async {
    setState(() {
      _lastError = null;
    });

    try {
      await action();
    } catch (error) {
      _handleError(error);
    }
  }

  Future<void> _runSosAction(
    Future<DeviceSosStatus> Function() action,
  ) async {
    setState(() {
      _loadingSos = true;
      _lastError = null;
    });

    try {
      final status = await action();
      if (!mounted) return;
      setState(() {
        _deviceSosStatus = status;
      });
    } catch (error) {
      _handleError(error);
    } finally {
      if (mounted) {
        setState(() {
          _loadingSos = false;
        });
      }
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
    _deviceSosSub?.cancel();
    _bleDebugSub?.cancel();
    _ackRelayNodeIdController.dispose();
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
            if (widget.notificationContextMessage != null) ...[
              const SizedBox(height: 16),
              _CardSection(
                title: 'Notification Context',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InfoLine(
                      label: 'Action',
                      value: widget.notificationActionId ?? '-',
                    ),
                    _InfoLine(
                      label: 'Message',
                      value: widget.notificationContextMessage ?? '-',
                    ),
                    _InfoLine(
                      label: 'Node ID',
                      value: _formatNodeId(widget.notificationNodeId),
                    ),
                  ],
                ),
              ),
            ],
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
                    value: _formatDeviceBattery(status),
                  ),
                  _InfoLine(
                    label: 'Battery source',
                    value: _formatBatterySource(status?.batterySource),
                  ),
                  _InfoLine(
                    label: 'Battery protocol level',
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
              title: 'SOS State',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(
                        label: Text(_deviceSosBadgeLabel(_deviceSosStatus)),
                        backgroundColor: _deviceSosBadgeColor(
                          _deviceSosStatus.state,
                        ),
                      ),
                      if (_deviceSosStatus.optimistic)
                        const Chip(label: Text('Optimistic')),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _InfoLine(
                    label: 'Current state',
                    value: _deviceSosStatus.state.name,
                  ),
                  _InfoLine(
                    label: 'State source',
                    value: _deviceSosStatus.derivedFromBlePacket
                        ? 'Derived from BLE packet parsing'
                        : 'Local/runtime state',
                  ),
                  _InfoLine(
                    label: 'Last SOS packet length',
                    value: _deviceSosStatus.lastPacketLength?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Last SOS packet timestamp',
                    value: _formatDate(_deviceSosStatus.lastPacketAt),
                  ),
                  _InfoLine(
                    label: 'Last SOS packet hex',
                    value: _deviceSosStatus.lastPacketHex ?? '-',
                  ),
                  _InfoLine(
                    label: 'Last transition',
                    value: _deviceSosStatus.lastEvent,
                  ),
                  _InfoLine(
                    label: 'Decoded nodeId',
                    value: _formatNodeId(_deviceSosStatus.nodeId),
                  ),
                  _InfoLine(
                    label: 'Decoded flags',
                    value: _formatByte(_deviceSosStatus.flags),
                  ),
                  _InfoLine(
                    label: 'Decoded SOS type',
                    value: _deviceSosStatus.sosType?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Retry count',
                    value: _deviceSosStatus.retryCount?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Relay count',
                    value: _deviceSosStatus.relayCount?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Battery level',
                    value: _formatSosBattery(_deviceSosStatus),
                  ),
                  _InfoLine(
                    label: 'GPS quality',
                    value: _deviceSosStatus.gpsQuality?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Packet id',
                    value: _deviceSosStatus.packetId?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Has location',
                    value: _deviceSosStatus.hasLocation?.toString() ?? '-',
                  ),
                  _InfoLine(
                    label: 'Decoder note',
                    value: _deviceSosStatus.decoderNote ?? '-',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'SOS Controls',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(
                        onPressed: _canTriggerDeviceSos
                            ? () => _runSosAction(widget.sdk.triggerDeviceSos)
                            : null,
                        child: const Text('Trigger SOS'),
                      ),
                      ElevatedButton(
                        onPressed: _canConfirmDeviceSos
                            ? () => _runSosAction(widget.sdk.confirmDeviceSos)
                            : null,
                        child: const Text('Confirm SOS'),
                      ),
                      OutlinedButton(
                        onPressed: _canCancelDeviceSos
                            ? () => _runSosAction(widget.sdk.cancelDeviceSos)
                            : null,
                        child: Text(_cancelDeviceSosLabel),
                      ),
                      ElevatedButton(
                        onPressed: _canSendBackendAck
                            ? () =>
                                _runSosAction(widget.sdk.acknowledgeDeviceSos)
                            : null,
                        child: const Text('Send Backend ACK'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Command meanings: Confirm SOS sends 0x05 during countdown. '
                    'Cancel and Resolve both send 0x04. '
                    'Send Backend ACK sends 0x07 to tell the device the backend acknowledged the SOS; it is not a local "mark as seen" action.',
                    style: TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'Connectivity Controls',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _bleDebugState.commandWriterReady
                        ? () => _runCommandAction(widget.sdk.sendInetOkToDevice)
                        : null,
                    child: const Text('INET OK'),
                  ),
                  OutlinedButton(
                    onPressed: _bleDebugState.commandWriterReady
                        ? () =>
                            _runCommandAction(widget.sdk.sendInetLostToDevice)
                        : null,
                    child: const Text('INET LOST'),
                  ),
                  OutlinedButton(
                    onPressed: _bleDebugState.commandWriterReady
                        ? () => _runCommandAction(
                              widget.sdk.sendPositionConfirmedToDevice,
                            )
                        : null,
                    child: const Text('POS CONFIRMED'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'Advanced Controls',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _ackRelayNodeIdController,
                    decoration: const InputDecoration(
                      labelText: 'SOS_ACK_RELAY nodeId',
                      hintText: '0x1AA8 or decimal',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: _bleDebugState.commandWriterReady
                          ? _sendAckRelayCommand
                          : null,
                      child: const Text('ACK Relay'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: _bleDebugState.commandWriterReady
                          ? _confirmAndSendShutdown
                          : null,
                      child: const Text('Shutdown'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _CardSection(
              title: 'Last Command Result',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoLine(
                    label: 'Last command sent',
                    value: _lastCommandLabel(_bleDebugState.lastCommandSent),
                  ),
                  _InfoLine(
                    label: 'Last payload hex',
                    value: _bleDebugState.lastCommandSent ?? '-',
                  ),
                  _InfoLine(
                    label: 'Target characteristic',
                    value: _bleDebugState.lastWriteTargetCharacteristic ?? '-',
                  ),
                  _InfoLine(
                    label: 'Write success/failure',
                    value: _bleDebugState.lastWriteResult ?? '-',
                  ),
                  _InfoLine(
                    label: 'Timestamp',
                    value: _formatDate(_bleDebugState.lastWriteAt),
                  ),
                  _InfoLine(
                    label: 'Exact error',
                    value: _bleDebugState.lastWriteError ?? '-',
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
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('Tap to expand'),
                children: [
                  _InfoLine(
                    label: 'Adapter state',
                    value: _bleDebugState.adapterState.toString(),
                  ),
                  _InfoLine(
                    label: 'Connected device id',
                    value: _bleDebugState.selectedDeviceId ?? '-',
                  ),
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
                  _InfoLine(
                    label: 'TEL notify subscribed',
                    value: _bleDebugState.telNotifySubscribed.toString(),
                  ),
                  _InfoLine(
                    label: 'SOS notify subscribed',
                    value: _bleDebugState.sosNotifySubscribed.toString(),
                  ),
                  _InfoLine(
                    label: 'Compatibility mode',
                    value: _compatibilityModeLabel(),
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

  bool get _canTriggerDeviceSos {
    final state = _deviceSosStatus.state;
    return !_loadingSos &&
        (state == DeviceSosState.inactive ||
            state == DeviceSosState.resolved ||
            state == DeviceSosState.unknown);
  }

  bool get _canConfirmDeviceSos =>
      !_loadingSos && _deviceSosStatus.state == DeviceSosState.preConfirm;

  bool get _canSendBackendAck =>
      !_loadingSos && _deviceSosStatus.state == DeviceSosState.active;

  bool get _canCancelDeviceSos {
    final state = _deviceSosStatus.state;
    return !_loadingSos &&
        (state == DeviceSosState.preConfirm ||
            state == DeviceSosState.active ||
            state == DeviceSosState.acknowledged);
  }

  String get _cancelDeviceSosLabel {
    return _deviceSosStatus.state == DeviceSosState.preConfirm
        ? 'Cancel SOS'
        : 'Resolve SOS';
  }

  String _deviceSosBadgeLabel(DeviceSosStatus status) {
    final text = switch (status.state) {
      DeviceSosState.inactive => 'Inactive',
      DeviceSosState.preConfirm => 'Pre-confirm',
      DeviceSosState.active => 'Active',
      DeviceSosState.acknowledged => 'Acknowledged',
      DeviceSosState.resolved => 'Resolved',
      DeviceSosState.unknown => 'Unknown',
    };
    return status.optimistic ? '$text (pending)' : text;
  }

  Color _deviceSosBadgeColor(DeviceSosState state) {
    switch (state) {
      case DeviceSosState.inactive:
        return Colors.grey.shade300;
      case DeviceSosState.preConfirm:
        return Colors.orange.shade200;
      case DeviceSosState.active:
        return Colors.red.shade200;
      case DeviceSosState.acknowledged:
        return Colors.blue.shade200;
      case DeviceSosState.resolved:
        return Colors.green.shade200;
      case DeviceSosState.unknown:
        return Colors.black12;
    }
  }

  String _formatByte(int? value) {
    if (value == null) return '-';
    return '0x${value.toRadixString(16).padLeft(2, '0')}';
  }

  String _formatNodeId(int? nodeId) {
    if (nodeId == null) return '-';
    final normalized = nodeId & 0xFFFF;
    return '0x${normalized.toRadixString(16).padLeft(4, '0')}';
  }

  String _lastCommandLabel(String? payloadHex) {
    if (payloadHex == null || payloadHex.trim().isEmpty) {
      return '-';
    }
    final firstToken = payloadHex.trim().split(RegExp(r'\s+')).first;
    final opcode = int.tryParse(firstToken, radix: 16);
    if (opcode == null) {
      return payloadHex;
    }
    switch (opcode) {
      case 0x01:
        return 'INET OK';
      case 0x02:
        return 'INET LOST';
      case 0x03:
        return 'POS CONFIRMED';
      case 0x04:
        return 'SOS CANCEL / RESOLVE';
      case 0x05:
        return 'SOS CONFIRM';
      case 0x06:
        return 'SOS TRIGGER APP';
      case 0x07:
        return 'BACKEND SOS ACK';
      case 0x08:
        return 'SOS ACK RELAY';
      case 0x10:
        return 'SHUTDOWN';
      default:
        return '0x${opcode.toRadixString(16).padLeft(2, '0')}';
    }
  }

  String _compatibilityModeLabel() {
    final softCompatible = _bleDebugState.eixamServiceFound &&
        _bleDebugState.telFound &&
        _bleDebugState.sosFound &&
        _bleDebugState.inetFound;
    if (!softCompatible) {
      return 'Incompatible';
    }
    if (_bleDebugState.cmdFound) {
      return 'Full';
    }
    return 'Soft';
  }

  String _formatDate(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _formatDeviceBattery(DeviceStatus? status) {
    if (status == null) {
      return '-';
    }

    final batteryState = status.effectiveBatteryState;
    if (batteryState == null) {
      return '-';
    }

    return '${batteryState.label} (~${batteryState.approximatePercentage}% UI est.)';
  }

  String _formatBatterySource(DeviceBatterySource? source) {
    return switch (source) {
      DeviceBatterySource.telPacket => 'Latest TEL packet',
      DeviceBatterySource.sosPacket => 'Latest SOS packet',
      DeviceBatterySource.unknown => 'Unknown',
      null => '-',
    };
  }

  String _formatSosBattery(DeviceSosStatus status) {
    final batteryState = status.batteryState;
    if (batteryState == null) {
      return status.batteryLevel?.toString() ?? '-';
    }

    return '${batteryState.label} (raw ${status.batteryLevel ?? "-"})';
  }

  Future<void> _sendAckRelayCommand() async {
    final raw = _ackRelayNodeIdController.text.trim();
    if (raw.isEmpty) {
      _handleError(StateError('Enter a nodeId for SOS_ACK_RELAY.'));
      return;
    }

    final nodeId = _parseNodeId(raw);
    if (nodeId == null) {
      _handleError(
        StateError('Invalid nodeId. Use decimal or hex like 0x1AA8.'),
      );
      return;
    }
    if (nodeId < 0 || nodeId > 0xFFFF) {
      _handleError(
        StateError('SOS_ACK_RELAY expects a 16-bit nodeId (0 to 65535).'),
      );
      return;
    }

    await _runCommandAction(
      () => widget.sdk.sendSosAckRelayToDevice(nodeId: nodeId),
    );
  }

  int? _parseNodeId(String raw) {
    if (raw.startsWith('0x') || raw.startsWith('0X')) {
      return int.tryParse(raw.substring(2), radix: 16);
    }
    return int.tryParse(raw);
  }

  Future<void> _confirmAndSendShutdown() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Confirm Shutdown'),
          content: const Text(
            'Send opcode 0x10 to the connected device?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Send'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      await _runCommandAction(widget.sdk.sendShutdownToDevice);
    }
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
