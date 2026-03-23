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
    final hasScanResults = _bleDebugState.scanResults.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Detail'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DeviceHeroCard(
              deviceName: deviceName,
              statusLabel: _statusLabel(status),
              model: status?.model ?? '-',
              deviceId: status?.deviceId ?? '-',
              batterySummary: _formatDeviceBattery(status),
              readinessSummary: _deviceReadinessSummary(status),
              isConnected: status?.connected ?? false,
              isReady: status?.isReadyForSafety ?? false,
            ),
            const SizedBox(height: 16),
            _DeviceOverviewCard(
              status: status,
              lastSeen: _formatDate(status?.lastSeen),
              connectionSummary: _connectionSummary(status),
            ),
            const SizedBox(height: 16),
            _SafetyStatusCard(
              status: _deviceSosStatus,
              badgeLabel: _deviceSosBadgeLabel(_deviceSosStatus),
              sourceLabel: _deviceSosStatus.derivedFromBlePacket
                  ? 'Updated from device packet'
                  : 'Updated by app/runtime state',
              lastPacketAt: _formatDate(_deviceSosStatus.lastPacketAt),
            ),
            const SizedBox(height: 16),
            _SosActionsCard(
              canTriggerDeviceSos: _canTriggerDeviceSos,
              canConfirmDeviceSos: _canConfirmDeviceSos,
              canCancelDeviceSos: _canCancelDeviceSos,
              canSendBackendAck: _canSendBackendAck,
              cancelDeviceSosLabel: _cancelDeviceSosLabel,
              onTrigger: () => _runSosAction(widget.sdk.triggerDeviceSos),
              onConfirm: () => _runSosAction(widget.sdk.confirmDeviceSos),
              onCancel: () => _runSosAction(widget.sdk.cancelDeviceSos),
              onAcknowledge: () =>
                  _runSosAction(widget.sdk.acknowledgeDeviceSos),
            ),
            const SizedBox(height: 16),
            _ConnectionActionsCard(
              loadingDevice: _loadingDevice,
              onPair: _pairDevice,
              onActivate: _activateDevice,
              onRefresh: _refreshDevice,
              onUnpair: _unpairDevice,
            ),
            const SizedBox(height: 16),
            _BluetoothSetupCard(
              permissionState: _permissionState,
              bleDebugState: _bleDebugState,
              loadingPermissions: _loadingPermissions,
              loadingScan: _loadingScan,
              showScanResults: _bleDebugState.isScanning || hasScanResults,
              onRequestPermissions: _requestScanPermissions,
              onRunScan: _runScan,
              onPairSelectedDevice: _pairSelectedDevice,
              loadingDevice: _loadingDevice,
            ),
            const SizedBox(height: 16),
            _AdvancedDebugSection(
              notificationContextMessage: widget.notificationContextMessage,
              notificationActionId: widget.notificationActionId,
              notificationNodeId: widget.notificationNodeId,
              bleDebugState: _bleDebugState,
              deviceSosStatus: _deviceSosStatus,
              ackRelayNodeIdController: _ackRelayNodeIdController,
              commandWriterReady: _bleDebugState.commandWriterReady,
              onSendInetOk: () => _runCommandAction(widget.sdk.sendInetOkToDevice),
              onSendInetLost: () =>
                  _runCommandAction(widget.sdk.sendInetLostToDevice),
              onSendPositionConfirmed: () => _runCommandAction(
                widget.sdk.sendPositionConfirmedToDevice,
              ),
              onSendAckRelay: _sendAckRelayCommand,
              onSendShutdown: _confirmAndSendShutdown,
              compatibilityModeLabel: _compatibilityModeLabel(),
              formatDate: _formatDate,
              formatNodeId: _formatNodeId,
              formatByte: _formatByte,
              formatSosBattery: _formatSosBattery,
              lastCommandLabel: _lastCommandLabel(_bleDebugState.lastCommandSent),
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

  String _connectionSummary(DeviceStatus? status) {
    if (status == null) return 'Disconnected';
    if (status.connected) return 'Connected';
    if (status.paired) return 'Paired, not connected';
    return 'Not connected';
  }

  String _deviceReadinessSummary(DeviceStatus? status) {
    if (status == null) {
      return 'No active device connection';
    }
    if (status.isReadyForSafety) {
      return 'Connected and ready for safety workflows';
    }
    if (status.connected) {
      return 'Connected, but setup is not complete';
    }
    if (status.paired) {
      return 'Device is paired but currently offline';
    }
    return 'Device is not paired';
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
      DeviceSosState.inactive => 'Safe',
      DeviceSosState.preConfirm => 'Waiting confirmation',
      DeviceSosState.active => 'Active',
      DeviceSosState.acknowledged => 'Acknowledged',
      DeviceSosState.resolved => 'Resolved',
      DeviceSosState.unknown => 'Unknown',
    };
    return status.optimistic ? '$text (pending)' : text;
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

class _DeviceHeroCard extends StatelessWidget {
  const _DeviceHeroCard({
    required this.deviceName,
    required this.statusLabel,
    required this.model,
    required this.deviceId,
    required this.batterySummary,
    required this.readinessSummary,
    required this.isConnected,
    required this.isReady,
  });

  final String deviceName;
  final String statusLabel;
  final String model;
  final String deviceId;
  final String batterySummary;
  final String readinessSummary;
  final bool isConnected;
  final bool isReady;

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
                _StatusPill(
                  label: isConnected ? 'Connected' : 'Offline',
                  active: isConnected,
                ),
                _StatusPill(
                  label: isReady ? 'Ready for safety' : 'Setup needed',
                  active: isReady,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Model: $model'),
            const SizedBox(height: 4),
            Text(
              readinessSummary,
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _SummaryTile(
                    label: 'Battery',
                    value: batterySummary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryTile(
                    label: 'Device ID',
                    value: deviceId,
                    compact: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceOverviewCard extends StatelessWidget {
  const _DeviceOverviewCard({
    required this.status,
    required this.lastSeen,
    required this.connectionSummary,
  });

  final DeviceStatus? status;
  final String lastSeen;
  final String connectionSummary;

  @override
  Widget build(BuildContext context) {
    return _CardSection(
      title: 'Quick Overview',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _SummaryTile(
                  label: 'Connection',
                  value: connectionSummary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryTile(
                  label: 'Ready for safety',
                  value: status?.isReadyForSafety == true ? 'Yes' : 'No',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SummaryTile(
                  label: 'Firmware',
                  value: status?.firmwareVersion ?? '-',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryTile(
                  label: 'Last seen',
                  value: lastSeen,
                ),
              ),
            ],
          ),
          if (status?.provisioningError != null) ...[
            const SizedBox(height: 12),
            _SummaryTile(
              label: 'Provisioning issue',
              value: status!.provisioningError!,
            ),
          ],
        ],
      ),
    );
  }
}

class _SafetyStatusCard extends StatelessWidget {
  const _SafetyStatusCard({
    required this.status,
    required this.badgeLabel,
    required this.sourceLabel,
    required this.lastPacketAt,
  });

  final DeviceSosStatus status;
  final String badgeLabel;
  final String sourceLabel;
  final String lastPacketAt;

  @override
  Widget build(BuildContext context) {
    return _CardSection(
      title: 'Safety Status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Chip(
                label: Text(badgeLabel),
                backgroundColor: _badgeColor(status.state),
              ),
              if (status.optimistic)
                const Chip(label: Text('Pending confirmation')),
            ],
          ),
          const SizedBox(height: 12),
          _InfoLine(
            label: 'Last transition',
            value: status.lastEvent,
          ),
          _InfoLine(
            label: 'Last device update',
            value: lastPacketAt,
          ),
          _InfoLine(
            label: 'Source',
            value: sourceLabel,
          ),
        ],
      ),
    );
  }

  Color _badgeColor(DeviceSosState state) {
    switch (state) {
      case DeviceSosState.inactive:
        return Colors.green.shade100;
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
}

class _SosActionsCard extends StatelessWidget {
  const _SosActionsCard({
    required this.canTriggerDeviceSos,
    required this.canConfirmDeviceSos,
    required this.canCancelDeviceSos,
    required this.canSendBackendAck,
    required this.cancelDeviceSosLabel,
    required this.onTrigger,
    required this.onConfirm,
    required this.onCancel,
    required this.onAcknowledge,
  });

  final bool canTriggerDeviceSos;
  final bool canConfirmDeviceSos;
  final bool canCancelDeviceSos;
  final bool canSendBackendAck;
  final String cancelDeviceSosLabel;
  final VoidCallback onTrigger;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    return _CardSection(
      title: 'SOS Actions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: canTriggerDeviceSos ? onTrigger : null,
                child: const Text('Trigger SOS'),
              ),
              ElevatedButton(
                onPressed: canConfirmDeviceSos ? onConfirm : null,
                child: const Text('Confirm SOS'),
              ),
              OutlinedButton(
                onPressed: canCancelDeviceSos ? onCancel : null,
                child: Text(cancelDeviceSosLabel),
              ),
              ElevatedButton(
                onPressed: canSendBackendAck ? onAcknowledge : null,
                child: const Text('Send Backend ACK'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Confirm sends the device confirmation command. Cancel and Resolve use the same cancel opcode. Backend ACK tells the device the backend acknowledged the SOS.',
            style: TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

class _ConnectionActionsCard extends StatelessWidget {
  const _ConnectionActionsCard({
    required this.loadingDevice,
    required this.onPair,
    required this.onActivate,
    required this.onRefresh,
    required this.onUnpair,
  });

  final bool loadingDevice;
  final VoidCallback onPair;
  final VoidCallback onActivate;
  final VoidCallback onRefresh;
  final VoidCallback onUnpair;

  @override
  Widget build(BuildContext context) {
    return _CardSection(
      title: 'Device Actions',
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          ElevatedButton(
            onPressed: loadingDevice ? null : onPair,
            child: const Text('Pair / Connect'),
          ),
          ElevatedButton(
            onPressed: loadingDevice ? null : onActivate,
            child: const Text('Activate'),
          ),
          ElevatedButton(
            onPressed: loadingDevice ? null : onRefresh,
            child: const Text('Refresh'),
          ),
          ElevatedButton(
            onPressed: loadingDevice ? null : onUnpair,
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
  }
}

class _BluetoothSetupCard extends StatelessWidget {
  const _BluetoothSetupCard({
    required this.permissionState,
    required this.bleDebugState,
    required this.loadingPermissions,
    required this.loadingScan,
    required this.showScanResults,
    required this.onRequestPermissions,
    required this.onRunScan,
    required this.onPairSelectedDevice,
    required this.loadingDevice,
  });

  final PermissionState? permissionState;
  final BleDebugState bleDebugState;
  final bool loadingPermissions;
  final bool loadingScan;
  final bool showScanResults;
  final Future<void> Function() onRequestPermissions;
  final Future<void> Function() onRunScan;
  final Future<void> Function(BleScanResult scan) onPairSelectedDevice;
  final bool loadingDevice;

  @override
  Widget build(BuildContext context) {
    return _CardSection(
      title: 'Bluetooth Setup',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _SummaryTile(
                  label: 'Bluetooth permission',
                  value: permissionState?.bluetooth.toString() ?? '-',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryTile(
                  label: 'Bluetooth enabled',
                  value: permissionState?.bluetoothEnabled.toString() ?? '-',
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SummaryTile(
                  label: 'Adapter state',
                  value: bleDebugState.adapterState.toString(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _SummaryTile(
                  label: 'Connection status',
                  value: bleDebugState.connectionStatus.name,
                ),
              ),
            ],
          ),
          if (bleDebugState.connectionError != null) ...[
            const SizedBox(height: 12),
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
              child: Text(bleDebugState.connectionError!),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: loadingPermissions ? null : onRequestPermissions,
                child: const Text('Request BLE permissions'),
              ),
              ElevatedButton(
                onPressed: loadingScan ? null : onRunScan,
                child: const Text('Scan BLE'),
              ),
            ],
          ),
          if (showScanResults) ...[
            const SizedBox(height: 12),
            if (bleDebugState.scanResults.isEmpty)
              const Text('No BLE devices discovered yet.')
            else
              Column(
                children: bleDebugState.scanResults.map((scan) {
                  final title = scan.name.isEmpty ? 'Unknown device' : scan.name;
                  final isSelected =
                      bleDebugState.selectedDeviceId == scan.deviceId;
                  final services = scan.advertisedServiceUuids.isEmpty
                      ? null
                      : scan.advertisedServiceUuids.join(', ');
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ScanResultCard(
                      title: title,
                      scan: scan,
                      isSelected: isSelected,
                      services: services,
                      onTap: loadingDevice || !scan.connectable
                          ? null
                          : () => onPairSelectedDevice(scan),
                    ),
                  );
                }).toList(growable: false),
              ),
          ],
        ],
      ),
    );
  }
}

class _AdvancedDebugSection extends StatelessWidget {
  const _AdvancedDebugSection({
    required this.notificationContextMessage,
    required this.notificationActionId,
    required this.notificationNodeId,
    required this.bleDebugState,
    required this.deviceSosStatus,
    required this.ackRelayNodeIdController,
    required this.commandWriterReady,
    required this.onSendInetOk,
    required this.onSendInetLost,
    required this.onSendPositionConfirmed,
    required this.onSendAckRelay,
    required this.onSendShutdown,
    required this.compatibilityModeLabel,
    required this.formatDate,
    required this.formatNodeId,
    required this.formatByte,
    required this.formatSosBattery,
    required this.lastCommandLabel,
  });

  final String? notificationContextMessage;
  final String? notificationActionId;
  final int? notificationNodeId;
  final BleDebugState bleDebugState;
  final DeviceSosStatus deviceSosStatus;
  final TextEditingController ackRelayNodeIdController;
  final bool commandWriterReady;
  final VoidCallback onSendInetOk;
  final VoidCallback onSendInetLost;
  final VoidCallback onSendPositionConfirmed;
  final VoidCallback onSendAckRelay;
  final VoidCallback onSendShutdown;
  final String compatibilityModeLabel;
  final String Function(DateTime? value) formatDate;
  final String Function(int? nodeId) formatNodeId;
  final String Function(int? value) formatByte;
  final String Function(DeviceSosStatus status) formatSosBattery;
  final String lastCommandLabel;

  @override
  Widget build(BuildContext context) {
    return _CardSection(
      title: 'Advanced Debug',
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: const Text('Technical diagnostics and low-level controls'),
        children: [
          if (notificationContextMessage != null) ...[
            const _SubsectionTitle('Notification Context'),
            _InfoLine(
              label: 'Action',
              value: notificationActionId ?? '-',
            ),
            _InfoLine(
              label: 'Message',
              value: notificationContextMessage ?? '-',
            ),
            _InfoLine(
              label: 'Node ID',
              value: formatNodeId(notificationNodeId),
            ),
            const SizedBox(height: 16),
          ],
          const _SubsectionTitle('Connectivity Controls'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: commandWriterReady ? onSendInetOk : null,
                child: const Text('INET OK'),
              ),
              OutlinedButton(
                onPressed: commandWriterReady ? onSendInetLost : null,
                child: const Text('INET LOST'),
              ),
              OutlinedButton(
                onPressed: commandWriterReady ? onSendPositionConfirmed : null,
                child: const Text('POS CONFIRMED'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SubsectionTitle('Advanced Controls'),
          TextField(
            controller: ackRelayNodeIdController,
            decoration: const InputDecoration(
              labelText: 'SOS_ACK_RELAY nodeId',
              hintText: '0x1AA8 or decimal',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: commandWriterReady ? onSendAckRelay : null,
                child: const Text('ACK Relay'),
              ),
              OutlinedButton(
                onPressed: commandWriterReady ? onSendShutdown : null,
                child: const Text('Shutdown'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const _SubsectionTitle('SOS Raw Details'),
          _InfoLine(
            label: 'Packet timestamp',
            value: formatDate(deviceSosStatus.lastPacketAt),
          ),
          _InfoLine(
            label: 'Packet length',
            value: deviceSosStatus.lastPacketLength?.toString() ?? '-',
          ),
          _InfoLine(
            label: 'Packet hex',
            value: deviceSosStatus.lastPacketHex ?? '-',
          ),
          _InfoLine(
            label: 'Decoded nodeId',
            value: formatNodeId(deviceSosStatus.nodeId),
          ),
          _InfoLine(
            label: 'Decoded flags',
            value: formatByte(deviceSosStatus.flags),
          ),
          _InfoLine(
            label: 'SOS type',
            value: deviceSosStatus.sosType?.toString() ?? '-',
          ),
          _InfoLine(
            label: 'Retry count',
            value: deviceSosStatus.retryCount?.toString() ?? '-',
          ),
          _InfoLine(
            label: 'Relay count',
            value: deviceSosStatus.relayCount?.toString() ?? '-',
          ),
          _InfoLine(
            label: 'Battery level',
            value: formatSosBattery(deviceSosStatus),
          ),
          _InfoLine(
            label: 'GPS quality',
            value: deviceSosStatus.gpsQuality?.toString() ?? '-',
          ),
          _InfoLine(
            label: 'Packet id',
            value: deviceSosStatus.packetId?.toString() ?? '-',
          ),
          _InfoLine(
            label: 'Has location',
            value: deviceSosStatus.hasLocation?.toString() ?? '-',
          ),
          _InfoLine(
            label: 'Decoder note',
            value: deviceSosStatus.decoderNote ?? '-',
          ),
          const SizedBox(height: 16),
          const _SubsectionTitle('Last Command Result'),
          _InfoLine(
            label: 'Last command sent',
            value: lastCommandLabel,
          ),
          _InfoLine(
            label: 'Payload hex',
            value: bleDebugState.lastCommandSent ?? '-',
          ),
          _InfoLine(
            label: 'Target characteristic',
            value: bleDebugState.lastWriteTargetCharacteristic ?? '-',
          ),
          _InfoLine(
            label: 'Write success/failure',
            value: bleDebugState.lastWriteResult ?? '-',
          ),
          _InfoLine(
            label: 'Timestamp',
            value: formatDate(bleDebugState.lastWriteAt),
          ),
          _InfoLine(
            label: 'Exact error',
            value: bleDebugState.lastWriteError ?? '-',
          ),
          const SizedBox(height: 16),
          const _SubsectionTitle('BLE Debug'),
          _InfoLine(
            label: 'Connected device id',
            value: bleDebugState.selectedDeviceId ?? '-',
          ),
          _InfoLine(
            label: 'Scanning',
            value: bleDebugState.isScanning.toString(),
          ),
          _InfoLine(
            label: 'EIXAM service found',
            value: bleDebugState.eixamServiceFound.toString(),
          ),
          _InfoLine(
            label: 'TEL found',
            value: bleDebugState.telFound.toString(),
          ),
          _InfoLine(
            label: 'SOS found',
            value: bleDebugState.sosFound.toString(),
          ),
          _InfoLine(
            label: 'INET found',
            value: bleDebugState.inetFound.toString(),
          ),
          _InfoLine(
            label: 'CMD found',
            value: bleDebugState.cmdFound.toString(),
          ),
          _InfoLine(
            label: 'TEL notify subscribed',
            value: bleDebugState.telNotifySubscribed.toString(),
          ),
          _InfoLine(
            label: 'SOS notify subscribed',
            value: bleDebugState.sosNotifySubscribed.toString(),
          ),
          _InfoLine(
            label: 'Compatibility mode',
            value: compatibilityModeLabel,
          ),
          _InfoLine(
            label: 'Exact connection error',
            value: bleDebugState.connectionError ?? '-',
          ),
          const SizedBox(height: 16),
          const _SubsectionTitle('Live Events'),
          if (bleDebugState.events.isEmpty)
            const Text('No BLE events yet.')
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: bleDebugState.events.reversed.take(10).map((event) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${formatDate(event.timestamp)}  ${event.message}',
                  ),
                );
              }).toList(growable: false),
            ),
        ],
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

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.label,
    required this.value,
    this.compact = false,
  });

  final String label;
  final String value;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.black54,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            value,
            style: TextStyle(
              fontSize: compact ? 13 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.active,
  });

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      backgroundColor: active
          ? Colors.green.withValues(alpha: 0.14)
          : Colors.black.withValues(alpha: 0.06),
    );
  }
}

class _ScanResultCard extends StatelessWidget {
  const _ScanResultCard({
    required this.title,
    required this.scan,
    required this.isSelected,
    required this.services,
    required this.onTap,
  });

  final String title;
  final BleScanResult scan;
  final bool isSelected;
  final String? services;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected
          ? Colors.blue.withValues(alpha: 0.06)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
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
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (isSelected) const Chip(label: Text('Selected')),
                ],
              ),
              const SizedBox(height: 6),
              Text('Device ID: ${scan.deviceId}'),
              Text('RSSI: ${scan.rssi}'),
              Text('Connectable: ${scan.connectable ? "Yes" : "No"}'),
              if (services != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Advertised services: $services',
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubsectionTitle extends StatelessWidget {
  const _SubsectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
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
