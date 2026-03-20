import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:flutter/foundation.dart';

import '../device/ble_debug_registry.dart';
import '../device/ble_incoming_event.dart';
import '../device/device_sos_controller.dart';
import 'ble_sos_notification_payload.dart';

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
  final Stream<BleIncomingEvent> bleIncomingEvents;

  final StreamController<EixamSdkEvent> _eventsController =
      StreamController.broadcast();

  final StreamController<RealtimeConnectionState>
      _realtimeConnectionStateController =
      StreamController<RealtimeConnectionState>.broadcast();

  final StreamController<RealtimeEvent> _realtimeEventsController =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<BleNotificationNavigationRequest>
      _bleNotificationNavigationController =
      StreamController<BleNotificationNavigationRequest>.broadcast();

  StreamSubscription<RealtimeConnectionState>? _realtimeConnectionSub;
  StreamSubscription<RealtimeEvent>? _realtimeEventsSub;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<DeviceSosStatus>? _deviceSosSub;

  EixamSdkConfig? _config;
  EixamSession? _session;
  Timer? _deathManTimer;
  bool _deathManCheckInNotified = false;
  bool _deathManOverdueNotified = false;

  RealtimeConnectionState _lastRealtimeConnectionState =
      RealtimeConnectionState.disconnected;
  RealtimeEvent? _lastRealtimeEvent;
  DeviceStatus? _lastDeviceStatus;
  DeviceSosStatus _lastDeviceSosStatus = DeviceSosStatus.initial();
  BleNotificationNavigationRequest? _pendingBleNotificationNavigationRequest;

  static const String _openAppActionId = 'open_app';
  static const String _backendAckSosActionId = 'backend_ack_sos';
  static const String _cancelOrResolveSosActionId = 'cancel_or_resolve_sos';
  static const String _confirmSosActionId = 'confirm_sos';

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
    required this.bleIncomingEvents,
  });

  @override
  Future<void> initialize(EixamSdkConfig config) async {
    _config = config;
    _lastDeviceStatus = await deviceRepository.getDeviceStatus();
    _lastDeviceSosStatus = await deviceSosController.getStatus();
    _bindDeviceStreams();
    await notificationsRepository.initialize(
      onAction: _handleNotificationAction,
    );
    _bindRealtimeStreams();
    await realtimeClient.connect();
  }

  void _bindDeviceStreams() {
    _deviceStatusSub?.cancel();
    _deviceSosSub?.cancel();

    _deviceStatusSub = deviceRepository.watchDeviceStatus().listen((status) {
      _lastDeviceStatus = status;
    });

    _deviceSosSub = deviceSosController.watchStatus().listen(
      (status) async {
        await _handleDeviceSosStatus(status);
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'BLE SOS notification monitor error: $error',
        );
      },
    );
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
  Future<BleNotificationNavigationRequest?>
      consumePendingBleNotificationNavigationRequest() async {
    final pending = _pendingBleNotificationNavigationRequest;
    _pendingBleNotificationNavigationRequest = null;
    return pending;
  }

  @override
  Stream<BleNotificationNavigationRequest>
      watchBleNotificationNavigationRequests() {
    return _bleNotificationNavigationController.stream;
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
    return notificationsRepository.initialize(
      onAction: _handleNotificationAction,
    );
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

  Future<void> _handleDeviceSosStatus(DeviceSosStatus status) async {
    final previousSnapshot = _lastDeviceSosStatus;
    _lastDeviceSosStatus = status;
    final previousState = status.previousState ?? previousSnapshot.state;
    final newState = status.state;

    BleDebugRegistry.instance.recordEvent(
      'SOS raw packet observed -> payload=${status.lastPacketHex ?? '-'} previous=${previousState.name} new=${newState.name} source=${status.transitionSource.name}',
    );

    if (!status.derivedFromBlePacket) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> previous=${previousState.name} new=${newState.name} source=${status.transitionSource.name} reason=not_from_ble_packet',
      );
      return;
    }

    if (status.transitionSource != DeviceSosTransitionSource.device) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> previous=${previousState.name} new=${newState.name} source=${status.transitionSource.name} reason=source_not_device',
      );
      return;
    }

    if (previousState == newState) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> previous=${previousState.name} new=${newState.name} source=${status.transitionSource.name} reason=same_derived_state',
      );
      return;
    }

    final kind = _notificationKindForSosTransition(previousState, newState);
    if (kind == null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> previous=${previousState.name} new=${newState.name} source=${status.transitionSource.name} reason=transition_not_relevant',
      );
      return;
    }

    final deviceLabel = _deviceLabel(
      deviceAlias: _lastDeviceStatus?.deviceAlias,
      fallbackDeviceId: _lastDeviceStatus?.deviceId,
    );
    final title = _notificationTitleFor(kind, deviceLabel);
    final body = _notificationBodyForSosTransition(
      kind,
      deviceLabel,
      status,
      previousState,
      newState,
    );
    final actions = _notificationActionsForSosState(newState);
    final payload = BleSosNotificationPayload(
      kind: kind,
      state: newState,
      transitionSource: status.transitionSource,
      deviceId: _lastDeviceStatus?.deviceId,
      deviceAlias: _lastDeviceStatus?.deviceAlias,
      nodeId: status.nodeId,
    );

    BleDebugRegistry.instance.recordEvent(
      'SOS notification emitted -> previous=${previousState.name} new=${newState.name} source=${status.transitionSource.name} reason=$kind',
    );

    try {
      await notificationsRepository.showLocalNotification(
        notificationId: _nextBleNotificationId(),
        title: title,
        body: body,
        payload: payload.toJsonString(),
        actions: actions,
      );
    } catch (error, stackTrace) {
      BleDebugRegistry.instance.recordEvent(
        'Local BLE notification failed -> kind=$kind error=$error',
      );
      debugPrint('Local BLE notification failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  String? _notificationKindForSosTransition(
    DeviceSosState previousState,
    DeviceSosState newState,
  ) {
    if (previousState == DeviceSosState.inactive &&
        newState == DeviceSosState.preConfirm) {
      return 'sos_generated';
    }
    if (previousState == DeviceSosState.inactive &&
        newState == DeviceSosState.active) {
      return 'sos_generated';
    }
    if (previousState == DeviceSosState.preConfirm &&
        newState == DeviceSosState.active) {
      return 'sos_activated';
    }
    if ((previousState == DeviceSosState.preConfirm ||
            previousState == DeviceSosState.active ||
            previousState == DeviceSosState.acknowledged) &&
        (newState == DeviceSosState.resolved ||
            newState == DeviceSosState.inactive)) {
      return 'sos_resolved';
    }
    return null;
  }

  String _notificationTitleFor(String kind, String deviceLabel) {
    switch (kind) {
      case 'sos_generated':
        return 'SOS generated on $deviceLabel';
      case 'sos_activated':
        return 'SOS activated on $deviceLabel';
      case 'sos_resolved':
        return 'SOS cancelled on $deviceLabel';
      default:
        return 'Device SOS event from $deviceLabel';
    }
  }

  String _notificationBodyForSosTransition(
    String kind,
    String deviceLabel,
    DeviceSosStatus status,
    DeviceSosState previousState,
    DeviceSosState newState,
  ) {
    final nodeId = status.nodeId;
    final nodeIdSuffix =
        nodeId == null ? '' : ' Node ${_formatNodeId(nodeId)}.';
    switch (kind) {
      case 'sos_generated':
        return 'The device started an SOS sequence.$nodeIdSuffix';
      case 'sos_activated':
        return 'The device escalated from countdown to active SOS.$nodeIdSuffix';
      case 'sos_resolved':
        return 'The device cancelled or resolved the SOS.$nodeIdSuffix';
      default:
        return 'SOS state changed from ${previousState.name} to ${newState.name}.$nodeIdSuffix';
    }
  }

  List<LocalNotificationAction> _notificationActionsForSosState(
    DeviceSosState state,
  ) {
    final actions = <LocalNotificationAction>[
      const LocalNotificationAction(
        id: _openAppActionId,
        title: 'Open app',
        foreground: true,
      ),
    ];

    if (state == DeviceSosState.preConfirm) {
      actions.add(
        const LocalNotificationAction(
          id: _confirmSosActionId,
          title: 'Confirm SOS',
          foreground: true,
        ),
      );
      actions.add(
        const LocalNotificationAction(
          id: _cancelOrResolveSosActionId,
          title: 'Resolve SOS',
          foreground: true,
          destructive: true,
        ),
      );
    }

    if (state == DeviceSosState.active) {
      actions.add(
        const LocalNotificationAction(
          id: _backendAckSosActionId,
          title: 'Send Backend ACK',
          foreground: true,
        ),
      );
      actions.add(
        const LocalNotificationAction(
          id: _cancelOrResolveSosActionId,
          title: 'Resolve SOS',
          foreground: true,
          destructive: true,
        ),
      );
    }

    if (state == DeviceSosState.acknowledged) {
      actions.add(
        const LocalNotificationAction(
          id: _cancelOrResolveSosActionId,
          title: 'Resolve SOS',
          foreground: true,
          destructive: true,
        ),
      );
    }

    return actions;
  }

  Future<void> _handleNotificationAction(
    NotificationActionInvocation invocation,
  ) async {
    final payload = BleSosNotificationPayload.tryParse(invocation.payload);
    final actionId = invocation.actionId;
    BleDebugRegistry.instance.recordEvent(
      'Notification action tapped -> action=$actionId payload=${invocation.payload ?? '-'} launchedApp=${invocation.launchedApp}',
    );

    if (payload == null) {
      await _queueBleNotificationNavigation(
        actionId: actionId,
        reason: 'Notification context could not be decoded.',
        state: DeviceSosState.unknown,
      );
      return;
    }

    if (actionId == _openAppActionId) {
      await _queueBleNotificationNavigation(
        actionId: actionId,
        reason: 'Open the device detail screen from the BLE SOS notification.',
        state: payload.state,
        deviceId: payload.deviceId,
        deviceAlias: payload.deviceAlias,
        nodeId: payload.nodeId,
      );
      return;
    }

    if (!_canExecuteBleActionNow()) {
      BleDebugRegistry.instance.recordEvent(
        'BLE command deferred from notification action -> action=$actionId reason=connection unavailable',
      );
      await _queueBleNotificationNavigation(
        actionId: actionId,
        reason: 'BLE connection is unavailable. Open the app to continue.',
        state: payload.state,
        deviceId: payload.deviceId,
        deviceAlias: payload.deviceAlias,
        nodeId: payload.nodeId,
      );
      return;
    }

    try {
      BleDebugRegistry.instance.recordEvent(
        'BLE command attempted from notification action -> action=$actionId',
      );
      switch (actionId) {
        case _backendAckSosActionId:
          await acknowledgeDeviceSos();
          return;
        case _cancelOrResolveSosActionId:
          await cancelDeviceSos();
          return;
        case _confirmSosActionId:
          await confirmDeviceSos();
          return;
        default:
          await _queueBleNotificationNavigation(
            actionId: actionId,
            reason: 'Unsupported notification action tapped.',
            state: payload.state,
            deviceId: payload.deviceId,
            deviceAlias: payload.deviceAlias,
            nodeId: payload.nodeId,
          );
          return;
      }
    } catch (error, stackTrace) {
      BleDebugRegistry.instance.recordEvent(
        'BLE command failed from notification action -> action=$actionId error=$error',
      );
      debugPrint('BLE notification action failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      await _queueBleNotificationNavigation(
        actionId: actionId,
        reason: 'BLE command could not be completed in the background.',
        state: payload.state,
        deviceId: payload.deviceId,
        deviceAlias: payload.deviceAlias,
        nodeId: payload.nodeId,
      );
    }
  }

  bool _canExecuteBleActionNow() {
    final status = _lastDeviceStatus;
    return status != null &&
        status.connected &&
        BleDebugRegistry.instance.currentState.commandWriterReady;
  }

  Future<void> _queueBleNotificationNavigation({
    required String actionId,
    required String reason,
    required DeviceSosState state,
    String? deviceId,
    String? deviceAlias,
    int? nodeId,
  }) async {
    final request = BleNotificationNavigationRequest(
      actionId: actionId,
      reason: reason,
      state: state,
      deviceId: deviceId,
      deviceAlias: deviceAlias,
      nodeId: nodeId,
    );
    _pendingBleNotificationNavigationRequest = request;
    _bleNotificationNavigationController.add(request);
  }

  String _deviceLabel({String? deviceAlias, String? fallbackDeviceId}) {
    if (deviceAlias != null && deviceAlias.trim().isNotEmpty) {
      return deviceAlias;
    }
    if (fallbackDeviceId != null && fallbackDeviceId.trim().isNotEmpty) {
      return fallbackDeviceId;
    }
    return 'EIXAM device';
  }

  String _formatNodeId(int? nodeId) {
    if (nodeId == null) {
      return '-';
    }
    final normalized = nodeId & 0xFFFFFFFF;
    return '0x${normalized.toRadixString(16).padLeft(8, '0')}';
  }

  int _nextBleNotificationId() {
    return DateTime.now().microsecondsSinceEpoch % 2147483647;
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
    await deathManRepository.updatePlanStatus(
      plan.id,
      DeathManStatus.monitoring,
    );
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
      await notificationsRepository.initialize(
        onAction: _handleNotificationAction,
      );
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
    await _deviceStatusSub?.cancel();
    await _deviceSosSub?.cancel();
    await deviceSosController.dispose();
    await realtimeClient.disconnect();
    await _realtimeConnectionStateController.close();
    await _realtimeEventsController.close();
    await _bleNotificationNavigationController.close();
    await _eventsController.close();
  }
}
