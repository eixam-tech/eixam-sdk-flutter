import 'dart:async';

import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const PartnerExampleApp());
}

class PartnerExampleApp extends StatelessWidget {
  const PartnerExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'EIXAM Partner Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B6E4F)),
        useMaterial3: true,
      ),
      home: const PartnerExampleHomePage(),
    );
  }
}

class PartnerExampleHomePage extends StatefulWidget {
  const PartnerExampleHomePage({super.key});

  @override
  State<PartnerExampleHomePage> createState() => _PartnerExampleHomePageState();
}

class _PartnerExampleHomePageState extends State<PartnerExampleHomePage> {
  final TextEditingController _appIdController = TextEditingController(
    text: 'partner-app',
  );
  final TextEditingController _externalUserIdController =
      TextEditingController(text: 'partner-user-123');
  final TextEditingController _userHashController = TextEditingController(
    text: 'signed-session-hash',
  );
  final TextEditingController _customApiBaseUrlController =
      TextEditingController(
    text: 'https://partner-api.example.com',
  );
  final TextEditingController _customWebsocketUrlController =
      TextEditingController(
    text: 'ssl://partner-mqtt.example.com:8883',
  );
  final TextEditingController _pairingCodeController = TextEditingController(
    text: 'PAIR-CODE-001',
  );
  final TextEditingController _activationCodeController = TextEditingController(
    text: 'ACTIVATION-CODE-001',
  );
  final TextEditingController _contactNameController = TextEditingController(
    text: 'Alice Doe',
  );
  final TextEditingController _contactPhoneController = TextEditingController(
    text: '+34123456789',
  );
  final TextEditingController _contactEmailController = TextEditingController(
    text: 'alice@example.com',
  );
  final TextEditingController _sosMessageController = TextEditingController(
    text: 'Need help now',
  );

  EixamConnectSdk? _sdk;
  StreamSubscription<SosState>? _sosStateSubscription;
  StreamSubscription<DeviceStatus>? _deviceStatusSubscription;
  StreamSubscription<List<EmergencyContact>>? _contactsSubscription;
  StreamSubscription<SdkOperationalDiagnostics>? _diagnosticsSubscription;

  EixamEnvironment _environment = EixamEnvironment.sandbox;
  bool _includeInitialSession = true;

  bool _bootstrapping = false;
  bool _requestingPermissions = false;
  bool _runningDeviceAction = false;
  bool _savingContact = false;
  bool _runningSosAction = false;
  bool _refreshingDiagnostics = false;
  bool _clearingSession = false;

  String? _statusMessage;
  String? _errorMessage;

  SosState _sosState = SosState.idle;
  DeviceStatus? _deviceStatus;
  PermissionState? _permissionState;
  EixamSession? _session;
  List<EmergencyContact> _contacts = const <EmergencyContact>[];
  SdkOperationalDiagnostics _diagnostics = const SdkOperationalDiagnostics(
    connectionState: RealtimeConnectionState.disconnected,
    bridge: SdkBridgeDiagnostics(),
  );

  bool get _hasSdk => _sdk != null;
  bool get _isCustomEnvironment => _environment == EixamEnvironment.custom;

  @override
  void dispose() {
    _sosStateSubscription?.cancel();
    _deviceStatusSubscription?.cancel();
    _contactsSubscription?.cancel();
    _diagnosticsSubscription?.cancel();
    _appIdController.dispose();
    _externalUserIdController.dispose();
    _userHashController.dispose();
    _customApiBaseUrlController.dispose();
    _customWebsocketUrlController.dispose();
    _pairingCodeController.dispose();
    _activationCodeController.dispose();
    _contactNameController.dispose();
    _contactPhoneController.dispose();
    _contactEmailController.dispose();
    _sosMessageController.dispose();
    super.dispose();
  }

  Future<void> _bootstrapSdk() async {
    setState(() {
      _bootstrapping = true;
      _errorMessage = null;
      _statusMessage = 'Bootstrapping SDK...';
    });

    try {
      // Partners bootstrap the SDK in one call with app identity and target
      // environment. The SDK handles internal endpoint resolution.
      final sdk = await EixamConnectSdk.bootstrap(
        EixamBootstrapConfig(
          appId: _appIdController.text.trim(),
          environment: _environment,
          initialSession: _includeInitialSession
              ? EixamSession.signed(
                  appId: _appIdController.text.trim(),
                  externalUserId: _externalUserIdController.text.trim(),
                  userHash: _userHashController.text.trim(),
                )
              : null,
          customEndpoints: _isCustomEnvironment
              ? EixamCustomEndpoints(
                  apiBaseUrl: _customApiBaseUrlController.text.trim(),
                  websocketUrl: _customWebsocketUrlController.text.trim(),
                )
              : null,
        ),
      );

      await _bindSdk(sdk);
      await _refreshSnapshot();

      setState(() {
        _statusMessage = 'SDK ready.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _bootstrapping = false;
        });
      }
    }
  }

  Future<void> _bindSdk(EixamConnectSdk sdk) async {
    await _sosStateSubscription?.cancel();
    await _deviceStatusSubscription?.cancel();
    await _contactsSubscription?.cancel();
    await _diagnosticsSubscription?.cancel();

    _sdk = sdk;

    // The host app listens to the public SDK streams and renders that state
    // inside its own UI.
    _sosStateSubscription = sdk.currentSosStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _sosState = state;
      });
    });

    _deviceStatusSubscription = sdk.deviceStatusStream.listen((status) {
      if (!mounted) return;
      setState(() {
        _deviceStatus = status;
      });
    });

    _contactsSubscription = sdk.watchEmergencyContacts().listen((contacts) {
      if (!mounted) return;
      setState(() {
        _contacts = contacts;
      });
    });

    _diagnosticsSubscription =
        sdk.watchOperationalDiagnostics().listen((diagnostics) {
      if (!mounted) return;
      setState(() {
        _diagnostics = diagnostics;
        _session = diagnostics.session;
      });
    });
  }

  Future<void> _clearSession() async {
    final sdk = _sdk;
    if (sdk == null) return;

    setState(() {
      _clearingSession = true;
      _errorMessage = null;
      _statusMessage = 'Clearing session...';
    });

    try {
      await sdk.clearSession();
      await _refreshSnapshot();
      setState(() {
        _statusMessage = 'Session cleared.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _clearingSession = false;
        });
      }
    }
  }

  Future<void> _requestPermissions() async {
    final sdk = _sdk;
    if (sdk == null) return;

    setState(() {
      _requestingPermissions = true;
      _errorMessage = null;
      _statusMessage = 'Requesting permissions...';
    });

    try {
      // The host UI can request the runtime permissions through the SDK.
      await sdk.requestLocationPermission();
      await sdk.requestNotificationPermission();
      _permissionState = await sdk.requestBluetoothPermission();
      setState(() {
        _statusMessage = 'Permissions updated.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _requestingPermissions = false;
        });
      }
    }
  }

  Future<void> _connectDevice() async {
    final sdk = _sdk;
    if (sdk == null) return;

    setState(() {
      _runningDeviceAction = true;
      _errorMessage = null;
      _statusMessage = 'Connecting device...';
    });

    try {
      // Device connection stays explicit and user-driven after bootstrap.
      _deviceStatus = await sdk.connectDevice(
        pairingCode: _pairingCodeController.text.trim(),
      );
      await _refreshSnapshot();
      setState(() {
        _statusMessage = 'Device connected.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _runningDeviceAction = false;
        });
      }
    }
  }

  Future<void> _activateDevice() async {
    final sdk = _sdk;
    if (sdk == null) return;

    setState(() {
      _runningDeviceAction = true;
      _errorMessage = null;
      _statusMessage = 'Activating device...';
    });

    try {
      // Activation remains an explicit public SDK call when the product flow
      // requires it.
      _deviceStatus = await sdk.activateDevice(
        activationCode: _activationCodeController.text.trim(),
      );
      await _refreshSnapshot();
      setState(() {
        _statusMessage = 'Device activated.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _runningDeviceAction = false;
        });
      }
    }
  }

  Future<void> _saveContact() async {
    final sdk = _sdk;
    if (sdk == null) return;

    setState(() {
      _savingContact = true;
      _errorMessage = null;
      _statusMessage = 'Saving contact...';
    });

    try {
      // Emergency contacts are managed through the public facade.
      await sdk.createEmergencyContact(
        name: _contactNameController.text.trim(),
        phone: _contactPhoneController.text.trim(),
        email: _contactEmailController.text.trim(),
      );
      await _refreshSnapshot();
      setState(() {
        _statusMessage = 'Contact saved.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingContact = false;
        });
      }
    }
  }

  Future<void> _deleteContact(String contactId) async {
    final sdk = _sdk;
    if (sdk == null) return;

    setState(() {
      _savingContact = true;
      _errorMessage = null;
      _statusMessage = 'Deleting contact...';
    });

    try {
      await sdk.deleteEmergencyContact(contactId);
      await _refreshSnapshot();
      setState(() {
        _statusMessage = 'Contact deleted.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _savingContact = false;
        });
      }
    }
  }

  Future<void> _triggerSos() async {
    final sdk = _sdk;
    if (sdk == null) return;

    setState(() {
      _runningSosAction = true;
      _errorMessage = null;
      _statusMessage = 'Triggering SOS...';
    });

    try {
      // SOS is triggered from partner-owned UI through the public SDK facade.
      await sdk.triggerSos(
        SosTriggerPayload(
          message: _sosMessageController.text.trim(),
          triggerSource: 'partner_example_app',
        ),
      );
      await _refreshSnapshot();
      setState(() {
        _statusMessage = 'SOS triggered.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _runningSosAction = false;
        });
      }
    }
  }

  Future<void> _cancelSos() async {
    final sdk = _sdk;
    if (sdk == null) return;

    setState(() {
      _runningSosAction = true;
      _errorMessage = null;
      _statusMessage = 'Cancelling SOS...';
    });

    try {
      await sdk.cancelSos();
      await _refreshSnapshot();
      setState(() {
        _statusMessage = 'SOS cancelled.';
      });
    } catch (error) {
      setState(() {
        _errorMessage = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _runningSosAction = false;
        });
      }
    }
  }

  Future<void> _refreshSnapshot() async {
    final sdk = _sdk;
    if (sdk == null) return;

    try {
      final session = await sdk.getCurrentSession();
      final permissionState = await sdk.getPermissionState();
      final deviceStatus = await sdk.getDeviceStatus();
      final contacts = await sdk.listEmergencyContacts();
      final diagnostics = await sdk.getOperationalDiagnostics();
      final sosState = await sdk.getSosState();

      if (!mounted) return;
      setState(() {
        _session = session;
        _permissionState = permissionState;
        _deviceStatus = deviceStatus;
        _contacts = contacts;
        _diagnostics = diagnostics;
        _sosState = sosState;
      });
    } catch (_) {
      // Keep refresh lightweight and let action handlers surface errors.
    }
  }

  Future<void> _refreshDiagnostics() async {
    setState(() {
      _refreshingDiagnostics = true;
      _errorMessage = null;
      _statusMessage = 'Refreshing diagnostics...';
    });

    try {
      await _refreshSnapshot();
      setState(() {
        _statusMessage = 'Diagnostics refreshed.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _refreshingDiagnostics = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('EIXAM Partner Example'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This example is a minimal partner smoke-test app: bootstrap the SDK, request permissions, and then validate a core flow such as device connect, SOS, or diagnostics.',
          ),
          const SizedBox(height: 16),
          const _JourneyBanner(
            title: 'Primary Smoke-Test Path',
            steps: <String>[
              '1. Bootstrap the SDK',
              '2. Confirm the signed session',
              '3. Request permissions',
              '4. Validate one core flow: diagnostics, device connect, or SOS',
            ],
          ),
          const SizedBox(height: 16),
          _SectionCard(
            title: '1. Bootstrap SDK',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Use the public bootstrap call with the EIXAM appId and environment assigned during onboarding.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _appIdController,
                  decoration: const InputDecoration(labelText: 'appId'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<EixamEnvironment>(
                  initialValue: _environment,
                  decoration: const InputDecoration(
                    labelText: 'Environment',
                  ),
                  items: EixamEnvironment.values
                      .map(
                        (environment) => DropdownMenuItem<EixamEnvironment>(
                          value: environment,
                          child: Text(environment.name),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() {
                      _environment = value;
                    });
                  },
                ),
                if (_isCustomEnvironment) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _customApiBaseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Custom API base URL',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _customWebsocketUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Custom realtime broker URI',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _includeInitialSession,
                  title: const Text('Include initial signed session'),
                  subtitle: const Text(
                    'Disable this if your app bootstraps first and applies the session later. Keep app secrets on your backend and pass only the signed session to the app.',
                  ),
                  onChanged: (value) {
                    setState(() {
                      _includeInitialSession = value;
                    });
                  },
                ),
                if (_includeInitialSession) ...[
                  TextField(
                    controller: _externalUserIdController,
                    decoration: const InputDecoration(
                      labelText: 'externalUserId',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _userHashController,
                    decoration: const InputDecoration(
                      labelText: 'Signed session value',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed: _bootstrapping ? null : _bootstrapSdk,
                      child: Text(
                        _bootstrapping ? 'Bootstrapping...' : 'Bootstrap SDK',
                      ),
                    ),
                    OutlinedButton(
                      onPressed:
                          !_hasSdk || _clearingSession ? null : _clearSession,
                      child: Text(
                        _clearingSession ? 'Clearing...' : 'Clear Session',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _InfoLine(
                  label: 'Current session',
                  value: _session == null
                      ? 'Not set'
                      : '${_session!.appId} / ${_session!.externalUserId}',
                ),
              ],
            ),
          ),
          _SectionCard(
            title: '2. Request Permissions',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton(
                  onPressed: !_hasSdk || _requestingPermissions
                      ? null
                      : _requestPermissions,
                  child: Text(
                    _requestingPermissions
                        ? 'Requesting...'
                        : 'Request Permissions',
                  ),
                ),
                const SizedBox(height: 8),
                _InfoLine(
                  label: 'Location',
                  value: _permissionState?.location.name ?? '-',
                ),
                _InfoLine(
                  label: 'Bluetooth',
                  value: _permissionState?.bluetooth.name ?? '-',
                ),
                _InfoLine(
                  label: 'Notifications',
                  value: _permissionState?.notifications.name ?? '-',
                ),
              ],
            ),
          ),
          _SectionCard(
            title: '3. Core Flow: Diagnostics',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Fastest smoke test after bootstrap: confirm the SDK is alive and streams are updating.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: !_hasSdk || _refreshingDiagnostics
                      ? null
                      : _refreshDiagnostics,
                  child: Text(
                    _refreshingDiagnostics
                        ? 'Refreshing...'
                        : 'Refresh Diagnostics',
                  ),
                ),
                const SizedBox(height: 8),
                _InfoLine(
                  label: 'Realtime',
                  value: _diagnostics.connectionState.name,
                ),
                _InfoLine(
                  label: 'Bridge active',
                  value: _diagnostics.bridge.isActive.toString(),
                ),
                _InfoLine(
                  label: 'Pending SOS',
                  value: (_diagnostics.bridge.pendingSos != null).toString(),
                ),
                _InfoLine(
                  label: 'Pending telemetry',
                  value:
                      (_diagnostics.bridge.pendingTelemetry != null).toString(),
                ),
                _InfoLine(
                  label: 'Last bridge decision',
                  value: _diagnostics.bridge.lastDecision ?? '-',
                ),
              ],
            ),
          ),
          const _SectionLabel(
            title: 'Advanced Public SDK Sections',
            body:
                'These sections remain available for broader manual validation, but they are not required for a minimal partner smoke test.',
          ),
          _SectionCard(
            title: '4. Device Lifecycle',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _pairingCodeController,
                  decoration: const InputDecoration(labelText: 'Pairing code'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed:
                      !_hasSdk || _runningDeviceAction ? null : _connectDevice,
                  child: Text(
                    _runningDeviceAction ? 'Working...' : 'Connect Device',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _activationCodeController,
                  decoration:
                      const InputDecoration(labelText: 'Activation code'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed:
                      !_hasSdk || _runningDeviceAction ? null : _activateDevice,
                  child: const Text('Activate Device'),
                ),
                const SizedBox(height: 8),
                _InfoLine(
                  label: 'Device ID',
                  value: _deviceStatus?.deviceId ?? '-',
                ),
                _InfoLine(
                  label: 'Connected',
                  value: (_deviceStatus?.connected ?? false).toString(),
                ),
                _InfoLine(
                  label: 'Activated',
                  value: (_deviceStatus?.activated ?? false).toString(),
                ),
                _InfoLine(
                  label: 'Lifecycle',
                  value: _deviceStatus?.lifecycleState.name ?? '-',
                ),
              ],
            ),
          ),
          _SectionCard(
            title: '5. Emergency Contacts',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _contactNameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contactPhoneController,
                  decoration: const InputDecoration(labelText: 'Phone'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _contactEmailController,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: !_hasSdk || _savingContact ? null : _saveContact,
                  child: Text(_savingContact ? 'Saving...' : 'Save Contact'),
                ),
                const SizedBox(height: 12),
                if (_contacts.isEmpty)
                  const Text('No emergency contacts yet.')
                else
                  Column(
                    children: _contacts
                        .map(
                          (contact) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(contact.name),
                            subtitle:
                                Text('${contact.phone} | ${contact.email}'),
                            trailing: TextButton(
                              onPressed: _savingContact
                                  ? null
                                  : () => _deleteContact(contact.id),
                              child: const Text('Delete'),
                            ),
                          ),
                        )
                        .toList(growable: false),
                  ),
              ],
            ),
          ),
          _SectionCard(
            title: '6. SOS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _sosMessageController,
                  decoration: const InputDecoration(labelText: 'SOS message'),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton(
                      onPressed:
                          !_hasSdk || _runningSosAction ? null : _triggerSos,
                      child: Text(
                        _runningSosAction ? 'Working...' : 'Trigger SOS',
                      ),
                    ),
                    OutlinedButton(
                      onPressed:
                          !_hasSdk || _runningSosAction ? null : _cancelSos,
                      child: const Text('Cancel SOS'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _InfoLine(label: 'SOS state', value: _sosState.name),
              ],
            ),
          ),
          _SectionCard(
            title: '7. Diagnostics and Streams',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Use this section when you want a broader view of operational state after the primary smoke test passes.',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: !_hasSdk || _refreshingDiagnostics
                      ? null
                      : _refreshDiagnostics,
                  child: Text(
                    _refreshingDiagnostics
                        ? 'Refreshing...'
                        : 'Refresh Diagnostics',
                  ),
                ),
                const SizedBox(height: 8),
                _InfoLine(
                  label: 'Realtime',
                  value: _diagnostics.connectionState.name,
                ),
                _InfoLine(
                  label: 'Bridge active',
                  value: _diagnostics.bridge.isActive.toString(),
                ),
                _InfoLine(
                  label: 'Pending SOS',
                  value: (_diagnostics.bridge.pendingSos != null).toString(),
                ),
                _InfoLine(
                  label: 'Pending telemetry',
                  value:
                      (_diagnostics.bridge.pendingTelemetry != null).toString(),
                ),
                _InfoLine(
                  label: 'Last bridge decision',
                  value: _diagnostics.bridge.lastDecision ?? '-',
                ),
              ],
            ),
          ),
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _statusMessage!,
                style: const TextStyle(color: Color(0xFF0B6E4F)),
              ),
            ),
          if (_errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _JourneyBanner extends StatelessWidget {
  const _JourneyBanner({
    required this.title,
    required this.steps,
  });

  final String title;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F4EE),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...steps.map((step) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(step),
              )),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(body),
        ],
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
