import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/sdk/guided_rescue_runtime.dart';
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
  String? lastMessage;
  String? lastTriggerSource;
  TrackingPosition? lastPositionSnapshot;
  String? lastDeviceId;
  final StreamController<SosState> stateController =
      StreamController<SosState>.broadcast();

  @override
  Future<SosIncident> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
  }) async {
    triggerCallCount++;
    lastMessage = message;
    lastTriggerSource = triggerSource;
    lastPositionSnapshot = positionSnapshot;
    lastDeviceId = deviceId;
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
    currentIncident = currentIncident.copyWith(state: SosState.cancelled);
    stateController.add(currentIncident.state);
    return currentIncident;
  }

  @override
  Future<SosIncident> resolveSos() async {
    resolveCallCount++;
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

  Future<void> dispose() async {
    await stateController.close();
  }
}

class FakeRehydratingSosRepository extends FakeSosRepository
    implements SosRuntimeRehydrationSupport {
  SosRuntimeRehydrationResult rehydrationResult =
      const SosRuntimeRehydrationResult(
    outcome: SosRuntimeRehydrationOutcome.clearedToIdle,
    resultingState: SosState.idle,
  );
  int rehydrateCallCount = 0;

  @override
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend() async {
    rehydrateCallCount++;
    currentIncident = currentIncident.copyWith(
      state: rehydrationResult.resultingState,
    );
    stateController.add(currentIncident.state);
    return rehydrationResult;
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

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    publishedPayloads.add(payload);
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
  }) async {
    final contact = EmergencyContact(
      id: 'contact-${contacts.length + 1}',
      name: name,
      phone: phone,
      email: email,
      priority: priority,
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
    contacts[index] = contact;
    _controller.add(List<EmergencyContact>.unmodifiable(contacts));
    return contact;
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

class FakeDeviceRepository implements DeviceRepository {
  FakeDeviceRepository({required DeviceStatus initialStatus})
      : _status = initialStatus;

  final StreamController<DeviceStatus> _controller =
      StreamController<DeviceStatus>.broadcast();

  DeviceStatus _status;
  int pairCallCount = 0;
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
  PermissionState permissionState;
  Object? getPermissionStateError;
  int requestNotificationPermissionCallCount = 0;

  FakePermissionsRepository({
    this.permissionState = const PermissionState(),
  });

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

class FakeGuidedRescueRuntime implements GuidedRescueRuntime {
  FakeGuidedRescueRuntime({
    GuidedRescueState? initialState,
  }) : _state = initialState ??
            const GuidedRescueState(
              hasRuntimeSupport: true,
              availableActions: <GuidedRescueAction>{
                GuidedRescueAction.requestPosition,
                GuidedRescueAction.acknowledgeSos,
                GuidedRescueAction.buzzerOn,
                GuidedRescueAction.buzzerOff,
                GuidedRescueAction.requestStatus,
              },
            );

  final StreamController<GuidedRescueState> _controller =
      StreamController<GuidedRescueState>.broadcast();

  GuidedRescueState _state;
  int requestPositionCallCount = 0;
  int acknowledgeSosCallCount = 0;
  int enableBuzzerCallCount = 0;
  int disableBuzzerCallCount = 0;
  int requestStatusCallCount = 0;
  int clearSessionCallCount = 0;

  @override
  Future<GuidedRescueState> getCurrentState() async => _state;

  @override
  Stream<GuidedRescueState> watchState() => _controller.stream;

  @override
  Future<GuidedRescueState> setSession({
    required int targetNodeId,
    required int rescueNodeId,
  }) async {
    _state = _state.copyWith(
      hasRuntimeSupport: true,
      targetNodeId: targetNodeId,
      rescueNodeId: rescueNodeId,
      lastUpdatedAt: DateTime.utc(2026, 1, 1, 12),
      clearLastError: true,
    );
    _controller.add(_state);
    return _state;
  }

  @override
  Future<void> clearSession() async {
    clearSessionCallCount++;
    _state = GuidedRescueState(
      hasRuntimeSupport: true,
      availableActions: _state.availableActions,
      lastKnownTargetPosition: _state.lastKnownTargetPosition,
      lastStatusSnapshot: _state.lastStatusSnapshot,
      lastUpdatedAt: DateTime.utc(2026, 1, 1, 12, 5),
    );
    _controller.add(_state);
  }

  @override
  Future<void> requestPosition() async {
    requestPositionCallCount++;
  }

  @override
  Future<void> acknowledgeSos() async {
    acknowledgeSosCallCount++;
  }

  @override
  Future<void> enableBuzzer() async {
    enableBuzzerCallCount++;
  }

  @override
  Future<void> disableBuzzer() async {
    disableBuzzerCallCount++;
  }

  @override
  Future<void> requestStatus() async {
    requestStatusCallCount++;
  }

  void emitState(GuidedRescueState state) {
    _state = state;
    _controller.add(state);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
