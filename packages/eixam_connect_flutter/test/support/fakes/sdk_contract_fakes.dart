import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/known_device_reconnect_repository.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:eixam_connect_flutter/src/data/repositories/telemetry_repository.dart';

class FakeSosRepository implements SosRepository {
  SosIncident currentIncident = SosIncident(
    id: 'sos-1',
    state: SosState.idle,
    createdAt: DateTime.utc(2026, 1, 1),
  );

  int triggerCallCount = 0;
  int cancelCallCount = 0;
  int resolveCallCount = 0;
  final List<String> terminalOperations = <String>[];
  String? lastMessage;
  String? lastTriggerSource;
  TrackingPosition? lastPositionSnapshot;
  String? lastDeviceId;
  String? lastHardwareId;
  int? lastOriginatorNodeId;
  int? lastRelayNodeId;
  String? lastRelayDeviceId;
  String? lastRelayHardwareId;
  SdkDeviceBatterySnapshot? lastDeviceBattery;
  SdkCoverageSnapshot? lastDeviceCoverage;
  int? lastMobileBattery;
  SdkCoverageSnapshot? lastMobileCoverage;
  OsSosWidgetActivation? lastOsWidgetActivation;
  Object? triggerError;
  final StreamController<SosState> stateController =
      StreamController<SosState>.broadcast();

  @override
  Future<SosIncident> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    OsSosWidgetActivation? osWidgetActivation,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async {
    if (triggerError != null) {
      throw triggerError!;
    }
    triggerCallCount++;
    lastMessage = message;
    lastTriggerSource = triggerSource;
    lastPositionSnapshot = positionSnapshot;
    lastDeviceId = deviceId;
    lastHardwareId = hardwareId;
    lastOriginatorNodeId = originatorNodeId;
    lastRelayNodeId = relayNodeId;
    lastRelayDeviceId = relayDeviceId;
    lastRelayHardwareId = relayHardwareId;
    lastDeviceBattery = deviceBattery;
    lastDeviceCoverage = deviceCoverage;
    lastMobileBattery = mobileBattery;
    lastMobileCoverage = mobileCoverage;
    lastOsWidgetActivation = osWidgetActivation;
    currentIncident = currentIncident.copyWith(
      state: SosState.sent,
      message: message,
      triggerSource: triggerSource,
      positionSnapshot: positionSnapshot,
    );
    stateController.add(currentIncident.state);
    return currentIncident;
  }

  @override
  Future<SosIncident> cancelSos() async {
    cancelCallCount++;
    terminalOperations.add('cancel:${currentIncident.id}');
    currentIncident = currentIncident.copyWith(state: SosState.cancelled);
    stateController.add(currentIncident.state);
    return currentIncident;
  }

  @override
  Future<SosIncident> resolveSos() async {
    resolveCallCount++;
    terminalOperations.add('resolve:${currentIncident.id}');
    currentIncident = currentIncident.copyWith(state: SosState.resolved);
    stateController.add(currentIncident.state);
    return currentIncident;
  }

  @override
  Future<SosState> getSosState() async => currentIncident.state;

  @override
  Future<SosIncident?> getCurrentIncident() async => currentIncident;

  @override
  Stream<SosState> watchSosState() => stateController.stream;

  @override
  Stream<SosIncident?> watchCurrentIncident() async* {
    yield currentIncident;
    await for (final _ in stateController.stream) {
      yield currentIncident;
    }
  }

  @override
  Future<SosHistoryPage> listSosHistory(
      {String? cursor, int limit = 20}) async {
    return const SosHistoryPage(items: [], hasMore: false);
  }

  Future<void> dispose() async {
    await stateController.close();
  }
}

class FakeRehydratingSosRepository extends FakeSosRepository
    implements SosRuntimeRehydrationSupport, SosRuntimeSessionIsolation {
  SosRuntimeRehydrationResult rehydrationResult =
      const SosRuntimeRehydrationResult(
    outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
    resultingState: SosState.idle,
  );
  int rehydrateCallCount = 0;
  int clearForSessionChangeCallCount = 0;

  @override
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend() async {
    rehydrateCallCount++;
    currentIncident = currentIncident.copyWith(
      state: rehydrationResult.resultingState,
    );
    stateController.add(currentIncident.state);
    return rehydrationResult;
  }

  @override
  Future<void> clearSosRuntimeForSessionChange() async {
    clearForSessionChangeCallCount++;
    currentIncident = currentIncident.copyWith(state: SosState.idle);
    stateController.add(SosState.idle);
  }
}

class FakeTrackingRepository implements TrackingRepository {
  FakeTrackingRepository({
    TrackingPosition? currentPosition,
    TrackingState initialState = TrackingState.idle,
  })  : _currentPosition = currentPosition,
        _state = initialState;

  final StreamController<TrackingPosition> _positionsController =
      StreamController<TrackingPosition>.broadcast();
  final StreamController<TrackingState> _stateController =
      StreamController<TrackingState>.broadcast();

  TrackingPosition? _currentPosition;
  TrackingState _state;
  int startCallCount = 0;
  int stopCallCount = 0;

  @override
  Future<void> startTracking() async {
    startCallCount++;
    _state = TrackingState.tracking;
    _stateController.add(_state);
  }

  @override
  Future<void> stopTracking() async {
    stopCallCount++;
    _state = TrackingState.idle;
    _stateController.add(_state);
  }

  @override
  Future<TrackingPosition?> getCurrentPosition() async => _currentPosition;

  @override
  Future<TrackingState> getTrackingState() async => _state;

  @override
  Stream<TrackingPosition> watchPositions() => _positionsController.stream;

  @override
  Stream<TrackingState> watchTrackingState() async* {
    yield _state;
    yield* _stateController.stream;
  }

  void emitPosition(TrackingPosition position) {
    _currentPosition = position;
    _positionsController.add(position);
  }

  Future<void> dispose() async {
    await _positionsController.close();
    await _stateController.close();
  }
}

class FakeTelemetryRepository implements TelemetryRepository {
  final List<SdkTelemetryPayload> publishedPayloads = <SdkTelemetryPayload>[];
  int publishCallCount = 0;
  Object? publishError;

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    publishCallCount++;
    if (publishError != null) {
      throw publishError!;
    }
    publishedPayloads.add(payload);
  }

  @override
  Future<void> publishTelemetryBatch(
    Iterable<SdkTelemetryPayload> payloads,
  ) async {
    for (final payload in payloads) {
      await publishTelemetry(payload);
    }
  }
}

class FakeContactsRepository implements ContactsRepository {
  final List<EmergencyContact> contacts = <EmergencyContact>[];
  final StreamController<List<EmergencyContact>> _controller =
      StreamController<List<EmergencyContact>>.broadcast();

  @override
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
    String language = 'en',
  }) async {
    final contact = EmergencyContact(
      id: 'contact-${contacts.length + 1}',
      name: name,
      phone: phone,
      email: email,
      priority: priority,
      language: language,
      createdAt: DateTime.utc(2026, 1, 1, 12),
      updatedAt: DateTime.utc(2026, 1, 1, 12),
    );
    contacts.add(contact);
    _controller.add(List<EmergencyContact>.unmodifiable(contacts));
    return contact;
  }

  @override
  Future<List<EmergencyContact>> listEmergencyContacts() async =>
      List<EmergencyContact>.unmodifiable(contacts);

  @override
  Future<void> removeEmergencyContact(String contactId) async {
    contacts.removeWhere((contact) => contact.id == contactId);
    _controller.add(List<EmergencyContact>.unmodifiable(contacts));
  }

  @override
  Future<EmergencyContact> updateEmergencyContact(
      EmergencyContact contact) async {
    final index = contacts.indexWhere((item) => item.id == contact.id);
    if (index < 0) {
      throw StateError('Emergency contact not found: ${contact.id}');
    }
    contacts[index] = contact;
    _controller.add(List<EmergencyContact>.unmodifiable(contacts));
    return contact;
  }

  @override
  Future<void> reorderEmergencyContacts(List<String> orderedContactIds) async {
    final byId = {for (final c in contacts) c.id: c};
    for (var i = 0; i < orderedContactIds.length; i++) {
      final id = orderedContactIds[i];
      final existing = byId[id]!;
      byId[id] = existing.copyWith(priority: i + 1);
    }
    contacts
      ..clear()
      ..addAll(byId.values);
    contacts.sort((a, b) => a.priority.compareTo(b.priority));
    _controller.add(List<EmergencyContact>.unmodifiable(contacts));
  }

  @override
  Stream<List<EmergencyContact>> watchEmergencyContacts() async* {
    yield List<EmergencyContact>.unmodifiable(contacts);
    yield* _controller.stream;
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

class FakeSdkDeviceRegistryRepository implements SdkDeviceRegistryRepository {
  final List<BackendRegisteredDevice> devices = <BackendRegisteredDevice>[];
  int upsertCallCount = 0;
  String? lastHardwareId;
  String? lastFirmwareVersion;
  String? lastHardwareModel;
  DateTime? lastPairedAt;

  @override
  Future<List<BackendRegisteredDevice>> listRegisteredDevices() async {
    return List<BackendRegisteredDevice>.unmodifiable(devices);
  }

  @override
  Future<void> removeRegisteredDevice(String deviceId) async {
    devices.removeWhere((device) => device.id == deviceId);
  }

  @override
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    upsertCallCount++;
    lastHardwareId = hardwareId;
    lastFirmwareVersion = firmwareVersion;
    lastHardwareModel = hardwareModel;
    lastPairedAt = pairedAt;
    final existingIndex =
        devices.indexWhere((device) => device.hardwareId == hardwareId);
    final now = DateTime.utc(2026, 3, 31, 12);
    final device = BackendRegisteredDevice(
      id: existingIndex >= 0
          ? devices[existingIndex].id
          : 'device-${devices.length + 1}',
      hardwareId: hardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
      createdAt: existingIndex >= 0 ? devices[existingIndex].createdAt : now,
      updatedAt: now,
    );
    if (existingIndex >= 0) {
      devices[existingIndex] = device;
    } else {
      devices.add(device);
    }
    return device;
  }
}

class FakeDeviceRepository
    implements DeviceRepository, KnownDeviceReconnectRepository {
  FakeDeviceRepository({required DeviceStatus initialStatus})
      : _status = initialStatus;

  final StreamController<DeviceStatus> _controller =
      StreamController<DeviceStatus>.broadcast();

  DeviceStatus _status;
  int pairCallCount = 0;
  int reconnectCallCount = 0;
  int refreshCallCount = 0;
  int unpairCallCount = 0;
  String? lastPairingCode;

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) async {
    pairCallCount++;
    lastPairingCode = pairingCode;
    return _status;
  }

  @override
  Future<DeviceStatus> reconnectDevice(
      {required PreferredDevice device, String? attemptId}) async {
    reconnectCallCount++;
    _status = _status.copyWith(
      deviceId: device.deviceId,
      deviceAlias: device.displayName ?? _status.deviceAlias,
      paired: true,
      connected: true,
      lifecycleState: _status.activated
          ? DeviceLifecycleState.ready
          : DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    return _status;
  }

  @override
  Future<DeviceStatus> activateDevice({required String activationCode}) async =>
      _status;

  @override
  Future<DeviceStatus> getDeviceStatus() async => _status;

  @override
  Future<DeviceStatus> refreshDeviceStatus() async {
    refreshCallCount++;
    return _status;
  }

  @override
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot() async {
    return RuntimeIdentitySnapshot(
      connectedBleNodeId: null,
      deviceId: _status.connected ? _status.deviceId : null,
      serviceBleConnected: _status.connected,
      commandCapable: false,
      readinessReason: _status.connected
          ? RuntimeIdentityReadinessReason.commandPathNotReady
          : RuntimeIdentityReadinessReason.noConnectedDevice,
      lastUpdatedAt: _status.lastSyncedAt ?? _status.lastSeen,
    );
  }

  @override
  Future<void> unpairDevice() async {
    unpairCallCount++;
  }

  @override
  Stream<DeviceStatus> watchDeviceStatus() => _controller.stream;

  void emitStatus(DeviceStatus status) {
    _status = status;
    _controller.add(status);
  }

  void setCurrentStatusSilently(DeviceStatus status) {
    _status = status;
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

class FakeDeathManRepository implements DeathManRepository {
  final StreamController<DeathManPlan> _controller =
      StreamController<DeathManPlan>.broadcast();

  DeathManPlan? activePlan;
  int updateCallCount = 0;
  final List<DeathManStatus> updatedStatuses = <DeathManStatus>[];

  @override
  Future<void> cancelDeathMan(String planId) async {
    if (activePlan?.id == planId) {
      activePlan = activePlan?.copyWith(status: DeathManStatus.cancelled);
      _controller.add(activePlan!);
    }
  }

  @override
  Future<void> confirmDeathManCheckIn(String planId) async {
    if (activePlan?.id == planId) {
      activePlan = activePlan?.copyWith(status: DeathManStatus.confirmedSafe);
      _controller.add(activePlan!);
    }
  }

  @override
  Future<DeathManPlan?> getActiveDeathManPlan() async => activePlan;

  @override
  Future<DeathManPlan> scheduleDeathMan({
    required DateTime expectedReturnAt,
    required Duration gracePeriod,
    required Duration checkInWindow,
    required bool autoTriggerSos,
  }) async {
    activePlan = DeathManPlan(
      id: 'deathman-1',
      expectedReturnAt: expectedReturnAt,
      gracePeriod: gracePeriod,
      checkInWindow: checkInWindow,
      autoTriggerSos: autoTriggerSos,
      status: DeathManStatus.scheduled,
    );
    _controller.add(activePlan!);
    return activePlan!;
  }

  @override
  Future<DeathManPlan> updatePlanStatus(
    String planId,
    DeathManStatus status,
  ) async {
    updateCallCount++;
    updatedStatuses.add(status);
    activePlan = activePlan!.copyWith(status: status);
    _controller.add(activePlan!);
    return activePlan!;
  }

  @override
  Stream<DeathManPlan> watchDeathManPlans() => _controller.stream;

  Future<void> dispose() async {
    await _controller.close();
  }
}

class FakePermissionsRepository implements PermissionsRepository {
  FakePermissionsRepository({
    this.permissionState = const PermissionState(),
  });
  PermissionState permissionState;
  Object? getPermissionStateError;
  int requestNotificationPermissionCallCount = 0;

  @override
  Future<PermissionState> getPermissionState() async {
    if (getPermissionStateError != null) {
      throw getPermissionStateError!;
    }
    return permissionState;
  }

  @override
  Future<PermissionState> requestBluetoothPermission() async => permissionState;

  @override
  Future<PermissionState> requestLocationPermission() async => permissionState;

  @override
  Future<PermissionState> requestNotificationPermission() async {
    requestNotificationPermissionCallCount++;
    return permissionState;
  }
}

class NotificationRecord {
  const NotificationRecord({
    required this.title,
    required this.body,
    this.notificationId,
    this.payload,
    this.actions = const <LocalNotificationAction>[],
  });

  final String title;
  final String body;
  final int? notificationId;
  final String? payload;
  final List<LocalNotificationAction> actions;
}

class FakeNotificationsRepository implements NotificationsRepository {
  int initializeCallCount = 0;
  int requestPermissionCallCount = 0;
  int clearSosNotificationsCallCount = 0;
  final List<NotificationRecord> notifications = <NotificationRecord>[];
  NotificationActionHandler? lastOnAction;

  @override
  Future<void> initialize({NotificationActionHandler? onAction}) async {
    initializeCallCount++;
    lastOnAction = onAction;
  }

  @override
  Future<void> requestPermission() async {
    requestPermissionCallCount++;
  }

  @override
  Future<void> clearSosNotifications() async {
    clearSosNotificationsCallCount++;
  }

  @override
  Future<void> showLocalNotification({
    int? notificationId,
    required String title,
    required String body,
    String? payload,
    List<LocalNotificationAction> actions = const <LocalNotificationAction>[],
  }) async {
    notifications.add(
      NotificationRecord(
        notificationId: notificationId,
        title: title,
        body: body,
        payload: payload,
        actions: List<LocalNotificationAction>.unmodifiable(actions),
      ),
    );
  }
}

class FakeRealtimeClient implements RealtimeClient {
  final StreamController<RealtimeConnectionState> _connectionController =
      StreamController<RealtimeConnectionState>.broadcast();
  final StreamController<RealtimeEvent> _eventsController =
      StreamController<RealtimeEvent>.broadcast();
  final List<MqttOperationalSosRequest> publishedSos =
      <MqttOperationalSosRequest>[];

  int connectCallCount = 0;
  int disconnectCallCount = 0;
  RealtimeConnectionState? stateToEmitOnConnect;
  RealtimeEvent? eventToEmitOnConnect;

  @override
  Future<void> connect() async {
    connectCallCount++;
    if (stateToEmitOnConnect != null) {
      _connectionController.add(stateToEmitOnConnect!);
    }
    if (eventToEmitOnConnect != null) {
      _eventsController.add(eventToEmitOnConnect!);
    }
  }

  @override
  Future<void> disconnect() async {
    disconnectCallCount++;
  }

  @override
  Stream<RealtimeConnectionState> watchConnectionState() =>
      _connectionController.stream;

  @override
  Stream<RealtimeEvent> watchEvents() => _eventsController.stream;

  void emitConnectionState(RealtimeConnectionState state) {
    _connectionController.add(state);
  }

  void emitEvent(RealtimeEvent event) {
    _eventsController.add(event);
  }

  Future<void> dispose() async {
    await _connectionController.close();
    await _eventsController.close();
  }
}
