import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/material.dart';

import '../../bootstrap/validation_backend_config.dart';
import '../../shared/presentation/info_line.dart';
import '../../shared/presentation/section_card.dart';
import 'operational_demo_sections.dart';
import 'validation_capability_card.dart';
import 'validation_console_controller.dart';
import 'validation_models.dart';
import 'validation_summary_card.dart';

class OperationalDemoScreen extends StatefulWidget {
  const OperationalDemoScreen({
    super.key,
    required this.sdk,
    required this.sdkGeneration,
    required this.backendConfig,
    required this.onApplyBackendConfig,
    required this.onOpenTechnicalLab,
  });

  final EixamConnectSdk sdk;
  final int sdkGeneration;
  final ValidationBackendConfig backendConfig;
  final Future<void> Function(ValidationBackendConfig config)
      onApplyBackendConfig;
  final VoidCallback onOpenTechnicalLab;

  @override
  State<OperationalDemoScreen> createState() => _OperationalDemoScreenState();
}

class _OperationalDemoScreenState extends State<OperationalDemoScreen> {
  late final ValidationConsoleController _controller;
  late final TextEditingController _sessionAppIdController;
  late final TextEditingController _sessionExternalUserIdController;
  late final TextEditingController _sessionUserHashController;
  final _sosMessageController =
      TextEditingController(text: 'Manual SOS from validation console');
  final _sosTriggerSourceController =
      TextEditingController(text: 'debug_validation_console');
  final _telemetryLatitudeController = TextEditingController(text: '41.3825');
  final _telemetryLongitudeController = TextEditingController(text: '2.1769');
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
  late final TextEditingController _apiBaseUrlController;
  late final TextEditingController _mqttUrlController;
  late ValidationBackendPreset _selectedBackendPreset;
  bool _applyingBackendConfig = false;

  @override
  void initState() {
    super.initState();
    _sessionAppIdController = TextEditingController(
      text: ValidationLocalDebugDefaults.isEnabled
          ? ValidationLocalDebugDefaults.appId
          : '',
    );
    _sessionExternalUserIdController = TextEditingController(
      text: ValidationLocalDebugDefaults.isEnabled
          ? ValidationLocalDebugDefaults.externalUserId
          : '',
    );
    _sessionUserHashController = TextEditingController(
      text: ValidationLocalDebugDefaults.isEnabled
          ? ValidationLocalDebugDefaults.userHash
          : '',
    );
    _controller = ValidationConsoleController(sdk: widget.sdk);
    _selectedBackendPreset = widget.backendConfig.preset;
    _apiBaseUrlController =
        TextEditingController(text: widget.backendConfig.apiBaseUrl);
    _mqttUrlController =
        TextEditingController(text: widget.backendConfig.mqttWebsocketUrl);
    _controller.initialize().then((_) {
      if (!mounted) {
        return;
      }
      _seedSessionDraftFromCurrentState();
    });
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
    _apiBaseUrlController.dispose();
    _mqttUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SDK Validation Console')),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final cards = _controller.buildMvpCapabilityCards(
            activeBackendConfig: widget.backendConfig,
            showsAndroidLocalhostWarning: _showsAndroidLocalhostWarning,
            backendApplyInProgress: _applyingBackendConfig,
            sdkGeneration: widget.sdkGeneration,
          );
          final summary = _controller.buildSummaryViewModel(
            activeBackendConfig: widget.backendConfig,
            showsAndroidLocalhostWarning: _showsAndroidLocalhostWarning,
            backendApplyInProgress: _applyingBackendConfig,
            sdkGeneration: widget.sdkGeneration,
          );

          return SafeArea(
            child: Stack(
              children: [
                AbsorbPointer(
                  absorbing: _applyingBackendConfig,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const SectionCard(
                        title: 'Validation Console MVP v1',
                        child: Text(
                          'Thin host validation surface for backend and operational SDK checks. Business logic stays in the SDK; this screen only drives capabilities, status evaluation, and diagnostics.',
                        ),
                      ),
                      const SizedBox(height: 16),
                      ValidationSummaryCard(summary: summary),
                      const SizedBox(height: 16),
                      ..._buildMvpCards(cards),
                      const SizedBox(height: 16),
                      _buildAdvancedSection(),
                    ],
                  ),
                ),
                if (_applyingBackendConfig)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildMvpCards(List<ValidationCardViewModel> cards) {
    return <Widget>[
      _buildBackendConfigurationCard(cards[0]),
      const SizedBox(height: 16),
      _buildSessionConfigurationCard(cards[1]),
      const SizedBox(height: 16),
      _buildHttpConnectivityCard(cards[2]),
      const SizedBox(height: 16),
      _buildMqttConnectivityCard(cards[3]),
      const SizedBox(height: 16),
      _buildTriggerSosCard(cards[4]),
      const SizedBox(height: 16),
      _buildCancelSosCard(cards[5]),
      const SizedBox(height: 16),
      _buildTelemetryCard(cards[6]),
      const SizedBox(height: 16),
      _buildContactsCard(cards[7]),
      const SizedBox(height: 16),
      _buildBackendReconfigureCard(cards[8]),
      if (_controller.lastActionError != null) ...[
        const SizedBox(height: 16),
        SectionCard(
          title: 'Last Action Error',
          child: SelectableText(_controller.lastActionError!),
        ),
      ],
    ];
  }

  Widget _buildBackendConfigurationCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        OutlinedButton(
          onPressed: _controller.refreshAll,
          child: const Text('Refresh diagnostics'),
        ),
        if (ValidationLocalDebugDefaults.isEnabled)
          OutlinedButton(
            onPressed: _loadLocalDebugDefaults,
            child: const Text('Load local debug defaults'),
          ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Android physical-device note: localhost points to the phone itself. Use a LAN IP or adb reverse when your backend runs on the workstation.',
          ),
        ],
      ),
    );
  }

  Widget _buildSessionConfigurationCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        ElevatedButton(
          onPressed: _controller.loadingSession ? null : _handleSetSession,
          child: const Text('Apply session'),
        ),
        OutlinedButton(
          onPressed: _controller.loadingSession
              ? null
              : _controller.refreshCanonicalIdentity,
          child: const Text('Refresh canonical identity'),
        ),
        OutlinedButton(
          onPressed:
              _controller.loadingSession ? null : _controller.clearSession,
          child: const Text('Clear session'),
        ),
        if (ValidationLocalDebugDefaults.isEnabled)
          OutlinedButton(
            onPressed: _loadLocalDebugDefaults,
            child: const Text('Reset local defaults'),
          ),
      ],
      child: Column(
        children: [
          ValidationTextField(
            controller: _sessionAppIdController,
            label: 'appId',
          ),
          const SizedBox(height: 8),
          ValidationTextField(
            controller: _sessionExternalUserIdController,
            label: 'externalUserId',
          ),
          const SizedBox(height: 8),
          ValidationTextField(
            controller: _sessionUserHashController,
            label: 'userHash',
          ),
        ],
      ),
    );
  }

  Widget _buildHttpConnectivityCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        ElevatedButton(
          onPressed: _controller.loadingSession
              ? null
              : _controller.runHttpConnectivityValidation,
          child: const Text('Run HTTP check'),
        ),
      ],
    );
  }

  Widget _buildMqttConnectivityCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        OutlinedButton(
          onPressed: _controller.refreshAll,
          child: const Text('Refresh diagnostics'),
        ),
        FilledButton(
          onPressed: widget.onOpenTechnicalLab,
          child: const Text('Open Technical Lab'),
        ),
      ],
      child: DiagnosticsBox(
        label: 'Last realtime payload',
        value: _controller.lastRealtimeEvent?.payload == null
            ? 'None'
            : _controller.lastRealtimeEvent!.payload.toString(),
      ),
    );
  }

  Widget _buildTriggerSosCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        ElevatedButton(
          onPressed:
              _controller.loadingSos ? null : _handleTriggerSosValidation,
          child: const Text('Run test'),
        ),
      ],
      child: Column(
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
        ],
      ),
    );
  }

  Widget _buildCancelSosCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        ElevatedButton(
          onPressed: _controller.loadingSos
              ? null
              : _controller.runCancelSosValidation,
          child: const Text('Run test'),
        ),
      ],
    );
  }

  Widget _buildTelemetryCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        ElevatedButton(
          onPressed:
              _controller.loadingTelemetry ? null : _handleTelemetryValidation,
          child: const Text('Run test'),
        ),
      ],
      child: Column(
        children: [
          ValidationTextField(
            controller: _telemetryLatitudeController,
            label: 'latitude',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          ValidationTextField(
            controller: _telemetryLongitudeController,
            label: 'longitude',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          ValidationTextField(
            controller: _telemetryAltitudeController,
            label: 'altitude',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          ValidationTextField(
            controller: _telemetryDeviceIdController,
            label: 'deviceId',
          ),
        ],
      ),
    );
  }

  Widget _buildContactsCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        ElevatedButton(
          onPressed: _controller.loadingContacts
              ? null
              : _controller.runContactsValidation,
          child: const Text('Run guided validation'),
        ),
        OutlinedButton(
          onPressed: _controller.loadingContacts ? null : _handleCreateContact,
          child: const Text('Create manual contact'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValidationTextField(
              controller: _contactNameController, label: 'name'),
          const SizedBox(height: 8),
          ValidationTextField(
              controller: _contactPhoneController, label: 'phone'),
          const SizedBox(height: 8),
          ValidationTextField(
              controller: _contactEmailController, label: 'email'),
          const SizedBox(height: 8),
          ValidationTextField(
            controller: _contactPriorityController,
            label: 'priority',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          if (_controller.contacts.isEmpty)
            const Text('No contacts loaded yet.')
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
    );
  }

  Widget _buildBackendReconfigureCard(ValidationCardViewModel card) {
    return ValidationCapabilityCard(
      viewModel: card,
      actions: <Widget>[
        ElevatedButton(
          onPressed: _applyingBackendConfig ? null : _handleApplyBackendConfig,
          child: Text(
            _applyingBackendConfig ? 'Applying backend...' : 'Apply backend',
          ),
        ),
      ],
      child: Column(
        children: [
          DropdownButtonFormField<ValidationBackendPreset>(
            initialValue: _selectedBackendPreset,
            decoration: const InputDecoration(
              labelText: 'Environment',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: ValidationBackendPreset.production,
                child: Text('Production'),
              ),
              DropdownMenuItem(
                value: ValidationBackendPreset.staging,
                child: Text('Staging'),
              ),
              DropdownMenuItem(
                value: ValidationBackendPreset.customLocal,
                child: Text('Custom local'),
              ),
              DropdownMenuItem(
                value: ValidationBackendPreset.custom,
                child: Text('Custom URL'),
              ),
            ],
            onChanged:
                _applyingBackendConfig ? null : _handleBackendPresetChanged,
          ),
          const SizedBox(height: 8),
          ValidationTextField(
            controller: _apiBaseUrlController,
            label: 'HTTP base URL',
            hintText: 'https://api.eixam.io',
          ),
          const SizedBox(height: 8),
          ValidationTextField(
            controller: _mqttUrlController,
            label: 'MQTT URL',
            hintText: 'tcp://127.0.0.1:1883',
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedSection() {
    final bridge = _controller.operationalDiagnostics.bridge;
    return SectionCard(
      title: 'Advanced / Later Scope',
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 12),
        title: const Text('BLE, device registry, and bridge diagnostics'),
        children: [
          _buildAdvancedRegistryCard(),
          const SizedBox(height: 16),
          _buildAdvancedBleCard(),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Operational Bridge / Diagnostics',
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
                  label: 'Last device command',
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
                            'longitude':
                                bridge.pendingSos!.positionSnapshot.longitude,
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
        ],
      ),
    );
  }

  Widget _buildAdvancedRegistryCard() {
    return SectionCard(
      title: 'Backend Device Registry',
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
          if (_controller.registeredDevices.isEmpty)
            const Text('No backend registry devices loaded.')
          else
            ..._controller.registeredDevices.map(
              (device) => RegistryDeviceTile(
                device: device,
                onUseAsDraft: () => _seedDeviceDraft(device),
                onDelete: () => _controller.deleteRegisteredDevice(device.id),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAdvancedBleCard() {
    return SectionCard(
      title: 'Local Device Runtime / BLE',
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
              OutlinedButton(
                onPressed: _controller.loadingDeviceRuntime
                    ? null
                    : _controller.disconnectDevice,
                child: const Text('disconnectDevice()'),
              ),
              OutlinedButton(
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
            value: (_controller.deviceStatus?.connected ?? false).toString(),
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

  Future<void> _handleTriggerSosValidation() async {
    await _controller.runTriggerSosValidation(
      message: _sosMessageController.text,
      triggerSource: _sosTriggerSourceController.text,
    );
  }

  Future<void> _handleTelemetryValidation() async {
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
      await _controller.runTelemetryValidation(payload);
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
                ValidationTextField(
                    controller: phoneController, label: 'phone'),
                const SizedBox(height: 8),
                ValidationTextField(
                    controller: emailController, label: 'email'),
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

  void _handleBackendPresetChanged(ValidationBackendPreset? preset) {
    if (preset == null) {
      return;
    }
    setState(() {
      _selectedBackendPreset = preset;
    });
    if (preset == ValidationBackendPreset.custom) {
      return;
    }
    final config = ValidationBackendConfig.presetFor(preset);
    _apiBaseUrlController.text = config.apiBaseUrl;
    _mqttUrlController.text = config.mqttWebsocketUrl;
  }

  Future<void> _handleApplyBackendConfig() async {
    final apiBaseUrl = _apiBaseUrlController.text.trim();
    final mqttUrl = _mqttUrlController.text.trim();
    if (apiBaseUrl.isEmpty || mqttUrl.isEmpty) {
      _controller.reportActionError(
        StateError('HTTP base URL and MQTT URL are both required.'),
      );
      return;
    }

    setState(() {
      _applyingBackendConfig = true;
    });
    debugPrint(
      'Validation console apply backend start -> api=$apiBaseUrl mqtt=$mqttUrl sdkHash=${identityHashCode(widget.sdk)}',
    );
    try {
      await widget.onApplyBackendConfig(
        ValidationBackendConfig(
          preset: _selectedBackendPreset,
          label: _labelForPreset(_selectedBackendPreset),
          apiBaseUrl: apiBaseUrl,
          mqttWebsocketUrl: mqttUrl,
        ),
      );
      debugPrint(
        'Validation console apply backend completed -> reloading validation surface expected',
      );
    } catch (error) {
      _controller.reportActionError(error);
    } finally {
      if (mounted) {
        setState(() {
          _applyingBackendConfig = false;
        });
      }
    }
  }

  bool get _showsAndroidLocalhostWarning {
    final combined = '${_apiBaseUrlController.text} ${_mqttUrlController.text}'
        .toLowerCase();
    return combined.contains('localhost') || combined.contains('127.0.0.1');
  }

  String _labelForPreset(ValidationBackendPreset preset) {
    switch (preset) {
      case ValidationBackendPreset.production:
        return 'Production';
      case ValidationBackendPreset.staging:
        return 'Staging';
      case ValidationBackendPreset.customLocal:
        return 'Custom local';
      case ValidationBackendPreset.custom:
        return 'Custom URL';
    }
  }

  void _seedSessionDraftFromCurrentState() {
    final session = _controller.session;
    if (session != null) {
      _sessionAppIdController.text = session.appId;
      _sessionExternalUserIdController.text = session.externalUserId;
      _sessionUserHashController.text = session.userHash;
      return;
    }

    if (ValidationLocalDebugDefaults.isEnabled) {
      _sessionAppIdController.text = ValidationLocalDebugDefaults.appId;
      _sessionExternalUserIdController.text =
          ValidationLocalDebugDefaults.externalUserId;
      _sessionUserHashController.text = ValidationLocalDebugDefaults.userHash;
    }
  }

  void _loadLocalDebugDefaults() {
    final config = ValidationBackendConfig.customLocal;
    setState(() {
      _selectedBackendPreset = ValidationBackendPreset.customLocal;
      _apiBaseUrlController.text = config.apiBaseUrl;
      _mqttUrlController.text = config.mqttWebsocketUrl;
      _sessionAppIdController.text = ValidationLocalDebugDefaults.appId;
      _sessionExternalUserIdController.text =
          ValidationLocalDebugDefaults.externalUserId;
      _sessionUserHashController.text = ValidationLocalDebugDefaults.userHash;
    });
  }
}
