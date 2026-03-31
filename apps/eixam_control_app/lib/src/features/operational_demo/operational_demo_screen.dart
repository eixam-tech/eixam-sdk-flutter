import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/material.dart';

import '../../shared/presentation/info_line.dart';
import '../../shared/presentation/section_card.dart';
import 'operational_demo_sections.dart';
import 'validation_console_controller.dart';

class OperationalDemoScreen extends StatefulWidget {
  const OperationalDemoScreen({
    super.key,
    required this.sdk,
    required this.onOpenTechnicalLab,
  });

  final EixamConnectSdk sdk;
  final VoidCallback onOpenTechnicalLab;

  @override
  State<OperationalDemoScreen> createState() => _OperationalDemoScreenState();
}

class _OperationalDemoScreenState extends State<OperationalDemoScreen> {
  late final ValidationConsoleController _controller;
  final _sessionAppIdController = TextEditingController(text: 'demo-app');
  final _sessionExternalUserIdController =
      TextEditingController(text: 'partner-user-42');
  final _sessionUserHashController =
      TextEditingController(text: 'signed-demo-token');
  final _sosMessageController =
      TextEditingController(text: 'Manual SOS from validation console');
  final _sosTriggerSourceController =
      TextEditingController(text: 'debug_validation_console');
  final _telemetryLatitudeController =
      TextEditingController(text: '41.3825');
  final _telemetryLongitudeController =
      TextEditingController(text: '2.1769');
  final _telemetryAltitudeController = TextEditingController(text: '12.0');
  final _telemetryDeviceIdController = TextEditingController(text: 'device-1');
  final _contactNameController = TextEditingController();
  final _contactPhoneController = TextEditingController();
  final _contactEmailController = TextEditingController();
  final _contactPriorityController = TextEditingController(text: '1');
  final _deviceHardwareIdController = TextEditingController();
  final _deviceFirmwareController = TextEditingController();
  final _deviceModelController = TextEditingController();
  final _devicePairedAtController =
      TextEditingController(text: DateTime.now().toUtc().toIso8601String());
  final _pairingCodeController = TextEditingController(text: 'DEMO-PAIR-001');

  @override
  void initState() {
    super.initState();
    _controller = ValidationConsoleController(sdk: widget.sdk);
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    _sessionAppIdController.dispose();
    _sessionExternalUserIdController.dispose();
    _sessionUserHashController.dispose();
    _sosMessageController.dispose();
    _sosTriggerSourceController.dispose();
    _telemetryLatitudeController.dispose();
    _telemetryLongitudeController.dispose();
    _telemetryAltitudeController.dispose();
    _telemetryDeviceIdController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    _contactEmailController.dispose();
    _contactPriorityController.dispose();
    _deviceHardwareIdController.dispose();
    _deviceFirmwareController.dispose();
    _deviceModelController.dispose();
    _devicePairedAtController.dispose();
    _pairingCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SDK Validation Console')),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final diagnostics = _controller.operationalDiagnostics;
          final session = _controller.session;
          final bridge = diagnostics.bridge;

          return SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  title: 'Validation Surface',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This app stays a thin host. All operational logic remains inside the SDK; this surface is only for validation, visibility, and controlled test actions.',
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: widget.onOpenTechnicalLab,
                        child: const Text('Open Technical Lab'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ConsoleSection(
                  title: '1. Session / Identity',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ValidationTextField(
                        controller: _sessionAppIdController,
                        label: 'appId',
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _sessionExternalUserIdController,
                        label: 'external user id',
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _sessionUserHashController,
                        label: 'userHash',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton(
                            onPressed: _controller.loadingSession
                                ? null
                                : _handleSetSession,
                            child: const Text('setSession'),
                          ),
                          ElevatedButton(
                            onPressed: _controller.loadingSession
                                ? null
                                : _controller.clearSession,
                            child: const Text('clearSession'),
                          ),
                          ElevatedButton(
                            onPressed: _controller.loadingSession
                                ? null
                                : _controller.refreshCanonicalIdentity,
                            child: const Text('refreshCanonicalIdentity'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      InfoLine(
                        label: 'Signed session',
                        value: session == null ? 'Not set' : 'Configured',
                      ),
                      InfoLine(label: 'appId', value: session?.appId ?? '-'),
                      InfoLine(
                        label: 'Session external user id',
                        value: session?.externalUserId ?? '-',
                      ),
                      InfoLine(
                        label: 'Canonical external_user_id',
                        value: session?.canonicalExternalUserId ?? 'Not resolved',
                      ),
                      InfoLine(
                        label: 'SDK user id',
                        value: session?.sdkUserId ?? '-',
                      ),
                      if (_controller.lastIdentityError != null) ...[
                        const SizedBox(height: 12),
                        DiagnosticsBox(
                          label: 'Last identity/auth error',
                          value: _controller.lastIdentityError!,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ConsoleSection(
                  title: '2. MQTT / Connectivity',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InfoLine(
                        label: 'MQTT connection state',
                        value: diagnostics.connectionState.name,
                      ),
                      InfoLine(
                        label: 'Current SOS topic subscription',
                        value: diagnostics.sosEventTopics.isEmpty
                            ? 'Unavailable until canonical identity is ready'
                            : diagnostics.sosEventTopics.join(', '),
                      ),
                      InfoLine(
                        label: 'Current TEL publish topic',
                        value: diagnostics.telemetryPublishTopic ??
                            'Unavailable until canonical identity is ready',
                      ),
                      InfoLine(
                        label: 'Operational bridge active',
                        value: bridge.isActive.toString(),
                      ),
                      InfoLine(
                        label: 'Operational publish available',
                        value: diagnostics.canPublishOperationally.toString(),
                      ),
                      InfoLine(
                        label: 'Last realtime event',
                        value: _controller.lastRealtimeEvent?.type ?? '-',
                      ),
                      InfoLine(
                        label: 'Last realtime timestamp',
                        value: formatDateTime(
                          _controller.lastRealtimeEvent?.timestamp,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ConsoleSection(
                  title: '3. SOS',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ValidationTextField(
                        controller: _sosMessageController,
                        label: 'SOS message',
                        maxLines: 2,
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _sosTriggerSourceController,
                        label: 'trigger source',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton(
                            onPressed:
                                _controller.loadingSos ? null : _handleTriggerSos,
                            child: const Text('triggerSos(payload)'),
                          ),
                          ElevatedButton(
                            onPressed:
                                _controller.loadingSos ? null : _controller.cancelSos,
                            child: const Text('cancelSos()'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      InfoLine(label: 'Current SOS state', value: _controller.sosState.name),
                      InfoLine(
                        label: 'Last SOS event',
                        value: _controller.lastSosEvent.runtimeType.toString(),
                      ),
                      InfoLine(
                        label: 'Incident ID',
                        value: _controller.lastSosIncident?.id ?? '-',
                      ),
                      InfoLine(
                        label: 'Pending SOS',
                        value: bridge.pendingSos == null
                            ? 'No'
                            : 'Yes (${bridge.pendingSos!.signature})',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ConsoleSection(
                  title: '4. Telemetry',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ValidationTextField(
                        controller: _telemetryLatitudeController,
                        label: 'latitude',
                        keyboardType: const TextInputType.numberWithOptions(
                          signed: true,
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _telemetryLongitudeController,
                        label: 'longitude',
                        keyboardType: const TextInputType.numberWithOptions(
                          signed: true,
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _telemetryAltitudeController,
                        label: 'altitude',
                        keyboardType: const TextInputType.numberWithOptions(
                          signed: true,
                          decimal: true,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _telemetryDeviceIdController,
                        label: 'deviceId',
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed:
                            _controller.loadingTelemetry ? null : _handlePublishTelemetry,
                        child: const Text('publishTelemetry(sample)'),
                      ),
                      const SizedBox(height: 12),
                      InfoLine(
                        label: 'Last published telemetry sample',
                        value: _controller.lastPublishedTelemetrySample == null
                            ? '-'
                            : _controller.lastPublishedTelemetrySample!.toJson().toString(),
                      ),
                      InfoLine(
                        label: 'Pending telemetry',
                        value: bridge.pendingTelemetry == null
                            ? 'No'
                            : 'Yes (${bridge.pendingTelemetry!.signature})',
                      ),
                      InfoLine(
                        label: 'Offline policy',
                        value: 'Latest sample wins',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ConsoleSection(
                  title: '5. Contacts',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ValidationTextField(
                        controller: _contactNameController,
                        label: 'name',
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _contactPhoneController,
                        label: 'phone',
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _contactEmailController,
                        label: 'email',
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _contactPriorityController,
                        label: 'priority',
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed:
                            _controller.loadingContacts ? null : _handleCreateContact,
                        child: const Text('createEmergencyContact(...)'),
                      ),
                      const SizedBox(height: 12),
                      InfoLine(
                        label: 'Total contacts',
                        value: _controller.contacts.length.toString(),
                      ),
                      const SizedBox(height: 8),
                      if (_controller.contacts.isEmpty)
                        const Text('No contacts loaded.')
                      else
                        ..._controller.contacts.map(
                          (contact) => ContactListTile(
                            contact: contact,
                            onEdit: () => _showEditContactDialog(contact),
                            onDelete: () => _controller.deleteContact(contact.id),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ConsoleSection(
                  title: '6. Backend Device Registry',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ValidationTextField(
                        controller: _deviceHardwareIdController,
                        label: 'hardware_id',
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _deviceFirmwareController,
                        label: 'firmware_version',
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _deviceModelController,
                        label: 'hardware_model',
                      ),
                      const SizedBox(height: 8),
                      ValidationTextField(
                        controller: _devicePairedAtController,
                        label: 'paired_at (ISO-8601)',
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: _controller.loadingDeviceRegistry
                            ? null
                            : _handleUpsertRegisteredDevice,
                        child: const Text('upsertRegisteredDevice(...)'),
                      ),
                      const SizedBox(height: 12),
                      InfoLine(
                        label: 'Registered devices',
                        value: _controller.registeredDevices.length.toString(),
                      ),
                      const SizedBox(height: 8),
                      if (_controller.registeredDevices.isEmpty)
                        const Text('No backend registry devices loaded.')
                      else
                        ..._controller.registeredDevices.map(
                          (device) => RegistryDeviceTile(
                            device: device,
                            onUseAsDraft: () => _seedDeviceDraft(device),
                            onDelete: () =>
                                _controller.deleteRegisteredDevice(device.id),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ConsoleSection(
                  title: '7. Local Device Runtime / BLE',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ValidationTextField(
                        controller: _pairingCodeController,
                        label: 'pairing code',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ElevatedButton(
                            onPressed: _controller.loadingDeviceRuntime
                                ? null
                                : _handleConnectDevice,
                            child: const Text('connectDevice(...)'),
                          ),
                          ElevatedButton(
                            onPressed: _controller.loadingDeviceRuntime
                                ? null
                                : _controller.disconnectDevice,
                            child: const Text('disconnectDevice()'),
                          ),
                          ElevatedButton(
                            onPressed: _controller.loadingDeviceRuntime
                                ? null
                                : _controller.refreshDeviceRuntime,
                            child: const Text('Refresh runtime'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      InfoLine(
                        label: 'deviceStatus.deviceId',
                        value: _controller.deviceStatus?.deviceId ?? '-',
                      ),
                      InfoLine(
                        label: 'Connected',
                        value: (_controller.deviceStatus?.connected ?? false)
                            .toString(),
                      ),
                      InfoLine(
                        label: 'Lifecycle',
                        value: _controller.deviceStatus?.lifecycleState.name ?? '-',
                      ),
                      InfoLine(
                        label: 'Firmware',
                        value: _controller.deviceStatus?.firmwareVersion ?? '-',
                      ),
                      InfoLine(
                        label: 'Preferred device',
                        value: _controller.preferredDevice == null
                            ? '-'
                            : '${_controller.preferredDevice!.deviceId} (${formatNullable(_controller.preferredDevice!.displayName)})',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ConsoleSection(
                  title: '8. Operational Bridge / Diagnostics',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InfoLine(
                        label: 'Last BLE TEL event',
                        value: bridge.lastBleTelemetryEventSummary ?? '-',
                      ),
                      InfoLine(
                        label: 'Last BLE SOS event',
                        value: bridge.lastBleSosEventSummary ?? '-',
                      ),
                      InfoLine(
                        label: 'Last bridge decision',
                        value: bridge.lastDecision ?? '-',
                      ),
                      InfoLine(
                        label: 'Last device command sent',
                        value: bridge.lastDeviceCommandSent ?? '-',
                      ),
                      const SizedBox(height: 8),
                      DiagnosticsBox(
                        label: 'Pending telemetry payload',
                        value: bridge.pendingTelemetry == null
                            ? 'None'
                            : bridge.pendingTelemetry!.payload.toJson().toString(),
                      ),
                      const SizedBox(height: 8),
                      DiagnosticsBox(
                        label: 'Pending SOS payload',
                        value: bridge.pendingSos == null
                            ? 'None'
                            : {
                                'signature': bridge.pendingSos!.signature,
                                'message': bridge.pendingSos!.message,
                                'position': {
                                  'latitude':
                                      bridge.pendingSos!.positionSnapshot.latitude,
                                  'longitude': bridge
                                      .pendingSos!.positionSnapshot.longitude,
                                  'altitude':
                                      bridge.pendingSos!.positionSnapshot.altitude,
                                  'timestamp': bridge
                                      .pendingSos!.positionSnapshot.timestamp
                                      .toIso8601String(),
                                },
                              }.toString(),
                      ),
                    ],
                  ),
                ),
                if (_controller.lastActionError != null) ...[
                  const SizedBox(height: 16),
                  SectionCard(
                    title: 'Last Action Error',
                    child: SelectableText(_controller.lastActionError!),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleSetSession() async {
    await _controller.setSession(
      EixamSession.signed(
        appId: _sessionAppIdController.text.trim(),
        externalUserId: _sessionExternalUserIdController.text.trim(),
        userHash: _sessionUserHashController.text.trim(),
      ),
    );
  }

  Future<void> _handleTriggerSos() async {
    await _controller.triggerSos(
      message: _sosMessageController.text,
      triggerSource: _sosTriggerSourceController.text,
    );
  }

  Future<void> _handlePublishTelemetry() async {
    try {
      final payload = SdkTelemetryPayload(
        timestamp: DateTime.now().toUtc(),
        latitude: double.parse(_telemetryLatitudeController.text.trim()),
        longitude: double.parse(_telemetryLongitudeController.text.trim()),
        altitude: double.parse(_telemetryAltitudeController.text.trim()),
        deviceId: _telemetryDeviceIdController.text.trim().isEmpty
            ? null
            : _telemetryDeviceIdController.text.trim(),
      );
      await _controller.publishTelemetry(payload);
    } catch (error) {
      _controller.reportActionError(error);
    }
  }

  Future<void> _handleCreateContact() async {
    await _controller.createContact(
      name: _contactNameController.text.trim(),
      phone: _contactPhoneController.text.trim(),
      email: _contactEmailController.text.trim(),
      priority: int.tryParse(_contactPriorityController.text.trim()) ?? 1,
    );
  }

  Future<void> _showEditContactDialog(EmergencyContact contact) async {
    final nameController = TextEditingController(text: contact.name);
    final phoneController = TextEditingController(text: contact.phone);
    final emailController = TextEditingController(text: contact.email);
    final priorityController =
        TextEditingController(text: contact.priority.toString());

    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Update contact'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValidationTextField(controller: nameController, label: 'name'),
                const SizedBox(height: 8),
                ValidationTextField(controller: phoneController, label: 'phone'),
                const SizedBox(height: 8),
                ValidationTextField(controller: emailController, label: 'email'),
                const SizedBox(height: 8),
                ValidationTextField(
                  controller: priorityController,
                  label: 'priority',
                  keyboardType: TextInputType.number,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    if (shouldSave == true) {
      await _controller.updateContact(
        contact.copyWith(
          name: nameController.text.trim(),
          phone: phoneController.text.trim(),
          email: emailController.text.trim(),
          priority: int.tryParse(priorityController.text.trim()) ?? 1,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }

    nameController.dispose();
    phoneController.dispose();
    emailController.dispose();
    priorityController.dispose();
  }

  Future<void> _handleUpsertRegisteredDevice() async {
    try {
      await _controller.upsertRegisteredDevice(
        hardwareId: _deviceHardwareIdController.text.trim(),
        firmwareVersion: _deviceFirmwareController.text.trim(),
        hardwareModel: _deviceModelController.text.trim(),
        pairedAt: DateTime.parse(_devicePairedAtController.text.trim()).toUtc(),
      );
    } catch (error) {
      _controller.reportActionError(error);
    }
  }

  void _seedDeviceDraft(BackendRegisteredDevice device) {
    _deviceHardwareIdController.text = device.hardwareId;
    _deviceFirmwareController.text = device.firmwareVersion;
    _deviceModelController.text = device.hardwareModel;
    _devicePairedAtController.text = device.pairedAt.toUtc().toIso8601String();
  }

  Future<void> _handleConnectDevice() async {
    await _controller.connectDevice(_pairingCodeController.text.trim());
  }
}
