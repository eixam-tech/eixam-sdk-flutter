import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

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
    });
  }

  Future<void> clearSession() async {
    await _runSessionAction(() async {
      await sdk.clearSession();
      session = await sdk.getCurrentSession();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
    });
  }

  Future<void> refreshCanonicalIdentity() async {
    await _runSessionAction(() async {
      session = await sdk.refreshCanonicalIdentity();
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
    });
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
    });
  }

  Future<void> cancelSos() async {
    await _runAction((value) => loadingSos = value, () async {
      lastSosIncident = await sdk.cancelSos();
      sosState = await sdk.getSosState();
    });
  }

  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    await _runAction((value) => loadingTelemetry = value, () async {
      await sdk.publishTelemetry(payload);
      lastPublishedTelemetrySample = payload;
      operationalDiagnostics = await sdk.getOperationalDiagnostics();
    });
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

  Future<void> _runSessionAction(Future<void> Function() action) async {
    loadingSession = true;
    lastIdentityError = null;
    lastActionError = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      lastIdentityError = error.toString();
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
