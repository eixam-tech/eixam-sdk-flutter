import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_state.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/sdk/device_debug_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart'
    as permission_handler;

import '../../bootstrap/validation_backend_config.dart';
import 'validation_models.dart';

class ValidationConsoleController extends ChangeNotifier {
  ValidationConsoleController({required this.sdk})
      : deviceDebugController = DeviceDebugController(sdk: sdk);

  final EixamConnectSdk sdk;
  final DeviceDebugController deviceDebugController;

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
  SosIncident? currentSosIncident;
  TrackingPosition? currentPositionSnapshot;
  SdkTelemetryPayload? lastPublishedTelemetrySample;
  List<EmergencyContact> contacts = const <EmergencyContact>[];
  List<BackendRegisteredDevice> registeredDevices =
      const <BackendRegisteredDevice>[];
  DeviceStatus? deviceStatus;
  PreferredDevice? preferredDevice;
  ProtectionReadinessReport protectionReadiness =
      const ProtectionReadinessReport(canArm: false);
  ProtectionStatus protectionStatus = ProtectionStatus(
    modeState: ProtectionModeState.off,
    coverageLevel: ProtectionCoverageLevel.none,
    runtimeState: ProtectionRuntimeState.inactive,
    sessionReady: false,
    devicePaired: false,
    deviceConnected: false,
    bluetoothEnabled: false,
    locationPermissionGranted: false,
    notificationsPermissionGranted: false,
    platformBackgroundCapabilityReady: false,
    backendReachable: false,
    realtimeReady: false,
    storeAndForwardEnabled: false,
    pendingSosCount: 0,
    pendingTelemetryCount: 0,
    pendingNativeSosCreateCount: 0,
    pendingNativeSosCancelCount: 0,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
  ProtectionDiagnostics protectionDiagnostics = const ProtectionDiagnostics(
    pendingSosCount: 0,
    pendingTelemetryCount: 0,
    pendingNativeSosCreateCount: 0,
    pendingNativeSosCancelCount: 0,
  );
  String? lastIdentityError;
  String? lastActionError;
  String? lastNotificationsError;
  DateTime? lastNotificationsActionAt;
  bool notificationsInitialized = false;
  bool notificationTestTriggered = false;
  String _ackRelayNodeIdDraft = '0x1AA8';

  bool loadingSession = false;
  bool loadingSos = false;
  bool loadingTelemetry = false;
  bool loadingContacts = false;
  bool loadingDeviceRegistry = false;
  bool loadingDeviceRuntime = false;
  bool loadingProtection = false;
  bool _refreshingDeviceSosObservability = false;
  bool _pendingDeviceSosObservabilityRefresh = false;

  final Map<ValidationCapabilityId, ValidationCapabilityResult>
      _capabilityRuns = <ValidationCapabilityId, ValidationCapabilityResult>{};

  StreamSubscription<SdkOperationalDiagnostics>? _operationalSub;
  StreamSubscription<RealtimeEvent>? _realtimeSub;
  StreamSubscription<SosState>? _sosStateSub;
  StreamSubscription<EixamSdkEvent>? _sosEventSub;
  StreamSubscription<List<EmergencyContact>>? _contactsSub;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<ProtectionStatus>? _protectionStatusSub;
  StreamSubscription<ProtectionDiagnostics>? _protectionDiagnosticsSub;
  VoidCallback? _deviceDebugListener;

  PermissionState? get permissionState => deviceDebugController.permissionState;
  BleDebugState get bleDebugState => deviceDebugController.bleDebugState;
  DeviceSosStatus get deviceSosStatus => deviceDebugController.deviceSosStatus;
  bool get isSignedSessionIdentityReady {
    final currentSession = session;
    if (currentSession == null) {
      return false;
    }
    final canonicalUserId = (currentSession.canonicalExternalUserId ??
            currentSession.externalUserId)
        .trim();
    return currentSession.appId.trim().isNotEmpty &&
        currentSession.userHash.trim().isNotEmpty &&
        canonicalUserId.isNotEmpty;
  }

  bool get isRuntimeDeviceReadyForRegistrySync {
    final status = deviceStatus;
    return status != null && status.paired && status.connected;
  }

  String get backendDeviceRegistryAutoSyncStatus {
    if (!isSignedSessionIdentityReady) {
      return 'Waiting for signed session identity';
    }
    if (!isRuntimeDeviceReadyForRegistrySync) {
      return 'Waiting for a paired and connected runtime device';
    }
    if (registeredDevices.isEmpty) {
      return 'No backend registered device loaded yet; auto-sync will only run when the SDK can resolve a canonical hardware_id safely';
    }
    if (registeredDevices.length == 1) {
      return 'Auto-sync can update the single backend registered device entry automatically';
    }
    return 'Multiple backend devices are loaded; the SDK will auto-sync only when one can be resolved unambiguously';
  }

  String get backendDeviceRegistryDraftHardwareId {
    if (registeredDevices.length == 1) {
      return registeredDevices.single.hardwareId;
    }
    return '-';
  }

  String get ackRelayNodeIdDraft => _ackRelayNodeIdDraft;

  set ackRelayNodeIdDraft(String value) {
    _ackRelayNodeIdDraft = value;
    notifyListeners();
  }

  Future<void> initialize() async {
    await deviceDebugController.initialize();
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
    _protectionStatusSub ??= sdk.watchProtectionStatus().listen(
      (status) {
        protectionStatus = status;
        notifyListeners();
      },
      onError: _handleActionError,
    );
    _protectionDiagnosticsSub ??= sdk.watchProtectionDiagnostics().listen(
      (diagnostics) {
        protectionDiagnostics = diagnostics;
        notifyListeners();
      },
      onError: _handleActionError,
    );
    _deviceDebugListener ??= () {
      notifyListeners();
      _requestDeviceSosObservabilityRefresh();
    };
    deviceDebugController.addListener(_deviceDebugListener!);
  }

  Future<void> refreshAll() async {
    try {
      session = await sdk.getCurrentSession();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
      lastRealtimeEvent = await sdk.getLastRealtimeEvent();
      sosState = await sdk.getSosState();
      currentSosIncident = await sdk.getCurrentSosIncident();
      currentPositionSnapshot = await sdk.getCurrentPosition();
      contacts = await sdk.listEmergencyContacts();
      registeredDevices = await sdk.listRegisteredDevices();
      deviceStatus = await sdk.getDeviceStatus();
      preferredDevice = await sdk.preferredDevice;
      protectionReadiness = await sdk.evaluateProtectionReadiness();
      protectionStatus = await sdk.getProtectionStatus();
      protectionDiagnostics = await sdk.getProtectionDiagnostics();
      await deviceDebugController.refreshAll();
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
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_triggerSosLocationGranted) {
      _recordCapabilityResult(
        ValidationCapabilityId.triggerSos,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'User location permission is required before running this SOS validation.',
        ),
      );
      return;
    }
    await _runBoundedValidation<_SosValidationSnapshot>(
      id: ValidationCapabilityId.triggerSos,
      runningDiagnostic: 'Triggering SOS through the public SDK facade...',
      timeout: timeout,
      captureBaseline: _captureSosValidationSnapshot,
      action: () => triggerSos(message: message, triggerSource: triggerSource),
      refresh: _refreshSosValidationState,
      evaluate: _evaluateTriggerSosValidation,
    );
  }

  Future<void> cancelSos() async {
    await _runAction((value) => loadingSos = value, () async {
      lastSosIncident = await sdk.cancelSos();
      sosState = await sdk.getSosState();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
    });
  }

  Future<void> runCancelSosValidation({
    Duration timeout = const Duration(seconds: 7),
  }) async {
    await _runBoundedValidation<_SosValidationSnapshot>(
      id: ValidationCapabilityId.cancelSos,
      runningDiagnostic: 'Requesting SOS cancellation through the SDK...',
      timeout: timeout,
      captureBaseline: _captureSosValidationSnapshot,
      action: cancelSos,
      refresh: _refreshSosValidationState,
      evaluate: _evaluateCancelSosValidation,
    );
  }

  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    await _runAction((value) => loadingTelemetry = value, () async {
      await sdk.publishTelemetry(payload);
      lastPublishedTelemetrySample = payload;
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
    });
  }

  Future<void> runTelemetryValidation(
    SdkTelemetryPayload payload, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await _runBoundedValidation<_TelemetryValidationSnapshot>(
      id: ValidationCapabilityId.telemetrySample,
      runningDiagnostic: 'Publishing telemetry sample through the SDK...',
      timeout: timeout,
      captureBaseline: _captureTelemetryValidationSnapshot,
      action: () => publishTelemetry(payload),
      refresh: _refreshTelemetryValidationState,
      evaluate: _evaluateTelemetryValidation,
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
      final createdVisible = contacts.any(
        (contact) =>
            contact.name.trim() == name.trim() &&
            contact.phone.trim() == phone.trim() &&
            contact.email.trim().toLowerCase() == email.trim().toLowerCase(),
      );
      if (createdVisible) {
        _recordCapabilityResult(
          ValidationCapabilityId.contacts,
          ValidationCapabilityResult(
            status: ValidationRunStatus.ok,
            diagnosticText:
                'Contact is visible in the refreshed list after manual creation.',
            lastExecutedAt: DateTime.now().toUtc(),
          ),
        );
      }
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

  Future<void> refreshPermissionsValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.permissions,
      runningDiagnostic: 'Refreshing permissions and adapter state...',
      action: deviceDebugController.refreshPermissions,
      evaluate: _buildPermissionsResult,
    );
  }

  Future<void> requestBluetoothPermissionsValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.permissions,
      runningDiagnostic: 'Requesting Bluetooth and scan prerequisites...',
      action: deviceDebugController.requestScanPermissions,
      evaluate: _buildPermissionsResult,
    );
  }

  Future<void> requestNotificationsPermissionValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.permissions,
      runningDiagnostic: 'Requesting notification permission...',
      action: deviceDebugController.requestNotificationPermission,
      evaluate: _buildPermissionsResult,
    );
  }

  Future<void> initializeNotificationsValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.notifications,
      runningDiagnostic: 'Initializing local notifications through the SDK...',
      action: () async {
        await deviceDebugController.initializeNotifications();
        notificationsInitialized = deviceDebugController.lastError == null;
        if (deviceDebugController.lastError != null) {
          lastNotificationsError = deviceDebugController.lastError;
        }
        lastNotificationsActionAt = DateTime.now().toUtc();
      },
      evaluate: _buildNotificationsResult,
    );
  }

  Future<void> testNotificationValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.notifications,
      runningDiagnostic: 'Triggering a test notification through the SDK...',
      action: () async {
        await deviceDebugController.showTestNotification();
        notificationTestTriggered = deviceDebugController.lastError == null;
        if (deviceDebugController.lastError != null) {
          lastNotificationsError = deviceDebugController.lastError;
        }
        lastNotificationsActionAt = DateTime.now().toUtc();
      },
      evaluate: _buildNotificationsResult,
    );
  }

  Future<void> runBleScanValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.bleScan,
      runningDiagnostic: 'Running BLE scan through the SDK debug surface...',
      action: deviceDebugController.runScan,
      evaluate: _buildBleScanResult,
    );
  }

  Future<void> runPairConnectValidation(
      {String pairingCode = 'DEMO-PAIR-001'}) async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.pairConnectDevice,
      runningDiagnostic: 'Connecting the device through the SDK...',
      action: () async {
        await deviceDebugController.sdk.connectDevice(pairingCode: pairingCode);
      },
      onAfterAction: () async {
        await deviceDebugController.refreshAll();
        deviceStatus = await sdk.getDeviceStatus();
        preferredDevice = await sdk.preferredDevice;
      },
      evaluate: _buildPairConnectResult,
    );
  }

  Future<void> runPairSelectedDeviceValidation(BleScanResult scan) async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.pairConnectDevice,
      runningDiagnostic: 'Connecting the selected BLE scan result...',
      action: () => deviceDebugController.pairSelectedDevice(scan),
      onAfterAction: () async {
        deviceStatus = await sdk.getDeviceStatus();
        preferredDevice = await sdk.preferredDevice;
      },
      evaluate: _buildPairConnectResult,
    );
  }

  Future<void> runActivateDeviceValidation({
    String activationCode = 'DEMO-ACT-001',
  }) async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.activateDevice,
      runningDiagnostic: 'Activating the connected device...',
      action: () async {
        await sdk.activateDevice(activationCode: activationCode);
      },
      onAfterAction: () async {
        await deviceDebugController.refreshAll();
        deviceStatus = await sdk.getDeviceStatus();
      },
      evaluate: _buildActivateDeviceResult,
    );
  }

  Future<void> runRefreshDeviceStatusValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.refreshDeviceStatus,
      runningDiagnostic: 'Refreshing device runtime state...',
      action: deviceDebugController.refreshDevice,
      onAfterAction: () async {
        deviceStatus = await sdk.getDeviceStatus();
      },
      evaluate: _buildRefreshDeviceStatusResult,
    );
  }

  Future<void> runUnpairDeviceValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.unpairDevice,
      runningDiagnostic: 'Disconnecting and clearing the active device...',
      action: deviceDebugController.unpairDevice,
      onAfterAction: () async {
        deviceStatus = await sdk.getDeviceStatus();
        preferredDevice = await sdk.preferredDevice;
      },
      evaluate: _buildUnpairDeviceResult,
    );
  }

  Future<void> runDeviceSosValidation({
    required String actionLabel,
    required Future<void> Function() action,
  }) async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.deviceSosFlow,
      runningDiagnostic: '$actionLabel through the SDK device SOS flow...',
      action: action,
      onAfterAction: () async {
        await deviceDebugController.refreshAll();
        await refreshDeviceSosObservability();
      },
      evaluate: _buildDeviceSosResult,
    );
  }

  Future<void> refreshDeviceSosObservability() async {
    try {
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
      currentSosIncident = await sdk.getCurrentSosIncident();
      currentPositionSnapshot = await sdk.getCurrentPosition();
      notifyListeners();
    } catch (error) {
      _handleActionError(error);
    }
  }

  Future<void> refreshCommandChannelReadiness() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.commandChannelReadiness,
      runningDiagnostic: 'Refreshing BLE diagnostics and command readiness...',
      action: deviceDebugController.refreshAll,
      evaluate: _buildCommandChannelReadinessResult,
    );
  }

  Future<void> runInetCommandValidation({
    required String actionLabel,
    required Future<void> Function() action,
  }) async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.inetCommands,
      runningDiagnostic: '$actionLabel through the SDK command path...',
      action: action,
      evaluate: _buildInetCommandsResult,
    );
  }

  Future<void> runAckRelayValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.ackRelay,
      runningDiagnostic:
          'Sending SOS_ACK_RELAY through the SDK command path...',
      action: () => deviceDebugController.sendAckRelay(_ackRelayNodeIdDraft),
      evaluate: _buildAckRelayResult,
    );
  }

  Future<void> runShutdownValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.shutdownCommand,
      runningDiagnostic: 'Sending shutdown through the SDK command path...',
      action: deviceDebugController.sendShutdown,
      onAfterAction: () async {
        protectionStatus = await sdk.getProtectionStatus();
        protectionDiagnostics = await sdk.getProtectionDiagnostics();
      },
      evaluate: _buildShutdownResult,
    );
  }

  Future<void> refreshBackendDeviceRegistryValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.backendDeviceRegistryAlignment,
      runningDiagnostic: 'Refreshing backend device registry...',
      action: () async {
        registeredDevices = await sdk.listRegisteredDevices();
      },
      evaluate: _buildBackendDeviceRegistryAlignmentResult,
    );
  }

  Future<void> retryBackendDeviceRegistryAutoSyncValidation() async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.backendDeviceRegistryAlignment,
      runningDiagnostic:
          'Refreshing device runtime so the SDK can retry automatic backend registry sync...',
      action: () async {
        deviceStatus = await sdk.refreshDeviceStatus();
      },
      onAfterAction: () async {
        registeredDevices = await sdk.listRegisteredDevices();
        preferredDevice = await sdk.preferredDevice;
      },
      evaluate: _buildBackendDeviceRegistryAlignmentResult,
    );
  }

  Future<void> upsertRegisteredDeviceValidation({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.backendDeviceRegistryAlignment,
      runningDiagnostic: 'Upserting backend registry entry...',
      action: () async {
        await sdk.upsertRegisteredDevice(
          hardwareId: hardwareId,
          firmwareVersion: firmwareVersion,
          hardwareModel: hardwareModel,
          pairedAt: pairedAt,
        );
      },
      onAfterAction: () async {
        registeredDevices = await sdk.listRegisteredDevices();
      },
      evaluate: _buildBackendDeviceRegistryAlignmentResult,
    );
  }

  Future<void> deleteRegisteredDeviceValidation(String deviceId) async {
    await _runBleCapabilityAction(
      id: ValidationCapabilityId.backendDeviceRegistryAlignment,
      runningDiagnostic: 'Deleting backend registry entry...',
      action: () => sdk.deleteRegisteredDevice(deviceId),
      onAfterAction: () async {
        registeredDevices = await sdk.listRegisteredDevices();
      },
      evaluate: _buildBackendDeviceRegistryAlignmentResult,
    );
  }

  Future<void> evaluateProtectionReadiness() async {
    await _runAction((value) => loadingProtection = value, () async {
      protectionReadiness = await sdk.evaluateProtectionReadiness();
      protectionStatus = await sdk.getProtectionStatus();
      protectionDiagnostics = await sdk.getProtectionDiagnostics();
      _recordCapabilityResult(
        ValidationCapabilityId.protectionReadiness,
        _buildProtectionReadinessResult(),
      );
    });
  }

  Future<void> enterProtectionMode() async {
    await _runAction((value) => loadingProtection = value, () async {
      _recordCapabilityResult(
        ValidationCapabilityId.protectionEnter,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.running,
          diagnosticText: 'Entering Protection Mode through the SDK facade...',
        ),
      );
      final result = await sdk.enterProtectionMode();
      protectionStatus = result.status;
      protectionReadiness = ProtectionReadinessReport(
        canArm: result.success,
        blockingIssues: result.blockingIssues,
        warnings: protectionReadiness.warnings,
      );
      protectionDiagnostics = await sdk.getProtectionDiagnostics();
      _recordCapabilityResult(
        ValidationCapabilityId.protectionEnter,
        _buildProtectionEnterResult(result),
      );
    });
  }

  Future<void> exitProtectionMode() async {
    await _runAction((value) => loadingProtection = value, () async {
      _recordCapabilityResult(
        ValidationCapabilityId.protectionExit,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.running,
          diagnosticText: 'Exiting Protection Mode through the SDK facade...',
        ),
      );
      protectionStatus = await sdk.exitProtectionMode();
      protectionDiagnostics = await sdk.getProtectionDiagnostics();
      _recordCapabilityResult(
        ValidationCapabilityId.protectionExit,
        _buildProtectionExitResult(ignoreRunningRecord: true),
      );
    });
  }

  Future<void> flushProtectionQueues() async {
    await _runAction((value) => loadingProtection = value, () async {
      final result = await sdk.flushProtectionQueues();
      protectionDiagnostics = await sdk.getProtectionDiagnostics();
      protectionStatus = await sdk.getProtectionStatus();
      _recordCapabilityResult(
        ValidationCapabilityId.protectionFlushQueues,
        ValidationCapabilityResult(
          status:
              result.success ? ValidationRunStatus.ok : ValidationRunStatus.nok,
          diagnosticText:
              'Protection queues flush is a safe MVP stub. SOS flushed: ${result.flushedSosCount}, telemetry flushed: ${result.flushedTelemetryCount}.',
        ),
      );
    });
  }

  Future<void> rehydrateProtectionState() async {
    await _runAction((value) => loadingProtection = value, () async {
      protectionStatus = await sdk.rehydrateProtectionState();
      protectionDiagnostics = await sdk.getProtectionDiagnostics();
      protectionReadiness = await sdk.evaluateProtectionReadiness();
      _recordCapabilityResult(
        ValidationCapabilityId.protectionRehydrate,
        _buildProtectionRehydrateResult(),
      );
    });
  }

  Future<void> refreshProtectionDiagnostics() async {
    await _runAction((value) => loadingProtection = value, () async {
      protectionStatus = await sdk.getProtectionStatus();
      protectionDiagnostics = await sdk.getProtectionDiagnostics();
      protectionReadiness = await sdk.evaluateProtectionReadiness();
      _recordCapabilityResult(
        ValidationCapabilityId.protectionDiagnostics,
        _buildProtectionDiagnosticsResult(),
      );
    });
  }

  List<ValidationCardViewModel> buildMvpCapabilityCards({
    required ValidationBackendConfig activeBackendConfig,
    required bool activeBackendLocalhostWarning,
    required ValidationBackendConfig draftBackendConfig,
    required bool draftBackendLocalhostWarning,
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
          showsAndroidLocalhostWarning: activeBackendLocalhostWarning,
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
        prerequisites: <ValidationStateField>[
          ValidationStateField(
            label: 'Location permission',
            value: triggerSosLocationPrerequisiteLabel,
          ),
          ValidationStateField(
            label: 'MQTT ready',
            value: triggerSosMqttReady ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Session ready',
            value: triggerSosSessionReady ? 'Yes' : 'No',
          ),
        ],
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
          draftBackendConfig: draftBackendConfig,
          draftBackendLocalhostWarning: draftBackendLocalhostWarning,
          backendApplyInProgress: backendApplyInProgress,
          sdkGeneration: sdkGeneration,
        ),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Draft preset',
            value: draftBackendConfig.label,
          ),
          ValidationStateField(
            label: 'Draft HTTP base URL',
            value: draftBackendConfig.apiBaseUrl,
          ),
          ValidationStateField(
            label: 'Draft MQTT URL',
            value: draftBackendConfig.mqttWebsocketUrl,
          ),
          ValidationStateField(
            label: 'Apply status',
            value: backendApplyInProgress ? 'Applying...' : 'Idle',
          ),
        ],
      ),
    ];
  }

  List<ValidationCardViewModel> buildBleCapabilityCards() {
    final status = deviceStatus;
    final bleState = bleDebugState;
    final deviceViewState = deviceDebugController.deviceViewState;

    return <ValidationCardViewModel>[
      ValidationCardViewModel(
        id: ValidationCapabilityId.permissions,
        title: 'A. Permissions',
        description:
            'Validate runtime permissions and adapter state required for BLE testing.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'Bluetooth access is granted, notifications are reported clearly, and the Bluetooth adapter is enabled.',
          howToValidate:
              'Refresh permissions, request Bluetooth and notifications if needed, then confirm the adapter is enabled.',
        ),
        result: _buildPermissionsResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Location permission',
            value: permissionState?.location.toString() ?? 'Unknown',
          ),
          ValidationStateField(
            label: 'Bluetooth permission',
            value: permissionState?.bluetooth.toString() ?? 'Unknown',
          ),
          ValidationStateField(
            label: 'Notifications permission',
            value: permissionState?.notifications.toString() ?? 'Unknown',
          ),
          ValidationStateField(
            label: 'Bluetooth enabled',
            value: permissionState?.bluetoothEnabled.toString() ?? 'Unknown',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.notifications,
        title: 'B. Notifications',
        description:
            'Validate host-side notification initialization and a simple test notification path.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Notifications initialize successfully and a test notification can be triggered.',
          howToValidate:
              'Initialize notifications, trigger a test notification, and verify any related errors stay empty.',
        ),
        result: _buildNotificationsResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Initialized',
            value: notificationsInitialized ? 'Yes' : 'Unknown / not confirmed',
          ),
          ValidationStateField(
            label: 'Test notification',
            value: notificationTestTriggered ? 'Triggered' : 'Not run',
          ),
          ValidationStateField(
            label: 'Last error',
            value: lastNotificationsError ??
                deviceDebugController.lastError ??
                '-',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.bleScan,
        title: 'C. BLE scan',
        description:
            'Validate BLE scanning and confirm that devices appear in scan results.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'BLE scan starts successfully and at least one device appears when hardware is present.',
          howToValidate:
              'Run a BLE scan, review the result count, and confirm whether an EIXAM service appears in the discovered devices.',
        ),
        result: _buildBleScanResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Scanning',
            value: bleState.isScanning.toString(),
          ),
          ValidationStateField(
            label: 'Selected device id',
            value: bleState.selectedDeviceId ?? '-',
          ),
          ValidationStateField(
            label: 'Scan result count',
            value: bleState.scanResults.length.toString(),
          ),
          ValidationStateField(
            label: 'EIXAM service in results',
            value: bleState.scanResults.any(
              (scan) => scan.advertisedServiceUuids
                  .map((item) => item.toLowerCase())
                  .contains('ea00'),
            )
                ? 'Yes'
                : 'No / unknown',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.pairConnectDevice,
        title: 'D. Pair / Connect device',
        description:
            'Validate device connection and preferred-device selection through the SDK.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'The device connects successfully and becomes the selected runtime device.',
          howToValidate:
              'Use the pairing flow or a selected scan result, then confirm connection status, readiness, and selected device metadata.',
        ),
        result: _buildPairConnectResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Selected device id',
            value: bleState.selectedDeviceId ?? '-',
          ),
          ValidationStateField(
            label: 'Connected',
            value: status?.connected.toString() ?? 'false',
          ),
          ValidationStateField(
            label: 'Readiness summary',
            value: deviceViewState.readinessSummary,
          ),
          ValidationStateField(
            label: 'Connection summary',
            value: deviceViewState.connectionSummary,
          ),
          ValidationStateField(
            label: 'Connection error',
            value: bleState.connectionError ??
                deviceDebugController.lastError ??
                '-',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.activateDevice,
        title: 'E. Activate device',
        description:
            'Validate device activation through the public SDK device flow.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'Activation succeeds and runtime state reflects an activated device.',
          howToValidate:
              'Run activation after connecting a device, then refresh state and confirm activated or ready status.',
        ),
        result: _buildActivateDeviceResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Paired', value: status?.paired.toString() ?? 'false'),
          ValidationStateField(
              label: 'Activated',
              value: status?.activated.toString() ?? 'false'),
          ValidationStateField(
            label: 'Lifecycle state',
            value: status?.lifecycleState.name ?? '-',
          ),
          ValidationStateField(
            label: 'Readiness summary',
            value: deviceViewState.readinessSummary,
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.refreshDeviceStatus,
        title: 'F. Refresh device status',
        description:
            'Validate runtime device refresh and confirm that key device metadata renders coherently.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Device status refresh succeeds and key metadata fields are visible.',
          howToValidate:
              'Run a device refresh and inspect id, model, firmware, battery, lifecycle, connectivity, and readiness fields.',
        ),
        result: _buildRefreshDeviceStatusResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Device id', value: status?.deviceId ?? '-'),
          ValidationStateField(
              label: 'Alias', value: status?.deviceAlias ?? '-'),
          ValidationStateField(label: 'Model', value: status?.model ?? '-'),
          ValidationStateField(
              label: 'Firmware', value: status?.firmwareVersion ?? '-'),
          ValidationStateField(
            label: 'Battery',
            value: deviceViewState.batterySummary,
          ),
          ValidationStateField(
            label: 'Lifecycle state',
            value: status?.lifecycleState.name ?? '-',
          ),
          ValidationStateField(
            label: 'Connected',
            value: status?.connected.toString() ?? 'false',
          ),
          ValidationStateField(
            label: 'Ready for safety',
            value: status?.isReadyForSafety.toString() ?? 'false',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.unpairDevice,
        title: 'G. Unpair device',
        description:
            'Validate that the active device can be disconnected and cleared from runtime state.',
        expectation: const ValidationExpectation(
          expectedResult:
              'The device is no longer active or connected in runtime state after unpair/disconnect.',
          howToValidate:
              'Run unpair, then refresh state and confirm the device is no longer connected or operational.',
        ),
        result: _buildUnpairDeviceResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Selected device id',
              value: bleState.selectedDeviceId ?? '-'),
          ValidationStateField(
              label: 'Paired', value: status?.paired.toString() ?? 'false'),
          ValidationStateField(
              label: 'Connected',
              value: status?.connected.toString() ?? 'false'),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.deviceSosFlow,
        title: 'H. Device/runtime SOS flow',
        description:
            'Validate device/runtime SOS transitions exposed by the SDK BLE device SOS flow.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'Device/runtime SOS actions drive visible local state transitions and expose source, detail, and packet timing clearly. This card does not by itself guarantee backend persistence.',
          howToValidate:
              'Run trigger, confirm, cancel, or backend ACK as appropriate and inspect the resulting device/runtime SOS state, packet diagnostics, and any bridge visibility shown here.',
        ),
        result: _buildDeviceSosResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'SOS state', value: deviceSosStatus.state.name),
          ValidationStateField(
            label: 'Transition source',
            value: deviceSosStatus.transitionSource.name,
          ),
          ValidationStateField(
            label: 'Last event detail',
            value: deviceSosStatus.lastEvent,
          ),
          ValidationStateField(
            label: 'Packet timestamp',
            value: deviceSosStatus.lastPacketAt == null
                ? '-'
                : _formatDateTime(deviceSosStatus.lastPacketAt),
          ),
          ValidationStateField(
            label: 'Latest BLE event type',
            value: bleState.lastDecodedIncomingEventType ?? '-',
          ),
          ValidationStateField(
            label: 'Raw BLE channel',
            value: bleState.lastRawNotificationChannel ?? '-',
          ),
          ValidationStateField(
            label: 'Characteristic',
            value: bleState.lastRawNotificationCharacteristic ?? '-',
          ),
          ValidationStateField(
            label: 'Payload hex',
            value: bleState.lastRawNotificationPayloadHex ?? '-',
          ),
          ValidationStateField(
            label: 'Decoded as',
            value: bleState.lastDecodeOutcome ?? '-',
          ),
          ValidationStateField(
            label: 'Last raw BLE notify',
            value: bleState.lastRawNotificationAt == null
                ? '-'
                : _formatDateTime(bleState.lastRawNotificationAt),
          ),
          ValidationStateField(
            label: 'Bridge SOS visibility',
            value: operationalDiagnostics.bridge.lastBleSosEventSummary ?? '-',
          ),
          ValidationStateField(
            label: 'Bridge last decision',
            value: operationalDiagnostics.bridge.lastDecision ?? '-',
          ),
          ValidationStateField(
            label: 'Current position snapshot',
            value: _formatPositionSnapshot(currentPositionSnapshot),
          ),
          ValidationStateField(
            label: 'Current SOS incident',
            value: _formatSosIncident(currentSosIncident),
          ),
          ValidationStateField(
            label: 'Bridge pending SOS',
            value: operationalDiagnostics.bridge.pendingSos == null
                ? 'None'
                : operationalDiagnostics.bridge.pendingSos!.signature,
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.commandChannelReadiness,
        title: 'I. Command channel readiness',
        description:
            'Validate command writer readiness and BLE characteristic availability without exposing protocol logic in widgets.',
        isCritical: true,
        expectation: const ValidationExpectation(
          expectedResult:
              'Command writer is ready and the required EIXAM BLE characteristics are visible.',
          howToValidate:
              'Refresh diagnostics and confirm the service, notify characteristics, and command writer state are coherent.',
        ),
        result: _buildCommandChannelReadinessResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Command writer ready',
              value: bleState.commandWriterReady.toString()),
          ValidationStateField(
              label: 'EIXAM service found',
              value: bleState.eixamServiceFound.toString()),
          ValidationStateField(
              label: 'TEL found', value: bleState.telFound.toString()),
          ValidationStateField(
              label: 'SOS found', value: bleState.sosFound.toString()),
          ValidationStateField(
              label: 'INET found', value: bleState.inetFound.toString()),
          ValidationStateField(
              label: 'CMD found', value: bleState.cmdFound.toString()),
          ValidationStateField(
              label: 'TEL notify subscribed',
              value: bleState.telNotifySubscribed.toString()),
          ValidationStateField(
              label: 'SOS notify subscribed',
              value: bleState.sosNotifySubscribed.toString()),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.inetCommands,
        title: 'J. INET commands',
        description:
            'Validate low-level INET command sending through the SDK technical path.',
        expectation: const ValidationExpectation(
          expectedResult:
              'INET command writes succeed and update write diagnostics clearly.',
          howToValidate:
              'Send INET OK, INET LOST, or POS CONFIRMED and confirm the last write metadata reflects the command result.',
        ),
        result: _buildInetCommandsResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Last command sent',
              value:
                  deviceDebugController.diagnosticsViewState.lastCommandLabel),
          ValidationStateField(
              label: 'Payload hex', value: bleState.lastCommandSent ?? '-'),
          ValidationStateField(
              label: 'Target characteristic',
              value: bleState.lastWriteTargetCharacteristic ?? '-'),
          ValidationStateField(
              label: 'Write success/failure',
              value: bleState.lastWriteResult ?? '-'),
          ValidationStateField(
              label: 'Timestamp',
              value: bleState.lastWriteAt == null
                  ? '-'
                  : _formatDateTime(bleState.lastWriteAt)),
          ValidationStateField(
              label: 'Exact error',
              value: bleState.lastWriteError ??
                  deviceDebugController.lastError ??
                  '-'),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.ackRelay,
        title: 'K. ACK relay',
        description:
            'Validate SOS ACK relay command sending with an operator-provided node id.',
        expectation: const ValidationExpectation(
          expectedResult:
              'ACK relay write succeeds and write diagnostics reflect the sent command.',
          howToValidate:
              'Enter a relay node id, send ACK relay, and confirm the write metadata updates without parse or transport errors.',
        ),
        result: _buildAckRelayResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Entered node id', value: _ackRelayNodeIdDraft),
          ValidationStateField(
              label: 'Last command/write',
              value:
                  deviceDebugController.diagnosticsViewState.lastCommandLabel),
          ValidationStateField(
              label: 'Exact error',
              value: bleState.lastWriteError ??
                  deviceDebugController.lastError ??
                  '-'),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.shutdownCommand,
        title: 'L. Shutdown command',
        description:
            'Validate the guarded shutdown command path for the connected device.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Shutdown command is sent successfully through the SDK command path.',
          howToValidate:
              'Send shutdown only when the operator intends to do so, then confirm the write diagnostics update coherently.',
        ),
        result: _buildShutdownResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Last command/write',
              value:
                  deviceDebugController.diagnosticsViewState.lastCommandLabel),
          ValidationStateField(
              label: 'Payload hex', value: bleState.lastCommandSent ?? '-'),
          ValidationStateField(
              label: 'Write success/failure',
              value: bleState.lastWriteResult ?? '-'),
          ValidationStateField(
              label: 'Exact error',
              value: bleState.lastWriteError ??
                  deviceDebugController.lastError ??
                  '-'),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.backendDeviceRegistryAlignment,
        title: 'M. Backend device registry alignment',
        description:
            'Validate backend device registry actions and compare runtime device state with registry data from one console.',
        expectation: const ValidationExpectation(
          expectedResult:
              'The SDK auto-syncs the connected paired device into the backend registry when it can resolve a canonical hardware_id, and the validation surface shows status plus retry options.',
          howToValidate:
              'Connect a known device with a signed session, refresh or retry auto-sync if needed, and inspect the loaded backend registry state without relying on manual form entry.',
        ),
        result: _buildBackendDeviceRegistryAlignmentResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
              label: 'Signed session ready',
              value: isSignedSessionIdentityReady ? 'Yes' : 'No'),
          ValidationStateField(
              label: 'Runtime ready for sync',
              value: isRuntimeDeviceReadyForRegistrySync ? 'Yes' : 'No'),
          ValidationStateField(
              label: 'Registry count',
              value: registeredDevices.length.toString()),
          ValidationStateField(
              label: 'Runtime firmware', value: status?.firmwareVersion ?? '-'),
          ValidationStateField(
              label: 'Runtime hardware model', value: status?.model ?? '-'),
          ValidationStateField(
              label: 'Resolved backend hardware_id draft',
              value: backendDeviceRegistryDraftHardwareId),
          ValidationStateField(
              label: 'Auto-sync status',
              value: backendDeviceRegistryAutoSyncStatus),
        ],
      ),
    ];
  }

  List<ValidationCardViewModel> buildProtectionCapabilityCards() {
    return <ValidationCardViewModel>[
      ValidationCardViewModel(
        id: ValidationCapabilityId.protectionReadiness,
        title: 'P1. Protection readiness',
        description:
            'Evaluate whether the current host app and SDK context can safely enter Protection Mode.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Protection Mode stays optional and reports blockers or warnings clearly without affecting existing runtime behavior.',
          howToValidate:
              'Run readiness evaluation and review blockers, warnings, and the current environment snapshot.',
        ),
        result: _buildProtectionReadinessResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Platform',
            value: protectionStatus.platform.name,
          ),
          ValidationStateField(
            label: 'Platform runtime configured',
            value: protectionStatus.platformRuntimeConfigured ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Background capability',
            value: protectionStatus.backgroundCapabilityState.name,
          ),
          ValidationStateField(
            label: 'Restoration configured',
            value: protectionStatus.restorationConfigured ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Can arm',
            value: protectionReadiness.canArm ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Blocking issues',
            value: protectionReadiness.blockingIssues.isEmpty
                ? 'None'
                : protectionReadiness.blockingIssues
                    .map((issue) => issue.type.name)
                    .join(', '),
          ),
          ValidationStateField(
            label: 'Warnings',
            value: protectionReadiness.warnings.isEmpty
                ? 'None'
                : protectionReadiness.warnings.join(' | '),
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.protectionStatus,
        title: 'P2. Current protection status',
        description:
            'Inspect the current additive Protection Mode state without changing any existing BLE or SOS flows.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Protection Mode is off by default and only changes state after explicit entry or exit actions.',
          howToValidate:
              'Refresh or rehydrate status and confirm mode, coverage, runtime, and readiness signals are coherent.',
        ),
        result: _buildProtectionStatusResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Mode state',
            value: protectionStatus.modeState.name,
          ),
          ValidationStateField(
            label: 'Coverage',
            value: protectionStatus.coverageLevel.name,
          ),
          ValidationStateField(
            label: 'Runtime state',
            value: protectionStatus.runtimeState.name,
          ),
          ValidationStateField(
            label: 'BLE owner',
            value: protectionStatus.bleOwner.name,
          ),
          ValidationStateField(
            label: 'Foreground service',
            value: protectionStatus.foregroundServiceRunning ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Runtime active',
            value: protectionStatus.protectionRuntimeActive ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Service BLE connected',
            value: protectionStatus.serviceBleConnected ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Service BLE ready',
            value: protectionStatus.serviceBleReady ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Expected BLE service',
            value: protectionStatus.expectedBleServiceUuid ?? '-',
          ),
          ValidationStateField(
            label: 'Expected BLE chars',
            value: protectionStatus.expectedBleCharacteristicUuids.isEmpty
                ? '-'
                : protectionStatus.expectedBleCharacteristicUuids.join(' | '),
          ),
          ValidationStateField(
            label: 'Discovered BLE services',
            value: protectionStatus.discoveredBleServicesSummary ?? '-',
          ),
          ValidationStateField(
            label: 'Readiness failure',
            value: protectionStatus.readinessFailureReason ?? '-',
          ),
          ValidationStateField(
            label: 'Active device',
            value: protectionStatus.activeDeviceId ?? '-',
          ),
          ValidationStateField(
            label: 'Protected device',
            value: protectionStatus.protectedDeviceId ?? '-',
          ),
          ValidationStateField(
            label: 'Last platform event',
            value: protectionStatus.lastPlatformEvent ?? '-',
          ),
          ValidationStateField(
            label: 'Last restoration event',
            value: protectionStatus.lastRestorationEvent ?? '-',
          ),
          ValidationStateField(
            label: 'Last BLE service event',
            value: protectionStatus.lastBleServiceEvent ?? '-',
          ),
          ValidationStateField(
            label: 'Pending native SOS create',
            value: protectionStatus.pendingNativeSosCreateCount.toString(),
          ),
          ValidationStateField(
            label: 'Pending native SOS cancel',
            value: protectionStatus.pendingNativeSosCancelCount.toString(),
          ),
          ValidationStateField(
            label: 'Native backend result',
            value: protectionStatus.lastNativeBackendHandoffResult ?? '-',
          ),
          ValidationStateField(
            label: 'Native backend error',
            value: protectionStatus.lastNativeBackendHandoffError ?? '-',
          ),
          ValidationStateField(
            label: 'Last command route',
            value: protectionStatus.lastCommandRoute ?? '-',
          ),
          ValidationStateField(
            label: 'Last command result',
            value: protectionStatus.lastCommandResult ?? '-',
          ),
          ValidationStateField(
            label: 'Last command error',
            value: protectionStatus.lastCommandError ?? '-',
          ),
          ValidationStateField(
            label: 'Degradation reason',
            value: protectionStatus.degradationReason ?? '-',
          ),
          ValidationStateField(
            label: 'Native backend URL',
            value: protectionStatus.nativeBackendBaseUrl ?? '-',
          ),
          ValidationStateField(
            label: 'Native backend config',
            value:
                protectionStatus.nativeBackendConfigValid ? 'Valid' : 'Invalid',
          ),
          ValidationStateField(
            label: 'Debug localhost allowed',
            value: protectionStatus.debugLocalhostBackendAllowed ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Debug cleartext allowed',
            value: protectionStatus.debugCleartextBackendAllowed ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Native backend issue',
            value: protectionStatus.nativeBackendConfigIssue ?? '-',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.protectionDiagnostics,
        title: 'P3. Protection diagnostics',
        description:
            'Review additive Protection Mode diagnostics and pending queue counters exposed by the SDK.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Diagnostics remain readable both with the default no-op path and with the Android host runtime, without overstating current MVP coverage.',
          howToValidate:
              'Inspect wake, failure, and pending queue fields before and after readiness, enter, flush, or rehydrate actions.',
        ),
        result: _buildProtectionDiagnosticsResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Last wake',
            value: protectionDiagnostics.lastWakeAt == null
                ? '-'
                : _formatDateTime(protectionDiagnostics.lastWakeAt),
          ),
          ValidationStateField(
            label: 'Wake reason',
            value: protectionDiagnostics.lastWakeReason ?? '-',
          ),
          ValidationStateField(
            label: 'Last failure',
            value: protectionDiagnostics.lastFailureReason ?? '-',
          ),
          ValidationStateField(
            label: 'Last platform event',
            value: protectionDiagnostics.lastPlatformEvent ?? '-',
          ),
          ValidationStateField(
            label: 'Last platform event at',
            value: protectionDiagnostics.lastPlatformEventAt == null
                ? '-'
                : _formatDateTime(protectionDiagnostics.lastPlatformEventAt),
          ),
          ValidationStateField(
            label: 'Last restoration event',
            value: protectionDiagnostics.lastRestorationEvent ?? '-',
          ),
          ValidationStateField(
            label: 'Last restoration at',
            value: protectionDiagnostics.lastRestorationEventAt == null
                ? '-'
                : _formatDateTime(protectionDiagnostics.lastRestorationEventAt),
          ),
          ValidationStateField(
            label: 'Last BLE service event',
            value: protectionDiagnostics.lastBleServiceEvent ?? '-',
          ),
          ValidationStateField(
            label: 'Protected device',
            value: protectionDiagnostics.protectedDeviceId ?? '-',
          ),
          ValidationStateField(
            label: 'Expected BLE service',
            value: protectionDiagnostics.expectedBleServiceUuid ?? '-',
          ),
          ValidationStateField(
            label: 'Discovered BLE services',
            value: protectionDiagnostics.discoveredBleServicesSummary ?? '-',
          ),
          ValidationStateField(
            label: 'Readiness failure',
            value: protectionDiagnostics.readinessFailureReason ?? '-',
          ),
          ValidationStateField(
            label: 'Reconnect attempts',
            value: protectionDiagnostics.reconnectAttemptCount.toString(),
          ),
          ValidationStateField(
            label: 'Last reconnect at',
            value: protectionDiagnostics.lastReconnectAttemptAt == null
                ? '-'
                : _formatDateTime(protectionDiagnostics.lastReconnectAttemptAt),
          ),
          ValidationStateField(
            label: 'Pending SOS',
            value: protectionDiagnostics.pendingSosCount.toString(),
          ),
          ValidationStateField(
            label: 'Pending native create',
            value: protectionDiagnostics.pendingNativeSosCreateCount.toString(),
          ),
          ValidationStateField(
            label: 'Pending native cancel',
            value: protectionDiagnostics.pendingNativeSosCancelCount.toString(),
          ),
          ValidationStateField(
            label: 'Pending telemetry',
            value: protectionDiagnostics.pendingTelemetryCount.toString(),
          ),
          ValidationStateField(
            label: 'Native backend result',
            value: protectionDiagnostics.lastNativeBackendHandoffResult ?? '-',
          ),
          ValidationStateField(
            label: 'Native backend error',
            value: protectionDiagnostics.lastNativeBackendHandoffError ?? '-',
          ),
          ValidationStateField(
            label: 'Last command route',
            value: protectionDiagnostics.lastCommandRoute ?? '-',
          ),
          ValidationStateField(
            label: 'Last command result',
            value: protectionDiagnostics.lastCommandResult ?? '-',
          ),
          ValidationStateField(
            label: 'Last command error',
            value: protectionDiagnostics.lastCommandError ?? '-',
          ),
          ValidationStateField(
            label: 'Native backend URL',
            value: protectionDiagnostics.nativeBackendBaseUrl ?? '-',
          ),
          ValidationStateField(
            label: 'Native backend config',
            value: protectionDiagnostics.nativeBackendConfigValid
                ? 'Valid'
                : 'Invalid',
          ),
          ValidationStateField(
            label: 'Debug localhost allowed',
            value: protectionDiagnostics.debugLocalhostBackendAllowed
                ? 'Yes'
                : 'No',
          ),
          ValidationStateField(
            label: 'Debug cleartext allowed',
            value: protectionDiagnostics.debugCleartextBackendAllowed
                ? 'Yes'
                : 'No',
          ),
          ValidationStateField(
            label: 'Native backend issue',
            value: protectionDiagnostics.nativeBackendConfigIssue ?? '-',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.protectionEnter,
        title: 'P4. Enter Protection Mode',
        description:
            'Attempt to enable the optional Protection Mode runtime through the SDK facade.',
        expectation: const ValidationExpectation(
          expectedResult:
              'With the Android host adapter, entry starts the foreground runtime. Without it, entry still fails safely and explains the missing platform capability.',
          howToValidate:
              'Use the enter action and verify the result remains explicit, non-crashing, and additive.',
        ),
        result: _buildProtectionEnterResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Store-and-forward',
            value: protectionStatus.storeAndForwardEnabled ? 'Enabled' : 'Off',
          ),
          ValidationStateField(
            label: 'Platform background ready',
            value: protectionStatus.platformBackgroundCapabilityReady
                ? 'Yes'
                : 'No',
          ),
          ValidationStateField(
            label: 'Foreground service running',
            value: protectionStatus.foregroundServiceRunning ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Realtime ready',
            value: protectionStatus.realtimeReady ? 'Yes' : 'No',
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.protectionExit,
        title: 'P5. Exit Protection Mode',
        description:
            'Stop the additive Protection Mode runtime and return to the default off state.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Exit returns Protection Mode to off/inactive without affecting current SDK SOS/BLE behavior.',
          howToValidate:
              'Run exit and confirm the mode returns to off with no side effects on the rest of the validation console.',
        ),
        result: _buildProtectionExitResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Mode after exit',
            value: protectionStatus.modeState.name,
          ),
          ValidationStateField(
            label: 'Runtime after exit',
            value: protectionStatus.runtimeState.name,
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.protectionFlushQueues,
        title: 'P6. Flush protection queues',
        description:
            'Exercise the MVP queue flush hook without introducing a risky new queueing model.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Queue flush remains a safe stub and reports counts explicitly.',
          howToValidate:
              'Run the flush action and confirm the result is returned cleanly even when nothing is flushed yet.',
        ),
        result: _buildProtectionFlushResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Status pending SOS',
            value: protectionStatus.pendingSosCount.toString(),
          ),
          ValidationStateField(
            label: 'Status pending telemetry',
            value: protectionStatus.pendingTelemetryCount.toString(),
          ),
        ],
      ),
      ValidationCardViewModel(
        id: ValidationCapabilityId.protectionRehydrate,
        title: 'P7. Rehydrate protection state',
        description:
            'Recompute additive Protection Mode state from available SDK context without arming anything automatically.',
        expectation: const ValidationExpectation(
          expectedResult:
              'Rehydration refreshes the current Protection snapshot only and does not alter startup behavior.',
          howToValidate:
              'Run rehydrate and confirm the status refreshes while the rest of the SDK remains untouched.',
        ),
        result: _buildProtectionRehydrateResult(),
        currentState: <ValidationStateField>[
          ValidationStateField(
            label: 'Session ready',
            value: protectionStatus.sessionReady ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Device paired',
            value: protectionStatus.devicePaired ? 'Yes' : 'No',
          ),
          ValidationStateField(
            label: 'Bluetooth ready',
            value: protectionStatus.bluetoothEnabled ? 'Yes' : 'No',
          ),
        ],
      ),
    ];
  }

  ValidationSummaryViewModel buildCoreSummaryViewModel({
    required ValidationBackendConfig activeBackendConfig,
    required bool activeBackendLocalhostWarning,
    required ValidationBackendConfig draftBackendConfig,
    required bool draftBackendLocalhostWarning,
    required bool backendApplyInProgress,
    required int sdkGeneration,
  }) {
    final cards = buildMvpCapabilityCards(
      activeBackendConfig: activeBackendConfig,
      activeBackendLocalhostWarning: activeBackendLocalhostWarning,
      draftBackendConfig: draftBackendConfig,
      draftBackendLocalhostWarning: draftBackendLocalhostWarning,
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
      title: 'Core Readiness',
      description:
          'Core backend and operational readiness (${cards.length} capability cards)',
      totalCapabilities: cards.length,
      passed: passed,
      warning: warning,
      failed: failed,
      notRun: notRun,
      running: running,
      readiness: readiness,
    );
  }

  ValidationSummaryViewModel buildBleSummaryViewModel() {
    final cards = buildBleCapabilityCards();
    return _buildSummaryFromCards(
      title: 'BLE / Device Readiness',
      description:
          'BLE and device readiness (${cards.length} capability cards)',
      cards: cards,
    );
  }

  ValidationSummaryViewModel buildProtectionSummaryViewModel() {
    final cards = buildProtectionCapabilityCards();
    return _buildSummaryFromCards(
      title: 'Protection Mode Readiness',
      description:
          'Optional Protection Mode readiness (${cards.length} capability cards)',
      cards: cards,
    );
  }

  ValidationSummaryViewModel buildSummaryViewModel({
    required ValidationBackendConfig activeBackendConfig,
    required bool activeBackendLocalhostWarning,
    required ValidationBackendConfig draftBackendConfig,
    required bool draftBackendLocalhostWarning,
    required bool backendApplyInProgress,
    required int sdkGeneration,
  }) {
    final cards = <ValidationCardViewModel>[
      ...buildMvpCapabilityCards(
        activeBackendConfig: activeBackendConfig,
        activeBackendLocalhostWarning: activeBackendLocalhostWarning,
        draftBackendConfig: draftBackendConfig,
        draftBackendLocalhostWarning: draftBackendLocalhostWarning,
        backendApplyInProgress: backendApplyInProgress,
        sdkGeneration: sdkGeneration,
      ),
      ...buildBleCapabilityCards(),
      ...buildProtectionCapabilityCards(),
    ];
    return _buildSummaryFromCards(
      title: 'Overall Readiness',
      description:
          'Unified SDK validation readiness (${cards.length} capability cards)',
      cards: cards,
    );
  }

  ValidationSummaryViewModel _buildSummaryFromCards({
    required String title,
    required String description,
    required List<ValidationCardViewModel> cards,
  }) {
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
      title: title,
      description: description,
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

  void resetValidationNoise() {
    lastIdentityError = null;
    lastActionError = null;
    lastNotificationsError = null;
    notificationsInitialized = false;
    notificationTestTriggered = false;
    _capabilityRuns.clear();
    notifyListeners();
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

  bool get _triggerSosLocationGranted =>
      permissionState?.hasLocationAccess ?? false;

  bool get triggerSosLocationNeedsSettings {
    final location = permissionState?.location;
    return location == SdkPermissionStatus.permanentlyDenied ||
        location == SdkPermissionStatus.restricted ||
        location == SdkPermissionStatus.serviceDisabled;
  }

  String get triggerSosLocationPrerequisiteLabel {
    final location = permissionState?.location;
    if (_triggerSosLocationGranted) {
      return 'Granted';
    }
    if (triggerSosLocationNeedsSettings) {
      return 'Permanently denied';
    }
    if (location == SdkPermissionStatus.denied) {
      return 'Missing';
    }
    return location?.name ?? 'Unknown';
  }

  bool get triggerSosSessionReady =>
      _hasSignedSession && _canonicalIdentityResolved;

  bool get triggerSosMqttReady =>
      operationalDiagnostics.connectionState ==
          RealtimeConnectionState.connected &&
      _mqttTopicReady;

  Future<void> requestTriggerSosLocationPermission() async {
    lastActionError = null;
    notifyListeners();
    try {
      await sdk.requestLocationPermission();
      await deviceDebugController.refreshPermissions();
      _recordCapabilityResult(
        ValidationCapabilityId.permissions,
        _buildPermissionsResult(),
      );
    } catch (error) {
      _handleActionError(error);
    }
  }

  Future<void> openTriggerSosAppSettings() async {
    lastActionError = null;
    notifyListeners();
    try {
      final opened = await permission_handler.openAppSettings();
      if (!opened) {
        _handleActionError(
          StateError('Unable to open app settings for location permission.'),
        );
        return;
      }
      await deviceDebugController.refreshPermissions();
      _recordCapabilityResult(
        ValidationCapabilityId.permissions,
        _buildPermissionsResult(),
      );
    } catch (error) {
      _handleActionError(error);
    }
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
    if (recorded != null) {
      return recorded;
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
    if (recorded != null) {
      return recorded;
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
    if (recorded != null) {
      return recorded;
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
    required ValidationBackendConfig draftBackendConfig,
    required bool draftBackendLocalhostWarning,
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
    if (draftBackendConfig.apiBaseUrl.trim().isEmpty ||
        draftBackendConfig.mqttWebsocketUrl.trim().isEmpty) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: 'Draft backend configuration is incomplete.',
      );
    }
    if (draftBackendLocalhostWarning) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'The pending draft backend uses localhost/127.0.0.1. On a physical Android device that points to the phone itself unless you use adb reverse.',
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

  ValidationCapabilityResult _buildProtectionReadinessResult() {
    final recorded =
        _capabilityRuns[ValidationCapabilityId.protectionReadiness];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if (protectionReadiness.canArm) {
      return _mergeWithRecorded(
        ValidationCapabilityId.protectionReadiness,
        ValidationCapabilityResult(
          status: protectionReadiness.warnings.isEmpty
              ? ValidationRunStatus.ok
              : ValidationRunStatus.warning,
          diagnosticText: protectionReadiness.warnings.isEmpty
              ? 'Protection Mode can be armed from the current SDK context.'
              : protectionReadiness.warnings.join(' '),
        ),
      );
    }
    if (protectionReadiness.blockingIssues.isNotEmpty) {
      return _mergeWithRecorded(
        ValidationCapabilityId.protectionReadiness,
        ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText: protectionReadiness.blockingIssues
              .map((issue) => issue.message)
              .join(' '),
        ),
      );
    }
    return _mergeWithRecorded(
      ValidationCapabilityId.protectionReadiness,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.notRun,
        diagnosticText:
            'Protection Mode is optional and currently off. Run readiness to inspect blockers and warnings.',
      ),
    );
  }

  ValidationCapabilityResult _buildProtectionStatusResult() {
    return ValidationCapabilityResult(
      status: protectionStatus.modeState == ProtectionModeState.off
          ? ValidationRunStatus.notRun
          : protectionStatus.modeState == ProtectionModeState.error
              ? ValidationRunStatus.nok
              : protectionStatus.modeState == ProtectionModeState.degraded
                  ? ValidationRunStatus.warning
                  : ValidationRunStatus.ok,
      diagnosticText:
          'Protection Mode is ${protectionStatus.modeState.name} on ${protectionStatus.platform.name} with ${protectionStatus.coverageLevel.name} coverage, BLE owner ${protectionStatus.bleOwner.name}, and runtime ${protectionStatus.runtimeState.name}.',
    );
  }

  ValidationCapabilityResult _buildProtectionDiagnosticsResult() {
    if ((protectionDiagnostics.lastFailureReason ?? '').trim().isNotEmpty) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText: protectionDiagnostics.lastFailureReason,
      );
    }
    return ValidationCapabilityResult(
      status: (protectionDiagnostics.lastPlatformEvent ?? '').trim().isNotEmpty
          ? ValidationRunStatus.ok
          : ValidationRunStatus.notRun,
      diagnosticText: (protectionDiagnostics.lastPlatformEvent ?? '')
              .trim()
              .isNotEmpty
          ? 'Latest protection event: ${protectionDiagnostics.lastPlatformEvent}.'
          : 'Protection diagnostics are idle until readiness, enter, flush, or rehydrate actions are run.',
    );
  }

  ValidationCapabilityResult _buildProtectionEnterResult([
    EnterProtectionModeResult? result,
  ]) {
    final recorded = _capabilityRuns[ValidationCapabilityId.protectionEnter];
    if (result != null) {
      final degradationReason = result.status.degradationReason;
      return ValidationCapabilityResult(
        status: result.success
            ? (result.status.modeState == ProtectionModeState.degraded
                ? ValidationRunStatus.warning
                : ValidationRunStatus.ok)
            : ValidationRunStatus.warning,
        diagnosticText: result.success
            ? result.status.modeState == ProtectionModeState.degraded
                ? degradationReason ??
                    'Protection Mode entered in a degraded state, but no explicit degradation reason was surfaced.'
                : 'Protection Mode entered with ${result.status.modeState.name} coverage semantics.'
            : (result.blockingIssues.isEmpty
                ? 'Protection Mode could not be entered.'
                : result.blockingIssues
                    .map((issue) => issue.message)
                    .join(' ')),
      );
    }
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if (recorded != null) {
      return recorded;
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Enter Protection Mode explicitly to validate the additive lifecycle.',
    );
  }

  ValidationCapabilityResult _buildProtectionExitResult({
    bool ignoreRunningRecord = false,
  }) {
    final recorded = _capabilityRuns[ValidationCapabilityId.protectionExit];
    if (!ignoreRunningRecord &&
        recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if ((lastActionError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastActionError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (recorded == null) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.notRun,
        diagnosticText:
            'Exit Protection Mode explicitly to validate the additive shutdown lifecycle.',
      );
    }
    if (protectionStatus.modeState != ProtectionModeState.off) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Exit was requested, but Protection Mode still reports ${protectionStatus.modeState.name}/${protectionStatus.runtimeState.name}.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    return ValidationCapabilityResult(
      status: ValidationRunStatus.ok,
      diagnosticText: 'Protection Mode has been returned to the off state.',
      lastExecutedAt: recorded.lastExecutedAt,
    );
  }

  ValidationCapabilityResult _buildProtectionFlushResult() {
    final recorded =
        _capabilityRuns[ValidationCapabilityId.protectionFlushQueues];
    if (recorded != null) {
      return recorded;
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Protection queue flushing is available as an MVP stub and has not been run yet.',
    );
  }

  ValidationCapabilityResult _buildProtectionRehydrateResult() {
    final recorded =
        _capabilityRuns[ValidationCapabilityId.protectionRehydrate];
    if (recorded != null) {
      return recorded;
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Protection state rehydration is available but has not been run yet.',
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

  _SosValidationSnapshot _captureSosValidationSnapshot() {
    return _SosValidationSnapshot(
      incidentId: lastSosIncident?.id,
      incidentState: lastSosIncident?.state,
      lastSosEventType: lastSosEvent?.runtimeType.toString(),
    );
  }

  Future<void> _refreshSosValidationState() async {
    sosState = await sdk.getSosState();
    lastSosIncident = await sdk.getCurrentSosIncident();
    operationalDiagnostics = await sdk.getOperationalDiagnostics();
    notifyListeners();
  }

  _TelemetryValidationSnapshot _captureTelemetryValidationSnapshot() {
    return _TelemetryValidationSnapshot(
      lastDecision: operationalDiagnostics.bridge.lastDecision,
      hasPendingTelemetry:
          operationalDiagnostics.bridge.pendingTelemetry != null,
      lastSampleSignature:
          _telemetryPayloadSignature(lastPublishedTelemetrySample),
    );
  }

  Future<void> _refreshTelemetryValidationState() async {
    operationalDiagnostics = await sdk.getOperationalDiagnostics();
    notifyListeners();
  }

  String? _telemetryPayloadSignature(SdkTelemetryPayload? payload) {
    return payload?.toJson().toString();
  }

  Future<void> _runBoundedValidation<T>({
    required ValidationCapabilityId id,
    required String runningDiagnostic,
    required Duration timeout,
    required T Function() captureBaseline,
    required Future<void> Function() action,
    required Future<void> Function() refresh,
    required ValidationCapabilityResult Function(T baseline, Duration timeout)
        evaluate,
  }) async {
    final baseline = captureBaseline();
    final startedAt = DateTime.now().toUtc();
    _recordCapabilityResult(
      id,
      ValidationCapabilityResult(
        status: ValidationRunStatus.running,
        diagnosticText: runningDiagnostic,
        lastExecutedAt: startedAt,
      ),
    );
    lastActionError = null;

    final stopwatch = Stopwatch()..start();
    try {
      await action();
      final actionError = (lastActionError ?? '').trim();
      if (actionError.isNotEmpty) {
        _recordCapabilityResult(
          id,
          ValidationCapabilityResult(
            status: ValidationRunStatus.nok,
            diagnosticText: actionError,
            lastExecutedAt: startedAt,
          ),
        );
        return;
      }

      await refresh();
      final immediate = evaluate(baseline, timeout);
      if (immediate.status == ValidationRunStatus.ok) {
        _recordCapabilityResult(
          id,
          immediate.copyWith(lastExecutedAt: startedAt),
        );
        return;
      }

      final remaining = timeout - stopwatch.elapsed;
      if (remaining > Duration.zero) {
        await Future.delayed(remaining);
        await refresh();
      }

      final settled = evaluate(baseline, timeout);
      _recordCapabilityResult(id, settled.copyWith(lastExecutedAt: startedAt));
    } catch (error) {
      _recordCapabilityResult(
        id,
        ValidationCapabilityResult(
          status: ValidationRunStatus.nok,
          diagnosticText: error.toString(),
          lastExecutedAt: startedAt,
        ),
      );
    }
  }

  ValidationCapabilityResult _evaluateTriggerSosValidation(
    _SosValidationSnapshot baseline,
    Duration timeout,
  ) {
    if (_hasObservableTriggeredSos(baseline)) {
      final incidentId = lastSosIncident?.id;
      final detail = incidentId == null
          ? 'SOS left idle state within ${timeout.inSeconds} seconds.'
          : 'SOS left idle state and incident $incidentId is visible within ${timeout.inSeconds} seconds.';
      return ValidationCapabilityResult(
        status: ValidationRunStatus.ok,
        diagnosticText: detail,
      );
    }

    if (_hasAcceptedButPendingTriggerEvidence()) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Trigger SOS was accepted locally, but after ${timeout.inSeconds} seconds the SDK still shows pending or propagating state.',
      );
    }

    return ValidationCapabilityResult(
      status: ValidationRunStatus.nok,
      diagnosticText:
          'Trigger SOS produced no observable runtime/backend evidence within ${timeout.inSeconds} seconds.',
    );
  }

  ValidationCapabilityResult _evaluateCancelSosValidation(
    _SosValidationSnapshot baseline,
    Duration timeout,
  ) {
    final backendVisibleState = lastSosIncident?.state;
    if (_isNonActiveSosState(sosState) ||
        _isNonActiveIncidentState(backendVisibleState)) {
      final visibleState = backendVisibleState;
      final detailState = _isNonActiveIncidentState(visibleState)
          ? visibleState!.name
          : sosState.name;
      return ValidationCapabilityResult(
        status: ValidationRunStatus.ok,
        diagnosticText:
            'SOS cancellation settled to $detailState within ${timeout.inSeconds} seconds.',
      );
    }

    if (_hasAcceptedButPendingCancelEvidence(baseline)) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Cancel SOS was accepted locally, but after ${timeout.inSeconds} seconds the runtime still shows ${sosState.name}.',
      );
    }

    return ValidationCapabilityResult(
      status: ValidationRunStatus.nok,
      diagnosticText:
          'Cancel SOS produced no meaningful runtime/backend state change within ${timeout.inSeconds} seconds.',
    );
  }

  ValidationCapabilityResult _evaluateTelemetryValidation(
    _TelemetryValidationSnapshot baseline,
    Duration timeout,
  ) {
    if (_hasObservableTelemetrySuccess(baseline)) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.ok,
        diagnosticText:
            'Telemetry sample publish is observable within ${timeout.inSeconds} seconds.',
      );
    }

    if (_hasAcceptedButPendingTelemetryEvidence(baseline)) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Telemetry sample was accepted locally, but after ${timeout.inSeconds} seconds it is still buffered or awaiting propagation.',
      );
    }

    return ValidationCapabilityResult(
      status: ValidationRunStatus.nok,
      diagnosticText:
          'Telemetry sample produced no observable publish evidence within ${timeout.inSeconds} seconds.',
    );
  }

  bool _hasObservableTriggeredSos(_SosValidationSnapshot baseline) {
    return sosState != SosState.idle || _sosEventChangedFromBaseline(baseline);
  }

  bool _hasAcceptedButPendingTriggerEvidence() {
    return operationalDiagnostics.bridge.pendingSos != null;
  }

  bool _hasAcceptedButPendingCancelEvidence(_SosValidationSnapshot baseline) {
    return sosState == SosState.cancelRequested ||
        sosState == SosState.sending ||
        sosState == SosState.sent ||
        sosState == SosState.acknowledged ||
        _incidentChangedFromBaseline(baseline) ||
        _sosEventChangedFromBaseline(baseline);
  }

  bool _hasObservableTelemetrySuccess(_TelemetryValidationSnapshot baseline) {
    final decision =
        operationalDiagnostics.bridge.lastDecision?.toLowerCase() ?? '';
    return operationalDiagnostics.bridge.pendingTelemetry == null &&
        !_isTelemetryFailureDecision(decision) &&
        (_telemetryPayloadSignature(lastPublishedTelemetrySample) !=
                baseline.lastSampleSignature ||
            (decision != (baseline.lastDecision?.toLowerCase() ?? '') &&
                decision.contains('telemetry published')));
  }

  bool _hasAcceptedButPendingTelemetryEvidence(
    _TelemetryValidationSnapshot baseline,
  ) {
    final decision =
        operationalDiagnostics.bridge.lastDecision?.toLowerCase() ?? '';
    return operationalDiagnostics.bridge.pendingTelemetry != null ||
        ((baseline.lastDecision?.toLowerCase() ?? '') != decision &&
            decision.contains('telemetry buffered')) ||
        decision.contains('telemetry publish queued') ||
        decision.contains('awaiting propagation');
  }

  bool _isTelemetryFailureDecision(String decision) {
    return decision.contains('telemetry publish failed') ||
        decision.contains('telemetry rejected');
  }

  bool _incidentChangedFromBaseline(_SosValidationSnapshot baseline) {
    return lastSosIncident?.id != baseline.incidentId ||
        lastSosIncident?.state != baseline.incidentState;
  }

  bool _sosEventChangedFromBaseline(_SosValidationSnapshot baseline) {
    return lastSosEvent?.runtimeType.toString() != baseline.lastSosEventType;
  }

  bool _isNonActiveSosState(SosState state) {
    return state == SosState.idle ||
        state == SosState.cancelled ||
        state == SosState.resolved;
  }

  bool _isNonActiveIncidentState(SosState? state) {
    return state == SosState.cancelled || state == SosState.resolved;
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

  ValidationCapabilityResult _buildPermissionsResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.permissions];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    final current = permissionState;
    final lastError = deviceDebugController.lastError;
    if ((lastError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (current == null) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.notRun,
        diagnosticText:
            'Refresh permissions to load Bluetooth, notifications, and adapter state.',
      );
    }
    if (current.hasBluetoothAccess && current.bluetoothEnabled) {
      final notificationsReady = current.hasNotificationAccess;
      return _mergeWithRecorded(
        ValidationCapabilityId.permissions,
        ValidationCapabilityResult(
          status: notificationsReady
              ? ValidationRunStatus.ok
              : ValidationRunStatus.warning,
          diagnosticText: notificationsReady
              ? 'Bluetooth permission and adapter state are ready for BLE validation.'
              : 'Bluetooth is ready, but notification permission still needs operator confirmation.',
        ),
      );
    }
    return _mergeWithRecorded(
      ValidationCapabilityId.permissions,
      const ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Bluetooth permission or adapter state still needs user action before BLE validation can proceed.',
      ),
    );
  }

  ValidationCapabilityResult _buildNotificationsResult() {
    return _computeNotificationsResult();
  }

  ValidationCapabilityResult _computeNotificationsResult({
    bool ignoreRunningRecord = false,
  }) {
    final recorded = _capabilityRuns[ValidationCapabilityId.notifications];
    if (!ignoreRunningRecord &&
        recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if ((lastNotificationsError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastNotificationsError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (notificationsInitialized && notificationTestTriggered) {
      return _mergeWithRecorded(
        ValidationCapabilityId.notifications,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'Notifications initialized successfully and a test notification was triggered.',
        ),
      );
    }
    if (notificationsInitialized || notificationTestTriggered) {
      return _mergeWithRecorded(
        ValidationCapabilityId.notifications,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'Notifications are partially validated. Run both initialize and test actions for a complete check.',
        ),
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Initialize notifications and trigger a test notification to validate this path.',
    );
  }

  ValidationCapabilityResult _buildBleScanResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.bleScan];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    final lastError = deviceDebugController.lastError;
    if ((lastError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (bleDebugState.scanResults.isNotEmpty) {
      return _mergeWithRecorded(
        ValidationCapabilityId.bleScan,
        ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'BLE scan returned ${bleDebugState.scanResults.length} result(s).',
        ),
      );
    }
    if (recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'BLE scan completed but no devices were discovered in the current environment.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText: 'Run a BLE scan to validate discoverability.',
    );
  }

  ValidationCapabilityResult _buildPairConnectResult() {
    return _computePairConnectResult();
  }

  ValidationCapabilityResult _computePairConnectResult({
    bool ignoreRunningRecord = false,
  }) {
    final recorded = _capabilityRuns[ValidationCapabilityId.pairConnectDevice];
    if (!ignoreRunningRecord &&
        recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if (deviceStatus?.connected == true) {
      return _mergeWithRecorded(
        ValidationCapabilityId.pairConnectDevice,
        ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'Device ${deviceStatus?.deviceId ?? ''} is connected through the SDK.',
        ),
      );
    }
    final lastError =
        bleDebugState.connectionError ?? deviceDebugController.lastError;
    if ((lastError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if ((bleDebugState.selectedDeviceId ?? '').isNotEmpty ||
        deviceStatus?.paired == true) {
      return _mergeWithRecorded(
        ValidationCapabilityId.pairConnectDevice,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'A device is selected or paired, but the runtime is not fully connected yet.',
        ),
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Connect the device from the validation console or from a selected scan result.',
    );
  }

  ValidationCapabilityResult _buildActivateDeviceResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.activateDevice];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    final lastError = deviceDebugController.lastError;
    if ((lastError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (deviceStatus?.activated == true ||
        deviceStatus?.isReadyForSafety == true) {
      return _mergeWithRecorded(
        ValidationCapabilityId.activateDevice,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText: 'Device activation is reflected in runtime status.',
        ),
      );
    }
    if (recorded != null && deviceStatus?.paired == true) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Activation was requested, but the runtime does not look fully activated yet.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Connect a device first, then run activation from this console.',
    );
  }

  ValidationCapabilityResult _buildRefreshDeviceStatusResult() {
    final recorded =
        _capabilityRuns[ValidationCapabilityId.refreshDeviceStatus];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    final lastError = deviceDebugController.lastError;
    if ((lastError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (deviceStatus == null) {
      return const ValidationCapabilityResult(
        status: ValidationRunStatus.notRun,
        diagnosticText: 'Refresh device status after connecting a device.',
      );
    }
    final hasKeyFields = (deviceStatus!.deviceId.trim().isNotEmpty) &&
        ((deviceStatus!.model ?? '').trim().isNotEmpty) &&
        ((deviceStatus!.firmwareVersion ?? '').trim().isNotEmpty);
    return _mergeWithRecorded(
      ValidationCapabilityId.refreshDeviceStatus,
      ValidationCapabilityResult(
        status:
            hasKeyFields ? ValidationRunStatus.ok : ValidationRunStatus.warning,
        diagnosticText: hasKeyFields
            ? 'Device status refreshed and key metadata is visible.'
            : 'Device status refreshed, but some fields are still missing.',
      ),
    );
  }

  ValidationCapabilityResult _buildUnpairDeviceResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.unpairDevice];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    final lastError = deviceDebugController.lastError;
    if ((lastError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (recorded != null &&
        deviceStatus?.paired != true &&
        deviceStatus?.connected != true) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.ok,
        diagnosticText:
            'The runtime no longer reports an active paired or connected device.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'Unpair was requested, but some device state still remains. Refresh the runtime once more.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText: 'Run unpair/disconnect to validate device cleanup.',
    );
  }

  ValidationCapabilityResult _buildDeviceSosResult() {
    return _computeDeviceSosResult();
  }

  ValidationCapabilityResult _computeDeviceSosResult({
    bool ignoreRunningRecord = false,
  }) {
    final recorded = _capabilityRuns[ValidationCapabilityId.deviceSosFlow];
    if (!ignoreRunningRecord &&
        recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    final lastError = deviceDebugController.lastError;
    if ((lastError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (recorded != null && deviceSosStatus.optimistic) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.warning,
        diagnosticText:
            'The device SOS action was accepted, but final propagation still looks optimistic/pending.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.ok,
        diagnosticText:
            'Device/runtime SOS state is ${deviceSosStatus.state.name} with source ${deviceSosStatus.transitionSource.name}. Backend persistence is not guaranteed by this card alone.',
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Run a device SOS action from this console to validate device/runtime state transitions. Backend persistence must be confirmed separately.',
    );
  }

  ValidationCapabilityResult _buildCommandChannelReadinessResult() {
    final recorded =
        _capabilityRuns[ValidationCapabilityId.commandChannelReadiness];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    final lastError =
        bleDebugState.connectionError ?? deviceDebugController.lastError;
    if ((lastError ?? '').trim().isNotEmpty && recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    final connected = deviceStatus?.connected == true;
    if (connected &&
        bleDebugState.commandWriterReady &&
        bleDebugState.eixamServiceFound &&
        bleDebugState.telFound &&
        bleDebugState.sosFound &&
        bleDebugState.inetFound) {
      return _mergeWithRecorded(
        ValidationCapabilityId.commandChannelReadiness,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'Command writer and required BLE characteristics are ready.',
        ),
      );
    }
    if (connected) {
      return _mergeWithRecorded(
        ValidationCapabilityId.commandChannelReadiness,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'The device is connected, but command-path readiness is still incomplete.',
        ),
      );
    }
    return const ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Connect a device first, then refresh diagnostics to validate command readiness.',
    );
  }

  ValidationCapabilityResult _buildInetCommandsResult() {
    return _buildWriteResultFor(
      ValidationCapabilityId.inetCommands,
      notRunDiagnostic:
          'Send INET OK, INET LOST, or POS CONFIRMED to validate the command path.',
    );
  }

  ValidationCapabilityResult _buildAckRelayResult() {
    return _buildWriteResultFor(
      ValidationCapabilityId.ackRelay,
      notRunDiagnostic:
          'Enter a relay node id and send ACK relay to validate this path.',
    );
  }

  ValidationCapabilityResult _buildShutdownResult() {
    if (protectionStatus.modeState != ProtectionModeState.off &&
        protectionStatus.bleOwner != ProtectionBleOwner.flutter) {
      return _buildProtectionShutdownResult();
    }
    return _buildWriteResultFor(
      ValidationCapabilityId.shutdownCommand,
      notRunDiagnostic:
          'Send shutdown only when you intentionally want to validate that guarded path.',
    );
  }

  ValidationCapabilityResult _buildWriteResultFor(
    ValidationCapabilityId id, {
    required String notRunDiagnostic,
    bool ignoreRunningRecord = false,
  }) {
    final recorded = _capabilityRuns[id];
    if (!ignoreRunningRecord &&
        recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if ((deviceDebugController.lastError ?? '').trim().isNotEmpty &&
        recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: deviceDebugController.lastError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if ((bleDebugState.lastWriteError ?? '').trim().isNotEmpty &&
        recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: bleDebugState.lastWriteError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if ((bleDebugState.lastWriteResult ?? '')
        .toLowerCase()
        .contains('success')) {
      return _mergeWithRecorded(
        id,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText: 'The last command write completed successfully.',
        ),
      );
    }
    if (bleDebugState.commandWriterReady) {
      return _mergeWithRecorded(
        id,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'The command path exists, but the last write result is not fully confirmed yet.',
        ),
      );
    }
    return ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText: notRunDiagnostic,
    );
  }

  ValidationCapabilityResult _buildProtectionShutdownResult() {
    final recorded = _capabilityRuns[ValidationCapabilityId.shutdownCommand];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if ((protectionStatus.lastCommandError ?? '').trim().isNotEmpty &&
        recorded != null) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: protectionStatus.lastCommandError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if ((protectionStatus.lastCommandResult ?? '').trim().isNotEmpty &&
        (protectionStatus.lastCommandRoute ?? '').trim().isNotEmpty) {
      return _mergeWithRecorded(
        ValidationCapabilityId.shutdownCommand,
        ValidationCapabilityResult(
          status: ValidationRunStatus.ok,
          diagnosticText:
              'Shutdown validated through ${protectionStatus.lastCommandRoute}: ${protectionStatus.lastCommandResult}',
        ),
      );
    }
    if (protectionStatus.protectionRuntimeActive ||
        protectionStatus.serviceBleConnected) {
      return _mergeWithRecorded(
        ValidationCapabilityId.shutdownCommand,
        ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'Protection Mode is armed with ${protectionStatus.bleOwner.name} as BLE owner, but the native shutdown result is not confirmed yet.',
        ),
      );
    }
    return ValidationCapabilityResult(
      status: ValidationRunStatus.notRun,
      diagnosticText:
          'Arm Protection Mode and run shutdown to validate the ${protectionStatus.bleOwner.name} native owner command path.',
    );
  }

  ValidationCapabilityResult _buildBackendDeviceRegistryAlignmentResult() {
    final recorded =
        _capabilityRuns[ValidationCapabilityId.backendDeviceRegistryAlignment];
    if (recorded?.status == ValidationRunStatus.running) {
      return recorded!;
    }
    if ((lastActionError ?? '').trim().isNotEmpty &&
        recorded != null &&
        lastActionError!.toLowerCase().contains('device')) {
      return ValidationCapabilityResult(
        status: ValidationRunStatus.nok,
        diagnosticText: lastActionError,
        lastExecutedAt: recorded.lastExecutedAt,
      );
    }
    if (!isSignedSessionIdentityReady) {
      return _mergeWithRecorded(
        ValidationCapabilityId.backendDeviceRegistryAlignment,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'Set a signed session first so the SDK can auto-sync the paired device into the backend registry.',
        ),
      );
    }
    if (!isRuntimeDeviceReadyForRegistrySync) {
      return _mergeWithRecorded(
        ValidationCapabilityId.backendDeviceRegistryAlignment,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'Connect a paired device first. Backend registry auto-sync runs from the SDK runtime after a successful device connection.',
        ),
      );
    }
    if (registeredDevices.isEmpty) {
      return _mergeWithRecorded(
        ValidationCapabilityId.backendDeviceRegistryAlignment,
        const ValidationCapabilityResult(
          status: ValidationRunStatus.warning,
          diagnosticText:
              'No backend registered devices are currently loaded. The SDK will only auto-sync when it can resolve a canonical backend hardware_id safely.',
        ),
      );
    }
    return _mergeWithRecorded(
      ValidationCapabilityId.backendDeviceRegistryAlignment,
      ValidationCapabilityResult(
        status: registeredDevices.length == 1
            ? ValidationRunStatus.ok
            : ValidationRunStatus.warning,
        diagnosticText: registeredDevices.length == 1
            ? 'A backend registered device is loaded, so the SDK can keep that entry auto-synced after successful pairing/connection.'
            : 'Multiple backend registered devices are loaded. The SDK will only auto-sync when it can resolve one safely from backend data and runtime metadata.',
      ),
    );
  }

  String _formatDateTime(DateTime? value) {
    if (value == null) {
      return '-';
    }
    final local = value.toLocal();
    final year = local.year.toString().padLeft(4, '0');
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute:$second';
  }

  String _formatPositionSnapshot(TrackingPosition? value) {
    if (value == null) {
      return 'null';
    }
    final altitude =
        value.altitude == null ? 'n/a' : value.altitude!.toString();
    return '${value.latitude.toStringAsFixed(5)}, '
        '${value.longitude.toStringAsFixed(5)} '
        '(alt=$altitude at ${_formatDateTime(value.timestamp)})';
  }

  String _formatSosIncident(SosIncident? incident) {
    if (incident == null) {
      return 'null';
    }
    return '${incident.id} (${incident.state.name})';
  }

  void _requestDeviceSosObservabilityRefresh() {
    if (_refreshingDeviceSosObservability) {
      _pendingDeviceSosObservabilityRefresh = true;
      return;
    }
    unawaited(_drainDeviceSosObservabilityRefreshQueue());
  }

  Future<void> _drainDeviceSosObservabilityRefreshQueue() async {
    do {
      _pendingDeviceSosObservabilityRefresh = false;
      _refreshingDeviceSosObservability = true;
      try {
        operationalDiagnostics = await sdk.getOperationalDiagnostics();
        currentSosIncident = await sdk.getCurrentSosIncident();
        currentPositionSnapshot = await sdk.getCurrentPosition();
      } catch (_) {
        // Best-effort diagnostics refresh for validation UI only.
      } finally {
        _refreshingDeviceSosObservability = false;
      }
    } while (_pendingDeviceSosObservabilityRefresh);
    notifyListeners();
  }

  Future<void> _runBleCapabilityAction({
    required ValidationCapabilityId id,
    required String runningDiagnostic,
    required Future<void> Function() action,
    required ValidationCapabilityResult Function() evaluate,
    Future<void> Function()? onAfterAction,
  }) async {
    _recordCapabilityResult(
      id,
      ValidationCapabilityResult(
        status: ValidationRunStatus.running,
        diagnosticText: runningDiagnostic,
      ),
    );
    lastActionError = null;
    try {
      await action();
      if (onAfterAction != null) {
        await onAfterAction();
      }
      final lastError =
          deviceDebugController.lastError ?? bleDebugState.lastWriteError;
      if ((lastError ?? '').trim().isNotEmpty &&
          _evaluateBleCapabilityAction(id, evaluate).status !=
              ValidationRunStatus.ok) {
        _recordCapabilityResult(
          id,
          ValidationCapabilityResult(
            status: ValidationRunStatus.nok,
            diagnosticText: lastError,
            lastExecutedAt: DateTime.now().toUtc(),
          ),
        );
        return;
      }
      _recordCapabilityResult(id, _evaluateBleCapabilityAction(id, evaluate));
    } catch (error) {
      _recordCapabilityResult(
        id,
        ValidationCapabilityResult(
          status: ValidationRunStatus.nok,
          diagnosticText: error.toString(),
          lastExecutedAt: DateTime.now().toUtc(),
        ),
      );
    }
  }

  ValidationCapabilityResult _evaluateBleCapabilityAction(
    ValidationCapabilityId id,
    ValidationCapabilityResult Function() evaluate,
  ) {
    final recorded = _capabilityRuns[id];
    if (recorded?.status != ValidationRunStatus.running) {
      return evaluate();
    }

    _capabilityRuns[id] =
        recorded!.copyWith(status: ValidationRunStatus.notRun);
    try {
      return evaluate();
    } finally {
      final current = _capabilityRuns[id];
      if (current?.status == ValidationRunStatus.notRun &&
          current?.lastExecutedAt == recorded.lastExecutedAt) {
        _capabilityRuns[id] = recorded;
      }
    }
  }

  @override
  void dispose() {
    _operationalSub?.cancel();
    _realtimeSub?.cancel();
    _sosStateSub?.cancel();
    _sosEventSub?.cancel();
    _contactsSub?.cancel();
    _deviceStatusSub?.cancel();
    _protectionStatusSub?.cancel();
    _protectionDiagnosticsSub?.cancel();
    if (_deviceDebugListener != null) {
      deviceDebugController.removeListener(_deviceDebugListener!);
    }
    deviceDebugController.dispose();
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

class _SosValidationSnapshot {
  const _SosValidationSnapshot({
    required this.incidentId,
    required this.incidentState,
    required this.lastSosEventType,
  });

  final String? incidentId;
  final SosState? incidentState;
  final String? lastSosEventType;
}

class _TelemetryValidationSnapshot {
  const _TelemetryValidationSnapshot({
    required this.lastDecision,
    required this.hasPendingTelemetry,
    required this.lastSampleSignature,
  });

  final String? lastDecision;
  final bool hasPendingTelemetry;
  final String? lastSampleSignature;
}
