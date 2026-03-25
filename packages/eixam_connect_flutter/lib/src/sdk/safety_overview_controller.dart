import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:flutter/foundation.dart';

import 'device_view_state.dart';
import 'rescue_view_state.dart';
import 'sos_view_state.dart';

class SafetyOverviewController extends ChangeNotifier {
  SafetyOverviewController({required this.sdk});

  final EixamConnectSdk sdk;

  PermissionState? permissionState;
  TrackingState? trackingState;
  TrackingPosition? lastPosition;
  SosState? sosState;
  SosIncident? activeIncident;
  DeviceStatus? deviceStatus;
  GuidedRescueState? guidedRescueState;
  DeathManPlan? activeDeathManPlan;
  List<EmergencyContact> contacts = const <EmergencyContact>[];
  RealtimeConnectionState? realtimeConnectionState;
  RealtimeEvent? lastRealtimeEvent;
  String? lastError;

  bool loadingPermissions = false;
  bool loadingTracking = false;
  bool loadingSos = false;
  bool loadingNotifications = false;
  bool loadingDeathMan = false;
  bool loadingContacts = false;
  bool loadingGuidedRescue = false;

  bool _initialized = false;
  StreamSubscription<TrackingPosition>? _positionSub;
  StreamSubscription<TrackingState>? _trackingStateSub;
  StreamSubscription<SosState>? _sosStateSub;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<GuidedRescueState>? _guidedRescueSub;
  StreamSubscription<DeathManPlan>? _deathManSub;
  StreamSubscription<List<EmergencyContact>>? _contactsSub;
  StreamSubscription<RealtimeConnectionState>? _realtimeConnectionSub;
  StreamSubscription<RealtimeEvent>? _realtimeEventsSub;

  DeviceViewState get deviceViewState =>
      DeviceViewState.fromStatus(deviceStatus);
  RescueViewState get rescueViewState => RescueViewState.fromSdkState(
        rescueState: guidedRescueState ?? const GuidedRescueState.unsupported(),
        deviceStatus: deviceStatus,
        lastPosition: lastPosition,
      );
  SosViewState get sosViewState => SosViewState.fromSdkState(
        state: sosState ?? SosState.idle,
        isBusy: loadingSos,
        incident: activeIncident,
      );

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _bindStreams();
    await _loadInitialState();
  }

  void _bindStreams() {
    _positionSub = sdk.watchPositions().listen(
      (position) {
        lastPosition = position;
        notifyListeners();
      },
      onError: _handleStreamError,
    );

    _trackingStateSub = sdk.watchTrackingState().listen(
      (state) {
        trackingState = state;
        notifyListeners();
      },
      onError: _handleStreamError,
    );

    _sosStateSub = sdk.watchSosState().listen(
      (state) {
        sosState = state;
        notifyListeners();
      },
      onError: _handleStreamError,
    );

    _deviceStatusSub = sdk.watchDeviceStatus().listen(
      (status) {
        deviceStatus = status;
        notifyListeners();
      },
      onError: _handleStreamError,
    );

    _guidedRescueSub = sdk.watchGuidedRescueState().listen(
      (state) {
        guidedRescueState = state;
        notifyListeners();
      },
      onError: _handleStreamError,
    );

    _deathManSub = sdk.watchDeathManPlans().listen(
      (plan) {
        activeDeathManPlan = plan;
        notifyListeners();
      },
      onError: _handleStreamError,
    );

    _contactsSub = sdk.watchEmergencyContacts().listen(
      (items) {
        contacts = items;
        notifyListeners();
      },
      onError: _handleStreamError,
    );

    _realtimeConnectionSub = sdk.watchRealtimeConnectionState().listen(
      (state) {
        realtimeConnectionState = state;
        notifyListeners();
      },
      onError: _handleStreamError,
    );

    _realtimeEventsSub = sdk.watchRealtimeEvents().listen(
      (event) {
        lastRealtimeEvent = event;
        notifyListeners();
      },
      onError: _handleStreamError,
    );
  }

  void _handleStreamError(Object error) {
    lastError = error.toString();
    notifyListeners();
  }

  Future<void> _loadInitialState() async {
    try {
      permissionState = await sdk.getPermissionState();
      trackingState = await sdk.getTrackingState();
      lastPosition = await sdk.getCurrentPosition();
      sosState = await sdk.getSosState();
      deviceStatus = await sdk.getDeviceStatus();
      guidedRescueState = await sdk.getGuidedRescueState();
      activeDeathManPlan = await sdk.getActiveDeathManPlan();
      contacts = await sdk.listEmergencyContacts();
      realtimeConnectionState = await sdk.getRealtimeConnectionState();
      lastRealtimeEvent = await sdk.getLastRealtimeEvent();
    } catch (error) {
      lastError = error.toString();
    }
    notifyListeners();
  }

  Future<void> refreshPermissions() async {
    await _runFlag(
      (value) => loadingPermissions = value,
      () async => permissionState = await sdk.getPermissionState(),
    );
  }

  Future<void> requestLocationPermission() async {
    await _runFlag(
      (value) => loadingPermissions = value,
      () async => permissionState = await sdk.requestLocationPermission(),
    );
  }

  Future<void> requestNotificationPermission() async {
    await _runFlag(
      (value) => loadingPermissions = value,
      () async => permissionState = await sdk.requestNotificationPermission(),
    );
  }

  Future<void> requestBluetoothPermission() async {
    await _runFlag(
      (value) => loadingPermissions = value,
      () async => permissionState = await sdk.requestBluetoothPermission(),
    );
  }

  Future<void> startTracking() async {
    await _runFlag(
      (value) => loadingTracking = value,
      () async {
        await sdk.startTracking();
        trackingState = await sdk.getTrackingState();
        lastPosition = await sdk.getCurrentPosition();
      },
    );
  }

  Future<void> stopTracking() async {
    await _runFlag(
      (value) => loadingTracking = value,
      () async {
        await sdk.stopTracking();
        trackingState = await sdk.getTrackingState();
      },
    );
  }

  Future<void> triggerSos() async {
    await _runFlag(
      (value) => loadingSos = value,
      () async {
        activeIncident = await sdk.triggerSos(
          message: 'Manual SOS triggered from demo',
          triggerSource: 'button_ui',
        );
        sosState = await sdk.getSosState();
      },
    );
  }

  Future<void> cancelSos() async {
    await _runFlag(
      (value) => loadingSos = value,
      () async {
        activeIncident = await sdk.cancelSos(
          reason: 'Cancelled from operational demo',
        );
        sosState = await sdk.getSosState();
      },
    );
  }

  Future<void> initializeNotifications() async {
    await _runFlag(
      (value) => loadingNotifications = value,
      sdk.initializeNotifications,
    );
  }

  Future<void> showTestNotification() async {
    await _runFlag(
      (value) => loadingNotifications = value,
      () => sdk.showLocalNotification(
        title: 'EIXAM test notification',
        body: 'Local notifications are working in the operational demo.',
      ),
    );
  }

  Future<void> scheduleQuickDeathMan() async {
    await _runFlag(
      (value) => loadingDeathMan = value,
      () async {
        activeDeathManPlan = await sdk.scheduleDeathMan(
          expectedReturnAt: DateTime.now().add(const Duration(seconds: 20)),
          gracePeriod: const Duration(seconds: 10),
          checkInWindow: const Duration(seconds: 15),
          autoTriggerSos: true,
        );
      },
    );
  }

  Future<void> confirmDeathMan() async {
    final plan = activeDeathManPlan;
    if (plan == null) return;

    await _runFlag(
      (value) => loadingDeathMan = value,
      () async {
        await sdk.confirmDeathManCheckIn(plan.id);
        activeDeathManPlan = await sdk.getActiveDeathManPlan();
      },
    );
  }

  Future<void> cancelDeathMan() async {
    final plan = activeDeathManPlan;
    if (plan == null) return;

    await _runFlag(
      (value) => loadingDeathMan = value,
      () async {
        await sdk.cancelDeathMan(plan.id);
        activeDeathManPlan = await sdk.getActiveDeathManPlan();
      },
    );
  }

  Future<void> addSampleContact() async {
    await _runFlag(
      (value) => loadingContacts = value,
      () async {
        final now = DateTime.now().millisecondsSinceEpoch;
        await sdk.addEmergencyContact(
          name: 'Sample Contact $now',
          phone: '+34123456789',
          email: 'sample$now@eixam.dev',
          priority: 1,
          active: true,
        );
        contacts = await sdk.listEmergencyContacts();
      },
    );
  }

  Future<void> toggleFirstContact() async {
    if (contacts.isEmpty) return;

    await _runFlag(
      (value) => loadingContacts = value,
      () async {
        final first = contacts.first;
        await sdk.setEmergencyContactActive(first.id, !first.active);
        contacts = await sdk.listEmergencyContacts();
      },
    );
  }

  Future<void> removeFirstContact() async {
    if (contacts.isEmpty) return;

    await _runFlag(
      (value) => loadingContacts = value,
      () async {
        await sdk.removeEmergencyContact(contacts.first.id);
        contacts = await sdk.listEmergencyContacts();
      },
    );
  }

  Future<void> requestGuidedRescueStatus() async {
    await _runFlag(
      (value) => loadingGuidedRescue = value,
      () async {
        await sdk.requestGuidedRescueStatus();
        guidedRescueState = await sdk.getGuidedRescueState();
      },
    );
  }

  Future<void> requestGuidedRescuePosition() async {
    await _runFlag(
      (value) => loadingGuidedRescue = value,
      () async {
        await sdk.requestGuidedRescuePosition();
        guidedRescueState = await sdk.getGuidedRescueState();
      },
    );
  }

  Future<void> acknowledgeGuidedRescueSos() async {
    await _runFlag(
      (value) => loadingGuidedRescue = value,
      () async {
        await sdk.acknowledgeGuidedRescueSos();
        guidedRescueState = await sdk.getGuidedRescueState();
      },
    );
  }

  Future<void> enableGuidedRescueBuzzer() async {
    await _runFlag(
      (value) => loadingGuidedRescue = value,
      () async {
        await sdk.enableGuidedRescueBuzzer();
        guidedRescueState = await sdk.getGuidedRescueState();
      },
    );
  }

  Future<void> disableGuidedRescueBuzzer() async {
    await _runFlag(
      (value) => loadingGuidedRescue = value,
      () async {
        await sdk.disableGuidedRescueBuzzer();
        guidedRescueState = await sdk.getGuidedRescueState();
      },
    );
  }

  Future<void> clearGuidedRescueSession() async {
    await _runFlag(
      (value) => loadingGuidedRescue = value,
      () async {
        await sdk.clearGuidedRescueSession();
        guidedRescueState = await sdk.getGuidedRescueState();
      },
    );
  }

  Future<void> configureGuidedRescueSessionForValidation({
    required String targetNodeIdText,
    required String rescueNodeIdText,
  }) async {
    await _runFlag(
      (value) => loadingGuidedRescue = value,
      () async {
        final targetNodeId = _parseGuidedRescueNodeId(
          targetNodeIdText,
          fieldLabel: 'target',
        );
        final rescueNodeId = _parseGuidedRescueNodeId(
          rescueNodeIdText,
          fieldLabel: 'rescue',
        );
        guidedRescueState = await sdk.setGuidedRescueSession(
          targetNodeId: targetNodeId,
          rescueNodeId: rescueNodeId,
        );
      },
    );
  }

  int _parseGuidedRescueNodeId(
    String rawValue, {
    required String fieldLabel,
  }) {
    final value = rawValue.trim();
    final parsed = value.toLowerCase().startsWith('0x')
        ? int.tryParse(value.substring(2), radix: 16)
        : int.tryParse(value);
    if (parsed == null || parsed < 0 || parsed > 0xFFFF) {
      throw RescueException(
        'E_RESCUE_INVALID_NODE_ID',
        'Enter a valid $fieldLabel node id in decimal or 0x hex format.',
      );
    }
    return parsed;
  }

  Future<void> _runFlag(
    void Function(bool value) setFlag,
    Future<void> Function() action,
  ) async {
    setFlag(true);
    lastError = null;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      lastError = error.toString();
    } finally {
      setFlag(false);
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _trackingStateSub?.cancel();
    _sosStateSub?.cancel();
    _deviceStatusSub?.cancel();
    _guidedRescueSub?.cancel();
    _deathManSub?.cancel();
    _contactsSub?.cancel();
    _realtimeConnectionSub?.cancel();
    _realtimeEventsSub?.cancel();
    super.dispose();
  }
}
