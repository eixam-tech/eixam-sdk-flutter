import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:flutter/widgets.dart';

import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/datasources_local/sdk_session_store.dart';
import '../data/datasources_remote/sdk_identity_remote_data_source.dart';
import '../device/ble_incoming_event.dart';
import '../device/device_sos_controller.dart';
import '../device/ble_debug_registry.dart';
import '../data/datasources_remote/sdk_session_context.dart';
import '../data/repositories/telemetry_repository.dart';
import 'ble_auto_reconnect_coordinator.dart';
import 'ble_sos_notification_payload.dart';
import 'guided_rescue_runtime.dart';
import 'operational_realtime_client.dart';

/// Main SDK orchestrator used by host apps.
///
/// It composes repositories, exposes a stable public API and coordinates
/// cross-module workflows such as attaching a location snapshot to SOS or
/// escalating a Death Man plan into SOS automatically.
class EixamConnectSdkImpl
    with WidgetsBindingObserver
    implements EixamConnectSdk {
  final SosRepository sosRepository;
  final TrackingRepository trackingRepository;
  final TelemetryRepository telemetryRepository;
  final ContactsRepository contactsRepository;
  final DeviceRepository deviceRepository;
  final DeathManRepository deathManRepository;
  final PermissionsRepository permissionsRepository;
  final NotificationsRepository notificationsRepository;
  final RealtimeClient realtimeClient;
  final DeviceSosController deviceSosController;
  final Stream<BleIncomingEvent> bleIncomingEvents;
  final PreferredBleDeviceStore preferredBleDeviceStore;
  final GuidedRescueRuntime? guidedRescueRuntime;
  final SdkSessionStore? sessionStore;
  final SdkSessionContext? sessionContext;
  final SdkIdentityRemoteDataSource? identityRemoteDataSource;
  final Future<void> Function()? disposeCallback;

  final StreamController<EixamSdkEvent> _eventsController =
      StreamController.broadcast();

  final StreamController<RealtimeConnectionState>
      _realtimeConnectionStateController =
      StreamController<RealtimeConnectionState>.broadcast();

  final StreamController<RealtimeEvent> _realtimeEventsController =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<GuidedRescueState> _guidedRescueStateController =
      StreamController<GuidedRescueState>.broadcast();
  final StreamController<BleNotificationNavigationRequest>
      _bleNotificationNavigationController =
      StreamController<BleNotificationNavigationRequest>.broadcast();

  StreamSubscription<RealtimeConnectionState>? _realtimeConnectionSub;
  StreamSubscription<RealtimeEvent>? _realtimeEventsSub;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<DeviceSosStatus>? _deviceSosSub;
  StreamSubscription<GuidedRescueState>? _guidedRescueSub;
  StreamSubscription<SosState>? _sosStateSub;

  Timer? _deathManTimer;
  bool _deathManCheckInNotified = false;
  bool _deathManOverdueNotified = false;

  RealtimeConnectionState _lastRealtimeConnectionState =
      RealtimeConnectionState.disconnected;
  RealtimeEvent? _lastRealtimeEvent;
  DeviceStatus? _lastDeviceStatus;
  GuidedRescueState _guidedRescueState = const GuidedRescueState.unsupported();
  BleNotificationNavigationRequest? _pendingBleNotificationNavigationRequest;
  String? _activeDeviceSosCycleKey;
  String? _notifiedDeviceSosCycleKey;
  DeviceSosState? _notifiedDeviceSosState;
  EixamSession? _session;
  String? _pendingCancelledIncidentId;
  late final BleAutoReconnectCoordinator _bleAutoReconnectCoordinator;

  static const String _openAppActionId = 'open_app';
  static const String _cancelSosActionId = 'cancel_sos';
  static const String _resolveSosActionId = 'resolve_sos';
  static const String _confirmSosActionId = 'confirm_sos';
  static const String _confirmDeadManSafeActionId = 'confirm_dead_man_safe';

  EixamConnectSdkImpl({
    required this.sosRepository,
    required this.trackingRepository,
    required this.telemetryRepository,
    required this.contactsRepository,
    required this.deviceRepository,
    required this.deathManRepository,
    required this.permissionsRepository,
    required this.notificationsRepository,
    required this.realtimeClient,
    required this.deviceSosController,
    required this.bleIncomingEvents,
    required this.preferredBleDeviceStore,
    this.guidedRescueRuntime,
    this.sessionStore,
    this.sessionContext,
    this.identityRemoteDataSource,
    this.disposeCallback,
  }) {
    _bleAutoReconnectCoordinator = BleAutoReconnectCoordinator(
      deviceRepository: deviceRepository,
      preferredDeviceStore: preferredBleDeviceStore,
    );
    _bindSosStreams();
  }

  @override
  Future<void> initialize(EixamSdkConfig config) async {
    _session = await sessionStore?.load();
    _session = await _bootstrapSessionIfNeeded(_session);
    if (sessionContext != null) {
      sessionContext!.currentSession = _session;
    }
    _lastDeviceStatus = await deviceRepository.getDeviceStatus();
    await deviceSosController.getStatus();
    _guidedRescueState = guidedRescueRuntime == null
        ? _fallbackGuidedRescueState()
        : await guidedRescueRuntime!.getCurrentState();
    WidgetsBinding.instance.addObserver(this);
    await _bleAutoReconnectCoordinator.initialize(
      initialStatus: _lastDeviceStatus!,
      deviceStatusStream: deviceRepository.watchDeviceStatus(),
    );
    _bindDeviceStreams();
    _bindGuidedRescueStreams();
    await notificationsRepository.initialize(
      onAction: _handleNotificationAction,
    );
    _bindRealtimeStreams();
    await realtimeClient.connect();
    await _resumeDeathManMonitoringIfNeeded();
    await _bleAutoReconnectCoordinator.tryAutoConnectOnStartup();
  }

  void _bindGuidedRescueStreams() {
    _guidedRescueSub?.cancel();

    if (guidedRescueRuntime == null) {
      _guidedRescueStateController.add(_guidedRescueState);
      return;
    }

    _guidedRescueSub = guidedRescueRuntime!.watchState().listen((state) {
      _guidedRescueState = state;
      _guidedRescueStateController.add(state);
    });
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
    _session = await _bootstrapSessionIfNeeded(session);
    if (sessionContext != null) {
      sessionContext!.currentSession = _session;
    }
    await sessionStore?.save(_session!);
    final realtime = realtimeClient;
    if (realtime is OperationalRealtimeClient) {
      await realtime.reconnectIfSessionChanged(_session!);
      return;
    }
    await realtimeClient.connect();
  }

  Future<EixamSession?> _bootstrapSessionIfNeeded(EixamSession? session) async {
    if (session == null) {
      return null;
    }
    final remoteDataSource = identityRemoteDataSource;
    if (remoteDataSource == null) {
      return session;
    }
    if (session.canonicalExternalUserId?.trim().isNotEmpty == true) {
      return session;
    }
    final bootstrapped = await remoteDataSource.bootstrapSession(session);
    await sessionStore?.save(bootstrapped);
    return bootstrapped;
  }

  void _bindSosStreams() {
    _sosStateSub?.cancel();
    _sosStateSub = sosRepository.watchSosState().listen((state) {
      final incidentId = _pendingCancelledIncidentId;
      if (state == SosState.cancelled && incidentId != null) {
        _pendingCancelledIncidentId = null;
        _eventsController.add(SOSCancelledEvent(incidentId));
        return;
      }
      if (state == SosState.idle ||
          state == SosState.failed ||
          state == SosState.resolved) {
        _pendingCancelledIncidentId = null;
      }
    });
  }

  @override
  Future<void> clearSession() async {
    _session = null;
    if (sessionContext != null) {
      sessionContext!.currentSession = null;
    }
    await sessionStore?.clear();
    await realtimeClient.disconnect();
  }

  @override
  Future<DeviceStatus> activateDevice({required String activationCode}) {
    return _cacheDeviceStatus(
      deviceRepository.activateDevice(activationCode: activationCode),
    );
  }

  @override
  Future<DeviceStatus> getDeviceStatus() =>
      _cacheDeviceStatus(deviceRepository.getDeviceStatus());

  @override
  Future<DeviceStatus> refreshDeviceStatus() =>
      _cacheDeviceStatus(deviceRepository.refreshDeviceStatus());

  @override
  Future<void> unpairDevice() async {
    await _bleAutoReconnectCoordinator.unpairDeviceManually(
      deviceRepository.unpairDevice,
    );
    _lastDeviceStatus = await deviceRepository.getDeviceStatus();
  }

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) {
    return _cacheDeviceStatus(
      _bleAutoReconnectCoordinator.pairDeviceManually(
        pairingCode: pairingCode,
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _bleAutoReconnectCoordinator.setAppForeground(true);
        unawaited(_bleAutoReconnectCoordinator.tryAutoConnectOnResume());
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _bleAutoReconnectCoordinator.setAppForeground(false);
        break;
    }
  }

  @override
  Stream<DeviceStatus> watchDeviceStatus() async* {
    final current =
        _lastDeviceStatus ?? await deviceRepository.getDeviceStatus();
    _lastDeviceStatus = current;
    yield current;
    yield* deviceRepository.watchDeviceStatus();
  }

  @override
  Future<DeviceSosStatus> getDeviceSosStatus() {
    return deviceSosController.getStatus();
  }

  @override
  Stream<DeviceSosStatus> watchDeviceSosStatus() async* {
    yield await deviceSosController.getStatus();
    yield* deviceSosController.watchStatus();
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
  Future<void> sendInetOkToDevice() {
    return deviceSosController.sendInetOk();
  }

  @override
  Future<void> sendInetLostToDevice() {
    return deviceSosController.sendInetLost();
  }

  @override
  Future<void> sendPositionConfirmedToDevice() {
    return deviceSosController.sendPositionConfirmed();
  }

  @override
  Future<void> sendSosAckRelayToDevice({required int nodeId}) {
    return deviceSosController.sendAckRelay(nodeId: nodeId);
  }

  @override
  Future<void> sendShutdownToDevice() {
    return deviceSosController.sendShutdown();
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

  @override
  Future<GuidedRescueState> getGuidedRescueState() async => _guidedRescueState;

  @override
  Stream<GuidedRescueState> watchGuidedRescueState() async* {
    yield _guidedRescueState;
    yield* _guidedRescueStateController.stream;
  }

  @override
  Future<GuidedRescueState> setGuidedRescueSession({
    required int targetNodeId,
    required int rescueNodeId,
  }) async {
    if (guidedRescueRuntime == null) {
      _guidedRescueState = _fallbackGuidedRescueState().copyWith(
        targetNodeId: targetNodeId,
        rescueNodeId: rescueNodeId,
        lastUpdatedAt: DateTime.now(),
        clearLastError: true,
      );
      _guidedRescueStateController.add(_guidedRescueState);
      return _guidedRescueState;
    }

    _guidedRescueState = await guidedRescueRuntime!.setSession(
      targetNodeId: targetNodeId,
      rescueNodeId: rescueNodeId,
    );
    _guidedRescueStateController.add(_guidedRescueState);
    return _guidedRescueState;
  }

  @override
  Future<void> clearGuidedRescueSession() async {
    if (guidedRescueRuntime == null) {
      _guidedRescueState = _fallbackGuidedRescueState();
      _guidedRescueStateController.add(_guidedRescueState);
      return;
    }
    await guidedRescueRuntime!.clearSession();
  }

  @override
  Future<void> requestGuidedRescuePosition() {
    return _runGuidedRescueCommand(GuidedRescueAction.requestPosition);
  }

  @override
  Future<void> acknowledgeGuidedRescueSos() {
    return _runGuidedRescueCommand(GuidedRescueAction.acknowledgeSos);
  }

  @override
  Future<void> enableGuidedRescueBuzzer() {
    return _runGuidedRescueCommand(GuidedRescueAction.buzzerOn);
  }

  @override
  Future<void> disableGuidedRescueBuzzer() {
    return _runGuidedRescueCommand(GuidedRescueAction.buzzerOff);
  }

  @override
  Future<void> requestGuidedRescueStatus() {
    return _runGuidedRescueCommand(GuidedRescueAction.requestStatus);
  }

  Future<void> _handleDeviceSosStatus(DeviceSosStatus status) async {
    final cycleKey = _deriveDeviceSosCycleKey(status);
    final isDeviceTimeoutPromotion = !status.derivedFromBlePacket &&
        status.state == DeviceSosState.active &&
        status.previousState == DeviceSosState.preConfirm &&
        status.triggerOrigin == DeviceSosTransitionSource.device &&
        status.transitionSource == DeviceSosTransitionSource.device;

    BleDebugRegistry.instance.recordEvent(
      'SOS packet observed -> payload=${status.lastPacketHex ?? '-'} state=${status.state.name} source=${status.transitionSource.name}',
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS state derived -> state=${status.state.name} previous=${status.previousState?.name ?? '-'} source=${status.transitionSource.name} derivedFromBle=${status.derivedFromBlePacket} nodeId=${_formatNodeId(status.nodeId)} packetId=${status.packetId?.toString() ?? '-'}',
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS cycle evaluated -> key=${cycleKey ?? '-'} activeCycle=${_activeDeviceSosCycleKey ?? '-'} notifiedCycle=${_notifiedDeviceSosCycleKey ?? '-'} notifiedState=${_notifiedDeviceSosState?.name ?? '-'}',
    );

    if (_isSosCycleClosed(status.state)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification suppression reset -> reason=cycle_closed clearedCycle=${_activeDeviceSosCycleKey ?? "-"}',
      );
      _activeDeviceSosCycleKey = null;
      _notifiedDeviceSosCycleKey = null;
      _notifiedDeviceSosState = null;
    }

    if (!status.derivedFromBlePacket && !isDeviceTimeoutPromotion) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> reason=not_from_ble_packet cycleKey=${cycleKey ?? "-"}',
      );
      return;
    }

    if (status.transitionSource != DeviceSosTransitionSource.device) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> reason=source_not_device cycleKey=${cycleKey ?? "-"}',
      );
      return;
    }

    if (!_isSosCycleNotifiable(status.state)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> reason=state_not_notifiable state=${status.state.name} cycleKey=${cycleKey ?? "-"}',
      );
      return;
    }

    if (cycleKey == null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> reason=missing_cycle_key',
      );
      return;
    }

    final previousActiveCycleKey = _activeDeviceSosCycleKey;
    if (previousActiveCycleKey == null) {
      _activeDeviceSosCycleKey = cycleKey;
      BleDebugRegistry.instance.recordEvent(
        'SOS cycle opened -> key=$cycleKey',
      );
    } else if (previousActiveCycleKey != cycleKey) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> reason=cycle_already_open activeCycle=$previousActiveCycleKey incomingCycle=$cycleKey',
      );
      return;
    }

    if (_notifiedDeviceSosCycleKey == cycleKey) {
      if (_notifiedDeviceSosState == status.state) {
        BleDebugRegistry.instance.recordEvent(
          'SOS notification skipped -> reason=already_notified_for_cycle_state cycleKey=$cycleKey state=${status.state.name}',
        );
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS notification state advanced -> cycleKey=$cycleKey from=${_notifiedDeviceSosState?.name ?? "-"} to=${status.state.name}',
      );
    }

    _notifiedDeviceSosCycleKey = cycleKey;
    _notifiedDeviceSosState = status.state;

    final title = _notificationTitleForSosState(status.state);
    final body = _notificationBodyForSosState(status.state);
    final actions = _notificationActionsForSosState(status.state);
    final payload = BleSosNotificationPayload(
      kind: 'sos_received',
      state: status.state,
      transitionSource: status.transitionSource,
      deviceId: _lastDeviceStatus?.deviceId,
      deviceAlias: _lastDeviceStatus?.deviceAlias,
      nodeId: status.nodeId,
    );

    BleDebugRegistry.instance.recordEvent(
      'SOS notification emitted -> cycleKey=$cycleKey source=${status.transitionSource.name}',
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
        'Local BLE notification failed -> kind=sos_received error=$error',
      );
      debugPrint('Local BLE notification failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  bool _isSosCycleNotifiable(DeviceSosState state) {
    return state == DeviceSosState.preConfirm ||
        state == DeviceSosState.active ||
        state == DeviceSosState.acknowledged;
  }

  bool _isSosCycleClosed(DeviceSosState state) {
    return state == DeviceSosState.inactive || state == DeviceSosState.resolved;
  }

  String? _deriveDeviceSosCycleKey(DeviceSosStatus status) {
    if (!_isSosCycleNotifiable(status.state)) {
      return null;
    }

    final deviceId = _lastDeviceStatus?.deviceId.trim();
    final nodeId = status.nodeId;
    final packetId = status.packetId;

    if (deviceId != null &&
        deviceId.isNotEmpty &&
        nodeId != null &&
        packetId != null) {
      return '$deviceId:$nodeId:$packetId:${status.sosType ?? -1}';
    }

    if (nodeId != null && packetId != null) {
      return 'node:$nodeId:packet:$packetId:${status.sosType ?? -1}';
    }

    return status.lastPacketSignature;
  }

  String _notificationTitleForSosState(DeviceSosState state) {
    if (state == DeviceSosState.preConfirm) {
      return 'Preventive SOS sent';
    }
    return 'SOS activated';
  }

  String _notificationBodyForSosState(DeviceSosState state) {
    if (state == DeviceSosState.preConfirm) {
      return 'Pending confirmation. You can cancel it or confirm it now.';
    }
    return 'Emergency protocol is now active. You can cancel or resolve the SOS.';
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
          id: _cancelSosActionId,
          title: 'Cancel SOS',
          foreground: true,
          destructive: true,
        ),
      );
      actions.add(
        const LocalNotificationAction(
          id: _confirmSosActionId,
          title: 'Confirm SOS',
          foreground: true,
        ),
      );
    }

    if (state == DeviceSosState.active) {
      actions.add(
        const LocalNotificationAction(
          id: _cancelSosActionId,
          title: 'Cancel SOS',
          foreground: true,
          destructive: true,
        ),
      );
      actions.add(
        const LocalNotificationAction(
          id: _resolveSosActionId,
          title: 'Resolve SOS',
          foreground: true,
          destructive: true,
        ),
      );
    }

    if (state == DeviceSosState.acknowledged) {
      actions.add(
        const LocalNotificationAction(
          id: _cancelSosActionId,
          title: 'Cancel SOS',
          foreground: true,
          destructive: true,
        ),
      );
      actions.add(
        const LocalNotificationAction(
          id: _resolveSosActionId,
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
    final actionId = invocation.actionId;
    BleDebugRegistry.instance.recordEvent(
      'Notification action tapped -> action=$actionId payload=${invocation.payload ?? '-'} launchedApp=${invocation.launchedApp}',
    );

    final deathManPayload =
        _DeathManNotificationPayload.tryParse(invocation.payload);
    if (deathManPayload != null) {
      try {
        await _handleDeathManNotificationAction(actionId, deathManPayload);
      } catch (error, stackTrace) {
        BleDebugRegistry.instance.recordEvent(
          'Death Man notification action failed -> action=$actionId error=$error',
        );
        debugPrint('Death Man notification action failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
      return;
    }

    final payload = BleSosNotificationPayload.tryParse(invocation.payload);
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
        case _cancelSosActionId:
        case _resolveSosActionId:
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

  Future<void> _handleDeathManNotificationAction(
    String actionId,
    _DeathManNotificationPayload payload,
  ) async {
    if (actionId == _confirmDeadManSafeActionId) {
      await confirmDeathManCheckIn(payload.planId);
      final activePlan = await deathManRepository.getActiveDeathManPlan();
      if (activePlan?.id == payload.planId) {
        await cancelDeathMan(payload.planId);
      }
      return;
    }

    await _queueBleNotificationNavigation(
      actionId: actionId,
      reason: 'Open the app to review the Dead Man safety check.',
      state: DeviceSosState.unknown,
    );
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

  String _formatNodeId(int? nodeId) {
    if (nodeId == null) {
      return '-';
    }
    final normalized = nodeId & 0xFFFF;
    return '0x${normalized.toRadixString(16).padLeft(4, '0')}';
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
  Future<void> publishTelemetry(SdkTelemetryPayload payload) {
    return telemetryRepository.publishTelemetry(payload);
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
  Stream<TrackingPosition> watchPositions() async* {
    final current = await trackingRepository.getCurrentPosition();
    if (current != null) {
      yield current;
    }
    yield* trackingRepository.watchPositions();
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
  Future<SosIncident> cancelSos() async {
    final incident = await sosRepository.cancelSos();
    if (incident.state == SosState.cancelled) {
      _pendingCancelledIncidentId = null;
      _eventsController.add(SOSCancelledEvent(incident.id));
    } else {
      _pendingCancelledIncidentId = incident.id;
    }
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
    required String phone,
    required String email,
    int priority = 1,
  }) {
    return contactsRepository.addEmergencyContact(
      name: name,
      phone: phone,
      email: email,
      priority: priority,
    );
  }

  @override
  Future<EmergencyContact> updateEmergencyContact(EmergencyContact contact) {
    return contactsRepository.updateEmergencyContact(contact);
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
  Stream<RealtimeConnectionState> watchRealtimeConnectionState() async* {
    yield _lastRealtimeConnectionState;
    yield* _realtimeConnectionStateController.stream;
  }

  @override
  Stream<RealtimeEvent> watchRealtimeEvents() {
    return _realtimeEventsController.stream;
  }

  void _startDeathManMonitoring(String planId) {
    _deathManTimer?.cancel();
    unawaited(_evaluateDeathManPlan(planId));
    _deathManTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_evaluateDeathManPlan(planId)),
    );
  }

  Future<void> _notifyDeathMan(
    String title,
    String body, {
    String? planId,
    bool includeConfirmAction = false,
  }) async {
    try {
      await notificationsRepository.initialize(
        onAction: _handleNotificationAction,
      );
      await notificationsRepository.showLocalNotification(
        title: title,
        body: body,
        payload: planId == null
            ? null
            : _DeathManNotificationPayload(planId).serialize(),
        actions: _notificationActionsForDeathMan(
          includeConfirmAction: includeConfirmAction,
        ),
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

  Future<DeviceStatus> _cacheDeviceStatus(
    Future<DeviceStatus> future,
  ) async {
    final status = await future;
    _lastDeviceStatus = status;
    return status;
  }

  Future<void> _resumeDeathManMonitoringIfNeeded() async {
    final activePlan = await deathManRepository.getActiveDeathManPlan();
    if (activePlan == null || !_shouldMonitorDeathManPlan(activePlan.status)) {
      return;
    }
    _deathManCheckInNotified =
        activePlan.status == DeathManStatus.awaitingConfirmation;
    _deathManOverdueNotified = activePlan.status == DeathManStatus.overdue ||
        activePlan.status == DeathManStatus.awaitingConfirmation;
    _startDeathManMonitoring(activePlan.id);
  }

  Future<void> _evaluateDeathManPlan(String planId) async {
    var plan = await deathManRepository.getActiveDeathManPlan();
    if (plan == null || plan.id != planId) {
      return;
    }

    final now = DateTime.now();
    final overdueAt = plan.expectedReturnAt.add(plan.gracePeriod);
    final expiresAt = overdueAt.add(plan.checkInWindow);

    if ((plan.status == DeathManStatus.monitoring ||
            plan.status == DeathManStatus.scheduled) &&
        now.isAfter(plan.expectedReturnAt)) {
      plan = await deathManRepository.updatePlanStatus(
        plan.id,
        DeathManStatus.overdue,
      );
      if (!_deathManOverdueNotified) {
        _deathManOverdueNotified = true;
        await _notifyDeathMan(
          'Safety check pending',
          'You are past the expected return time. Please confirm that you are safe.',
          planId: plan.id,
          includeConfirmAction: true,
        );
        _eventsController.add(
          DeathManStatusChangedEvent(plan.id, DeathManStatus.overdue.name),
        );
      }
    }

    if (plan.status == DeathManStatus.overdue && now.isAfter(overdueAt)) {
      plan = await deathManRepository.updatePlanStatus(
        plan.id,
        DeathManStatus.awaitingConfirmation,
      );
      if (!_deathManCheckInNotified) {
        _deathManCheckInNotified = true;
        await _notifyDeathMan(
          'Confirmation required',
          'If you do not respond during the check-in window, the SOS protocol will be triggered.',
          planId: plan.id,
          includeConfirmAction: true,
        );
        _eventsController.add(
          DeathManStatusChangedEvent(
            plan.id,
            DeathManStatus.awaitingConfirmation.name,
          ),
        );
      }
    }

    if (plan.status == DeathManStatus.awaitingConfirmation &&
        now.isAfter(expiresAt)) {
      await deathManRepository.updatePlanStatus(
        plan.id,
        DeathManStatus.escalated,
      );
      _eventsController.add(DeathManEscalatedEvent(plan.id));
      await _notifyDeathMan(
        'Protocol escalated',
        'No response was received. Automatic escalation has been triggered.',
        planId: plan.id,
      );
      if (plan.autoTriggerSos) {
        await triggerSos(
          message: 'Auto-triggered by Death Man Protocol',
          triggerSource: 'death_man_protocol',
        );
      }
      await deathManRepository.updatePlanStatus(
        plan.id,
        DeathManStatus.expired,
      );
      _eventsController.add(
        DeathManStatusChangedEvent(plan.id, DeathManStatus.expired.name),
      );
      _stopDeathManMonitoring();
    }
  }

  bool _shouldMonitorDeathManPlan(DeathManStatus status) {
    return status == DeathManStatus.scheduled ||
        status == DeathManStatus.monitoring ||
        status == DeathManStatus.overdue ||
        status == DeathManStatus.awaitingConfirmation;
  }

  List<LocalNotificationAction> _notificationActionsForDeathMan({
    required bool includeConfirmAction,
  }) {
    final actions = <LocalNotificationAction>[
      const LocalNotificationAction(
        id: _openAppActionId,
        title: 'Open app',
        foreground: true,
      ),
    ];
    if (includeConfirmAction) {
      actions.add(
        const LocalNotificationAction(
          id: _confirmDeadManSafeActionId,
          title: 'I\'m OK',
          foreground: true,
        ),
      );
    }
    return actions;
  }

  Future<void> _runGuidedRescueCommand(GuidedRescueAction action) async {
    final state = _guidedRescueState;
    if (!state.hasSession) {
      throw const RescueException.missingSession();
    }

    if (guidedRescueRuntime == null) {
      _guidedRescueState = state.copyWith(
        lastError: const RescueException.notImplemented().message,
        lastUpdatedAt: DateTime.now(),
      );
      _guidedRescueStateController.add(_guidedRescueState);
      throw const RescueException.notImplemented();
    }

    switch (action) {
      case GuidedRescueAction.requestPosition:
        await guidedRescueRuntime!.requestPosition();
        break;
      case GuidedRescueAction.acknowledgeSos:
        await guidedRescueRuntime!.acknowledgeSos();
        break;
      case GuidedRescueAction.buzzerOn:
        await guidedRescueRuntime!.enableBuzzer();
        break;
      case GuidedRescueAction.buzzerOff:
        await guidedRescueRuntime!.disableBuzzer();
        break;
      case GuidedRescueAction.requestStatus:
        await guidedRescueRuntime!.requestStatus();
        break;
    }
  }

  GuidedRescueState _fallbackGuidedRescueState() {
    return GuidedRescueState.unsupported(
      unavailableReason:
          'Guided Rescue Phase 1 contract is exposed by the SDK, but the runtime orchestration is still pending.',
    );
  }

  Future<void> dispose() async {
    WidgetsBinding.instance.removeObserver(this);
    _deathManTimer?.cancel();
    await _bleAutoReconnectCoordinator.dispose();
    await _realtimeConnectionSub?.cancel();
    await _realtimeEventsSub?.cancel();
    await _deviceStatusSub?.cancel();
    await _deviceSosSub?.cancel();
    await _guidedRescueSub?.cancel();
    await _sosStateSub?.cancel();
    await deviceSosController.dispose();
    await realtimeClient.disconnect();
    await disposeCallback?.call();
    await _realtimeConnectionStateController.close();
    await _realtimeEventsController.close();
    await _guidedRescueStateController.close();
    await _bleNotificationNavigationController.close();
    await _eventsController.close();
  }
}

class _DeathManNotificationPayload {
  const _DeathManNotificationPayload(this.planId);

  final String planId;

  String serialize() => 'death_man:$planId';

  static _DeathManNotificationPayload? tryParse(String? payload) {
    if (payload == null || !payload.startsWith('death_man:')) {
      return null;
    }
    final planId = payload.substring('death_man:'.length).trim();
    if (planId.isEmpty) {
      return null;
    }
    return _DeathManNotificationPayload(planId);
  }
}
