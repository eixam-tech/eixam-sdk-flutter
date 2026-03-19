import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';

import '../device/device_sos_controller.dart';

/// Main SDK orchestrator used by host apps.
///
/// It composes repositories, exposes a stable public API and coordinates
/// cross-module workflows such as attaching a location snapshot to SOS or
/// escalating a Death Man plan into SOS automatically.
class EixamConnectSdkImpl implements EixamConnectSdk {
  final SosRepository sosRepository;
  final TrackingRepository trackingRepository;
  final ContactsRepository contactsRepository;
  final DeviceRepository deviceRepository;
  final DeathManRepository deathManRepository;
  final PermissionsRepository permissionsRepository;
  final NotificationsRepository notificationsRepository;
  final RealtimeClient realtimeClient;
  final DeviceSosController deviceSosController;

  final StreamController<EixamSdkEvent> _eventsController =
      StreamController.broadcast();

  final StreamController<RealtimeConnectionState>
      _realtimeConnectionStateController =
      StreamController<RealtimeConnectionState>.broadcast();

  final StreamController<RealtimeEvent> _realtimeEventsController =
      StreamController<RealtimeEvent>.broadcast();

  StreamSubscription<RealtimeConnectionState>? _realtimeConnectionSub;
  StreamSubscription<RealtimeEvent>? _realtimeEventsSub;

  EixamSdkConfig? _config;
  EixamSession? _session;
  Timer? _deathManTimer;
  bool _deathManCheckInNotified = false;
  bool _deathManOverdueNotified = false;

  RealtimeConnectionState _lastRealtimeConnectionState =
      RealtimeConnectionState.disconnected;
  RealtimeEvent? _lastRealtimeEvent;

  EixamConnectSdkImpl({
    required this.sosRepository,
    required this.trackingRepository,
    required this.contactsRepository,
    required this.deviceRepository,
    required this.deathManRepository,
    required this.permissionsRepository,
    required this.notificationsRepository,
    required this.realtimeClient,
    required this.deviceSosController,
  });

  @override
  Future<void> initialize(EixamSdkConfig config) async {
    _config = config;
    _bindRealtimeStreams();
    await realtimeClient.connect();
  }

  void _bindRealtimeStreams() {
    _realtimeConnectionSub?.cancel();
    _realtimeEventsSub?.cancel();

    _realtimeConnectionSub = realtimeClient.watchConnectionState().listen(
      (state) {
        _lastRealtimeConnectionState = state;
        _realtimeConnectionStateController.add(state);
      },
      onError: (Object error) {
        // Keep bootstrap resilient.
      },
    );

    _realtimeEventsSub = realtimeClient.watchEvents().listen(
      (event) {
        _lastRealtimeEvent = event;
        _realtimeEventsController.add(event);
      },
      onError: (Object error) {
        // Keep bootstrap resilient.
      },
    );
  }

  @override
  Future<void> setSession(EixamSession session) async {
    _session = session;
  }

  @override
  Future<void> clearSession() async {
    _session = null;
  }

  @override
  Future<DeviceStatus> activateDevice({required String activationCode}) {
    return deviceRepository.activateDevice(activationCode: activationCode);
  }

  @override
  Future<DeviceStatus> getDeviceStatus() {
    return deviceRepository.getDeviceStatus();
  }

  @override
  Future<DeviceStatus> refreshDeviceStatus() {
    return deviceRepository.refreshDeviceStatus();
  }

  @override
  Future<void> unpairDevice() {
    return deviceRepository.unpairDevice();
  }

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) {
    return deviceRepository.pairDevice(pairingCode: pairingCode);
  }

  @override
  Stream<DeviceStatus> watchDeviceStatus() {
    return deviceRepository.watchDeviceStatus();
  }

  @override
  Future<DeviceSosStatus> getDeviceSosStatus() {
    return deviceSosController.getStatus();
  }

  @override
  Stream<DeviceSosStatus> watchDeviceSosStatus() {
    return deviceSosController.watchStatus();
  }

  @override
  Future<DeviceSosStatus> triggerDeviceSos() {
    return deviceSosController.triggerSos();
  }

  @override
  Future<DeviceSosStatus> confirmDeviceSos() {
    return deviceSosController.confirmSos();
  }

  @override
  Future<DeviceSosStatus> cancelDeviceSos() {
    return deviceSosController.cancelSos();
  }

  @override
  Future<DeviceSosStatus> acknowledgeDeviceSos() {
    return deviceSosController.acknowledgeSos();
  }

  @override
  Future<PermissionState> getPermissionState() {
    return permissionsRepository.getPermissionState();
  }

  @override
  Future<PermissionState> requestLocationPermission() {
    return permissionsRepository.requestLocationPermission();
  }

  @override
  Future<PermissionState> requestNotificationPermission() async {
    await notificationsRepository.requestPermission();
    return permissionsRepository.requestNotificationPermission();
  }

  @override
  Future<PermissionState> requestBluetoothPermission() {
    return permissionsRepository.requestBluetoothPermission();
  }

  @override
  Future<void> initializeNotifications() {
    return notificationsRepository.initialize();
  }

  @override
  Future<void> showLocalNotification({
    required String title,
    required String body,
  }) {
    return notificationsRepository.showLocalNotification(
      title: title,
      body: body,
    );
  }

  @override
  Future<void> startTracking() {
    return trackingRepository.startTracking();
  }

  @override
  Future<void> stopTracking() {
    return trackingRepository.stopTracking();
  }

  @override
  Future<TrackingPosition?> getCurrentPosition() {
    return trackingRepository.getCurrentPosition();
  }

  @override
  Future<TrackingState> getTrackingState() {
    return trackingRepository.getTrackingState();
  }

  @override
  Stream<TrackingPosition> watchPositions() {
    return trackingRepository.watchPositions();
  }

  @override
  Stream<TrackingState> watchTrackingState() {
    return trackingRepository.watchTrackingState();
  }

  @override
  Future<SosIncident> triggerSos({
    String? message,
    String triggerSource = 'button_ui',
  }) async {
    TrackingPosition? positionSnapshot;
    try {
      final permissionState = await permissionsRepository.getPermissionState();
      if (permissionState.hasLocationAccess) {
        positionSnapshot = await trackingRepository.getCurrentPosition();
      }
    } catch (_) {
      // Best-effort snapshot: SOS should continue even if location lookup fails.
    }

    final incident = await sosRepository.triggerSos(
      message: message,
      triggerSource: triggerSource,
      positionSnapshot: positionSnapshot,
    );
    _eventsController.add(SOSTriggeredEvent(incident.id));
    return incident;
  }

  @override
  Future<SosIncident> cancelSos({String? reason}) async {
    final incident = await sosRepository.cancelSos(reason: reason);
    _eventsController.add(SOSCancelledEvent(incident.id));
    return incident;
  }

  @override
  Future<SosState> getSosState() {
    return sosRepository.getSosState();
  }

  @override
  Stream<SosState> watchSosState() {
    return sosRepository.watchSosState();
  }

  @override
  Future<List<EmergencyContact>> listEmergencyContacts() {
    return contactsRepository.listEmergencyContacts();
  }

  @override
  Stream<List<EmergencyContact>> watchEmergencyContacts() {
    return contactsRepository.watchEmergencyContacts();
  }

  @override
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    String? phone,
    String? email,
    int priority = 1,
    bool active = true,
  }) {
    return contactsRepository.addEmergencyContact(
      name: name,
      phone: phone,
      email: email,
      priority: priority,
      active: active,
    );
  }

  @override
  Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact) {
    return contactsRepository.updateEmergencyContact(contact);
  }

  @override
  Future<void> setEmergencyContactActive(String contactId, bool active) {
    return contactsRepository.setEmergencyContactActive(contactId, active);
  }

  @override
  Future<void> removeEmergencyContact(String contactId) {
    return contactsRepository.removeEmergencyContact(contactId);
  }

  @override
  Future<DeathManPlan> scheduleDeathMan({
    required DateTime expectedReturnAt,
    Duration gracePeriod = const Duration(minutes: 30),
    Duration checkInWindow = const Duration(minutes: 10),
    bool autoTriggerSos = true,
  }) async {
    final plan = await deathManRepository.scheduleDeathMan(
      expectedReturnAt: expectedReturnAt,
      gracePeriod: gracePeriod,
      checkInWindow: checkInWindow,
      autoTriggerSos: autoTriggerSos,
    );
    _deathManCheckInNotified = false;
    _deathManOverdueNotified = false;
    _eventsController.add(DeathManScheduledEvent(plan.id));
    await deathManRepository.updatePlanStatus(plan.id, DeathManStatus.monitoring);
    _startDeathManMonitoring(plan.id);
    return (await deathManRepository.getActiveDeathManPlan())!;
  }

  @override
  Future<DeathManPlan?> getActiveDeathManPlan() {
    return deathManRepository.getActiveDeathManPlan();
  }

  @override
  Future<void> confirmDeathManCheckIn(String planId) async {
    await deathManRepository.confirmDeathManCheckIn(planId);
    _eventsController.add(
      DeathManStatusChangedEvent(planId, DeathManStatus.confirmedSafe.name),
    );
    _stopDeathManMonitoring();
  }

  @override
  Future<void> cancelDeathMan(String planId) async {
    await deathManRepository.cancelDeathMan(planId);
    _eventsController.add(
      DeathManStatusChangedEvent(planId, DeathManStatus.cancelled.name),
    );
    _stopDeathManMonitoring();
  }

  @override
  Stream<DeathManPlan> watchDeathManPlans() {
    return deathManRepository.watchDeathManPlans();
  }

  @override
  Stream<EixamSdkEvent> watchEvents() {
    return _eventsController.stream;
  }

  @override
  Future<RealtimeConnectionState> getRealtimeConnectionState() async {
    return _lastRealtimeConnectionState;
  }

  @override
  Future<RealtimeEvent?> getLastRealtimeEvent() async {
    return _lastRealtimeEvent;
  }

  @override
  Stream<RealtimeConnectionState> watchRealtimeConnectionState() {
    return _realtimeConnectionStateController.stream;
  }

  @override
  Stream<RealtimeEvent> watchRealtimeEvents() {
    return _realtimeEventsController.stream;
  }

  void _startDeathManMonitoring(String planId) {
    _deathManTimer?.cancel();
    _deathManTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final plan = await deathManRepository.getActiveDeathManPlan();
      if (plan == null || plan.id != planId) return;

      final now = DateTime.now();
      final overdueAt = plan.expectedReturnAt.add(plan.gracePeriod);
      final expiresAt = overdueAt.add(plan.checkInWindow);

      if ((plan.status == DeathManStatus.monitoring ||
              plan.status == DeathManStatus.scheduled) &&
          now.isAfter(plan.expectedReturnAt)) {
        await deathManRepository.updatePlanStatus(
          plan.id,
          DeathManStatus.overdue,
        );
        if (!_deathManOverdueNotified) {
          _deathManOverdueNotified = true;
          await _notifyDeathMan(
            'Safety check pending',
            'You are past the expected return time. Please confirm that you are safe.',
          );
          _eventsController.add(
            DeathManStatusChangedEvent(plan.id, DeathManStatus.overdue.name),
          );
        }
      }

      if (plan.status == DeathManStatus.overdue && now.isAfter(overdueAt)) {
        await deathManRepository.updatePlanStatus(
          plan.id,
          DeathManStatus.awaitingConfirmation,
        );
        if (!_deathManCheckInNotified) {
          _deathManCheckInNotified = true;
          await _notifyDeathMan(
            'Confirmation required',
            'If you do not respond during the check-in window, the SOS protocol will be triggered.',
          );
          _eventsController.add(
            DeathManStatusChangedEvent(
              plan.id,
              DeathManStatus.awaitingConfirmation.name,
            ),
          );
        }
      }

      final refreshed = await deathManRepository.getActiveDeathManPlan();
      if (refreshed == null) return;

      if (refreshed.status == DeathManStatus.awaitingConfirmation &&
          now.isAfter(expiresAt)) {
        await deathManRepository.updatePlanStatus(
          refreshed.id,
          DeathManStatus.escalated,
        );
        _eventsController.add(DeathManEscalatedEvent(refreshed.id));
        await _notifyDeathMan(
          'Protocol escalated',
          'No response was received. Automatic escalation has been triggered.',
        );
        if (refreshed.autoTriggerSos) {
          await triggerSos(
            message: 'Auto-triggered by Death Man Protocol',
            triggerSource: 'death_man_protocol',
          );
        }
        await deathManRepository.updatePlanStatus(
          refreshed.id,
          DeathManStatus.expired,
        );
        _eventsController.add(
          DeathManStatusChangedEvent(refreshed.id, DeathManStatus.expired.name),
        );
        _stopDeathManMonitoring();
      }
    });
  }

  Future<void> _notifyDeathMan(String title, String body) async {
    try {
      await notificationsRepository.initialize();
      await notificationsRepository.showLocalNotification(
        title: title,
        body: body,
      );
    } catch (_) {
      // Best effort; death man logic should continue.
    }
  }

  void _stopDeathManMonitoring() {
    _deathManTimer?.cancel();
    _deathManTimer = null;
    _deathManCheckInNotified = false;
    _deathManOverdueNotified = false;
  }

  Future<void> dispose() async {
    _deathManTimer?.cancel();
    await _realtimeConnectionSub?.cancel();
    await _realtimeEventsSub?.cancel();
    await deviceSosController.dispose();
    await realtimeClient.disconnect();
    await _realtimeConnectionStateController.close();
    await _realtimeEventsController.close();
    await _eventsController.close();
  }
}
