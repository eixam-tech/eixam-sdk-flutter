import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import '../../bootstrap/validation_backend_config.dart';
import 'validation_models.dart';

class ValidationConsoleController extends ChangeNotifier {
  ValidationConsoleController({required this.sdk});

  final EixamConnectSdk sdk;

  EixamSession? session;
  SdkOperationalDiagnostics operationalDiagnostics =
      const SdkOperationalDiagnostics(
    connectionState: RealtimeConnectionState.disconnected,
    bridge: SdkBridgeDiagnostics(),
  );
  RealtimeEvent? lastRealtimeEvent;
  SosState sosState = SosState.idle;
  EixamSdkEvent? lastSosEvent;
  SosIncident? lastSosIncident;
  SdkTelemetryPayload? lastPublishedTelemetrySample;
  List<EmergencyContact> contacts = const <EmergencyContact>[];
  List<BackendRegisteredDevice> registeredDevices =
      const <BackendRegisteredDevice>[];
  DeviceStatus? deviceStatus;
  PreferredDevice? preferredDevice;
  String? lastIdentityError;
  String? lastActionError;

  bool loadingSession = false;
  bool loadingSos = false;
  bool loadingTelemetry = false;
  bool loadingContacts = false;
  bool loadingDeviceRegistry = false;
  bool loadingDeviceRuntime = false;

  final Map<ValidationCapabilityId, ValidationCapabilityResult>
      _capabilityRuns = <ValidationCapabilityId, ValidationCapabilityResult>{};

  StreamSubscription<SdkOperationalDiagnostics>? _operationalSub;
  StreamSubscription<RealtimeEvent>? _realtimeSub;
  StreamSubscription<SosState>? _sosStateSub;
  StreamSubscription<EixamSdkEvent>? _sosEventSub;
  StreamSubscription<List<EmergencyContact>>? _contactsSub;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;

  Future<void> initialize() async {
    _bindStreams();
    await refreshAll();
  }

  void _bindStreams() {
    _operationalSub ??= sdk.watchOperationalDiagnostics().listen(
      (diagnostics) {
        operationalDiagnostics = diagnostics;
        session = diagnostics.session;
        notifyListeners();
      },
      onError: _handleActionError,
    );
    _realtimeSub ??= sdk.watchRealtimeEvents().listen(
      (event) {
        lastRealtimeEvent = event;
        notifyListeners();
      },
      onError: _handleActionError,
    );
    _sosStateSub ??= sdk.currentSosStateStream.listen(
      (state) {
        sosState = state;
        notifyListeners();
      },
      onError: _handleActionError,
    );
    _sosEventSub ??= sdk.lastSosEventStream.listen(
      (event) {
        lastSosEvent = event;
        notifyListeners();
      },
      onError: _handleActionError,
    );
    _contactsSub ??= sdk.watchEmergencyContacts().listen(
      (items) {
        contacts = items;
        notifyListeners();
      },
      onError: _handleActionError,
    );
    _deviceStatusSub ??= sdk.deviceStatusStream.listen(
      (status) {
        deviceStatus = status;
        notifyListeners();
      },
      onError: _handleActionError,
    );
  }

  Future<void> refreshAll() async {
    try {
      session = await sdk.getCurrentSession();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
      lastRealtimeEvent = await sdk.getLastRealtimeEvent();
      sosState = await sdk.getSosState();
      contacts = await sdk.listEmergencyContacts();
      registeredDevices = await sdk.listRegisteredDevices();
      deviceStatus = await sdk.getDeviceStatus();
      preferredDevice = await sdk.preferredDevice;
      notifyListeners();
    } catch (error) {
      _handleActionError(error);
    }
  }

  Future<void> setSession(EixamSession nextSession) async {
    await _runSessionAction(() async {
      await sdk.setSession(nextSession);
      session = await sdk.getCurrentSession();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
      _recordCapabilityResult(
        ValidationCapabilityId.sessionConfiguration,
        _buildSessionResult(),
      );
      _recordCapabilityResult(
        ValidationCapabilityId.httpConnectivity,
        _buildHttpResult(),
      );
    });
  }

  Future<void> clearSession() async {
    await _runSessionAction(() async {
      await sdk.clearSession();
      session = await sdk.getCurrentSession();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
      _recordCapabilityResult(
        ValidationCapabilityId.sessionConfiguration,
        const ValidationCapabilityResult(status: ValidationRunStatus.notRun),
      );
      _recordCapabilityResult(
        ValidationCapabilityId.httpConnectivity,
        const ValidationCapabilityResult(status: ValidationRunStatus.notRun),
      );
    });
  }

  Future<void> refreshCanonicalIdentity() async {
    await _runSessionAction(() async {
      session = await sdk.refreshCanonicalIdentity();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
      _recordCapabilityResult(
        ValidationCapabilityId.sessionConfiguration,
        _buildSessionResult(),
      );
      _recordCapabilityResult(
        ValidationCapabilityId.httpConnectivity,
        _buildHttpResult(),
      );
    });
  }

  Future<void> runHttpConnectivityValidation() async {
    _recordCapabilityResult(
      ValidationCapabilityId.httpConnectivity,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.running,
        diagnosticText: 'Refreshing canonical identity against the backend...',
      ),
    );
    await refreshCanonicalIdentity();
  }

  Future<void> triggerSos({
    required String message,
    required String triggerSource,
  }) async {
    await _runAction((value) => loadingSos = value, () async {
      lastSosIncident = await sdk.triggerSos(
        SosTriggerPayload(
          message: message.trim().isEmpty ? null : message.trim(),
          triggerSource: triggerSource.trim().isEmpty
              ? 'debug_validation_console'
              : triggerSource.trim(),
        ),
      );
      sosState = await sdk.getSosState();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
    });
  }

  Future<void> runTriggerSosValidation({
    required String message,
    required String triggerSource,
  }) async {
    _recordCapabilityResult(
      ValidationCapabilityId.triggerSos,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.running,
        diagnosticText: 'Triggering SOS through the public SDK facade...',
      ),
    );
    await triggerSos(message: message, triggerSource: triggerSource);
    _recordCapabilityResult(
      ValidationCapabilityId.triggerSos,
      _buildTriggerSosResult(),
    );
  }

  Future<void> cancelSos() async {
    await _runAction((value) => loadingSos = value, () async {
      lastSosIncident = await sdk.cancelSos();
      sosState = await sdk.getSosState();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
    });
  }

  Future<void> runCancelSosValidation() async {
    _recordCapabilityResult(
      ValidationCapabilityId.cancelSos,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.running,
        diagnosticText: 'Requesting SOS cancellation through the SDK...',
      ),
    );
    await cancelSos();
    _recordCapabilityResult(
      ValidationCapabilityId.cancelSos,
      _buildCancelSosResult(),
    );
  }

  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    await _runAction((value) => loadingTelemetry = value, () async {
      await sdk.publishTelemetry(payload);
      lastPublishedTelemetrySample = payload;
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
    });
  }

  Future<void> runTelemetryValidation(SdkTelemetryPayload payload) async {
    _recordCapabilityResult(
      ValidationCapabilityId.telemetrySample,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.running,
        diagnosticText: 'Publishing telemetry sample through the SDK...',
      ),
    );
    await publishTelemetry(payload);
    _recordCapabilityResult(
      ValidationCapabilityId.telemetrySample,
      _buildTelemetryResult(),
    );
  }

  Future<void> createContact({
    required String name,
    required String phone,
    required String email,
    required int priority,
  }) async {
    await _runAction((value) => loadingContacts = value, () async {
      await sdk.createEmergencyContact(
        name: name,
        phone: phone,
        email: email,
        priority: priority,
      );
      contacts = await sdk.listEmergencyContacts();
    });
  }

  Future<void> runContactsValidation() async {
    _recordCapabilityResult(
      ValidationCapabilityId.contacts,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.running,
        diagnosticText:
            'Ensuring the guided validation contact is available...',
      ),
    );

    final signature = _validationContactSignature();
    final existing = contacts.where(
      (contact) =>
          contact.email.trim().toLowerCase() == signature.email.toLowerCase(),
    );

    if (existing.isEmpty) {
      await createContact(
        name: signature.name,
        phone: signature.phone,
        email: signature.email,
        priority: 1,
      );
    } else {
      contacts = await sdk.listEmergencyContacts();
      notifyListeners();
    }

    final isVisible = contacts.any(
      (contact) =>
          contact.email.trim().toLowerCase() == signature.email.toLowerCase(),
    );

    _recordCapabilityResult(
      ValidationCapabilityId.contacts,
      ValidationCapabilityResult(
        status: isVisible ? ValidationRunStatus.ok : ValidationRunStatus.nok,
        diagnosticText: isVisible
            ? 'Guided validation contact is present in the backend-backed list.'
            : 'Guided validation contact was not visible after refresh.',
        lastExecutedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> updateContact(EmergencyContact contact) async {
    await _runAction((value) => loadingContacts = value, () async {
      await sdk.updateEmergencyContact(contact);
      contacts = await sdk.listEmergencyContacts();
    });
  }

  Future<void> deleteContact(String contactId) async {
    await _runAction((value) => loadingContacts = value, () async {
      await sdk.deleteEmergencyContact(contactId);
      contacts = await sdk.listEmergencyContacts();
    });
  }

  Future<void> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    await _runAction((value) => loadingDeviceRegistry = value, () async {
      await sdk.upsertRegisteredDevice(
        hardwareId: hardwareId,
        firmwareVersion: firmwareVersion,
        hardwareModel: hardwareModel,
        pairedAt: pairedAt,
      );
      registeredDevices = await sdk.listRegisteredDevices();
    });
  }

  Future<void> deleteRegisteredDevice(String deviceId) async {
    await _runAction((value) => loadingDeviceRegistry = value, () async {
      await sdk.deleteRegisteredDevice(deviceId);
      registeredDevices = await sdk.listRegisteredDevices();
    });
  }

  Future<void> connectDevice(String pairingCode) async {
    await _runAction((value) => loadingDeviceRuntime = value, () async {
      deviceStatus = await sdk.connectDevice(pairingCode: pairingCode);
      preferredDevice = await sdk.preferredDevice;
    });
  }

  Future<void> disconnectDevice() async {
    await _runAction((value) => loadingDeviceRuntime = value, () async {
      await sdk.disconnectDevice();
      deviceStatus = await sdk.getDeviceStatus();
      preferredDevice = await sdk.preferredDevice;
    });
  }

  Future<void> refreshDeviceRuntime() async {
    await _runAction((value) => loadingDeviceRuntime = value, () async {
      deviceStatus = await sdk.refreshDeviceStatus();
      preferredDevice = await sdk.preferredDevice;
    });
  }

  List<ValidationCardViewModel> buildMvpCapabilityCards({
    required ValidationBackendConfig activeBackendConfig,
    required bool showsAndroidLocalhostWarning,
    required bool backendApplyInProgress,
    required int sdkGeneration,
  }) {
    return <ValidationCardViewModel>[
      ValidationCardViewModel(
        id: ValidationCapabilityId.backendConfiguration,
        title: '1. Backend configuration',
        description:
            'Confirm the currently active backend setup before running operational validation.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'A valid HTTP base URL and MQTT URL are active for the current SDK instance.',
          howToValidate:
              'Review the active backend snapshot and confirm it matches the environment you intend to test.',
        ),
        result: _buildBackendConfigurationResult(
          activeBackendConfig: activeBackendConfig,
          showsAndroidLocalhostWarning: showsAndroidLocalhostWarning,
        ),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Preset', value: activeBackendConfig.label),
          ValidationStateField(
            label: 'HTTP base URL',
            value: activeBackendConfig.apiBaseUrl,
          ),
          ValidationStateField(
            label: 'MQTT URL',
            value: activeBackendConfig.mqttWebsocketUrl,
          ),
          ValidationStateField(
            label: 'SDK generation',
            value: sdkGeneration.toString(),
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.sessionConfiguration,
        title: '2. Session configuration',
        description:
            'Validate that the signed SDK session exists and canonical identity is resolved.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'The signed session is stored and canonical identity data is available from the backend.',
          howToValidate:
              'Apply the session payload, then refresh canonical identity and confirm the SDK user identifiers are populated.',
        ),
        result: _buildSessionResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Signed session',
            value: _hasSignedSession ? 'Configured' : 'Not set',
          ),
          ValidationStateField(
            label: 'Canonical identity',
            value: _canonicalIdentityResolved
                ? 'Resolved'
                : 'Pending / unavailable',
          ),
          ValidationStateField(label: 'appId', value: session?.appId ?? '-'),
          ValidationStateField(
            label: 'externalUserId',
            value: session?.externalUserId ?? '-',
          ),
          ValidationStateField(
            label: 'canonicalExternalUserId',
            value: session?.canonicalExternalUserId ?? '-',
          ),
          ValidationStateField(
            label: 'sdkUserId',
            value: session?.sdkUserId ?? '-',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.httpConnectivity,
        title: '3. HTTP connectivity',
        description:
            'Verify the backend accepts the signed session and resolves canonical identity via HTTP.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'The backend accepts the signed session and resolves canonical identity without auth or transport errors.',
          howToValidate:
              'Run the HTTP check to refresh canonical identity and inspect the result plus any identity/auth diagnostics.',
        ),
        result: _buildHttpResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Canonical identity',
            value: _canonicalIdentityResolved ? 'Resolved' : 'Not resolved yet',
          ),
          ValidationStateField(
            label: 'Last identity error',
            value: lastIdentityError ?? '-',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.mqttConnectivity,
        title: '4. MQTT connectivity',
        description:
            'Validate realtime connectivity and MQTT topic readiness exposed by SDK operational diagnostics.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'Realtime transport is connected and SOS/TEL topics are ready for operational use.',
          howToValidate:
              'Refresh diagnostics and confirm connection state, topic readiness, and last realtime payload are coherent.',
        ),
        result: _buildMqttResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Realtime connection',
            value: operationalDiagnostics.connectionState.name,
          ),
          ValidationStateField(
            label: 'SOS topics',
            value: operationalDiagnostics.sosEventTopics.isEmpty
                ? 'Unavailable'
                : operationalDiagnostics.sosEventTopics.join(', '),
          ),
          ValidationStateField(
            label: 'TEL topic',
            value: operationalDiagnostics.telemetryPublishTopic ?? '-',
          ),
          ValidationStateField(
            label: 'Last realtime event',
            value: lastRealtimeEvent?.type ?? '-',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.triggerSos,
        title: '5. Trigger SOS',
        description:
            'Run a guided SOS trigger test through the public SDK facade.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'SOS leaves idle state and the incident becomes visible in the validation surface or buffer diagnostics.',
          howToValidate:
              'Run the guided SOS trigger and inspect the SDK SOS state, incident snapshot, and pending SOS diagnostics.',
        ),
        result: _buildTriggerSosResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(label: 'SOS state', value: sosState.name),
          ValidationStateField(
            label: 'Incident id',
            value: lastSosIncident?.id ?? '-',
          ),
          ValidationStateField(
            label: 'Pending SOS buffer',
            value:
                operationalDiagnostics.bridge.pendingSos == null ? 'No' : 'Yes',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.cancelSos,
        title: '6. Cancel SOS',
        description: 'Run a guided cancellation test for the current SOS flow.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'Cancellation is accepted and the SOS state returns to a non-active runtime/backend state.',
          howToValidate:
              'Run the guided cancellation and confirm the SOS state settles instead of staying active indefinitely.',
        ),
        result: _buildCancelSosResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(label: 'SOS state', value: sosState.name),
          ValidationStateField(
            label: 'Last SOS event',
            value: lastSosEvent?.runtimeType.toString() ?? '-',
          ),
          ValidationStateField(
            label: 'Last incident snapshot',
            value: lastSosIncident == null
                ? '-'
                : '${lastSosIncident!.id} (${lastSosIncident!.state.name})',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.telemetrySample,
        title: '7. Telemetry sample',
        description:
            'Publish a manual telemetry sample and confirm the SDK reports the operational result clearly.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Telemetry is published successfully or buffered explicitly when MQTT is offline.',
          howToValidate:
              'Run the telemetry sample and inspect the publish topic, pending buffer, and last action diagnostics.',
        ),
        result: _buildTelemetryResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'TEL topic',
            value: operationalDiagnostics.telemetryPublishTopic ?? '-',
          ),
          ValidationStateField(
            label: 'Pending telemetry buffer',
            value: operationalDiagnostics.bridge.pendingTelemetry == null
                ? 'No'
                : 'Yes',
          ),
          ValidationStateField(
            label: 'Last sample',
            value: lastPublishedTelemetrySample == null
                ? '-'
                : lastPublishedTelemetrySample!.toJson().toString(),
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.contacts,
        title: '8. Create/List contacts',
        description:
            'Validate backend-backed contacts through both guided and manual host-app actions.',
        expectation: const ValidationExpectation(
          expectedResult:
              'A guided validation contact or manually created contact appears in the refreshed list.',
          howToValidate:
              'Run the guided contact validation or create a manual contact, then confirm the contact list updates.',
        ),
        result: _buildContactsResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Contact count',
            value: contacts.length.toString(),
          ),
          ValidationStateField(
            label: 'Top contacts',
            value: contacts.isEmpty
                ? '-'
                : contacts.take(3).map((contact) => contact.name).join(', '),
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.backendReconfigure,
        title: '9. Backend reconfigure',
        description:
            'Rebuild the SDK against a different backend configuration without leaving stale disposed clients behind.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Applying backend settings rebuilds the SDK instance and the validation surface remains operational.',
          howToValidate:
              'Apply a backend change, reopen the validation console if needed, then rerun the critical validation cards on the new SDK generation.',
        ),
        result: _buildBackendReconfigureResult(
          activeBackendConfig: activeBackendConfig,
          backendApplyInProgress: backendApplyInProgress,
          sdkGeneration: sdkGeneration,
        ),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Active backend',
            value:
                '${activeBackendConfig.label} (${activeBackendConfig.apiBaseUrl})',
          ),
          ValidationStateField(
            label: 'MQTT URL',
            value: activeBackendConfig.mqttWebsocketUrl,
          ),
          ValidationStateField(
            label: 'SDK generation',
            value: sdkGeneration.toString(),
          ),
        ],
      ),
    ];
  }

  ValidationSummaryViewModel buildSummaryViewModel({
    required ValidationBackendConfig activeBackendConfig,
    required bool showsAndroidLocalhostWarning,
    required bool backendApplyInProgress,
    required int sdkGeneration,
  }) {
    final cards = buildMvpCapabilityCards(
      activeBackendConfig: activeBackendConfig,
      showsAndroidLocalhostWarning: showsAndroidLocalhostWarning,
      backendApplyInProgress: backendApplyInProgress,
      sdkGeneration: sdkGeneration,
    );

    final passed = cards
        .where((card) => card.result.status == ValidationRunStatus.ok)
        .length;
    final warning = cards
        .where((card) => card.result.status == ValidationRunStatus.warning)
        .length;
    final failed = cards
        .where((card) => card.result.status == ValidationRunStatus.nok)
        .length;
    final notRun = cards
        .where((card) => card.result.status == ValidationRunStatus.notRun)
        .length;
    final running = cards
        .where((card) => card.result.status == ValidationRunStatus.running)
        .length;

    final criticalCards = cards.where((card) => card.isCritical);
    final hasCriticalFailure = criticalCards.any(
      (card) => card.result.status == ValidationRunStatus.nok,
    );
    final allCriticalPassed = criticalCards.every(
      (card) => card.result.status == ValidationRunStatus.ok,
    );

    final readiness = hasCriticalFailure
        ? ValidationReadiness.blocked
        : allCriticalPassed
            ? ValidationReadiness.ready
            : ValidationReadiness.partial;

    return ValidationSummaryViewModel(
      totalCapabilities: cards.length,
      passed: passed,
      warning: warning,
      failed: failed,
      notRun: notRun,
      running: running,
      readiness: readiness,
    );
  }

  Future<void> _runSessionAction(Future<void> Function() action) async {
    loadingSession = true;
    lastIdentityError = null;
    lastActionError = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      lastIdentityError = error.toString();
      final failedResult = ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastIdentityError,
        lastExecutedAt: DateTime.now().toUtc(),
      );
      _recordCapabilityResult(
        ValidationCapabilityId.sessionConfiguration,
        failedResult,
      );
      _recordCapabilityResult(
        ValidationCapabilityId.httpConnectivity,
        failedResult,
      );
    } finally {
      loadingSession = false;
      notifyListeners();
    }
  }

  Future<void> _runAction(
    void Function(bool value) setLoading,
    Future<void> Function() action,
  ) async {
    setLoading(true);
    lastActionError = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      _handleActionError(error);
    } finally {
      setLoading(false);
      notifyListeners();
    }
  }

  void _handleActionError(Object error) {
    lastActionError = error.toString();
    notifyListeners();
  }

  void reportActionError(Object error) {
    _handleActionError(error);
  }

  bool get _hasSignedSession {
    final current = session;
    if (current == null) {
      return false;
    }
    return current.appId.trim().isNotEmpty &&
        current.externalUserId.trim().isNotEmpty &&
        current.userHash.trim().isNotEmpty;
  }

  bool get _canonicalIdentityResolved {
    final current = session;
    if (current == null) {
      return false;
    }
    return (current.canonicalExternalUserId ?? '').trim().isNotEmpty &&
        (current.sdkUserId ?? '').trim().isNotEmpty;
  }

  bool get _mqttTopicReady {
    return operationalDiagnostics.sosEventTopics.isNotEmpty &&
        (operationalDiagnostics.telemetryPublishTopic ?? '').trim().isNotEmpty;
  }

  ValidationCapabilityResult _buildBackendConfigurationResult({
    required ValidationBackendConfig activeBackendConfig,
    required bool showsAndroidLocalhostWarning,
  }) {
    if (activeBackendConfig.apiBaseUrl.trim().isEmpty ||
        activeBackendConfig.mqttWebsocketUrl.trim().isEmpty) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: 'Active backend configuration is incomplete.',
      );
    }
    if (showsAndroidLocalhostWarning) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Localhost/127.0.0.1 points to the Android device itself on physical hardware. Use a LAN IP or adb reverse when validating against your workstation backend.',
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.ok,
      diagnosticText:
          'Backend configuration is present for the active SDK generation.',
    );
  }

  ValidationCapabilityResult _buildSessionResult() {
    final running =
        _capabilityRuns[ValidationCapabilityId.sessionConfiguration];
    if (running?.status == ValidationRunStatus.running) {
      return running!;
    }
    if ((lastIdentityError ?? '').trim().isNotEmpty) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastIdentityError,
        lastExecutedAt: running?.lastExecutedAt,
      );
    }
    if (_hasSignedSession && _canonicalIdentityResolved) {
      return _mergeWithRecorded(
        ValidationCapabilityId.sessionConfiguration,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'Signed session is configured and canonical identity is resolved.',
        ),
      );
    }
    if (_hasSignedSession) {
      return _mergeWithRecorded(
        ValidationCapabilityId.sessionConfiguration,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'Signed session exists, but canonical identity is still pending.',
        ),
      );
    }
    return _mergeWithRecorded(
      ValidationCapabilityId.sessionConfiguration,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.notRun,
        diagnosticText:
            'No signed session is configured yet for this validation run.',
      ),
    );
  }

  ValidationCapabilityResult _buildHttpResult() {
    final running = _capabilityRuns[ValidationCapabilityId.httpConnectivity];
    if (running?.status == ValidationRunStatus.running) {
      return running!;
    }
    if ((lastIdentityError ?? '').trim().isNotEmpty) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastIdentityError,
        lastExecutedAt: running?.lastExecutedAt,
      );
    }
    if (_canonicalIdentityResolved) {
      return _mergeWithRecorded(
        ValidationCapabilityId.httpConnectivity,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'HTTP identity refresh succeeded and canonical identity is available.',
        ),
      );
    }
    if (_hasSignedSession) {
      return _mergeWithRecorded(
        ValidationCapabilityId.httpConnectivity,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'Signed session exists, but the HTTP identity validation has not resolved canonical identity yet.',
        ),
      );
    }
    return _mergeWithRecorded(
      ValidationCapabilityId.httpConnectivity,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.notRun,
        diagnosticText:
            'Run the HTTP connectivity check after configuring a signed session.',
      ),
    );
  }

  ValidationCapabilityResult _buildMqttResult() {
    if (operationalDiagnostics.connectionState ==
            RealtimeConnectionState.connected &&
        _mqttTopicReady) {
      return _mergeWithRecorded(
        ValidationCapabilityId.mqttConnectivity,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'Realtime transport is connected and SOS/TEL topics are ready.',
        ),
      );
    }

    final actionError = (lastActionError ?? '').toLowerCase();
    final transportIssue = actionError.contains('mqtt') ||
        actionError.contains('socket') ||
        actionError.contains('realtime');
    if (transportIssue) {
      return _mergeWithRecorded(
        ValidationCapabilityId.mqttConnectivity,
        ValidationCapabilityResult(
          status: ValidationRunStatus.nok,
          diagnosticText: lastActionError,
        ),
      );
    }

    if (_hasSignedSession) {
      return _mergeWithRecorded(
        ValidationCapabilityId.mqttConnectivity,
        ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'Session is configured, but MQTT is not fully ready yet. Current connection state: ${operationalDiagnostics.connectionState.name}.',
        ),
      );
    }

    return _mergeWithRecorded(
      ValidationCapabilityId.mqttConnectivity,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.notRun,
        diagnosticText:
            'Configure session and HTTP identity first, then inspect MQTT readiness.',
      ),
    );
  }

  ValidationCapabilityResult _buildTriggerSosResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.triggerSos];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if ((lastActionError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastActionError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (operationalDiagnostics.bridge.pendingSos != null) {
      return _mergeWithRecorded(
        ValidationCapabilityId.triggerSos,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'SOS request is buffered pending operational transport availability.',
        ),
      );
    }
    if (sosState != SosState.idle && lastSosIncident != null) {
      return _mergeWithRecorded(
        ValidationCapabilityId.triggerSos,
        ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'SOS left idle state and incident ${lastSosIncident!.id} is visible.',
        ),
      );
    }
    return _mergeWithRecorded(
      ValidationCapabilityId.triggerSos,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.notRun,
        diagnosticText:
            'Run the guided SOS trigger test to evaluate this path.',
      ),
    );
  }

  ValidationCapabilityResult _buildCancelSosResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.cancelSos];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if ((lastActionError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastActionError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (recorded != null && sosState != SosState.idle) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Cancellation was requested, but SOS state is still ${sosState.name}. Backend/runtime propagation may still be in progress.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (recorded != null && sosState == SosState.idle) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.ok,
        diagnosticText:
            'SOS cancellation path completed and the runtime is back to idle.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Run the guided SOS cancellation after triggering or rehydrating an SOS incident.',
    );
  }

  ValidationCapabilityResult _buildTelemetryResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.telemetrySample];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if ((lastActionError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastActionError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (operationalDiagnostics.bridge.pendingTelemetry != null) {
      return _mergeWithRecorded(
        ValidationCapabilityId.telemetrySample,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'Telemetry sample is buffered pending reconnect or publish availability.',
        ),
      );
    }
    if (lastPublishedTelemetrySample != null) {
      return _mergeWithRecorded(
        ValidationCapabilityId.telemetrySample,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'Telemetry sample was accepted by the SDK without buffering.',
        ),
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText: 'Run the guided telemetry sample to evaluate this path.',
    );
  }

  ValidationCapabilityResult _buildContactsResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.contacts];
    if (recorded != null) {
      return recorded;
    }
    return ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText: contacts.isEmpty
          ? 'Run the guided contact validation or create a contact manually.'
          : 'Contacts are present, but the guided validation has not been run yet.',
    );
  }

  ValidationCapabilityResult _buildBackendReconfigureResult({
    required ValidationBackendConfig activeBackendConfig,
    required bool backendApplyInProgress,
    required int sdkGeneration,
  }) {
    if (backendApplyInProgress) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.running,
        diagnosticText:
            'Applying backend configuration and rebuilding the SDK instance...',
      );
    }
    if (activeBackendConfig.apiBaseUrl.trim().isEmpty ||
        activeBackendConfig.mqttWebsocketUrl.trim().isEmpty) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: 'Cannot reconfigure backend with empty URLs.',
      );
    }
    if (sdkGeneration > 1) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.ok,
        diagnosticText:
            'A fresh SDK generation is active. Rerun validation on the current backend to confirm end-to-end health.',
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Apply a different backend configuration to validate SDK rebootstrap behavior.',
    );
  }

  ValidationCapabilityResult _mergeWithRecorded(
    ValidationCapabilityId id,
    ValidationCapabilityResult derived,
  ) {
    final recorded = _capabilityRuns[id];
    if (recorded == null) {
      return derived;
    }
    return derived.copyWith(lastExecutedAt: recorded.lastExecutedAt);
  }

  void _recordCapabilityResult(
    ValidationCapabilityId id,
    ValidationCapabilityResult result,
  ) {
    _capabilityRuns[id] = result.copyWith(
      lastExecutedAt: result.lastExecutedAt ?? DateTime.now().toUtc(),
    );
    notifyListeners();
  }

  _ValidationContactSignature _validationContactSignature() {
    final basis =
        (session?.canonicalExternalUserId ?? session?.externalUserId ?? 'local')
            .replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')
            .toLowerCase();
    return _ValidationContactSignature(
      name: 'Validation Contact $basis',
      phone: '+34600000001',
      email: 'validation+$basis@eixam.local',
    );
  }

  @override
  void dispose() {
    _operationalSub?.cancel();
    _realtimeSub?.cancel();
    _sosStateSub?.cancel();
    _sosEventSub?.cancel();
    _contactsSub?.cancel();
    _deviceStatusSub?.cancel();
    super.dispose();
  }
}

class _ValidationContactSignature {
  const _ValidationContactSignature({
    required this.name,
    required this.phone,
    required this.email,
  });

  final String name;
  final String phone;
  final String email;
}
