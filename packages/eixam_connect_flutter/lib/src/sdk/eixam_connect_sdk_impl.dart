import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:flutter/widgets.dart';

import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/datasources_local/sdk_session_store.dart';
import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_remote/sos_remote_data_source.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/api_sos_repository.dart';
import '../data/repositories/mqtt_operational_sos_repository.dart';
import '../data/datasources_remote/sdk_identity_remote_data_source.dart';
import '../data/datasources_remote/sdk_profile_remote_data_source.dart';
import '../device/ble_incoming_event.dart';
import '../device/ble_incoming_payload_classifier.dart';
import '../device/device_sos_controller.dart';
import '../device/ble_debug_registry.dart';
import '../device/eixam_ble_command.dart';
import '../device/eixam_ble_protocol.dart';
import '../device/eixam_sos_event_packet.dart';
import '../device/eixam_sos_packet.dart';
import '../data/datasources_remote/sdk_session_context.dart';
import '../data/repositories/telemetry_repository.dart';
import '../data/repositories/sos_runtime_rehydration_support.dart';
import 'android_protection_platform_adapter.dart';
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
import 'sos_backend_identity_normalizer.dart';

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
  final SdkProfileRemoteDataSource? profileRemoteDataSource;
  final EixamNotificationPolicy notificationPolicy;
  final ProtectionPlatformAdapter protectionPlatformAdapter;
  final BackgroundTelemetryPlatformAdapter backgroundTelemetryPlatformAdapter;
  final SharedPrefsSdkStore _localStore;
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
  final StreamController<DeviceStatus> _publicDeviceStatusController =
      StreamController<DeviceStatus>.broadcast();
  final StreamController<SosState> _publicSosStateController =
      StreamController<SosState>.broadcast();
  final StreamController<PublicPreSosStatus?> _publicPreSosStatusController =
      StreamController<PublicPreSosStatus?>.broadcast();
  final StreamController<EixamNotificationIntent>
      _notificationIntentController =
      StreamController<EixamNotificationIntent>.broadcast();
  final BleIncomingPayloadClassifier _protectionSosPayloadClassifier =
      const BleIncomingPayloadClassifier();

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
  DeviceStatus? _lastPublicDeviceStatus;
  GuidedRescueState _guidedRescueState = const GuidedRescueState.unsupported();
  BleNotificationNavigationRequest? _pendingBleNotificationNavigationRequest;
  final List<EixamNotificationIntent> _pendingNotificationIntents =
      <EixamNotificationIntent>[];
  final Set<String> _emittedNotificationIntentKeys = <String>{};
  final List<String> _emittedNotificationIntentKeyOrder = <String>[];
  String? _activeDeviceSosCycleKey;
  String? _notifiedDeviceSosCycleKey;
  DeviceSosState? _notifiedDeviceSosState;
  EixamSession? _session;
  EixamSdkEvent? _lastSosEvent;
  String? _pendingCancelledIncidentId;
  String? _lastSosRehydrationNote;
  SdkBridgeDiagnostics _bridgeDiagnostics = const SdkBridgeDiagnostics();
  SosState _publicSosState = SosState.idle;
  PublicPreSosStatus? _lastPublishedPreSosStatus;
  SosIncident? _publicSosFallbackIncident;
  SosIncident? _lastKnownActiveSosIncident;
  String? _lastLoggedActiveIncidentPreservationSignature;
  bool _loggedBackgroundSosPublishTraceV2 = false;
  String? _lastPublicSosIncidentId;
  SosDeliveryChannel? _lastPublicSosDeliveryChannel;
  final Set<String> _acknowledgedTerminalSosIncidentIds = <String>{};
  bool _acknowledgedTerminalSosWithoutIncident = false;
  _AppTriggeredSosBridge? _pendingAppTriggeredSosBridge;
  _PreSosSession? _preSosSession;
  int? _knownLocalDeviceNodeId;
  SosDeliveryChannel? _lastPublishedCurrentSosCapabilityChannel;
  DeviceTelRelayRx? _lastTelRelayRx;
  final Map<String, _ObservedRelaySosContext> _observedRelaySosBySignature =
      <String, _ObservedRelaySosContext>{};
  final Map<String, DateTime> _remoteRelaySosBackendHandoffBySignature =
      <String, DateTime>{};
  final Map<String, _TerminalSosSuppression> _terminalSosSuppressionByKey =
      <String, _TerminalSosSuppression>{};
  final Map<String, _SosClosureIntent>
      _deviceOriginatedClosureIntentByCycleKey = <String, _SosClosureIntent>{};
  final Map<String, _SosClosureIntent>
      _deviceOriginatedClosureIntentByIncidentId =
      <String, _SosClosureIntent>{};
  String? _activeDeviceRuntimeIncidentId;
  String? _activeDeviceRuntimeCycleKey;
  String? _activeDeviceRuntimeLocalCycleKey;
  int _deviceRuntimeLocalCycleSequence = 0;
  String? _deviceOwnedBackendIncidentId;
  String? _lastDeviceRuntimeCanonicalIncidentSignature;
  SosIncident? _lastDeviceRuntimeCanonicalIncident;
  final Set<String> _loggedDeviceRuntimeCanonicalizationSignatures = <String>{};
  final Set<String> _closedDeviceRuntimeIncidentIds = <String>{};
  final Map<String, int> _sosRuntimeNodeIdByHardwareId = <String, int>{};
  final Map<String, DateTime> _sosRuntimeInvariantLogByKey =
      <String, DateTime>{};
  final Map<String, DateTime> _sosRejectionLogByKey = <String, DateTime>{};
  bool _publicSosActionInFlight = false;
  _SosClosureIntent? _publicSosClosureInFlight;
  Future<SosIncident>? _pendingPreSosConfirmation;
  bool _preSosExpirySettlementInFlight = false;
  final Set<String> _deviceOriginatedBackendSyncInFlight = <String>{};
  EixamSdkConfig? _sdkConfig;
  bool _registeredDeviceAutoSyncInFlight = false;
  final Set<String> _backendRegisteredNodeIdsForSession = <String>{};
  final Map<String, Future<void>> _backendDeviceRegistrationInFlightByNodeId =
      <String, Future<void>>{};
  bool _manualDisconnectRequested = false;
  bool _lastDeviceSosCommandPathAvailable = false;
  int _preSosCycleRevision = 0;
  final Set<int> _loggedIgnoredPreSosTickCycles = <int>{};
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
  static const Duration _terminalSosSuppressionWindow = Duration(seconds: 10);
  static const int _maxPendingNotificationIntents = 20;
  static const int _maxRememberedNotificationIntentKeys = 100;

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
    this.profileRemoteDataSource,
    this.notificationPolicy = EixamNotificationPolicy.sdkManaged,
    ProtectionPlatformAdapter? protectionPlatformAdapter,
    BackgroundTelemetryPlatformAdapter? backgroundTelemetryPlatformAdapter,
    SharedPrefsSdkStore? localStore,
    Duration appTriggeredSosBridgeWindow = _defaultAppTriggeredSosBridgeWindow,
    this.disposeCallback,
  })  : _appTriggeredSosBridgeWindow = appTriggeredSosBridgeWindow,
        _localStore = localStore ?? SharedPrefsSdkStore(),
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
      sosBackendDeviceRegisterRetry: _retrySosAfterBackendDeviceRegistration,
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
      hostAppManagedNotificationsProvider: () =>
          notificationPolicy == EixamNotificationPolicy.hostAppManaged,
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
    BleDebugRegistry.instance.recordEvent(
      '[SDK_RUNTIME_MARKER] package=eixam_connect_flutter '
      'marker=sos_debug_build_v3 path=eixam_connect_sdk_impl.dart',
    );
    _sdkConfig = config;
    _session = await sessionStore?.load();
    _session = await _bootstrapSessionIfNeeded(_session);
    _manualDisconnectRequested =
        await preferredBleDeviceStore.readManualDisconnectRequested();
    if (_manualDisconnectRequested) {
      _clearDeviceRuntimeResidueAfterManualDisconnect();
    }
    if (sessionContext != null) {
      sessionContext!.currentSession = _session;
    }
    await _rehydrateSosRuntimeState();
    _publicSosState = _publicSosStateFromRepositoryLoad(
      incoming: await sosRepository.getSosState(),
      source: 'repository_load:initialize',
    );
    _lastDeviceStatus = await deviceRepository.getDeviceStatus();
    final deviceSosStatus = await deviceSosController.getStatus();
    _syncPreSosSessionFromDeviceStatus(deviceSosStatus);
    await _syncPreSosSessionFromProtectionPlatformSnapshot(
      trigger: 'initialize',
    );
    await _restorePersistedPreSosSession(trigger: 'initialize');
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
    await _seedPreferredBleDeviceFromBackendRegistryIfNeeded(
      trigger: 'initialize',
    );
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
      final promotedStatus = _promoteCachedNodeIdOntoDeviceStatus(
        status,
        source: 'device_status_stream',
      );
      final previousStatus = _lastDeviceStatus;
      _lastDeviceStatus = promotedStatus;
      if (promotedStatus.nodeId != null) {
        _knownLocalDeviceNodeId = promotedStatus.nodeId;
      }
      _publishPublicDeviceStatus(
        rawStatus: promotedStatus,
        reason: 'device_status_stream',
      );
      BleDebugRegistry.instance.recordEvent(
        'Device connectivity changed -> connected=${promotedStatus.connected} previous=${previousStatus?.connected} deviceId=${promotedStatus.nodeId?.toString() ?? "-"} nodeId=${promotedStatus.nodeId?.toString() ?? "-"} hardwareId=${promotedStatus.deviceId} lifecycle=${promotedStatus.lifecycleState.name}',
      );
      _emitOperationalDiagnostics();
      unawaited(
        _updateBackgroundTelemetryState(reason: 'device_status_stream'),
      );
      _scheduleRegisteredDeviceAutoSync(
        trigger: 'device_status_stream',
        status: promotedStatus,
      );
      unawaited(
        _backlogSyncController.onDeviceStatusChanged(
          previous: previousStatus,
          current: promotedStatus,
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
          'SOS command path availability changed -> available=$available previous=$previous connected=${_lastDeviceStatus?.connected} deviceId=${_lastDeviceStatus?.nodeId?.toString() ?? "-"} nodeId=${_lastDeviceStatus?.nodeId?.toString() ?? "-"} hardwareId=${_lastDeviceStatus?.deviceId ?? "-"}',
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
      final rawStatus = _lastDeviceStatus;
      if (rawStatus != null) {
        _publishPublicDeviceStatus(
          rawStatus: rawStatus,
          reason: 'protection_status_stream',
        );
      }
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
            _logSosTrace(
              'dart_sdk_remote_relay_received '
              'originatorNodeId=${remoteRelaySnapshot.originatorNodeId} '
              'relayNodeId=${remoteRelaySnapshot.relayNodeId ?? "none"} '
              'source=${remoteRelaySnapshot.source.name} '
              'payloadLen=${remoteRelaySnapshot.rawPayload.length} '
              'payloadHex=${remoteRelaySnapshot.payloadHex ?? "-"} '
              'hasLocation=${remoteRelaySnapshot.location != null} '
              'lat=${remoteRelaySnapshot.location?.latitude ?? "none"} '
              'lon=${remoteRelaySnapshot.location?.longitude ?? "none"} '
              'alt=${remoteRelaySnapshot.location?.altitude ?? "none"}',
            );
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
    _backlogSyncSub = _backlogSyncController.watchState().listen((_) {});
  }

  @override
  Future<void> setSession(EixamSession session) async {
    _bleOperationalRuntimeBridge.resetForSessionChange();
    _clearBackendDeviceRegistrationSessionCache();
    _session = await _bootstrapSessionIfNeeded(session);
    if (sessionContext != null) {
      sessionContext!.currentSession = _session;
    }
    await _rehydrateSosRuntimeState();
    _publicSosFallbackIncident = null;
    _clearPendingAppTriggeredSosBridge(reason: 'session_replaced');
    _publicSosState = _publicSosStateFromRepositoryLoad(
      incoming: await sosRepository.getSosState(),
      source: 'repository_load:set_session',
    );
    await sessionStore?.save(_session!);
    _emitOperationalDiagnostics();
    _operationalTelemetryCoordinator.start(initialSosState: _publicSosState);
    await _reconcileBackgroundTelemetry(reason: 'set_session');
    _scheduleRegisteredDeviceAutoSync(
      trigger: 'set_session',
      status: _lastDeviceStatus,
    );
    await _seedPreferredBleDeviceFromBackendRegistryIfNeeded(
      trigger: 'set_session',
    );
    await _bleAutoReconnectCoordinator.tryAutoConnectOnResume();
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
    if (refreshed.appId != session.appId ||
        refreshed.externalUserId != session.externalUserId ||
        refreshed.userHash != session.userHash ||
        refreshed.canonicalExternalUserId != session.canonicalExternalUserId) {
      _clearBackendDeviceRegistrationSessionCache();
    }
    _session = refreshed;
    if (sessionContext != null) {
      sessionContext!.currentSession = refreshed;
    }
    await _rehydrateSosRuntimeState();
    _publicSosFallbackIncident = null;
    _clearPendingAppTriggeredSosBridge(reason: 'identity_refreshed');
    _publicSosState = _publicSosStateFromRepositoryLoad(
      incoming: await sosRepository.getSosState(),
      source: 'repository_load:refresh_identity',
    );
    await sessionStore?.save(refreshed);
    _emitOperationalDiagnostics();
    _operationalTelemetryCoordinator.start(initialSosState: _publicSosState);
    await _reconcileBackgroundTelemetry(reason: 'refresh_identity');
    _scheduleRegisteredDeviceAutoSync(
      trigger: 'refresh_identity',
      status: _lastDeviceStatus,
    );
    await _seedPreferredBleDeviceFromBackendRegistryIfNeeded(
      trigger: 'refresh_identity',
    );
    await _bleAutoReconnectCoordinator.tryAutoConnectOnResume();
    final realtime = realtimeClient;
    if (realtime is OperationalRealtimeClient) {
      await realtime.reconnectIfSessionChanged(refreshed);
    } else {
      await realtime.connect();
    }
    return refreshed;
  }

  @override
  Future<SdkUserProfile> fetchSdkUserProfile() async {
    final ds = profileRemoteDataSource;
    if (ds == null) {
      throw const AuthException(
        'E_SDK_PROFILE_HTTP_UNAVAILABLE',
        'SDK profile HTTP API is not configured for this runtime.',
      );
    }
    final session = _session;
    if (session == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'An SDK session must be configured before fetching profile.',
      );
    }
    return ds.fetchProfile(sessionOverride: session);
  }

  @override
  Future<SdkUserProfile> updateSdkUserProfile(
      SdkUserProfileUpdate update) async {
    final ds = profileRemoteDataSource;
    if (ds == null) {
      throw const AuthException(
        'E_SDK_PROFILE_HTTP_UNAVAILABLE',
        'SDK profile HTTP API is not configured for this runtime.',
      );
    }
    final session = _session;
    if (session == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'An SDK session must be configured before updating profile.',
      );
    }
    return ds.updateProfile(update, sessionOverride: session);
  }

  Future<EixamSession?> _bootstrapSessionIfNeeded(EixamSession? session) async {
    if (session == null) {
      return null;
    }
    final remoteDataSource = identityRemoteDataSource;
    if (remoteDataSource == null) {
      return session;
    }
    final hasCanonicalExternalUserId =
        session.canonicalExternalUserId?.trim().isNotEmpty == true;
    final hasSdkUserId = session.sdkUserId?.trim().isNotEmpty == true;
    if (hasCanonicalExternalUserId && hasSdkUserId) {
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
        _applyTerminalSosSuppression(
          reason: 'backend_terminal_state:${state.name}',
        );
        await _clearSosNotificationsSafely(
          reason: 'public_state_stream:${state.name}',
        );
        await _emitRepositoryTerminalSosNotificationIntent(state);
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
    _clearBackendDeviceRegistrationSessionCache();
    _lastSosRehydrationNote = null;
    _publicSosFallbackIncident = null;
    _lastPublicSosIncidentId = null;
    _lastPublicSosDeliveryChannel = null;
    _clearPreSosSession(
      reason: 'session_cleared',
      emitIdleState: false,
    );
    _clearPendingAppTriggeredSosBridge(reason: 'session_cleared');
    _clearDeviceRuntimeSosOwnership(reason: 'session_cleared');
    _emitPublicSosState(SosState.idle, source: 'clear_session');
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

  Future<SosRuntimeRehydrationResult?> _rehydrateSosRuntimeState({
    String trigger = 'startup',
    bool emitPublicState = false,
  }) async {
    _lastSosRehydrationNote = null;

    if (_session == null) {
      return null;
    }

    if (sosRepository is! SosRuntimeRehydrationSupport) {
      return null;
    }
    final rehydrationRepository = sosRepository as SosRuntimeRehydrationSupport;

    try {
      final result =
          await rehydrationRepository.rehydrateRuntimeStateFromBackend();
      _lastSosRehydrationNote = result.diagnosticNote;
      await _applySosRuntimeRehydrationResult(
        result,
        trigger: trigger,
        emitPublicState: emitPublicState,
      );
      return result;
    } catch (error) {
      _lastSosRehydrationNote =
          'SOS rehydration failed for $trigger. Error: $error';
      BleDebugRegistry.instance.recordEvent(
        '[SOS_REHYDRATE] trigger=$trigger outcome=failed error=$error',
      );
      return null;
    }
  }

  Future<void> _applySosRuntimeRehydrationResult(
    SosRuntimeRehydrationResult result, {
    required String trigger,
    required bool emitPublicState,
  }) async {
    BleDebugRegistry.instance.recordEvent(
      '[SOS_REHYDRATE] trigger=$trigger outcome=${result.outcome.name} '
      'state=${result.resultingState.name} '
      'note=${result.diagnosticNote ?? "-"}',
    );

    switch (result.outcome) {
      case SosRuntimeRehydrationOutcome.clearedToIdle:
        if (_buildCurrentPreSosStatus() != null &&
            _publicSosClosureInFlight == null) {
          BleDebugRegistry.instance.recordEvent(
            '[SOS_REHYDRATE] action=keep_pre_sos_countdown '
            'trigger=$trigger backendState=idle reason=sdk_pre_sos_active',
          );
          if (emitPublicState || _publicSosState != SosState.arming) {
            _emitPublicSosState(
              SosState.arming,
              source: 'sos_rehydrate:$trigger:pre_sos_active',
            );
          }
          return;
        }
        _clearPreSosSession(
          reason: 'backend_rehydration_cleared_to_idle',
          emitIdleState: false,
        );
        if (deviceSosController.currentStatus.state ==
            DeviceSosState.preConfirm) {
          deviceSosController.clearPreSosLocally(
            reason: 'backend_rehydration_cleared_to_idle',
          );
        }
        _publicSosFallbackIncident = null;
        _lastKnownActiveSosIncident = null;
        _lastLoggedActiveIncidentPreservationSignature = null;
        _clearPendingAppTriggeredSosBridge(
          reason: 'backend_rehydration_cleared_to_idle',
        );
        _clearDeviceRuntimeSosOwnership(
          reason: 'backend_rehydration_cleared_to_idle',
        );
        BleDebugRegistry.instance.recordEvent(
          '[SOS_REHYDRATE] action=stale_countdown_discarded '
          'trigger=$trigger backendState=idle',
        );
        if (emitPublicState || _publicSosState != SosState.idle) {
          _emitPublicSosState(SosState.idle, source: 'sos_rehydrate:$trigger');
        }
        return;
      case SosRuntimeRehydrationOutcome.hydratedFromBackend:
        final state = result.resultingState;
        if (_isTerminalPublicSosState(state)) {
          _clearPreSosSession(
            reason: 'backend_rehydration_terminal:${state.name}',
            emitIdleState: false,
          );
          _applyTerminalSosSuppression(
            reason: 'backend_terminal_state:${state.name}',
          );
        } else if (_isOpenSosState(state)) {
          _clearPreSosSession(
            reason: 'backend_rehydration_open:${state.name}',
            emitIdleState: false,
          );
        }
        if (emitPublicState || _publicSosState != state) {
          _emitPublicSosState(state, source: 'sos_rehydrate:$trigger');
        }
        return;
      case SosRuntimeRehydrationOutcome.keptLocalFallback:
        return;
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
      nodeId: status?.nodeId,
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
          nodeId: status?.nodeId,
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

  SosState _promotePostTriggerSosState(SosState state) {
    return switch (state) {
      SosState.idle ||
      SosState.arming ||
      SosState.triggerRequested ||
      SosState.triggeredLocal ||
      SosState.sending =>
        SosState.sent,
      _ => state,
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
      reason: 'activate_device',
    );
  }

  @override
  Future<DeviceStatus> getDeviceStatus() {
    return _cacheDeviceStatus(
      deviceRepository.getDeviceStatus(),
      reason: 'get_device_status',
      emitPublicStatus: false,
    );
  }

  @override
  Future<DeviceStatus> refreshDeviceStatus() {
    return _cacheDeviceStatus(
      deviceRepository.refreshDeviceStatus(),
      reason: 'refresh_device_status',
    );
  }

  @override
  Future<void> unpairDevice() async {
    _manualDisconnectRequested = true;
    _clearDeviceRuntimeResidueAfterManualDisconnect();
    final preferredDevice = await preferredBleDeviceStore.getPreferredDevice();
    final currentStatus = await _readCurrentDeviceStatusForUnpair();
    await _stopProtectionRuntimeForManualUnpair();
    await _removeAndroidBluetoothBondsForManualUnpair(
      preferredDevice: preferredDevice,
      currentStatus: currentStatus,
    );
    await _bleAutoReconnectCoordinator.unpairDeviceManually(
      deviceRepository.unpairDevice,
    );
    _lastDeviceStatus = await deviceRepository.getDeviceStatus();
    _publishPublicDeviceStatus(
      rawStatus: _lastDeviceStatus!,
      reason: 'unpair_device',
    );
  }

  Future<DeviceStatus?> _readCurrentDeviceStatusForUnpair() async {
    try {
      return await deviceRepository.getDeviceStatus();
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Manual unpair could not read current device status before cleanup: $error',
      );
      return _lastDeviceStatus;
    }
  }

  Future<void> _stopProtectionRuntimeForManualUnpair() async {
    final status = _protectionModeController.currentStatus;
    if (!status.protectionRuntimeActive &&
        !status.foregroundServiceRunning &&
        status.bleOwner == ProtectionBleOwner.flutter) {
      return;
    }
    try {
      await _protectionModeController.exit();
      BleDebugRegistry.instance.recordEvent(
        'Protection runtime stopped before manual unpair',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Protection runtime stop before manual unpair failed: $error',
      );
    }
  }

  Future<void> _removeAndroidBluetoothBondsForManualUnpair({
    required PreferredDevice? preferredDevice,
    required DeviceStatus? currentStatus,
  }) async {
    final adapter = protectionPlatformAdapter;
    if (adapter is! AndroidProtectionPlatformAdapter) {
      return;
    }
    for (final deviceId in _manualUnpairBluetoothDeviceIds(
      preferredDevice: preferredDevice,
      currentStatus: currentStatus,
    )) {
      final removed = await adapter.removeBluetoothBond(deviceId);
      BleDebugRegistry.instance.recordEvent(
        removed
            ? 'Android Bluetooth bond removed before manual unpair -> hardwareId=$deviceId'
            : 'Android Bluetooth bond removal before manual unpair skipped -> hardwareId=$deviceId',
      );
      if (removed) {
        return;
      }
    }
  }

  List<String> _manualUnpairBluetoothDeviceIds({
    required PreferredDevice? preferredDevice,
    required DeviceStatus? currentStatus,
  }) {
    final values = <String?>[
      preferredDevice?.deviceId,
      currentStatus?.deviceId,
      currentStatus?.canonicalHardwareId,
      _lastDeviceStatus?.deviceId,
      _lastDeviceStatus?.canonicalHardwareId,
    ];
    final seen = <String>{};
    return values
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .where((value) => seen.add(value.toLowerCase()))
        .toList(growable: false);
  }

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) {
    _manualDisconnectRequested = false;
    return _cacheDeviceStatus(
      _bleAutoReconnectCoordinator.pairDeviceManually(
        pairingCode: pairingCode,
      ),
      reason: 'pair_device',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _bleAutoReconnectCoordinator.setAppForeground(true);
        unawaited(
          _rehydrateSosStateOnAppResume(),
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

  Future<void> _rehydrateSosStateOnAppResume() async {
    BleDebugRegistry.instance.recordEvent(
      '[SOS_REHYDRATE] trigger=app_resumed action=start',
    );
    await _restorePersistedPreSosSession(trigger: 'app_resumed');
    await _settleExpiredPreSosSession(trigger: 'app_resumed');
    await _rehydrateSosRuntimeState(
      trigger: 'app_resumed',
      emitPublicState: true,
    );
    await _rehydrateDeviceSosPublicState(
      trigger: 'app_resumed',
      emitResolvedState: true,
    );
  }

  @override
  Stream<DeviceStatus> watchDeviceStatus() async* {
    final current =
        _lastDeviceStatus ?? await deviceRepository.getDeviceStatus();
    _lastDeviceStatus = current;
    final publicCurrent = _publishPublicDeviceStatus(
      rawStatus: current,
      reason: 'watch_device_status_initial',
      emit: false,
    );
    yield publicCurrent;
    yield* _publicDeviceStatusController.stream;
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
    bool waitForDeviceAcknowledgement = true,
  }) async {
    final currentStatus = await deviceSosController.getStatus();
    final capabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
      reason: 'device_terminal_${intent.name}_command',
    );
    late final DeviceSosStatus status;
    _logSosTrace(
      'device_terminal_command_requested action=${intent.name}',
    );
    try {
      status = await deviceSosController.cancelSos(
        commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
        commandRouteLabel: _currentDeviceCommandOwnerRoute,
        terminalAction: intent.name,
        terminalCmdAvailable: capabilitySnapshot.longCommandAvailable,
        waitForCloseAcknowledgement: waitForDeviceAcknowledgement,
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
      _applyTerminalSosSuppression(
        reason: 'device_close_command_without_ack:${intent.name}',
        nodeId: status.nodeId,
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
    return deviceSosController.sendInetOk(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  @override
  Future<void> sendInetLostToDevice() {
    return deviceSosController.sendInetLost(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  @override
  Future<void> sendPositionConfirmedToDevice() {
    return deviceSosController.sendPositionConfirmed(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  @override
  Future<void> sendSosAckRelayToDevice({required int nodeId}) {
    return deviceSosController.sendAckRelay(
      nodeId: nodeId,
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  @override
  Future<void> sendShutdownToDevice() async {
    if (!_isProtectionPlatformOwningBle &&
        !deviceSosController.hasSosCommandPath) {
      await _ensureCommandCapableDeviceRepository(action: 'send_shutdown');
    }
    await deviceSosController.sendShutdown(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
    await _markDeviceDisconnectedAfterLocalShutdown();
  }

  @override
  Future<void> setDeviceNotificationVolume(int volume) async {
    _validateDeviceVolume(volume);
    await _sendDeviceControlCommandThroughActiveOwner(
      action: 'set_notification_volume',
      command: EixamDeviceCommand.notificationVolume(volume),
    );
  }

  @override
  Future<void> setDeviceSosVolume(int volume) async {
    _validateDeviceVolume(volume);
    await _sendDeviceControlCommandThroughActiveOwner(
      action: 'set_sos_volume',
      command: EixamDeviceCommand.sosVolume(volume),
    );
  }

  @override
  Future<DeviceRuntimeStatus> getDeviceRuntimeStatus() async {
    final repository = await _ensureCommandCapableDeviceRepository(
      action: 'get_device_runtime_status',
    );
    return repository.getDeviceRuntimeStatus();
  }

  @override
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot() async {
    final snapshot = await deviceRepository.getRuntimeIdentitySnapshot();
    if (snapshot.readinessReason != RuntimeIdentityReadinessReason.ready) {
      BleDebugRegistry.instance.recordEvent(
        '[RUNTIME_IDENTITY_SNAPSHOT] unavailable '
        'reason=${snapshot.readinessReason.diagnosticName} '
        'serviceBleConnected=${snapshot.serviceBleConnected} '
        'commandCapable=${snapshot.commandCapable} '
        'connectedBleNodeId=${snapshot.connectedBleNodeId ?? "-"} '
        'deviceId=${snapshot.deviceId ?? "-"}',
      );
    }
    return snapshot;
  }

  @override
  Future<void> rebootDevice() async {
    await _sendDeviceControlCommandThroughActiveOwner(
      action: 'reboot_device',
      command: EixamDeviceCommand.reboot(),
    );
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
  Future<List<EixamNotificationIntent>>
      consumePendingNotificationIntents() async {
    final pending =
        List<EixamNotificationIntent>.unmodifiable(_pendingNotificationIntents);
    _pendingNotificationIntents.clear();
    BleDebugRegistry.instance.recordEvent(
      '[NOTIFICATION_FLOW] sdk_intent_consume count=${pending.length}',
    );
    return pending;
  }

  @override
  Stream<EixamNotificationIntent> watchNotificationIntents() {
    return _notificationIntentController.stream;
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

  void _emitNotificationIntent(EixamNotificationIntent intent) {
    final key = '${intent.type.name}:${intent.dedupeKey}';
    if (_emittedNotificationIntentKeys.contains(key)) {
      return;
    }
    _emittedNotificationIntentKeys.add(key);
    _emittedNotificationIntentKeyOrder.add(key);
    while (_emittedNotificationIntentKeyOrder.length >
        _maxRememberedNotificationIntentKeys) {
      final expiredKey = _emittedNotificationIntentKeyOrder.removeAt(0);
      _emittedNotificationIntentKeys.remove(expiredKey);
    }
    _pendingNotificationIntents.add(intent);
    _trimPendingNotificationIntents();
    if (!_notificationIntentController.isClosed) {
      _notificationIntentController.add(intent);
    }
    BleDebugRegistry.instance.recordEvent(
      '[NOTIFICATION_FLOW] sdk_intent_emit '
      'type=${intent.type.name} dedupeKey=${intent.dedupeKey} '
      'policy=${_notificationPolicyLabel(notificationPolicy)}',
    );
    if (!_sdkSosNotificationsEnabled) {
      BleDebugRegistry.instance.recordEvent(
        '[NOTIFICATION_FLOW] sdk_local_notification_skip '
        'type=${intent.type.name} reason=hostAppManaged',
      );
    }
  }

  void _trimPendingNotificationIntents() {
    final overflow =
        _pendingNotificationIntents.length - _maxPendingNotificationIntents;
    if (overflow > 0) {
      _pendingNotificationIntents.removeRange(0, overflow);
    }
  }

  EixamNotificationIntent _buildNotificationIntent({
    required EixamNotificationIntentType type,
    required String dedupeKey,
    required EixamNotificationIntentSeverity severity,
    String? incidentId,
    String? deviceId,
    String? deviceAlias,
    int? nodeId,
    int? originatorNodeId,
    int? relayNodeId,
    String? titleKey,
    String? bodyKey,
    String? fallbackTitle,
    String? fallbackBody,
    Map<String, String> payload = const <String, String>{},
    bool shouldClearSosNotifications = false,
  }) {
    final createdAt = DateTime.now().toUtc();
    return EixamNotificationIntent(
      id: 'notification-intent-${createdAt.microsecondsSinceEpoch}',
      type: type,
      dedupeKey: dedupeKey,
      createdAt: createdAt,
      severity: severity,
      incidentId: incidentId,
      deviceId: deviceId,
      deviceAlias: deviceAlias,
      nodeId: nodeId,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      titleKey: titleKey,
      bodyKey: bodyKey,
      fallbackTitle: fallbackTitle,
      fallbackBody: fallbackBody,
      payload: payload,
      shouldClearSosNotifications: shouldClearSosNotifications,
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
  Future<ProtectionStatus> getProtectionStatus() async {
    final status = await _protectionModeController.getStatus();
    return _syncDeviceStateFromProtectionStatus(status);
  }

  @override
  Stream<ProtectionStatus> watchProtectionStatus() {
    return _protectionModeController.watchStatus().asyncMap(
          _syncDeviceStateFromProtectionStatus,
        );
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
    await _backlogSyncController.start(
      since: since,
      maxEvents: maxEvents,
    );
    return _backlogSyncController.currentState;
  }

  @override
  Future<void> cancelBacklogSync() async {
    await _backlogSyncController.cancel();
  }

  Future<void> _handleDeviceSosStatus(DeviceSosStatus status) async {
    _emitOperationalDiagnostics();
    _consumePendingAppTriggeredSosBridge(status);
    final deviceOwnedPreSosActivation =
        _preSosSession?.owner == _SosOwner.device &&
            status.state == DeviceSosState.active &&
            status.previousState == DeviceSosState.preConfirm &&
            status.nodeId != null;
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
    final promotedNodeId = _resolveDeviceOriginatedSosNodeId(
      status: status,
      cycleKey: cycleKey,
    );
    if (promotedNodeId != null) {
      _promoteDeviceNodeIdFromSos(
        nodeId: promotedNodeId,
        source: 'device_originated_sos',
      );
    }
    _rememberDeviceRuntimeSosOwnership(status, cycleKey);
    _emitDeviceSosActiveNotificationIntent(status, cycleKey);
    _emitDeviceSosTerminalNotificationIntent(status, cycleKey);

    final isAppOriginatedStatus =
        status.triggerOrigin == DeviceSosTransitionSource.app;
    if ((isAppOriginatedStatus || isCorrelatedAppTriggeredStatus) &&
        !deviceOwnedPreSosActivation) {
      if (status.nodeId != null) {
        _knownLocalDeviceNodeId = status.nodeId;
      }
      BleDebugRegistry.instance.recordEvent(
        isCorrelatedAppTriggeredStatus
            ? 'App-triggered SOS correlation preserved -> incidentId=${_pendingAppTriggeredSosBridge?.incidentId ?? "-"} nodeId=${_formatNodeId(status.nodeId)} state=${status.state.name}'
            : 'App-triggered SOS origin preserved without pending bridge -> nodeId=${_formatNodeId(status.nodeId)} state=${status.state.name}',
      );
      if (_isDeviceSosCycleClosed(status.state) && !_publicSosActionInFlight) {
        final appCycleIncident = await sosRepository.getCurrentIncident();
        if (_hasBackendVisibleSosIncident(appCycleIncident)) {
          BleDebugRegistry.instance.recordEvent(
            'App-triggered SOS device-side closure -> '
            'syncing backend incidentId=${appCycleIncident!.id} '
            'state=${status.state.name}',
          );
          await _applyBackendClosureForAppTriggeredCycle(
            status: status,
            incident: appCycleIncident,
          );
        }
      }
    } else {
      await _synchronizeDeviceOriginatedBackendLifecycle(
        status,
        forceDeviceOwned: deviceOwnedPreSosActivation,
      );
    }

    await _rehydrateDeviceSosPublicState(
      trigger: 'device_sos_status:${status.state.name}',
      deviceStatus: status,
      emitResolvedState: true,
    );

    if (_isSosCycleClosed(status.state)) {
      _applyTerminalSosSuppression(
        reason: 'device_terminal_event:${status.state.name}',
        nodeId: status.nodeId,
      );
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

    if (!_sdkSosNotificationsEnabled) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification skipped -> reason=host_app_managed cycleKey=$cycleKey state=${status.state.name}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[NOTIFICATION_FLOW] sdk_local_notification_skip '
        'type=${_notificationIntentTypeForDeviceSosState(status.state).name} '
        'reason=hostAppManaged',
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
      BleDebugRegistry.instance.recordEvent(
        '[NOTIFICATION_FLOW] sdk_local_notification_show '
        'type=${_notificationIntentTypeForDeviceSosState(status.state).name} '
        'policy=${_notificationPolicyLabel(notificationPolicy)} '
        'channel=eixam_sos_alerts',
      );
      await notificationsRepository.showLocalNotification(
        notificationId: _nextBleNotificationId(),
        title: title,
        body: body,
        payload: payload.toJsonString(),
        actions: const <LocalNotificationAction>[],
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Local BLE notification failed -> kind=sos_received error=$error',
      );
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

  EixamNotificationIntentType _notificationIntentTypeForDeviceSosState(
    DeviceSosState state,
  ) {
    return switch (state) {
      DeviceSosState.preConfirm => EixamNotificationIntentType.preSos,
      DeviceSosState.active ||
      DeviceSosState.acknowledged =>
        EixamNotificationIntentType.sosActive,
      DeviceSosState.resolved => EixamNotificationIntentType.sosResolved,
      DeviceSosState.inactive ||
      DeviceSosState.unknown =>
        EixamNotificationIntentType.sosCancelled,
    };
  }

  bool get _sdkSosNotificationsEnabled =>
      notificationPolicy != EixamNotificationPolicy.hostAppManaged;

  String _notificationPolicyLabel(EixamNotificationPolicy policy) {
    if (policy == EixamNotificationPolicy.hostAppManaged) {
      return 'hostAppManaged';
    }
    if (policy == EixamNotificationPolicy.sdkManaged) {
      return 'sdkManaged';
    }
    return policy.toString();
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

    final nodeId = status.nodeId ??
        _parseDeviceRuntimeNodeId(status.lastPacketSignature) ??
        _parseSosCycleNodeId(status.lastPacketSignature) ??
        _knownLocalDeviceNodeId;
    final localCycleKey = _resolveLocalDeviceRuntimeCycleKey(
      status: status,
      nodeId: nodeId,
    );
    if (localCycleKey != null) {
      return localCycleKey;
    }
    final packetId = status.packetId;

    if (nodeId != null && packetId != null) {
      return 'sos:$nodeId:$packetId';
    }

    if (nodeId != null && status.lastPacketSignature != null) {
      return 'sos:$nodeId:${status.lastPacketSignature}';
    }

    return status.lastPacketSignature;
  }

  String? _resolveLocalDeviceRuntimeCycleKey({
    required DeviceSosStatus status,
    required int? nodeId,
  }) {
    if (nodeId == null || !_isLocalDeviceRuntimeSosStatus(status)) {
      return null;
    }
    final currentLocalCycle = _activeDeviceRuntimeLocalCycleKey;
    if (currentLocalCycle != null &&
        !_isTerminalPublicSosState(_publicSosState)) {
      return currentLocalCycle;
    }
    if (currentLocalCycle != null &&
        _parseSosCycleNodeId(currentLocalCycle) == nodeId &&
        !_isNewLocalActivationAfterTerminal(status)) {
      return currentLocalCycle;
    }
    final supersedesTerminalGuard = _isNewLocalActivationAfterTerminal(status);
    _deviceRuntimeLocalCycleSequence += 1;
    final nextCycle = 'sos:$nodeId:$_deviceRuntimeLocalCycleSequence';
    final previousIncident = _activeDeviceRuntimeIncidentId;
    final previousTerminal = _terminalLabelForPublicSos(_publicSosState);
    _activeDeviceRuntimeLocalCycleKey = nextCycle;
    _activeDeviceRuntimeCycleKey = 'sos-cycle:$nextCycle';
    _activeDeviceRuntimeIncidentId = 'device-runtime-$nextCycle';
    _lastDeviceRuntimeCanonicalIncidentSignature = null;
    _lastDeviceRuntimeCanonicalIncident = null;
    _deviceOwnedBackendIncidentId = null;
    if (supersedesTerminalGuard) {
      BleDebugRegistry.instance.recordEvent(
        '[APP_SOS_RECONCILE] action=clear_terminal_guard_for_new_local_activation '
        'source=BACKGROUND_SOS incidentId=$_activeDeviceRuntimeIncidentId '
        'canonicalIncidentId=$_activeDeviceRuntimeIncidentId '
        'previous_stage=${_publicSosState.name} incoming_stage=active '
        'previous_terminal=$previousTerminal incoming_terminal=open '
        'guardedIds=${previousIncident ?? "none"} '
        'originatorNodeId=$nodeId connectedDeviceNodeId=$nodeId',
      );
      BleDebugRegistry.instance.recordEvent(
        '[APP_SOS_RECONCILE] decision=accept_new_local_activation_after_terminal '
        'reason=local_activation_supersedes_terminal_guard '
        'source=BACKGROUND_SOS incidentId=$_activeDeviceRuntimeIncidentId '
        'canonicalIncidentId=$_activeDeviceRuntimeIncidentId '
        'previous_stage=${_publicSosState.name} incoming_stage=active '
        'previous_terminal=$previousTerminal incoming_terminal=open '
        'guardedIds=${previousIncident ?? "none"} '
        'originatorNodeId=$nodeId connectedDeviceNodeId=$nodeId',
      );
    }
    return nextCycle;
  }

  bool _isLocalDeviceRuntimeSosStatus(DeviceSosStatus status) {
    return status.triggerOrigin == DeviceSosTransitionSource.device ||
        status.transitionSource == DeviceSosTransitionSource.device ||
        _preSosSession?.owner == _SosOwner.device;
  }

  bool _isNewLocalActivationAfterTerminal(DeviceSosStatus status) {
    if (!_isTerminalPublicSosState(_publicSosState)) {
      return false;
    }
    return status.state == DeviceSosState.preConfirm ||
        status.state == DeviceSosState.active ||
        status.state == DeviceSosState.acknowledged;
  }

  String _terminalLabelForPublicSos(SosState state) {
    if (state == SosState.resolved) {
      return 'resolved';
    }
    if (state == SosState.cancelled) {
      return 'cancelled';
    }
    if (state == SosState.idle || state == SosState.failed) {
      return 'idle';
    }
    return 'open';
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
      } catch (error) {
        BleDebugRegistry.instance.recordEvent(
          'Death Man notification action failed -> action=$actionId error=$error',
        );
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
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'BLE command failed from notification action -> action=$actionId error=$error',
      );

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
    await _restorePersistedPreSosSession(trigger: 'startPreSos');
    if (await _settleExpiredPreSosSession(trigger: 'startPreSos')) {
      return;
    }
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
    final canMirrorPreSosOnDevice = runtimeStatus != null;
    final owner = _SosOwner.app;
    _logAppPreSosRouteDecision(
      runtimeStatus: runtimeStatus,
      countdown: countdown,
      decision: canMirrorPreSosOnDevice
          ? 'app_countdown_plus_device_pre_sos'
          : ((_lastDeviceStatus?.connected ?? false)
              ? 'app_countdown_device_path_skip'
              : 'no_ble_pre_sos'),
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_OWNER_SELECTED owner=${owner.name} '
      'reason=${canMirrorPreSosOnDevice ? "connected_pre_sos_device_path" : "app_fallback"} '
      'nodeId=${runtimeStatus?.nodeId?.toString() ?? "-"} '
      'hardwareId=${runtimeStatus?.canonicalHardwareId ?? "-"}',
    );
    if (canMirrorPreSosOnDevice) {
      try {
        BleDebugRegistry.instance.recordEvent(
          '[APP_PRE_SOS_DEVICE_COMMAND] action=attempt '
          'path=ble_inet_sos_trigger countdown=${countdown.inSeconds}',
        );
        final deviceStatus = await triggerDeviceSos();
        mirroredOnDevice = deviceStatus.state == DeviceSosState.preConfirm ||
            deviceStatus.state == DeviceSosState.active;
        BleDebugRegistry.instance.recordEvent(
          '[APP_PRE_SOS_DEVICE_COMMAND] action=sent '
          'path=ble_inet_sos_trigger',
        );
        _syncPreSosSession(
          startedAt: deviceStatus.countdownStartedAt ?? DateTime.now(),
          expectedActivationAt: deviceStatus.expectedActivationAt ??
              DateTime.now().add(countdown),
          mirroredOnDevice: mirroredOnDevice,
          origin: DeviceSosTransitionSource.app,
          owner: owner,
          cycleKey: _preSosCycleKeyFromDeviceStatus(deviceStatus),
          originatorNodeId: deviceStatus.nodeId ?? runtimeStatus.nodeId,
          packetId: deviceStatus.packetId,
        );
        return;
      } catch (error) {
        BleDebugRegistry.instance.recordEvent(
          '[APP_PRE_SOS_DEVICE_COMMAND] action=skip '
          'reason=send_failed bleConnected=true cmd=${deviceSosController.longCommandAvailable} '
          'inet_continues=true error=${_compactDiagnosticValue(error)}',
        );
      }
    } else {
      BleDebugRegistry.instance.recordEvent(
        '[APP_PRE_SOS_DEVICE_COMMAND] action=skip '
        'reason=${(_lastDeviceStatus?.connected ?? false) ? "pre_sos_device_path_unavailable" : "no_ble"} '
        'bleConnected=${_lastDeviceStatus?.connected ?? false} '
        'cmd=${deviceSosController.longCommandAvailable} '
        'inet_continues=true',
      );
    }

    final startedAt = DateTime.now();
    _syncPreSosSession(
      startedAt: startedAt,
      expectedActivationAt: startedAt.add(countdown),
      mirroredOnDevice: mirroredOnDevice,
      origin: DeviceSosTransitionSource.app,
      owner: owner,
      cycleKey: _newLocalPreSosCycleKey(startedAt),
      originatorNodeId: runtimeStatus?.nodeId,
      packetId: null,
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
    final previousClosureInFlight = _publicSosClosureInFlight;
    _publicSosClosureInFlight = _SosClosureIntent.cancel;
    try {
      final status = await deviceSosController.getStatus();
      final activeSession = _preSosSession;
      final runtimeStatus = await _loadRuntimeReadyDeviceStatusForSosSync(
        action: 'cancel_pre_sos',
        refreshRuntimeStatus: true,
      );
      final capabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
        reason: 'cancel_pre_sos_decision',
        statusOverride: runtimeStatus,
      );
      final deviceConnected = capabilitySnapshot.deviceConnected;
      final commandAvailable = capabilitySnapshot.shortCommandAvailable ||
          capabilitySnapshot.longCommandAvailable;
      final stageIsArming = _publicSosState == SosState.arming;
      final protectionStatus = _protectionModeController.currentStatus;
      final protectionActive =
          protectionStatus.modeState == ProtectionModeState.armed ||
              protectionStatus.runtimeState == ProtectionRuntimeState.active;
      final deviceOwnedCountdown = status.state == DeviceSosState.preConfirm ||
          activeSession?.mirroredOnDevice == true ||
          activeSession?.owner == _SosOwner.device ||
          activeSession?.origin == DeviceSosTransitionSource.device ||
          stageIsArming;
      final hasIncidentId =
          _hasBackendVisibleSosIncident(_lastKnownActiveSosIncident) ||
              _hasBackendVisibleSosIncident(_publicSosFallbackIncident);
      final deviceId = runtimeStatus?.nodeId?.toString() ??
          _lastDeviceStatus?.nodeId?.toString() ??
          runtimeStatus?.deviceId ??
          _lastDeviceStatus?.deviceId ??
          '-';
      final cancelDecision = deviceConnected && commandAvailable
          ? 'send_device_cancel'
          : 'local_only_cancel';
      BleDebugRegistry.instance.recordEvent(
        '[APP_PRE_SOS_CANCEL] action=clear_requested source=cancelPreSos '
        'cycle=${activeSession?.cycleRevision ?? _preSosCycleRevision} '
        'countdown=${_buildCurrentPreSosStatus()?.remainingSeconds.toString() ?? "none"} '
        'deadline=${activeSession?.expectedActivationAt.toUtc().toIso8601String() ?? "none"}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[APP_PRE_SOS_CANCEL] action=cancel_pre_sos '
        'stage=${_publicSosState.name} '
        'deviceConnected=$deviceConnected '
        'commandAvailable=$commandAvailable '
        'deviceId=$deviceId '
        'hasIncidentId=$hasIncidentId '
        'deviceOwnedCountdown=$deviceOwnedCountdown '
        'protectionMode=${protectionStatus.modeState.name} '
        'runtimeMode=${protectionStatus.runtimeState.name} '
        'protectionActive=$protectionActive '
        'decision=$cancelDecision',
      );
      if (cancelDecision == 'send_device_cancel') {
        try {
          BleDebugRegistry.instance.recordEvent(
            '[APP_PRE_SOS_DEVICE_COMMAND] action=attempt '
            'path=ble_pre_sos_cancel countdown=0',
          );
          await _closeDeviceSos(
            intent: _SosClosureIntent.cancel,
            syncBackendForDeviceOriginatedCycle: false,
            waitForDeviceAcknowledgement: false,
          );
          BleDebugRegistry.instance.recordEvent(
            '[APP_PRE_SOS_DEVICE_COMMAND] action=sent '
            'path=ble_pre_sos_cancel',
          );
          BleDebugRegistry.instance.recordEvent(
            '[APP_PRE_SOS_CANCEL] action=cancel_pre_sos '
            'decision=send_device_cancel result=device_cancel_dispatched',
          );
        } catch (error) {
          BleDebugRegistry.instance.recordEvent(
            '[APP_PRE_SOS_DEVICE_COMMAND] action=skip '
            'reason=cancel_failed bleConnected=${_lastDeviceStatus?.connected ?? false} '
            'cmd=${deviceSosController.longCommandAvailable} '
            'inet_continues=true error=${_compactDiagnosticValue(error)}',
          );
          BleDebugRegistry.instance.recordEvent(
            '[APP_PRE_SOS_CANCEL] action=cancel_pre_sos '
            'decision=send_device_cancel result=device_cancel_failed '
            'error=${_compactDiagnosticValue(error)}',
          );
          rethrow;
        }
      }
      if (status.state == DeviceSosState.preConfirm) {
        deviceSosController.clearPreSosLocally(reason: 'app_cancel_pre_sos');
      }
      _clearPreSosSession(
        reason: 'public_pre_sos_cancelled',
        emitIdleState: true,
      );
      BleDebugRegistry.instance.recordEvent(
        '[APP_PRE_SOS_CANCEL] action=cancel_pre_sos '
        'decision=$cancelDecision result=local_state_cleared',
      );
    } finally {
      _publicSosClosureInFlight = previousClosureInFlight;
    }
  }

  @override
  Future<PublicPreSosStatus?> getPreSosStatus() async {
    await _syncPreSosSessionFromProtectionPlatformSnapshot(
      trigger: 'getPreSosStatus',
    );
    await _restorePersistedPreSosSession(trigger: 'getPreSosStatus');
    final deviceStatus = await deviceSosController.getStatus();
    await _rehydrateDeviceSosPublicState(
      trigger: 'getPreSosStatus',
      deviceStatus: deviceStatus,
      emitResolvedState: false,
    );
    if (await _settleExpiredPreSosSession(trigger: 'getPreSosStatus')) {
      return null;
    }
    final current = _buildCurrentPreSosStatus();
    if (current != null) {
      return current;
    }
    if (_shouldKeepSdkPreSosArmingState(
      incoming: SosState.idle,
      source: 'get_pre_sos_status',
    )) {
      _logSosRuntimePrecedence(
        incomingSource: 'get_pre_sos_status',
        incoming: SosState.idle,
        decision: 'keep_sdk_pre_sos_arming',
        reason: _runtimePrecedenceKeepReason(),
      );
      return _lastPublishedPreSosStatus;
    }
    return null;
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
    bool allowDeviceRuntimeActiveShortCircuit = true,
  }) async {
    if (allowDeviceRuntimeActiveShortCircuit &&
        await _deviceRuntimeSosAlreadyActive()) {
      BleDebugRegistry.instance.recordEvent(
        'APP_SOS_COUNTDOWN_ZERO_BACKEND_REQUIRED '
        'reason=device_runtime_sos_already_active '
        'activeCycle=${_activeDeviceRuntimeCycleKey ?? _activeDeviceSosCycleKey ?? "-"}',
      );
    }
    _publicSosActionInFlight = true;
    try {
      final positionSnapshot = await _loadPositionSnapshotForSos();
      final metadata = _buildOperationalSosMetadata();
      final capabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
        reason: 'trigger_sos_start',
      );
      BleDebugRegistry.instance.recordEvent(
        'triggerSos() start -> backendAvailable=${capabilitySnapshot.backendAvailable} cachedDeviceConnected=${_lastDeviceStatus?.connected} shortCommandAvailable=${capabilitySnapshot.shortCommandAvailable} longCommandAvailable=${capabilitySnapshot.longCommandAvailable} currentCapability=${capabilitySnapshot.capability?.name ?? "unavailable"} activeOwner=$_currentDeviceCommandOwnerRoute',
      );
      _emitPublicSosState(
        SosState.sending,
        source: 'public_sos_backend_publish_start',
      );
      _logAppSosRouteDecision(
        action: 'trigger',
        capabilitySnapshot: capabilitySnapshot,
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
      final identity = await _resolveLocalOperationalSosIdentity();
      final identitySource = _sosIdentitySourceFor(identity);
      if (!_loggedBackgroundSosPublishTraceV2) {
        _loggedBackgroundSosPublishTraceV2 = true;
        BleDebugRegistry.instance.recordEvent(
          '[BACKGROUND_SOS] diagnostics_version=sos_backend_publish_trace_v2',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_requested state=sent '
        'diagnostics_version=sos_backend_publish_trace_v3_actual_line '
        'before_requested=true occurrence=1',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_requested state=sent '
        'route=sosRepository.triggerSos '
        'deviceId=${identity.deviceId ?? "none"} '
        'nodeId=${identity.originatorNodeId?.toString() ?? "none"} '
        'hardwareId=${identity.hardwareId ?? "none"} '
        'identitySource=$identitySource '
        'commandAvailable=${deviceSync.available}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_requested state=sent '
        'diagnostics_version=sos_backend_publish_trace_v3_actual_line '
        'after_requested=true occurrence=1',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] diagnostics_version=sos_backend_publish_trace_v3_actual_line '
        'function=_activatePublicSos file=eixam_connect_sdk_impl.dart '
        'occurrence=1',
      );
      BleDebugRegistry.instance.recordEvent(
        '[BACKGROUND_SOS] backend_publish_payload identity '
        'deviceId=${identity.deviceId ?? "none"} '
        'nodeId=${identity.originatorNodeId?.toString() ?? "none"} '
        'hardwareId=${identity.hardwareId ?? "none"} '
        'userId=${_session?.canonicalExternalUserId ?? _session?.sdkUserId ?? "none"} '
        'hasLocation=${positionSnapshot != null}',
      );

      SosIncident? backendIncident;
      Object? backendError;
      final backendPublishStopwatch = Stopwatch()..start();
      try {
        BleDebugRegistry.instance.recordEvent(
          '[BACKGROUND_SOS] backend_publish_call_start state=sent '
          'incidentId=none '
          'deviceId=${identity.deviceId ?? "none"} '
          'nodeId=${identity.originatorNodeId?.toString() ?? "none"} '
          'hardwareId=${identity.hardwareId ?? "none"} '
          'identitySource=$identitySource',
        );
        final publishedIncident = await sosRepository.triggerSos(
          message: payload.message,
          triggerSource: payload.triggerSource,
          positionSnapshot: positionSnapshot,
          deviceId: identity.deviceId,
          hardwareId: identity.hardwareId,
          originatorNodeId: identity.originatorNodeId,
          deviceBattery: metadata.deviceBattery,
          deviceCoverage: metadata.deviceCoverage,
          mobileBattery: metadata.mobileBattery,
          mobileCoverage: metadata.mobileCoverage,
        );
        BleDebugRegistry.instance.recordEvent(
          '[BACKGROUND_SOS] backend_publish_call_returned state=sent '
          'resultType=${publishedIncident.runtimeType} '
          'result=${_compactDiagnosticValue('id=${publishedIncident.id} state=${publishedIncident.state.name} delivery=${publishedIncident.deliveryChannel?.name ?? "none"}')}',
        );
        backendIncident = publishedIncident;
        final backendIncidentId = _isLocalAppSosIncidentId(publishedIncident.id)
            ? 'none'
            : publishedIncident.id;
        BleDebugRegistry.instance.recordEvent(
          '[BACKGROUND_SOS] backend_publish_succeeded state=sent '
          'backendIncidentId=$backendIncidentId '
          'httpStatus=not_available '
          'localIncidentId=${publishedIncident.id} '
          'deviceId=${identity.deviceId ?? "none"} '
          'nodeId=${identity.originatorNodeId?.toString() ?? "none"} '
          'hardwareId=${identity.hardwareId ?? "none"} '
          'identitySource=$identitySource '
          'backendConfirmation=${backendIncidentId == "none" ? "not_confirmed" : "confirmed"}',
        );
        if (backendIncidentId == 'none') {
          BleDebugRegistry.instance.recordEvent(
            '[BACKGROUND_SOS] local_incident_created state=sent '
            'localIncidentId=${publishedIncident.id} '
            'reason=repository_returned_local_runtime_incident '
            'backendIncidentId=none',
          );
        }
      } catch (error) {
        backendError = error;
        BleDebugRegistry.instance.recordEvent(
          'Public SOS backend trigger failed -> error=$error',
        );
        BleDebugRegistry.instance.recordEvent(
          '[BACKGROUND_SOS] backend_publish_failed state=sent '
          'errorType=${error.runtimeType} '
          'message=${_compactDiagnosticValue(_errorMessageFor(error))} '
          'httpStatus=${_httpStatusForError(error)} '
          'responseBody=${_responseBodyForError(error)} '
          'endpoint=sosRepository.triggerSos '
          'deviceId=${identity.deviceId ?? "none"} '
          'nodeId=${identity.originatorNodeId?.toString() ?? "none"} '
          'hardwareId=${identity.hardwareId ?? "none"} '
          'identitySource=$identitySource',
        );
      } finally {
        backendPublishStopwatch.stop();
        BleDebugRegistry.instance.recordEvent(
          '[BACKGROUND_SOS] backend_publish_finally state=sent '
          'elapsedMs=${backendPublishStopwatch.elapsedMilliseconds}',
        );
      }

      final deliveryChannel = _resolveSuccessfulSosDeliveryChannel(
        backendSucceeded: backendIncident != null,
        deviceSucceeded: deviceSync.succeeded,
      );
      BleDebugRegistry.instance.recordEvent(
        'triggerSos() channel decision -> backendSucceeded=${backendIncident != null} deviceAvailable=${deviceSync.available} deviceAttempted=${deviceSync.attempted} deviceSucceeded=${deviceSync.succeeded} activeOwner=$_currentDeviceCommandOwnerRoute delivery=${deliveryChannel?.name ?? "-"}',
      );
      _logAppSosRouteDecision(
        action: 'trigger',
        capabilitySnapshot: capabilitySnapshot,
      );
      if (backendIncident == null) {
        BleDebugRegistry.instance.recordEvent(
          '[BACKGROUND_SOS] backend_required_failed '
          'deviceAvailable=${deviceSync.available} '
          'deviceAttempted=${deviceSync.attempted} '
          'deviceSucceeded=${deviceSync.succeeded} '
          'reason=no_backend_incident',
        );
        final alreadyActiveBackendError = backendError is SosException &&
            backendError.code == 'E_SOS_ALREADY_ACTIVE';
        if (!alreadyActiveBackendError) {
          _clearPendingAppTriggeredSosBridge(
            reason: 'public_trigger_backend_failed',
          );
          _clearDeviceRuntimeSosOwnership(
            reason: 'public_trigger_backend_failed',
          );
          _publicSosFallbackIncident = null;
          _emitPublicSosState(
            SosState.failed,
            source: 'public_sos_backend_failed',
          );
        }
        _throwTriggerSosFailure(
          backendError: backendError,
          backendUnavailable: _isBackendUnavailableForTrigger(backendError),
          deviceAvailable: deviceSync.available,
        );
      }
      if (deliveryChannel == null ||
          deliveryChannel == SosDeliveryChannel.deviceOnly) {
        _throwTriggerSosFailure(
          backendError: backendError,
          backendUnavailable: _isBackendUnavailableForTrigger(backendError),
          deviceAvailable: deviceSync.available,
        );
      }

      final incident = backendIncident.copyWith(
        deliveryChannel: deliveryChannel,
        state: _promotePostTriggerSosState(backendIncident.state),
      );
      _recordPublicSosResult(
        incident: incident,
        deliveryChannel: deliveryChannel,
      );
      _emitSosActiveNotificationIntent(incident);
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
    final session = _preSosSession;
    var deviceStatus = await deviceSosController.getStatus();
    if (session != null &&
        _isPreSosSessionExpired(session) &&
        deviceStatus.state == DeviceSosState.preConfirm) {
      deviceStatus = deviceSosController.settleExpiredPreConfirmCountdown(
        reason: 'sdk_pre_sos_deadline',
      );
    }
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

    if (session?.owner == _SosOwner.device) {
      if (appMirroredPreConfirm || deviceOriginatedPreConfirm) {
        final confirmedStatus = await deviceSosController.confirmSos(
          commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
          commandRouteLabel: _currentDeviceCommandOwnerRoute,
        );
        await _ensureBackendSosForDeviceOriginatedCycle(
          confirmedStatus,
          triggerSource: 'ble_device_runtime_confirm',
          message: 'Device-owned SOS confirmed and promoted to backend sync.',
        );
      } else if (deviceAlreadyActive) {
        await _ensureBackendSosForDeviceOriginatedCycle(
          deviceStatus,
          triggerSource: 'ble_device_runtime_countdown_elapsed',
          message:
              'Device-owned SOS countdown elapsed and was promoted to backend sync.',
          forceDeviceOwned: true,
        );
      }
      _clearPreSosSession(
        reason: 'public_pre_sos_confirmed_device_owned',
        emitIdleState: false,
      );
      final incident = await getCurrentSosIncident();
      if (_hasNonRuntimeVisibleSosIncident(incident)) {
        return incident!.copyWith(
          deliveryChannel: SosDeliveryChannel.backendAndDevice,
        );
      }
      if (deviceAlreadyActive) {
        return _activatePublicSos(
          payload,
          skipDeviceAction: true,
          deviceAlreadyActive: true,
          allowDeviceRuntimeActiveShortCircuit: false,
        );
      }
      return _activatePublicSos(
        payload,
        skipDeviceAction: true,
        deviceAlreadyActive: true,
        allowDeviceRuntimeActiveShortCircuit: false,
      );
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
        allowDeviceRuntimeActiveShortCircuit: false,
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
      if (!_hasNonRuntimeVisibleSosIncident(incident)) {
        await _ensureBackendSosForDeviceOriginatedCycle(
          confirmedStatus,
          triggerSource: 'ble_device_runtime_confirm',
          message:
              'Device-originated SOS confirmed from the app and promoted to backend sync.',
        );
        incident = await getCurrentSosIncident();
      }
      if (_hasNonRuntimeVisibleSosIncident(incident)) {
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
        allowDeviceRuntimeActiveShortCircuit: false,
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
        allowDeviceRuntimeActiveShortCircuit: false,
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
    final repositoryIncident = await sosRepository.getCurrentIncident();
    if (_isAcknowledgedTerminalSosIncident(repositoryIncident)) {
      return null;
    }
    final incident =
        _decorateIncidentWithPublicDeliveryChannel(repositoryIncident);
    final rememberedIncident = _preserveActiveIncidentWhenMissing(
      incident,
      source: 'get_current_sos_incident',
    );
    final deviceDerivedIncident =
        _buildDeviceRuntimePublicSosIncident(deviceStatus);
    if (_shouldSuppressDeviceRuntimePublicIncident(
      deviceDerivedIncident,
      backendIncident: rememberedIncident,
      source: 'get_current_sos_incident',
    )) {
      return _guardDeviceOwnedCanonicalIncident(
        rememberedIncident,
        source: 'get_current_sos_incident',
      );
    }
    if (deviceDerivedIncident != null) {
      _rememberDeviceRuntimeSosOwnership(
        deviceStatus,
        _deriveDeviceSosCycleKey(deviceStatus),
      );
    }
    if (deviceDerivedIncident != null &&
        _hasActiveDeviceRuntimeSosOwnership() &&
        rememberedIncident != null &&
        _isLocalAppSosIncidentId(rememberedIncident.id) &&
        !_isDeviceOwnedBackendIncidentId(rememberedIncident.id)) {
      _logSosRejectionThrottled(
        cycleId: _activeDeviceRuntimeCycleKey ??
            _deriveDeviceSosCycleKey(deviceStatus) ??
            deviceDerivedIncident.id,
        source: 'get_current_sos_incident',
        reason: 'duplicate_device_owned_sos',
        message: 'SOS_BACKEND_PUBLISH_SKIPPED reason=duplicate_owner '
            'owner=device source=get_current_sos_incident '
            'incomingIncident=${rememberedIncident.id} '
            'activeIncident=${deviceDerivedIncident.id}',
      );
      return deviceDerivedIncident;
    }
    if (rememberedIncident == null &&
        _hasOpenDeviceRuntimeSosInvariant() &&
        _canSurfaceDeviceRuntimeOpenSos()) {
      _logDeviceRuntimeInvariantPreserved(
        source: 'repository_load:runtime_current',
        rejectedState: SosState.idle,
        preservedState: _deviceRuntimeInvariantFallbackState(),
      );
      return _activeDeviceRuntimeFallbackIncident();
    }
    return _guardDeviceOwnedCanonicalIncident(
      rememberedIncident,
      source: 'get_current_sos_incident',
    );
  }

  @override
  Future<SosIncident> cancelSos() async {
    _publicSosActionInFlight = true;
    final previousClosureInFlight = _publicSosClosureInFlight;
    _publicSosClosureInFlight = _SosClosureIntent.cancel;
    try {
      final deviceStatus = await deviceSosController.getStatus();
      if (_hasActivePreSosSession ||
          _publicSosState == SosState.arming ||
          (deviceStatus.state == DeviceSosState.preConfirm &&
              !_isOpenSosState(_publicSosState))) {
        await cancelPreSos();
        return SosIncident(
          id: 'pre-sos-cancelled:${DateTime.now().toUtc().microsecondsSinceEpoch}',
          state: SosState.cancelled,
          createdAt: DateTime.now().toUtc(),
          triggerSource: 'pre_sos_cancel',
        );
      }
      final activeIncident = await getCurrentSosIncident();
      final cancellableIncident = activeIncident ?? _lastKnownActiveSosIncident;
      if (cancellableIncident == null &&
          _isOpenSosState(_publicSosState) &&
          !_canCloseDeviceSosForPublicSos(deviceStatus)) {
        BleDebugRegistry.instance.recordEvent(
          '[SOS_CANCEL] action=blocked reason=missing_incident_id '
          'stage=${_publicSosState.name} terminal=open',
        );
        throw const SosException(
          'E_SOS_CANCEL_MISSING_INCIDENT_ID',
          'An active SOS cannot be cancelled because no incident id is available.',
        );
      }
      _rememberDeviceOriginatedClosureIntent(
        incident: cancellableIncident,
        intent: _SosClosureIntent.cancel,
      );
      final fallbackDeliveryChannel =
          _publicSosFallbackIncident?.deliveryChannel;
      final cancelCapabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
        reason: 'cancel_sos_start',
      );
      _logAppSosRouteDecision(
        action: 'cancel',
        capabilitySnapshot: cancelCapabilitySnapshot,
      );
      final deviceSync = await _attemptPublicSosDeviceAction(
        action: 'cancel',
        shouldRun: (status) => _shouldCloseDeviceForPublicSos(
          status,
          activeIncident: activeIncident,
        ),
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
      _logAppSosRouteDecision(
        action: 'cancel',
        capabilitySnapshot: cancelCapabilitySnapshot,
      );
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
      _applyTerminalSosSuppression(reason: 'public_cancel_completed');
      await _clearSosNotificationsSafely(reason: 'public_cancel_completed');
      _recordPublicSosResult(
        incident: incident,
        deliveryChannel: deliveryChannel,
        fallbackState: backendIncident == null ? SosState.cancelled : null,
      );
      _clearCurrentPublicSosAfterCancellation(incident);
      _emitSosTerminalNotificationIntent(
        incident,
        type: EixamNotificationIntentType.sosCancelled,
        severity: EixamNotificationIntentSeverity.info,
        titleKey: 'notification.sos.cancelled.title',
        bodyKey: 'notification.sos.cancelled.body',
        fallbackTitle: 'SOS cancelled',
        fallbackBody: 'The SOS has been cancelled.',
      );
      _clearPendingAppTriggeredSosBridge(reason: 'public_cancel_completed');
      _publishCancelledSosEventIfNeeded(incident);
      return incident;
    } finally {
      _publicSosClosureInFlight = previousClosureInFlight;
      _publicSosActionInFlight = false;
    }
  }

  @override
  Future<void> resolveSos() async {
    _publicSosActionInFlight = true;
    final previousClosureInFlight = _publicSosClosureInFlight;
    _publicSosClosureInFlight = _SosClosureIntent.resolve;
    try {
      if (_hasActivePreSosSession ||
          (await deviceSosController.getStatus()).state ==
              DeviceSosState.preConfirm) {
        await confirmPreSos(const SosTriggerPayload());
      }
      final activeIncident = await sosRepository.getCurrentIncident();
      _rememberDeviceOriginatedClosureIntent(
        incident: activeIncident,
        intent: _SosClosureIntent.resolve,
      );
      final deviceSync = await _attemptPublicSosDeviceAction(
        action: 'resolve',
        shouldRun: (status) => _shouldCloseDeviceForPublicSos(
          status,
          activeIncident: activeIncident,
        ),
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
      _applyTerminalSosSuppression(reason: 'public_resolve_completed');
      await _clearSosNotificationsSafely(reason: 'public_resolve_completed');
      _recordPublicSosResult(
        incident: incident,
        deliveryChannel: deliveryChannel,
        fallbackState: backendIncident == null ? SosState.resolved : null,
      );
      _emitSosTerminalNotificationIntent(
        incident,
        type: EixamNotificationIntentType.sosResolved,
        severity: EixamNotificationIntentSeverity.success,
        titleKey: 'notification.sos.resolved.title',
        bodyKey: 'notification.sos.resolved.body',
        fallbackTitle: 'SOS resolved',
        fallbackBody: 'The SOS has been resolved.',
      );
      _clearPendingAppTriggeredSosBridge(reason: 'public_resolve_completed');
    } finally {
      _publicSosClosureInFlight = previousClosureInFlight;
      _publicSosActionInFlight = false;
    }
  }

  @override
  Future<SosState> acknowledgeSosSummary() async {
    final repositoryIncident = await sosRepository.getCurrentIncident();
    final terminalIncident = _publicSosFallbackIncident ??
        (_isTerminalBackendSosIncident(repositoryIncident)
            ? repositoryIncident
            : null);
    _rememberAcknowledgedTerminalSosIncident(terminalIncident);
    _clearPreSosSession(
      reason: 'terminal_summary_acknowledged',
      emitIdleState: false,
    );
    _publicSosFallbackIncident = null;
    _lastKnownActiveSosIncident = null;
    _clearDeviceRuntimeSosOwnership(reason: 'terminal_summary_acknowledged');
    _clearPendingAppTriggeredSosBridge(reason: 'terminal_summary_acknowledged');
    _emitPublicSosState(SosState.idle, source: 'terminal_summary_acknowledged');
    _emitOperationalDiagnostics();
    BleDebugRegistry.instance.recordEvent(
      '[SOS_SUMMARY_ACK] action=acknowledge '
      'incidentId=${terminalIncident?.id ?? 'none'} state=idle',
    );
    return SosState.idle;
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

  Future<_OperationalSosIdentity> _resolveLocalOperationalSosIdentity() async {
    final status =
        _lastDeviceStatus ?? await deviceRepository.getDeviceStatus();
    _lastDeviceStatus = status;
    final originatorNodeId = status.nodeId ?? _knownLocalDeviceNodeId;
    if (originatorNodeId != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_BACKEND_IDENTITY_RESOLVED deviceId=${originatorNodeId.toString()} '
        'originatorNodeId=$originatorNodeId '
        'hardwareId=${status.canonicalHardwareId ?? "-"} '
        'identitySource=ble_node source=local_sos owner=device',
      );
      return _OperationalSosIdentity(
        deviceId: originatorNodeId.toString(),
        hardwareId: status.canonicalHardwareId,
        originatorNodeId: originatorNodeId,
      );
    }
    final hardwareId = status.connected ? status.canonicalHardwareId : null;
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_IDENTITY_RESOLVED deviceId=none '
      'originatorNodeId=none '
      'hardwareId=${hardwareId ?? "-"} '
      'identitySource=${hardwareId == null ? "app" : "device_hardware_pending"} '
      'source=local_sos owner=app',
    );
    return _OperationalSosIdentity(
      deviceId: null,
      hardwareId: hardwareId,
    );
  }

  String _sosIdentitySourceFor(_OperationalSosIdentity identity) {
    if (identity.originatorNodeId != null) {
      return 'ble_node';
    }
    if (identity.hardwareId != null && identity.hardwareId!.trim().isNotEmpty) {
      return 'device_hardware_pending';
    }
    return 'app';
  }

  String _httpStatusForError(Object error) {
    return error is SosHttpException ? error.statusCode.toString() : 'none';
  }

  String _responseBodyForError(Object error) {
    if (error is SosHttpException) {
      return _compactDiagnosticValue(error.message);
    }
    return 'none';
  }

  String _errorMessageFor(Object error) {
    if (error is EixamSdkException) {
      return error.message;
    }
    return error.toString();
  }

  String _compactDiagnosticValue(Object? value) {
    final summary = value.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (summary.isEmpty) {
      return 'none';
    }
    return summary.length <= 240 ? summary : '${summary.substring(0, 240)}...';
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
    var status = _lastDeviceStatus;
    final hardwareId = await _loadBackendHardwareIdForOperationalPayloads(
      runtimeStatus: status,
    );
    status = _lastDeviceStatus;
    final nodeId = payload.nodeId ?? status?.nodeId ?? _knownLocalDeviceNodeId;
    if (nodeId == null && isBleMacDeviceId(payload.deviceId ?? hardwareId)) {
      BleDebugRegistry.instance.recordEvent(
        'TELEMETRY_BACKEND_NODE_ID_UNAVAILABLE '
        'hardwareId=${payload.deviceId ?? hardwareId ?? "-"} action=fallback',
      );
    }
    final identity = normalizeTelemetryBackendIdentity(
      payload: payload.copyWith(
        nodeId: nodeId,
        hardwareId: payload.hardwareId ?? hardwareId,
      ),
      hardwareId: hardwareId,
    );
    if (identity.normalized) {
      BleDebugRegistry.instance.recordEvent(
        'BACKEND_DEVICE_ID_NORMALIZED '
        'previousDeviceId=${identity.previousDeviceId} '
        'normalizedDeviceId=${identity.payload.deviceId} source=telemetry',
      );
    }
    if (identity.invalidDeviceId) {
      BleDebugRegistry.instance.recordEvent(
        'BACKEND_DEVICE_ID_INVALID '
        'invalidBackendDeviceId=${identity.previousDeviceId} source=telemetry',
      );
    }

    return identity.payload.copyWith(
      userId: null,
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
    BleDebugRegistry.instance.recordEvent(
      'Public SOS device sync evaluated -> action=$action commandPathAvailable=true deviceId=${runtimeStatus.nodeId?.toString() ?? "-"} nodeId=${runtimeStatus.nodeId?.toString() ?? "-"} hardwareId=${runtimeStatus.deviceId} state=${deviceSosStatus.state.name} origin=${deviceSosStatus.triggerOrigin.name} optimistic=${deviceSosStatus.optimistic} derivedFromBle=${deviceSosStatus.derivedFromBlePacket}',
    );
    if (!shouldRun(deviceSosStatus)) {
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync skipped -> action=$action reason=state_already_converged state=${deviceSosStatus.state.name} origin=${deviceSosStatus.triggerOrigin.name} deviceId=${runtimeStatus.nodeId?.toString() ?? "-"} hardwareId=${runtimeStatus.deviceId} commandPathAvailable=true',
      );
      return const _PublicSosDeviceAttempt(
        available: true,
        attempted: false,
        succeeded: false,
      );
    }

    try {
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync attempting -> action=$action deviceId=${runtimeStatus.nodeId?.toString() ?? "-"} hardwareId=${runtimeStatus.deviceId} route=$_currentDeviceCommandOwnerRoute state=${deviceSosStatus.state.name} commandPathAvailable=true',
      );
      await operation();
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync succeeded -> action=$action deviceId=${runtimeStatus.nodeId?.toString() ?? "-"} hardwareId=${runtimeStatus.deviceId} route=$_currentDeviceCommandOwnerRoute',
      );
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
        'Public SOS device sync failed -> action=$action error=$error deviceId=${runtimeStatus.nodeId?.toString() ?? "-"} hardwareId=${runtimeStatus.deviceId} route=$_currentDeviceCommandOwnerRoute',
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
      final deviceSosStatus = await deviceSosController.getStatus();
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync command path availability -> action=$action deviceConnected=${capabilitySnapshot.deviceConnected} shortCommandAvailable=${capabilitySnapshot.shortCommandAvailable} longCommandAvailable=${capabilitySnapshot.longCommandAvailable} activeOwner=$_currentDeviceCommandOwnerRoute cachedDeviceSosState=${deviceSosStatus.state.name} cachedDeviceSosOrigin=${deviceSosStatus.triggerOrigin.name}',
      );

      if (!capabilitySnapshot.deviceConnected) {
        BleDebugRegistry.instance.recordEvent(
          'Public SOS device sync skipped -> action=$action reason=device_not_connected lifecycle=${status.lifecycleState.name} flutterConnected=${status.connected} protectionConnected=${capabilitySnapshot.serviceBleConnected ?? false} protectionReady=${capabilitySnapshot.serviceBleReady ?? false} paired=${status.paired} activated=${status.activated} cachedDeviceSosState=${deviceSosStatus.state.name}',
        );
        return null;
      }

      if ((action == 'trigger' || action == 'pre_sos_start') &&
          status.nodeId == null) {
        if (action == 'pre_sos_start' &&
            capabilitySnapshot.shortCommandAvailable) {
          return status;
        }
        if (!capabilitySnapshot.shortCommandAvailable) {
          BleDebugRegistry.instance.recordEvent(
            '[APP_PRE_SOS_DEVICE_COMMAND] action=skip '
            'reason=cmd_not_ready inet_continues=true '
            'bleConnected=${capabilitySnapshot.deviceConnected} '
            'cmd=${capabilitySnapshot.longCommandAvailable}',
          );
        }
        BleDebugRegistry.instance.recordEvent(
          'Public SOS device sync skipped -> action=$action '
          'reason=missing_node_id deviceId=none nodeId=none '
          'hardwareId=${status.canonicalHardwareId ?? status.deviceId}',
        );
        return null;
      }

      final terminalAction = action == 'cancel' ||
          action == 'resolve' ||
          action == 'cancel_pre_sos';
      if (!capabilitySnapshot.shortCommandAvailable && !terminalAction) {
        BleDebugRegistry.instance.recordEvent(
          '[APP_SOS_DEVICE_COMMAND] action=skip '
          'reason=cmd_not_ready inet_continues=true '
          'flow=$action bleConnected=${capabilitySnapshot.deviceConnected} '
          'nodeId=${status.nodeId?.toString() ?? "none"} '
          'hardwareId=${status.canonicalHardwareId ?? status.deviceId}',
        );
        BleDebugRegistry.instance.recordEvent(
          'Public SOS device sync skipped -> action=$action reason=sos_command_path_unavailable hardwareId=${status.deviceId} activeOwner=$_currentDeviceCommandOwnerRoute cachedDeviceSosState=${deviceSosStatus.state.name}',
        );
        return null;
      }
      if (!capabilitySnapshot.shortCommandAvailable &&
          !capabilitySnapshot.longCommandAvailable) {
        BleDebugRegistry.instance.recordEvent(
          '[APP_SOS_DEVICE_COMMAND] action=skip '
          'reason=cmd_not_ready inet_continues=true '
          'flow=$action bleConnected=${capabilitySnapshot.deviceConnected} '
          'nodeId=${status.nodeId?.toString() ?? "none"} '
          'hardwareId=${status.canonicalHardwareId ?? status.deviceId}',
        );
        BleDebugRegistry.instance.recordEvent(
          'SOS_TRACE device_terminal_command_queued reason=no_command_characteristic_ready',
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

  void _logAppSosRouteDecision({
    required String action,
    required _CurrentSosCapabilitySnapshot capabilitySnapshot,
  }) {
    final inet = capabilitySnapshot.backendAvailable;
    final bleConnected = capabilitySnapshot.deviceConnected;
    final cmd = capabilitySnapshot.shortCommandAvailable;
    final decision = inet
        ? (bleConnected
            ? (cmd ? 'inet_plus_cmd' : 'inet_only_cmd_skip')
            : 'inet_only_no_ble')
        : (cmd ? 'cmd_only' : 'unavailable');
    BleDebugRegistry.instance.recordEvent(
      '[APP_SOS_ROUTE] origin=app action=$action '
      'inet=$inet bleConnected=$bleConnected cmd=$cmd '
      'decision=$decision',
    );
  }

  void _logAppPreSosRouteDecision({
    required DeviceStatus? runtimeStatus,
    required Duration countdown,
    required String decision,
  }) {
    final bleConnected =
        runtimeStatus?.connected ?? _lastDeviceStatus?.connected ?? false;
    final shortPath = deviceSosController.shortCommandAvailable;
    final longPath = deviceSosController.longCommandAvailable;
    final path =
        shortPath ? 'ble_inet_sos_trigger' : (longPath ? 'ble_cmd' : 'none');
    BleDebugRegistry.instance.recordEvent(
      '[APP_PRE_SOS_ROUTE] origin=app '
      'bleConnected=$bleConnected cmd=$longPath '
      'preSosDevicePath=$path decision=$decision '
      'countdown=${countdown.inSeconds}',
    );
  }

  void _rememberDeviceRuntimeSosOwnership(
    DeviceSosStatus status,
    String? cycleKey,
  ) {
    final incident = _buildDeviceRuntimePublicSosIncident(status);
    if (incident == null || !_hasBackendVisibleSosIncident(incident)) {
      return;
    }
    _activeDeviceRuntimeIncidentId = incident.id;
    _activeDeviceRuntimeCycleKey =
        cycleKey == null ? null : 'sos-cycle:$cycleKey';
    BleDebugRegistry.instance.recordEvent(
      'SOS_OWNER_SELECTED owner=device reason=device_runtime_sos '
      'incidentId=${incident.id} cycle=${_activeDeviceRuntimeCycleKey ?? "-"}',
    );
  }

  int? _resolveDeviceOriginatedSosNodeId({
    required DeviceSosStatus status,
    String? cycleKey,
    String? incidentId,
  }) {
    return status.nodeId ??
        _parseDeviceRuntimeNodeId(incidentId) ??
        _parseSosCycleNodeId(cycleKey) ??
        _parseSosCycleNodeId(
          cycleKey == null ? null : 'sos-cycle:$cycleKey',
        ) ??
        _parseDeviceRuntimeNodeId(status.lastPacketSignature) ??
        _parseSosCycleNodeId(status.lastPacketSignature) ??
        _cachedNodeIdForCurrentHardwareId();
  }

  void _promoteDeviceNodeIdFromSos({
    required int nodeId,
    required String source,
  }) {
    _knownLocalDeviceNodeId = nodeId;
    final status = _lastDeviceStatus;
    final hardwareId = _canonicalHardwareIdForStatus(status);
    if (hardwareId != null) {
      _sosRuntimeNodeIdByHardwareId[hardwareId] = nodeId;
    }
    if (status == null) {
      return;
    }
    final previousDeviceId = status.nodeId?.toString() ??
        (isBleMacDeviceId(status.deviceId) ? null : status.deviceId) ??
        status.deviceId;
    final promotedStatus = status.copyWith(nodeId: nodeId);
    _lastDeviceStatus = promotedStatus;
    _publishPublicDeviceStatus(
      rawStatus: promotedStatus,
      reason: source,
    );
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_NODE_ID_PROMOTED source=$source '
      'nodeId=$nodeId hardwareId=${hardwareId ?? status.deviceId} '
      'previousDeviceId=$previousDeviceId nextDeviceId=$nodeId',
    );
    unawaited(
      ensureBackendDeviceRegistered(
        nodeId: nodeId,
        bleHardwareId: hardwareId,
        firmwareVersion: status.firmwareVersion,
        hardwareModel: status.model ?? status.deviceAlias,
        pairedAt: status.lastSeen ?? DateTime.now().toUtc(),
        reason: 'identity_promoted:$source',
      ),
    );
  }

  DeviceStatus _promoteCachedNodeIdOntoDeviceStatus(
    DeviceStatus status, {
    required String source,
  }) {
    if (status.nodeId != null) {
      final hardwareId = _canonicalHardwareIdForStatus(status);
      if (hardwareId != null) {
        _sosRuntimeNodeIdByHardwareId[hardwareId] = status.nodeId!;
      }
      return status;
    }
    final hardwareId = _canonicalHardwareIdForStatus(status);
    final cachedNodeId =
        hardwareId == null ? null : _sosRuntimeNodeIdByHardwareId[hardwareId];
    if (cachedNodeId == null) {
      return status;
    }
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_NODE_ID_CACHE_HIT hardwareId=$hardwareId '
      'nodeId=$cachedNodeId source=sos_runtime_cache',
    );
    return status.copyWith(nodeId: cachedNodeId);
  }

  int? _cachedNodeIdForCurrentHardwareId() {
    final hardwareId = _canonicalHardwareIdForStatus(_lastDeviceStatus);
    return _cachedNodeIdForHardwareId(hardwareId);
  }

  int? _cachedNodeIdForHardwareId(String? hardwareId) {
    return hardwareId == null
        ? null
        : _sosRuntimeNodeIdByHardwareId[hardwareId];
  }

  _RemoteRelayLocalGuardMatch _resolveConnectedDeviceNodeGuardMatch() {
    final deviceRuntimeIncidentNodeId = _parseDeviceRuntimeNodeId(
            _activeDeviceRuntimeIncidentId) ??
        _parseDeviceRuntimeNodeId(_currentDeviceRuntimeUiIncidentId()) ??
        _parseDeviceRuntimeNodeId(_publicSosFallbackIncident?.id) ??
        _parseDeviceRuntimeNodeId(_lastPublicSosIncidentId) ??
        _parseDeviceRuntimeNodeId(_lastDeviceRuntimeCanonicalIncident?.id) ??
        _deviceRuntimeNodeIdFromCanonicalizationState();
    if (deviceRuntimeIncidentNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: deviceRuntimeIncidentNodeId,
        matchedBy: 'device_runtime_incident_id',
      );
    }
    final publicStatusNodeId =
        _nodeIdFromConnectedRuntimeStatus(_lastPublicDeviceStatus);
    if (publicStatusNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: publicStatusNodeId,
        matchedBy: 'promoted_public_device',
      );
    }
    final runtimeStatusNodeId =
        _nodeIdFromConnectedRuntimeStatus(_lastDeviceStatus);
    if (runtimeStatusNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: runtimeStatusNodeId,
        matchedBy: 'runtime_device_status',
      );
    }
    final promotedPublicNodeId = _cachedNodeIdForHardwareId(
      _canonicalHardwareIdForStatus(_lastPublicDeviceStatus),
    );
    final promotedRuntimeNodeId = _cachedNodeIdForHardwareId(
      _canonicalHardwareIdForStatus(_lastDeviceStatus),
    );
    final hardwareNodeId = promotedPublicNodeId ?? promotedRuntimeNodeId;
    if (hardwareNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: hardwareNodeId,
        matchedBy: 'hardware_node_cache',
      );
    }
    final statusNodeId =
        _lastDeviceStatus?.nodeId ?? _lastPublicDeviceStatus?.nodeId;
    if (statusNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: statusNodeId,
        matchedBy: 'runtime_device_status',
      );
    }
    final runtimeCycleNodeId =
        _parseSosCycleNodeId(_activeDeviceRuntimeCycleKey);
    if (runtimeCycleNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: runtimeCycleNodeId,
        matchedBy: 'device_runtime_cycle',
      );
    }
    final activeCycleNodeId = _parseSosCycleNodeId(_activeDeviceSosCycleKey);
    if (activeCycleNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: activeCycleNodeId,
        matchedBy: 'active_sos_cycle',
      );
    }
    if (_knownLocalDeviceNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: _knownLocalDeviceNodeId,
        matchedBy: 'hardware_node_cache',
      );
    }
    final currentHardwareNodeId = _cachedNodeIdForCurrentHardwareId();
    return _RemoteRelayLocalGuardMatch(
      nodeId: currentHardwareNodeId,
      matchedBy: currentHardwareNodeId == null ? 'none' : 'hardware_node_cache',
    );
  }

  int? _nodeIdFromConnectedRuntimeStatus(DeviceStatus? status) {
    if (status == null || !status.connected) {
      return null;
    }
    return status.nodeId;
  }

  int? _deviceRuntimeNodeIdFromCanonicalizationState() {
    final signature = _lastDeviceRuntimeCanonicalIncidentSignature;
    if (signature == null || signature.isEmpty) {
      return null;
    }
    for (final part in signature.split('|')) {
      final nodeId = _parseDeviceRuntimeNodeId(part);
      if (nodeId != null) {
        return nodeId;
      }
    }
    return null;
  }

  String? _canonicalHardwareIdForStatus(DeviceStatus? status) {
    if (status == null) {
      return null;
    }
    final hardwareId = <String?>[
      status.canonicalHardwareId,
      status.deviceId,
    ].whereType<String>().map((value) => value.trim()).firstWhere(
          (value) => value.isNotEmpty,
          orElse: () => '',
        );
    return hardwareId.isEmpty ? null : hardwareId;
  }

  int? _parseDeviceRuntimeNodeId(String? incidentId) {
    const prefix = 'device-runtime-sos:';
    if (incidentId == null || !incidentId.startsWith(prefix)) {
      return null;
    }
    return _parseFirstIntSegment(incidentId.substring(prefix.length));
  }

  int? _parseSosCycleNodeId(String? cycleKey) {
    if (cycleKey == null) {
      return null;
    }
    const dedupePrefix = 'sos-cycle:sos:';
    if (cycleKey.startsWith(dedupePrefix)) {
      return _parseFirstIntSegment(cycleKey.substring(dedupePrefix.length));
    }
    const cyclePrefix = 'sos:';
    if (cycleKey.startsWith(cyclePrefix)) {
      return _parseFirstIntSegment(cycleKey.substring(cyclePrefix.length));
    }
    return null;
  }

  int? _parseFirstIntSegment(String value) {
    final segment = value.split(':').first.trim();
    if (segment.isEmpty) {
      return null;
    }
    return int.tryParse(segment);
  }

  void _clearDeviceRuntimeSosOwnership({required String reason}) {
    if (_activeDeviceRuntimeIncidentId == null &&
        _activeDeviceRuntimeCycleKey == null &&
        _deviceOwnedBackendIncidentId == null) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_OWNER_CLEARED owner=device reason=$reason '
      'incidentId=${_activeDeviceRuntimeIncidentId ?? "-"} '
      'cycle=${_activeDeviceRuntimeCycleKey ?? "-"}',
    );
    _activeDeviceRuntimeIncidentId = null;
    _activeDeviceRuntimeCycleKey = null;
    _activeDeviceRuntimeLocalCycleKey = null;
    _deviceOwnedBackendIncidentId = null;
    _lastDeviceRuntimeCanonicalIncidentSignature = null;
    _lastDeviceRuntimeCanonicalIncident = null;
    _loggedDeviceRuntimeCanonicalizationSignatures.clear();
  }

  void _rememberClosedDeviceRuntimeIncidentIds({
    required Iterable<String?> ids,
  }) {
    for (final raw in ids) {
      final id = raw?.trim();
      if (id == null || id.isEmpty) {
        continue;
      }
      _closedDeviceRuntimeIncidentIds.add(id);
    }
    while (_closedDeviceRuntimeIncidentIds.length > 12) {
      _closedDeviceRuntimeIncidentIds.remove(
        _closedDeviceRuntimeIncidentIds.first,
      );
    }
  }

  bool _isClosedDeviceRuntimeIncidentId(String? id) {
    final normalized = id?.trim();
    return normalized != null &&
        normalized.isNotEmpty &&
        _closedDeviceRuntimeIncidentIds.contains(normalized);
  }

  bool _hasActiveDeviceRuntimeSosOwnership() {
    return _activeDeviceRuntimeIncidentId != null ||
        _isDeviceRuntimeSosCycleKey(_activeDeviceRuntimeCycleKey) ||
        _isDeviceRuntimeSosCycleKey(
          _activeDeviceSosCycleKey == null
              ? null
              : 'sos-cycle:$_activeDeviceSosCycleKey',
        );
  }

  bool _isLocalAppSosIncidentId(String? incidentId) {
    return incidentId != null && incidentId.startsWith('sos-');
  }

  bool _isDeviceOwnedBackendIncidentId(String? incidentId) {
    return incidentId != null &&
        incidentId == _deviceOwnedBackendIncidentId &&
        !_isLocalAppSosIncidentId(incidentId) &&
        !_isDeviceRuntimeSosIncidentId(incidentId);
  }

  void _rememberDeviceOwnedBackendIncidentId({
    required String backendIncidentId,
  }) {
    if (_deviceOwnedBackendIncidentId == backendIncidentId) {
      return;
    }
    _deviceOwnedBackendIncidentId = backendIncidentId;
  }

  SosIncident? _guardDeviceOwnedCanonicalIncident(
    SosIncident? incoming, {
    required String source,
  }) {
    if (incoming == null || !_hasActiveDeviceRuntimeSosOwnership()) {
      return incoming;
    }
    if (_isDeviceOwnedBackendIncidentId(incoming.id)) {
      return _canonicalizeDeviceOwnedBackendIncident(
        incoming,
        source: source,
      );
    }
    if (_isDeviceRuntimeSosIncidentId(incoming.id)) {
      final backendIncidentId = _deviceOwnedBackendIncidentId;
      if (backendIncidentId != null) {
        return _canonicalizeDeviceOwnedBackendIncident(
          _reidentifySosIncident(
            incoming,
            id: backendIncidentId,
            deliveryChannel: SosDeliveryChannel.backendAndDevice,
          ),
          source: source,
        );
      }
      return incoming;
    }
    if (!_isLocalAppSosIncidentId(incoming.id) &&
        _hasBackendVisibleSosIncident(incoming)) {
      _rememberDeviceOwnedBackendIncidentId(
        backendIncidentId: incoming.id,
      );
      return _canonicalizeDeviceOwnedBackendIncident(
        incoming,
        source: source,
      );
    }
    if (_isLocalAppSosIncidentId(incoming.id)) {
      _logSosRejectionThrottled(
        cycleId: _activeDeviceRuntimeCycleKey ??
            _activeDeviceRuntimeIncidentId ??
            'unknown',
        source: source,
        reason: 'duplicate_device_owned_sos',
        message: 'SOS_BACKEND_PUBLISH_SKIPPED reason=duplicate_owner '
            'owner=device source=$source incomingIncident=${incoming.id} '
            'activeIncident=${_activeDeviceRuntimeIncidentId ?? "-"} '
            'cycle=${_activeDeviceRuntimeCycleKey ?? "-"}',
      );
      final backendIncidentId = _deviceOwnedBackendIncidentId;
      if (backendIncidentId != null) {
        return _canonicalizeDeviceOwnedBackendIncident(
          _reidentifySosIncident(
            incoming,
            id: backendIncidentId,
            state: SosState.sent,
            triggerSource: 'ble_device_runtime_status',
            deliveryChannel: SosDeliveryChannel.backendAndDevice,
          ),
          source: source,
        );
      }
      return _activeDeviceRuntimeIncidentId == null
          ? null
          : SosIncident(
              id: _activeDeviceRuntimeIncidentId!,
              state: SosState.sent,
              createdAt: incoming.createdAt,
              triggerSource: 'ble_device_runtime_status',
              positionSnapshot: incoming.positionSnapshot,
              deliveryChannel: SosDeliveryChannel.deviceOnly,
            );
    }
    return incoming;
  }

  SosIncident _reidentifySosIncident(
    SosIncident incident, {
    required String id,
    SosState? state,
    String? triggerSource,
    SosDeliveryChannel? deliveryChannel,
  }) {
    return SosIncident(
      id: id,
      state: state ?? incident.state,
      createdAt: incident.createdAt,
      positionSnapshot: incident.positionSnapshot,
      triggerSource: triggerSource ?? incident.triggerSource,
      message: incident.message,
      deliveryChannel: deliveryChannel ?? incident.deliveryChannel,
    );
  }

  SosIncident _canonicalizeDeviceOwnedBackendIncident(
    SosIncident incoming, {
    required String source,
  }) {
    final runtimeIncidentId = _activeDeviceRuntimeIncidentId;
    final backendIncidentId = _deviceOwnedBackendIncidentId;
    if (runtimeIncidentId == null ||
        backendIncidentId == null ||
        incoming.id != backendIncidentId) {
      return incoming;
    }
    final signature =
        '$backendIncidentId|$runtimeIncidentId|$backendIncidentId|${incoming.state.name}';
    final cachedCanonicalIncident = _lastDeviceRuntimeCanonicalIncident;
    if (_lastDeviceRuntimeCanonicalIncidentSignature == signature &&
        cachedCanonicalIncident != null) {
      return cachedCanonicalIncident;
    }
    _logDeviceRuntimeCanonicalizationOnce(
      action: 'adopt_backend_canonical_incident_id',
      source: source,
      incomingIncidentId: backendIncidentId,
      existingIncidentId: runtimeIncidentId,
      existingCanonicalIncidentId: runtimeIncidentId,
      chosenCanonicalIncidentId: backendIncidentId,
    );
    final canonicalIncident = incoming.copyWith(
      deliveryChannel:
          incoming.deliveryChannel ?? SosDeliveryChannel.backendAndDevice,
    );
    _lastDeviceRuntimeCanonicalIncidentSignature = signature;
    _lastDeviceRuntimeCanonicalIncident = canonicalIncident;
    return canonicalIncident;
  }

  void _logDeviceRuntimeCanonicalizationOnce({
    required String action,
    required String source,
    required String incomingIncidentId,
    required String existingIncidentId,
    required String existingCanonicalIncidentId,
    required String chosenCanonicalIncidentId,
  }) {
    if (_isNoOpCanonicalization(
      incomingIncidentId: incomingIncidentId,
      existingIncidentId: existingIncidentId,
      existingCanonicalIncidentId: existingCanonicalIncidentId,
      chosenCanonicalIncidentId: chosenCanonicalIncidentId,
    )) {
      return;
    }
    if (action == 'preserve_existing_canonical_id' &&
        existingCanonicalIncidentId == chosenCanonicalIncidentId) {
      return;
    }
    final originatorNodeId = _parseDeviceRuntimeNodeId(existingIncidentId) ??
        _parseSosCycleNodeId(_activeDeviceRuntimeCycleKey) ??
        _parseSosCycleNodeId(_activeDeviceSosCycleKey);
    final terminal = _isOpenSosState(_publicSosState)
        ? 'open'
        : _publicSosState == SosState.resolved
            ? 'resolved'
            : _publicSosState == SosState.cancelled
                ? 'cancelled'
                : _publicSosState.name;
    final signature = [
      action,
      incomingIncidentId,
      existingIncidentId,
      existingCanonicalIncidentId,
      chosenCanonicalIncidentId,
      _publicSosState.name,
      terminal,
      originatorNodeId?.toString() ?? 'none',
    ].join('|');
    if (!_loggedDeviceRuntimeCanonicalizationSignatures.add(signature)) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      '[SOS_CANONICALIZE] action=$action '
      'source=$source stage=${_publicSosState.name} terminal=$terminal '
      'originatorNodeId=${originatorNodeId?.toString() ?? "none"} '
      'incomingIncidentId=$incomingIncidentId '
      'existingIncidentId=$existingIncidentId '
      'existingCanonicalIncidentId=$existingCanonicalIncidentId '
      'chosenCanonicalIncidentId=$chosenCanonicalIncidentId',
    );
  }

  bool _isNoOpCanonicalization({
    required String incomingIncidentId,
    required String existingIncidentId,
    required String existingCanonicalIncidentId,
    required String chosenCanonicalIncidentId,
  }) {
    final incoming = incomingIncidentId.trim();
    final existing = existingIncidentId.trim();
    final existingCanonical = existingCanonicalIncidentId.trim();
    final chosenCanonical = chosenCanonicalIncidentId.trim();
    if (incoming.isNotEmpty &&
        incoming == existing &&
        existing == chosenCanonical) {
      return true;
    }
    if (incoming == existing &&
        existingCanonical == chosenCanonical &&
        !_containsBackendUuid(<String>[
          incoming,
          existing,
          existingCanonical,
          chosenCanonical,
        ])) {
      return true;
    }
    if (incomingIncidentId == existingIncidentId &&
        existingIncidentId == existingCanonicalIncidentId &&
        existingCanonicalIncidentId == chosenCanonicalIncidentId) {
      return true;
    }
    final ids = <String>{
      incomingIncidentId,
      existingIncidentId,
      existingCanonicalIncidentId,
      chosenCanonicalIncidentId,
    }..removeWhere((id) => id.isEmpty);
    if (ids.length != 1) {
      return false;
    }
    return ids.single.startsWith('device-runtime-sos:');
  }

  bool _containsBackendUuid(Iterable<String> values) {
    return values.any((value) {
      final trimmed = value.trim();
      return RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(trimmed);
    });
  }

  Future<SosIncident> _updateFallbackPublicSosIncident({
    required SosState state,
    required SosDeliveryChannel deliveryChannel,
  }) async {
    final fallback = _publicSosFallbackIncident ??
        _decorateIncidentWithPublicDeliveryChannel(
          await sosRepository.getCurrentIncident(),
        ) ??
        _decorateIncidentWithPublicDeliveryChannel(
          _lastKnownActiveSosIncident,
        );
    if (fallback != null) {
      return fallback.copyWith(
        state: state,
        deliveryChannel: deliveryChannel,
      );
    }
    final now = DateTime.now().toUtc();
    return SosIncident(
      id: 'public-sos-fallback:${now.microsecondsSinceEpoch}',
      state: state,
      createdAt: now,
      triggerSource: 'public_sos_fallback',
      deliveryChannel: deliveryChannel,
    );
  }

  void _recordPublicSosResult({
    required SosIncident incident,
    required SosDeliveryChannel deliveryChannel,
    SosState? fallbackState,
  }) {
    final recordedIncident = _guardDeviceOwnedCanonicalIncident(
      incident,
      source: 'record_public_sos_result',
    );
    if (recordedIncident == null) {
      return;
    }
    _rememberActiveSosIncident(recordedIncident);
    _lastPublicSosIncidentId = recordedIncident.id;
    _lastPublicSosDeliveryChannel = deliveryChannel;
    if (fallbackState != null) {
      _publicSosFallbackIncident = recordedIncident;
      _emitPublicSosState(fallbackState, source: 'public_sos_result');
    } else {
      _publicSosFallbackIncident = null;
      _emitPublicSosState(
        recordedIncident.state,
        source: 'public_sos_result',
      );
    }
    _emitOperationalDiagnostics();
  }

  void _clearCurrentPublicSosAfterCancellation(SosIncident incident) {
    _rememberAcknowledgedTerminalSosIncident(incident);
    _publicSosFallbackIncident = null;
    _lastKnownActiveSosIncident = null;
    _clearDeviceRuntimeSosOwnership(reason: 'public_cancel_completed');
    _activeDeviceSosCycleKey = null;
    _notifiedDeviceSosCycleKey = null;
    _notifiedDeviceSosState = null;
    _emitPublicSosState(
      SosState.idle,
      source: 'public_cancel_completed:clear_current_sos',
    );
    _emitOperationalDiagnostics();
  }

  SosIncident? _preserveActiveIncidentWhenMissing(
    SosIncident? incoming, {
    required String source,
  }) {
    if (incoming != null) {
      _rememberActiveSosIncident(incoming);
      return incoming;
    }
    final remembered = _lastKnownActiveSosIncident;
    if (remembered == null || !_isOpenSosState(_publicSosState)) {
      return null;
    }
    _logActiveIncidentPreservedOnce(
      source: source,
      incident: remembered,
    );
    return remembered.copyWith(state: _publicSosState);
  }

  void _rememberActiveSosIncident(SosIncident incident) {
    if (_isOpenSosState(incident.state)) {
      _lastKnownActiveSosIncident = incident;
      return;
    }
    if (incident.state == SosState.cancelled ||
        incident.state == SosState.resolved) {
      _lastKnownActiveSosIncident = null;
      _lastLoggedActiveIncidentPreservationSignature = null;
    }
  }

  void _logActiveIncidentPreservedOnce({
    required String source,
    required SosIncident incident,
  }) {
    final signature = '$source|${incident.id}|${_publicSosState.name}';
    if (_lastLoggedActiveIncidentPreservationSignature == signature) {
      return;
    }
    _lastLoggedActiveIncidentPreservationSignature = signature;
    BleDebugRegistry.instance.recordEvent(
      '[APP_SOS_RECONCILE] decision=preserve_active_incident_id '
      'reason=incoming_active_missing_incident source=$source '
      'stage=${_publicSosState.name} terminal=open incident=${incident.id}',
    );
  }

  String _sosIntentDedupeKeyForIncident(SosIncident incident) {
    return 'sos:${incident.id}';
  }

  String _sosIntentDedupeKeyForDeviceStatus(
    DeviceSosStatus status,
    String? cycleKey,
  ) {
    final bridgeIncidentId = _pendingAppTriggeredSosBridge?.incidentId;
    if (bridgeIncidentId != null && bridgeIncidentId.isNotEmpty) {
      return 'sos:$bridgeIncidentId';
    }
    final resolvedCycleKey = cycleKey ??
        _deriveDeviceSosCycleKey(status) ??
        status.lastPacketSignature ??
        status.packetId?.toString() ??
        status.updatedAt.toUtc().microsecondsSinceEpoch.toString();
    return 'sos-cycle:$resolvedCycleKey';
  }

  void _emitSosActiveNotificationIntent(
    SosIncident incident, {
    String? dedupeKey,
    int? nodeId,
  }) {
    _emitNotificationIntent(
      _buildNotificationIntent(
        type: EixamNotificationIntentType.sosActive,
        dedupeKey: dedupeKey ?? _sosIntentDedupeKeyForIncident(incident),
        severity: EixamNotificationIntentSeverity.critical,
        incidentId: incident.id,
        deviceId: _lastDeviceStatus?.deviceId,
        deviceAlias: _lastDeviceStatus?.deviceAlias,
        nodeId: nodeId,
        titleKey: 'notification.sos.active.title',
        bodyKey: 'notification.sos.active.body',
        fallbackTitle: 'SOS active',
        fallbackBody: 'An SOS is active.',
        payload: <String, String>{
          'incidentId': incident.id,
          if (incident.deliveryChannel != null)
            'deliveryChannel': incident.deliveryChannel!.name,
        },
      ),
    );
  }

  void _emitSosTerminalNotificationIntent(
    SosIncident incident, {
    required EixamNotificationIntentType type,
    required EixamNotificationIntentSeverity severity,
    required String titleKey,
    required String bodyKey,
    required String fallbackTitle,
    required String fallbackBody,
    String? dedupeKey,
    int? nodeId,
  }) {
    _emitNotificationIntent(
      _buildNotificationIntent(
        type: type,
        dedupeKey: dedupeKey ?? _sosIntentDedupeKeyForIncident(incident),
        severity: severity,
        incidentId: incident.id,
        deviceId: _lastDeviceStatus?.deviceId,
        deviceAlias: _lastDeviceStatus?.deviceAlias,
        nodeId: nodeId,
        titleKey: titleKey,
        bodyKey: bodyKey,
        fallbackTitle: fallbackTitle,
        fallbackBody: fallbackBody,
        payload: <String, String>{
          'incidentId': incident.id,
          if (incident.deliveryChannel != null)
            'deliveryChannel': incident.deliveryChannel!.name,
        },
        shouldClearSosNotifications: true,
      ),
    );
  }

  void _emitDeviceSosActiveNotificationIntent(
    DeviceSosStatus status,
    String? cycleKey,
  ) {
    if (status.state != DeviceSosState.active &&
        status.state != DeviceSosState.acknowledged) {
      return;
    }
    final dedupeKey = _sosIntentDedupeKeyForDeviceStatus(status, cycleKey);
    _emitNotificationIntent(
      _buildNotificationIntent(
        type: EixamNotificationIntentType.sosActive,
        dedupeKey: dedupeKey,
        severity: EixamNotificationIntentSeverity.critical,
        incidentId: dedupeKey.startsWith('sos:')
            ? dedupeKey.substring('sos:'.length)
            : null,
        deviceId: _lastDeviceStatus?.deviceId,
        deviceAlias: _lastDeviceStatus?.deviceAlias,
        nodeId: status.nodeId,
        titleKey: 'notification.sos.active.title',
        bodyKey: 'notification.sos.active.body',
        fallbackTitle: _notificationTitleForSosState(status.state),
        fallbackBody: _notificationBodyForSosState(status.state),
        payload: <String, String>{
          'deviceSosState': status.state.name,
          'transitionSource': status.transitionSource.name,
          if (cycleKey != null) 'cycleKey': cycleKey,
        },
      ),
    );
  }

  void _emitDeviceSosTerminalNotificationIntent(
    DeviceSosStatus status,
    String? cycleKey,
  ) {
    final publicState = _mapTerminalDeviceStatusToPublicSosState(status);
    if (publicState == null) {
      return;
    }
    final type = publicState == SosState.resolved
        ? EixamNotificationIntentType.sosResolved
        : EixamNotificationIntentType.sosCancelled;
    final severity = publicState == SosState.resolved
        ? EixamNotificationIntentSeverity.success
        : EixamNotificationIntentSeverity.info;
    final dedupeKey = _sosIntentDedupeKeyForDeviceStatus(status, cycleKey);
    _emitNotificationIntent(
      _buildNotificationIntent(
        type: type,
        dedupeKey: dedupeKey,
        severity: severity,
        incidentId: dedupeKey.startsWith('sos:')
            ? dedupeKey.substring('sos:'.length)
            : null,
        deviceId: _lastDeviceStatus?.deviceId,
        deviceAlias: _lastDeviceStatus?.deviceAlias,
        nodeId: status.nodeId,
        titleKey: publicState == SosState.resolved
            ? 'notification.sos.resolved.title'
            : 'notification.sos.cancelled.title',
        bodyKey: publicState == SosState.resolved
            ? 'notification.sos.resolved.body'
            : 'notification.sos.cancelled.body',
        fallbackTitle:
            publicState == SosState.resolved ? 'SOS resolved' : 'SOS cancelled',
        fallbackBody: publicState == SosState.resolved
            ? 'The SOS has been resolved.'
            : 'The SOS has been cancelled.',
        payload: <String, String>{
          'deviceSosState': status.state.name,
          'transitionSource': status.transitionSource.name,
          if (cycleKey != null) 'cycleKey': cycleKey,
        },
        shouldClearSosNotifications: true,
      ),
    );
  }

  Future<void> _emitRepositoryTerminalSosNotificationIntent(
    SosState state,
  ) async {
    final incident = _decorateIncidentWithPublicDeliveryChannel(
      await sosRepository.getCurrentIncident(),
    );
    if (incident == null) {
      return;
    }
    if (state == SosState.resolved) {
      _emitSosTerminalNotificationIntent(
        incident,
        type: EixamNotificationIntentType.sosResolved,
        severity: EixamNotificationIntentSeverity.success,
        titleKey: 'notification.sos.resolved.title',
        bodyKey: 'notification.sos.resolved.body',
        fallbackTitle: 'SOS resolved',
        fallbackBody: 'The SOS has been resolved.',
      );
      return;
    }
    if (state == SosState.cancelled) {
      _emitSosTerminalNotificationIntent(
        incident,
        type: EixamNotificationIntentType.sosCancelled,
        severity: EixamNotificationIntentSeverity.info,
        titleKey: 'notification.sos.cancelled.title',
        bodyKey: 'notification.sos.cancelled.body',
        fallbackTitle: 'SOS cancelled',
        fallbackBody: 'The SOS has been cancelled.',
      );
    }
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
      'App-triggered SOS bridge registered -> incidentId=${incident.id} deviceId=${_lastDeviceStatus?.nodeId?.toString() ?? "-"} nodeId=${_lastDeviceStatus?.nodeId?.toString() ?? "-"} hardwareId=${_lastDeviceStatus?.deviceId ?? "-"} expiresInMs=${_appTriggeredSosBridgeWindow.inMilliseconds}',
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
    final cycleKey = _preSosCycleKeyFromDeviceStatus(status);
    final existing = _preSosSession;
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
      owner: status.triggerOrigin == DeviceSosTransitionSource.app ||
              existing?.owner == _SosOwner.app
          ? _SosOwner.app
          : _SosOwner.device,
      cycleKey: cycleKey,
      originatorNodeId: status.nodeId ?? _knownLocalDeviceNodeId,
      packetId: status.packetId,
    );
  }

  Future<void> _syncPreSosSessionFromProtectionPlatformSnapshot({
    required String trigger,
  }) async {
    ProtectionPlatformSnapshot snapshot;
    try {
      snapshot = await protectionPlatformAdapter.getPlatformSnapshot();
    } catch (_) {
      return;
    }
    if (snapshot.bleOwner == ProtectionBleOwner.flutter ||
        (!snapshot.serviceRunning && !snapshot.runtimeActive)) {
      return;
    }
    final state = snapshot.preSosLifecycleState;
    final startedAt = snapshot.preSosStartedAt;
    final expectedActivationAt = snapshot.preSosExpectedActivationAt;
    if (state == null || state == 'idle') {
      return;
    }
    if (state == 'cancelPending') {
      _clearPreSosSession(
        reason: 'native_pre_sos_cancel_pending',
        emitIdleState: false,
      );
      return;
    }
    if (state == 'createPending') {
      _clearPreSosSession(
        reason: 'native_pre_sos_create_pending',
        emitIdleState: false,
      );
      await _syncNativePreSosBackendPending(
        trigger: 'native_pre_sos_create_pending',
      );
      return;
    }
    if (startedAt == null || expectedActivationAt == null) {
      return;
    }
    if (!DateTime.now().isBefore(expectedActivationAt)) {
      if (state == 'preConfirmSeen') {
        _clearPreSosSession(
          reason: 'native_pre_sos_elapsed',
          emitIdleState: false,
        );
        await _syncNativePreSosBackendPending(
          trigger: 'native_pre_sos_elapsed',
        );
      }
      return;
    }
    _syncPreSosSession(
      startedAt: startedAt,
      expectedActivationAt: expectedActivationAt,
      mirroredOnDevice: true,
      origin: DeviceSosTransitionSource.device,
      owner: snapshot.preSosOwner == 'app' ? _SosOwner.app : _SosOwner.device,
      cycleKey: snapshot.preSosCycleKey,
      originatorNodeId: snapshot.preSosOriginatorNodeId,
      packetId: snapshot.preSosPacketId,
    );
    BleDebugRegistry.instance.recordEvent(
      '[PRE_SOS_CYCLE] action=rehydrate_native trigger=$trigger '
      'cycle=${snapshot.preSosCycleKey ?? "-"} '
      'deadline=${expectedActivationAt.toUtc().toIso8601String()}',
    );
  }

  Future<void> _syncNativePreSosBackendPending({
    required String trigger,
  }) async {
    try {
      final incident = await sosRepository.getCurrentIncident();
      if (_hasNonRuntimeVisibleSosIncident(incident)) {
        final deliveryChannel =
            incident!.deliveryChannel ?? SosDeliveryChannel.backendAndDevice;
        _recordPublicSosResult(
          incident: incident.copyWith(deliveryChannel: deliveryChannel),
          deliveryChannel: deliveryChannel,
        );
        BleDebugRegistry.instance.recordEvent(
          '[NATIVE_PRE_SOS_BACKEND] action=backend_confirmed '
          'trigger=$trigger incidentId=${incident.id} '
          'state=${incident.state.name}',
        );
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        '[NATIVE_PRE_SOS_BACKEND] action=await_backend_confirmation '
        'trigger=$trigger reason=no_backend_incident',
      );
      _emitPublicSosState(SosState.sending, source: trigger);
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[NATIVE_PRE_SOS_BACKEND] action=await_backend_confirmation_failed '
        'trigger=$trigger error=${_compactDiagnosticValue(error)}',
      );
      _emitPublicSosState(SosState.sending, source: trigger);
    }
  }

  void _syncPreSosSession({
    required DateTime startedAt,
    required DateTime expectedActivationAt,
    required bool mirroredOnDevice,
    required DeviceSosTransitionSource? origin,
    required _SosOwner owner,
    String? cycleKey,
    int? originatorNodeId,
    int? packetId,
    bool emitNotificationIntent = true,
    bool publishStatus = true,
  }) {
    _clearTerminalPublicSosFallbackForNewOpenFlow();
    final session = _preSosSession;
    final createdSession = session == null;
    final effectiveCycleKey =
        cycleKey ?? session?.cycleKey ?? _newLocalPreSosCycleKey(startedAt);
    if (session == null) {
      final cycleRevision = ++_preSosCycleRevision;
      _preSosSession = _PreSosSession(
        cycleRevision: cycleRevision,
        cycleKey: effectiveCycleKey,
        startedAt: startedAt,
        expectedActivationAt: expectedActivationAt,
        mirroredOnDevice: mirroredOnDevice,
        origin: origin,
        owner: owner,
        originatorNodeId: originatorNodeId,
        packetId: packetId,
        timer: Timer.periodic(_preSosTickInterval, (_) {
          unawaited(_handlePreSosTimerTick(cycleRevision: cycleRevision));
        }),
      );
      BleDebugRegistry.instance.recordEvent(
        '[APP_PRE_SOS_START] action=fresh_cycle cycle=$cycleRevision '
        'cycleKey=$effectiveCycleKey owner=${owner.name} '
        'origin=${origin?.name ?? "-"} '
        'mirroredOnDevice=$mirroredOnDevice '
        'originatorNodeId=${originatorNodeId?.toString() ?? "-"} '
        'packetId=${packetId?.toString() ?? "-"} '
        'countdown=${expectedActivationAt.difference(startedAt).inSeconds} '
        'deadline=${expectedActivationAt.toUtc().toIso8601String()}',
      );
    } else {
      final sameCycle = _isSamePreSosCycle(
        session,
        incomingCycleKey: effectiveCycleKey,
        incomingOriginatorNodeId: originatorNodeId,
        incomingPacketId: packetId,
      );
      final sameCountdownWindow =
          _samePreSosInstant(session.startedAt, startedAt) &&
              _samePreSosInstant(
                session.expectedActivationAt,
                expectedActivationAt,
              );
      final sameOriginNode = session.originatorNodeId != null &&
          originatorNodeId != null &&
          session.originatorNodeId == originatorNodeId;
      final preserveExistingCycle =
          sameCycle || (sameCountdownWindow && sameOriginNode);
      final resolvedCycleKey =
          preserveExistingCycle ? session.cycleKey : effectiveCycleKey;
      final resolvedPacketId =
          preserveExistingCycle ? session.packetId ?? packetId : packetId;
      _preSosSession = session.copyWith(
        cycleKey: resolvedCycleKey,
        startedAt: preserveExistingCycle ? session.startedAt : startedAt,
        expectedActivationAt: preserveExistingCycle
            ? session.expectedActivationAt
            : expectedActivationAt,
        mirroredOnDevice: mirroredOnDevice,
        origin: origin,
        owner: owner,
        originatorNodeId: originatorNodeId ?? session.originatorNodeId,
        packetId: resolvedPacketId,
      );
      if (preserveExistingCycle &&
          (session.startedAt != startedAt ||
              session.expectedActivationAt != expectedActivationAt ||
              session.cycleKey != effectiveCycleKey ||
              session.packetId != packetId)) {
        BleDebugRegistry.instance.recordEvent(
          '[PRE_SOS_CYCLE] action=preserve_cycle '
          'cycle=${session.cycleKey} owner=${session.owner.name} '
          'incomingCycle=$effectiveCycleKey sameCycle=$sameCycle '
          'sameCountdownWindow=$sameCountdownWindow '
          'sameOriginNode=$sameOriginNode '
          'incomingPacketId=${packetId?.toString() ?? "-"} '
          'keptPacketId=${resolvedPacketId?.toString() ?? "-"} '
          'incomingDeadline=${expectedActivationAt.toUtc().toIso8601String()} '
          'keptDeadline=${session.expectedActivationAt.toUtc().toIso8601String()}',
        );
      } else {
        BleDebugRegistry.instance.recordEvent(
          '[PRE_SOS_CYCLE] action=sync_existing '
          'cycle=${session.cycleKey} incomingCycle=$effectiveCycleKey '
          'sameCycle=$sameCycle sameCountdownWindow=$sameCountdownWindow '
          'sameOriginNode=$sameOriginNode owner=${owner.name} '
          'origin=${origin?.name ?? "-"} '
          'packetId=${packetId?.toString() ?? "-"} '
          'deadline=${expectedActivationAt.toUtc().toIso8601String()}',
        );
      }
    }
    if (createdSession && emitNotificationIntent) {
      _emitPreSosNotificationIntent(_preSosSession!);
    }
    unawaited(_persistPreSosSession(_preSosSession!));
    if (publishStatus) {
      _publishPreSosStatus(_buildCurrentPreSosStatus());
    }
  }

  Future<void> _restorePersistedPreSosSession({
    required String trigger,
  }) async {
    if (_preSosSession != null) {
      return;
    }
    final raw =
        await _localStore.readJson(SharedPrefsSdkStore.preSosSessionKey);
    if (raw == null) {
      return;
    }
    final startedAt = _parsePersistedDateTime(raw['startedAt']);
    final expectedActivationAt =
        _parsePersistedDateTime(raw['expectedActivationAt']);
    final owner = _parsePersistedPreSosOwner(raw['owner']);
    if (startedAt == null || expectedActivationAt == null || owner == null) {
      await _clearPersistedPreSosSession();
      return;
    }
    _syncPreSosSession(
      startedAt: startedAt,
      expectedActivationAt: expectedActivationAt,
      mirroredOnDevice: raw['mirroredOnDevice'] == true,
      origin: _parsePersistedDeviceSosTransitionSource(raw['origin']),
      owner: owner,
      cycleKey: raw['cycleKey'] as String?,
      originatorNodeId: raw['originatorNodeId'] as int?,
      packetId: raw['packetId'] as int?,
      emitNotificationIntent: false,
      publishStatus: DateTime.now().isBefore(expectedActivationAt),
    );
    BleDebugRegistry.instance.recordEvent(
      '[PRE_SOS_CYCLE] action=restore_persisted trigger=$trigger '
      'cycle=${raw['cycleKey'] ?? "-"} '
      'deadline=${expectedActivationAt.toUtc().toIso8601String()}',
    );
    await _settleExpiredPreSosSession(trigger: 'restore_persisted:$trigger');
  }

  Future<void> _persistPreSosSession(_PreSosSession session) async {
    await _localStore.saveJson(
      SharedPrefsSdkStore.preSosSessionKey,
      <String, dynamic>{
        'cycleKey': session.cycleKey,
        'owner': session.owner.name,
        'startedAt': session.startedAt.toUtc().toIso8601String(),
        'expectedActivationAt':
            session.expectedActivationAt.toUtc().toIso8601String(),
        'mirroredOnDevice': session.mirroredOnDevice,
        if (session.origin != null) 'origin': session.origin!.name,
        if (session.originatorNodeId != null)
          'originatorNodeId': session.originatorNodeId,
        if (session.packetId != null) 'packetId': session.packetId,
      },
    );
  }

  Future<void> _clearPersistedPreSosSession() {
    return _localStore.remove(SharedPrefsSdkStore.preSosSessionKey);
  }

  DateTime? _parsePersistedDateTime(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      return null;
    }
    return DateTime.tryParse(value)?.toLocal();
  }

  _SosOwner? _parsePersistedPreSosOwner(Object? value) {
    if (value == _SosOwner.device.name) {
      return _SosOwner.device;
    }
    if (value == _SosOwner.app.name) {
      return _SosOwner.app;
    }
    return null;
  }

  DeviceSosTransitionSource? _parsePersistedDeviceSosTransitionSource(
    Object? value,
  ) {
    if (value is! String || value.isEmpty) {
      return null;
    }
    for (final source in DeviceSosTransitionSource.values) {
      if (source.name == value) {
        return source;
      }
    }
    return null;
  }

  Future<bool> _settleExpiredPreSosSession({
    required String trigger,
  }) async {
    final session = _preSosSession;
    if (session == null || !_isPreSosSessionExpired(session)) {
      return false;
    }
    if (_preSosExpirySettlementInFlight) {
      return true;
    }
    _preSosExpirySettlementInFlight = true;
    try {
      BleDebugRegistry.instance.recordEvent(
        '[APP_SOS_COUNTDOWN_ZERO] action=deadline_settle trigger=$trigger '
        'cycle=${session.cycleKey} owner=${session.owner.name}',
      );
      await _handlePreSosTimerTick(cycleRevision: session.cycleRevision);
    } finally {
      _preSosExpirySettlementInFlight = false;
    }
    return true;
  }

  void _clearTerminalPublicSosFallbackForNewOpenFlow() {
    _clearAcknowledgedTerminalSosSummaries(reason: 'new_user_driven_open_flow');
    final fallback = _publicSosFallbackIncident;
    if (fallback == null || !_isTerminalPublicSosState(fallback.state)) {
      return;
    }
    _publicSosFallbackIncident = null;
    BleDebugRegistry.instance.recordEvent(
      '[SOS_CLOSE_GUARD] action=clear reason=new_user_driven_open_flow '
      'clearedIds=${fallback.id}',
    );
  }

  void _emitPreSosNotificationIntent(_PreSosSession session) {
    final dedupeKey =
        'pre_sos:${session.startedAt.toUtc().microsecondsSinceEpoch}';
    _emitNotificationIntent(
      _buildNotificationIntent(
        type: EixamNotificationIntentType.preSos,
        dedupeKey: dedupeKey,
        severity: EixamNotificationIntentSeverity.warning,
        deviceId: _lastDeviceStatus?.deviceId,
        deviceAlias: _lastDeviceStatus?.deviceAlias,
        titleKey: 'notification.pre_sos.title',
        bodyKey: 'notification.pre_sos.body',
        fallbackTitle: 'SOS countdown started',
        fallbackBody: 'An SOS will be activated when the countdown ends.',
        payload: <String, String>{
          'cycleKey': session.cycleKey,
          'startedAt': session.startedAt.toUtc().toIso8601String(),
          'expectedActivationAt':
              session.expectedActivationAt.toUtc().toIso8601String(),
          'mirroredOnDevice': session.mirroredOnDevice.toString(),
          'owner': session.owner.name,
          if (session.originatorNodeId != null)
            'originatorNodeId': session.originatorNodeId.toString(),
          if (session.packetId != null) 'packetId': session.packetId.toString(),
          if (session.origin != null) 'origin': session.origin!.name,
        },
      ),
    );
  }

  Future<void> _handlePreSosTimerTick({required int cycleRevision}) async {
    final session = _preSosSession;
    if (session == null) {
      _logIgnoredPreSosTickOnce(
        staleCycle: cycleRevision,
        currentCycle: _preSosCycleRevision,
      );
      return;
    }
    if (session.cycleRevision != cycleRevision) {
      _logIgnoredPreSosTickOnce(
        staleCycle: cycleRevision,
        currentCycle: session.cycleRevision,
      );
      return;
    }
    if (_isPreSosSessionExpired(session)) {
      if (_pendingPreSosConfirmation == null) {
        await _confirmPreSosFromCountdownZero();
      }
      return;
    }
    final status = _buildCurrentPreSosStatus();
    _publishPreSosStatus(status);
    if (status == null ||
        status.remainingSeconds > 0 ||
        _pendingPreSosConfirmation != null) {
      return;
    }
    await _confirmPreSosFromCountdownZero();
  }

  Future<void> _confirmPreSosFromCountdownZero() async {
    try {
      await confirmPreSos(const SosTriggerPayload());
    } on SosException catch (error) {
      if (error.code != 'E_SOS_ALREADY_ACTIVE') {
        BleDebugRegistry.instance.recordEvent(
          '[APP_SOS_COUNTDOWN_ZERO] action=activate_failed '
          'errorType=${error.runtimeType} code=${error.code} '
          'message=${_compactDiagnosticValue(error.message)}',
        );
        _markCountdownZeroActivationFailed();
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'APP_SOS_COUNTDOWN_ZERO_ALREADY_ACTIVE_HANDLED',
      );
      await _rehydrateDeviceSosPublicState(
        trigger: 'countdown_zero_already_active',
        emitResolvedState: true,
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[APP_SOS_COUNTDOWN_ZERO] action=activate_failed '
        'errorType=${error.runtimeType} '
        'message=${_compactDiagnosticValue(error)}',
      );
      _markCountdownZeroActivationFailed();
    }
  }

  void _markCountdownZeroActivationFailed({
    String source = 'countdown_zero_activation_failed',
  }) {
    _clearPreSosSession(
      reason: source,
      emitIdleState: false,
    );
    _clearPendingAppTriggeredSosBridge(
      reason: source,
    );
    _clearDeviceRuntimeSosOwnership(
      reason: source,
    );
    _publicSosFallbackIncident = null;
    _emitPublicSosState(
      SosState.failed,
      source: source,
    );
  }

  Future<bool> _deviceRuntimeSosAlreadyActive() async {
    final deviceStatus = await deviceSosController.getStatus();
    final deviceSosAlreadyActive =
        deviceStatus.state == DeviceSosState.active ||
            deviceStatus.state == DeviceSosState.acknowledged;
    if (!deviceSosAlreadyActive) {
      return false;
    }
    final incident = await sosRepository.getCurrentIncident();
    return _isDeviceRuntimeSosIncidentId(incident?.id) &&
        _isOpenSosState(incident!.state) &&
        incident.state != SosState.arming;
  }

  bool _isDeviceRuntimeSosIncidentId(String? incidentId) {
    return incidentId != null && incidentId.startsWith('device-runtime-sos:');
  }

  bool _isDeviceRuntimeSosCycleKey(String? cycleKey) {
    return cycleKey != null &&
        (cycleKey.startsWith('sos:') || cycleKey.startsWith('sos-cycle:sos:'));
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
      cycleKey: session.cycleKey,
      owner: session.owner == _SosOwner.device
          ? PublicPreSosOwner.device
          : PublicPreSosOwner.app,
      originatorNodeId: session.originatorNodeId,
      packetId: session.packetId,
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

  bool _samePreSosInstant(DateTime first, DateTime second) {
    return first.toUtc().isAtSameMomentAs(second.toUtc());
  }

  bool _isPreSosSessionExpired(_PreSosSession session) {
    return !DateTime.now().isBefore(session.expectedActivationAt);
  }

  String? _preSosCycleKeyFromDeviceStatus(DeviceSosStatus status) {
    final nodeId = status.nodeId ?? _knownLocalDeviceNodeId;
    final packetId = status.packetId;
    if (nodeId != null && packetId != null) {
      return 'sos:$nodeId:$packetId';
    }
    final signature = status.lastPacketSignature;
    if (signature != null && signature.trim().isNotEmpty) {
      return 'sos:${signature.trim()}';
    }
    return null;
  }

  String _newLocalPreSosCycleKey(DateTime startedAt) {
    return 'app:${startedAt.toUtc().microsecondsSinceEpoch}';
  }

  bool _isSamePreSosCycle(
    _PreSosSession session, {
    required String incomingCycleKey,
    required int? incomingOriginatorNodeId,
    required int? incomingPacketId,
  }) {
    if (session.cycleKey == incomingCycleKey) {
      return true;
    }
    if (session.owner == _SosOwner.app &&
        session.mirroredOnDevice &&
        incomingCycleKey.startsWith('sos:')) {
      if (session.originatorNodeId == null && session.packetId == null) {
        return true;
      }
      final sameNode = session.originatorNodeId != null &&
          incomingOriginatorNodeId != null &&
          session.originatorNodeId == incomingOriginatorNodeId;
      if (!sameNode) {
        return false;
      }
      return session.packetId == null ||
          incomingPacketId == null ||
          session.packetId == incomingPacketId;
    }
    return session.originatorNodeId != null &&
        incomingOriginatorNodeId != null &&
        session.packetId != null &&
        incomingPacketId != null &&
        session.originatorNodeId == incomingOriginatorNodeId &&
        session.packetId == incomingPacketId;
  }

  void _logIgnoredPreSosTickOnce({
    required int staleCycle,
    required int currentCycle,
  }) {
    if (!_loggedIgnoredPreSosTickCycles.add(staleCycle)) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      '[APP_PRE_SOS_CANCEL] action=ignore_stale_tick '
      'staleCycle=$staleCycle currentCycle=$currentCycle',
    );
  }

  void _publishPreSosStatus(PublicPreSosStatus? status) {
    if (status == null &&
        _shouldKeepSdkPreSosArmingState(
          incoming: SosState.idle,
          source: 'pre_sos_status_clear',
        )) {
      _logSosRuntimePrecedence(
        incomingSource: 'pre_sos_status_clear',
        incoming: SosState.idle,
        decision: 'keep_sdk_pre_sos_arming',
        reason: _runtimePrecedenceKeepReason(),
      );
      if (_publicSosState != SosState.arming) {
        _emitPublicSosState(SosState.arming, source: 'pre_sos_status_guard');
      }
      return;
    }
    if (_equivalentPreSosStatus(_lastPublishedPreSosStatus, status)) {
      return;
    }
    _lastPublishedPreSosStatus = status;
    if (!_publicPreSosStatusController.isClosed) {
      _publicPreSosStatusController.add(status);
    }
    if (status != null && _publicSosState != SosState.arming) {
      _emitPublicSosState(SosState.arming, source: 'pre_sos_status');
    }
  }

  bool _equivalentPreSosStatus(
    PublicPreSosStatus? previous,
    PublicPreSosStatus? next,
  ) {
    if (identical(previous, next)) {
      return true;
    }
    if (previous == null || next == null) {
      return false;
    }
    return previous.active == next.active &&
        previous.startedAt == next.startedAt &&
        previous.expectedActivationAt == next.expectedActivationAt &&
        previous.remainingSeconds == next.remainingSeconds &&
        previous.mirroredOnDevice == next.mirroredOnDevice &&
        previous.origin == next.origin &&
        previous.cycleKey == next.cycleKey &&
        previous.owner == next.owner &&
        previous.originatorNodeId == next.originatorNodeId &&
        previous.packetId == next.packetId;
  }

  Future<void> _clearSosNotificationsSafely({
    required String reason,
  }) async {
    if (!_sdkSosNotificationsEnabled) {
      BleDebugRegistry.instance.recordEvent(
        '[NOTIFICATION_FLOW] sdk_local_notification_skip '
        'type=sosClear reason=hostAppManaged',
      );
      return;
    }
    try {
      await notificationsRepository.clearSosNotifications();
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'SOS notification cleanup failed -> reason=$reason error=$error',
      );
      debugPrint('SOS notification cleanup failed: $error');
    }
  }

  void _clearPreSosSession({
    required String reason,
    required bool emitIdleState,
  }) {
    final session = _preSosSession;
    if (session == null) {
      if (emitIdleState) {
        _emitPublicSosState(SosState.idle, source: 'pre_sos_clear_empty');
      }
      return;
    }
    final cycleRevision = session.cycleRevision;
    session.timer.cancel();
    _preSosCycleRevision++;
    _loggedIgnoredPreSosTickCycles.remove(cycleRevision);
    BleDebugRegistry.instance.recordEvent(
      '[APP_PRE_SOS_CANCEL] action=timer_cancelled cycle=$cycleRevision',
    );
    _preSosSession = null;
    unawaited(_clearPersistedPreSosSession());
    _publishPreSosStatus(null);
    BleDebugRegistry.instance.recordEvent(
      'Public PRE-SOS session cleared -> reason=$reason origin=${session.origin?.name ?? "-"} owner=${session.owner.name} mirroredOnDevice=${session.mirroredOnDevice}',
    );
    BleDebugRegistry.instance.recordEvent(
      '[APP_PRE_SOS_CANCEL] action=state_cleared cycle=$cycleRevision',
    );
    if (emitIdleState) {
      _emitPublicSosState(SosState.idle, source: reason);
    }
  }

  void _emitPublicSosState(
    SosState state, {
    String source = 'unspecified',
  }) {
    final stateAfterRuntimePrecedence = _applyPublicSosRuntimePrecedence(
      incoming: state,
      source: source,
    );
    final nextState = _preserveDeviceRuntimeSosStateIfNeeded(
      incoming: stateAfterRuntimePrecedence,
      source: source,
    );
    if (nextState == _publicSosState) {
      return;
    }
    _publicSosState = nextState;
    if (!_publicSosStateController.isClosed) {
      _publicSosStateController.add(nextState);
    }
    unawaited(
      _updateBackgroundTelemetryState(reason: 'sos_state:${nextState.name}'),
    );
  }

  SosState _applyPublicSosRuntimePrecedence({
    required SosState incoming,
    required String source,
  }) {
    if (!_shouldKeepSdkPreSosArmingState(
      incoming: incoming,
      source: source,
    )) {
      if (_isClosingPublicSosState(incoming)) {
        _logSosRuntimePrecedence(
          incomingSource: source,
          incoming: incoming,
          decision: 'apply_idle_or_terminal',
          reason: _runtimePrecedenceApplyReason(),
        );
      }
      return incoming;
    }
    _logSosRuntimePrecedence(
      incomingSource: source,
      incoming: incoming,
      decision: 'keep_sdk_pre_sos_arming',
      reason: _runtimePrecedenceKeepReason(),
    );
    return SosState.arming;
  }

  SosState _publicSosStateFromRepositoryLoad({
    required SosState incoming,
    required String source,
  }) {
    final runtimePrecedenceState = _applyPublicSosRuntimePrecedence(
      incoming: incoming,
      source: source,
    );
    return _preserveDeviceRuntimeSosStateIfNeeded(
      incoming: runtimePrecedenceState,
      source: source,
    );
  }

  bool _shouldKeepSdkPreSosArmingState({
    required SosState incoming,
    required String source,
  }) {
    if (!_isClosingPublicSosState(incoming)) {
      return false;
    }
    if (_publicSosClosureInFlight != null) {
      return false;
    }
    if (_buildCurrentPreSosStatus() != null) {
      return true;
    }
    if (!_runtimeProtectionActiveForPreSos()) {
      return false;
    }
    return _publicSosState == SosState.arming ||
        _preSosSession != null ||
        _lastPublishedPreSosStatus != null ||
        deviceSosController.currentStatus.state == DeviceSosState.preConfirm;
  }

  String _runtimePrecedenceKeepReason() {
    if (_buildCurrentPreSosStatus() != null) {
      return 'sdk_pre_sos_active';
    }
    if (_runtimeProtectionActiveForPreSos()) {
      return 'runtime_pre_sos_active';
    }
    return 'unknown';
  }

  bool _isClosingPublicSosState(SosState state) {
    return state == SosState.idle ||
        state == SosState.failed ||
        _isTerminalPublicSosState(state);
  }

  String _runtimePrecedenceApplyReason() {
    if (_publicSosClosureInFlight == _SosClosureIntent.cancel) {
      return 'user_cancel_in_flight';
    }
    if (_publicSosClosureInFlight == _SosClosureIntent.resolve) {
      return 'resolve_in_flight';
    }
    if (_buildCurrentPreSosStatus() != null) {
      return 'sdk_pre_sos_active';
    }
    if (!_runtimeProtectionActiveForPreSos()) {
      return 'runtime_inactive';
    }
    if (_publicSosState != SosState.arming &&
        _preSosSession == null &&
        _lastPublishedPreSosStatus == null &&
        deviceSosController.currentStatus.state != DeviceSosState.preConfirm) {
      return 'sent_transition';
    }
    return 'current_cycle_terminal';
  }

  void _logSosRuntimePrecedence({
    required String incomingSource,
    required SosState incoming,
    required String decision,
    required String reason,
  }) {
    final status = _protectionModeController.currentStatus;
    final currentPreSosStatus =
        _buildCurrentPreSosStatus() ?? _lastPublishedPreSosStatus;
    final currentTerminal = _isOpenSosState(_publicSosState)
        ? 'open'
        : _isTerminalPublicSosState(_publicSosState)
            ? _publicSosState.name
            : _publicSosState.name;
    final incomingTerminal = _isOpenSosState(incoming)
        ? 'open'
        : _isTerminalPublicSosState(incoming)
            ? incoming.name
            : incoming.name;
    final deviceId = _lastDeviceStatus?.nodeId?.toString() ??
        status.activeDeviceId ??
        status.protectedDeviceId ??
        _lastDeviceStatus?.deviceId ??
        'none';
    final commandAvailable = deviceSosController.shortCommandAvailable ||
        deviceSosController.longCommandAvailable;
    BleDebugRegistry.instance.recordEvent(
      '[SOS_RUNTIME_PRECEDENCE] '
      'action=sos_runtime_precedence '
      'incomingSource=$incomingSource '
      'incomingStage=${incoming.name} '
      'incomingTerminal=$incomingTerminal '
      'incomingCountdown=none '
      'currentStage=${_publicSosState.name} '
      'currentTerminal=$currentTerminal '
      'currentCountdown=${currentPreSosStatus?.remainingSeconds.toString() ?? "none"} '
      'runtimeMode=${status.modeState.name} '
      'runtimeState=${status.runtimeState.name} '
      'runtimeActive=${_runtimeProtectionActiveForPreSos()} '
      'deviceConnected=${status.deviceConnected} '
      'commandAvailable=$commandAvailable '
      'deviceId=$deviceId '
      'incomingIncidentId=${_publicSosFallbackIncident?.id ?? _lastPublicSosIncidentId ?? "none"} '
      'currentIncidentId=${_currentDeviceRuntimeUiIncidentId() ?? _lastPublicSosIncidentId ?? "none"} '
      'decision=$decision '
      'reason=$reason',
    );
  }

  SosState _preserveDeviceRuntimeSosStateIfNeeded({
    required SosState incoming,
    required String source,
  }) {
    if (!_shouldPreserveDeviceRuntimeSosAgainst(incoming)) {
      return incoming;
    }
    final preserved = _deviceRuntimeInvariantFallbackState();
    _logDeviceRuntimeInvariantPreserved(
      source: source,
      rejectedState: incoming,
      preservedState: preserved,
    );
    return preserved;
  }

  bool _shouldPreserveDeviceRuntimeSosAgainst(SosState incoming) {
    if (!_canSurfaceDeviceRuntimeOpenSos()) {
      return false;
    }
    if (!_hasOpenDeviceRuntimeSosInvariant() &&
        !_hasOpenDeviceRuntimeIdleRegressionRisk()) {
      return false;
    }
    if (incoming == SosState.idle &&
        _hasOpenDeviceRuntimeIdleRegressionRisk()) {
      return true;
    }
    return incoming == SosState.idle || incoming == SosState.failed;
  }

  bool _canSurfaceDeviceRuntimeOpenSos() {
    return _hasNonRuntimeVisibleSosIncident(_lastKnownActiveSosIncident) ||
        (_deviceOwnedBackendIncidentId?.trim().isNotEmpty ?? false);
  }

  bool _shouldSuppressDeviceRuntimeOpenSosState({
    required SosState? state,
    required String source,
  }) {
    if (state == null || !_isOpenSosState(state)) {
      return false;
    }
    if (_canSurfaceDeviceRuntimeOpenSos()) {
      return false;
    }
    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_SOS_REHYDRATE] trigger=$source '
      'decision=suppress_device_only_open_state incoming=${state.name} '
      'reason=backend_required',
    );
    return true;
  }

  bool _shouldSuppressDeviceRuntimePublicIncident(
    SosIncident? incident, {
    required SosIncident? backendIncident,
    required String source,
  }) {
    if (incident == null || !_isOpenSosState(incident.state)) {
      return false;
    }
    if (_hasNonRuntimeVisibleSosIncident(backendIncident) ||
        _canSurfaceDeviceRuntimeOpenSos()) {
      return false;
    }
    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_SOS_REHYDRATE] trigger=$source '
      'decision=suppress_device_only_incident '
      'incidentId=${incident.id} state=${incident.state.name} '
      'reason=backend_required',
    );
    return true;
  }

  bool _hasOpenDeviceRuntimeIdleRegressionRisk() {
    if (!_hasActiveDeviceRuntimeSosOwnership()) {
      return false;
    }
    if (!_isOpenSosState(_publicSosState)) {
      return false;
    }
    final cycleNodeId =
        _parseDeviceRuntimeNodeId(_activeDeviceRuntimeIncidentId) ??
            _parseSosCycleNodeId(_activeDeviceRuntimeCycleKey) ??
            _parseSosCycleNodeId(_activeDeviceSosCycleKey);
    return cycleNodeId != null || _activeDeviceRuntimeIncidentId != null;
  }

  bool _hasOpenDeviceRuntimeSosInvariant() {
    if (!_hasActiveDeviceRuntimeSosOwnership()) {
      return false;
    }
    return _publicSosState != SosState.cancelled &&
        _publicSosState != SosState.resolved;
  }

  SosState _deviceRuntimeInvariantFallbackState() {
    if (_isOpenSosState(_publicSosState)) {
      return _publicSosState;
    }
    if (_publicSosState == SosState.acknowledged) {
      return SosState.acknowledged;
    }
    return SosState.sent;
  }

  SosIncident _activeDeviceRuntimeFallbackIncident() {
    return SosIncident(
      id: _activeDeviceRuntimeIncidentId ?? 'device-runtime-sos:unknown',
      state: _deviceRuntimeInvariantFallbackState(),
      createdAt: DateTime.now().toUtc(),
      triggerSource: 'ble_device_runtime_status',
      deliveryChannel: SosDeliveryChannel.deviceOnly,
    );
  }

  void _logDeviceRuntimeInvariantPreserved({
    required String source,
    required SosState rejectedState,
    required SosState preservedState,
  }) {
    final cycleId = _activeDeviceRuntimeCycleKey ??
        _activeDeviceSosCycleKey ??
        _activeDeviceRuntimeIncidentId ??
        'unknown';
    final reason = rejectedState == SosState.idle
        ? 'stale_idle_during_device_sos'
        : 'backend_failure_during_device_sos';
    final key = '$cycleId|$source|$reason';
    if (!_shouldLogThrottled(
      _sosRuntimeInvariantLogByKey,
      key,
      const Duration(seconds: 10),
    )) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_RUNTIME_INVARIANT_PRESERVED '
      'cycleId=$cycleId source=$source reason=$reason '
      'rejected=${rejectedState.name} preserved=${preservedState.name} '
      'activeIncident=${_activeDeviceRuntimeIncidentId ?? "none"} '
      'activeCycle=${_activeDeviceRuntimeCycleKey ?? "none"}',
    );
    _logSosRejectionThrottled(
      cycleId: cycleId,
      source: source,
      reason: reason,
      message: rejectedState == SosState.idle
          ? '[APP_SOS_RECONCILE] decision=reject_open_sos_idle_regression '
              'reason=stale_idle_during_open_sos cycleId=$cycleId '
              'source=$source previous_stage=${_publicSosState.name} '
              'incoming_stage=${rejectedState.name} previous_terminal=open '
              'incoming_terminal=idle '
              'activeIncident=${_activeDeviceRuntimeIncidentId ?? "none"}'
          : 'APP_SOS_RECONCILE rejected_device_sos_regression '
              'cycleId=$cycleId source=$source reason=$reason '
              'activeIncident=${_activeDeviceRuntimeIncidentId ?? "none"}',
    );
  }

  bool _shouldLogThrottled(
    Map<String, DateTime> cache,
    String key,
    Duration window,
  ) {
    final now = DateTime.now().toUtc();
    cache.removeWhere((_, seenAt) => now.difference(seenAt) > window);
    final lastSeen = cache[key];
    if (lastSeen != null && now.difference(lastSeen) <= window) {
      return false;
    }
    cache[key] = now;
    return true;
  }

  void _logSosRejectionThrottled({
    required String cycleId,
    required String source,
    required String reason,
    required String message,
  }) {
    final key = '$cycleId|$source|$reason';
    if (!_shouldLogThrottled(
      _sosRejectionLogByKey,
      key,
      const Duration(seconds: 10),
    )) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(message);
  }

  Future<void> _syncPublicSosStateFromRepository(SosState state) async {
    final deviceOverride = await _rehydrateDeviceSosPublicState(
      trigger: 'repository_stream:${state.name}',
      emitResolvedState: false,
    );
    if (deviceOverride != null) {
      _emitPublicSosState(
        deviceOverride,
        source: 'sos_state_stream:device_override',
      );
      return;
    }
    if (_publicSosFallbackIncident != null || _publicSosActionInFlight) {
      return;
    }
    if (_shouldIgnoreStaleRepositoryTerminalDuringPreSos(
      incoming: state,
      source: 'sos_state_stream',
    )) {
      return;
    }
    if (_isTerminalPublicSosState(state) &&
        await _isCurrentRepositoryTerminalSosAcknowledged()) {
      _logSosTerminalArbitration(
        incomingSource: 'sos_state_stream',
        incomingRaw: state,
        decision: 'apply_terminal',
        reason: 'current_cycle_terminal_acknowledged',
      );
      _emitPublicSosState(SosState.idle,
          source: 'sos_state_stream:acknowledged');
      return;
    }
    if (_isTerminalPublicSosState(state)) {
      _logSosTerminalArbitration(
        incomingSource: 'sos_state_stream',
        incomingRaw: state,
        decision: 'apply_terminal',
        reason: _runtimeProtectionActiveForPreSos()
            ? 'current_cycle_terminal'
            : 'runtime_inactive',
      );
    }
    _emitPublicSosState(state, source: 'sos_state_stream');
  }

  bool _shouldIgnoreStaleRepositoryTerminalDuringPreSos({
    required SosState incoming,
    required String source,
  }) {
    if (!_isTerminalPublicSosState(incoming)) {
      return false;
    }
    if (_publicSosActionInFlight) {
      _logSosTerminalArbitration(
        incomingSource: source,
        incomingRaw: incoming,
        decision: 'apply_terminal',
        reason: 'user_cancelled',
      );
      return false;
    }
    final preSosStatus = _buildCurrentPreSosStatus();
    final hasActivePreSos =
        preSosStatus != null || _publicSosState == SosState.arming;
    if (!hasActivePreSos || !_runtimeProtectionActiveForPreSos()) {
      return false;
    }
    _logSosTerminalArbitration(
      incomingSource: source,
      incomingRaw: incoming,
      decision: 'ignore_stale_terminal_keep_runtime_arming',
      reason: 'runtime_pre_sos_active',
    );
    if (_publicSosState != SosState.arming) {
      _emitPublicSosState(SosState.arming, source: '$source:pre_sos_guard');
    }
    return true;
  }

  bool _runtimeProtectionActiveForPreSos() {
    final status = _protectionModeController.currentStatus;
    return status.deviceConnected &&
        (status.protectionRuntimeActive ||
            status.modeState == ProtectionModeState.armed ||
            status.modeState == ProtectionModeState.arming ||
            status.runtimeState == ProtectionRuntimeState.active ||
            status.runtimeState == ProtectionRuntimeState.recovering);
  }

  void _logSosTerminalArbitration({
    required String incomingSource,
    required SosState incomingRaw,
    required String decision,
    required String reason,
  }) {
    final status = _protectionModeController.currentStatus;
    final preSosStatus = _buildCurrentPreSosStatus();
    final currentTerminal = _isOpenSosState(_publicSosState)
        ? 'open'
        : _isTerminalPublicSosState(_publicSosState)
            ? _publicSosState.name
            : _publicSosState.name;
    final incomingIncidentId = _publicSosFallbackIncident?.id ??
        _lastKnownActiveSosIncident?.id ??
        _lastPublicSosIncidentId ??
        'none';
    BleDebugRegistry.instance.recordEvent(
      '[SOS_TERMINAL_ARBITRATION] '
      'action=sos_terminal_arbitration '
      'incomingSource=$incomingSource '
      'incomingRaw=${incomingRaw.name} '
      'incomingIncidentId=$incomingIncidentId '
      'currentStage=${_publicSosState.name} '
      'currentTerminal=$currentTerminal '
      'currentCountdown=${preSosStatus?.remainingSeconds.toString() ?? "none"} '
      'runtimeMode=${status.modeState.name} '
      'runtimeState=${status.runtimeState.name} '
      'runtimeActive=${_runtimeProtectionActiveForPreSos()} '
      'deviceConnected=${status.deviceConnected} '
      'decision=$decision '
      'reason=$reason',
    );
  }

  Future<bool> _isCurrentRepositoryTerminalSosAcknowledged() async {
    final incident = await sosRepository.getCurrentIncident();
    return _isAcknowledgedTerminalSosIncident(incident);
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

    if (_shouldSuppressDeviceRuntimeOpenSosState(
      state: chosenPublicState,
      source: trigger,
    )) {
      chosenPublicState = null;
    }

    if (chosenPublicState != null &&
        _isTerminalPublicSosState(chosenPublicState) &&
        _acknowledgedTerminalSosWithoutIncident) {
      BleDebugRegistry.instance.recordEvent(
        '[DEVICE_SOS_REHYDRATE] trigger=$trigger '
        'decision=suppress_acknowledged_terminal incoming=${chosenPublicState.name}',
      );
      chosenPublicState = null;
    }

    if (chosenPublicState != null &&
        _isTerminalPublicSosState(chosenPublicState) &&
        _isTerminalPublicSosState(_publicSosState) &&
        chosenPublicState != _publicSosState) {
      BleDebugRegistry.instance.recordEvent(
        '[DEVICE_SOS_REHYDRATE] trigger=$trigger '
        'decision=keep_existing_terminal existing=${_publicSosState.name} '
        'incoming=${chosenPublicState.name}',
      );
      chosenPublicState = _publicSosState;
    }

    if (emitResolvedState && chosenPublicState != null) {
      _emitPublicSosState(chosenPublicState, source: trigger);
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
        _activeDeviceRuntimeCycleKey?.replaceFirst('sos-cycle:', '') ??
        status.lastPacketSignature ??
        'device-runtime-${status.updatedAt.microsecondsSinceEpoch}';
    final runtimeIncidentId = 'device-runtime-$cycleKey';
    if (_isOpenSosState(publicState) &&
        _isClosedDeviceRuntimeIncidentId(runtimeIncidentId)) {
      BleDebugRegistry.instance.recordEvent(
        '[APP_SOS_STALE_ACTIVE_SUPPRESSED] reason=device_terminal_closed_cycle '
        'affectsReadiness=false incidentId=$runtimeIncidentId',
      );
      return null;
    }
    final activeRuntimeIncidentId = _currentDeviceRuntimeUiIncidentId();
    if (_isTerminalPublicSosState(publicState) &&
        activeRuntimeIncidentId != null &&
        _sameDeviceRuntimeCycle(
          status: status,
          incidentId: activeRuntimeIncidentId,
        )) {
      return SosIncident(
        id: activeRuntimeIncidentId,
        state: publicState,
        createdAt: (status.countdownStartedAt ?? status.updatedAt).toUtc(),
        triggerSource: 'ble_device_runtime_status',
        deliveryChannel: SosDeliveryChannel.deviceOnly,
      );
    }
    return SosIncident(
      id: runtimeIncidentId,
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
      'E_SOS_BACKEND_NOT_CONFIRMED',
      'SOS could not be sent because the backend did not confirm incident creation.',
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

    if (status.nodeId != null) {
      await ensureBackendDeviceRegistered(
        nodeId: status.nodeId!,
        bleHardwareId: _canonicalHardwareIdForStatus(status),
        firmwareVersion: status.firmwareVersion,
        hardwareModel: status.model ?? status.deviceAlias,
        pairedAt: status.lastSeen ?? DateTime.now().toUtc(),
        reason: 'registered_device_auto_sync:$trigger',
      );
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      'Registered device auto-sync skipped -> reason=missing_node_id '
      'trigger=$trigger runtimeDeviceId=${status.deviceId} '
      'bleHardwareId=${status.canonicalHardwareId ?? "none"}',
    );
  }

  Future<void> _seedPreferredBleDeviceFromBackendRegistryIfNeeded({
    required String trigger,
  }) async {
    final manualDisconnectRequested =
        await preferredBleDeviceStore.readManualDisconnectRequested();
    _manualDisconnectRequested = manualDisconnectRequested;
    if (manualDisconnectRequested) {
      await preferredBleDeviceStore.clearPreferredDevice();
      _clearDeviceRuntimeResidueAfterManualDisconnect();

      return;
    }
    final existingPreferred =
        await preferredBleDeviceStore.getPreferredDevice();
    if (existingPreferred != null) {
      return;
    }
    final status =
        _lastDeviceStatus ?? await deviceRepository.getDeviceStatus();
    if (status.paired && status.deviceId.trim().isNotEmpty) {
      return;
    }
    if (!_hasSignedSessionIdentityReadyForDeviceRegistrySync()) {
      return;
    }

    final registeredDevices =
        await deviceRegistryRepository.listRegisteredDevices();
    final candidate =
        _preferredReconnectCandidateFromRegistry(registeredDevices);
    if (candidate == null) {
      return;
    }

    final preferredDevice = PreferredDevice(
      deviceId: candidate.hardwareId.trim(),
      displayName: candidate.hardwareModel.trim().isEmpty
          ? null
          : candidate.hardwareModel.trim(),
      lastConnectedAt: candidate.updatedAt,
    );
    final restoredNodeId = _preferredNodeIdCandidateFromRegistry(
      registeredDevices,
      bleHardwareId: preferredDevice.deviceId,
    );
    if (restoredNodeId != null) {
      _knownLocalDeviceNodeId = restoredNodeId;
      _sosRuntimeNodeIdByHardwareId[preferredDevice.deviceId] = restoredNodeId;
    }
    await preferredBleDeviceStore.savePreferredDevice(preferredDevice);
    await preferredBleDeviceStore.saveManualDisconnectRequested(false);

    BleDebugRegistry.instance.recordEvent(
      'Preferred BLE device restored from backend registry -> trigger=$trigger bleHardwareId=${preferredDevice.deviceId} nodeId=${restoredNodeId?.toString() ?? "none"}',
    );
  }

  BackendRegisteredDevice? _preferredReconnectCandidateFromRegistry(
    List<BackendRegisteredDevice> devices,
  ) {
    final candidates = devices
        .where((device) => device.hardwareId.trim().isNotEmpty)
        .toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) {
      final aIsBleId = isBleMacDeviceId(a.hardwareId);
      final bIsBleId = isBleMacDeviceId(b.hardwareId);
      if (aIsBleId != bIsBleId) {
        return aIsBleId ? -1 : 1;
      }
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return candidates.first;
  }

  int? _preferredNodeIdCandidateFromRegistry(
    List<BackendRegisteredDevice> devices, {
    required String bleHardwareId,
  }) {
    final candidates = devices.where((device) {
      final hardwareId = device.hardwareId.trim();
      return hardwareId.isNotEmpty &&
          hardwareId != bleHardwareId &&
          !isBleMacDeviceId(hardwareId) &&
          int.tryParse(hardwareId) != null;
    }).toList(growable: false);
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return int.tryParse(candidates.first.hardwareId.trim())?.toUnsigned(32);
  }

  String? _currentDeviceRuntimeUiIncidentId() {
    final active = _activeDeviceRuntimeIncidentId;
    if (_isDeviceRuntimeSosIncidentId(active)) {
      return active;
    }
    final fallback = _publicSosFallbackIncident?.id;
    if (_isDeviceRuntimeSosIncidentId(fallback)) {
      return fallback;
    }
    final lastPublic = _lastPublicSosIncidentId;
    if (_isDeviceRuntimeSosIncidentId(lastPublic)) {
      return lastPublic;
    }
    final activeCycle = _activeDeviceRuntimeCycleKey;
    if (_isDeviceRuntimeSosCycleKey(activeCycle)) {
      return 'device-runtime-${activeCycle!.replaceFirst('sos-cycle:', '')}';
    }
    final deviceSosCycle = _activeDeviceSosCycleKey;
    if (_isDeviceRuntimeSosCycleKey(
      deviceSosCycle == null ? null : 'sos-cycle:$deviceSosCycle',
    )) {
      return 'device-runtime-$deviceSosCycle';
    }
    return null;
  }

  bool _isTerminalPublicSosState(SosState state) {
    return state == SosState.resolved || state == SosState.cancelled;
  }

  void _rememberAcknowledgedTerminalSosIncident(SosIncident? incident) {
    _acknowledgedTerminalSosWithoutIncident = true;
    final ids = _terminalSosIncidentIds(incident);
    if (ids.isEmpty) {
      return;
    }
    _acknowledgedTerminalSosIncidentIds.addAll(ids);
    while (_acknowledgedTerminalSosIncidentIds.length > 24) {
      _acknowledgedTerminalSosIncidentIds.remove(
        _acknowledgedTerminalSosIncidentIds.first,
      );
    }
  }

  bool _isAcknowledgedTerminalSosIncident(SosIncident? incident) {
    if (!_isTerminalBackendSosIncident(incident)) {
      return false;
    }
    final ids = _terminalSosIncidentIds(incident);
    if (ids.isEmpty) {
      return _acknowledgedTerminalSosWithoutIncident;
    }
    return ids.any(_acknowledgedTerminalSosIncidentIds.contains);
  }

  Set<String> _terminalSosIncidentIds(SosIncident? incident) {
    final ids = <String>{};
    final id = incident?.id.trim();
    if (id != null && id.isNotEmpty) {
      ids.add(id);
    }
    return ids;
  }

  void _clearAcknowledgedTerminalSosSummaries({required String reason}) {
    if (_acknowledgedTerminalSosIncidentIds.isEmpty &&
        !_acknowledgedTerminalSosWithoutIncident) {
      return;
    }
    _acknowledgedTerminalSosIncidentIds.clear();
    _acknowledgedTerminalSosWithoutIncident = false;
    BleDebugRegistry.instance.recordEvent(
      '[SOS_SUMMARY_ACK] action=clear_acknowledged reason=$reason',
    );
  }

  bool _sameDeviceRuntimeCycle({
    required DeviceSosStatus status,
    required String incidentId,
  }) {
    final activeNodeId = _parseDeviceRuntimeNodeId(incidentId);
    if (activeNodeId == null) {
      return true;
    }
    final statusNodeId = status.nodeId ??
        _parseDeviceRuntimeNodeId(status.lastPacketSignature) ??
        _parseSosCycleNodeId(status.lastPacketSignature) ??
        _knownLocalDeviceNodeId;
    return statusNodeId == null || statusNodeId == activeNodeId;
  }

  List<String> _availableLocalGuardIncidentIds() {
    final ids = _nonEmptyStrings(<String?>[
      _activeDeviceRuntimeIncidentId,
      _currentDeviceRuntimeUiIncidentId(),
      _activeDeviceRuntimeCycleKey,
      _activeDeviceSosCycleKey,
      _publicSosFallbackIncident?.id,
      _lastPublicSosIncidentId,
      _deviceOwnedBackendIncidentId,
    ]).toSet().toList();
    return ids.isEmpty ? <String>['none'] : ids;
  }

  List<String> _availableLocalGuardDeviceIds() {
    final ids = _nonEmptyStrings(<String?>[
      _lastPublicDeviceStatus?.nodeId?.toString(),
      _lastDeviceStatus?.nodeId?.toString(),
      _knownLocalDeviceNodeId?.toString(),
      _lastPublicDeviceStatus?.deviceId,
      _lastDeviceStatus?.deviceId,
      _lastPublicDeviceStatus?.canonicalHardwareId,
      _lastDeviceStatus?.canonicalHardwareId,
    ]).toSet().toList();
    return ids.isEmpty ? <String>['none'] : ids;
  }

  List<String> _nonEmptyStrings(List<String?> values) {
    return values
        .whereType<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
  }

  Future<void> ensureBackendDeviceRegistered({
    required int nodeId,
    String? bleHardwareId,
    String? firmwareVersion,
    String? hardwareModel,
    DateTime? pairedAt,
    required String reason,
  }) {
    final backendHardwareId = nodeId.toString();
    if (_backendRegisteredNodeIdsForSession.contains(backendHardwareId)) {
      return Future<void>.value();
    }
    final existing =
        _backendDeviceRegistrationInFlightByNodeId[backendHardwareId];
    if (existing != null) {
      return existing;
    }
    final future = _ensureBackendDeviceRegisteredInternal(
      nodeId: nodeId,
      backendHardwareId: backendHardwareId,
      bleHardwareId: bleHardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
      reason: reason,
    );
    _backendDeviceRegistrationInFlightByNodeId[backendHardwareId] = future;
    return future.whenComplete(() {
      if (identical(
        _backendDeviceRegistrationInFlightByNodeId[backendHardwareId],
        future,
      )) {
        _backendDeviceRegistrationInFlightByNodeId.remove(backendHardwareId);
      }
    });
  }

  void _clearBackendDeviceRegistrationSessionCache() {
    _backendRegisteredNodeIdsForSession.clear();
    _backendDeviceRegistrationInFlightByNodeId.clear();
  }

  Future<void> _ensureBackendDeviceRegisteredInternal({
    required int nodeId,
    required String backendHardwareId,
    String? bleHardwareId,
    String? firmwareVersion,
    String? hardwareModel,
    DateTime? pairedAt,
    required String reason,
  }) async {
    final normalizedFirmware = firmwareVersion?.trim() ?? '';
    final normalizedModel = hardwareModel?.trim() ?? '';
    final normalizedPairedAt = (pairedAt ?? DateTime.now()).toUtc();
    final payload = <String, dynamic>{
      'hardware_id': backendHardwareId,
      'firmware_version': normalizedFirmware,
      'hardware_model': normalizedModel,
      'paired_at': normalizedPairedAt.toIso8601String(),
    };
    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_BACKEND_REGISTER_OUTBOUND] endpoint=/v1/sdk/devices '
      'backendHardwareId=$backendHardwareId nodeId=$nodeId '
      'bleHardwareId=${bleHardwareId ?? "none"} '
      'firmwareVersion=$normalizedFirmware '
      'hardwareModel=$normalizedModel '
      'pairedAt=${normalizedPairedAt.toIso8601String()} '
      'reason=$reason payload=${_compactJson(payload)}',
    );
    try {
      final registered = await deviceRegistryRepository.upsertRegisteredDevice(
        hardwareId: backendHardwareId,
        firmwareVersion: normalizedFirmware,
        hardwareModel: normalizedModel,
        pairedAt: normalizedPairedAt,
      );
      _backendRegisteredNodeIdsForSession.add(backendHardwareId);
      BleDebugRegistry.instance.recordEvent(
        '[DEVICE_BACKEND_REGISTER_RESPONSE] status=ok '
        'backendDeviceId=${registered.id} '
        'backendHardwareId=${registered.hardwareId} '
        'responseSummary=registered',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[DEVICE_BACKEND_REGISTER_RESPONSE] status=error '
        'backendDeviceId=none backendHardwareId=$backendHardwareId '
        'responseSummary=${_compactSummary(error)}',
      );
      rethrow;
    }
  }

  Future<bool> _retrySosAfterBackendDeviceRegistration({
    required String originalCorrelationId,
    required String retryCorrelationId,
    required String signature,
    required String triggerSource,
    required String message,
    required TrackingPosition positionSnapshot,
    required String? deviceId,
    required String? hardwareId,
    required int? originatorNodeId,
    required int? relayNodeId,
    required String? relayDeviceId,
    required String? relayHardwareId,
    required String? incidentId,
    required String? cycleKey,
  }) async {
    final nodeId = originatorNodeId;
    if (nodeId == null) {
      return false;
    }
    final status = _lastDeviceStatus;
    final backendHardwareId = nodeId.toString();
    try {
      await ensureBackendDeviceRegistered(
        nodeId: nodeId,
        bleHardwareId: hardwareId ?? _canonicalHardwareIdForStatus(status),
        firmwareVersion: status?.firmwareVersion,
        hardwareModel: status?.model ?? status?.deviceAlias,
        pairedAt: status?.lastSeen ?? DateTime.now().toUtc(),
        reason: 'sos_backend_retry_after_422',
      );
      BleDebugRegistry.instance.recordEvent(
        '[SOS_BACKEND_RETRY_AFTER_DEVICE_REGISTER] '
        'originalCorrelationId=$originalCorrelationId '
        'retryCorrelationId=$retryCorrelationId '
        'nodeId=$nodeId backendHardwareId=$backendHardwareId '
        'reason=referenced_device_does_not_exist',
      );
      await sosRepository.triggerSos(
        message: message,
        triggerSource: triggerSource,
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
        hardwareId: hardwareId,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: relayDeviceId,
        relayHardwareId: relayHardwareId,
        incidentId: incidentId,
        cycleKey: cycleKey,
      );
      return true;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'SOS backend retry after device registration failed -> '
        'nodeId=$nodeId backendHardwareId=$backendHardwareId '
        'retryCorrelationId=$retryCorrelationId error=$error',
      );
      return false;
    }
  }

  String _compactJson(Map<String, dynamic> payload) {
    final body = payload.entries.map((entry) {
      final value = entry.value;
      if (value is num || value is bool) {
        return '"${entry.key}":$value';
      }
      return '"${entry.key}":"${value.toString().replaceAll('"', r'\"')}"';
    }).join(',');
    return '{$body}';
  }

  String _compactSummary(Object? value, {int maxLength = 500}) {
    final text = value?.toString() ?? 'none';
    final singleLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (singleLine.length <= maxLength) {
      return singleLine;
    }
    return '${singleLine.substring(0, maxLength)}...';
  }

  String? _resolveOperationalDeviceId({
    required int? nodeId,
    required String? backendHardwareId,
  }) {
    if (nodeId != null) {
      return nodeId.toString();
    }
    final hardwareId = backendHardwareId?.trim();
    if (hardwareId == null ||
        hardwareId.isEmpty ||
        isBleMacDeviceId(hardwareId)) {
      return null;
    }
    return hardwareId;
  }

  Future<void> _ensureBackendSosForDeviceOriginatedCycle(
    DeviceSosStatus status, {
    required String triggerSource,
    required String message,
    bool forceDeviceOwned = false,
  }) async {
    if ((!forceDeviceOwned &&
            status.triggerOrigin != DeviceSosTransitionSource.device) ||
        !_isBackendSyncRelevantDeviceSosState(status.state)) {
      return;
    }

    final cycleKey = _deriveDeviceSosCycleKey(status) ??
        'device-runtime:${status.lastPacketSignature ?? status.state.name}';
    final originatorNodeId = _resolveDeviceOriginatedSosNodeId(
      status: status,
      cycleKey: cycleKey,
      incidentId: 'device-runtime-$cycleKey',
    );
    if (originatorNodeId != null) {
      _promoteDeviceNodeIdFromSos(
        nodeId: originatorNodeId,
        source: 'device_originated_sos',
      );
    }
    final localIdentity = await _resolveLocalOperationalSosIdentity();
    if (originatorNodeId != null) {
      try {
        await ensureBackendDeviceRegistered(
          nodeId: originatorNodeId,
          bleHardwareId: localIdentity.hardwareId,
          firmwareVersion: _lastDeviceStatus?.firmwareVersion,
          hardwareModel:
              _lastDeviceStatus?.model ?? _lastDeviceStatus?.deviceAlias,
          pairedAt: _lastDeviceStatus?.lastSeen ?? status.updatedAt,
          reason: 'before_device_originated_sos',
        );
      } catch (error) {
        BleDebugRegistry.instance.recordEvent(
          'Device SOS backend device registration failed before SOS -> '
          'nodeId=$originatorNodeId error=$error',
        );
      }
    }
    if (!_deviceOriginatedBackendSyncInFlight.add(cycleKey)) {
      BleDebugRegistry.instance.recordEvent(
        'Device SOS backend sync skipped -> reason=sync_in_flight cycle=$cycleKey triggerSource=$triggerSource',
      );
      return;
    }

    try {
      final incident = await sosRepository.getCurrentIncident();
      if (_hasNonRuntimeVisibleSosIncident(incident)) {
        _logSosRejectionThrottled(
          cycleId: cycleKey,
          source: triggerSource,
          reason: 'duplicate_device_owned_sos',
          message: 'SOS_BACKEND_PUBLISH_SKIPPED reason=duplicate_owner '
              'owner=device cycle=$cycleKey activeIncident=${incident!.id} '
              'state=${incident.state.name}',
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

      final relayContext = _relayContextFrom(status);
      final relayNodeId = relayContext == null
          ? null
          : _lastDeviceStatus?.nodeId ?? _knownLocalDeviceNodeId;
      final created =
          await _bleOperationalRuntimeBridge.promoteDeviceOriginatedSos(
        signature: 'device_sos:$cycleKey:$triggerSource',
        triggerSource: triggerSource,
        message: message,
        positionSnapshot: positionSnapshot,
        deviceId: originatorNodeId?.toString() ?? localIdentity.deviceId,
        hardwareId: localIdentity.hardwareId,
        originatorNodeId: originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: relayNodeId?.toString(),
        relayHardwareId: relayContext == null
            ? null
            : _lastDeviceStatus?.canonicalHardwareId,
        incidentId: 'device-runtime-$cycleKey',
        cycleKey: 'sos-cycle:$cycleKey',
        relayContext: relayContext,
        summary:
            'device_runtime state=${status.state.name} origin=${status.triggerOrigin.name} cycle=$cycleKey',
      );
      if (created) {
        final createdIncident = await sosRepository.getCurrentIncident();
        if (createdIncident != null) {
          if (_isLocalAppSosIncidentId(createdIncident.id)) {
            _logSosRejectionThrottled(
              cycleId: cycleKey,
              source: triggerSource,
              reason: 'duplicate_device_owned_sos',
              message: 'SOS_BACKEND_PUBLISH_SKIPPED reason=duplicate_owner '
                  'owner=device source=$triggerSource '
                  'incomingIncident=${createdIncident.id} '
                  'activeIncident=${_activeDeviceRuntimeIncidentId ?? "-"} '
                  'cycle=${_activeDeviceRuntimeCycleKey ?? "sos-cycle:$cycleKey"}',
            );
            return;
          }
          if (!_isDeviceRuntimeSosIncidentId(createdIncident.id)) {
            _rememberDeviceOwnedBackendIncidentId(
              backendIncidentId: createdIncident.id,
            );
          }
          final publicIncident = createdIncident.copyWith(
            deliveryChannel: SosDeliveryChannel.backendAndDevice,
          );
          _recordPublicSosResult(
            incident: publicIncident,
            deliveryChannel: SosDeliveryChannel.backendAndDevice,
          );
          _publishSdkEvent(SOSTriggeredEvent(publicIncident.id));
          _emitSosActiveNotificationIntent(
            publicIncident,
            dedupeKey: _sosIntentDedupeKeyForDeviceStatus(status, cycleKey),
            nodeId: status.nodeId,
          );
          BleDebugRegistry.instance.recordEvent(
            'Device SOS backend sync created incident -> incidentId=${publicIncident.id} triggerSource=$triggerSource',
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

    if (_publicSosActionInFlight) {
      BleDebugRegistry.instance.recordEvent(
        'Device SOS backend closure deferred -> incidentId=${incident?.id ?? "-"} '
        'intent=${(rememberedIntent ?? fallbackIntent ?? _SosClosureIntent.cancel).name} '
        'reason=public_sos_action_in_flight',
      );
      return;
    }

    final intent =
        rememberedIntent ?? fallbackIntent ?? _SosClosureIntent.cancel;
    final terminalIncident = await _runBackendTerminalClosure(
      intent: intent,
      status: status,
      cycleKey: cycleKey,
    );
    BleDebugRegistry.instance.recordEvent(
      'Device SOS backend ${intent.name} applied -> '
      'incidentId=${terminalIncident.id}',
    );
  }

  Future<void> _applyBackendClosureForAppTriggeredCycle({
    required DeviceSosStatus status,
    required SosIncident incident,
  }) async {
    if (_isTerminalBackendSosIncident(incident)) {
      return;
    }
    final intent =
        _mapTerminalDeviceStatusToPublicSosState(status) == SosState.resolved
            ? _SosClosureIntent.resolve
            : _SosClosureIntent.cancel;
    try {
      final terminalIncident = await _runBackendTerminalClosure(
        intent: intent,
        status: status,
        cycleKey: _activeDeviceSosCycleKey,
      );
      BleDebugRegistry.instance.recordEvent(
        'App-triggered SOS device-side closure backend ${intent.name} applied -> '
        'incidentId=${terminalIncident.id}',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'App-triggered SOS device-side closure backend ${intent.name} failed -> '
        'incidentId=${incident.id} error=$error',
      );
    }
  }

  Future<SosIncident> _runBackendTerminalClosure({
    required _SosClosureIntent intent,
    required DeviceSosStatus status,
    required String? cycleKey,
  }) async {
    final SosIncident terminal;
    final EixamNotificationIntentType notificationType;
    final EixamNotificationIntentSeverity severity;
    final String titleKey;
    final String bodyKey;
    final String fallbackTitle;
    final String fallbackBody;
    switch (intent) {
      case _SosClosureIntent.cancel:
        terminal = await sosRepository.cancelSos();
        notificationType = EixamNotificationIntentType.sosCancelled;
        severity = EixamNotificationIntentSeverity.info;
        titleKey = 'notification.sos.cancelled.title';
        bodyKey = 'notification.sos.cancelled.body';
        fallbackTitle = 'SOS cancelled';
        fallbackBody = 'The SOS has been cancelled.';
        break;
      case _SosClosureIntent.resolve:
        terminal = await sosRepository.resolveSos();
        notificationType = EixamNotificationIntentType.sosResolved;
        severity = EixamNotificationIntentSeverity.success;
        titleKey = 'notification.sos.resolved.title';
        bodyKey = 'notification.sos.resolved.body';
        fallbackTitle = 'SOS resolved';
        fallbackBody = 'The SOS has been resolved.';
        break;
    }
    _emitSosTerminalNotificationIntent(
      terminal,
      type: notificationType,
      severity: severity,
      titleKey: titleKey,
      bodyKey: bodyKey,
      fallbackTitle: fallbackTitle,
      fallbackBody: fallbackBody,
      dedupeKey: cycleKey == null ? null : 'sos-cycle:$cycleKey',
      nodeId: status.nodeId,
    );
    if (intent == _SosClosureIntent.cancel) {
      _publishCancelledSosEventIfNeeded(terminal);
    }
    return terminal;
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

  bool _shouldCloseDeviceForPublicSos(
    DeviceSosStatus status, {
    required SosIncident? activeIncident,
  }) {
    final backendOrAppSosActive = _hasBackendVisibleSosIncident(
          activeIncident,
        ) ||
        _hasBackendVisibleSosIncident(_publicSosFallbackIncident) ||
        (_publicSosState != SosState.idle &&
            _publicSosState != SosState.cancelled &&
            _publicSosState != SosState.resolved &&
            _publicSosState != SosState.failed);
    final statusAllowsClose = _canCloseDeviceSosForPublicSos(status);
    final shouldClose = backendOrAppSosActive || statusAllowsClose;
    BleDebugRegistry.instance.recordEvent(
      'Public SOS device close decision -> shouldClose=$shouldClose backendOrAppSosActive=$backendOrAppSosActive statusAllowsClose=$statusAllowsClose state=${status.state.name} origin=${status.triggerOrigin.name} incidentId=${activeIncident?.id ?? _publicSosFallbackIncident?.id ?? "-"}',
    );
    return shouldClose;
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

  bool _hasNonRuntimeVisibleSosIncident(SosIncident? incident) {
    return _hasBackendVisibleSosIncident(incident) &&
        !_isDeviceRuntimeSosIncidentId(incident!.id);
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
    DeviceSosStatus status, {
    bool forceDeviceOwned = false,
  }) async {
    if (!forceDeviceOwned &&
        status.triggerOrigin != DeviceSosTransitionSource.device) {
      return;
    }

    if (_isBackendSyncRelevantDeviceSosState(status.state)) {
      await _ensureBackendSosForDeviceOriginatedCycle(
        status,
        triggerSource: 'ble_device_runtime_status',
        message:
            'Device-originated SOS became active in runtime and was promoted to backend sync.',
        forceDeviceOwned: forceDeviceOwned,
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
    await _restorePersistedPreSosSession(trigger: 'getSosState');
    await _settleExpiredPreSosSession(trigger: 'getSosState');
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
      _publicSosState = _applyPublicSosRuntimePrecedence(
        incoming: deviceOverride,
        source: 'fetch_sos_state:device_override',
      );
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> deviceOverride=${deviceOverride.name} '
        'effectiveState=${_publicSosState.name}',
      );
      return _publicSosState;
    }
    if (_publicSosFallbackIncident != null) {
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> fallbackState=${_publicSosState.name}',
      );
      return _publicSosState;
    }
    final repositoryState = await sosRepository.getSosState();
    final runtimePrecedenceState = _applyPublicSosRuntimePrecedence(
      incoming: repositoryState,
      source: 'fetch_sos_state',
    );
    if (runtimePrecedenceState != repositoryState) {
      _publicSosState = runtimePrecedenceState;
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> repositoryState=${repositoryState.name} '
        'effectiveState=${_publicSosState.name} '
        'reason=sdk_pre_sos_precedence',
      );
      return _publicSosState;
    }
    if (_shouldIgnoreStaleRepositoryTerminalDuringPreSos(
      incoming: repositoryState,
      source: 'fetch_sos_state',
    )) {
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> repositoryState=${repositoryState.name} '
        'effectiveState=${_publicSosState.name} '
        'reason=runtime_pre_sos_terminal_guard',
      );
      return _publicSosState;
    }
    if (_isTerminalPublicSosState(repositoryState) &&
        await _isCurrentRepositoryTerminalSosAcknowledged()) {
      _logSosTerminalArbitration(
        incomingSource: 'fetch_sos_state',
        incomingRaw: repositoryState,
        decision: 'apply_terminal',
        reason: 'current_cycle_terminal_acknowledged',
      );
      _publicSosState = SosState.idle;
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> repositoryState=${repositoryState.name} '
        'effectiveState=idle reason=terminal_summary_acknowledged',
      );
      return _publicSosState;
    }
    if (_isTerminalPublicSosState(repositoryState)) {
      _logSosTerminalArbitration(
        incomingSource: 'fetch_sos_state',
        incomingRaw: repositoryState,
        decision: 'apply_terminal',
        reason: _runtimeProtectionActiveForPreSos()
            ? 'current_cycle_terminal'
            : 'runtime_inactive',
      );
    }
    _publicSosState = _preserveDeviceRuntimeSosStateIfNeeded(
      incoming: repositoryState,
      source: 'fetch_sos_state',
    );
    BleDebugRegistry.instance.recordEvent(
      'getSosState() -> repositoryState=${repositoryState.name} '
      'effectiveState=${_publicSosState.name}',
    );
    return _publicSosState;
  }

  @override
  Future<SosHistoryPage> listSosHistory(
      {String? cursor, int limit = 20}) async {
    return sosRepository.listSosHistory(cursor: cursor, limit: limit);
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
    String language = 'en',
  }) {
    return addEmergencyContact(
      name: name,
      phone: phone,
      email: email,
      priority: priority,
      language: language,
    );
  }

  @override
  Future<EmergencyContact> addEmergencyContact({
    required String name,
    required String phone,
    required String email,
    int priority = 1,
    String language = 'en',
  }) {
    return contactsRepository.addEmergencyContact(
      name: name,
      phone: phone,
      email: email,
      priority: priority,
      language: language,
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
  Future<void> reorderEmergencyContacts(List<String> orderedContactIds) {
    return contactsRepository.reorderEmergencyContacts(orderedContactIds);
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
    Future<DeviceStatus> future, {
    required String reason,
    bool emitPublicStatus = true,
  }) async {
    final status = _promoteCachedNodeIdOntoDeviceStatus(
      await future,
      source: reason,
    );
    _lastDeviceStatus = status;
    if (status.nodeId != null) {
      _knownLocalDeviceNodeId = status.nodeId;
    }
    final publicStatus = _publishPublicDeviceStatus(
      rawStatus: status,
      reason: reason,
      emit: emitPublicStatus,
    );
    _scheduleRegisteredDeviceAutoSync(
      trigger: 'cache_device_status',
      status: status,
    );
    return publicStatus;
  }

  DeviceStatus _publishPublicDeviceStatus({
    required DeviceStatus rawStatus,
    required String reason,
    bool emit = true,
  }) {
    final publicStatus = _toPublicDeviceStatus(rawStatus, reason: reason);
    final previous = _lastPublicDeviceStatus;
    _lastPublicDeviceStatus = publicStatus;
    if (publicStatus.nodeId != null) {
      _knownLocalDeviceNodeId = publicStatus.nodeId;
      final hardwareId = _canonicalHardwareIdForStatus(publicStatus);
      if (hardwareId != null) {
        _sosRuntimeNodeIdByHardwareId[hardwareId] = publicStatus.nodeId!;
      }
    }
    if (emit &&
        !_publicDeviceStatusController.isClosed &&
        (previous == null ||
            _hasEffectivePublicDeviceStatusChange(previous, publicStatus))) {
      _publicDeviceStatusController.add(publicStatus);
    }
    return publicStatus;
  }

  DeviceStatus _toPublicDeviceStatus(
    DeviceStatus rawStatus, {
    required String reason,
  }) {
    final protectionStatus = _protectionModeController.currentStatus;
    final protectionLive =
        _protectionReportsLiveBleConnection(protectionStatus);
    final belongsToKnownDevice = _protectionConnectionBelongsToKnownDevice(
      baseStatus: rawStatus,
      protectionStatus: protectionStatus,
    );
    final shouldBridge =
        !rawStatus.connected && protectionLive && belongsToKnownDevice;
    final publicStatus = shouldBridge
        ? rawStatus.copyWith(
            connected: true,
            lifecycleState: rawStatus.activated
                ? DeviceLifecycleState.ready
                : rawStatus.lifecycleState,
            lastSeen: rawStatus.lastSeen ?? DateTime.now(),
          )
        : rawStatus;

    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_FLOW] sdk_public_device_status '
      'reason=$reason '
      'rawConnected=${rawStatus.connected} '
      'protectionDeviceConnected=${protectionStatus.deviceConnected} '
      'serviceBleConnected=${protectionStatus.serviceBleConnected} '
      'serviceBleReady=${protectionStatus.serviceBleReady} '
      'bleOwner=${protectionStatus.bleOwner.name} '
      'baseDeviceId=${rawStatus.deviceId} '
      'nodeId=${rawStatus.nodeId?.toString() ?? "-"} '
      'canonicalHardwareId=${rawStatus.canonicalHardwareId ?? "-"} '
      'activeDeviceId=${protectionStatus.activeDeviceId ?? "-"} '
      'protectedDeviceId=${protectionStatus.protectedDeviceId ?? "-"} '
      'finalConnected=${publicStatus.connected} '
      'finalPublicConnected=${publicStatus.connected}',
    );
    if (shouldBridge) {
      BleDebugRegistry.instance.recordEvent(
        '[DEVICE_FLOW] protection_connection_bridge '
        'flutterConnected=${rawStatus.connected} '
        'protectionDeviceConnected=${protectionStatus.deviceConnected} '
        'serviceBleConnected=${protectionStatus.serviceBleConnected} '
        'serviceBleReady=${protectionStatus.serviceBleReady} '
        'bleOwner=${protectionStatus.bleOwner.name} '
        'finalPublicConnected=${publicStatus.connected} '
        'deviceId=${rawStatus.nodeId?.toString() ?? "-"} nodeId=${rawStatus.nodeId?.toString() ?? "-"} hardwareId=${rawStatus.deviceId}',
      );
    }
    return publicStatus;
  }

  bool _protectionReportsLiveBleConnection(ProtectionStatus status) {
    return status.deviceConnected ||
        status.serviceBleConnected ||
        status.serviceBleReady;
  }

  bool _protectionConnectionBelongsToKnownDevice({
    required DeviceStatus baseStatus,
    required ProtectionStatus protectionStatus,
  }) {
    if (!baseStatus.paired) {
      return false;
    }

    final knownIds = <String>{
      baseStatus.deviceId.trim(),
      if ((baseStatus.canonicalHardwareId ?? '').trim().isNotEmpty)
        baseStatus.canonicalHardwareId!.trim(),
    }..removeWhere((id) => id.isEmpty);
    final protectionIds = <String>{
      if ((protectionStatus.activeDeviceId ?? '').trim().isNotEmpty)
        protectionStatus.activeDeviceId!.trim(),
      if ((protectionStatus.protectedDeviceId ?? '').trim().isNotEmpty)
        protectionStatus.protectedDeviceId!.trim(),
    };
    final hasMatchingProtectionId =
        protectionIds.any((id) => knownIds.contains(id));

    if (!protectionStatus.devicePaired) {
      return hasMatchingProtectionId;
    }

    if (protectionIds.isEmpty) {
      return true;
    }
    return hasMatchingProtectionId;
  }

  bool _hasEffectivePublicDeviceStatusChange(
    DeviceStatus previous,
    DeviceStatus next,
  ) {
    return previous.deviceId != next.deviceId ||
        previous.nodeId != next.nodeId ||
        previous.canonicalHardwareId != next.canonicalHardwareId ||
        previous.deviceAlias != next.deviceAlias ||
        previous.model != next.model ||
        previous.paired != next.paired ||
        previous.activated != next.activated ||
        previous.connected != next.connected ||
        previous.batteryLevel != next.batteryLevel ||
        previous.effectiveBatteryState != next.effectiveBatteryState ||
        previous.batterySource != next.batterySource ||
        previous.firmwareVersion != next.firmwareVersion ||
        previous.signalQuality != next.signalQuality ||
        previous.lifecycleState != next.lifecycleState ||
        previous.provisioningError != next.provisioningError;
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

    if (!deviceSosController.shortCommandAvailable &&
        !deviceSosController.longCommandAvailable) {
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
    final protectionStatus = _protectionModeController.currentStatus;
    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_FLOW] ble_owner_transition '
      'flutterConnected=${_lastDeviceStatus?.connected ?? false} '
      'protectionDeviceConnected=${protectionStatus.deviceConnected} '
      'serviceBleConnected=${protectionStatus.serviceBleConnected} '
      'serviceBleReady=${protectionStatus.serviceBleReady} '
      'bleOwner=${owner.name} '
      'finalPublicConnected=${_lastPublicDeviceStatus?.connected ?? _lastDeviceStatus?.connected ?? false} '
      'deviceId=${_lastDeviceStatus?.nodeId?.toString() ?? "-"} nodeId=${_lastDeviceStatus?.nodeId?.toString() ?? "-"} hardwareId=${_lastDeviceStatus?.deviceId ?? "-"}',
    );
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
    if (_handleProtectionPlatformBackendSyncEvent(event)) {
      return;
    }
    final payloadReason = _protectionSosPayloadReasonFromPlatformEvent(event);
    _logSosTrace(
      'dart_platform_event_raw type=${event.type.name} '
      'payloadKeys=${payloadReason.debugPayloadKeys}',
    );
    final isRemoteSosEvent =
        event.type == ProtectionPlatformEventType.sosEventReceived;
    final isOwnDeviceSosLifecycleEvent =
        event.type == ProtectionPlatformEventType.ownDeviceSosLifecycleObserved;
    final isNativeApprovedOwnLifecycle =
        isOwnDeviceSosLifecycleEvent && payloadReason.identityOwn;
    if (!isRemoteSosEvent && !isOwnDeviceSosLifecycleEvent) {
      _logSosTrace(
        'dart_platform_event_route route=ignored reason=not_sos_event_type',
      );
      _logSosTrace(
        'dart_platform_event_ignored reason=not_sos_event_type',
      );
      return;
    }
    final rawHex = payloadReason.payloadHex;
    if (rawHex == null || rawHex.isEmpty) {
      _logSosTrace(
        'dart_platform_event_parse_result originatorNodeId=none '
        'relayNodeId=none classification=missingPayload hasLocation=false',
      );
      _logSosTrace(
        'dart_platform_event_route route=ignored reason=missing_hex_payload',
      );
      _logSosTrace(
        'dart_platform_event_ignored reason=missing_hex_payload',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload ignored -> reason=missing_hex_payload',
      );
      return;
    }
    final bytes = _tryDecodeHexPayload(rawHex);
    if (bytes == null || bytes.isEmpty) {
      _logSosTrace(
        'dart_platform_event_parse_result originatorNodeId=none '
        'relayNodeId=${payloadReason.relayNodeId ?? "none"} '
        'classification=invalidPayload hasLocation=false',
      );
      _logSosTrace(
        'dart_platform_event_route route=ignored reason=invalid_hex_payload',
      );
      _logSosTrace(
        'dart_platform_event_ignored reason=invalid_hex_payload',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload ignored -> reason=invalid_hex_payload payload=$rawHex',
      );
      return;
    }

    final remoteClassification = _classifyProtectionPlatformRemoteSos(
      bytes: bytes,
      rawHex: rawHex,
      source: payloadReason.source,
      relayNodeId: payloadReason.relayNodeId,
      forceUnknownIdentity: payloadReason.identityUnknown,
    );
    final isUnknownOriginSos =
        remoteClassification.kind == BleIncomingPayloadKind.unknownOriginSos;
    final platformConnectedBleNodeId = payloadReason.identityUnknown
        ? null
        : payloadReason.relayNodeId ?? _knownLocalDeviceNodeId;
    final hasTrustedPlatformConnectedNode =
        platformConnectedBleNodeId != null && !payloadReason.identityUnknown;
    final unknownRemoteRelaySnapshot =
        !payloadReason.identityOwn && isUnknownOriginSos
            ? _unknownOriginRemoteSosSnapshotFromPlatform(
                bytes: bytes,
                rawHex: rawHex,
                source: payloadReason.source,
              )
            : null;
    final classifiedRemoteRelaySnapshot =
        payloadReason.identityOwn && !hasTrustedPlatformConnectedNode
            ? null
            : remoteClassification.remoteRelaySosSnapshot;
    final remoteRelaySnapshot =
        classifiedRemoteRelaySnapshot ?? unknownRemoteRelaySnapshot;
    final originatorNodeId = remoteRelaySnapshot?.originatorNodeId ??
        remoteClassification.sosPacket?.nodeId ??
        remoteClassification.sosEventPacket?.nodeId ??
        EixamSosPacket.tryParse(bytes)?.nodeId ??
        EixamSosEventPacket.tryParse(bytes)?.nodeId;
    final platformSosEventPacket = EixamSosEventPacket.tryParse(bytes);
    if (isNativeApprovedOwnLifecycle &&
        platformSosEventPacket?.opcode !=
            EixamBleProtocol.sosEventAppCancelAckOpcode &&
        _shouldSuppressRecentTerminalOwnSosPacket(
          originatorNodeId: originatorNodeId,
          rawHex: rawHex,
        )) {
      return;
    }
    final effectiveClassificationKind = isNativeApprovedOwnLifecycle
        ? BleIncomingPayloadKind.ownDeviceSos
        : remoteClassification.kind;
    final isLocalPlatformSosClassification = isNativeApprovedOwnLifecycle ||
        hasTrustedPlatformConnectedNode &&
            (remoteClassification.kind == BleIncomingPayloadKind.ownDeviceSos ||
                remoteClassification.kind == BleIncomingPayloadKind.sosClear ||
                remoteClassification.kind == BleIncomingPayloadKind.sosCancel);
    _logProtectionSosIdentityDecision(
      originatorNodeId: originatorNodeId,
      connectedBleNodeId: platformConnectedBleNodeId,
      relayNodeId: payloadReason.relayNodeId,
      sourceChannel:
          (payloadReason.source ?? RemoteRelaySosSource.sosNotify).name,
      platformEventType: event.type.name,
      decision: remoteRelaySnapshot != null
          ? unknownRemoteRelaySnapshot != null
              ? 'unknown_hold'
              : 'remote_relay'
          : isLocalPlatformSosClassification
              ? 'own_device'
              : 'unknown_hold',
      reason: remoteRelaySnapshot != null
          ? unknownRemoteRelaySnapshot != null
              ? 'connected_ble_node_unknown'
              : 'originator_differs_from_connected_ble_node'
          : isLocalPlatformSosClassification
              ? 'originator_matches_connected_ble_node'
              : 'connected_ble_node_unknown',
    );
    _logSosTrace(
      'dart_platform_event_parse_result '
      'originatorNodeId=${originatorNodeId?.toString() ?? "none"} '
      'relayNodeId=${remoteRelaySnapshot?.relayNodeId ?? payloadReason.relayNodeId ?? "none"} '
      'classification=${effectiveClassificationKind.name} '
      'hasLocation=${remoteRelaySnapshot?.location != null}',
    );
    if (remoteRelaySnapshot != null) {
      final route = unknownRemoteRelaySnapshot != null
          ? 'unknown_remote_candidate'
          : 'remote_relay';
      _logSosTrace(
        'dart_platform_event_route route=$route reason=remote_sos_candidate',
      );
      _logSosTrace(
        'dart_platform_event type=${event.type.name} '
        'originatorNodeId=${remoteRelaySnapshot.originatorNodeId} '
        'relayNodeId=${remoteRelaySnapshot.relayNodeId ?? "none"} '
        'hasLocation=${remoteRelaySnapshot.location != null} '
        'lat=${remoteRelaySnapshot.location?.latitude ?? "none"} '
        'lon=${remoteRelaySnapshot.location?.longitude ?? "none"} '
        'alt=${remoteRelaySnapshot.location?.altitude ?? "none"} '
        'payloadHex=${remoteRelaySnapshot.payloadHex ?? rawHex}',
      );
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] protection_platform_observed '
        'originatorNodeId=${remoteRelaySnapshot.originatorNodeId} '
        'relayNodeId=${remoteRelaySnapshot.relayNodeId ?? "-"} '
        'kind=${remoteRelaySnapshot.kind.name}',
      );
      _logSosTrace(
        'dart_sdk_remote_relay_received '
        'originatorNodeId=${remoteRelaySnapshot.originatorNodeId} '
        'relayNodeId=${remoteRelaySnapshot.relayNodeId ?? "none"} '
        'classification=${effectiveClassificationKind.name} '
        'hasLocation=${remoteRelaySnapshot.location != null}',
      );
      _publishSdkEvent(RemoteRelaySosObservedEvent(remoteRelaySnapshot));
      unawaited(
        _handleRemoteRelaySosBackendHandoff(remoteRelaySnapshot),
      );
      return;
    }
    if (payloadReason.identityOwn && !isOwnDeviceSosLifecycleEvent) {
      _logSosTrace(
        'dart_platform_event_route route=ignored reason=native_own_device_sos',
      );
      _logSosTrace(
        'dart_platform_event_ignored reason=native_own_device_sos',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload ignored -> reason=native_own_device_sos',
      );
      return;
    }
    if (remoteClassification.kind == BleIncomingPayloadKind.unknownOriginSos &&
        !isNativeApprovedOwnLifecycle) {
      _logSosTrace(
        'dart_platform_event_route route=ignored reason=unknown_origin_without_sos_packet',
      );
      _logSosTrace(
        'dart_platform_event_ignored reason=unknown_origin_without_sos_packet',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload held -> reason=unknown_connected_node_identity payload=$rawHex',
      );
      return;
    }
    if (!hasTrustedPlatformConnectedNode &&
        !isNativeApprovedOwnLifecycle &&
        originatorNodeId != null) {
      _logSosTrace(
        'dart_platform_event_route route=ignored reason=unknown_connected_node_identity',
      );
      _logSosTrace(
        'dart_platform_event_ignored reason=unknown_connected_node_identity',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload held -> reason=unknown_connected_node_identity payload=$rawHex',
      );
      return;
    }

    final sosEventPacket = platformSosEventPacket;
    if (sosEventPacket != null) {
      _logSosTrace(
        'dart_platform_event_route route=local_sos reason=sos_event_packet',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload forwarded -> type=sosDeviceEvent payload=${sosEventPacket.rawHex}',
      );
      deviceSosController.handleIncomingSosEventPacket(
        sosEventPacket,
        source: DeviceSosTransitionSource.device,
      );
      if (_isTerminalSosEventPacket(sosEventPacket)) {
        _applyTerminalSosSuppression(
          reason: 'own_device_terminal_packet',
          nodeId: sosEventPacket.nodeId,
        );
      }
      return;
    }

    final sosPacket = EixamSosPacket.tryParse(bytes);
    if (sosPacket != null) {
      _logSosTrace(
        'dart_platform_event_route route=local_sos reason=sos_mesh_packet',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload forwarded -> type=sosMeshPacket payload=${sosPacket.rawHex}',
      );
      deviceSosController.handleIncomingSosPacket(
        sosPacket,
        source: DeviceSosTransitionSource.device,
      );
      return;
    }

    _logSosTrace(
      'dart_platform_event_route route=ignored reason=unrecognized_payload',
    );
    _logSosTrace(
      'dart_platform_event_ignored reason=unrecognized_payload',
    );
    BleDebugRegistry.instance.recordEvent(
      'Protection SOS payload ignored -> reason=unrecognized_payload payload=$rawHex len=${bytes.length}',
    );
  }

  bool _handleProtectionPlatformBackendSyncEvent(
    ProtectionPlatformEvent event,
  ) {
    switch (event.type) {
      case ProtectionPlatformEventType.nativeBackendSyncQueued:
        BleDebugRegistry.instance.recordEvent(
          '[NATIVE_PRE_SOS_BACKEND] action=queued '
          'reason=${event.reason ?? "-"}',
        );
        _clearPreSosSession(
          reason: 'native_backend_sync_queued',
          emitIdleState: false,
        );
        _emitPublicSosState(
          SosState.sending,
          source: 'native_backend_sync_queued',
        );
        return true;
      case ProtectionPlatformEventType.nativeBackendSyncSucceeded:
        BleDebugRegistry.instance.recordEvent(
          '[NATIVE_PRE_SOS_BACKEND] action=succeeded '
          'reason=${event.reason ?? "-"}',
        );
        _clearPreSosSession(
          reason: 'native_backend_sync_succeeded',
          emitIdleState: false,
        );
        unawaited(_syncNativePreSosBackendPending(
          trigger: 'native_backend_sync_succeeded',
        ));
        return true;
      case ProtectionPlatformEventType.nativeBackendSyncFailed:
        BleDebugRegistry.instance.recordEvent(
          '[NATIVE_PRE_SOS_BACKEND] action=failed '
          'reason=${event.reason ?? "-"}',
        );
        _markCountdownZeroActivationFailed(
          source: 'native_backend_sync_failed',
        );
        return true;
      case ProtectionPlatformEventType.serviceStarted:
      case ProtectionPlatformEventType.serviceStopped:
      case ProtectionPlatformEventType.serviceRestarted:
      case ProtectionPlatformEventType.woke:
      case ProtectionPlatformEventType.runtimeStarting:
      case ProtectionPlatformEventType.runtimeStarted:
      case ProtectionPlatformEventType.runtimeActive:
      case ProtectionPlatformEventType.runtimeStopped:
      case ProtectionPlatformEventType.runtimeRecovered:
      case ProtectionPlatformEventType.runtimeRestarted:
      case ProtectionPlatformEventType.runtimeFailed:
      case ProtectionPlatformEventType.deviceConnecting:
      case ProtectionPlatformEventType.deviceConnected:
      case ProtectionPlatformEventType.deviceDisconnected:
      case ProtectionPlatformEventType.reconnectScheduled:
      case ProtectionPlatformEventType.reconnectFailed:
      case ProtectionPlatformEventType.servicesDiscovered:
      case ProtectionPlatformEventType.subscriptionsActive:
      case ProtectionPlatformEventType.packetReceived:
      case ProtectionPlatformEventType.sosEventReceived:
      case ProtectionPlatformEventType.ownDeviceSosLifecycleObserved:
      case ProtectionPlatformEventType.runtimeError:
      case ProtectionPlatformEventType.restorationDetected:
      case ProtectionPlatformEventType.restorationRehydrated:
      case ProtectionPlatformEventType.bluetoothTurnedOff:
      case ProtectionPlatformEventType.bluetoothTurnedOn:
        return false;
    }
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

  void _applyTerminalSosSuppression({
    required String reason,
    int? nodeId,
  }) {
    if (_manualDisconnectRequested) {
      _clearDeviceRuntimeResidueAfterManualDisconnect();
      return;
    }
    final now = DateTime.now();
    _pruneTerminalSosSuppressions(now);
    final boundDeviceId = _lastDeviceStatus?.deviceId.trim();
    final status = deviceSosController.currentStatus;
    final effectiveNodeId = nodeId ?? status.nodeId ?? _knownLocalDeviceNodeId;
    final keys = _terminalSosSuppressionKeys(
      originatorNodeId: effectiveNodeId,
      boundDeviceId: boundDeviceId,
    );
    if (keys.isEmpty) {
      _applyDeviceTerminalPublicSosClose(
        reason: reason,
        nodeId: effectiveNodeId,
      );
      return;
    }
    final suppression = _TerminalSosSuppression(
      originatorNodeId: effectiveNodeId,
      boundDeviceId: boundDeviceId?.isEmpty == true ? null : boundDeviceId,
      expiresAt: now.add(_terminalSosSuppressionWindow),
      reason: reason,
    );
    for (final key in keys) {
      _terminalSosSuppressionByKey[key] = suppression;
    }
    _logSosTrace(
      'terminal_suppression_applied '
      'reason=$reason '
      'originatorNodeId=${effectiveNodeId?.toString() ?? "none"} '
      'boundDeviceId=${boundDeviceId?.isNotEmpty == true ? boundDeviceId : "none"}',
    );
    _applyDeviceTerminalPublicSosClose(
      reason: reason,
      nodeId: effectiveNodeId,
    );
  }

  void _applyDeviceTerminalPublicSosClose({
    required String reason,
    required int? nodeId,
  }) {
    if (!_isTerminalSuppressionCloseReason(reason)) {
      return;
    }
    final terminalState = _terminalStateForSuppressionReason(reason);
    final currentRuntimeIncidentId = _currentDeviceRuntimeUiIncidentId();
    final activeIncident = _lastKnownActiveSosIncident;
    final fallbackIncident = _publicSosFallbackIncident;
    final incidentId = currentRuntimeIncidentId ??
        fallbackIncident?.id ??
        activeIncident?.id ??
        _lastPublicSosIncidentId ??
        (nodeId == null ? null : 'device-runtime-sos:$nodeId:1');
    if (incidentId == null || incidentId.trim().isEmpty) {
      return;
    }
    final shouldClose = _isOpenSosState(_publicSosState) ||
        _hasActiveDeviceRuntimeSosOwnership() ||
        _hasBackendVisibleSosIncident(fallbackIncident) ||
        _hasBackendVisibleSosIncident(activeIncident);
    if (!shouldClose &&
        _publicSosState == SosState.idle &&
        _acknowledgedTerminalSosWithoutIncident) {
      BleDebugRegistry.instance.recordEvent(
        '[APP_SOS_TERMINAL_EVENT] source=device_terminal_event '
        'decision=ignore_acknowledged_terminal_after_idle '
        'incoming=$terminalState reason=$reason',
      );
      return;
    }
    if (reason.toLowerCase().contains('device_terminal_event') &&
        _isTerminalPublicSosState(_publicSosState) &&
        _publicSosState != terminalState) {
      BleDebugRegistry.instance.recordEvent(
        '[APP_SOS_TERMINAL_EVENT] source=device_terminal_event '
        'decision=keep_existing_terminal existing=${_publicSosState.name} '
        'incoming=${terminalState.name} reason=$reason',
      );
      return;
    }
    if (!shouldClose && _isTerminalPublicSosState(_publicSosState)) {
      return;
    }
    _rememberClosedDeviceRuntimeIncidentIds(
      ids: <String?>[
        incidentId,
        currentRuntimeIncidentId,
        _activeDeviceRuntimeIncidentId,
        _activeDeviceRuntimeCycleKey == null
            ? null
            : 'device-runtime-${_activeDeviceRuntimeCycleKey!.replaceFirst('sos-cycle:', '')}',
        _activeDeviceSosCycleKey == null
            ? null
            : 'device-runtime-${_activeDeviceSosCycleKey!}',
        _deviceOwnedBackendIncidentId,
      ],
    );
    final referenceIncident = fallbackIncident ?? activeIncident;
    final terminalIncident = SosIncident(
      id: incidentId,
      state: terminalState,
      createdAt: referenceIncident?.createdAt ?? DateTime.now().toUtc(),
      positionSnapshot: referenceIncident?.positionSnapshot,
      triggerSource:
          referenceIncident?.triggerSource ?? 'ble_device_runtime_status',
      message: referenceIncident?.message,
      deliveryChannel:
          referenceIncident?.deliveryChannel ?? SosDeliveryChannel.deviceOnly,
    );
    _publicSosFallbackIncident = terminalIncident;
    _lastKnownActiveSosIncident = null;
    _lastPublicSosIncidentId = terminalIncident.id;
    _lastPublicSosDeliveryChannel =
        terminalIncident.deliveryChannel ?? SosDeliveryChannel.deviceOnly;
    _clearDeviceRuntimeSosOwnership(reason: 'device_terminal_event');
    BleDebugRegistry.instance.recordEvent(
      '[APP_SOS_TERMINAL_EVENT] source=device_terminal_event '
      'decision=accept_terminal incidentId=${terminalIncident.id} '
      'canonicalIncidentId=${terminalIncident.id} reason=$reason',
    );
    _emitPublicSosState(terminalState, source: 'device_terminal_event');
    _emitOperationalDiagnostics();
  }

  bool _isTerminalSuppressionCloseReason(String reason) {
    final normalized = reason.toLowerCase();
    return normalized.contains('device_terminal_event') ||
        normalized.contains('own_device_terminal_packet') ||
        normalized.contains('backend_terminal_state') ||
        normalized.contains('public_cancel_completed') ||
        normalized.contains('public_resolve_completed') ||
        normalized.contains('device_close_command_without_ack');
  }

  SosState _terminalStateForSuppressionReason(String reason) {
    final normalized = reason.toLowerCase();
    return normalized.contains('resolved') || normalized.contains('resolve')
        ? SosState.resolved
        : SosState.cancelled;
  }

  bool _shouldSuppressRecentTerminalOwnSosPacket({
    required int? originatorNodeId,
    required String rawHex,
  }) {
    if (_manualDisconnectRequested) {
      _clearDeviceRuntimeResidueAfterManualDisconnect();
      return true;
    }
    final now = DateTime.now();
    _pruneTerminalSosSuppressions(now);
    final boundDeviceId = _lastDeviceStatus?.deviceId.trim();
    final keys = _terminalSosSuppressionKeys(
      originatorNodeId: originatorNodeId,
      boundDeviceId: boundDeviceId,
    );
    for (final key in keys) {
      final suppression = _terminalSosSuppressionByKey[key];
      if (suppression == null || now.isAfter(suppression.expiresAt)) {
        continue;
      }
      _logSosTrace(
        'terminal_suppression_applied '
        'reason=recent_terminal_action '
        'originatorNodeId=${originatorNodeId?.toString() ?? "none"} '
        'boundDeviceId=${boundDeviceId?.isNotEmpty == true ? boundDeviceId : "none"} '
        'suppressionReason=${suppression.reason}',
      );
      _logSosTrace(
        'dart_platform_event_route route=ignored reason=recent_terminal_action',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload suppressed -> reason=recent_terminal_action '
        'originatorNodeId=${originatorNodeId?.toString() ?? "-"} '
        'boundDeviceId=${boundDeviceId?.isNotEmpty == true ? boundDeviceId : "-"} '
        'payload=$rawHex',
      );
      return true;
    }
    return false;
  }

  Iterable<String> _terminalSosSuppressionKeys({
    required int? originatorNodeId,
    required String? boundDeviceId,
  }) sync* {
    if (originatorNodeId != null) {
      yield 'node:$originatorNodeId';
      return;
    }
    final deviceId = boundDeviceId?.trim();
    if (deviceId != null && deviceId.isNotEmpty) {
      yield 'device:$deviceId';
    }
  }

  void _clearDeviceRuntimeResidueAfterManualDisconnect() {
    _terminalSosSuppressionByKey.clear();
    _sosRuntimeNodeIdByHardwareId.clear();
    _knownLocalDeviceNodeId = null;
    _activeDeviceSosCycleKey = null;
    _notifiedDeviceSosCycleKey = null;
    _notifiedDeviceSosState = null;
    _activeDeviceRuntimeIncidentId = null;
    _activeDeviceRuntimeCycleKey = null;
    _activeDeviceRuntimeLocalCycleKey = null;
    _deviceOwnedBackendIncidentId = null;
    _lastDeviceRuntimeCanonicalIncidentSignature = null;
    _lastDeviceRuntimeCanonicalIncident = null;
  }

  void _pruneTerminalSosSuppressions(DateTime now) {
    _terminalSosSuppressionByKey.removeWhere(
      (_, suppression) => now.isAfter(suppression.expiresAt),
    );
  }

  bool _isTerminalSosEventPacket(EixamSosEventPacket packet) {
    if (packet.opcode == EixamBleProtocol.sosEventUserDeactivatedOpcode) {
      return packet.subcode == 0x01 || packet.subcode == 0x02;
    }
    if (packet.opcode == EixamBleProtocol.sosEventAppCancelAckOpcode) {
      return packet.subcode == 0x01 ||
          packet.subcode == 0x02 ||
          packet.subcode == 0x03;
    }
    return false;
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
    final guardMatch = _resolveConnectedDeviceNodeGuardMatch();
    final connectedDeviceNodeId = guardMatch.nodeId;
    final hardwareId = _canonicalHardwareIdForStatus(_lastPublicDeviceStatus) ??
        _canonicalHardwareIdForStatus(_lastDeviceStatus);
    final identitySource = connectedDeviceNodeId != null
        ? 'ble_node'
        : hardwareId != null
            ? 'device_hardware_pending'
            : 'none';
    if (connectedDeviceNodeId == null) {
      BleDebugRegistry.instance.recordEvent(
        '[APP_REMOTE_RELAY_LOCAL_GUARD_NODE_RESOLVE_FAILED] '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'availableIncidentIds=${_availableLocalGuardIncidentIds().join(",")} '
        'availableDeviceIds=${_availableLocalGuardDeviceIds().join(",")}',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_GUARD_NODE_RESOLVED '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'connectedDeviceNodeId=${connectedDeviceNodeId?.toString() ?? "none"} '
      'guardMatchedBy=${guardMatch.matchedBy} '
      'identitySource=$identitySource '
      'hardwareId=${hardwareId ?? "none"}',
    );
    if (connectedDeviceNodeId == snapshot.originatorNodeId) {
      BleDebugRegistry.instance.recordEvent(
        '[APP_REMOTE_RELAY_LOCAL_GUARD_BLOCKED] '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
        'connectedDeviceNodeId=$connectedDeviceNodeId '
        'guardMatchedBy=${guardMatch.matchedBy} '
        'hasLocation=${snapshot.location != null} '
        'action=map_sos_state',
      );
      if (_hasOpenDeviceRuntimeSosInvariant()) {
        _emitPublicSosState(
          _deviceRuntimeInvariantFallbackState(),
          source: 'remote_relay_self_guard',
        );
      }
      return;
    }

    final signature = _remoteRelaySosBackendHandoffSignature(snapshot);
    final now = DateTime.now().toUtc();
    _remoteRelaySosBackendHandoffBySignature.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(minutes: 5),
    );
    if (_remoteRelaySosBackendHandoffBySignature.containsKey(signature)) {
      _logSosTrace(
        'remote_backend_handoff_decision '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId ?? "none"} '
        'hasLocation=${snapshot.location != null} '
        'locationSource=none willAttemptBackend=false skipReason=duplicate',
      );
      return;
    }
    _remoteRelaySosBackendHandoffBySignature[signature] = now;

    final deviceId = _remoteRelayOriginatorDeviceId(snapshot);
    final relayNodeId = snapshot.relayNodeId ?? _lastDeviceStatus?.nodeId;
    final relayDeviceId = relayNodeId?.toString();
    final relayHardwareId = _lastDeviceStatus?.canonicalHardwareId;
    final location = snapshot.location;
    final positionSnapshot = _hasValidRemoteRelayLocation(location)
        ? _remoteRelayBackendPosition(
            location: location!,
            receivedAt: snapshot.receivedAt,
          )
        : null;
    final locationSource = positionSnapshot != null
        ? (snapshot.rawPayload.length ==
                EixamBleProtocol.sosPacketLengthWithPosition
            ? 'packet_12b'
            : 'last_known')
        : 'none';
    _logSosTrace(
      'remote_backend_handoff_decision '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId ?? "none"} '
      'hasLocation=${positionSnapshot != null} '
      'locationSource=$locationSource willAttemptBackend=true skipReason=none',
    );
    _logSosTrace(
      'remote_handoff_decision '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId ?? "none"} '
      'hasLocation=${positionSnapshot != null} '
      'locationSource=$locationSource willAttemptBackend=true skipReason=none',
    );
    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS] backend_handoff_start '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'deviceId=$deviceId '
      'hasLocation=${positionSnapshot != null}',
    );

    try {
      await _showRemoteRelaySosNotification(snapshot);
      _logSosTrace(
        'backend_submit_path path=${_remoteRelaySosBackendSubmitPath()}',
      );
      _logSosTrace(
        'backend_submit_payload '
        'deviceId=$deviceId '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId ?? "none"} '
        'relayDeviceId=${relayDeviceId ?? "none"} '
        'relayHardwareId=${relayHardwareId ?? "none"} '
        'triggerSource=remote_lora_relay '
        'packetSource=${snapshot.source.name} '
        'hasLocation=${positionSnapshot != null}',
      );
      _logSosTrace(
        'backend_create_attempt '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId ?? "none"} '
        'hasLocation=${positionSnapshot != null}',
      );
      final backendResult = await _submitRemoteRelaySosToBackend(
        snapshot: snapshot,
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
        relayDeviceId: relayDeviceId,
        relayHardwareId: relayHardwareId,
      );
      _logSosTrace(
        'backend_result originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId ?? "none"} '
        'submittedToBackend=true '
        'path=${backendResult.submitPath} '
        'hasLocation=${positionSnapshot != null} '
        'statusCode=${backendResult.statusCode ?? "none"} '
        'incidentId=${backendResult.incidentId ?? "none"} '
        'success=true error=none skipReason=none',
      );
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] backend_handoff_success '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'deviceId=$deviceId',
      );

      var ackRelaySent = false;
      String? ackRelayErrorMessage;
      if (!deviceSosController.longCommandAvailable) {
        _logSosTrace(
          'ack_relay_pending_no_long_command_path '
          'originatorNodeId=${snapshot.originatorNodeId} '
          'relayNodeId=${snapshot.relayNodeId ?? "none"}',
        );
      } else {
        try {
          final ackBytes = EixamDeviceCommand.sosAckRelay(
            nodeId: snapshot.originatorNodeId,
          ).bytes;
          _logSosTrace(
            'ack_relay_write_attempt '
            'originatorNodeId=${snapshot.originatorNodeId} '
            'relayNodeId=${snapshot.relayNodeId ?? "none"} '
            'bytesHex=${EixamBleProtocol.hex(ackBytes)}',
          );
          await deviceSosController.sendAckRelay(
            nodeId: snapshot.originatorNodeId,
          );
          ackRelaySent = true;
          _logSosTrace(
            'ack_relay_write_result '
            'originatorNodeId=${snapshot.originatorNodeId} '
            'relayNodeId=${snapshot.relayNodeId ?? "none"} '
            'bytesHex=${EixamBleProtocol.hex(ackBytes)} success=true error=none',
          );
          BleDebugRegistry.instance.recordEvent(
            '[REMOTE_RELAY_SOS] ack_relay_sent '
            'originatorNodeId=${snapshot.originatorNodeId}',
          );
        } catch (error) {
          ackRelayErrorMessage = error.toString();
          _logSosTrace(
            'ack_relay_write_result '
            'originatorNodeId=${snapshot.originatorNodeId} '
            'relayNodeId=${snapshot.relayNodeId ?? "none"} '
            'bytesHex=${EixamBleProtocol.hex(EixamDeviceCommand.sosAckRelay(nodeId: snapshot.originatorNodeId).bytes)} '
            'success=false error=$error',
          );
          BleDebugRegistry.instance.recordEvent(
            '[REMOTE_RELAY_SOS] ack_relay_failed '
            'originatorNodeId=${snapshot.originatorNodeId} '
            'error=$error',
          );
        }
      }

      _publishSdkEvent(
        RemoteRelaySosBackendHandoffResultEvent(
          snapshot: snapshot,
          status: RemoteRelaySosBackendHandoffStatus.submitted,
          deviceId: deviceId,
          statusCode: backendResult.statusCode,
          incidentId: backendResult.incidentId,
          ackRelaySent: ackRelaySent,
          ackRelayErrorMessage: ackRelayErrorMessage,
        ),
      );
      _logRemoteRelaySosStateRehydrate(
        snapshot: snapshot,
        expectedIncidentId: backendResult.incidentId,
        source: 'mqtt',
      );
      _emitExternalSosSentNotificationIntent(
        snapshot: snapshot,
        statusCode: backendResult.statusCode,
        incidentId: backendResult.incidentId,
      );
    } catch (error) {
      _logRemoteRelayBackendResponse(
        correlationId: _remoteRelayCorrelationId(snapshot),
        snapshot: snapshot,
        statusCode: _statusCodeForError(error),
        incidentId: null,
        backendStatus: 'mqtt_publish_failed',
        responseSummary: _compactDiagnosticValue(error),
        error: error,
      );
      _logSosTrace(
        'backend_result originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId ?? "none"} '
        'hasLocation=${positionSnapshot != null} '
        'submittedToBackend=false '
        'statusCode=${_statusCodeForError(error) ?? "none"} '
        'incidentId=none success=false error=$error skipReason=none',
      );
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] backend_handoff_failed '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'error=$error',
      );
      _publishSdkEvent(
        RemoteRelaySosBackendHandoffResultEvent(
          snapshot: snapshot,
          status: RemoteRelaySosBackendHandoffStatus.failed,
          deviceId: deviceId,
          statusCode: _statusCodeForError(error),
          errorMessage: error.toString(),
        ),
      );
    }
  }

  void _emitExternalSosSentNotificationIntent({
    required RemoteRelaySosSnapshot snapshot,
    required int? statusCode,
    required String? incidentId,
  }) {
    final trimmedIncidentId = incidentId?.trim();
    final hasIncidentId =
        trimmedIncidentId != null && trimmedIncidentId.isNotEmpty;
    final dedupeToken = hasIncidentId
        ? trimmedIncidentId
        : snapshot.receivedAt.toUtc().microsecondsSinceEpoch.toString();
    final relayNodeId = snapshot.relayNodeId?.toString() ?? 'none';
    _emitNotificationIntent(
      _buildNotificationIntent(
        type: EixamNotificationIntentType.externalSosSent,
        dedupeKey: 'external_sos_sent:'
            '${snapshot.originatorNodeId}:$relayNodeId:$dedupeToken',
        severity: EixamNotificationIntentSeverity.critical,
        incidentId: trimmedIncidentId,
        deviceId: snapshot.relayNodeId?.toString(),
        nodeId: snapshot.originatorNodeId,
        originatorNodeId: snapshot.originatorNodeId,
        relayNodeId: snapshot.relayNodeId,
        titleKey: 'notification.external_sos.sent.title',
        bodyKey: 'notification.external_sos.sent.body',
        fallbackTitle: 'External SOS sent',
        fallbackBody: 'A relay SOS was submitted.',
        payload: <String, String>{
          'originatorNodeId': snapshot.originatorNodeId.toString(),
          if (snapshot.relayNodeId != null)
            'relayNodeId': snapshot.relayNodeId!.toString(),
          if (hasIncidentId) 'incidentId': trimmedIncidentId,
          if (statusCode != null) 'statusCode': statusCode.toString(),
          'receivedAt': snapshot.receivedAt.toUtc().toIso8601String(),
        },
      ),
    );
  }

  Future<void> _showRemoteRelaySosNotification(
    RemoteRelaySosSnapshot snapshot,
  ) async {
    if (!_sdkSosNotificationsEnabled) {
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] notification_skipped '
        'originatorNodeId=${snapshot.originatorNodeId} reason=host_app_managed',
      );
      BleDebugRegistry.instance.recordEvent(
        '[NOTIFICATION_FLOW] sdk_local_notification_skip '
        'type=${EixamNotificationIntentType.externalSosSent.name} '
        'reason=hostAppManaged',
      );
      return;
    }

    PermissionState? permissionState;
    Object? permissionError;
    try {
      permissionState = await permissionsRepository.getPermissionState();
    } catch (error) {
      permissionError = error;
    }
    final permissionLabel = permissionState?.notifications.name ?? 'unknown';
    final appLifecycle =
        WidgetsBinding.instance.lifecycleState?.name ?? 'unknown';
    final hasLocation = snapshot.location != null;
    _logSosTrace(
      'remote_notification_decision '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'hasLocation=$hasLocation permission=$permissionLabel '
      'appLifecycle=$appLifecycle willShow=true skipReason=none',
    );
    if (permissionError != null) {
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] notification_permission_snapshot_failed '
        'originatorNodeId=${snapshot.originatorNodeId} error=$permissionError',
      );
    }

    try {
      BleDebugRegistry.instance.recordEvent(
        '[NOTIFICATION_FLOW] sdk_local_notification_show '
        'type=${EixamNotificationIntentType.externalSosSent.name} '
        'policy=${_notificationPolicyLabel(notificationPolicy)} '
        'channel=eixam_sos_alerts',
      );
      await notificationsRepository.showLocalNotification(
        notificationId: _nextBleNotificationId(),
        title: 'Remote SOS received',
        body: hasLocation
            ? 'Relay SOS from node ${snapshot.originatorNodeId} with location.'
            : 'Relay SOS from node ${snapshot.originatorNodeId}.',
        payload: BleSosNotificationPayload(
          kind: 'sos_received',
          state: DeviceSosState.active,
          transitionSource: DeviceSosTransitionSource.device,
          deviceId: snapshot.relayNodeId?.toString(),
          nodeId: snapshot.originatorNodeId,
        ).toJsonString(),
        actions: const <LocalNotificationAction>[],
      );
      _logSosTrace(
        'remote_notification_result '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'hasLocation=$hasLocation permission=$permissionLabel '
        'appLifecycle=$appLifecycle shown=true error=none',
      );
    } catch (error) {
      _logSosTrace(
        'remote_notification_result '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'hasLocation=$hasLocation permission=$permissionLabel '
        'appLifecycle=$appLifecycle shown=false error=$error',
      );
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] notification_failed '
        'originatorNodeId=${snapshot.originatorNodeId} error=$error',
      );
      debugPrint('Remote relay SOS notification failed: $error');
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

  Future<_RemoteRelayBackendSubmissionResult> _submitRemoteRelaySosToBackend({
    required RemoteRelaySosSnapshot snapshot,
    required TrackingPosition? positionSnapshot,
    required String? deviceId,
    required String? relayDeviceId,
    required String? relayHardwareId,
  }) async {
    final correlationId = _remoteRelayCorrelationId(snapshot);
    final relayNodeId = snapshot.relayNodeId;
    final relaySource = 'remote_lora_relay';
    _logRemoteRelayBackendOutbound(
      correlationId: correlationId,
      snapshot: snapshot,
      endpoint: _remoteRelayBackendEndpointLabel(),
      method: _remoteRelayBackendMethodLabel(),
      submitPath: _remoteRelaySosBackendSubmitPath(),
      deviceId: deviceId,
      relayDeviceId: relayDeviceId,
      relayHardwareId: relayHardwareId,
      positionSnapshot: positionSnapshot,
    );
    final repository = sosRepository;
    if (repository is MqttOperationalSosRepository) {
      // Remote relay SOS creation is MQTT-only. Attached HTTP data sources are
      // retained for other repository operations, not for this handoff.
      if (repository.remoteDataSource != null) {
        _logRemoteRelayHttpSosCreationSkipped(
          correlationId: correlationId,
          snapshot: snapshot,
          deviceId: deviceId,
        );
      }
      await repository.submitSosToBackend(
        timestamp: snapshot.receivedAt.toUtc(),
        positionSnapshot: positionSnapshot,
        deviceId: deviceId,
        originatorNodeId: snapshot.originatorNodeId,
        relayNodeId: relayNodeId,
        relayDeviceId: relayDeviceId,
        relayHardwareId: relayHardwareId,
        relaySource: relaySource,
      );
      _logRemoteRelayBackendResponse(
        correlationId: correlationId,
        snapshot: snapshot,
        statusCode: null,
        incidentId: null,
        backendStatus: 'mqtt_publish_accepted',
        responseSummary: 'backend_confirmation=not_available',
        error: null,
      );
      return const _RemoteRelayBackendSubmissionResult(
        submitPath: 'mqtt_operational_publish',
        statusCode: null,
        incidentId: null,
      );
    }
    if (repository is ApiSosRepository) {
      _logRemoteRelayHttpSosCreationSkipped(
        correlationId: correlationId,
        snapshot: snapshot,
        deviceId: deviceId,
      );
    }

    final operationalClient = _remoteRelayOperationalRealtimeClient();
    if (operationalClient != null) {
      await operationalClient.publishOperationalSos(
        MqttOperationalSosRequest(
          timestamp: snapshot.receivedAt.toUtc(),
          positionSnapshot: positionSnapshot,
          deviceId: deviceId,
          originatorNodeId: snapshot.originatorNodeId,
          relayNodeId: relayNodeId,
          relayDeviceId: relayDeviceId,
          relayHardwareId: relayHardwareId,
          source: relaySource,
        ),
      );
      _logRemoteRelayBackendResponse(
        correlationId: correlationId,
        snapshot: snapshot,
        statusCode: null,
        incidentId: null,
        backendStatus: 'mqtt_publish_accepted',
        responseSummary: 'backend_confirmation=not_available',
        error: null,
      );
      return const _RemoteRelayBackendSubmissionResult(
        submitPath: 'remote_special',
        statusCode: null,
        incidentId: null,
      );
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

  String _remoteRelayCorrelationId(RemoteRelaySosSnapshot snapshot) {
    return 'remote-relay-${snapshot.originatorNodeId}-'
        '${snapshot.receivedAt.toUtc().microsecondsSinceEpoch}';
  }

  void _logRemoteRelayBackendOutbound({
    required String correlationId,
    required RemoteRelaySosSnapshot snapshot,
    required String endpoint,
    required String method,
    required String submitPath,
    required String? deviceId,
    required String? relayDeviceId,
    required String? relayHardwareId,
    required TrackingPosition? positionSnapshot,
  }) {
    final session = _session;
    final appUserIdPresent =
        session?.externalUserId.trim().isNotEmpty == true ||
            session?.canonicalExternalUserId?.trim().isNotEmpty == true;
    final sdkUserIdPresent = session?.sdkUserId?.trim().isNotEmpty == true;
    final identity = normalizeSosBackendIdentity(
      deviceId: deviceId,
      originatorNodeId: snapshot.originatorNodeId,
      relayNodeId: snapshot.relayNodeId,
      relayDeviceId: relayDeviceId,
      incidentId: null,
      cycleKey: null,
      hardwareId: null,
    );
    final transport = switch (submitPath) {
      'mqtt_operational_publish' || 'remote_special' => 'mqtt',
      _ => 'none',
    };
    final topic = transport == 'mqtt' ? endpoint : 'none';
    final payloadSummary =
        'triggerSource=remote_lora_relay source=remote_lora_relay '
        'packetSource=${snapshot.source.name} '
        'deviceId=${identity.deviceId ?? "none"} '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
        'relayDeviceId=${identity.relayDeviceId ?? "none"} '
        'relayHardwareId=${relayHardwareId ?? "none"} '
        'hasLocation=${positionSnapshot != null} '
        'hasLat=${positionSnapshot?.latitude.isFinite == true} '
        'hasLon=${positionSnapshot?.longitude.isFinite == true}';
    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS_BACKEND_OUTBOUND] '
      'transport=$transport '
      'topic=$topic '
      'endpoint=$endpoint '
      'method=$method '
      'correlationId=$correlationId '
      'submitPath=$submitPath '
      'deviceId=${identity.deviceId ?? "none"} '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'triggerSource=remote_lora_relay '
      'incidentId=none '
      'connectedDeviceNodeId=${_resolveConnectedDeviceNodeGuardMatch().nodeId?.toString() ?? "none"} '
      'hasLocation=${positionSnapshot != null} '
      'latPresent=${positionSnapshot?.latitude.isFinite == true} '
      'lonPresent=${positionSnapshot?.longitude.isFinite == true} '
      'payloadSummary=${_compactDiagnosticValue(payloadSummary)} '
      'appUserIdPresent=$appUserIdPresent '
      'sdkUserIdPresent=$sdkUserIdPresent '
      'relayDeviceId=${identity.relayDeviceId ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"} '
      'identitySource=${identity.identitySource}',
    );
  }

  void _logRemoteRelayHttpSosCreationSkipped({
    required String correlationId,
    required RemoteRelaySosSnapshot snapshot,
    required String? deviceId,
  }) {
    final identity = normalizeSosBackendIdentity(
      deviceId: deviceId,
      originatorNodeId: snapshot.originatorNodeId,
      relayNodeId: snapshot.relayNodeId,
      relayDeviceId: snapshot.relayNodeId?.toString(),
      incidentId: null,
      cycleKey: null,
      hardwareId: null,
    );
    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS_BACKEND_OUTBOUND] '
      'transport=http '
      'decision=skipped '
      'reason=sos_must_use_mqtt '
      'endpoint=/v1/sdk/sos '
      'method=POST '
      'correlationId=$correlationId '
      'deviceId=${identity.deviceId ?? "none"} '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'triggerSource=remote_lora_relay '
      'incidentId=none',
    );
  }

  void _logRemoteRelayBackendResponse({
    required String correlationId,
    required RemoteRelaySosSnapshot snapshot,
    required int? statusCode,
    required String? incidentId,
    required String backendStatus,
    required String responseSummary,
    required Object? error,
  }) {
    final deviceId = _remoteRelayOriginatorDeviceId(snapshot);
    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS_BACKEND_RESPONSE] '
      'transport=mqtt '
      'correlationId=$correlationId '
      'deviceId=$deviceId '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'triggerSource=remote_lora_relay '
      'httpStatus=${statusCode?.toString() ?? "not_applicable"} '
      'incidentId=${incidentId ?? "none"} '
      'backendStatus=$backendStatus '
      'responseSummary=${_compactDiagnosticValue(responseSummary)} '
      'error=${error == null ? "none" : _compactDiagnosticValue(error)}',
    );
  }

  void _logRemoteRelaySosStateRehydrate({
    required RemoteRelaySosSnapshot snapshot,
    required String? expectedIncidentId,
    required String source,
  }) {
    final currentIncident =
        _publicSosFallbackIncident ?? _lastKnownActiveSosIncident;
    final currentIncidentId = currentIncident?.id ?? _lastPublicSosIncidentId;
    final terminal = _isOpenSosState(_publicSosState)
        ? 'open'
        : _isTerminalPublicSosState(_publicSosState)
            ? _publicSosState.name
            : _publicSosState.name;
    final containsRemoteSos = expectedIncidentId != null &&
        expectedIncidentId.trim().isNotEmpty &&
        currentIncidentId == expectedIncidentId;
    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS_STATE_REHYDRATE] '
      'source=$source '
      'deviceId=${_remoteRelayOriginatorDeviceId(snapshot)} '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'expectedIncidentId=${expectedIncidentId ?? "none"} '
      'fetchSosState=${_publicSosState.name} '
      'currentStage=${_publicSosState.name} '
      'currentTerminal=$terminal '
      'currentIncidentId=${currentIncidentId ?? "none"} '
      'backendStateContainsRemoteSos=$containsRemoteSos',
    );
  }

  String _remoteRelaySosBackendSubmitPath() {
    final repository = sosRepository;
    if (repository is MqttOperationalSosRepository) {
      return 'mqtt_operational_publish';
    }
    if (_remoteRelayOperationalRealtimeClient() != null) {
      return 'remote_special';
    }
    return 'none';
  }

  String _remoteRelayBackendEndpointLabel() {
    final path = _remoteRelaySosBackendSubmitPath();
    return switch (path) {
      'mqtt_operational_publish' || 'remote_special' => SdkMqttTopics.sosAlerts,
      _ => 'none',
    };
  }

  String _remoteRelayBackendMethodLabel() {
    final path = _remoteRelaySosBackendSubmitPath();
    return path == 'none' ? 'none' : 'MQTT_PUBLISH';
  }

  String _remoteRelayOriginatorDeviceId(RemoteRelaySosSnapshot snapshot) {
    // LoRa relay SOS is owned by the originator node; the connected relay is
    // metadata only.
    return snapshot.originatorNodeId.toString();
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
      final repository = sosRepository as MqttOperationalSosRepository;
      return _session != null &&
          (_lastRealtimeConnectionState == RealtimeConnectionState.connected ||
              repository.remoteDataSource != null);
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
    final flutterShortCommandPath = deviceSosController.shortCommandAvailable;
    final flutterLongCommandPath = deviceSosController.longCommandAvailable;
    final serviceBleConnected =
        platformOwnsBle ? protectionStatus.serviceBleConnected : null;
    final serviceBleReady =
        platformOwnsBle ? protectionStatus.serviceBleReady : null;
    final deviceConnected = platformOwnsBle
        ? protectionStatus.deviceConnected ||
            protectionStatus.serviceBleConnected ||
            protectionStatus.serviceBleReady
        : (chosenConnected ?? false) ||
            flutterShortCommandPath ||
            flutterLongCommandPath;
    final shortCommandAvailable = platformOwnsBle
        ? protectionStatus.serviceBleReady || flutterShortCommandPath
        : flutterShortCommandPath;
    final longCommandAvailable = platformOwnsBle
        ? protectionStatus.serviceBleReady || flutterLongCommandPath
        : flutterLongCommandPath;
    final deviceSosAvailable = deviceConnected && shortCommandAvailable;
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
      'shortCommandAvailable=$shortCommandAvailable '
      'longCommandAvailable=$longCommandAvailable '
      'result=${capability?.name ?? "unavailable"}',
    );

    return _CurrentSosCapabilitySnapshot(
      backendAvailable: backendAvailable,
      deviceConnected: deviceConnected,
      chosenConnected: chosenConnected ?? false,
      serviceBleConnected: serviceBleConnected,
      serviceBleReady: serviceBleReady,
      shortCommandAvailable: shortCommandAvailable,
      longCommandAvailable: longCommandAvailable,
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

  Future<InMemoryDeviceRepository> _ensureCommandCapableDeviceRepository({
    required String action,
  }) async {
    final repository = deviceRepository;
    if (repository is! InMemoryDeviceRepository) {
      _throwDeviceCommandNotReady();
    }
    if (repository.hasCommandCapableBleRuntime) {
      return repository;
    }

    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_COMMAND_READY] rebind_requested action=$action',
    );
    await _bleAutoReconnectCoordinator.tryAutoConnectOnResume();
    if (repository.hasCommandCapableBleRuntime) {
      BleDebugRegistry.instance.recordEvent(
        '[DEVICE_COMMAND_READY] rebind_succeeded action=$action',
      );
      return repository;
    }

    final identity = await repository.getRuntimeIdentitySnapshot();
    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_COMMAND_READY] rebind_unavailable action=$action '
      'serviceBleConnected=${identity.serviceBleConnected} '
      'commandCapable=${identity.commandCapable} '
      'reason=${identity.readinessReason.diagnosticName}',
    );
    _throwDeviceCommandNotReady();
  }

  Future<void> _markDeviceDisconnectedAfterLocalShutdown() async {
    final repository = deviceRepository;
    if (repository is! InMemoryDeviceRepository) {
      _lastDeviceStatus = await repository.getDeviceStatus();
      return;
    }
    _lastDeviceStatus = await repository.markDeviceDisconnected(
      reason: 'shutdown_command',
    );
  }

  Future<ProtectionStatus> _syncDeviceStateFromProtectionStatus(
    ProtectionStatus status,
  ) async {
    if (!_protectionStatusIndicatesMissingMobileBond(status)) {
      return status;
    }
    final repository = deviceRepository;
    if (repository is InMemoryDeviceRepository) {
      _lastDeviceStatus = await repository.markMobileBondMissing(
        reason: 'protection_mobile_bond_missing',
      );
    }
    return status.copyWith(
      devicePaired: false,
      deviceConnected: false,
    );
  }

  bool _protectionStatusIndicatesMissingMobileBond(ProtectionStatus status) {
    final text = <String?>[
      status.readinessFailureReason,
      status.degradationReason,
      status.lastCommandError,
    ].whereType<String>().join(' ').toLowerCase();
    return text.contains('e_device_mobile_bond_required') ||
        text.contains('phone bluetooth bond') ||
        text.contains('no longer paired in the phone bluetooth');
  }

  Future<void> _sendDeviceControlCommandThroughActiveOwner({
    required String action,
    required EixamDeviceCommand command,
  }) async {
    if (!_isProtectionPlatformOwningBle) {
      await _ensureCommandCapableDeviceRepository(action: action);
    }
    await _sendDeviceCommandThroughActiveOwner(command);
  }

  void _validateDeviceVolume(int volume) {
    if (volume < 0 || volume > 100) {
      throw const DeviceException(
        'E_DEVICE_INVALID_VOLUME',
        'Device volume must be within the inclusive range 0..100.',
      );
    }
  }

  Never _throwDeviceCommandNotReady() {
    throw const DeviceException(
      'E_DEVICE_COMMAND_NOT_READY',
      'A connected command-capable device is required for this SDK action.',
    );
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
      shortCommandAvailable: capabilitySnapshot.shortCommandAvailable,
      longCommandAvailable: capabilitySnapshot.longCommandAvailable,
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

  _ProtectionSosPayloadReason _protectionSosPayloadReasonFromPlatformEvent(
    ProtectionPlatformEvent event,
  ) {
    final reason = _parseProtectionSosPayloadReason(event.reason);
    final payloadHex = reason.payloadHex ?? event.payloadHex?.trim();
    final source = reason.source ??
        (event.source == null
            ? null
            : _remoteRelaySourceFromPlatform(event.source!.trim()));
    final allowNativeOwnClassification =
        event.type == ProtectionPlatformEventType.ownDeviceSosLifecycleObserved;
    final identityOwn = reason.identityOwn ||
        allowNativeOwnClassification &&
            (event.classification == 'ownDeviceSos' ||
                event.classification == 'own_device');
    final identityUnknown = reason.identityUnknown ||
        event.classification == 'unknownOriginSos' ||
        event.classification == 'unknown_origin';
    return _ProtectionSosPayloadReason(
      payloadHex: payloadHex == null || payloadHex.isEmpty ? null : payloadHex,
      source: source,
      relayNodeId: reason.relayNodeId,
      identityOwn: identityOwn,
      identityUnknown: identityUnknown && !identityOwn,
    );
  }

  _ProtectionSosPayloadReason _parseProtectionSosPayloadReason(
    String? reason,
  ) {
    final rawReason = reason?.trim();
    if (rawReason == null || rawReason.isEmpty) {
      return const _ProtectionSosPayloadReason();
    }
    final parts = rawReason.split(':');
    if (parts.length == 4 && parts[0] == 'remote') {
      return _ProtectionSosPayloadReason(
        payloadHex: parts[3],
        source: _remoteRelaySourceFromPlatform(parts[1]),
        relayNodeId: int.tryParse(parts[2]),
      );
    }
    if (parts.length == 3 && parts[0] == 'unknown') {
      return _ProtectionSosPayloadReason(
        payloadHex: parts[2],
        source: _remoteRelaySourceFromPlatform(parts[1]),
        identityUnknown: true,
      );
    }
    if (parts.length == 3 && parts[0] == 'own') {
      return _ProtectionSosPayloadReason(
        payloadHex: parts[2],
        source: _remoteRelaySourceFromPlatform(parts[1]),
        identityOwn: true,
      );
    }
    return _ProtectionSosPayloadReason(payloadHex: rawReason);
  }

  RemoteRelaySosSource _remoteRelaySourceFromPlatform(String source) {
    return switch (source) {
      'tel' => RemoteRelaySosSource.telRelay,
      'd2' => RemoteRelaySosSource.d2Relay,
      _ => RemoteRelaySosSource.sosNotify,
    };
  }

  BleIncomingPayloadClassification _classifyProtectionPlatformRemoteSos({
    required List<int> bytes,
    required String rawHex,
    required RemoteRelaySosSource? source,
    required int? relayNodeId,
    required bool forceUnknownIdentity,
  }) {
    final channel = source == RemoteRelaySosSource.telRelay
        ? EixamBleChannel.tel
        : EixamBleChannel.sos;
    return _protectionSosPayloadClassifier.classifySosPayload(
      payload: bytes,
      payloadHex: rawHex,
      receivedAt: DateTime.now().toUtc(),
      source: DeviceSosTransitionSource.device,
      channel: channel,
      connectedBleTagNodeId:
          forceUnknownIdentity ? null : relayNodeId ?? _knownLocalDeviceNodeId,
      fallbackOnUnknownConnectedNode: const BleIncomingPayloadClassification(
        kind: BleIncomingPayloadKind.unknownOriginSos,
      ),
    );
  }

  RemoteRelaySosSnapshot? _unknownOriginRemoteSosSnapshotFromPlatform({
    required List<int> bytes,
    required String rawHex,
    required RemoteRelaySosSource? source,
  }) {
    final sosPacket = EixamSosPacket.tryParse(bytes);
    if (sosPacket == null || sosPacket.sosType == 0) {
      return null;
    }
    final receivedAt = DateTime.now().toUtc();
    return RemoteRelaySosSnapshot(
      kind: RemoteRelaySosKind.sos,
      originatorNodeId: sosPacket.nodeId,
      relayNodeId: null,
      source: source ?? RemoteRelaySosSource.sosNotify,
      sosType: sosPacket.sosType,
      location: sosPacket.position == null
          ? null
          : TrackingPosition(
              latitude: sosPacket.position!.latitude,
              longitude: sosPacket.position!.longitude,
              altitude: sosPacket.position!.altitudeMeters.toDouble(),
              timestamp: receivedAt,
              source: DeliveryMode.mesh,
            ),
      receivedAt: receivedAt,
      rawPayload: List<int>.unmodifiable(bytes),
      payloadHex: rawHex,
      relayCount: sosPacket.relayCount,
    );
  }

  int? _statusCodeForError(Object error) {
    final dynamic dynamicError = error;
    try {
      return dynamicError.statusCode as int?;
    } catch (_) {
      return null;
    }
  }

  void _logSosTrace(String message) {}

  void _logProtectionSosIdentityDecision({
    required int? originatorNodeId,
    required int? connectedBleNodeId,
    required int? relayNodeId,
    required String sourceChannel,
    required String platformEventType,
    required String decision,
    required String reason,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'sos_identity_decision '
      'originatorNodeId=${originatorNodeId?.toString() ?? "-"} '
      'connectedBleNodeId=${connectedBleNodeId?.toString() ?? "-"} '
      'relayNodeId=${relayNodeId?.toString() ?? "-"} '
      'sourceChannel=$sourceChannel '
      'platformEventType=$platformEventType '
      'decision=$decision '
      'reason=$reason',
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
      if (initialStatus.nodeId != null) {
        _knownLocalDeviceNodeId = initialStatus.nodeId;
      }
      BleDebugRegistry.instance.recordEvent(
        '$trigger device status resolved -> connected=${initialStatus.connected} previous=- deviceId=${initialStatus.nodeId?.toString() ?? 'none'} nodeId=${initialStatus.nodeId ?? 'none'} hardwareId=${initialStatus.deviceId} lifecycle=${initialStatus.lifecycleState.name} refreshed=$refreshRuntimeStatus source=initial_repository_snapshot',
      );
      return initialStatus;
    }
    final status = refreshRuntimeStatus
        ? await deviceRepository.refreshDeviceStatus()
        : await deviceRepository.getDeviceStatus();
    final previous = _lastDeviceStatus;
    _lastDeviceStatus = status;
    if (status.nodeId != null) {
      _knownLocalDeviceNodeId = status.nodeId;
    }
    BleDebugRegistry.instance.recordEvent(
      '$trigger device status resolved -> connected=${status.connected} previous=${previous?.connected} deviceId=${status.nodeId?.toString() ?? 'none'} nodeId=${status.nodeId ?? 'none'} hardwareId=${status.deviceId} lifecycle=${status.lifecycleState.name} refreshed=$refreshRuntimeStatus',
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
    await _publicDeviceStatusController.close();
    await _publicSosStateController.close();
    await _publicPreSosStatusController.close();
    await _notificationIntentController.close();
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

class _RemoteRelayLocalGuardMatch {
  const _RemoteRelayLocalGuardMatch({
    required this.nodeId,
    required this.matchedBy,
  });

  final int? nodeId;
  final String matchedBy;
}

enum _SosOwner { app, device }

class _OperationalSosIdentity {
  const _OperationalSosIdentity({
    this.deviceId,
    this.hardwareId,
    this.originatorNodeId,
  });

  final String? deviceId;
  final String? hardwareId;
  final int? originatorNodeId;
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
    required this.cycleRevision,
    required this.cycleKey,
    required this.startedAt,
    required this.expectedActivationAt,
    required this.mirroredOnDevice,
    required this.origin,
    required this.owner,
    required this.originatorNodeId,
    required this.packetId,
    required this.timer,
  });

  final int cycleRevision;
  final String cycleKey;
  final DateTime startedAt;
  final DateTime expectedActivationAt;
  final bool mirroredOnDevice;
  final DeviceSosTransitionSource? origin;
  final _SosOwner owner;
  final int? originatorNodeId;
  final int? packetId;
  final Timer timer;

  _PreSosSession copyWith({
    int? cycleRevision,
    String? cycleKey,
    DateTime? startedAt,
    DateTime? expectedActivationAt,
    bool? mirroredOnDevice,
    Object? origin = _unset,
    _SosOwner? owner,
    int? originatorNodeId,
    int? packetId,
    Timer? timer,
  }) {
    return _PreSosSession(
      cycleRevision: cycleRevision ?? this.cycleRevision,
      cycleKey: cycleKey ?? this.cycleKey,
      startedAt: startedAt ?? this.startedAt,
      expectedActivationAt: expectedActivationAt ?? this.expectedActivationAt,
      mirroredOnDevice: mirroredOnDevice ?? this.mirroredOnDevice,
      origin: identical(origin, _unset)
          ? this.origin
          : origin as DeviceSosTransitionSource?,
      owner: owner ?? this.owner,
      originatorNodeId: originatorNodeId ?? this.originatorNodeId,
      packetId: packetId ?? this.packetId,
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
    required this.shortCommandAvailable,
    required this.longCommandAvailable,
    required this.deviceSosAvailable,
    required this.capability,
  });

  final bool backendAvailable;
  final bool deviceConnected;
  final bool chosenConnected;
  final bool? serviceBleConnected;
  final bool? serviceBleReady;
  final bool shortCommandAvailable;
  final bool longCommandAvailable;
  final bool deviceSosAvailable;
  final SosDeliveryChannel? capability;
}

class _TerminalSosSuppression {
  const _TerminalSosSuppression({
    required this.originatorNodeId,
    required this.boundDeviceId,
    required this.expiresAt,
    required this.reason,
  });

  final int? originatorNodeId;
  final String? boundDeviceId;
  final DateTime expiresAt;
  final String reason;
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

class _ProtectionSosPayloadReason {
  const _ProtectionSosPayloadReason({
    this.payloadHex,
    this.source,
    this.relayNodeId,
    this.identityUnknown = false,
    this.identityOwn = false,
  });

  final String? payloadHex;
  final RemoteRelaySosSource? source;
  final int? relayNodeId;
  final bool identityUnknown;
  final bool identityOwn;

  String get debugPayloadKeys {
    final keys = <String>[];
    if (payloadHex != null) {
      keys.add('payloadHex');
    }
    if (source != null) {
      keys.add('source');
    }
    if (relayNodeId != null) {
      keys.add('relayNodeId');
    }
    if (identityUnknown) {
      keys.add('classification');
    }
    if (identityOwn) {
      keys.add('classification');
    }
    return keys.isEmpty ? 'none' : keys.join(',');
  }
}

class _RemoteRelayBackendSubmissionResult {
  const _RemoteRelayBackendSubmissionResult({
    required this.submitPath,
    this.statusCode,
    this.incidentId,
  });

  final String submitPath;
  final int? statusCode;
  final String? incidentId;
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
