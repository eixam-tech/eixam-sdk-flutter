import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';

class FakeSosRepository implements SosRepository {
  SosIncident currentIncident = SosIncident(
    id: 'sos-1',
    state: SosState.idle,
    createdAt: DateTime.utc(2026, 1, 1),
  );

  int triggerCallCount = 0;
  int cancelCallCount = 0;
  String? lastMessage;
  String? lastTriggerSource;
  TrackingPosition? lastPositionSnapshot;
  final StreamController<SosState> _stateController =
      StreamController<SosState>.broadcast();

  @override
  Future<SosIncident> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  }) async {
    triggerCallCount++;
    lastMessage = message;
    lastTriggerSource = triggerSource;
    lastPositionSnapshot = positionSnapshot;
    currentIncident = currentIncident.copyWith(
      state: SosState.sent,
      message: message,
      triggerSource: triggerSource,
      positionSnapshot: positionSnapshot,
    );
    _stateController.add(currentIncident.state);
    return currentIncident;
  }

  @override
  Future<SosIncident> cancelSos({String? reason}) async {
    cancelCallCount++;
    currentIncident = currentIncident.copyWith(state: SosState.cancelled);
    _stateController.add(currentIncident.state);
    return currentIncident;
  }

  @override
  Future<SosState> getSosState() async => currentIncident.state;

  @override
  Stream<SosState> watchSosState() => _stateController.stream;

  Future<void> dispose() async {
    await _stateController.close();
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

class FakeContactsRepository implements ContactsRepository {
  final List<EmergencyContact> contacts = <EmergencyContact>[];
  final StreamController<List<EmergencyContact>> _controller =
      StreamController<List<EmergencyContact>>.broadcast();

  @override
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    String? phone,
    String? email,
    int priority = 1,
    bool active = true,
  }) async {
    final contact = EmergencyContact(
      id: 'contact-${contacts.length + 1}',
      name: name,
      phone: phone,
      email: email,
      priority: priority,
      active: active,
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
  Future<void> setEmergencyContactActive(String contactId, bool active) async {
    final index = contacts.indexWhere((contact) => contact.id == contactId);
    if (index == -1) return;
    contacts[index] = contacts[index].copyWith(active: active);
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
