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
  BleDebugState _bleDebugState = BleDebugRegistry.instance.currentState;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<BleDebugState>? _bleDebugSub;
  bool _loadingDevice = false;
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
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
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
      await widget.sdk.pairDevice(pairingCode: 'DEMO-PAIR-001');
    });
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
                    label: 'EIXAM service found',
                    value: _bleDebugState.eixamServiceFound.toString(),
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
