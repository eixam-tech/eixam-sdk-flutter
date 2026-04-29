import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:flutter/widgets.dart';

import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/datasources_local/sdk_session_store.dart';
import '../data/datasources_remote/sos_remote_data_source.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/api_sos_repository.dart';
import '../data/repositories/mqtt_operational_sos_repository.dart';
import '../data/datasources_remote/sdk_identity_remote_data_source.dart';
import '../device/ble_incoming_event.dart';
import '../device/device_sos_controller.dart';
import '../device/ble_debug_registry.dart';
import '../device/eixam_ble_command.dart';
import '../device/eixam_ble_protocol.dart';
import '../device/eixam_sos_event_packet.dart';
import '../device/eixam_sos_packet.dart';
import '../data/datasources_remote/sdk_session_context.dart';
import '../data/repositories/telemetry_repository.dart';
import '../data/repositories/sos_runtime_rehydration_support.dart';
import 'backlog_sync_controller.dart';
import 'background_telemetry_platform_adapter.dart';
import 'background_telemetry_platform_adapter_factory.dart';
import 'ble_operational_runtime_bridge.dart';
import 'ble_auto_reconnect_coordinator.dart';
import 'ble_sos_notification_payload.dart';
import 'guided_rescue_runtime.dart';
import 'operational_telemetry_coordinator.dart';
import 'operational_realtime_client.dart';
import 'protection_mode_controller.dart';
import 'protection_platform_adapter.dart';
import 'protection_platform_adapter_factory.dart';
import 'relay_ingest_context.dart';
import 'sdk_mqtt_contract.dart';

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
  final SdkDeviceRegistryRepository deviceRegistryRepository;
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
  final ProtectionPlatformAdapter protectionPlatformAdapter;
  final BackgroundTelemetryPlatformAdapter backgroundTelemetryPlatformAdapter;
  final Future<void> Function()? disposeCallback;

  final StreamController<EixamSdkEvent> _eventsController =
      StreamController.broadcast();

  final StreamController<RealtimeConnectionState>
      _realtimeConnectionStateController =
      StreamController<RealtimeConnectionState>.broadcast();

  final StreamController<RealtimeEvent> _realtimeEventsController =
      StreamController<RealtimeEvent>.broadcast();
  final StreamController<SdkOperationalDiagnostics>
      _operationalDiagnosticsController =
      StreamController<SdkOperationalDiagnostics>.broadcast();
  final StreamController<GuidedRescueState> _guidedRescueStateController =
      StreamController<GuidedRescueState>.broadcast();
  final StreamController<BleNotificationNavigationRequest>
      _bleNotificationNavigationController =
      StreamController<BleNotificationNavigationRequest>.broadcast();
  final StreamController<SosState> _publicSosStateController =
      StreamController<SosState>.broadcast();
  final StreamController<PublicPreSosStatus?> _publicPreSosStatusController =
      StreamController<PublicPreSosStatus?>.broadcast();

  StreamSubscription<RealtimeConnectionState>? _realtimeConnectionSub;
  StreamSubscription<RealtimeEvent>? _realtimeEventsSub;
  StreamSubscription<DeviceStatus>? _deviceStatusSub;
  StreamSubscription<DeviceSosStatus>? _deviceSosSub;
  StreamSubscription<bool>? _deviceSosCommandPathSub;
  StreamSubscription<GuidedRescueState>? _guidedRescueSub;
  StreamSubscription<BacklogSyncState>? _backlogSyncSub;
  StreamSubscription<SosState>? _sosStateSub;
  StreamSubscription<SdkBridgeDiagnostics>? _bridgeDiagnosticsSub;
  StreamSubscription<BleIncomingEvent>? _bleIncomingEventDiagnosticsSub;
  StreamSubscription<ProtectionStatus>? _protectionStatusSub;
  StreamSubscription<ProtectionPlatformEvent>? _protectionRawSosEventsSub;
  Timer? _protectionDisconnectGraceTimer;
  bool _lastProtectionDeviceConnected = false;

  Timer? _deathManTimer;
  bool _deathManCheckInNotified = false;
  bool _deathManOverdueNotified = false;

  RealtimeConnectionState _lastRealtimeConnectionState =
      RealtimeConnectionState.disconnected;
  RealtimeEvent? _lastRealtimeEvent;
  DeviceStatus? _lastDeviceStatus;
  GuidedRescueState _guidedRescueState = const GuidedRescueState.unsupported();
  BacklogSyncState _backlogSyncState = const BacklogSyncState.idle();
  BleNotificationNavigationRequest? _pendingBleNotificationNavigationRequest;
  String? _activeDeviceSosCycleKey;
  String? _notifiedDeviceSosCycleKey;
  DeviceSosState? _notifiedDeviceSosState;
  EixamSession? _session;
  EixamSdkEvent? _lastSosEvent;
  String? _pendingCancelledIncidentId;
  String? _lastSosRehydrationNote;
  SdkBridgeDiagnostics _bridgeDiagnostics = const SdkBridgeDiagnostics();
  SosState _publicSosState = SosState.idle;
  SosIncident? _publicSosFallbackIncident;
  String? _lastPublicSosIncidentId;
  SosDeliveryChannel? _lastPublicSosDeliveryChannel;
  _AppTriggeredSosBridge? _pendingAppTriggeredSosBridge;
  _PreSosSession? _preSosSession;
  int? _knownLocalDeviceNodeId;
  SosDeliveryChannel? _lastPublishedCurrentSosCapabilityChannel;
  DeviceTelRelayRx? _lastTelRelayRx;
  final Map<String, _ObservedRelaySosContext> _observedRelaySosBySignature =
      <String, _ObservedRelaySosContext>{};
  final Map<String, DateTime> _remoteRelaySosBackendHandoffBySignature =
      <String, DateTime>{};
  final Map<String, _SosClosureIntent>
      _deviceOriginatedClosureIntentByCycleKey = <String, _SosClosureIntent>{};
  final Map<String, _SosClosureIntent>
      _deviceOriginatedClosureIntentByIncidentId =
      <String, _SosClosureIntent>{};
  bool _publicSosActionInFlight = false;
  Future<SosIncident>? _pendingPreSosConfirmation;
  final Set<String> _deviceOriginatedBackendSyncInFlight = <String>{};
  EixamSdkConfig? _sdkConfig;
  bool _registeredDeviceAutoSyncInFlight = false;
  String? _lastRegisteredDeviceAutoSyncFingerprint;
  bool _lastDeviceSosCommandPathAvailable = false;
  late final BleAutoReconnectCoordinator _bleAutoReconnectCoordinator;
  late final BacklogSyncController _backlogSyncController;
  late final BleOperationalRuntimeBridge _bleOperationalRuntimeBridge;
  late final ProtectionModeController _protectionModeController;
  late final OperationalTelemetryCoordinator _operationalTelemetryCoordinator;
  final Duration _appTriggeredSosBridgeWindow;
  bool _backgroundTelemetryEnabled = true;
  bool _backgroundTelemetryStarted = false;
  String? _backgroundTelemetryStartFingerprint;
  String? _backgroundTelemetryNotificationTitle;
  String? _backgroundTelemetryNotificationBody;
  BackgroundTelemetryDiagnostics _backgroundTelemetryDiagnostics =
      const BackgroundTelemetryDiagnostics();

  static const String _openAppActionId = 'open_app';
  static const String _cancelSosActionId = 'cancel_sos';
  static const String _resolveSosActionId = 'resolve_sos';
  static const String _confirmSosActionId = 'confirm_sos';
  static const String _confirmDeadManSafeActionId = 'confirm_dead_man_safe';
  static const Duration _defaultAppTriggeredSosBridgeWindow =
      Duration(seconds: 15);
  static const Duration _preSosTickInterval = Duration(milliseconds: 50);

  EixamConnectSdkImpl({
    required this.sosRepository,
    required this.trackingRepository,
    required this.telemetryRepository,
    required this.contactsRepository,
    required this.deviceRepository,
    required this.deviceRegistryRepository,
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
    ProtectionPlatformAdapter? protectionPlatformAdapter,
    BackgroundTelemetryPlatformAdapter? backgroundTelemetryPlatformAdapter,
    Duration appTriggeredSosBridgeWindow = _defaultAppTriggeredSosBridgeWindow,
    this.disposeCallback,
  })  : _appTriggeredSosBridgeWindow = appTriggeredSosBridgeWindow,
        protectionPlatformAdapter = protectionPlatformAdapter ??
            buildDefaultProtectionPlatformAdapter(),
        backgroundTelemetryPlatformAdapter =
            backgroundTelemetryPlatformAdapter ??
                buildDefaultBackgroundTelemetryPlatformAdapter() {
    _bleAutoReconnectCoordinator = BleAutoReconnectCoordinator(
      deviceRepository: deviceRepository,
      preferredDeviceStore: preferredBleDeviceStore,
    );
    _bleOperationalRuntimeBridge = BleOperationalRuntimeBridge(
      bleIncomingEvents: bleIncomingEvents,
      connectionStates: realtimeClient.watchConnectionState(),
      realtimeEvents: realtimeClient.watchEvents(),
      telemetryRepository: telemetryRepository,
      sosRepository: sosRepository,
      deviceSosController: deviceSosController,
      sessionProvider: () => _session,
      backendHardwareIdResolver: (runtimeDeviceId) =>
          _loadBackendHardwareIdForOperationalPayloads(
        runtimeStatus: _lastDeviceStatus,
      ),
    );
    _backlogSyncController = BacklogSyncController(
      bleIncomingEvents: bleIncomingEvents,
      telemetryRepository: telemetryRepository,
      commandSender: _sendDeviceCommandThroughActiveOwner,
      backendHardwareIdResolver: () =>
          _loadBackendHardwareIdForOperationalPayloads(
        runtimeStatus: _lastDeviceStatus,
      ),
    );
    _protectionModeController = ProtectionModeController(
      platformAdapter: this.protectionPlatformAdapter,
      sessionProvider: () async => _session,
      sdkConfigProvider: () => _sdkConfig,
      deviceStatusProvider: () async =>
          _lastDeviceStatus ?? await deviceRepository.getDeviceStatus(),
      permissionStateProvider: permissionsRepository.getPermissionState,
      operationalDiagnosticsProvider: () async => _buildOperationalDiagnostics(
        reason: 'protection_mode_controller',
      ),
      backendHardwareIdProvider: () =>
          _loadBackendHardwareIdForOperationalPayloads(
        runtimeStatus: _lastDeviceStatus,
      ),
      onBleOwnershipChanged: _handleProtectionBleOwnershipChanged,
    );
    _operationalTelemetryCoordinator = OperationalTelemetryCoordinator(
      trackingRepository: trackingRepository,
      sosStateStream: _publicSosStateController.stream,
      sessionProvider: () => _session,
      publishTelemetry: publishTelemetry,
    );
    _bindSosStreams();
  }

  @override
  Future<void> initialize(EixamSdkConfig config) async {
    _sdkConfig = config;
    _session = await sessionStore?.load();
    _session = await _bootstrapSessionIfNeeded(_session);
    if (sessionContext != null) {
      sessionContext!.currentSession = _session;
    }
    await _rehydrateSosRuntimeState();
    _publicSosState = await sosRepository.getSosState();
    _lastDeviceStatus = await deviceRepository.getDeviceStatus();
    final deviceSosStatus = await deviceSosController.getStatus();
    _syncPreSosSessionFromDeviceStatus(deviceSosStatus);
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
    _bindBacklogSyncStreams();
    await notificationsRepository.initialize(
      onAction: _handleNotificationAction,
    );
    _bindRealtimeStreams();
    _bindOperationalDiagnostics();
    _bleOperationalRuntimeBridge.start();
    _emitOperationalDiagnostics();
    _operationalTelemetryCoordinator.start(initialSosState: _publicSosState);
    await _reconcileBackgroundTelemetry(reason: 'initialize');
    await realtimeClient.connect();
    await _resumeDeathManMonitoringIfNeeded();
    await _bleAutoReconnectCoordinator.tryAutoConnectOnStartup();
    _scheduleRegisteredDeviceAutoSync(
      trigger: 'initialize',
      status: _lastDeviceStatus,
    );
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
    _deviceSosCommandPathSub?.cancel();
    _lastDeviceSosCommandPathAvailable = deviceSosController.hasSosCommandPath;

    _deviceStatusSub = deviceRepository.watchDeviceStatus().listen((status) {
      final previousStatus = _lastDeviceStatus;
      _lastDeviceStatus = status;
      BleDebugRegistry.instance.recordEvent(
        'Device connectivity changed -> connected=${status.connected} previous=${previousStatus?.connected} deviceId=${status.deviceId} lifecycle=${status.lifecycleState.name}',
      );
      _emitOperationalDiagnostics();
      unawaited(
        _updateBackgroundTelemetryState(reason: 'device_status_stream'),
      );
      _scheduleRegisteredDeviceAutoSync(
        trigger: 'device_status_stream',
        status: status,
      );
      unawaited(
        _backlogSyncController.onDeviceStatusChanged(
          previous: previousStatus,
          current: status,
        ),
      );
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

    _deviceSosCommandPathSub =
        deviceSosController.watchCommandPathAvailability().listen(
      (available) async {
        final previous = _lastDeviceSosCommandPathAvailable;
        _lastDeviceSosCommandPathAvailable = available;
        BleDebugRegistry.instance.recordEvent(
          'SOS command path availability changed -> available=$available previous=$previous connected=${_lastDeviceStatus?.connected} deviceId=${_lastDeviceStatus?.deviceId ?? "-"}',
        );
        if (available == previous) {
          BleDebugRegistry.instance.recordEvent(
            'device_sos_command_path_changed -> diagnostics_refresh_skipped reason=no_effective_change',
          );
          return;
        }
        await _refreshOperationalDiagnostics(
          trigger: 'device_sos_command_path_changed',
          refreshRuntimeStatus: false,
        );
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'SOS command path monitor error: $error',
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
        _emitOperationalDiagnostics();
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

  void _bindOperationalDiagnostics() {
    _bridgeDiagnosticsSub?.cancel();
    _bridgeDiagnosticsSub =
        _bleOperationalRuntimeBridge.watchDiagnostics().listen((diagnostics) {
      _bridgeDiagnostics = diagnostics;
      _emitOperationalDiagnostics(reason: 'bridge_diagnostics');
    });
    _protectionStatusSub?.cancel();
    _protectionStatusSub =
        _protectionModeController.watchStatus().listen((status) {
      final previousConnected = _lastProtectionDeviceConnected;
      _lastProtectionDeviceConnected = status.deviceConnected;
      _reconcileProtectionDisconnectLifecycle(
        previousConnected: previousConnected,
        status: status,
      );
      _emitOperationalDiagnostics(
        reason:
            'protection_status:${status.bleOwner.name}:${status.serviceBleConnected}:${status.serviceBleReady}:${status.deviceConnected}',
      );
    });
    _bleIncomingEventDiagnosticsSub?.cancel();
    _bleIncomingEventDiagnosticsSub = bleIncomingEvents.listen(
      (event) {
        final relayPacket = event.telRelayRxPacket;
        if (relayPacket != null) {
          _lastTelRelayRx = relayPacket.relay;
          _emitOperationalDiagnostics(reason: 'ble_tel_relay_rx');
        }
        final remoteRelaySnapshot = event.remoteRelaySosSnapshot;
        if (remoteRelaySnapshot != null) {
          if (remoteRelaySnapshot.kind == RemoteRelaySosKind.sos) {
            BleDebugRegistry.instance.recordEvent(
              '[REMOTE_RELAY_SOS] observed '
              'originatorNodeId=${remoteRelaySnapshot.originatorNodeId} '
              'relayNodeId=${remoteRelaySnapshot.relayNodeId ?? "-"} '
              'hasLocation=${remoteRelaySnapshot.location != null}',
            );
          } else {
            BleDebugRegistry.instance.recordEvent(
              '[REMOTE_RELAY_SOS] remote_cancel_observed '
              'originatorNodeId=${remoteRelaySnapshot.originatorNodeId} '
              'relayNodeId=${remoteRelaySnapshot.relayNodeId ?? "-"}',
            );
          }
          _publishSdkEvent(RemoteRelaySosObservedEvent(remoteRelaySnapshot));
          unawaited(
            _handleRemoteRelaySosBackendHandoff(remoteRelaySnapshot),
          );
        }
        final sosPacket = event.sosPacket;
        final remoteDeviceId = sosPacket?.remoteDeviceId?.trim();
        if (sosPacket != null &&
            (sosPacket.relayCount > 0) &&
            remoteDeviceId != null &&
            remoteDeviceId.isNotEmpty) {
          final signature =
              '${sosPacket.nodeId}:${sosPacket.packetId}:${sosPacket.rawHex}';
          _observedRelaySosBySignature[signature] = _ObservedRelaySosContext(
            remoteDeviceId: remoteDeviceId,
            nodeId: sosPacket.nodeId,
            relayCount: sosPacket.relayCount,
            packetSignature: signature,
          );
        }
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'BLE diagnostics relay-event monitor error: $error',
        );
      },
    );
    _protectionRawSosEventsSub?.cancel();
    _protectionRawSosEventsSub =
        protectionPlatformAdapter.watchPlatformEvents().listen(
      (event) {
        _handleProtectionPlatformSosEvent(event);
      },
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'Protection platform SOS event monitor error: $error',
        );
      },
    );
  }

  void _reconcileProtectionDisconnectLifecycle({
    required bool previousConnected,
    required ProtectionStatus status,
  }) {
    if (!_canExitProtectionAfterDisconnect(status)) {
      _cancelProtectionDisconnectGraceTimer();
      return;
    }
    if (status.deviceConnected) {
      _cancelProtectionDisconnectGraceTimer();
      return;
    }
    if (_protectionDisconnectGraceTimer != null) {
      return;
    }
    if (!previousConnected) {
      return;
    }
    final gracePeriod = _currentProtectionDisconnectGracePeriod;
    _protectionDisconnectGraceTimer = Timer(gracePeriod, () async {
      _protectionDisconnectGraceTimer = null;
      final currentStatus = await _protectionModeController.getStatus();
      if (!_canExitProtectionAfterDisconnect(currentStatus) ||
          currentStatus.deviceConnected) {
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'Protection disconnect grace expired -> exiting protection mode owner=${currentStatus.bleOwner.name} graceMs=${gracePeriod.inMilliseconds}',
      );
      await _protectionModeController.exit();
      await _refreshOperationalDiagnostics(
        trigger: 'protection_disconnect_grace_expired',
        refreshRuntimeStatus: false,
      );
    });
  }

  bool _canExitProtectionAfterDisconnect(ProtectionStatus status) {
    if (!_isPlatformBleOwner(status.bleOwner)) {
      return false;
    }
    if (status.modeState == ProtectionModeState.off ||
        status.modeState == ProtectionModeState.stopping ||
        status.modeState == ProtectionModeState.error) {
      return false;
    }
    return true;
  }

  Duration get _currentProtectionDisconnectGracePeriod {
    return _protectionModeController.currentDisconnectGracePeriod;
  }

  void _cancelProtectionDisconnectGraceTimer() {
    _protectionDisconnectGraceTimer?.cancel();
    _protectionDisconnectGraceTimer = null;
  }

  void _bindBacklogSyncStreams() {
    _backlogSyncSub?.cancel();
    _backlogSyncState = _backlogSyncController.currentState;
    _backlogSyncSub = _backlogSyncController.watchState().listen((state) {
      _backlogSyncState = state;
    });
  }

  @override
  Future<void> setSession(EixamSession session) async {
    _bleOperationalRuntimeBridge.resetForSessionChange();
    _session = await _bootstrapSessionIfNeeded(session);
    if (sessionContext != null) {
      sessionContext!.currentSession = _session;
    }
    await _rehydrateSosRuntimeState();
    _publicSosFallbackIncident = null;
    _clearPendingAppTriggeredSosBridge(reason: 'session_replaced');
    _publicSosState = await sosRepository.getSosState();
    await sessionStore?.save(_session!);
    _emitOperationalDiagnostics();
    _operationalTelemetryCoordinator.start(initialSosState: _publicSosState);
    await _reconcileBackgroundTelemetry(reason: 'set_session');
    _scheduleRegisteredDeviceAutoSync(
      trigger: 'set_session',
      status: _lastDeviceStatus,
    );
    final realtime = realtimeClient;
    if (realtime is OperationalRealtimeClient) {
      await realtime.reconnectIfSessionChanged(_session!);
      return;
    }
    await realtimeClient.connect();
  }

  @override
  Future<EixamSession> refreshCanonicalIdentity() async {
    final session = _session;
    if (session == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'An SDK session must be configured before refreshing identity.',
      );
    }
    final remoteDataSource = identityRemoteDataSource;
    final refreshed = remoteDataSource == null
        ? session
        : await remoteDataSource.bootstrapSession(session);
    _session = refreshed;
    if (sessionContext != null) {
      sessionContext!.currentSession = refreshed;
    }
    await _rehydrateSosRuntimeState();
    _publicSosFallbackIncident = null;
    _clearPendingAppTriggeredSosBridge(reason: 'identity_refreshed');
    _publicSosState = await sosRepository.getSosState();
    await sessionStore?.save(refreshed);
    _emitOperationalDiagnostics();
    _operationalTelemetryCoordinator.start(initialSosState: _publicSosState);
    await _reconcileBackgroundTelemetry(reason: 'refresh_identity');
    _scheduleRegisteredDeviceAutoSync(
      trigger: 'refresh_identity',
      status: _lastDeviceStatus,
    );
    final realtime = realtimeClient;
    if (realtime is OperationalRealtimeClient) {
      await realtime.reconnectIfSessionChanged(refreshed);
    } else {
      await realtime.connect();
    }
    return refreshed;
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
    _sosStateSub = sosRepository.watchSosState().listen((state) async {
      await _syncPublicSosStateFromRepository(state);
      if (state == SosState.cancelled || state == SosState.resolved) {
        await _clearSosNotificationsSafely(
          reason: 'public_state_stream:${state.name}',
        );
      }
      final incidentId = _pendingCancelledIncidentId;
      if (state == SosState.cancelled && incidentId != null) {
        _pendingCancelledIncidentId = null;
        _publishSdkEvent(SOSCancelledEvent(incidentId));
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
    await _stopBackgroundTelemetry(reason: 'clear_session');
    await _operationalTelemetryCoordinator.stop();
    _bleOperationalRuntimeBridge.clearPendingOperationalItems();
    _session = null;
    _lastSosRehydrationNote = null;
    _publicSosFallbackIncident = null;
    _lastPublicSosIncidentId = null;
    _lastPublicSosDeliveryChannel = null;
    _clearPreSosSession(
      reason: 'session_cleared',
      emitIdleState: false,
    );
    _clearPendingAppTriggeredSosBridge(reason: 'session_cleared');
    _emitPublicSosState(SosState.idle);
    if (sessionContext != null) {
      sessionContext!.currentSession = null;
    }
    await sessionStore?.clear();
    _emitOperationalDiagnostics();
    await realtimeClient.disconnect();
  }

  @override
  Future<void> enableBackgroundTelemetry({
    String? notificationTitle,
    String? notificationBody,
  }) async {
    _backgroundTelemetryEnabled = true;
    _backgroundTelemetryNotificationTitle = notificationTitle;
    _backgroundTelemetryNotificationBody = notificationBody;
    await _reconcileBackgroundTelemetry(reason: 'enable_background_telemetry');
    _emitOperationalDiagnostics();
  }

  @override
  Future<void> disableBackgroundTelemetry() async {
    _backgroundTelemetryEnabled = false;
    await _stopBackgroundTelemetry(reason: 'disable_background_telemetry');
    _operationalTelemetryCoordinator.setIntervalPublishingEnabled(true);
    _emitOperationalDiagnostics();
  }

  Future<void> _rehydrateSosRuntimeState() async {
    _lastSosRehydrationNote = null;

    if (_session == null) {
      return;
    }

    if (sosRepository is! SosRuntimeRehydrationSupport) {
      return;
    }
    final rehydrationRepository = sosRepository as SosRuntimeRehydrationSupport;

    try {
      final result =
          await rehydrationRepository.rehydrateRuntimeStateFromBackend();
      _lastSosRehydrationNote = result.diagnosticNote;
    } catch (error) {
      _lastSosRehydrationNote =
          'SOS rehydration failed before startup completed. Error: $error';
    }
  }

  @override
  Future<EixamSession?> getCurrentSession() async => _session;

  Future<void> _reconcileBackgroundTelemetry({
    required String reason,
  }) async {
    final session = _session;
    final config = _sdkConfig;
    if (!_backgroundTelemetryEnabled || session == null || config == null) {
      await _stopBackgroundTelemetry(reason: reason);
      _operationalTelemetryCoordinator.setIntervalPublishingEnabled(true);
      return;
    }

    final status = _lastDeviceStatus;
    final deviceId = _resolveOperationalDeviceId(
      backendHardwareId: await _loadBackendHardwareIdForOperationalPayloads(
        runtimeStatus: status,
      ),
    );
    final fingerprint = _backgroundTelemetryFingerprint(
      apiBaseUrl: config.apiBaseUrl,
      session: session,
    );
    if (_backgroundTelemetryStarted &&
        _backgroundTelemetryStartFingerprint == fingerprint) {
      await _updateBackgroundTelemetryState(reason: reason);
      _operationalTelemetryCoordinator.setIntervalPublishingEnabled(false);
      return;
    }
    try {
      await backgroundTelemetryPlatformAdapter.startBackgroundTelemetry(
        BackgroundTelemetryStartRequest(
          apiBaseUrl: config.apiBaseUrl,
          session: session,
          sosOpen: _isOpenSosState(_publicSosState),
          deviceId: deviceId,
          deviceBattery: _buildDeviceBatterySnapshot(status),
          deviceCoverage: _buildDeviceCoverageSnapshot(status),
          notificationTitle: _backgroundTelemetryNotificationTitle,
          notificationBody: _backgroundTelemetryNotificationBody,
        ),
      );
      _backgroundTelemetryStarted = true;
      _backgroundTelemetryStartFingerprint = fingerprint;
      _operationalTelemetryCoordinator.setIntervalPublishingEnabled(false);
      await _refreshBackgroundTelemetryDiagnostics();
      BleDebugRegistry.instance.recordEvent(
        '[SDK_BACKGROUND_TELEMETRY] action=start reason=$reason',
      );
    } catch (error) {
      _backgroundTelemetryStarted = false;
      _backgroundTelemetryStartFingerprint = null;
      _operationalTelemetryCoordinator.setIntervalPublishingEnabled(true);
      _backgroundTelemetryDiagnostics = BackgroundTelemetryDiagnostics(
        enabled: _backgroundTelemetryEnabled,
        serviceRunning: false,
        permissionStatus: 'unknown',
        lastTelemetryAt: _backgroundTelemetryDiagnostics.lastTelemetryAt,
        lastTelemetryError: error.toString(),
        lastLocationMode: _backgroundTelemetryDiagnostics.lastLocationMode,
        activeLocationRequest:
            _backgroundTelemetryDiagnostics.activeLocationRequest,
      );
      BleDebugRegistry.instance.recordEvent(
        '[SDK_BACKGROUND_TELEMETRY] action=start_failed reason=$reason error=$error',
      );
    }
  }

  Future<void> _updateBackgroundTelemetryState({
    required String reason,
  }) async {
    if (!_backgroundTelemetryEnabled || !_backgroundTelemetryStarted) {
      return;
    }
    final status = _lastDeviceStatus;
    try {
      await backgroundTelemetryPlatformAdapter.updateBackgroundTelemetry(
        sosOpen: _isOpenSosState(_publicSosState),
        deviceId: _resolveOperationalDeviceId(
          backendHardwareId: await _loadBackendHardwareIdForOperationalPayloads(
            runtimeStatus: status,
          ),
        ),
        deviceBattery: _buildDeviceBatterySnapshot(status),
        deviceCoverage: _buildDeviceCoverageSnapshot(status),
      );
      await _refreshBackgroundTelemetryDiagnostics();
    } catch (error) {
      _backgroundTelemetryDiagnostics = BackgroundTelemetryDiagnostics(
        enabled: _backgroundTelemetryEnabled,
        serviceRunning: _backgroundTelemetryDiagnostics.serviceRunning,
        permissionStatus: _backgroundTelemetryDiagnostics.permissionStatus,
        lastTelemetryAt: _backgroundTelemetryDiagnostics.lastTelemetryAt,
        lastTelemetryError: error.toString(),
        lastLocationMode: _backgroundTelemetryDiagnostics.lastLocationMode,
        activeLocationRequest:
            _backgroundTelemetryDiagnostics.activeLocationRequest,
      );
      BleDebugRegistry.instance.recordEvent(
        '[SDK_BACKGROUND_TELEMETRY] action=update_failed reason=$reason error=$error',
      );
    }
  }

  Future<void> _stopBackgroundTelemetry({required String reason}) async {
    if (!_backgroundTelemetryStarted && !_backgroundTelemetryEnabled) {
      return;
    }
    try {
      await backgroundTelemetryPlatformAdapter.stopBackgroundTelemetry();
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[SDK_BACKGROUND_TELEMETRY] action=stop_failed reason=$reason error=$error',
      );
    }
    _backgroundTelemetryStarted = false;
    _backgroundTelemetryStartFingerprint = null;
    await _refreshBackgroundTelemetryDiagnostics();
  }

  String _backgroundTelemetryFingerprint({
    required String apiBaseUrl,
    required EixamSession session,
  }) {
    return [
      apiBaseUrl,
      session.appId,
      session.externalUserId,
      session.userHash,
      session.canonicalExternalUserId ?? '',
      session.sdkUserId ?? '',
    ].join('|');
  }

  Future<void> _refreshBackgroundTelemetryDiagnostics() async {
    try {
      _backgroundTelemetryDiagnostics = await backgroundTelemetryPlatformAdapter
          .getBackgroundTelemetryDiagnostics();
    } catch (_) {
      _backgroundTelemetryDiagnostics = BackgroundTelemetryDiagnostics(
        enabled: _backgroundTelemetryEnabled,
        serviceRunning: _backgroundTelemetryStarted,
        permissionStatus: 'unknown',
        lastTelemetryAt: _backgroundTelemetryDiagnostics.lastTelemetryAt,
        lastTelemetryError: _backgroundTelemetryDiagnostics.lastTelemetryError,
        lastLocationMode: _backgroundTelemetryDiagnostics.lastLocationMode,
        activeLocationRequest:
            _backgroundTelemetryDiagnostics.activeLocationRequest,
      );
    }
  }

  bool _isOpenSosState(SosState state) {
    return switch (state) {
      SosState.arming ||
      SosState.triggerRequested ||
      SosState.triggeredLocal ||
      SosState.sending ||
      SosState.sent ||
      SosState.acknowledged ||
      SosState.cancelRequested =>
        true,
      SosState.idle ||
      SosState.cancelled ||
      SosState.resolved ||
      SosState.failed =>
        false,
    };
  }

  @override
  Future<DeviceStatus> connectDevice({required String pairingCode}) {
    return pairDevice(pairingCode: pairingCode);
  }

  @override
  Future<void> disconnectDevice() {
    return unpairDevice();
  }

  @override
  Future<PreferredDevice?> get preferredDevice {
    return preferredBleDeviceStore.getPreferredDevice();
  }

  @override
  Stream<DeviceStatus> get deviceStatusStream => watchDeviceStatus();

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
        unawaited(
          _rehydrateDeviceSosPublicState(
            trigger: 'app_resumed',
            emitResolvedState: true,
          ),
        );
        if (_isProtectionPlatformOwningBle) {
          unawaited(
            protectionPlatformAdapter.ensureProtectionRuntimeActive(
              reason: 'app_foreground_resume',
            ),
          );
          unawaited(_protectionModeController.rehydrate());
        } else {
          unawaited(_bleAutoReconnectCoordinator.tryAutoConnectOnResume());
        }
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
    return deviceSosController.triggerSos(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  Future<DeviceSosStatus> _activateActiveSosOnDeviceFromApp() {
    if (_isProtectionPlatformOwningBle) {
      return _activateActiveSosOnNativeOwnerFromApp();
    }
    return deviceSosController.activateSosFromApp(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  Future<DeviceSosStatus> _activateActiveSosOnNativeOwnerFromApp() async {
    try {
      return await deviceSosController.activateSosFromApp(
        commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
        commandRouteLabel: _currentDeviceCommandOwnerRoute,
      );
    } catch (error) {
      final status = await deviceSosController.getStatus();
      final canFallbackToImmediateConfirm =
          status.state == DeviceSosState.preConfirm &&
              status.triggerOrigin == DeviceSosTransitionSource.app;
      if (!canFallbackToImmediateConfirm) {
        rethrow;
      }
      try {
        return await deviceSosController.confirmSos(
          commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
          commandRouteLabel: _currentDeviceCommandOwnerRoute,
        );
      } catch (confirmError) {
        BleDebugRegistry.instance.recordEvent(
          'App SOS device activation incomplete -> route=$_currentDeviceCommandOwnerRoute state=${status.state.name} error=$confirmError note=device_stayed_in_pre_sos',
        );
        rethrow;
      }
    }
  }

  @override
  Future<DeviceSosStatus> confirmDeviceSos() async {
    final status = await deviceSosController.confirmSos(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
    await _ensureBackendSosForDeviceOriginatedCycle(
      status,
      triggerSource: 'ble_device_runtime_confirm',
      message:
          'Device-originated SOS confirmed from the app and promoted to backend sync.',
    );
    return status;
  }

  @override
  Future<DeviceSosStatus> cancelDeviceSos() async {
    return _closeDeviceSos(intent: _SosClosureIntent.cancel);
  }

  Future<DeviceSosStatus> _closeDeviceSos({
    required _SosClosureIntent intent,
    bool syncBackendForDeviceOriginatedCycle = true,
  }) async {
    final currentStatus = await deviceSosController.getStatus();
    late final DeviceSosStatus status;
    try {
      status = await deviceSosController.cancelSos(
        commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
        commandRouteLabel: _currentDeviceCommandOwnerRoute,
      );
    } catch (error) {
      if (currentStatus.triggerOrigin != DeviceSosTransitionSource.device ||
          !_canCloseDeviceSosForPublicSos(currentStatus)) {
        rethrow;
      }
      status = currentStatus.copyWith(
        state: DeviceSosState.resolved,
        previousState: currentStatus.state,
        transitionSource: DeviceSosTransitionSource.app,
        lastEvent:
            'SDK accepted device-originated SOS cancellation after command dispatch without waiting for a close acknowledgement.',
        updatedAt: DateTime.now(),
        optimistic: false,
        derivedFromBlePacket: false,
        countdownStartedAt: null,
        expectedActivationAt: null,
        countdownRemainingSeconds: null,
      );
    }
    if (syncBackendForDeviceOriginatedCycle) {
      await _applyBackendClosureForDeviceOriginatedCycle(
        status,
        fallbackIntent: intent,
      );
    }
    return status;
  }

  @override
  Future<DeviceSosStatus> acknowledgeDeviceSos() {
    return deviceSosController.acknowledgeSos(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
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
  Future<void> sendShutdownToDevice() async {
    return deviceSosController.sendShutdown(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  @override
  Future<void> setDeviceNotificationVolume(int volume) async {
    await _requireCommandCapableDeviceRepository()
        .setNotificationVolume(volume);
  }

  @override
  Future<void> setDeviceSosVolume(int volume) async {
    await _requireCommandCapableDeviceRepository().setSosVolume(volume);
  }

  @override
  Future<DeviceRuntimeStatus> getDeviceRuntimeStatus() async {
    return _requireCommandCapableDeviceRepository().getDeviceRuntimeStatus();
  }

  @override
  Future<void> rebootDevice() async {
    await _requireCommandCapableDeviceRepository().rebootDevice();
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
  Future<ProtectionReadinessReport> evaluateProtectionReadiness() {
    return _protectionModeController.evaluateReadiness();
  }

  @override
  Future<EnterProtectionModeResult> enterProtectionMode({
    ProtectionModeOptions options = const ProtectionModeOptions(),
  }) {
    return _protectionModeController.enter(options: options);
  }

  @override
  Future<ProtectionStatus> exitProtectionMode() {
    return _protectionModeController.exit();
  }

  @override
  Future<ProtectionStatus> getProtectionStatus() {
    return _protectionModeController.getStatus();
  }

  @override
  Stream<ProtectionStatus> watchProtectionStatus() {
    return _protectionModeController.watchStatus();
  }

  @override
  Future<ProtectionDiagnostics> getProtectionDiagnostics() {
    return _protectionModeController.getDiagnostics();
  }

  @override
  Stream<ProtectionDiagnostics> watchProtectionDiagnostics() {
    return _protectionModeController.watchDiagnostics();
  }

  @override
  Future<ProtectionStatus> rehydrateProtectionState() {
    return _protectionModeController.rehydrate();
  }

  @override
  Future<FlushProtectionQueuesResult> flushProtectionQueues() {
    return _protectionModeController.flushQueues();
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

  @override
  Future<BacklogSyncState> getBacklogSyncState() async =>
      _backlogSyncController.currentState;

  @override
  Stream<BacklogSyncState> watchBacklogSyncState() async* {
    yield _backlogSyncController.currentState;
    yield* _backlogSyncController.watchState();
  }

  @override
  Future<BacklogSyncState> startBacklogSync({
    DateTime? since,
    int maxEvents = 100,
  }) async {
    _backlogSyncState = await _backlogSyncController.start(
      since: since,
      maxEvents: maxEvents,
    );
    return _backlogSyncController.currentState;
  }

  @override
  Future<void> cancelBacklogSync() async {
    await _backlogSyncController.cancel();
    _backlogSyncState = _backlogSyncController.currentState;
  }

  Future<void> _handleDeviceSosStatus(DeviceSosStatus status) async {
    _emitOperationalDiagnostics();
    _consumePendingAppTriggeredSosBridge(status);
    if (status.state == DeviceSosState.preConfirm) {
      _syncPreSosSessionFromDeviceStatus(status);
    } else if (status.previousState == DeviceSosState.preConfirm) {
      _clearPreSosSession(
        reason: 'device_left_pre_confirm:${status.state.name}',
        emitIdleState: false,
      );
    }
    final isCorrelatedAppTriggeredStatus =
        _isCorrelatedAppTriggeredSosStatus(status);
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

    final isAppOriginatedStatus =
        status.triggerOrigin == DeviceSosTransitionSource.app;
    if (isAppOriginatedStatus || isCorrelatedAppTriggeredStatus) {
      if (status.nodeId != null) {
        _knownLocalDeviceNodeId = status.nodeId;
      }
      BleDebugRegistry.instance.recordEvent(
        isCorrelatedAppTriggeredStatus
            ? 'App-triggered SOS correlation preserved -> incidentId=${_pendingAppTriggeredSosBridge?.incidentId ?? "-"} nodeId=${_formatNodeId(status.nodeId)} state=${status.state.name}'
            : 'App-triggered SOS origin preserved without pending bridge -> nodeId=${_formatNodeId(status.nodeId)} state=${status.state.name}',
      );
    } else {
      await _synchronizeDeviceOriginatedBackendLifecycle(status);
    }

    await _rehydrateDeviceSosPublicState(
      trigger: 'device_sos_status:${status.state.name}',
      deviceStatus: status,
      emitResolvedState: true,
    );

    if (_isSosCycleClosed(status.state)) {
      final closedCycleKey = _activeDeviceSosCycleKey;
      BleDebugRegistry.instance.recordEvent(
        'SOS notification suppression reset -> reason=cycle_closed clearedCycle=${_activeDeviceSosCycleKey ?? "-"}',
      );
      await _clearSosNotificationsSafely(
        reason: 'device_cycle_closed:${status.state.name}',
      );
      _activeDeviceSosCycleKey = null;
      _notifiedDeviceSosCycleKey = null;
      _notifiedDeviceSosState = null;
      _clearRememberedDeviceOriginatedClosureIntent(cycleKey: closedCycleKey);
      _clearPendingAppTriggeredSosBridge(reason: 'device_cycle_closed');
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

    if (_shouldSuppressExternalSosNotificationForSelfNode(status)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> reason=self_node nodeId=${_formatNodeId(status.nodeId)}',
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
    final payload = BleSosNotificationPayload(
      kind: 'sos_received',
      state: status.state,
      transitionSource: status.transitionSource,
      deviceId: _lastDeviceStatus?.deviceId,
      deviceAlias: _lastDeviceStatus?.deviceAlias,
      nodeId: status.nodeId,
    );

    BleDebugRegistry.instance.recordEvent(
      'SOS notification emitted -> reason=external_node nodeId=${_formatNodeId(status.nodeId)} cycleKey=$cycleKey source=${status.transitionSource.name}',
    );

    try {
      await notificationsRepository.showLocalNotification(
        notificationId: _nextBleNotificationId(),
        title: title,
        body: body,
        payload: payload.toJsonString(),
        actions: const <LocalNotificationAction>[],
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

  bool _shouldSuppressExternalSosNotificationForSelfNode(
    DeviceSosStatus status,
  ) {
    final nodeId = status.nodeId;
    if (nodeId == null) {
      return false;
    }
    if (_knownLocalDeviceNodeId == nodeId) {
      return true;
    }
    final bridge = _pendingAppTriggeredSosBridge;
    return bridge != null &&
        bridge.nodeId == nodeId &&
        (status.triggerOrigin == DeviceSosTransitionSource.app ||
            _isCorrelatedAppTriggeredSosStatus(status));
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
      return '$deviceId:$nodeId:$packetId';
    }

    if (nodeId != null && packetId != null) {
      return 'node:$nodeId:packet:$packetId';
    }

    return status.lastPacketSignature;
  }

  String? debugDeriveDeviceSosCycleKey(DeviceSosStatus status) {
    return _deriveDeviceSosCycleKey(status);
  }

  String _notificationTitleForSosState(DeviceSosState state) {
    if (state == DeviceSosState.preConfirm) {
      return 'Preventive SOS sent';
    }
    return 'SOS activated';
  }

  String _notificationBodyForSosState(DeviceSosState state) {
    if (state == DeviceSosState.preConfirm) {
      return 'Pending confirmation. Tap to open the app and review it.';
    }
    return 'Emergency protocol is now active. Tap to open the app and review it.';
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
          await _closeDeviceSos(intent: _SosClosureIntent.cancel);
          return;
        case _resolveSosActionId:
          await _closeDeviceSos(intent: _SosClosureIntent.resolve);
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
    final normalized = nodeId & 0xFFFFFFFF;
    return '0x${normalized.toRadixString(16).padLeft(8, '0')} ($nodeId)';
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
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    await telemetryRepository.publishTelemetry(
      await _enrichOperationalTelemetryPayload(payload),
    );
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
  Future<void> startPreSos({
    Duration countdown = const Duration(seconds: 20),
  }) async {
    if (_hasBackendVisibleSosIncident(await getCurrentSosIncident()) ||
        _hasActivePreSosSession) {
      return;
    }

    final currentDeviceStatus = await deviceSosController.getStatus();
    if (currentDeviceStatus.state == DeviceSosState.preConfirm) {
      _syncPreSosSessionFromDeviceStatus(currentDeviceStatus);
      return;
    }

    var mirroredOnDevice = false;
    final runtimeStatus = await _loadRuntimeReadyDeviceStatusForSosSync(
      action: 'pre_sos_start',
      refreshRuntimeStatus: true,
    );
    if (runtimeStatus != null) {
      final deviceStatus = await triggerDeviceSos();
      mirroredOnDevice = deviceStatus.state == DeviceSosState.preConfirm ||
          deviceStatus.state == DeviceSosState.active;
      _syncPreSosSession(
        startedAt: deviceStatus.countdownStartedAt ?? DateTime.now(),
        expectedActivationAt:
            deviceStatus.expectedActivationAt ?? DateTime.now().add(countdown),
        mirroredOnDevice: mirroredOnDevice,
        origin: DeviceSosTransitionSource.app,
      );
      return;
    }

    final startedAt = DateTime.now();
    _syncPreSosSession(
      startedAt: startedAt,
      expectedActivationAt: startedAt.add(countdown),
      mirroredOnDevice: mirroredOnDevice,
      origin: DeviceSosTransitionSource.app,
    );
  }

  @override
  Future<SosIncident> confirmPreSos(SosTriggerPayload payload) {
    final pending = _pendingPreSosConfirmation;
    if (pending != null) {
      return pending;
    }
    final future = _confirmPreSosInternal(payload);
    _pendingPreSosConfirmation = future;
    return future.whenComplete(() {
      if (identical(_pendingPreSosConfirmation, future)) {
        _pendingPreSosConfirmation = null;
      }
    });
  }

  @override
  Future<void> cancelPreSos() async {
    final status = await deviceSosController.getStatus();
    if (status.state == DeviceSosState.preConfirm) {
      await cancelDeviceSos();
    }
    _clearPreSosSession(
      reason: 'public_pre_sos_cancelled',
      emitIdleState: true,
    );
  }

  @override
  Future<PublicPreSosStatus?> getPreSosStatus() async {
    final deviceStatus = await deviceSosController.getStatus();
    await _rehydrateDeviceSosPublicState(
      trigger: 'getPreSosStatus',
      deviceStatus: deviceStatus,
      emitResolvedState: false,
    );
    return _buildCurrentPreSosStatus();
  }

  @override
  Stream<PublicPreSosStatus?> watchPreSosStatus() async* {
    yield await getPreSosStatus();
    yield* _publicPreSosStatusController.stream;
  }

  @override
  Future<SosIncident> triggerSos(SosTriggerPayload payload) async {
    if (_hasActivePreSosSession ||
        (await deviceSosController.getStatus()).state ==
            DeviceSosState.preConfirm) {
      return confirmPreSos(payload);
    }
    return _activatePublicSos(payload);
  }

  Future<SosIncident> _activatePublicSos(
    SosTriggerPayload payload, {
    bool skipDeviceAction = false,
    bool deviceAlreadyActive = false,
  }) async {
    _publicSosActionInFlight = true;
    try {
      final positionSnapshot = await _loadPositionSnapshotForSos();
      final deviceId = await _loadBackendHardwareIdForOperationalPayloads(
        runtimeStatus: _lastDeviceStatus,
      );
      final metadata = _buildOperationalSosMetadata();
      final capabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
        reason: 'trigger_sos_start',
      );
      BleDebugRegistry.instance.recordEvent(
        'triggerSos() start -> backendAvailable=${capabilitySnapshot.backendAvailable} cachedDeviceConnected=${_lastDeviceStatus?.connected} commandPath=${capabilitySnapshot.hasSosCommandPath} currentCapability=${capabilitySnapshot.capability?.name ?? "unavailable"} activeOwner=$_currentDeviceCommandOwnerRoute',
      );
      final deviceSync = skipDeviceAction
          ? _PublicSosDeviceAttempt(
              available: deviceAlreadyActive,
              attempted: false,
              succeeded: deviceAlreadyActive,
            )
          : await _attemptPublicSosDeviceAction(
              action: 'trigger',
              shouldRun: _canTriggerDeviceSosForPublicSos,
              operation: _activateActiveSosOnDeviceFromApp,
              refreshRuntimeStatus: true,
            );

      SosIncident? backendIncident;
      Object? backendError;
      try {
        backendIncident = await sosRepository.triggerSos(
          message: payload.message,
          triggerSource: payload.triggerSource,
          positionSnapshot: positionSnapshot,
          deviceId: deviceId,
          deviceBattery: metadata.deviceBattery,
          deviceCoverage: metadata.deviceCoverage,
          mobileBattery: metadata.mobileBattery,
          mobileCoverage: metadata.mobileCoverage,
        );
      } catch (error) {
        backendError = error;
        BleDebugRegistry.instance.recordEvent(
          'Public SOS backend trigger failed -> error=$error',
        );
      }

      final deliveryChannel = _resolveSuccessfulSosDeliveryChannel(
        backendSucceeded: backendIncident != null,
        deviceSucceeded: deviceSync.succeeded,
      );
      BleDebugRegistry.instance.recordEvent(
        'triggerSos() channel decision -> backendSucceeded=${backendIncident != null} deviceAvailable=${deviceSync.available} deviceAttempted=${deviceSync.attempted} deviceSucceeded=${deviceSync.succeeded} activeOwner=$_currentDeviceCommandOwnerRoute delivery=${deliveryChannel?.name ?? "-"}',
      );
      if (deliveryChannel == null) {
        _throwTriggerSosFailure(
          backendError: backendError,
          backendUnavailable: _isBackendUnavailableForTrigger(backendError),
          deviceAvailable: deviceSync.available,
        );
      }

      final incident = backendIncident != null
          ? backendIncident.copyWith(deliveryChannel: deliveryChannel)
          : _createDeviceOnlyPublicSosIncident(
              payload: payload,
              positionSnapshot: positionSnapshot,
              deliveryChannel: deliveryChannel,
            );
      _recordPublicSosResult(
        incident: incident,
        deliveryChannel: deliveryChannel,
        fallbackState: backendIncident == null ? SosState.sent : null,
      );
      if (deviceSync.succeeded) {
        _registerPendingAppTriggeredSosBridge(incident);
      } else {
        _clearPendingAppTriggeredSosBridge(
          reason: 'public_trigger_device_sync_not_completed',
        );
      }
      _publishSdkEvent(SOSTriggeredEvent(incident.id));
      return incident;
    } finally {
      _publicSosActionInFlight = false;
    }
  }

  Future<SosIncident> _confirmPreSosInternal(SosTriggerPayload payload) async {
    final deviceStatus = await deviceSosController.getStatus();
    final session = _preSosSession;
    final hasLocalSession = session != null;
    final devicePreConfirm = deviceStatus.state == DeviceSosState.preConfirm;
    final deviceAlreadyActive = deviceStatus.state == DeviceSosState.active ||
        deviceStatus.state == DeviceSosState.acknowledged;
    final deviceOriginatedPreConfirm = devicePreConfirm &&
        deviceStatus.triggerOrigin == DeviceSosTransitionSource.device;
    final appMirroredPreConfirm = devicePreConfirm &&
        deviceStatus.triggerOrigin == DeviceSosTransitionSource.app;

    if (!hasLocalSession && !devicePreConfirm) {
      return _activatePublicSos(payload);
    }

    if (appMirroredPreConfirm) {
      await confirmDeviceSos();
      _clearPreSosSession(
        reason: 'public_pre_sos_confirmed_app_mirror',
        emitIdleState: false,
      );
      return _activatePublicSos(
        payload,
        skipDeviceAction: true,
        deviceAlreadyActive: true,
      );
    }

    if (deviceOriginatedPreConfirm) {
      final confirmedStatus = await deviceSosController.confirmSos(
        commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
        commandRouteLabel: _currentDeviceCommandOwnerRoute,
      );
      await Future<void>.delayed(Duration.zero);
      _clearPreSosSession(
        reason: 'public_pre_sos_confirmed_device_originated',
        emitIdleState: false,
      );
      var incident = await getCurrentSosIncident();
      if (!_hasBackendVisibleSosIncident(incident)) {
        await _ensureBackendSosForDeviceOriginatedCycle(
          confirmedStatus,
          triggerSource: 'ble_device_runtime_confirm',
          message:
              'Device-originated SOS confirmed from the app and promoted to backend sync.',
        );
        incident = await getCurrentSosIncident();
      }
      if (_hasBackendVisibleSosIncident(incident)) {
        final decorated = incident!.copyWith(
          deliveryChannel: SosDeliveryChannel.backendAndDevice,
        );
        _recordPublicSosResult(
          incident: decorated,
          deliveryChannel: SosDeliveryChannel.backendAndDevice,
        );
        return decorated;
      }
      return _activatePublicSos(
        payload,
        skipDeviceAction: true,
        deviceAlreadyActive: true,
      );
    }

    if (hasLocalSession && session.mirroredOnDevice && deviceAlreadyActive) {
      _clearPreSosSession(
        reason: 'public_pre_sos_confirmed_after_device_auto_activation',
        emitIdleState: false,
      );
      return _activatePublicSos(
        payload,
        skipDeviceAction: true,
        deviceAlreadyActive: true,
      );
    }

    _clearPreSosSession(
      reason: 'public_pre_sos_confirmed_local_only',
      emitIdleState: false,
    );
    return _activatePublicSos(payload);
  }

  @override
  Future<SosIncident?> getCurrentSosIncident() async {
    if (_publicSosFallbackIncident != null) {
      return _publicSosFallbackIncident;
    }
    final deviceStatus = await deviceSosController.getStatus();
    await _rehydrateDeviceSosPublicState(
      trigger: 'getCurrentSosIncident',
      deviceStatus: deviceStatus,
      emitResolvedState: false,
    );
    final incident = _decorateIncidentWithPublicDeliveryChannel(
      await sosRepository.getCurrentIncident(),
    );
    final deviceDerivedIncident =
        _buildDeviceRuntimePublicSosIncident(deviceStatus);
    if (deviceDerivedIncident != null &&
        !_hasBackendVisibleSosIncident(incident)) {
      return deviceDerivedIncident;
    }
    return incident;
  }

  @override
  Future<SosIncident> cancelSos() async {
    _publicSosActionInFlight = true;
    try {
      final activeIncident = await sosRepository.getCurrentIncident();
      _rememberDeviceOriginatedClosureIntent(
        incident: activeIncident,
        intent: _SosClosureIntent.cancel,
      );
      final fallbackDeliveryChannel =
          _publicSosFallbackIncident?.deliveryChannel;
      final deviceSync = await _attemptPublicSosDeviceAction(
        action: 'cancel',
        shouldRun: _canCloseDeviceSosForPublicSos,
        operation: () => _closeDeviceSos(
          intent: _SosClosureIntent.cancel,
          syncBackendForDeviceOriginatedCycle: false,
        ),
        refreshRuntimeStatus: true,
      );

      SosIncident? backendIncident;
      Object? backendError;
      try {
        backendIncident = await sosRepository.cancelSos();
      } catch (error) {
        backendError = error;
        BleDebugRegistry.instance.recordEvent(
          'Public SOS backend cancel failed -> error=$error',
        );
      }

      final deliveryChannel = _resolveSuccessfulSosDeliveryChannel(
            backendSucceeded: backendIncident != null,
            deviceSucceeded: deviceSync.succeeded,
          ) ??
          (backendIncident == null &&
                  backendError != null &&
                  fallbackDeliveryChannel == SosDeliveryChannel.deviceOnly
              ? SosDeliveryChannel.deviceOnly
              : null);
      if (deliveryChannel == null) {
        if (backendError != null) {
          throw backendError;
        }
        throw const SosException(
          'E_SOS_CANCEL_NOT_ALLOWED',
          'There is no active SOS to cancel.',
        );
      }

      final incident = backendIncident != null
          ? backendIncident.copyWith(deliveryChannel: deliveryChannel)
          : await _updateFallbackPublicSosIncident(
              state: SosState.cancelled,
              deliveryChannel: deliveryChannel,
            );
      await _clearSosNotificationsSafely(reason: 'public_cancel_completed');
      _recordPublicSosResult(
        incident: incident,
        deliveryChannel: deliveryChannel,
        fallbackState: backendIncident == null ? SosState.cancelled : null,
      );
      _clearPendingAppTriggeredSosBridge(reason: 'public_cancel_completed');
      _publishCancelledSosEventIfNeeded(incident);
      return incident;
    } finally {
      _publicSosActionInFlight = false;
    }
  }

  @override
  Future<void> resolveSos() async {
    _publicSosActionInFlight = true;
    try {
      final activeIncident = await sosRepository.getCurrentIncident();
      _rememberDeviceOriginatedClosureIntent(
        incident: activeIncident,
        intent: _SosClosureIntent.resolve,
      );
      final deviceSync = await _attemptPublicSosDeviceAction(
        action: 'resolve',
        shouldRun: _canCloseDeviceSosForPublicSos,
        operation: () => _closeDeviceSos(
          intent: _SosClosureIntent.resolve,
          syncBackendForDeviceOriginatedCycle: false,
        ),
        refreshRuntimeStatus: true,
      );

      SosIncident? backendIncident;
      Object? backendError;
      try {
        backendIncident = await sosRepository.resolveSos();
      } catch (error) {
        backendError = error;
        BleDebugRegistry.instance.recordEvent(
          'Public SOS backend resolve failed -> error=$error',
        );
      }

      final deliveryChannel = _resolveSuccessfulSosDeliveryChannel(
        backendSucceeded: backendIncident != null,
        deviceSucceeded: deviceSync.succeeded,
      );
      if (deliveryChannel == null) {
        if (backendError != null) {
          throw backendError;
        }
        throw const SosException(
          'E_SOS_RESOLVE_NOT_ALLOWED',
          'There is no active SOS to resolve.',
        );
      }

      final incident = backendIncident != null
          ? backendIncident.copyWith(deliveryChannel: deliveryChannel)
          : await _updateFallbackPublicSosIncident(
              state: SosState.resolved,
              deliveryChannel: deliveryChannel,
            );
      await _clearSosNotificationsSafely(reason: 'public_resolve_completed');
      _recordPublicSosResult(
        incident: incident,
        deliveryChannel: deliveryChannel,
        fallbackState: backendIncident == null ? SosState.resolved : null,
      );
      _clearPendingAppTriggeredSosBridge(reason: 'public_resolve_completed');
    } finally {
      _publicSosActionInFlight = false;
    }
  }

  Future<TrackingPosition?> _loadPositionSnapshotForSos() async {
    try {
      return await trackingRepository.getCurrentPosition();
    } catch (_) {
      // Best-effort snapshot: SOS should continue even if location lookup fails.
    }
    return null;
  }

  Future<String?> _loadBackendHardwareIdForOperationalPayloads({
    DeviceStatus? runtimeStatus,
  }) async {
    try {
      final status = runtimeStatus ??
          _lastDeviceStatus ??
          await deviceRepository.getDeviceStatus();
      _lastDeviceStatus = status;
      if (!status.paired && !status.connected && !status.activated) {
        return null;
      }
      final hardwareId = status.canonicalHardwareId?.trim();
      return hardwareId == null || hardwareId.isEmpty ? null : hardwareId;
    } catch (_) {
      return null;
    }
  }

  SdkDeviceBatterySnapshot? _buildDeviceBatterySnapshot(
    DeviceStatus? status,
  ) {
    try {
      if (status == null) {
        return null;
      }
      final batteryState = status.effectiveBatteryState;
      if (batteryState != null) {
        return SdkDeviceBatterySnapshot.fromLevel(batteryState);
      }
      final batteryLevel = status.batteryLevel;
      if (batteryLevel == null) {
        return null;
      }
      return SdkDeviceBatterySnapshot.fromRawValue(batteryLevel);
    } catch (_) {
      return null;
    }
  }

  SdkCoverageSnapshot? _buildDeviceCoverageSnapshot(DeviceStatus? status) {
    try {
      final signalQuality = status?.signalQuality;
      if (status == null || signalQuality == null) {
        return null;
      }
      return SdkCoverageSnapshot(
        signalStrength: signalQuality,
        networkType: 'ble',
        isConnected: status.connected,
      );
    } catch (_) {
      return null;
    }
  }

  Future<SdkTelemetryPayload> _enrichOperationalTelemetryPayload(
    SdkTelemetryPayload payload,
  ) async {
    final session = _session;
    var status = _lastDeviceStatus;
    final backendHardwareId =
        await _loadBackendHardwareIdForOperationalPayloads(
      runtimeStatus: status,
    );
    status = _lastDeviceStatus;
    final resolvedDeviceId = _resolveOperationalDeviceId(
      backendHardwareId: backendHardwareId,
    );

    return payload.copyWith(
      userId: payload.userId ??
          session?.canonicalExternalUserId ??
          session?.externalUserId,
      deviceId: resolvedDeviceId,
      deviceBatterySnapshot:
          payload.deviceBatterySnapshot ?? _buildDeviceBatterySnapshot(status),
      deviceCoverageSnapshot: payload.deviceCoverageSnapshot ??
          _buildDeviceCoverageSnapshot(status),
    );
  }

  _OperationalSosMetadata _buildOperationalSosMetadata() {
    try {
      final status = _lastDeviceStatus;
      return _OperationalSosMetadata(
        deviceBattery: _buildDeviceBatterySnapshot(status),
        deviceCoverage: _buildDeviceCoverageSnapshot(status),
        mobileBattery: null,
        mobileCoverage: null,
      );
    } catch (_) {
      return const _OperationalSosMetadata(
        mobileBattery: null,
        mobileCoverage: null,
      );
    }
  }

  Future<String?> _resolveOperationalSosDeviceId(DeviceSosStatus status) async {
    final relayContext = _relayContextFrom(status);
    if (relayContext != null) {
      return relayContext.remoteDeviceId;
    }
    return _loadBackendHardwareIdForOperationalPayloads(
      runtimeStatus: _lastDeviceStatus,
    );
  }

  RelayIngestContext? _relayContextFrom(DeviceSosStatus status) {
    final relayCount = status.relayCount ?? 0;
    if (relayCount <= 0) {
      return null;
    }
    final signature = status.lastPacketSignature;
    if (signature == null) {
      return null;
    }
    final observed = _observedRelaySosBySignature[signature];
    if (observed == null) {
      return null;
    }
    return RelayIngestContext(
      kind: RelayIngestKind.sos,
      remoteDeviceId: observed.remoteDeviceId,
      gatewayRuntimeDeviceId: _lastDeviceStatus?.deviceId ?? 'unknown',
      gatewayCanonicalHardwareId: _lastDeviceStatus?.canonicalHardwareId,
      payloadSignature: observed.packetSignature,
      relayCount: observed.relayCount,
    );
  }

  Future<_PublicSosDeviceAttempt> _attemptPublicSosDeviceAction({
    required String action,
    required bool Function(DeviceSosStatus status) shouldRun,
    required Future<DeviceSosStatus> Function() operation,
    bool refreshRuntimeStatus = false,
  }) async {
    final runtimeStatus = await _loadRuntimeReadyDeviceStatusForSosSync(
      action: action,
      refreshRuntimeStatus: refreshRuntimeStatus,
    );
    if (runtimeStatus == null) {
      return const _PublicSosDeviceAttempt(
        available: false,
        attempted: false,
        succeeded: false,
      );
    }

    final deviceSosStatus = await deviceSosController.getStatus();
    if (!shouldRun(deviceSosStatus)) {
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync skipped -> action=$action reason=state_already_converged state=${deviceSosStatus.state.name} origin=${deviceSosStatus.triggerOrigin.name} deviceId=${runtimeStatus.deviceId}',
      );
      return const _PublicSosDeviceAttempt(
        available: true,
        attempted: false,
        succeeded: false,
      );
    }

    try {
      await operation();
      return const _PublicSosDeviceAttempt(
        available: true,
        attempted: true,
        succeeded: true,
      );
    } catch (error) {
      if (action == 'trigger') {
        _clearPreSosSession(
          reason: 'legacy_public_trigger_failed',
          emitIdleState: false,
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync failed -> action=$action error=$error deviceId=${runtimeStatus.deviceId}',
      );
      return const _PublicSosDeviceAttempt(
        available: true,
        attempted: true,
        succeeded: false,
      );
    }
  }

  Future<DeviceStatus?> _loadRuntimeReadyDeviceStatusForSosSync({
    required String action,
    bool refreshRuntimeStatus = false,
  }) async {
    try {
      if (refreshRuntimeStatus) {
        BleDebugRegistry.instance.recordEvent(
          'Public SOS device sync live re-evaluation -> action=$action reason=execution_time_channel_decision',
        );
      }
      final status = await _resolveDeviceStatusForCapability(
        trigger: 'public_sos_$action',
        refreshRuntimeStatus: refreshRuntimeStatus,
      );
      final capabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
        reason: 'public_sos_${action}_execution',
        statusOverride: status,
      );

      if (!capabilitySnapshot.deviceConnected) {
        BleDebugRegistry.instance.recordEvent(
          'Public SOS device sync skipped -> action=$action reason=device_not_connected lifecycle=${status.lifecycleState.name} flutterConnected=${status.connected} protectionConnected=${capabilitySnapshot.serviceBleConnected ?? false} protectionReady=${capabilitySnapshot.serviceBleReady ?? false} paired=${status.paired} activated=${status.activated}',
        );
        return null;
      }

      if (!capabilitySnapshot.hasSosCommandPath) {
        BleDebugRegistry.instance.recordEvent(
          'Public SOS device sync skipped -> action=$action reason=sos_command_path_unavailable deviceId=${status.deviceId} activeOwner=$_currentDeviceCommandOwnerRoute',
        );
        return null;
      }

      return status;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync skipped -> action=$action reason=runtime_status_unavailable error=$error',
      );
      return null;
    }
  }

  SosDeliveryChannel? _resolveSuccessfulSosDeliveryChannel({
    required bool backendSucceeded,
    required bool deviceSucceeded,
  }) {
    if (backendSucceeded && deviceSucceeded) {
      return SosDeliveryChannel.backendAndDevice;
    }
    if (backendSucceeded) {
      return SosDeliveryChannel.backendOnly;
    }
    if (deviceSucceeded) {
      return SosDeliveryChannel.deviceOnly;
    }
    return null;
  }

  SosIncident _createDeviceOnlyPublicSosIncident({
    required SosTriggerPayload payload,
    required TrackingPosition? positionSnapshot,
    required SosDeliveryChannel deliveryChannel,
  }) {
    return SosIncident(
      id: 'device-only-sos-${DateTime.now().microsecondsSinceEpoch}',
      state: SosState.sent,
      createdAt: DateTime.now().toUtc(),
      positionSnapshot: positionSnapshot,
      triggerSource: payload.triggerSource,
      message: payload.message,
      deliveryChannel: deliveryChannel,
    );
  }

  Future<SosIncident> _updateFallbackPublicSosIncident({
    required SosState state,
    required SosDeliveryChannel deliveryChannel,
  }) async {
    final fallback = _publicSosFallbackIncident ??
        _decorateIncidentWithPublicDeliveryChannel(
          await sosRepository.getCurrentIncident(),
        );
    if (fallback == null) {
      throw const SosException(
        'E_SOS_NOT_AVAILABLE',
        'SOS is unavailable because neither backend nor device channel can complete this request.',
      );
    }
    return fallback.copyWith(
      state: state,
      deliveryChannel: deliveryChannel,
    );
  }

  void _recordPublicSosResult({
    required SosIncident incident,
    required SosDeliveryChannel deliveryChannel,
    SosState? fallbackState,
  }) {
    _lastPublicSosIncidentId = incident.id;
    _lastPublicSosDeliveryChannel = deliveryChannel;
    if (fallbackState != null) {
      _publicSosFallbackIncident = incident;
      _emitPublicSosState(fallbackState);
    } else {
      _publicSosFallbackIncident = null;
      _emitPublicSosState(incident.state);
    }
    _emitOperationalDiagnostics();
  }

  void _registerPendingAppTriggeredSosBridge(SosIncident incident) {
    final now = DateTime.now();
    _pendingAppTriggeredSosBridge = _AppTriggeredSosBridge(
      incidentId: incident.id,
      deviceId: _lastDeviceStatus?.deviceId.trim(),
      createdAt: now,
      expiresAt: now.add(_appTriggeredSosBridgeWindow),
    );
    BleDebugRegistry.instance.recordEvent(
      'App-triggered SOS bridge registered -> incidentId=${incident.id} deviceId=${_lastDeviceStatus?.deviceId ?? "-"} expiresInMs=${_appTriggeredSosBridgeWindow.inMilliseconds}',
    );
  }

  void _consumePendingAppTriggeredSosBridge(DeviceSosStatus status) {
    final bridge = _pendingAppTriggeredSosBridge;
    if (bridge == null) {
      return;
    }
    final now = DateTime.now();
    if (now.isAfter(bridge.expiresAt)) {
      _clearPendingAppTriggeredSosBridge(reason: 'expired');
      return;
    }
    if (!_isSosCycleNotifiable(status.state)) {
      return;
    }
    final bridgeDeviceId = bridge.deviceId;
    final currentDeviceId = _lastDeviceStatus?.deviceId.trim();
    if (bridgeDeviceId != null &&
        bridgeDeviceId.isNotEmpty &&
        currentDeviceId != null &&
        currentDeviceId.isNotEmpty &&
        bridgeDeviceId != currentDeviceId) {
      return;
    }
    final bridgeNodeId = bridge.nodeId;
    final statusNodeId = status.nodeId;
    if (bridgeNodeId != null &&
        statusNodeId != null &&
        bridgeNodeId != statusNodeId) {
      return;
    }
    _pendingAppTriggeredSosBridge = bridge.copyWith(
      nodeId: statusNodeId ?? bridge.nodeId,
      matchedAt: now,
      expiresAt: now.add(_appTriggeredSosBridgeWindow),
    );
    if (statusNodeId != null) {
      _knownLocalDeviceNodeId = statusNodeId;
    }
    BleDebugRegistry.instance.recordEvent(
      'App-triggered SOS bridge refreshed -> incidentId=${bridge.incidentId} nodeId=${_formatNodeId(statusNodeId ?? bridge.nodeId)} state=${status.state.name}',
    );
  }

  bool _isCorrelatedAppTriggeredSosStatus(DeviceSosStatus status) {
    final bridge = _pendingAppTriggeredSosBridge;
    if (bridge == null) {
      return false;
    }
    final now = DateTime.now();
    if (now.isAfter(bridge.expiresAt)) {
      _clearPendingAppTriggeredSosBridge(reason: 'expired');
      return false;
    }
    if (status.triggerOrigin == DeviceSosTransitionSource.app) {
      return true;
    }
    if (!_isSosCycleNotifiable(status.state)) {
      return false;
    }
    final bridgeDeviceId = bridge.deviceId;
    final currentDeviceId = _lastDeviceStatus?.deviceId.trim();
    if (bridgeDeviceId != null &&
        bridgeDeviceId.isNotEmpty &&
        currentDeviceId != null &&
        currentDeviceId.isNotEmpty &&
        bridgeDeviceId != currentDeviceId) {
      return false;
    }
    final bridgeNodeId = bridge.nodeId;
    if (bridgeNodeId != null &&
        status.nodeId != null &&
        bridgeNodeId != status.nodeId) {
      return false;
    }
    return true;
  }

  void _clearPendingAppTriggeredSosBridge({
    required String reason,
  }) {
    final bridge = _pendingAppTriggeredSosBridge;
    if (bridge == null) {
      return;
    }
    _pendingAppTriggeredSosBridge = null;
    BleDebugRegistry.instance.recordEvent(
      'App-triggered SOS bridge cleared -> incidentId=${bridge.incidentId} reason=$reason matched=${bridge.matchedAt != null} nodeId=${_formatNodeId(bridge.nodeId)}',
    );
  }

  bool get _hasActivePreSosSession => _buildCurrentPreSosStatus() != null;

  void _syncPreSosSessionFromDeviceStatus(DeviceSosStatus status) {
    if (status.state != DeviceSosState.preConfirm) {
      return;
    }
    final startedAt = status.countdownStartedAt ?? DateTime.now();
    final expectedActivationAt = status.expectedActivationAt ??
        startedAt.add(const Duration(seconds: 20));
    _syncPreSosSession(
      startedAt: startedAt,
      expectedActivationAt: expectedActivationAt,
      mirroredOnDevice: true,
      origin: status.triggerOrigin == DeviceSosTransitionSource.unknown
          ? null
          : status.triggerOrigin,
    );
  }

  void _syncPreSosSession({
    required DateTime startedAt,
    required DateTime expectedActivationAt,
    required bool mirroredOnDevice,
    required DeviceSosTransitionSource? origin,
  }) {
    final session = _preSosSession;
    if (session == null) {
      _preSosSession = _PreSosSession(
        startedAt: startedAt,
        expectedActivationAt: expectedActivationAt,
        mirroredOnDevice: mirroredOnDevice,
        origin: origin,
        timer: Timer.periodic(_preSosTickInterval, (_) {
          unawaited(_handlePreSosTimerTick());
        }),
      );
    } else {
      _preSosSession = session.copyWith(
        startedAt: startedAt,
        expectedActivationAt: expectedActivationAt,
        mirroredOnDevice: mirroredOnDevice,
        origin: origin,
      );
    }
    _publishPreSosStatus(_buildCurrentPreSosStatus());
  }

  Future<void> _handlePreSosTimerTick() async {
    final session = _preSosSession;
    if (session == null) {
      return;
    }
    if (_isPreSosSessionExpired(session)) {
      if (session.origin == DeviceSosTransitionSource.device) {
        _clearPreSosSession(
          reason: 'device_pre_sos_countdown_expired',
          emitIdleState: false,
        );
      } else if (_pendingPreSosConfirmation == null) {
        await confirmPreSos(const SosTriggerPayload());
      }
      return;
    }
    final status = _buildCurrentPreSosStatus();
    _publishPreSosStatus(status);
    if (status == null ||
        status.remainingSeconds > 0 ||
        session.origin == DeviceSosTransitionSource.device ||
        _pendingPreSosConfirmation != null) {
      return;
    }
    await confirmPreSos(const SosTriggerPayload());
  }

  PublicPreSosStatus? _buildCurrentPreSosStatus() {
    final session = _preSosSession;
    if (session == null) {
      return null;
    }
    if (_isPreSosSessionExpired(session)) {
      return null;
    }
    final remainingSeconds = _computeRemainingSeconds(
      expectedActivationAt: session.expectedActivationAt,
    );
    return PublicPreSosStatus(
      active: true,
      startedAt: session.startedAt,
      expectedActivationAt: session.expectedActivationAt,
      remainingSeconds: remainingSeconds,
      mirroredOnDevice: session.mirroredOnDevice,
      origin: session.origin,
    );
  }

  int _computeRemainingSeconds({
    required DateTime expectedActivationAt,
  }) {
    final remaining = expectedActivationAt.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      return 0;
    }
    return remaining.inSeconds + (remaining.inMilliseconds % 1000 == 0 ? 0 : 1);
  }

  bool _isPreSosSessionExpired(_PreSosSession session) {
    return !DateTime.now().isBefore(session.expectedActivationAt);
  }

  void _publishPreSosStatus(PublicPreSosStatus? status) {
    if (!_publicPreSosStatusController.isClosed) {
      _publicPreSosStatusController.add(status);
    }
    if (status != null && _publicSosState != SosState.arming) {
      _emitPublicSosState(SosState.arming);
    }
  }

  Future<void> _clearSosNotificationsSafely({
    required String reason,
  }) async {
    try {
      await notificationsRepository.clearSosNotifications();
    } catch (error, stackTrace) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification cleanup failed -> reason=$reason error=$error',
      );
      debugPrint('SOS notification cleanup failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  void _clearPreSosSession({
    required String reason,
    required bool emitIdleState,
  }) {
    final session = _preSosSession;
    if (session == null) {
      if (emitIdleState) {
        _emitPublicSosState(SosState.idle);
      }
      return;
    }
    session.timer.cancel();
    _preSosSession = null;
    _publishPreSosStatus(null);
    BleDebugRegistry.instance.recordEvent(
      'Public PRE-SOS session cleared -> reason=$reason origin=${session.origin?.name ?? "-"} mirroredOnDevice=${session.mirroredOnDevice}',
    );
    if (emitIdleState) {
      _emitPublicSosState(SosState.idle);
    }
  }

  void _emitPublicSosState(SosState state) {
    _publicSosState = state;
    if (!_publicSosStateController.isClosed) {
      _publicSosStateController.add(state);
    }
    unawaited(
        _updateBackgroundTelemetryState(reason: 'sos_state:${state.name}'));
  }

  Future<void> _syncPublicSosStateFromRepository(SosState state) async {
    final deviceOverride = await _rehydrateDeviceSosPublicState(
      trigger: 'repository_stream:${state.name}',
      emitResolvedState: false,
    );
    if (deviceOverride != null) {
      _emitPublicSosState(deviceOverride);
      return;
    }
    if (_publicSosFallbackIncident != null || _publicSosActionInFlight) {
      return;
    }
    _emitPublicSosState(state);
  }

  Future<SosState?> _rehydrateDeviceSosPublicState({
    required String trigger,
    DeviceSosStatus? deviceStatus,
    required bool emitResolvedState,
  }) async {
    final status = deviceStatus ?? await deviceSosController.getStatus();
    final session = _preSosSession;
    final sessionExpired = session != null && _isPreSosSessionExpired(session);
    final deviceCountdownExpired = status.expectedActivationAt != null &&
        !DateTime.now().isBefore(status.expectedActivationAt!);
    SosState? chosenPublicState;

    if (session != null &&
        !sessionExpired &&
        !session.mirroredOnDevice &&
        !status.derivedFromBlePacket) {
      chosenPublicState = SosState.arming;
    } else if (status.state == DeviceSosState.preConfirm &&
        !deviceCountdownExpired) {
      _syncPreSosSessionFromDeviceStatus(status);
      chosenPublicState = SosState.arming;
    } else {
      if (session != null &&
          (session.mirroredOnDevice || status.derivedFromBlePacket) &&
          (status.state != DeviceSosState.preConfirm || sessionExpired)) {
        _clearPreSosSession(
          reason: 'device_rehydrate:${status.state.name}',
          emitIdleState: false,
        );
      }
      chosenPublicState = status.state == DeviceSosState.preConfirm
          ? SosState.sent
          : _mapDeviceStatusToPublicSosState(status);
    }

    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_SOS_REHYDRATE] trigger=$trigger device=${status.state.name} previous=${status.previousState?.name ?? "-"} origin=${status.triggerOrigin.name} remaining=${status.countdownRemainingSeconds?.toString() ?? "-"} expectedActivationAt=${status.expectedActivationAt?.toIso8601String() ?? "-"} sessionExpired=$sessionExpired deviceCountdownExpired=$deviceCountdownExpired chosen=${chosenPublicState?.name ?? "-"}',
    );

    if (emitResolvedState && chosenPublicState != null) {
      _emitPublicSosState(chosenPublicState);
    }

    return chosenPublicState;
  }

  SosState? _mapDeviceStatusToPublicSosState(DeviceSosStatus status) {
    final terminalState = _mapTerminalDeviceStatusToPublicSosState(status);
    if (terminalState != null) {
      return terminalState;
    }
    return switch (status.state) {
      DeviceSosState.preConfirm => SosState.arming,
      DeviceSosState.active => SosState.sent,
      DeviceSosState.acknowledged => SosState.acknowledged,
      DeviceSosState.inactive ||
      DeviceSosState.resolved ||
      DeviceSosState.unknown =>
        null,
    };
  }

  SosState? _mapTerminalDeviceStatusToPublicSosState(DeviceSosStatus status) {
    if (status.state != DeviceSosState.inactive &&
        status.state != DeviceSosState.resolved) {
      return null;
    }
    if (!_isBleTerminalSosEventStatus(status)) {
      return null;
    }
    if (status.triggerOrigin == DeviceSosTransitionSource.app &&
        status.previousState == DeviceSosState.preConfirm) {
      return null;
    }
    final eventBytes = _parseHexBytes(status.lastPacketHex);
    if (eventBytes == null || eventBytes.length < 2) {
      return status.state == DeviceSosState.resolved
          ? SosState.resolved
          : SosState.cancelled;
    }
    final opcode = eventBytes[0];
    final subcode = eventBytes[1];
    if (opcode == EixamBleProtocol.sosEventUserDeactivatedOpcode) {
      return subcode == 0x02 ? SosState.resolved : SosState.cancelled;
    }
    if (opcode == EixamBleProtocol.sosEventAppCancelAckOpcode) {
      return subcode == 0x02 || subcode == 0x03
          ? SosState.resolved
          : SosState.cancelled;
    }
    return status.state == DeviceSosState.resolved
        ? SosState.resolved
        : SosState.cancelled;
  }

  bool _isBleTerminalSosEventStatus(DeviceSosStatus status) {
    if (!status.derivedFromBlePacket) {
      return false;
    }
    final opcode = status.lastOpcode;
    if (opcode == EixamBleProtocol.sosEventUserDeactivatedOpcode ||
        opcode == EixamBleProtocol.sosEventAppCancelAckOpcode) {
      return true;
    }
    final eventBytes = _parseHexBytes(status.lastPacketHex);
    if (eventBytes == null || eventBytes.isEmpty) {
      return false;
    }
    return eventBytes.first == EixamBleProtocol.sosEventUserDeactivatedOpcode ||
        eventBytes.first == EixamBleProtocol.sosEventAppCancelAckOpcode;
  }

  List<int>? _parseHexBytes(String? hex) {
    if (hex == null) {
      return null;
    }
    final normalized = hex.replaceAll(RegExp(r'\s+'), '');
    if (normalized.isEmpty || normalized.length.isOdd) {
      return null;
    }
    final bytes = <int>[];
    for (var i = 0; i < normalized.length; i += 2) {
      final value = int.tryParse(normalized.substring(i, i + 2), radix: 16);
      if (value == null) {
        return null;
      }
      bytes.add(value);
    }
    return bytes;
  }

  SosIncident? _buildDeviceRuntimePublicSosIncident(DeviceSosStatus status) {
    final deviceCountdownExpired = status.expectedActivationAt != null &&
        !DateTime.now().isBefore(status.expectedActivationAt!);
    final publicState =
        status.state == DeviceSosState.preConfirm && deviceCountdownExpired
            ? SosState.sent
            : _mapDeviceStatusToPublicSosState(status);
    if (publicState == null || publicState == SosState.arming) {
      return null;
    }
    final cycleKey = _deriveDeviceSosCycleKey(status) ??
        status.lastPacketSignature ??
        'device-runtime-${status.updatedAt.microsecondsSinceEpoch}';
    return SosIncident(
      id: 'device-runtime-$cycleKey',
      state: publicState,
      createdAt: (status.countdownStartedAt ?? status.updatedAt).toUtc(),
      triggerSource: 'ble_device_runtime_status',
      deliveryChannel: SosDeliveryChannel.deviceOnly,
    );
  }

  SosIncident? _decorateIncidentWithPublicDeliveryChannel(
      SosIncident? incident) {
    if (incident == null) {
      return null;
    }
    if (_lastPublicSosIncidentId != null &&
        incident.id == _lastPublicSosIncidentId &&
        _lastPublicSosDeliveryChannel != null) {
      return incident.copyWith(
        deliveryChannel: _lastPublicSosDeliveryChannel,
      );
    }
    return incident;
  }

  bool _isBackendUnavailableForTrigger(Object? error) {
    if (error is NetworkException) {
      return true;
    }
    if (error is! EixamSdkException) {
      return false;
    }
    return error.code == 'E_MQTT_NOT_CONNECTED' ||
        error.code == 'E_SOS_POSITION_REQUIRED' ||
        error.code == 'E_SOS_TRIGGER_FAILED' ||
        error.code == 'E_HTTP_SOS_TRIGGER_MISSING_SESSION';
  }

  Never _throwTriggerSosFailure({
    required Object? backendError,
    required bool backendUnavailable,
    required bool deviceAvailable,
  }) {
    if (backendUnavailable && !deviceAvailable) {
      throw const SosException(
        'E_SOS_NOT_AVAILABLE',
        'SOS is unavailable because neither backend nor device channel is currently available.',
      );
    }
    if (backendError != null) {
      throw backendError;
    }
    throw const SosException(
      'E_SOS_NOT_AVAILABLE',
      'SOS is unavailable because neither backend nor device channel is currently available.',
    );
  }

  bool _hasSignedSessionIdentityReadyForDeviceRegistrySync() {
    final session = _session;
    if (session == null) {
      return false;
    }
    final canonicalUserId =
        (session.canonicalExternalUserId ?? session.externalUserId).trim();
    return session.appId.trim().isNotEmpty &&
        canonicalUserId.isNotEmpty &&
        session.userHash.trim().isNotEmpty;
  }

  bool _isRegisteredDeviceAutoSyncEligible(DeviceStatus status) {
    return status.paired && status.connected;
  }

  void _scheduleRegisteredDeviceAutoSync({
    required String trigger,
    DeviceStatus? status,
  }) {
    unawaited(
      _maybeAutoSyncRegisteredDevice(
        trigger: trigger,
        runtimeStatus: status,
      ),
    );
  }

  Future<void> _maybeAutoSyncRegisteredDevice({
    required String trigger,
    DeviceStatus? runtimeStatus,
  }) async {
    if (_registeredDeviceAutoSyncInFlight) {
      return;
    }
    final status = runtimeStatus ??
        _lastDeviceStatus ??
        await deviceRepository.getDeviceStatus();
    if (!_isRegisteredDeviceAutoSyncEligible(status) ||
        !_hasSignedSessionIdentityReadyForDeviceRegistrySync()) {
      return;
    }

    final hardwareId = status.canonicalHardwareId?.trim();
    if (hardwareId == null || hardwareId.isEmpty) {
      BleDebugRegistry.instance.recordEvent(
        'Registered device auto-sync skipped -> reason=missing_canonical_hardware_id trigger=$trigger runtimeDeviceId=${status.deviceId}',
      );
      return;
    }

    BackendRegisteredDevice? existingDevice;
    try {
      final devices = await deviceRegistryRepository.listRegisteredDevices();
      for (final device in devices) {
        if (device.hardwareId.trim() == hardwareId) {
          existingDevice = device;
          break;
        }
      }
    } catch (_) {
      existingDevice = null;
    }

    final firmwareVersion = (status.firmwareVersion?.trim().isNotEmpty == true)
        ? status.firmwareVersion!.trim()
        : existingDevice?.firmwareVersion ?? '';
    final hardwareModel = (status.model?.trim().isNotEmpty == true)
        ? status.model!.trim()
        : existingDevice?.hardwareModel ?? '';
    final session = _session!;
    final canonicalUserId =
        (session.canonicalExternalUserId ?? session.externalUserId).trim();
    final fingerprint =
        '$hardwareId|$firmwareVersion|$hardwareModel|${session.appId.trim()}|$canonicalUserId';
    if (_lastRegisteredDeviceAutoSyncFingerprint == fingerprint) {
      return;
    }

    _registeredDeviceAutoSyncInFlight = true;
    try {
      await deviceRegistryRepository.upsertRegisteredDevice(
        hardwareId: hardwareId,
        firmwareVersion: firmwareVersion,
        hardwareModel: hardwareModel,
        pairedAt: DateTime.now().toUtc(),
      );
      _lastRegisteredDeviceAutoSyncFingerprint = fingerprint;
      BleDebugRegistry.instance.recordEvent(
        'Registered device auto-sync succeeded -> trigger=$trigger hardwareId=$hardwareId',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Registered device auto-sync failed -> trigger=$trigger hardwareId=$hardwareId error=$error',
      );
    } finally {
      _registeredDeviceAutoSyncInFlight = false;
    }
  }

  String? _resolveOperationalDeviceId({
    required String? backendHardwareId,
  }) {
    if (backendHardwareId == null || backendHardwareId.trim().isEmpty) {
      return null;
    }
    return backendHardwareId;
  }

  Future<void> _ensureBackendSosForDeviceOriginatedCycle(
    DeviceSosStatus status, {
    required String triggerSource,
    required String message,
  }) async {
    if (status.triggerOrigin != DeviceSosTransitionSource.device ||
        !_isBackendSyncRelevantDeviceSosState(status.state)) {
      return;
    }

    final cycleKey = _deriveDeviceSosCycleKey(status) ??
        'device-runtime:${status.lastPacketSignature ?? status.state.name}';
    if (!_deviceOriginatedBackendSyncInFlight.add(cycleKey)) {
      BleDebugRegistry.instance.recordEvent(
        'Device SOS backend sync skipped -> reason=sync_in_flight cycle=$cycleKey triggerSource=$triggerSource',
      );
      return;
    }

    try {
      final incident = await sosRepository.getCurrentIncident();
      if (_hasBackendVisibleSosIncident(incident)) {
        BleDebugRegistry.instance.recordEvent(
          'Device SOS backend sync skipped -> reason=incident_already_active state=${incident!.state.name}',
        );
        return;
      }

      final positionSnapshot = await _loadPositionSnapshotForSos();
      if (positionSnapshot == null) {
        BleDebugRegistry.instance.recordEvent(
          'Device SOS backend sync skipped -> reason=missing_position_snapshot triggerSource=$triggerSource',
        );
        return;
      }

      final created =
          await _bleOperationalRuntimeBridge.promoteDeviceOriginatedSos(
        signature: 'device_sos:$cycleKey:$triggerSource',
        triggerSource: triggerSource,
        message: message,
        positionSnapshot: positionSnapshot,
        deviceId: await _resolveOperationalSosDeviceId(status),
        relayContext: _relayContextFrom(status),
        summary:
            'device_runtime state=${status.state.name} origin=${status.triggerOrigin.name} cycle=$cycleKey',
      );
      if (created) {
        final createdIncident = await sosRepository.getCurrentIncident();
        if (createdIncident != null) {
          _publishSdkEvent(SOSTriggeredEvent(createdIncident.id));
          BleDebugRegistry.instance.recordEvent(
            'Device SOS backend sync created incident -> incidentId=${createdIncident.id} triggerSource=$triggerSource',
          );
        }
      }
    } finally {
      _deviceOriginatedBackendSyncInFlight.remove(cycleKey);
    }
  }

  Future<void> _applyBackendClosureForDeviceOriginatedCycle(
    DeviceSosStatus status, {
    _SosClosureIntent? fallbackIntent,
    SosIncident? currentIncident,
  }) async {
    if (status.triggerOrigin != DeviceSosTransitionSource.device ||
        !_isDeviceSosCycleClosed(status.state)) {
      return;
    }

    final cycleKey = _deviceOriginatedClosureCycleKeyFor(status);
    final incident =
        currentIncident ?? await sosRepository.getCurrentIncident();
    final rememberedIntent = incident == null
        ? _lookupRememberedDeviceOriginatedClosureIntent(cycleKey: cycleKey)
        : _lookupRememberedDeviceOriginatedClosureIntent(
            incident: incident,
            cycleKey: cycleKey,
          );
    if (_isTerminalBackendSosIncident(incident)) {
      _recordLateAutomaticClosureSkippedForTerminalIncident(
        incident: incident!,
        cycleKey: cycleKey,
      );
      BleDebugRegistry.instance.recordEvent(
        'Device SOS backend closure skipped because incident already terminal -> '
        'incidentId=${incident.id} state=${incident.state.name} cycleKey=${cycleKey ?? "-"}',
      );
      return;
    }

    if (!_hasBackendVisibleSosIncident(incident)) {
      _clearRememberedDeviceOriginatedClosureIntent(
        incidentId: incident?.id,
        cycleKey: cycleKey,
      );
      BleDebugRegistry.instance.recordEvent(
        'Device SOS backend closure skipped -> reason=no_active_backend_incident',
      );
      return;
    }

    if (_publicSosActionInFlight && rememberedIntent != null) {
      BleDebugRegistry.instance.recordEvent(
        'Device SOS backend closure deferred -> incidentId=${incident?.id ?? "-"} intent=${rememberedIntent.name} reason=public_sos_action_in_flight',
      );
      return;
    }

    final intent =
        rememberedIntent ?? fallbackIntent ?? _SosClosureIntent.cancel;
    late final SosIncident terminalIncident;
    switch (intent) {
      case _SosClosureIntent.cancel:
        terminalIncident = await sosRepository.cancelSos();
        _publishCancelledSosEventIfNeeded(terminalIncident);
        break;
      case _SosClosureIntent.resolve:
        terminalIncident = await sosRepository.resolveSos();
        break;
    }
    BleDebugRegistry.instance.recordEvent(
      'Device SOS backend ${intent.name} applied -> '
      'incidentId=${terminalIncident.id}',
    );
  }

  void _rememberDeviceOriginatedClosureIntent({
    required SosIncident? incident,
    required _SosClosureIntent intent,
  }) {
    if (!_hasBackendVisibleSosIncident(incident) || incident == null) {
      return;
    }
    final cycleKey = _activeDeviceSosCycleKey;
    if (cycleKey != null && cycleKey.isNotEmpty) {
      _deviceOriginatedClosureIntentByCycleKey[cycleKey] = intent;
    }
    _deviceOriginatedClosureIntentByIncidentId[incident.id] = intent;
    BleDebugRegistry.instance.recordEvent(
      'Device SOS explicit ${intent.name} intent recorded for cycle -> '
      'incidentId=${incident.id} cycleKey=${cycleKey ?? "-"}',
    );
  }

  _SosClosureIntent? _lookupRememberedDeviceOriginatedClosureIntent({
    SosIncident? incident,
    String? cycleKey,
  }) {
    if (cycleKey != null && cycleKey.isNotEmpty) {
      final cycleIntent = _deviceOriginatedClosureIntentByCycleKey[cycleKey];
      if (cycleIntent != null) {
        return cycleIntent;
      }
    }
    if (incident == null) {
      return null;
    }
    return _deviceOriginatedClosureIntentByIncidentId[incident.id];
  }

  void _clearRememberedDeviceOriginatedClosureIntent({
    String? incidentId,
    String? cycleKey,
  }) {
    if (incidentId == null && cycleKey == null) {
      return;
    }
    if (incidentId != null) {
      _deviceOriginatedClosureIntentByIncidentId.remove(incidentId);
    }
    if (cycleKey != null && cycleKey.isNotEmpty) {
      _deviceOriginatedClosureIntentByCycleKey.remove(cycleKey);
    }
  }

  bool _isBackendSyncRelevantDeviceSosState(DeviceSosState state) {
    return state == DeviceSosState.active ||
        state == DeviceSosState.acknowledged;
  }

  bool _canTriggerDeviceSosForPublicSos(DeviceSosStatus status) {
    return status.state == DeviceSosState.inactive ||
        status.state == DeviceSosState.resolved ||
        status.state == DeviceSosState.unknown;
  }

  bool _canCloseDeviceSosForPublicSos(DeviceSosStatus status) {
    return status.state == DeviceSosState.preConfirm ||
        status.state == DeviceSosState.active ||
        status.state == DeviceSosState.acknowledged;
  }

  bool _isDeviceSosCycleClosed(DeviceSosState state) {
    return state == DeviceSosState.inactive || state == DeviceSosState.resolved;
  }

  bool _hasBackendVisibleSosIncident(SosIncident? incident) {
    if (incident == null) {
      return false;
    }
    return incident.state != SosState.idle &&
        incident.state != SosState.cancelled &&
        incident.state != SosState.resolved &&
        incident.state != SosState.failed;
  }

  bool _isTerminalBackendSosIncident(SosIncident? incident) {
    if (incident == null) {
      return false;
    }
    return incident.state == SosState.resolved ||
        incident.state == SosState.cancelled;
  }

  String? _deviceOriginatedClosureCycleKeyFor(DeviceSosStatus status) {
    return _activeDeviceSosCycleKey ?? _deriveDeviceSosCycleKey(status);
  }

  void _recordLateAutomaticClosureSkippedForTerminalIncident({
    required SosIncident incident,
    required String? cycleKey,
  }) {
    if (!_isTerminalBackendSosIncident(incident)) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'Device SOS late automatic closure skipped because cycle already terminal=${incident.state.name} -> '
      'incidentId=${incident.id} cycleKey=${cycleKey ?? "-"}',
    );
  }

  Future<void> _synchronizeDeviceOriginatedBackendLifecycle(
    DeviceSosStatus status,
  ) async {
    if (status.triggerOrigin != DeviceSosTransitionSource.device) {
      return;
    }

    if (_isBackendSyncRelevantDeviceSosState(status.state)) {
      await _ensureBackendSosForDeviceOriginatedCycle(
        status,
        triggerSource: 'ble_device_runtime_status',
        message:
            'Device-originated SOS became active in runtime and was promoted to backend sync.',
      );
      return;
    }

    if (_isDeviceSosCycleClosed(status.state)) {
      final incident = await sosRepository.getCurrentIncident();
      final cycleKey = _deviceOriginatedClosureCycleKeyFor(status);
      if (_isTerminalBackendSosIncident(incident)) {
        _recordLateAutomaticClosureSkippedForTerminalIncident(
          incident: incident!,
          cycleKey: cycleKey,
        );
        BleDebugRegistry.instance.recordEvent(
          'Device SOS backend closure skipped because incident already terminal -> '
          'incidentId=${incident.id} state=${incident.state.name} cycleKey=${cycleKey ?? "-"}',
        );
        return;
      }
      await _applyBackendClosureForDeviceOriginatedCycle(
        status,
        currentIncident: incident,
      );
    }
  }

  void _publishCancelledSosEventIfNeeded(SosIncident incident) {
    if (incident.state == SosState.cancelled) {
      _pendingCancelledIncidentId = null;
      _publishSdkEvent(SOSCancelledEvent(incident.id));
    } else {
      _pendingCancelledIncidentId = incident.id;
    }
  }

  @override
  Future<SosState> getSosState() async {
    BleDebugRegistry.instance.recordEvent(
      'getSosState() -> passive diagnostics snapshot requested; live refresh skipped',
    );
    await _refreshOperationalDiagnostics(
      trigger: 'getSosState',
      refreshRuntimeStatus: false,
      emit: false,
    );
    final deviceSosStatus = await deviceSosController.getStatus();
    final deviceOverride = await _rehydrateDeviceSosPublicState(
      trigger: 'getSosState',
      deviceStatus: deviceSosStatus,
      emitResolvedState: false,
    );
    if (deviceOverride != null) {
      _publicSosState = deviceOverride;
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> deviceOverride=${deviceOverride.name}',
      );
      return deviceOverride;
    }
    if (_publicSosFallbackIncident != null) {
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> fallbackState=${_publicSosState.name}',
      );
      return _publicSosState;
    }
    final repositoryState = await sosRepository.getSosState();
    _publicSosState = repositoryState;
    BleDebugRegistry.instance.recordEvent(
      'getSosState() -> repositoryState=${repositoryState.name}',
    );
    return repositoryState;
  }

  @override
  Stream<SosState> get currentSosStateStream async* {
    yield await getSosState();
    yield* _publicSosStateController.stream;
  }

  @override
  Stream<EixamSdkEvent> get lastSosEventStream async* {
    final current = _lastSosEvent;
    if (current != null) {
      yield current;
    }
    yield* _eventsController.stream.where(_isSosSdkEvent);
  }

  @override
  Stream<SosState> watchSosState() {
    return _publicSosStateController.stream;
  }

  @override
  Future<List<BackendRegisteredDevice>> listRegisteredDevices() {
    return deviceRegistryRepository.listRegisteredDevices();
  }

  @override
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) {
    return deviceRegistryRepository.upsertRegisteredDevice(
      hardwareId: hardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
    );
  }

  @override
  Future<void> deleteRegisteredDevice(String deviceId) {
    return deviceRegistryRepository.removeRegisteredDevice(deviceId);
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
  Future<EmergencyContact> createEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
  }) {
    return addEmergencyContact(
      name: name,
      phone: phone,
      email: email,
      priority: priority,
    );
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
  Future<void> deleteEmergencyContact(String contactId) {
    return removeEmergencyContact(contactId);
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
    _publishSdkEvent(DeathManScheduledEvent(plan.id));
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
    _publishSdkEvent(
      DeathManStatusChangedEvent(planId, DeathManStatus.confirmedSafe.name),
    );
    _stopDeathManMonitoring();
  }

  @override
  Future<void> cancelDeathMan(String planId) async {
    await deathManRepository.cancelDeathMan(planId);
    _publishSdkEvent(
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
  Future<SdkOperationalDiagnostics> getOperationalDiagnostics() async {
    BleDebugRegistry.instance.recordEvent(
      'getOperationalDiagnostics() -> passive diagnostics snapshot requested; live refresh skipped',
    );
    return _refreshOperationalDiagnostics(
      trigger: 'getOperationalDiagnostics',
      refreshRuntimeStatus: false,
      emit: false,
    );
  }

  @override
  Stream<SdkOperationalDiagnostics> watchOperationalDiagnostics() async* {
    BleDebugRegistry.instance.recordEvent(
      'watchOperationalDiagnostics.initial -> passive diagnostics snapshot requested; live refresh skipped',
    );
    yield await _refreshOperationalDiagnostics(
      trigger: 'watchOperationalDiagnostics.initial',
      refreshRuntimeStatus: false,
      emit: false,
    );
    yield* _operationalDiagnosticsController.stream;
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
    _scheduleRegisteredDeviceAutoSync(
      trigger: 'cache_device_status',
      status: status,
    );
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

  bool get _isProtectionPlatformOwningBle {
    final status = _protectionModeController.currentStatus;
    return status.modeState != ProtectionModeState.off &&
        status.bleOwner != ProtectionBleOwner.flutter;
  }

  String get _currentDeviceCommandOwnerRoute =>
      _isProtectionPlatformOwningBle ? 'native_protection' : 'flutter_writer';

  Future<void> _sendDeviceCommandThroughActiveOwner(
    EixamDeviceCommand command,
  ) async {
    final ownerRoute = _currentDeviceCommandOwnerRoute;
    BleDebugRegistry.instance.recordEvent(
      'Device leg owner chosen -> owner=$ownerRoute command=${command.label}',
    );
    if (_isProtectionPlatformOwningBle) {
      final result = await protectionPlatformAdapter.sendProtectionCommand(
        request: ProtectionPlatformCommandRequest(
          label: command.label,
          bytes: command.encode(),
          forceCmdCharacteristic: command.usesCmdCharacteristic,
        ),
      );
      await _protectionModeController.rehydrate();
      if (!result.success) {
        BleDebugRegistry.instance.recordEvent(
          'Native owner command rejected -> owner=$ownerRoute command=${command.label} route=${result.route ?? "-"} error=${result.error ?? result.result ?? "-"}',
        );
        throw StateError(
          result.error ??
              'Protection Mode native BLE owner could not send ${command.label}.',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'Native owner command accepted -> owner=$ownerRoute command=${command.label} route=${result.route ?? "-"} result=${result.result ?? "-"}',
      );
      return;
    }

    if (!deviceSosController.hasSosCommandPath) {
      BleDebugRegistry.instance.recordEvent(
        'Flutter writer command rejected -> owner=$ownerRoute command=${command.label} reason=writer_unavailable',
      );
      throw StateError(
        'Flutter BLE command writer is not ready for ${command.label}.',
      );
    }

    try {
      await deviceSosController.sendAttachedCommand(command);
      BleDebugRegistry.instance.recordEvent(
        'Flutter writer command accepted -> owner=$ownerRoute command=${command.label}',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Flutter writer command rejected -> owner=$ownerRoute command=${command.label} error=$error',
      );
      rethrow;
    }
  }

  Future<void> _handleProtectionBleOwnershipChanged(
    ProtectionBleOwner owner,
  ) async {
    if (deviceRepository is! InMemoryDeviceRepository) {
      return;
    }
    final repository = deviceRepository as InMemoryDeviceRepository;
    if (owner != ProtectionBleOwner.flutter) {
      await repository.releaseBleOwnershipToProtectionMode(
        reason: 'Protection Mode native runtime is armed',
      );
      _bleAutoReconnectCoordinator.setAppForeground(false);
      return;
    }
    await repository.reclaimBleOwnershipFromProtectionMode(
      reason: 'Protection Mode returned BLE ownership to Flutter',
    );
    _bleAutoReconnectCoordinator.setAppForeground(true);
  }

  void _handleProtectionPlatformSosEvent(ProtectionPlatformEvent event) {
    if (event.type != ProtectionPlatformEventType.sosEventReceived ||
        !_isProtectionPlatformOwningBle) {
      return;
    }
    final rawHex = event.reason?.trim();
    if (rawHex == null || rawHex.isEmpty) {
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload ignored -> reason=missing_hex_payload',
      );
      return;
    }
    final bytes = _tryDecodeHexPayload(rawHex);
    if (bytes == null || bytes.isEmpty) {
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload ignored -> reason=invalid_hex_payload payload=$rawHex',
      );
      return;
    }

    final sosEventPacket = EixamSosEventPacket.tryParse(bytes);
    if (sosEventPacket != null) {
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload forwarded -> type=sosDeviceEvent payload=${sosEventPacket.rawHex}',
      );
      deviceSosController.handleIncomingSosEventPacket(
        sosEventPacket,
        source: DeviceSosTransitionSource.device,
      );
      return;
    }

    final sosPacket = EixamSosPacket.tryParse(bytes);
    if (sosPacket != null) {
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload forwarded -> type=sosMeshPacket payload=${sosPacket.rawHex}',
      );
      deviceSosController.handleIncomingSosPacket(
        sosPacket,
        source: DeviceSosTransitionSource.device,
      );
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      'Protection SOS payload ignored -> reason=unrecognized_payload payload=$rawHex len=${bytes.length}',
    );
  }

  List<int>? _tryDecodeHexPayload(String rawHex) {
    final normalized = rawHex.replaceAll(RegExp(r'\s+'), '');
    if (normalized.length.isOdd) {
      return null;
    }
    final bytes = <int>[];
    for (var index = 0; index < normalized.length; index += 2) {
      final value = int.tryParse(
        normalized.substring(index, index + 2),
        radix: 16,
      );
      if (value == null) {
        return null;
      }
      bytes.add(value);
    }
    return bytes;
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
        _publishSdkEvent(
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
        _publishSdkEvent(
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
      _publishSdkEvent(DeathManEscalatedEvent(plan.id));
      await _notifyDeathMan(
        'Protocol escalated',
        'No response was received. Automatic escalation has been triggered.',
        planId: plan.id,
      );
      if (plan.autoTriggerSos) {
        await triggerSos(
          const SosTriggerPayload(
            message: 'Auto-triggered by Death Man Protocol',
            triggerSource: 'death_man_protocol',
          ),
        );
      }
      await deathManRepository.updatePlanStatus(
        plan.id,
        DeathManStatus.expired,
      );
      _publishSdkEvent(
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

  Future<void> _handleRemoteRelaySosBackendHandoff(
    RemoteRelaySosSnapshot snapshot,
  ) async {
    if (snapshot.kind != RemoteRelaySosKind.sos) {
      if (_isRemoteRelayCancelSnapshot(snapshot)) {
        await _handleRemoteRelaySosCancelBackendHandoff(snapshot);
      }
      return;
    }

    final signature = _remoteRelaySosBackendHandoffSignature(snapshot);
    final now = DateTime.now().toUtc();
    _remoteRelaySosBackendHandoffBySignature.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(minutes: 5),
    );
    if (_remoteRelaySosBackendHandoffBySignature.containsKey(signature)) {
      return;
    }
    _remoteRelaySosBackendHandoffBySignature[signature] = now;

    final location = snapshot.location;
    if (!_hasValidRemoteRelayLocation(location)) {
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] backend_handoff_skipped '
        'reason=missing_remote_position '
        'originatorNodeId=${snapshot.originatorNodeId}',
      );
      _publishSdkEvent(
        RemoteRelaySosBackendHandoffResultEvent(
          snapshot: snapshot,
          status: RemoteRelaySosBackendHandoffStatus.skipped,
          reason: 'missing_remote_position',
        ),
      );
      return;
    }

    final deviceId = snapshot.originatorNodeId.toString();
    final positionSnapshot = _remoteRelayBackendPosition(
      location: location!,
      receivedAt: snapshot.receivedAt,
    );
    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS] backend_handoff_start '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'deviceId=$deviceId',
    );

    try {
      await _submitRemoteRelaySosToBackend(
        snapshot: snapshot,
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
      );
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] backend_handoff_success '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'deviceId=$deviceId',
      );

      var ackRelaySent = false;
      String? ackRelayErrorMessage;
      try {
        await deviceSosController.sendAckRelay(
          nodeId: snapshot.originatorNodeId,
        );
        ackRelaySent = true;
        BleDebugRegistry.instance.recordEvent(
          '[REMOTE_RELAY_SOS] ack_relay_sent '
          'originatorNodeId=${snapshot.originatorNodeId}',
        );
      } catch (error) {
        ackRelayErrorMessage = error.toString();
        BleDebugRegistry.instance.recordEvent(
          '[REMOTE_RELAY_SOS] ack_relay_failed '
          'originatorNodeId=${snapshot.originatorNodeId} '
          'error=$error',
        );
      }

      _publishSdkEvent(
        RemoteRelaySosBackendHandoffResultEvent(
          snapshot: snapshot,
          status: RemoteRelaySosBackendHandoffStatus.submitted,
          ackRelaySent: ackRelaySent,
          ackRelayErrorMessage: ackRelayErrorMessage,
        ),
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] backend_handoff_failed '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'error=$error',
      );
      _publishSdkEvent(
        RemoteRelaySosBackendHandoffResultEvent(
          snapshot: snapshot,
          status: RemoteRelaySosBackendHandoffStatus.failed,
          errorMessage: error.toString(),
        ),
      );
    }
  }

  bool _isRemoteRelayCancelSnapshot(RemoteRelaySosSnapshot snapshot) {
    return snapshot.kind == RemoteRelaySosKind.cancel ||
        snapshot.kind == RemoteRelaySosKind.clear;
  }

  Future<void> _handleRemoteRelaySosCancelBackendHandoff(
    RemoteRelaySosSnapshot snapshot,
  ) async {
    final deviceId = snapshot.originatorNodeId.toString();
    if (deviceId.trim().isEmpty) {
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] remote_cancel_handoff_skipped '
        'reason=missing_device_id '
        'originatorNodeId=${snapshot.originatorNodeId}',
      );
      _publishRemoteRelaySosCancelHandoffResult(
        snapshot: snapshot,
        deviceId: deviceId,
        status: RemoteRelaySosBackendHandoffStatus.skipped,
        reason: 'missing_device_id',
      );
      return;
    }

    final dataSource = _remoteRelaySosCancelRemoteDataSource();
    if (dataSource == null) {
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] remote_cancel_handoff_skipped '
        'reason=backend_transport_unavailable '
        'originatorNodeId=${snapshot.originatorNodeId}',
      );
      _publishRemoteRelaySosCancelHandoffResult(
        snapshot: snapshot,
        deviceId: deviceId,
        status: RemoteRelaySosBackendHandoffStatus.skipped,
        reason: 'backend_transport_unavailable',
      );
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS] remote_cancel_handoff_start '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'deviceId=$deviceId',
    );

    try {
      await dataSource.cancelSos(deviceId: deviceId);
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] remote_cancel_handoff_success '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'deviceId=$deviceId',
      );
      _publishRemoteRelaySosCancelHandoffResult(
        snapshot: snapshot,
        deviceId: deviceId,
        status: RemoteRelaySosBackendHandoffStatus.submitted,
      );
    } catch (error) {
      final reason = _remoteRelaySosCancelFailureReason(error);
      final statusCode = error is SosHttpException ? error.statusCode : null;
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] remote_cancel_handoff_failed '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'statusCode=${statusCode ?? "-"} '
        'error=$error',
      );
      _publishRemoteRelaySosCancelHandoffResult(
        snapshot: snapshot,
        deviceId: deviceId,
        status: RemoteRelaySosBackendHandoffStatus.failed,
        reason: reason,
        errorMessage: error.toString(),
      );
    }
  }

  SosRemoteDataSource? _remoteRelaySosCancelRemoteDataSource() {
    final repository = sosRepository;
    if (repository is ApiSosRepository) {
      return repository.remoteDataSource;
    }
    if (repository is MqttOperationalSosRepository) {
      return repository.cancelRemoteDataSource ?? repository.remoteDataSource;
    }
    return null;
  }

  String _remoteRelaySosCancelFailureReason(Object error) {
    if (error is SosHttpException) {
      return switch (error.statusCode) {
        400 => 'invalid_request',
        401 => 'missing_or_invalid_sdk_identity',
        409 => 'conflict_not_associated',
        422 => 'unknown_device',
        _ => 'backend_error',
      };
    }
    if (error is AuthException) {
      return 'missing_or_invalid_sdk_identity';
    }
    if (error is NetworkException) {
      return 'network_error';
    }
    return 'backend_error';
  }

  void _publishRemoteRelaySosCancelHandoffResult({
    required RemoteRelaySosSnapshot snapshot,
    required String deviceId,
    required RemoteRelaySosBackendHandoffStatus status,
    String? reason,
    String? errorMessage,
  }) {
    _publishSdkEvent(
      RemoteRelaySosCancelHandoffResultEvent(
        originatorNodeId: snapshot.originatorNodeId,
        relayNodeId: snapshot.relayNodeId,
        deviceId: deviceId,
        status: status,
        reason: reason,
        errorMessage: errorMessage,
        receivedAt: snapshot.receivedAt,
      ),
    );
  }

  Future<void> _submitRemoteRelaySosToBackend({
    required RemoteRelaySosSnapshot snapshot,
    required TrackingPosition positionSnapshot,
    required String deviceId,
  }) async {
    final operationalClient = _remoteRelayOperationalRealtimeClient();
    if (operationalClient != null) {
      await operationalClient.publishOperationalSos(
        MqttOperationalSosRequest(
          timestamp: snapshot.receivedAt.toUtc(),
          positionSnapshot: positionSnapshot,
          deviceId: deviceId,
        ),
      );
      return;
    }

    final repository = sosRepository;
    if (repository is ApiSosRepository) {
      await repository.remoteDataSource.triggerSos(
        triggerSource: 'remote_lora_relay',
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
      );
      return;
    }

    throw const SosException(
      'E_REMOTE_RELAY_SOS_BACKEND_TRANSPORT_UNAVAILABLE',
      'No backend SOS transport is available for remote relay SOS handoff.',
    );
  }

  OperationalRealtimeClient? _remoteRelayOperationalRealtimeClient() {
    final client = realtimeClient;
    if (client is OperationalRealtimeClient) {
      return client;
    }
    final repository = sosRepository;
    if (repository is MqttOperationalSosRepository) {
      return repository.realtimeClient;
    }
    return null;
  }

  bool _hasValidRemoteRelayLocation(TrackingPosition? location) {
    if (location == null) {
      return false;
    }
    return location.latitude.isFinite &&
        location.latitude >= -90 &&
        location.latitude <= 90 &&
        location.longitude.isFinite &&
        location.longitude >= -180 &&
        location.longitude <= 180 &&
        !(location.latitude == 0 && location.longitude == 0);
  }

  TrackingPosition _remoteRelayBackendPosition({
    required TrackingPosition location,
    required DateTime receivedAt,
  }) {
    return TrackingPosition(
      latitude: location.latitude,
      longitude: location.longitude,
      altitude: location.altitude,
      accuracy: location.accuracy,
      speed: location.speed,
      heading: location.heading,
      source: location.source,
      timestamp: receivedAt.toUtc(),
    );
  }

  String _remoteRelaySosBackendHandoffSignature(
    RemoteRelaySosSnapshot snapshot,
  ) {
    final rawPayloadHex = EixamBleProtocol.hex(snapshot.rawPayload);
    final payloadToken = snapshot.payloadHex ?? rawPayloadHex;
    return '${snapshot.originatorNodeId}:'
        '${snapshot.sosType}:'
        '${snapshot.receivedAt.toUtc().microsecondsSinceEpoch}:'
        '$payloadToken';
  }

  void _publishSdkEvent(EixamSdkEvent event) {
    if (_isSosSdkEvent(event)) {
      _lastSosEvent = event;
    }
    _eventsController.add(event);
  }

  bool _isSosSdkEvent(EixamSdkEvent event) {
    return event is SOSTriggeredEvent ||
        event is SOSCancelledEvent ||
        event is RemoteRelaySosObservedEvent ||
        event is RemoteRelaySosBackendHandoffResultEvent ||
        event is RemoteRelaySosCancelHandoffResultEvent;
  }

  bool _isBackendSosChannelAvailable() {
    if (sosRepository is MqttOperationalSosRepository) {
      return _session != null &&
          _lastRealtimeConnectionState == RealtimeConnectionState.connected;
    }
    if (sosRepository is ApiSosRepository) {
      return _session != null;
    }
    return true;
  }

  _CurrentSosCapabilitySnapshot _computeCurrentSosCapabilitySnapshot({
    required String reason,
    DeviceStatus? statusOverride,
  }) {
    final backendAvailable = _isBackendSosChannelAvailable();
    final protectionStatus = _protectionModeController.currentStatus;
    final platformOwnsBle = _isPlatformBleOwner(protectionStatus.bleOwner);
    final chosenConnected =
        statusOverride?.connected ?? _lastDeviceStatus?.connected;
    final flutterCommandPath = deviceSosController.hasSosCommandPath;
    final serviceBleConnected =
        platformOwnsBle ? protectionStatus.serviceBleConnected : null;
    final serviceBleReady =
        platformOwnsBle ? protectionStatus.serviceBleReady : null;
    final deviceConnected = platformOwnsBle
        ? protectionStatus.deviceConnected ||
            protectionStatus.serviceBleConnected ||
            protectionStatus.serviceBleReady
        : (chosenConnected ?? false) || flutterCommandPath;
    final hasSosCommandPath = platformOwnsBle
        ? protectionStatus.serviceBleReady || flutterCommandPath
        : flutterCommandPath;
    final deviceSosAvailable = deviceConnected && hasSosCommandPath;
    final capability = backendAvailable
        ? (deviceSosAvailable
            ? SosDeliveryChannel.backendAndDevice
            : SosDeliveryChannel.backendOnly)
        : (deviceSosAvailable ? SosDeliveryChannel.deviceOnly : null);

    BleDebugRegistry.instance.recordEvent(
      '[SDK_SOS_CAPABILITY] recompute reason=$reason '
      'backendAvailable=$backendAvailable '
      'deviceConnected=$deviceConnected '
      'chosenConnected=${chosenConnected ?? false} '
      'serviceBleConnected=${serviceBleConnected ?? false} '
      'serviceBleReady=${serviceBleReady ?? false} '
      'hasSosCommandPath=$hasSosCommandPath '
      'result=${capability?.name ?? "unavailable"}',
    );

    return _CurrentSosCapabilitySnapshot(
      backendAvailable: backendAvailable,
      deviceConnected: deviceConnected,
      chosenConnected: chosenConnected ?? false,
      serviceBleConnected: serviceBleConnected,
      serviceBleReady: serviceBleReady,
      hasSosCommandPath: hasSosCommandPath,
      deviceSosAvailable: deviceSosAvailable,
      capability: capability,
    );
  }

  void _logCurrentSosCapabilityPublication({
    required SdkOperationalDiagnostics diagnostics,
    required String reason,
  }) {
    final next = diagnostics.currentSosCapabilityChannel;
    final previous = _lastPublishedCurrentSosCapabilityChannel;
    if (previous == next) {
      BleDebugRegistry.instance.recordEvent(
        '[SDK_SOS_CAPABILITY] publication_skipped reason=$reason '
        'old=${previous?.name ?? "unavailable"} '
        'new=${next?.name ?? "unavailable"}',
      );
      return;
    }
    if (previous != null) {
      BleDebugRegistry.instance.recordEvent(
        '[SDK_SOS_CAPABILITY] publication_overwrite reason=$reason '
        'old=${previous.name} '
        'new=${next?.name ?? "unavailable"}',
      );
    } else {
      BleDebugRegistry.instance.recordEvent(
        '[SDK_SOS_CAPABILITY] publication reason=$reason new=${next?.name ?? "unavailable"}',
      );
    }
    _lastPublishedCurrentSosCapabilityChannel = next;
  }

  bool _isPlatformBleOwner(ProtectionBleOwner owner) {
    return owner != ProtectionBleOwner.flutter;
  }

  bool _hasDeviceSosCommandPath({
    DeviceStatus? status,
    String trigger = 'unspecified',
  }) {
    return _computeCurrentSosCapabilitySnapshot(
      reason: trigger,
      statusOverride: status,
    ).hasSosCommandPath;
  }

  InMemoryDeviceRepository _requireCommandCapableDeviceRepository() {
    final repository = deviceRepository;
    if (repository is! InMemoryDeviceRepository ||
        !repository.hasCommandCapableBleRuntime) {
      throw const DeviceException(
        'E_DEVICE_COMMAND_NOT_READY',
        'A connected command-capable device is required for this SDK action.',
      );
    }
    return repository;
  }

  SdkOperationalDiagnostics _buildOperationalDiagnostics({
    String reason = 'build_operational_diagnostics',
  }) {
    final capabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
      reason: reason,
    );
    final session = _session;
    String? telemetryPublishTopic;
    List<String> sosEventTopics = const <String>[];

    if (session != null) {
      try {
        telemetryPublishTopic = SdkMqttTopics.telemetryDataFor(session);
        sosEventTopics = SdkMqttTopics.eventTopicsFor(session).toList()..sort();
      } on AuthException {
        telemetryPublishTopic = null;
        sosEventTopics = const <String>[];
      }
    }

    return SdkOperationalDiagnostics(
      session: session,
      connectionState: _lastRealtimeConnectionState,
      telemetryPublishTopic: telemetryPublishTopic,
      sosEventTopics: sosEventTopics,
      sosRehydrationNote: _lastSosRehydrationNote,
      backendSosAvailable: capabilitySnapshot.backendAvailable,
      deviceSosAvailable: capabilitySnapshot.deviceSosAvailable,
      lastPublicSosDeliveryChannel: _lastPublicSosDeliveryChannel,
      lastTelRelayRx: _lastTelRelayRx,
      backgroundTelemetryEnabled: _backgroundTelemetryEnabled,
      androidForegroundServiceRunning:
          _backgroundTelemetryDiagnostics.serviceRunning,
      backgroundPermissionStatus:
          _backgroundTelemetryDiagnostics.permissionStatus,
      lastBackgroundTelemetryAt:
          _backgroundTelemetryDiagnostics.lastTelemetryAt,
      lastBackgroundTelemetryError:
          _backgroundTelemetryDiagnostics.lastTelemetryError,
      lastBackgroundLocationMode:
          _backgroundTelemetryDiagnostics.lastLocationMode,
      activeBackgroundLocationRequest:
          _backgroundTelemetryDiagnostics.activeLocationRequest,
      bridge: _bridgeDiagnostics,
    );
  }

  void _emitOperationalDiagnostics({
    String reason = 'emit',
  }) {
    if (_operationalDiagnosticsController.isClosed) {
      return;
    }
    final diagnostics = _buildOperationalDiagnostics(reason: reason);
    _logCurrentSosCapabilityPublication(
      diagnostics: diagnostics,
      reason: reason,
    );
    _operationalDiagnosticsController.add(diagnostics);
  }

  Future<DeviceStatus> _resolveDeviceStatusForCapability({
    required String trigger,
    bool refreshRuntimeStatus = false,
  }) async {
    if (!refreshRuntimeStatus) {
      BleDebugRegistry.instance.recordEvent(
        '$trigger device status resolution -> using cached SDK snapshot without repository read',
      );
      final status = _lastDeviceStatus;
      if (status != null) {
        return status;
      }
      final initialStatus = await deviceRepository.getDeviceStatus();
      _lastDeviceStatus = initialStatus;
      BleDebugRegistry.instance.recordEvent(
        '$trigger device status resolved -> connected=${initialStatus.connected} previous=- deviceId=${initialStatus.deviceId} lifecycle=${initialStatus.lifecycleState.name} refreshed=$refreshRuntimeStatus source=initial_repository_snapshot',
      );
      return initialStatus;
    }
    final status = refreshRuntimeStatus
        ? await deviceRepository.refreshDeviceStatus()
        : await deviceRepository.getDeviceStatus();
    final previous = _lastDeviceStatus;
    _lastDeviceStatus = status;
    BleDebugRegistry.instance.recordEvent(
      '$trigger device status resolved -> connected=${status.connected} previous=${previous?.connected} deviceId=${status.deviceId} lifecycle=${status.lifecycleState.name} refreshed=$refreshRuntimeStatus',
    );
    return status;
  }

  Future<SdkOperationalDiagnostics> _refreshOperationalDiagnostics({
    required String trigger,
    bool refreshRuntimeStatus = false,
    bool emit = true,
  }) async {
    try {
      await _resolveDeviceStatusForCapability(
        trigger: trigger,
        refreshRuntimeStatus: refreshRuntimeStatus,
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '$trigger device status refresh failed -> error=$error',
      );
    }
    await _refreshBackgroundTelemetryDiagnostics();
    final diagnostics = _buildOperationalDiagnostics(reason: trigger);
    if (emit && !_operationalDiagnosticsController.isClosed) {
      _logCurrentSosCapabilityPublication(
        diagnostics: diagnostics,
        reason: trigger,
      );
      _operationalDiagnosticsController.add(diagnostics);
    }
    return diagnostics;
  }

  Future<void> dispose() async {
    await _stopBackgroundTelemetry(reason: 'dispose');
    _cancelProtectionDisconnectGraceTimer();
    WidgetsBinding.instance.removeObserver(this);
    _deathManTimer?.cancel();
    _preSosSession?.timer.cancel();
    await _bleAutoReconnectCoordinator.dispose();
    await _realtimeConnectionSub?.cancel();
    await _realtimeEventsSub?.cancel();
    await _deviceStatusSub?.cancel();
    await _deviceSosSub?.cancel();
    await _deviceSosCommandPathSub?.cancel();
    await _guidedRescueSub?.cancel();
    await _backlogSyncSub?.cancel();
    await _sosStateSub?.cancel();
    await _bridgeDiagnosticsSub?.cancel();
    await _bleIncomingEventDiagnosticsSub?.cancel();
    await _protectionStatusSub?.cancel();
    await _protectionRawSosEventsSub?.cancel();
    await _bleOperationalRuntimeBridge.dispose();
    await _backlogSyncController.dispose();
    await _protectionModeController.dispose();
    await _operationalTelemetryCoordinator.stop();
    await deviceSosController.dispose();
    await realtimeClient.disconnect();
    await disposeCallback?.call();
    await _realtimeConnectionStateController.close();
    await _realtimeEventsController.close();
    await _operationalDiagnosticsController.close();
    await _guidedRescueStateController.close();
    await _bleNotificationNavigationController.close();
    await _publicSosStateController.close();
    await _publicPreSosStatusController.close();
    await _eventsController.close();
  }
}

class _PublicSosDeviceAttempt {
  const _PublicSosDeviceAttempt({
    required this.available,
    required this.attempted,
    required this.succeeded,
  });

  final bool available;
  final bool attempted;
  final bool succeeded;
}

class _AppTriggeredSosBridge {
  const _AppTriggeredSosBridge({
    required this.incidentId,
    required this.createdAt,
    required this.expiresAt,
    this.deviceId,
    this.nodeId,
    this.matchedAt,
  });

  final String incidentId;
  final String? deviceId;
  final int? nodeId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? matchedAt;

  _AppTriggeredSosBridge copyWith({
    String? incidentId,
    String? deviceId,
    int? nodeId,
    DateTime? createdAt,
    DateTime? expiresAt,
    DateTime? matchedAt,
  }) {
    return _AppTriggeredSosBridge(
      incidentId: incidentId ?? this.incidentId,
      deviceId: deviceId ?? this.deviceId,
      nodeId: nodeId ?? this.nodeId,
      createdAt: createdAt ?? this.createdAt,
      expiresAt: expiresAt ?? this.expiresAt,
      matchedAt: matchedAt ?? this.matchedAt,
    );
  }
}

class _PreSosSession {
  const _PreSosSession({
    required this.startedAt,
    required this.expectedActivationAt,
    required this.mirroredOnDevice,
    required this.origin,
    required this.timer,
  });

  final DateTime startedAt;
  final DateTime expectedActivationAt;
  final bool mirroredOnDevice;
  final DeviceSosTransitionSource? origin;
  final Timer timer;

  _PreSosSession copyWith({
    DateTime? startedAt,
    DateTime? expectedActivationAt,
    bool? mirroredOnDevice,
    Object? origin = _unset,
    Timer? timer,
  }) {
    return _PreSosSession(
      startedAt: startedAt ?? this.startedAt,
      expectedActivationAt: expectedActivationAt ?? this.expectedActivationAt,
      mirroredOnDevice: mirroredOnDevice ?? this.mirroredOnDevice,
      origin: identical(origin, _unset)
          ? this.origin
          : origin as DeviceSosTransitionSource?,
      timer: timer ?? this.timer,
    );
  }

  static const Object _unset = Object();
}

class _CurrentSosCapabilitySnapshot {
  const _CurrentSosCapabilitySnapshot({
    required this.backendAvailable,
    required this.deviceConnected,
    required this.chosenConnected,
    required this.serviceBleConnected,
    required this.serviceBleReady,
    required this.hasSosCommandPath,
    required this.deviceSosAvailable,
    required this.capability,
  });

  final bool backendAvailable;
  final bool deviceConnected;
  final bool chosenConnected;
  final bool? serviceBleConnected;
  final bool? serviceBleReady;
  final bool hasSosCommandPath;
  final bool deviceSosAvailable;
  final SosDeliveryChannel? capability;
}

enum _SosClosureIntent { cancel, resolve }

class _ObservedRelaySosContext {
  const _ObservedRelaySosContext({
    required this.remoteDeviceId,
    required this.nodeId,
    required this.relayCount,
    required this.packetSignature,
  });

  final String remoteDeviceId;
  final int nodeId;
  final int relayCount;
  final String packetSignature;
}

class _OperationalSosMetadata {
  const _OperationalSosMetadata({
    this.deviceBattery,
    this.deviceCoverage,
    this.mobileBattery,
    this.mobileCoverage,
  });

  final SdkDeviceBatterySnapshot? deviceBattery;
  final SdkCoverageSnapshot? deviceCoverage;
  final int? mobileBattery;
  final SdkCoverageSnapshot? mobileCoverage;
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
