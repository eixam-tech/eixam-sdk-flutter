import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

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

  final StreamController<EixamSdkEvent> _eventsController = StreamController.broadcast();

  EixamSdkConfig? _config;
  EixamSession? _session;
  Timer? _deathManTimer;
  bool _deathManCheckInNotified = false;
  bool _deathManOverdueNotified = false;

  EixamConnectSdkImpl({
    required this.sosRepository,
    required this.trackingRepository,
    required this.contactsRepository,
    required this.deviceRepository,
    required this.deathManRepository,
    required this.permissionsRepository,
    required this.notificationsRepository,
  });

  @override
  Future<void> initialize(EixamSdkConfig config) async {
    _config = config;
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
  Stream<DeviceStatus> watchDeviceStatus() => deviceRepository.watchDeviceStatus();

  @override
  Future<PermissionState> getPermissionState() => permissionsRepository.getPermissionState();

  @override
  Future<PermissionState> requestLocationPermission() => permissionsRepository.requestLocationPermission();

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
  Future<void> initializeNotifications() => notificationsRepository.initialize();

  @override
  Future<void> showLocalNotification({required String title, required String body}) {
    return notificationsRepository.showLocalNotification(title: title, body: body);
  }

  @override
  Future<void> startTracking() => trackingRepository.startTracking();

  @override
  Future<void> stopTracking() => trackingRepository.stopTracking();

  @override
  Future<TrackingPosition?> getCurrentPosition() => trackingRepository.getCurrentPosition();

  @override
  Future<TrackingState> getTrackingState() => trackingRepository.getTrackingState();

  @override
  Stream<TrackingPosition> watchPositions() => trackingRepository.watchPositions();

  @override
  Stream<TrackingState> watchTrackingState() => trackingRepository.watchTrackingState();

  @override
  Future<SosIncident> triggerSos({String? message, String triggerSource = 'button_ui'}) async {
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
  Future<SosState> getSosState() => sosRepository.getSosState();

  @override
  Stream<SosState> watchSosState() => sosRepository.watchSosState();

  @override
  Future<List<EmergencyContact>> listEmergencyContacts() => contactsRepository.listEmergencyContacts();

  @override
  Stream<List<EmergencyContact>> watchEmergencyContacts() => contactsRepository.watchEmergencyContacts();

  @override
  Future<EmergencyContact> addEmergencyContact({required String name, String? phone, String? email, int priority = 1, bool active = true}) {
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
  Future<DeathManPlan> scheduleDeathMan({required DateTime expectedReturnAt, Duration gracePeriod = const Duration(minutes: 30), Duration checkInWindow = const Duration(minutes: 10), bool autoTriggerSos = true}) async {
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
  Future<DeathManPlan?> getActiveDeathManPlan() => deathManRepository.getActiveDeathManPlan();

  @override
  Future<void> confirmDeathManCheckIn(String planId) async {
    await deathManRepository.confirmDeathManCheckIn(planId);
    _eventsController.add(DeathManStatusChangedEvent(planId, DeathManStatus.confirmedSafe.name));
    _stopDeathManMonitoring();
  }

  @override
  Future<void> cancelDeathMan(String planId) async {
    await deathManRepository.cancelDeathMan(planId);
    _eventsController.add(DeathManStatusChangedEvent(planId, DeathManStatus.cancelled.name));
    _stopDeathManMonitoring();
  }

  @override
  Stream<DeathManPlan> watchDeathManPlans() => deathManRepository.watchDeathManPlans();

  @override
  Stream<EixamSdkEvent> watchEvents() => _eventsController.stream;

  void _startDeathManMonitoring(String planId) {
    _deathManTimer?.cancel();
    _deathManTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final plan = await deathManRepository.getActiveDeathManPlan();
      if (plan == null || plan.id != planId) return;
      final now = DateTime.now();
      final overdueAt = plan.expectedReturnAt.add(plan.gracePeriod);
      final expiresAt = overdueAt.add(plan.checkInWindow);

      if ((plan.status == DeathManStatus.monitoring || plan.status == DeathManStatus.scheduled) && now.isAfter(plan.expectedReturnAt)) {
        await deathManRepository.updatePlanStatus(plan.id, DeathManStatus.overdue);
        if (!_deathManOverdueNotified) {
          _deathManOverdueNotified = true;
          await _notifyDeathMan('Safety check pending', 'You are past the expected return time. Please confirm that you are safe.');
          _eventsController.add(DeathManStatusChangedEvent(plan.id, DeathManStatus.overdue.name));
        }
      }

      if (plan.status == DeathManStatus.overdue && now.isAfter(overdueAt)) {
        await deathManRepository.updatePlanStatus(plan.id, DeathManStatus.awaitingConfirmation);
        if (!_deathManCheckInNotified) {
          _deathManCheckInNotified = true;
          await _notifyDeathMan('Confirmation required', 'If you do not respond during the check-in window, the SOS protocol will be triggered.');
          _eventsController.add(DeathManStatusChangedEvent(plan.id, DeathManStatus.awaitingConfirmation.name));
        }
      }

      final refreshed = await deathManRepository.getActiveDeathManPlan();
      if (refreshed == null) return;
      if (refreshed.status == DeathManStatus.awaitingConfirmation && now.isAfter(expiresAt)) {
        await deathManRepository.updatePlanStatus(refreshed.id, DeathManStatus.escalated);
        _eventsController.add(DeathManEscalatedEvent(refreshed.id));
        await _notifyDeathMan('Protocol escalated', 'No response was received. Automatic escalation has been triggered.');
        if (refreshed.autoTriggerSos) {
          await triggerSos(message: 'Auto-triggered by Death Man Protocol', triggerSource: 'death_man_protocol');
        }
        await deathManRepository.updatePlanStatus(refreshed.id, DeathManStatus.expired);
        _eventsController.add(DeathManStatusChangedEvent(refreshed.id, DeathManStatus.expired.name));
        _stopDeathManMonitoring();
      }
    });
  }

  Future<void> _notifyDeathMan(String title, String body) async {
    try {
      await notificationsRepository.initialize();
      await notificationsRepository.showLocalNotification(title: title, body: body);
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
}
