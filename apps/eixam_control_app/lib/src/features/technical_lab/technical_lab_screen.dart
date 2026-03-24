import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/material.dart';

import 'technical_lab_sections.dart';

class TechnicalLabScreen extends StatefulWidget {
  const TechnicalLabScreen({
    super.key,
    required this.sdk,
    this.notificationRequest,
  });

  final EixamConnectSdk sdk;
  final BleNotificationNavigationRequest? notificationRequest;

  @override
  State<TechnicalLabScreen> createState() => _TechnicalLabScreenState();
}

class _TechnicalLabScreenState extends State<TechnicalLabScreen> {
  late final DeviceDebugController _controller;
  final TextEditingController _ackRelayNodeIdController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = DeviceDebugController(sdk: widget.sdk);
    _controller.initialize();
    final request = widget.notificationRequest;
    if (request != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_notificationMessage(request))),
        );
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _ackRelayNodeIdController.dispose();
    super.dispose();
  }

  String _notificationMessage(BleNotificationNavigationRequest request) {
    final node = request.nodeId == null ? '' : ' node ${_formatNodeId(request.nodeId)}';
    return '${request.reason} (${request.actionId})$node';
  }

  Future<void> _confirmAndSendShutdown() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Confirm Shutdown'),
          content: const Text('Send opcode 0x10 to the connected device?'),
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
      await _controller.sendShutdown();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Technical Lab')),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final deviceViewState = _controller.deviceViewState;
          final deviceSosViewState = _controller.deviceSosViewState;
          final diagnosticsViewState = _controller.diagnosticsViewState;
          final status = _controller.status;
          final bleDebugState = _controller.bleDebugState;
          final permissionState = _controller.permissionState;
          final notificationRequest = widget.notificationRequest;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LabCard(
                  title: 'Technical Surface',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This surface keeps diagnostics and technical actions available for validation, but consumes SDK APIs and presentation helpers instead of embedding protocol logic in widgets.',
                      ),
                      if (notificationRequest != null) ...[
                        const SizedBox(height: 12),
                        LabInfoLine(
                          label: 'Notification action',
                          value: notificationRequest.actionId,
                        ),
                        LabInfoLine(
                          label: 'Notification reason',
                          value: notificationRequest.reason,
                        ),
                        LabInfoLine(
                          label: 'Node ID',
                          value: _formatNodeId(notificationRequest.nodeId),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                PermissionsSection(
                  permissionState: permissionState,
                  loading: _controller.loadingPermissions,
                  onRefresh: _controller.refreshPermissions,
                  onRequestBluetooth: _controller.requestScanPermissions,
                  onRequestNotifications: _controller.requestNotificationPermission,
                ),
                const SizedBox(height: 16),
                NotificationsSection(
                  loading: _controller.loadingNotifications,
                  onInitialize: _controller.initializeNotifications,
                  onTest: _controller.showTestNotification,
                ),
                const SizedBox(height: 16),
                LabCard(
                  title: 'Device Overview',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        deviceViewState.deviceName,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Chip(label: Text(deviceViewState.statusLabel)),
                          StatusPill(label: 'Connected', active: status?.connected ?? false),
                          StatusPill(
                            label: 'Ready',
                            active: status?.isReadyForSafety ?? false,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      LabInfoLine(
                        label: 'Connection',
                        value: deviceViewState.connectionSummary,
                      ),
                      LabInfoLine(
                        label: 'Readiness',
                        value: deviceViewState.readinessSummary,
                      ),
                      LabInfoLine(label: 'Device ID', value: status?.deviceId ?? '-'),
                      LabInfoLine(label: 'Model', value: deviceViewState.modelLabel),
                      LabInfoLine(label: 'Alias', value: deviceViewState.aliasLabel),
                      LabInfoLine(label: 'Battery', value: deviceViewState.batterySummary),
                      LabInfoLine(
                        label: 'Firmware',
                        value: deviceViewState.firmwareLabel,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                LabCard(
                  title: 'Device Actions',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton(
                        onPressed: _controller.loadingDevice ? null : _controller.pairDevice,
                        child: const Text('Pair / Connect'),
                      ),
                      ElevatedButton(
                        onPressed:
                            _controller.loadingDevice ? null : _controller.activateDevice,
                        child: const Text('Activate'),
                      ),
                      ElevatedButton(
                        onPressed:
                            _controller.loadingDevice ? null : _controller.refreshDevice,
                        child: const Text('Refresh'),
                      ),
                      ElevatedButton(
                        onPressed:
                            _controller.loadingDevice ? null : _controller.unpairDevice,
                        child: const Text('Unpair'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                LabCard(
                  title: 'Device SOS',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LabInfoLine(label: 'State', value: deviceSosViewState.label),
                      LabInfoLine(
                        label: 'Transition source',
                        value: deviceSosViewState.sourceLabel,
                      ),
                      LabInfoLine(
                        label: 'Last event',
                        value: deviceSosViewState.detailLabel,
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton(
                            onPressed: deviceSosViewState.canTrigger
                                ? _controller.triggerDeviceSos
                                : null,
                            child: const Text('Trigger SOS'),
                          ),
                          ElevatedButton(
                            onPressed: deviceSosViewState.canConfirm
                                ? _controller.confirmDeviceSos
                                : null,
                            child: const Text('Confirm SOS'),
                          ),
                          ElevatedButton(
                            onPressed: deviceSosViewState.canCancel
                                ? _controller.cancelDeviceSos
                                : null,
                            child: Text(deviceSosViewState.cancelLabel),
                          ),
                          ElevatedButton(
                            onPressed: deviceSosViewState.canAcknowledge
                                ? _controller.acknowledgeDeviceSos
                                : null,
                            child: const Text('Backend ACK'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                LabCard(
                  title: 'BLE Setup',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LabInfoLine(
                        label: 'Adapter state',
                        value: diagnosticsViewState.adapterStateLabel,
                      ),
                      LabInfoLine(
                        label: 'Connection status',
                        value: diagnosticsViewState.connectionStatusLabel,
                      ),
                      LabInfoLine(
                        label: 'Compatibility mode',
                        value: diagnosticsViewState.compatibilityModeLabel,
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
                            onPressed: _controller.loadingScan ? null : _controller.runScan,
                            child: const Text('Scan BLE'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (!bleDebugState.isScanning && !diagnosticsViewState.hasScanResults)
                        const Text('No BLE devices discovered yet.')
                      else
                        Column(
                          children: bleDebugState.scanResults.map((scan) {
                            final services = scan.advertisedServiceUuids.isEmpty
                                ? null
                                : scan.advertisedServiceUuids.join(', ');
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: ScanResultCard(
                                title: scan.name.isEmpty ? 'Unknown device' : scan.name,
                                scan: scan,
                                isSelected:
                                    bleDebugState.selectedDeviceId == scan.deviceId,
                                services: services,
                                onTap: _controller.loadingDevice || !scan.connectable
                                    ? null
                                    : () => _controller.pairSelectedDevice(scan),
                              ),
                            );
                          }).toList(growable: false),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                LabCard(
                  title: 'Advanced Debug',
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: const Text('Technical diagnostics and low-level controls'),
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed:
                                bleDebugState.commandWriterReady ? _controller.sendInetOk : null,
                            child: const Text('INET OK'),
                          ),
                          OutlinedButton(
                            onPressed: bleDebugState.commandWriterReady
                                ? _controller.sendInetLost
                                : null,
                            child: const Text('INET LOST'),
                          ),
                          OutlinedButton(
                            onPressed: bleDebugState.commandWriterReady
                                ? _controller.sendPositionConfirmed
                                : null,
                            child: const Text('POS CONFIRMED'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _ackRelayNodeIdController,
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
                            onPressed: bleDebugState.commandWriterReady
                                ? () =>
                                    _controller.sendAckRelay(_ackRelayNodeIdController.text)
                                : null,
                            child: const Text('ACK Relay'),
                          ),
                          OutlinedButton(
                            onPressed: bleDebugState.commandWriterReady
                                ? _confirmAndSendShutdown
                                : null,
                            child: const Text('Shutdown'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      LabInfoLine(
                        label: 'Packet timestamp',
                        value: _formatDate(_controller.deviceSosStatus.lastPacketAt),
                      ),
                      LabInfoLine(
                        label: 'Packet length',
                        value:
                            _controller.deviceSosStatus.lastPacketLength?.toString() ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Packet hex',
                        value: _controller.deviceSosStatus.lastPacketHex ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Decoded nodeId',
                        value: _formatNodeId(_controller.deviceSosStatus.nodeId),
                      ),
                      LabInfoLine(
                        label: 'Retry count',
                        value: _controller.deviceSosStatus.retryCount?.toString() ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Relay count',
                        value: _controller.deviceSosStatus.relayCount?.toString() ?? '-',
                      ),
                      LabInfoLine(
                        label: 'GPS quality',
                        value: _controller.deviceSosStatus.gpsQuality?.toString() ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Packet id',
                        value: _controller.deviceSosStatus.packetId?.toString() ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Decoder note',
                        value: _controller.deviceSosStatus.decoderNote ?? '-',
                      ),
                      const SizedBox(height: 16),
                      LabInfoLine(
                        label: 'Last command sent',
                        value: diagnosticsViewState.lastCommandLabel,
                      ),
                      LabInfoLine(
                        label: 'Payload hex',
                        value: bleDebugState.lastCommandSent ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Target characteristic',
                        value: bleDebugState.lastWriteTargetCharacteristic ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Write success/failure',
                        value: bleDebugState.lastWriteResult ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Timestamp',
                        value: _formatDate(bleDebugState.lastWriteAt),
                      ),
                      LabInfoLine(
                        label: 'Exact error',
                        value: bleDebugState.lastWriteError ?? '-',
                      ),
                      const SizedBox(height: 16),
                      LabInfoLine(
                        label: 'Connected device id',
                        value: bleDebugState.selectedDeviceId ?? '-',
                      ),
                      LabInfoLine(
                        label: 'Scanning',
                        value: bleDebugState.isScanning.toString(),
                      ),
                      LabInfoLine(
                        label: 'EIXAM service found',
                        value: bleDebugState.eixamServiceFound.toString(),
                      ),
                      LabInfoLine(label: 'TEL found', value: bleDebugState.telFound.toString()),
                      LabInfoLine(label: 'SOS found', value: bleDebugState.sosFound.toString()),
                      LabInfoLine(
                        label: 'INET found',
                        value: bleDebugState.inetFound.toString(),
                      ),
                      LabInfoLine(label: 'CMD found', value: bleDebugState.cmdFound.toString()),
                      LabInfoLine(
                        label: 'TEL notify subscribed',
                        value: bleDebugState.telNotifySubscribed.toString(),
                      ),
                      LabInfoLine(
                        label: 'SOS notify subscribed',
                        value: bleDebugState.sosNotifySubscribed.toString(),
                      ),
                      const SizedBox(height: 16),
                      if (bleDebugState.events.isEmpty)
                        const Text('No BLE events yet.')
                      else
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: bleDebugState.events.reversed.take(10).map((event) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Text(
                                '${_formatDate(event.timestamp)}  ${event.message}',
                              ),
                            );
                          }).toList(growable: false),
                        ),
                    ],
                  ),
                ),
                if (_controller.lastError != null) ...[
                  const SizedBox(height: 16),
                  LabCard(
                    title: 'Last Error',
                    child: SelectableText(_controller.lastError!),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatDate(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _formatNodeId(int? nodeId) {
    if (nodeId == null) return '-';
    final normalized = nodeId & 0xFFFF;
    return '0x${normalized.toRadixString(16).padLeft(4, '0')}';
  }
}
