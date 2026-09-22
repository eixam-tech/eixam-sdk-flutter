import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, kDebugMode, visibleForTesting;
import 'package:flutter/widgets.dart';

import '../data/datasources_local/device_config_store.dart';
import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/datasources_local/sdk_session_store.dart';
import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_remote/sos_remote_data_source.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/api_sos_repository.dart';
import '../data/repositories/mqtt_operational_sos_repository.dart';
import '../diagnostics/security_diagnostics_redactor.dart';
import '../data/datasources_remote/sdk_device_config_remote_data_source.dart';
import '../data/datasources_remote/sdk_feedback_remote_data_source.dart';
import '../data/datasources_remote/sdk_geo_country_remote_data_source.dart';
import '../data/datasources_remote/sdk_identity_remote_data_source.dart';
import '../data/datasources_remote/sdk_network_psk_remote_data_source.dart';
import '../data/datasources_remote/sdk_profile_remote_data_source.dart';
import '../device/ble_incoming_event.dart';
import '../device/ble_incoming_payload_classifier.dart';
import '../device/canonical_hardware_id.dart';
import '../device/device_sos_controller.dart';
import '../device/ble_debug_registry.dart';
import '../device/ble_debug_state.dart';
import '../device/eixam_ble_command.dart';
import '../device/eixam_ble_protocol.dart';
import '../device/ble_scan_result.dart';
import '../device/eixam_sos_event_packet.dart';
import '../device/eixam_sos_packet.dart';
import '../provisioning/device_provisioning_coordinator.dart';
import '../provisioning/device_assignment_verifier.dart';
import '../provisioning/strict_device_provisioning_config.dart';
import '../data/datasources_remote/sdk_session_context.dart';
import '../data/repositories/telemetry_repository.dart';
import '../data/repositories/sos_runtime_rehydration_support.dart';
import '../mappers/local_state_serializers.dart';
import 'android_protection_platform_adapter.dart';
import 'android_tracking_owner_arbiter.dart';
import 'authoritative_sos_lifecycle_controller.dart';
import 'background_location_platform_adapter.dart';
import 'background_location_platform_adapter_factory.dart';
import 'background_telemetry_platform_adapter.dart';
import 'background_telemetry_platform_adapter_factory.dart';
import 'ble_operational_runtime_bridge.dart';
import 'ble_auto_reconnect_coordinator.dart';
import 'ble_sos_notification_payload.dart';
import 'device_country_config_controller.dart';
import 'device_position_batch_normalizer.dart';
import 'device_position_backlog_coordinator.dart';
import 'firmware_update_coordinator.dart';
import 'device_migration_coordinator.dart';
import 'nearby_text_controller.dart';
import 'operational_telemetry_coordinator.dart';
import 'operational_realtime_client.dart';
import 'protection_mode_controller.dart';
import 'protection_platform_adapter.dart';
import 'protection_platform_adapter_factory.dart';
import 'public_device_connection_bridge.dart';
import 'relay_ingest_context.dart';
import 'location_debug_log.dart';
import 'latest_phone_position_sink.dart';
import 'sdk_resolved_location_resolver.dart';
import 'sdk_mqtt_contract.dart';
import 'sos_backend_identity_normalizer.dart';
import 'sos_incident_correlation.dart';
import 'sos_origin_classifier.dart';
import 'sos_location_ownership_effect.dart';
import 'sos_location_ownership_orchestrator.dart';
import 'sos_location_ownership_platform_sink.dart';
import 'sos_location_trace.dart';

int _sosProcessSessionSequence = 0;

String _nextSosProcessSessionId() {
  _sosProcessSessionSequence += 1;
  return '${DateTime.now().toUtc().microsecondsSinceEpoch}-$_sosProcessSessionSequence';
}

@visibleForTesting
bool isStrictlyNewerSosReceiveSequence({
  required int incomingSequence,
  required int terminalBoundarySequence,
}) {
  return incomingSequence > terminalBoundarySequence;
}

@visibleForTesting
enum SosBleOwnershipState { flutterOwner, nativePreparing, nativeReadyOwner }

@visibleForTesting
enum SosBleSingleOwnerViolation {
  none,
  nativeOwnerWithFlutterGatt,
  flutterOwnerWithNativeGatt,
}

@visibleForTesting
SosBleOwnershipState resolveSosBleOwnershipState({
  required ProtectionBleOwner declaredOwner,
  required bool nativeCommandReady,
}) {
  if (declaredOwner == ProtectionBleOwner.flutter) {
    return SosBleOwnershipState.flutterOwner;
  }
  return nativeCommandReady
      ? SosBleOwnershipState.nativeReadyOwner
      : SosBleOwnershipState.nativePreparing;
}

@visibleForTesting
SosBleSingleOwnerViolation evaluateSosBleSingleOwnerInvariant({
  required bool nativeDeclared,
  required bool flutterOwner,
  required bool flutterReleaseSettled,
  required bool nativeGattConnected,
  required bool flutterGattConnected,
}) {
  if (nativeDeclared && flutterReleaseSettled && flutterGattConnected) {
    return SosBleSingleOwnerViolation.nativeOwnerWithFlutterGatt;
  }
  if (flutterOwner && nativeGattConnected) {
    return SosBleSingleOwnerViolation.flutterOwnerWithNativeGatt;
  }
  return SosBleSingleOwnerViolation.none;
}

@visibleForTesting
enum NativeProtectionCommandReadinessFailure {
  none,
  ownerNotNative,
  gattNotConnected,
  canonicalCommandPathNotReady,
  targetIdentityMismatch,
  operationQueueFailed,
}

@visibleForTesting
class NativeProtectionCommandReadiness {
  const NativeProtectionCommandReadiness({
    required this.ready,
    required this.failure,
  });

  final bool ready;
  final NativeProtectionCommandReadinessFailure failure;
}

@visibleForTesting
NativeProtectionCommandReadiness evaluateNativeProtectionCommandReadiness({
  required ProtectionBleOwner declaredOwner,
  required bool serviceBleConnected,
  required bool serviceReady,
  required bool cmdEa04Ready,
  required bool exactTargetIdentityMatch,
  required bool operationQueueOperational,
}) {
  final failure = declaredOwner == ProtectionBleOwner.flutter
      ? NativeProtectionCommandReadinessFailure.ownerNotNative
      : !serviceBleConnected
      ? NativeProtectionCommandReadinessFailure.gattNotConnected
      : !serviceReady || !cmdEa04Ready
      ? NativeProtectionCommandReadinessFailure.canonicalCommandPathNotReady
      : !exactTargetIdentityMatch
      ? NativeProtectionCommandReadinessFailure.targetIdentityMismatch
      : !operationQueueOperational
      ? NativeProtectionCommandReadinessFailure.operationQueueFailed
      : NativeProtectionCommandReadinessFailure.none;
  return NativeProtectionCommandReadiness(
    ready: failure == NativeProtectionCommandReadinessFailure.none,
    failure: failure,
  );
}

/// Main SDK orchestrator used by host apps.
///
/// It composes repositories, exposes a stable public API and coordinates
/// cross-module workflows such as attaching a location snapshot to SOS or
/// escalating a Death Man plan into SOS automatically.
class EixamConnectSdkImpl
    with WidgetsBindingObserver
    implements
        EixamConnectSdk,
        BackgroundLocationControl,
        SosIncidentProgressProvider {
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
    this.sessionStore,
    this.recoverUnreadablePersistedSession = false,
    SecureKeyValueStore? sosLifecycleSecureStore,
    this.sessionContext,
    this.identityRemoteDataSource,
    this.profileRemoteDataSource,
    this.feedbackRemoteDataSource,
    this.geoCountryRemoteDataSource,
    this.deviceConfigRemoteDataSource,
    this.networkPskRemoteDataSource,
    this.provisioningConfigSource,
    this.provisioningBackendUrl,
    this.deviceConfigStore,
    this.firmwareUpdateCoordinator,
    this.deviceMigrationCoordinator,
    this.notificationPolicy = EixamNotificationPolicy.sdkManaged,
    this.notificationTexts = _fallbackNotificationTexts,
    this.permissionDisclosureConfig = const EixamPermissionDisclosureConfig(),
    ProtectionPlatformAdapter? protectionPlatformAdapter,
    BackgroundLocationPlatformAdapter? backgroundLocationPlatformAdapter,
    BackgroundTelemetryPlatformAdapter? backgroundTelemetryPlatformAdapter,
    SharedPrefsSdkStore? localStore,
    DateTime Function()? clock,
    Duration appTriggeredSosBridgeWindow = _defaultAppTriggeredSosBridgeWindow,
    SosLocationOwnershipEffectMode sosLocationOwnershipEffectMode =
        SosLocationOwnershipEffectMode.enabled,
    TargetPlatform? sosLocationOwnershipPlatform,
    bool? sosLocationOwnershipIsWeb,
    Future<void> Function(EixamDeviceCommand command)? backlogCommandWriter,
    this.disposeCallback,
  }) : _clock = clock ?? DateTime.now,
       _appTriggeredSosBridgeWindow = appTriggeredSosBridgeWindow,
       _localStore = localStore ?? SharedPrefsSdkStore(),
       protectionPlatformAdapter =
           protectionPlatformAdapter ?? buildDefaultProtectionPlatformAdapter(),
       backgroundLocationPlatformAdapter =
           backgroundLocationPlatformAdapter ??
           buildDefaultBackgroundLocationPlatformAdapter(),
       backgroundTelemetryPlatformAdapter =
           backgroundTelemetryPlatformAdapter ??
           buildDefaultBackgroundTelemetryPlatformAdapter() {
    _devicePositionBacklogCoordinator = DevicePositionBacklogCoordinator(
      writeCommand: backlogCommandWriter ?? _writePositionBacklogCommand,
      normalizer: _devicePositionBatchNormalizer,
      emitBatch: (batch) {
        if (!_devicePositionBatchController.isClosed) {
          _devicePositionBatchController.add(batch);
        }
      },
    );
    _nearbyTextController = NearbyTextController(
      incomingEvents: bleIncomingEvents,
      writeCommand: _sendDeviceCommandThroughActiveOwner,
      // Passive native TEL notifications now share the Dart decoder. Nearby
      // request/response still fails fast until its command transaction is
      // explicitly owner-aware, avoiding timeouts that poison the group epoch.
      bleOwnedByProtection: () => _isProtectionPlatformOwningBle,
    );
    _bleAutoReconnectCoordinator = BleAutoReconnectCoordinator(
      deviceRepository: deviceRepository,
      preferredDeviceStore: preferredBleDeviceStore,
      permissionStateProvider: permissionsRepository.getPermissionState,
      isNativeProtectionOwningBle: () => _shouldSkipFlutterBleReconnect,
      nativeProtectionReconnectSuppressionReason: () {
        if (!_isProtectionPlatformOwningBle) {
          return null;
        }
        return _isAuthoritativeNativeProtectionBleOwner
            ? 'native_ready'
            : 'native_preparing';
      },
      onNativeProtectionOwnsBle: (trigger) {
        return _delegateBleToNativeProtection(reason: 'native_owner_$trigger');
      },
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
      sosBackendAssignmentVerifiedRetry: _retrySosAfterAssignmentVerification,
    );
    _protectionModeController = ProtectionModeController(
      platformAdapter: this.protectionPlatformAdapter,
      sessionProvider: () async => _session,
      sdkConfigProvider: () => _sdkConfig,
      deviceStatusProvider: () async =>
          _lastDeviceStatus ?? await deviceRepository.getDeviceStatus(),
      permissionStateProvider: permissionsRepository.getPermissionState,
      operationalDiagnosticsProvider: () async =>
          _buildOperationalDiagnostics(reason: 'protection_mode_controller'),
      backendHardwareIdProvider: () =>
          _loadBackendHardwareIdForOperationalPayloads(
            runtimeStatus: _lastDeviceStatus,
          ),
      hostAppManagedNotificationsProvider: () =>
          notificationPolicy == EixamNotificationPolicy.hostAppManaged,
      notificationTextsProvider: () => notificationTexts,
      onBleOwnershipChanged: _handleProtectionBleOwnershipChanged,
    );
    _resolvedLocationResolver = SdkResolvedLocationResolver(
      trackingRepository: trackingRepository,
      deviceStatusProvider: () => _lastPublicDeviceStatus ?? _lastDeviceStatus,
      bridgeDiagnosticsProvider: () => _bridgeDiagnostics,
    );
    _trackingOwnerArbiter = AndroidTrackingOwnerArbiter(
      trackingRepository: trackingRepository,
    );
    final sosLocationOwnershipEffectSink = createSosLocationOwnershipEffectSink(
      platform: sosLocationOwnershipPlatform,
      isWeb: sosLocationOwnershipIsWeb,
      effectMode: sosLocationOwnershipEffectMode,
      trackingOwnerArbiter: _trackingOwnerArbiter,
      backgroundLocationPlatformAdapter: this.backgroundLocationPlatformAdapter,
    );
    _sosLifecycle = AuthoritativeSosLifecycleController(
      secureStore: sosLifecycleSecureStore ?? InMemorySecureKeyValueStore(),
      locationOwnershipEffectSink: sosLocationOwnershipEffectSink,
      locationOwnershipEffectMode: sosLocationOwnershipEffectMode,
    );
    deviceSosController.setPhysicalSosStartAdmissionPolicy(
      _evaluatePhysicalSosStartAdmission,
    );
    if (sosLocationOwnershipEffectMode ==
        SosLocationOwnershipEffectMode.enabled) {
      _sosLocationOwnershipStatusSub = this.backgroundLocationPlatformAdapter
          .watchBackgroundLocationStatus()
          .listen((_) {
            unawaited(
              _sosLifecycle.reconcileLocationOwnership(
                SosLocationOwnershipReconciliationReason
                    .permissionOrStatusChange,
              ),
            );
          });
    }
    if (trackingRepository is LatestPhonePositionSink) {
      final phonePositionSink = trackingRepository as LatestPhonePositionSink;
      _nativeLocationSampleSub = this.backgroundLocationPlatformAdapter
          .watchLocationSamples()
          .listen(
            (sample) {
              unawaited(
                phonePositionSink.acceptPhonePosition(
                  sample.toTrackingPosition(),
                  source: PhonePositionSource.nativeContext,
                ),
              );
            },
            onError: (Object _, StackTrace _) {
              SosLocationTrace.emit('ios_native_sample', {
                'action': 'rejected',
                'context': 'unknown',
                'sample_available': false,
                'timestamp_present': false,
                'observer_count': 1,
              });
            },
          );
    }
    _operationalTelemetryCoordinator = OperationalTelemetryCoordinator(
      trackingRepository: trackingRepository,
      authoritativeSosCadenceStream: _sosLifecycle.cadenceStream,
      sessionProvider: () => _session,
      publishTelemetry: publishTelemetry,
      resolvedLocationProvider: () => _resolveLocation(
        useCase: SdkResolvedLocationUseCase.telemetryBackend,
      ),
    );
    final repository = sosRepository;
    if (repository is MqttOperationalSosRepository) {
      repository.preSosBackendPublishBlocker =
          _shouldBlockDeviceOriginPreSosBackendPublish;
      repository.lifecycleGenerationProvider = () =>
          _sosLifecycle.current.generation;
    }
    _maybeBuildDeviceCountryConfigController();
    _bindSosStreams();
    final rejectedTerminalSource = sosRepository;
    if (rejectedTerminalSource is SosRejectedTerminalReconciliationSource) {
      final source =
          rejectedTerminalSource as SosRejectedTerminalReconciliationSource;
      _rejectedTerminalReconciliationSub = source
          .watchRejectedTerminalReconciliations()
          .listen(_handleRejectedTerminalReconciliationRequest);
    }
    _sosCapabilityLifecycleSub = _sosLifecycle.stream.listen((lifecycle) {
      if (lifecycle.isTerminal) {
        _recordTerminalNativeReceiveBoundary(lifecycle);
        final status = deviceSosController.currentStatus;
        _rememberTerminalDeviceCycleFence(
          status: status,
          effectiveNodeId:
              lifecycle.nodeId ?? status.nodeId ?? _knownLocalDeviceNodeId,
        );
      }
      unawaited(_emitSosCapability(reason: 'lifecycle_change'));
    });
  }

  void _maybeBuildDeviceCountryConfigController() {
    final geoSource = geoCountryRemoteDataSource;
    final configSource = deviceConfigRemoteDataSource;
    final configStore = deviceConfigStore;
    if (geoSource == null || configSource == null || configStore == null) {
      return;
    }
    final controller = DeviceCountryConfigController(
      geoCountrySource: geoSource,
      deviceConfigSource: configSource,
      store: configStore,
      locationProvider: () => _resolveLocation(
        useCase: SdkResolvedLocationUseCase.emergencyBackend,
      ),
      runtimeStatusProvider: getDeviceRuntimeStatus,
      setRegionCommand: (regionCode) =>
          _sendDeviceControlCommandThroughActiveOwner(
            action: 'set_region',
            command: EixamDeviceCommand.setRegion(regionCode),
          ),
      rebootCommand: rebootDevice,
      deviceStatusProvider: () => _lastPublicDeviceStatus ?? _lastDeviceStatus,
      safetyHoldReason: _deviceCountryConfigSafetyHold,
    );
    _deviceCountryConfigController = controller;
    _deviceCountryConfigStatusSub = controller.watchStatus().listen((status) {
      _lastDeviceCountryConfigStatus = status;
      if (!_deviceCountryConfigStatusController.isClosed) {
        _deviceCountryConfigStatusController.add(status);
      }
    });
  }

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
  final SdkSessionStore? sessionStore;
  final bool recoverUnreadablePersistedSession;
  late final AuthoritativeSosLifecycleController _sosLifecycle;
  late final AndroidTrackingOwnerArbiter _trackingOwnerArbiter;
  @visibleForTesting
  SosLocationOwnershipOrchestrator get debugSosLocationOwnershipOrchestrator =>
      _sosLifecycle.locationOwnershipOrchestrator;
  @visibleForTesting
  SosLocationOwnershipEffectDiagnostics
  get debugSosLocationOwnershipEffectDiagnostics =>
      _sosLifecycle.locationOwnershipEffectDispatcher.diagnostics;
  @visibleForTesting
  AndroidTrackingOwnerDiagnostics get debugAndroidTrackingOwnerDiagnostics =>
      _trackingOwnerArbiter.diagnostics;
  @visibleForTesting
  Future<void> debugReconcileSosLocationOwnership() =>
      _sosLifecycle.reconcileLocationOwnershipForTesting();
  final SdkSessionContext? sessionContext;
  final SdkIdentityRemoteDataSource? identityRemoteDataSource;
  final SdkProfileRemoteDataSource? profileRemoteDataSource;
  final SdkFeedbackRemoteDataSource? feedbackRemoteDataSource;
  final SdkGeoCountryRemoteDataSource? geoCountryRemoteDataSource;
  final SdkDeviceConfigRemoteDataSource? deviceConfigRemoteDataSource;
  final SdkNetworkPskRemoteDataSource? networkPskRemoteDataSource;
  final StrictDeviceProvisioningConfigSource? provisioningConfigSource;
  final String? provisioningBackendUrl;
  final DeviceConfigStore? deviceConfigStore;
  final EixamNotificationPolicy notificationPolicy;
  final EixamNotificationTexts notificationTexts;
  final EixamPermissionDisclosureConfig permissionDisclosureConfig;
  final ProtectionPlatformAdapter protectionPlatformAdapter;
  final BackgroundLocationPlatformAdapter backgroundLocationPlatformAdapter;
  final BackgroundTelemetryPlatformAdapter backgroundTelemetryPlatformAdapter;
  final FirmwareUpdateCoordinator? firmwareUpdateCoordinator;
  final DeviceMigrationCoordinator? deviceMigrationCoordinator;
  DeviceCountryConfigController? _deviceCountryConfigController;
  DeviceProvisioningCoordinator? _deviceProvisioningCoordinator;
  final StreamController<DeviceCountryConfigStatus>
  _deviceCountryConfigStatusController =
      StreamController<DeviceCountryConfigStatus>.broadcast();
  DeviceCountryConfigStatus _lastDeviceCountryConfigStatus =
      DeviceCountryConfigStatus.idle();
  StreamSubscription<DeviceCountryConfigStatus>? _deviceCountryConfigStatusSub;
  StreamSubscription<BackgroundLocationRuntimeStatus>?
  _sosLocationOwnershipStatusSub;
  StreamSubscription<IosBackgroundLocationSample>? _nativeLocationSampleSub;
  final DateTime Function() _clock;
  bool _deviceCountryConfigCheckDrainRunning = false;
  ({String trigger, int? connectionEpoch, bool resume})?
  _queuedDeviceCountryConfigCheck;
  int _deviceCountryConfigConnectionEpoch = 0;
  int? _lastCheckedDeviceCountryConfigConnectionEpoch;
  DateTime? _lastDeviceCountryConfigCheckAt;
  String? _lastDeviceCountryConfigCheckDeviceKey;
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
  final StreamController<SdkResolvedLocation?> _resolvedLocationController =
      StreamController<SdkResolvedLocation?>.broadcast();
  final StreamController<EixamDevicePositionBatch>
  _devicePositionBatchController =
      StreamController<EixamDevicePositionBatch>.broadcast();
  final StreamController<SosCapabilitySnapshot> _sosCapabilityController =
      StreamController<SosCapabilitySnapshot>.broadcast();
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
  StreamSubscription<bool>? _deviceControlCommandPathSub;
  StreamSubscription<SosState>? _sosStateSub;
  StreamSubscription<MqttAcceptedSosLifecycleTransition>?
  _mqttAcceptedSosLifecycleTransitionSub;
  StreamSubscription<SosRejectedTerminalReconciliationRequest>?
  _rejectedTerminalReconciliationSub;
  StreamSubscription<SdkBridgeDiagnostics>? _bridgeDiagnosticsSub;
  StreamSubscription<BleIncomingEvent>? _bleIncomingEventDiagnosticsSub;
  StreamSubscription<ProtectionStatus>? _protectionStatusSub;
  StreamSubscription<ProtectionPlatformEvent>? _protectionRawSosEventsSub;
  StreamSubscription<SosLifecycleSnapshot>? _sosCapabilityLifecycleSub;
  Timer? _protectionDisconnectGraceTimer;
  bool _lastProtectionDeviceConnected = false;
  bool _lastProtectionServiceBleReady = false;
  bool _lastNativeProtectionCommandReady = false;
  ProtectionBleOwner _lastProtectionBleOwner = ProtectionBleOwner.flutter;
  ProtectionModeState _lastProtectionModeState = ProtectionModeState.off;
  SosBleOwnershipState _lastSosBleOwnershipState =
      SosBleOwnershipState.flutterOwner;
  bool _firmwareOtaInProgress = false;
  bool _migrationInspectionInProgress = false;
  bool _bleOwnershipHandoffInFlight = false;
  bool _nativeCommandReadinessRefreshInFlight = false;
  bool _flutterBleReleaseCompletedForNativeOwnership = false;
  bool _nativePreparationRequestedForOwnership = false;
  String? _lastSosBleOwnerDiagnostic;
  String? _lastSosBleOwnerStateSignature;
  String? _lastSosBleSingleOwnerViolationSignature;
  String? _lastNativeRawPayloadHex;
  String? _lastNativeRawReceiveCorrelation;
  int? _lastNativeRawReceiveSequence;
  String? _lastNativeRawCharacteristicUuid;
  String? _lastNativeRawConnectedDeviceMarker;
  final String _processSessionId = _nextSosProcessSessionId();
  final DateTime _processSessionStartedAt = DateTime.now().toUtc();
  int? _latestNativeReceiveSequence;
  int? _lastOwnDeviceTerminalNativeReceiveSequence;
  int? _lastOwnDeviceTerminalNativeGeneration;
  String? _lastOwnDeviceTerminalReceiveSequenceDomain;
  String? _lastOwnDeviceTerminalProcessSessionId;
  int? _terminalBoundaryFromPreviousProcessGeneration;
  final Set<int> _terminalGenerationsEstablishedThisProcess = <int>{};

  Timer? _deathManTimer;
  bool _deathManCheckInNotified = false;
  bool _deathManOverdueNotified = false;

  RealtimeConnectionState _lastRealtimeConnectionState =
      RealtimeConnectionState.disconnected;
  RealtimeEvent? _lastRealtimeEvent;
  DeviceStatus? _lastDeviceStatus;
  DeviceStatus? _lastPublicDeviceStatus;
  _CanonicalNativeConnectionProof? _canonicalNativeConnectionProof;
  int _canonicalNativeConnectionProofSequence = 0;
  String? _lastProjectedDeviceConnectionOwner;
  String? _lastConnectionTransitionPreservedSignature;
  BleNotificationNavigationRequest? _pendingBleNotificationNavigationRequest;
  final List<EixamNotificationIntent> _pendingNotificationIntents =
      <EixamNotificationIntent>[];
  final Set<String> _emittedNotificationIntentKeys = <String>{};
  final List<String> _emittedNotificationIntentKeyOrder = <String>[];
  bool _disposed = false;
  String? _activeDeviceSosCycleKey;
  String? _notifiedDeviceSosCycleKey;
  DeviceSosState? _notifiedDeviceSosState;
  EixamSession? _session;
  EixamSdkEvent? _lastSosEvent;
  String? _pendingCancelledIncidentId;
  String? _lastSosRehydrationNote;
  Future<SosRuntimeRehydrationResult?>? _sosRuntimeRehydrationInFlight;
  bool _sosRuntimeRehydrationInFlightExpectsTerminal = false;
  Timer? _foregroundSosReconciliationTimer;
  int _foregroundSosReconciliationAttempt = 0;
  SdkBridgeDiagnostics _bridgeDiagnostics = const SdkBridgeDiagnostics();
  SdkResolvedLocation? _lastResolvedLocation;
  SosState _publicSosState = SosState.idle;
  int _publicSosStateGeneration = 0;
  int? _publicTerminalGeneration;
  int? _publicAcknowledgedGeneration;
  static const Duration _foregroundSosReconciliationInitialDelay = Duration(
    seconds: 5,
  );
  static const Duration _foregroundSosReconciliationMaximumDelay = Duration(
    seconds: 30,
  );
  PublicPreSosStatus? _lastPublishedPreSosStatus;
  SosIncident? _publicSosFallbackIncident;
  SosIncident? _lastKnownActiveSosIncident;
  String? _lastLoggedActiveIncidentPreservationSignature;
  bool _loggedBackgroundSosPublishTraceV2 = false;
  String? _lastPublicSosIncidentId;
  SosDeliveryChannel? _lastPublicSosDeliveryChannel;
  SosTerminalReason? _lastPublicSosTerminalReason;
  final Set<String> _acknowledgedTerminalSosIncidentIds = <String>{};
  bool _acknowledgedTerminalSosWithoutIncident = false;
  _AppTriggeredSosBridge? _pendingAppTriggeredSosBridge;
  _PreSosSession? _preSosSession;
  _AppOriginMirroredPreSosBridge? _recentAppOriginMirroredPreSosBridge;
  _AppOriginActiveSosBridge? _appOriginActiveSosBridge;
  _AppOriginDeviceOwnershipContext? _appOriginDeviceOwnershipContext;
  String? _remoteTerminalDeviceClearInFlightKey;
  _PhysicalSosTerminationTarget? _remoteTerminalDeviceClearPendingProof;
  _PhysicalSosTerminationTarget? _remoteTerminalDeviceClearAwaitingAckProof;
  _PhysicalSosTerminationTarget? _remoteTerminalDeviceClearAcknowledgedProof;
  final Set<String> _supersededRemoteTerminalDeviceClearKeys = <String>{};
  final Set<String> _backendResolvePhysicalTerminalResultKeys = <String>{};
  final Set<String> _backendResolveWriteSubmittedKeys = <String>{};
  final Set<String> _backendResolveWriteSuccessKeys = <String>{};
  final Set<String> _authoritativeTerminalOperationKeys = <String>{};
  _SosDeviceMirrorState _sosDeviceMirrorState =
      _SosDeviceMirrorState.synchronized;
  _TerminalConvergenceFence? _terminalConvergenceFence;
  int? _freshPhysicalStartSupersededRemoteClearGeneration;
  int? _postResolvePhysicalRxGeneration;
  int? _deviceInactiveBoundaryAfterTerminalGeneration;
  _ObservedOwnDeviceInactiveBoundary? _latestOwnDeviceInactiveBoundary;
  _TerminalDeviceCycleFence? _terminalDeviceCycleFence;
  _FreshPhysicalStartProof? _pendingFreshPhysicalStartProof;
  final Set<String> _acceptedPhysicalStartPacketSignatures = <String>{};
  final Map<int, Set<String>> _devicePacketSignaturesByGeneration =
      <int, Set<String>>{};
  final Set<int> _deviceMirrorDispatchedGenerations = <int>{};
  int? _knownLocalDeviceNodeId;
  SosDeliveryChannel? _lastPublishedCurrentSosCapabilityChannel;
  String? _lastSosCapabilityEvaluationSignature;
  int _sosCapabilityEmissionRevision = 0;
  DeviceTelRelayRx? _lastTelRelayRx;
  final Map<String, _ObservedRelaySosContext> _observedRelaySosBySignature =
      <String, _ObservedRelaySosContext>{};
  final Map<String, DateTime> _remoteRelaySosBackendHandoffBySignature =
      <String, DateTime>{};
  final Map<String, DateTime> _remoteRelaySosBackendHandoffInFlightBySignature =
      <String, DateTime>{};
  final Map<String, DateTime> _remoteRelayLifecycleAdmissionBySignature =
      <String, DateTime>{};
  final Map<String, String> _remoteRelayLifecycleAdmissionRouteBySignature =
      <String, String>{};
  final Map<String, DateTime> _remoteRelaySosCancelSucceededBySignature =
      <String, DateTime>{};
  final Map<String, DateTime> _remoteRelaySosCancelInFlightBySignature =
      <String, DateTime>{};
  final Map<String, DateTime> _externalRelayRearmedAtByKey =
      <String, DateTime>{};
  final Map<String, _RecentExternalRelaySosContext>
  _recentExternalRelaySosContexts = <String, _RecentExternalRelaySosContext>{};
  final Map<String, _PendingExternalRelayCancel> _pendingExternalRelayCancels =
      <String, _PendingExternalRelayCancel>{};
  final Map<String, _PreSosTerminalCancelContext>
  _preSosTerminalCancelContextByKey = <String, _PreSosTerminalCancelContext>{};
  final Map<String, _SosClosureIntent>
  _deviceOriginatedClosureIntentByCycleKey = <String, _SosClosureIntent>{};
  final Map<String, _SosClosureIntent>
  _deviceOriginatedClosureIntentByIncidentId = <String, _SosClosureIntent>{};
  String? _activeDeviceRuntimeIncidentId;
  String? _activeDeviceRuntimeCycleKey;
  String? _activeDeviceRuntimeLocalCycleKey;
  String? _lastClosedDeviceRuntimeLocalCycleKey;
  int _deviceRuntimeLocalCycleSequence = 0;
  int _deviceSosStatusEventSequence = 0;
  String? _deviceOwnedBackendIncidentId;
  String? _lastDeviceRuntimeCanonicalIncidentSignature;
  SosIncident? _lastDeviceRuntimeCanonicalIncident;
  final Set<String> _loggedDeviceRuntimeCanonicalizationSignatures = <String>{};
  final Set<String> _closedDeviceRuntimeIncidentIds = <String>{};
  final Map<String, int> _sosRuntimeNodeIdByHardwareId = <String, int>{};
  final Map<int, String> _hardwareIdByNodeId = <int, String>{};
  final Map<String, DateTime> _sosRuntimeInvariantLogByKey =
      <String, DateTime>{};
  final Map<String, DateTime> _sosRejectionLogByKey = <String, DateTime>{};
  bool _publicSosActionInFlight = false;
  _SosClosureIntent? _publicSosClosureInFlight;
  Future<SosIncident>? _pendingPreSosConfirmation;
  bool _preSosExpirySettlementInFlight = false;
  final Map<String, DateTime> _recentOsSosWidgetActions = <String, DateTime>{};
  final Set<String> _deviceOriginatedBackendSyncInFlight = <String>{};
  final Set<String> _iosExpiredPreSosPromotionKeys = <String>{};
  EixamSdkConfig? _sdkConfig;
  bool _sdkInitialized = false;
  bool _sosLifecycleConsumerReady = true;
  final Set<String> _verifiedAssignedNodeIdsForSession = <String>{};
  final Set<int> _assignmentClaimInFlight = <int>{};
  bool _manualDisconnectRequested = false;
  bool _lastDeviceControlCommandPathAvailable = false;
  int _preSosCycleRevision = 0;
  int _pendingSosActivationRevision = 0;
  _PendingSosActivationOperation? _pendingSosActivation;
  final Set<int> _loggedIgnoredPreSosTickCycles = <int>{};
  late final BleAutoReconnectCoordinator _bleAutoReconnectCoordinator;
  late final BleOperationalRuntimeBridge _bleOperationalRuntimeBridge;
  late final ProtectionModeController _protectionModeController;
  late final OperationalTelemetryCoordinator _operationalTelemetryCoordinator;
  late final SdkResolvedLocationResolver _resolvedLocationResolver;
  final DevicePositionBatchNormalizer _devicePositionBatchNormalizer =
      DevicePositionBatchNormalizer();
  late final DevicePositionBacklogCoordinator _devicePositionBacklogCoordinator;
  late final NearbyTextController _nearbyTextController;
  final Duration _appTriggeredSosBridgeWindow;
  bool _deferredRuntimeWorkPending = false;
  bool _backgroundTelemetryEnabled = false;
  bool _backgroundTelemetryStarted = false;
  BackgroundTrackingState _backgroundTrackingState =
      BackgroundTrackingState.stopped;
  AppLifecycleState _appLifecycleState =
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  DateTime? _lastNativeProtectionEnsureAt;
  String? _backgroundTelemetryStartFingerprint;
  String? _backgroundTelemetryNotificationTitle;
  String? _backgroundTelemetryNotificationBody;
  BackgroundTelemetryDiagnostics _backgroundTelemetryDiagnostics =
      const BackgroundTelemetryDiagnostics();
  bool _nativeBackgroundTelemetryFlushInFlight = false;
  final Set<String> _nativeSosCreateFlushInFlight = <String>{};

  static const String _openAppActionId = 'open_app';
  static const String _cancelSosActionId = 'cancel_sos';
  static const String _resolveSosActionId = 'resolve_sos';
  static const String _confirmSosActionId = 'confirm_sos';
  static const String _confirmDeadManSafeActionId = 'confirm_dead_man_safe';
  static const Duration _externalRelayIdentityTtl = Duration(days: 30);
  static const Duration _defaultAppTriggeredSosBridgeWindow = Duration(
    seconds: 15,
  );
  static const Duration _preSosTickInterval = Duration(milliseconds: 50);
  static const Duration _preSosTerminalCancelGraceWindow = Duration(seconds: 5);
  static const Duration _preSosTerminalCancelContextTtl = Duration(seconds: 30);
  static const Duration _osSosWidgetActionDedupeWindow = Duration(minutes: 10);
  static const Duration _deviceCountryConfigResumeMinInterval = Duration(
    minutes: 15,
  );
  static const Duration _deviceCountryConfigDuplicateMinInterval = Duration(
    seconds: 10,
  );
  static const Duration _nativeProtectionEnsureDebounce = Duration(seconds: 2);
  static const Duration _nativePendingSosCreateTtl = Duration(hours: 24);
  static const Duration _backgroundTelemetryStartConfirmationInterval =
      Duration(milliseconds: 50);
  static const int _backgroundTelemetryStartConfirmationAttempts = 20;
  static const Duration _nativePendingSosBackendConfirmTtl = Duration(
    hours: 24,
  );
  static const Duration _iosExpiredPreSosPromotionTtl = Duration(minutes: 10);
  static const int _maxPendingNotificationIntents = 20;
  static const int _maxRememberedNotificationIntentKeys = 100;
  static const String _permissionDisclosureAcksKey =
      'eixam.permissions.disclosure_acks';
  static const EixamNotificationTexts _fallbackNotificationTexts =
      EixamNotificationTexts(
        protectionActiveTitle: '',
        protectionActiveBody: '',
        protectionModeTitle: '',
        protectionModeBody: '',
        protectionModeChannelName: '',
        protectionModeChannelDescription: '',
        protectionSosChannelName: '',
        protectionSosChannelDescription: '',
        protectionPreSosTitle: '',
        protectionPreSosBody: '',
        protectionSosActiveTitle: '',
        protectionSosActiveBody: '',
        protectionSosResolvedTitle: '',
        protectionSosResolvedBody: '',
      );

  @override
  Future<void> initialize(EixamSdkConfig config) async {
    _sosLifecycleConsumerReady = false;
    SosLocationTrace.emit('sdk_runtime', {
      'action': 'initialize_begin',
      'recurring_publication_owner': 'sdk',
      'recurring_publication_paths': 1,
    });
    BleDebugRegistry.instance.recordEvent(
      '[SDK_RUNTIME_MARKER] package=eixam_connect_flutter '
      'marker=sos_debug_build_v3 path=eixam_connect_sdk_impl.dart',
    );
    _backgroundTelemetryNotificationTitle ??=
        notificationTexts.protectionActiveTitle;
    _backgroundTelemetryNotificationBody ??=
        notificationTexts.protectionActiveBody;
    _sdkConfig = config;
    _session = await sessionStore?.load(
      recoverUnreadableEntry: recoverUnreadablePersistedSession,
    );
    _session = await _bootstrapSessionIfNeeded(_session);
    await _sosLifecycle.restoreFor(_session, emitToStream: false);
    _recordRestoredTerminalBoundaryFromPreviousProcess();
    await _refreshBackgroundTelemetryDiagnostics();
    if (_backgroundTelemetryDiagnostics.serviceRunning && _session != null) {
      _backgroundTelemetryStartFingerprint = _backgroundTelemetryFingerprint(
        apiBaseUrl: config.apiBaseUrl,
        session: _session!,
      );
    }
    _manualDisconnectRequested = await preferredBleDeviceStore
        .readManualDisconnectRequested();
    if (_manualDisconnectRequested) {
      _clearDeviceRuntimeResidueAfterManualDisconnect();
    }
    if (sessionContext != null) {
      sessionContext!.currentSession = _session;
    }
    await _restoreDeviceIdentityMappings();
    await _restoreRecentExternalRelaySosContexts();
    _lastDeviceStatus = await deviceRepository.getDeviceStatus();
    final deviceSosStatus = await deviceSosController.getStatus();
    _syncPreSosSessionFromDeviceStatus(deviceSosStatus);
    await _syncPreSosSessionFromProtectionPlatformSnapshot(
      trigger: 'initialize',
    );
    await _restorePersistedPreSosSession(trigger: 'initialize');
    await _rehydrateSosRuntimeState();
    _sosLifecycleConsumerReady = true;
    _sosLifecycle.publishCurrent();
    _applyPublicSosState(
      _publicSosStateFromRepositoryLoad(
        incoming: await sosRepository.getSosState(),
        source: 'repository_load:initialize',
      ),
      source: 'repository_load:initialize',
      emit: false,
    );
    WidgetsBinding.instance.addObserver(this);
    await _bleAutoReconnectCoordinator.initialize(
      initialStatus: _publishPublicDeviceStatus(
        rawStatus: _lastDeviceStatus!,
        reason: 'auto_reconnect_initialize',
        emit: false,
      ),
      deviceStatusStream: _publicDeviceStatusController.stream,
    );
    _bindDeviceStreams();
    if (_sdkSosNotificationsEnabled) {
      await notificationsRepository.initialize(
        onAction: _handleNotificationAction,
      );
    }
    _bindRealtimeStreams();
    _bindOperationalDiagnostics();
    _bleOperationalRuntimeBridge.start();
    _emitOperationalDiagnostics();
    _operationalTelemetryCoordinator.start(
      initialCadence: _sosLifecycle.currentCadence,
    );
    if ((_sdkConfig?.deferRuntimeStartup ?? false) && _session != null) {
      _deferredRuntimeWorkPending = true;
      BleDebugRegistry.instance.recordEvent(
        'SDK_CLIENT_CREATION_READY_WITH_TRANSPORT_PENDING '
        'trigger=initialize transport=mqtt status=runtime_deferred',
      );
      _sdkInitialized = true;
      _emitOperationalDiagnostics(reason: 'sdk_initialized');
      return;
    }
    await _reconcileBackgroundTelemetry(reason: 'initialize');
    _connectRealtimeInBackground(trigger: 'initialize');
    await _resumeDeathManMonitoringIfNeeded();
    await _seedPreferredBleDeviceFromSystemAssociationIfNeeded(
      trigger: 'initialize',
    );
    await _seedPreferredBleDeviceFromBackendRegistryIfNeeded(
      trigger: 'initialize',
    );
    await _flushPendingExternalRelayCancelsFromProtectionPlatform(
      trigger: 'initialize',
    );
    if (await _nativeProtectionOwnsBleAfterRehydrate()) {
      unawaited(
        _delegateBleToNativeProtection(reason: 'initialize_native_ble_owner'),
      );
    } else {
      await _bleAutoReconnectCoordinator.tryAutoConnectOnStartup();
    }
    if ((_lastPublicDeviceStatus ?? _lastDeviceStatus)?.connected == true) {
      final connectionEpoch = _ensureDeviceCountryConfigConnectionEpoch();
      unawaited(
        _maybeCheckDeviceCountryConfig(
          'initialize',
          connectionEpoch: connectionEpoch,
        ),
      );
    }
    _sdkInitialized = true;
    _emitOperationalDiagnostics(reason: 'sdk_initialized');
  }

  void _bindDeviceStreams() {
    _deviceStatusSub?.cancel();
    _deviceSosSub?.cancel();
    _deviceControlCommandPathSub?.cancel();
    _lastDeviceControlCommandPathAvailable =
        deviceSosController.hasCommandChannel;
    if ((_lastPublicDeviceStatus ?? _lastDeviceStatus)?.connected == true) {
      final connectionEpoch = _ensureDeviceCountryConfigConnectionEpoch();
      unawaited(
        _maybeCheckDeviceCountryConfig(
          'device_streams_bound',
          connectionEpoch: connectionEpoch,
        ),
      );
    }

    _deviceStatusSub = deviceRepository.watchDeviceStatus().listen((status) {
      final promotedStatus = _promoteCachedNodeIdOntoDeviceStatus(
        status,
        source: 'device_status_stream',
      );
      final previousStatus = _lastDeviceStatus;
      _lastDeviceStatus = promotedStatus;
      _logSosBleOwnerState(
        reason: 'flutter_device_status',
        status: _protectionModeController.currentStatus,
      );
      final protectionStatus = _protectionModeController.currentStatus;
      if (!promotedStatus.connected &&
          _sosBleOwnershipState == SosBleOwnershipState.nativeReadyOwner) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_FLUTTER_GATT_CLEANUP_ISOLATED '
          'nativeOwner=nativeReady '
          'nativeGattConnected=${protectionStatus.serviceBleConnected} '
          'subscriptionsActive=${protectionStatus.serviceBleReady} '
          'nativeCommandReady=${protectionStatus.nativeCommandReady}',
        );
      }
      if (promotedStatus.nodeId != null) {
        _knownLocalDeviceNodeId = promotedStatus.nodeId;
      }
      _publishPublicDeviceStatus(
        rawStatus: promotedStatus,
        reason: 'device_status_stream',
      );
      _scheduleConnectedDeviceAssignmentClaim(
        status: promotedStatus,
        previous: previousStatus,
      );
      BleDebugRegistry.instance.recordEvent(
        'Device connectivity changed -> connected=${promotedStatus.connected} previous=${previousStatus?.connected} deviceId=${promotedStatus.nodeId?.toString() ?? "-"} nodeId=${promotedStatus.nodeId?.toString() ?? "-"} hardwareId=${promotedStatus.deviceId} lifecycle=${promotedStatus.lifecycleState.name}',
      );
      _emitOperationalDiagnostics();
      if (!promotedStatus.connected) {
        _nearbyTextController.markDisconnected();
        unawaited(_devicePositionBacklogCoordinator.disconnected());
      } else if (previousStatus?.connected != true) {
        _nearbyTextController.markConnected();
      } else {
        _nearbyTextController.noteStillConnected();
      }
      unawaited(
        _updateBackgroundTelemetryState(reason: 'device_status_stream'),
      );
      final connectedDeviceChanged =
          promotedStatus.connected &&
          (previousStatus?.connected != true ||
              DeviceCountryConfigController.deviceKeyFor(previousStatus!) !=
                  DeviceCountryConfigController.deviceKeyFor(promotedStatus));
      if (connectedDeviceChanged) {
        // A real connection transition must always be checked once. If service
        // discovery is still finishing, this is deferred until CMD is ready.
        final connectionEpoch = _startDeviceCountryConfigConnectionEpoch();
        unawaited(
          _maybeCheckDeviceCountryConfig(
            'device_connected',
            connectionEpoch: connectionEpoch,
          ),
        );
      }
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

    _deviceControlCommandPathSub = deviceSosController
        .watchControlCommandPathAvailability()
        .listen(
          (available) async {
            final previous = _lastDeviceControlCommandPathAvailable;
            _lastDeviceControlCommandPathAvailable = available;
            BleDebugRegistry.instance.recordEvent(
              'Device control command path availability changed -> available=$available previous=$previous connected=${_lastDeviceStatus?.connected} deviceId=${_lastDeviceStatus?.nodeId?.toString() ?? "-"} nodeId=${_lastDeviceStatus?.nodeId?.toString() ?? "-"} hardwareId=${_lastDeviceStatus?.deviceId ?? "-"}',
            );
            if (available == previous) {
              BleDebugRegistry.instance.recordEvent(
                'device_control_command_path_changed -> diagnostics_refresh_skipped reason=no_effective_change',
              );
              return;
            }
            if (available &&
                (_lastPublicDeviceStatus ?? _lastDeviceStatus)?.connected ==
                    true) {
              // Complete a connection check that was deferred while Flutter was
              // discovering services. The connection epoch prevents this from
              // duplicating a check already started by the status stream.
              final connectionEpoch =
                  _ensureDeviceCountryConfigConnectionEpoch();
              unawaited(
                _maybeCheckDeviceCountryConfig(
                  'control_command_path_available',
                  connectionEpoch: connectionEpoch,
                ),
              );
            }
            await _refreshOperationalDiagnostics(
              trigger: 'device_control_command_path_changed',
              refreshRuntimeStatus: false,
            );
          },
          onError: (Object error) {
            BleDebugRegistry.instance.recordEvent(
              'Device control command path monitor error: $error',
            );
          },
        );
  }

  void _bindRealtimeStreams() {
    _realtimeConnectionSub?.cancel();
    _realtimeEventsSub?.cancel();

    _realtimeConnectionSub = realtimeClient.watchConnectionState().listen(
      (state) {
        final previousState = _lastRealtimeConnectionState;
        _lastRealtimeConnectionState = state;
        _realtimeConnectionStateController.add(state);
        _emitOperationalDiagnostics();
        if (state == RealtimeConnectionState.connected &&
            previousState != RealtimeConnectionState.connected &&
            _session != null) {
          unawaited(
            _rehydrateSosRuntimeState(
              trigger: 'mqtt_reconnected',
              emitPublicState: true,
            ),
          );
        }
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
    _bridgeDiagnosticsSub = _bleOperationalRuntimeBridge
        .watchDiagnostics()
        .listen((diagnostics) {
          _bridgeDiagnostics = diagnostics;
          final latestOwnDeviceLocation = diagnostics.latestOwnDeviceLocation;
          final connected =
              (_lastPublicDeviceStatus ?? _lastDeviceStatus)?.connected == true;
          if (connected && latestOwnDeviceLocation != null) {
            _rememberResolvedLocation(latestOwnDeviceLocation);
          }
          _emitOperationalDiagnostics(reason: 'bridge_diagnostics');
        });
    _protectionStatusSub?.cancel();
    _protectionStatusSub = _protectionModeController.watchStatus().listen((
      status,
    ) {
      final previousConnected = _lastProtectionDeviceConnected;
      final previousReady = _lastProtectionServiceBleReady;
      final previousNativeCommandReady = _lastNativeProtectionCommandReady;
      final previousOwner = _lastProtectionBleOwner;
      final previousNativeOwnsBle =
          _lastProtectionModeState != ProtectionModeState.off &&
          previousOwner != ProtectionBleOwner.flutter;
      _lastProtectionDeviceConnected = status.deviceConnected;
      _lastProtectionServiceBleReady = status.serviceBleReady;
      _lastNativeProtectionCommandReady = status.nativeCommandReady;
      _lastProtectionBleOwner = status.bleOwner;
      _lastProtectionModeState = status.modeState;
      final nativeOwnsBle =
          status.modeState != ProtectionModeState.off &&
          status.bleOwner != ProtectionBleOwner.flutter;
      final currentSosBleOwnershipState =
          status.modeState == ProtectionModeState.off
          ? SosBleOwnershipState.flutterOwner
          : resolveSosBleOwnershipState(
              declaredOwner: status.bleOwner,
              nativeCommandReady: _nativeCommandReadinessForStatus(
                status,
              ).ready,
            );
      final nativeOwnerBecameReady =
          currentSosBleOwnershipState ==
              SosBleOwnershipState.nativeReadyOwner &&
          _lastSosBleOwnershipState != SosBleOwnershipState.nativeReadyOwner;
      _lastSosBleOwnershipState = currentSosBleOwnershipState;
      if (nativeOwnsBle && !previousNativeOwnsBle) {
        _flutterBleReleaseCompletedForNativeOwnership = false;
      }
      if (status.bleOwner == ProtectionBleOwner.flutter) {
        _flutterBleReleaseCompletedForNativeOwnership = false;
        _nativePreparationRequestedForOwnership = false;
      }
      final ownershipStatusReason = nativeOwnerBecameReady
          ? 'protection_status:native_readiness_snapshot'
          : 'protection_status:${status.lastPlatformEvent ?? "snapshot"}';
      _logSosBleOwnerState(reason: ownershipStatusReason, status: status);
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
      final nativeLive = _protectionReportsLiveBleConnection(status);
      if (nativeOwnsBle && nativeLive && _isAppBackgrounded) {
        _bleAutoReconnectCoordinator.setAppForeground(false);
      }
      final nativeOwnershipStarted = nativeOwnsBle && !previousNativeOwnsBle;
      final nativeConnectionBecameLive =
          nativeOwnsBle && nativeLive && !previousConnected;
      final nativeCommandPathBecameReady =
          nativeOwnsBle &&
          status.nativeCommandReady &&
          !previousNativeCommandReady;
      final nativeOwnershipNeedsHandoff =
          nativeOwnershipStarted ||
          nativeConnectionBecameLive ||
          nativeCommandPathBecameReady;
      if (nativeOwnershipNeedsHandoff) {
        unawaited(_handleProtectionBleOwnershipChanged(status.bleOwner));
      }
      final nativeReadinessEvent =
          status.lastPlatformEvent ==
              ProtectionPlatformEventType.nativeCommandReadinessChanged.name ||
          previousNativeCommandReady != status.nativeCommandReady;
      if (nativeReadinessEvent || nativeOwnerBecameReady) {
        final falsePredicate = !nativeOwnsBle
            ? 'nativeOwner'
            : !status.serviceBleConnected
            ? 'nativeGattConnected'
            : !status.nativeCommandServiceReady
            ? 'serviceDiscovered'
            : !status.nativeCommandEa04Ready
            ? 'ea04Present'
            : !status.nativeCommandIdentityReady
            ? 'exactIdentityMatch'
            : !status.nativeCommandQueueHealthy
            ? 'queueHealthy'
            : 'none';
        BleDebugRegistry.instance.recordEvent(
          'SOS_NATIVE_COMMAND_READINESS_INPUT '
          'nativeOwner=$nativeOwnsBle '
          'nativeGattConnected=${status.serviceBleConnected} '
          'serviceDiscovered=${status.nativeCommandServiceReady} '
          'ea04Present=${status.nativeCommandEa04Ready} '
          'exactIdentityMatch=${status.nativeCommandIdentityReady} '
          'queueHealthy=${status.nativeCommandQueueHealthy} '
          'nativeCommandReady=${status.nativeCommandReady} '
          'falsePredicate=$falsePredicate '
          'ownerTransitionReady=$nativeOwnerBecameReady',
        );
        BleDebugRegistry.instance.recordEvent(
          'SOS_NATIVE_COMMAND_READINESS_CHANGED '
          'previous=$previousNativeCommandReady '
          'next=${status.nativeCommandReady} '
          'reason=${status.lastBleServiceEvent ?? "platform_event"}',
        );
        final capabilityReason = nativeOwnerBecameReady
            ? 'native_owner_ready'
            : 'native_command_readiness_changed';
        if (nativeOwnerBecameReady) {
          BleDebugRegistry.instance.recordEvent(
            'SOS_NATIVE_OWNER_READY_CAPABILITY_REFRESH '
            'trigger=resolved_owner_transition '
            'snapshotEvent=${status.lastPlatformEvent ?? "none"} '
            'nativeCommandReady=${status.nativeCommandReady}',
          );
        }
        unawaited(_emitSosCapability(reason: capabilityReason));
      }
      if (nativeOwnsBle &&
          status.deviceConnected &&
          (!previousConnected || nativeOwnershipStarted)) {
        final connectionEpoch = _startDeviceCountryConfigConnectionEpoch();
        unawaited(
          _maybeCheckDeviceCountryConfig(
            'native_protection_device_connected',
            connectionEpoch: connectionEpoch,
          ),
        );
      } else if (nativeOwnsBle &&
          status.deviceConnected &&
          status.serviceBleReady &&
          !previousReady) {
        final connectionEpoch = _ensureDeviceCountryConfigConnectionEpoch();
        unawaited(
          _maybeCheckDeviceCountryConfig(
            'native_protection_command_path_available',
            connectionEpoch: connectionEpoch,
          ),
        );
      }
    });
    _bleIncomingEventDiagnosticsSub?.cancel();
    _bleIncomingEventDiagnosticsSub = bleIncomingEvents.listen(
      (event) {
        if (event.type == BleIncomingEventType.telPositionBacklog) {
          unawaited(_devicePositionBacklogCoordinator.handleEvent(event));
          return;
        }
        final positionBatch = _devicePositionBatchNormalizer.normalize(event);
        if (positionBatch != null && !_devicePositionBatchController.isClosed) {
          _devicePositionBatchController.add(positionBatch);
        }
        final relayPacket = event.telRelayRxPacket;
        if (relayPacket != null) {
          _lastTelRelayRx = relayPacket.relay;
          _emitOperationalDiagnostics(reason: 'ble_tel_relay_rx');
        }
        final remoteRelaySnapshot = event.remoteRelaySosSnapshot;
        if (remoteRelaySnapshot != null) {
          if (!_admitRemoteRelayLifecycleEvidence(
            remoteRelaySnapshot,
            evidenceRoute:
                'flutter:${event.source.name}:${event.channel.name}:${event.type.name}',
          )) {
            BleDebugRegistry.instance.recordEvent(
              'SOS_REMOTE_LIFECYCLE_ADMISSION admitted=false '
              'reason=duplicate_cross_characteristic_evidence '
              'remoteIdentity=${remoteRelaySnapshot.originatorNodeId} '
              'cycleCorrelation=${_remoteRelayCycleCorrelation(remoteRelaySnapshot)}',
            );
            return;
          }
          BleDebugRegistry.instance.recordEvent(
            'SOS_REMOTE_RELAY_CLASSIFICATION '
            'classification=${remoteRelaySnapshot.kind == RemoteRelaySosKind.sos ? "remoteRelaySos" : "remoteRelayCancel"} '
            'remoteOriginator=${remoteRelaySnapshot.originatorNodeId} '
            'connectedRelay=${remoteRelaySnapshot.relayNodeId?.toString() ?? "unknown"} '
            'lifecycleAction=${remoteRelaySnapshot.kind == RemoteRelaySosKind.sos ? "START" : "CANCEL"}',
          );
          BleDebugRegistry.instance.recordEvent(
            'SOS_REMOTE_LIFECYCLE_ADMISSION admitted=true '
            'reason=external_relay_evidence '
            'remoteIdentity=${remoteRelaySnapshot.originatorNodeId} '
            'cycleCorrelation=${_remoteRelayCycleCorrelation(remoteRelaySnapshot)}',
          );
          _logRemoteRelayTelClearDetected(remoteRelaySnapshot);
          _logRemoteRelayCancelDetection(
            source: 'ble_incoming_event',
            rawType: event.type.name,
            nodeId: remoteRelaySnapshot.originatorNodeId,
            originatorNodeId: remoteRelaySnapshot.originatorNodeId,
            relayNodeId: remoteRelaySnapshot.relayNodeId,
            relayHardwareId: event.canonicalHardwareId,
            classifiedAs: 'remoteRelay',
            action: remoteRelaySnapshot.kind == RemoteRelaySosKind.sos
                ? 'trigger_handoff'
                : 'cancel_handoff',
          );
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
          unawaited(_handleRemoteRelaySosBackendHandoff(remoteRelaySnapshot));
        }
        final sosEventPacket = event.sosEventPacket;
        if (sosEventPacket != null &&
            _isTerminalSosEventPacket(sosEventPacket)) {
          final synthesizedRemoteCancel =
              _remoteRelayCancelSnapshotForRelayTerminalEvent(
                packet: sosEventPacket,
                receivedAt: event.receivedAt,
                rawPayload: event.payload,
                payloadHex: event.payloadHex,
              );
          _logRemoteRelayCancelDetection(
            source: 'ble_incoming_event_terminal',
            rawType: event.type.name,
            nodeId: sosEventPacket.nodeId,
            originatorNodeId:
                synthesizedRemoteCancel?.originatorNodeId ??
                sosEventPacket.nodeId,
            relayNodeId:
                synthesizedRemoteCancel?.relayNodeId ?? sosEventPacket.nodeId,
            relayHardwareId: event.canonicalHardwareId,
            classifiedAs: synthesizedRemoteCancel == null
                ? 'ownDevice'
                : 'remoteRelay',
            action: synthesizedRemoteCancel == null
                ? 'local_terminal_only'
                : 'external_cancel_handoff',
          );
          if (synthesizedRemoteCancel != null) {
            _publishSdkEvent(
              RemoteRelaySosObservedEvent(synthesizedRemoteCancel),
            );
            unawaited(
              _handleRemoteRelaySosCancelBackendHandoff(
                synthesizedRemoteCancel,
              ),
            );
          }
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
    _protectionRawSosEventsSub = protectionPlatformAdapter
        .watchPlatformEvents()
        .listen(
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

  @override
  Future<void> setSession(
    EixamSession session, {
    bool deferRuntimeWork = false,
  }) async {
    final previousSession = _session;
    final nextSession = (await _bootstrapSessionIfNeeded(session))!;
    final authenticatedPrincipalChanged =
        previousSession != null &&
        !_sameAuthenticatedPrincipal(previousSession, nextSession);
    if (authenticatedPrincipalChanged) {
      _bleOperationalRuntimeBridge.resetForSessionChange();
      _clearVerifiedDeviceAssignments();
      await _clearSosRuntimeForSessionChange();
    }
    _session = nextSession;
    await _sosLifecycle.restoreFor(_session, emitToStream: false);
    _recordRestoredTerminalBoundaryFromPreviousProcess();
    if (sessionContext != null) {
      sessionContext!.currentSession = _session;
    }
    await _rehydrateSosRuntimeState();
    _sosLifecycle.publishCurrent();
    final preserveCurrentLocalSos =
        _sosLifecycle.current.localActionable &&
        !_sosLifecycle.current.externalOnly &&
        _sosLifecycle.current.isOpen;
    if (!preserveCurrentLocalSos) {
      _publicSosFallbackIncident = null;
      _clearPendingAppTriggeredSosBridge(reason: 'session_replaced');
    }
    _applyPublicSosState(
      _publicSosStateFromRepositoryLoad(
        incoming: await sosRepository.getSosState(),
        source: 'repository_load:set_session',
      ),
      source: 'repository_load:set_session',
      emit: false,
    );
    await sessionStore?.save(_session!);
    _emitOperationalDiagnostics();
    if (deferRuntimeWork) {
      _deferredRuntimeWorkPending = true;
      return;
    }
    await _startSessionRuntimeWork(trigger: 'set_session', session: _session!);
  }

  @override
  Future<void> startDeferredRuntime() async {
    final session = _session;
    if (session == null || !_deferredRuntimeWorkPending) {
      return;
    }
    _deferredRuntimeWorkPending = false;
    await _startSessionRuntimeWork(
      trigger: 'deferred_runtime',
      session: session,
    );
  }

  Future<void> _startSessionRuntimeWork({
    required String trigger,
    required EixamSession session,
  }) async {
    _operationalTelemetryCoordinator.start(
      initialCadence: _sosLifecycle.currentCadence,
    );
    await _reconcileBackgroundTelemetry(reason: trigger);
    await _seedPreferredBleDeviceFromSystemAssociationIfNeeded(
      trigger: trigger,
    );
    await _seedPreferredBleDeviceFromBackendRegistryIfNeeded(trigger: trigger);
    await _bleAutoReconnectCoordinator.tryAutoConnectOnResume();
    _connectRealtimeInBackground(
      trigger: trigger,
      sessionForReconnect: session,
    );
  }

  void _connectRealtimeInBackground({
    required String trigger,
    EixamSession? sessionForReconnect,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SDK_CLIENT_CREATION_MQTT_CONNECT_DEFERRED trigger=$trigger',
    );
    unawaited(() async {
      try {
        final stopwatch = Stopwatch()..start();
        final realtime = realtimeClient;
        if (sessionForReconnect != null &&
            realtime is OperationalRealtimeClient) {
          await realtime.reconnectIfSessionChanged(sessionForReconnect);
        } else {
          await realtime.connect();
        }
        BleDebugRegistry.instance.recordEvent(
          'SDK_CLIENT_CREATION_READY_WITH_TRANSPORT_PENDING '
          'trigger=$trigger transport=mqtt status=connect_attempt_finished '
          'elapsedMs=${stopwatch.elapsedMilliseconds}',
        );
      } catch (error) {
        BleDebugRegistry.instance.recordEvent(
          'SDK_CLIENT_CREATION_READY_WITH_TRANSPORT_PENDING '
          'trigger=$trigger transport=mqtt status=pending '
          'errorType=${error.runtimeType}',
        );
      }
    }());
    BleDebugRegistry.instance.recordEvent(
      'SDK_CLIENT_CREATION_READY_WITH_TRANSPORT_PENDING '
      'trigger=$trigger transport=mqtt status=background_connecting',
    );
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
      _clearVerifiedDeviceAssignments();
    }
    _session = refreshed;
    if (sessionContext != null) {
      sessionContext!.currentSession = refreshed;
    }
    await _rehydrateSosRuntimeState();
    final preserveCurrentLocalSos =
        _sosLifecycle.current.localActionable &&
        !_sosLifecycle.current.externalOnly &&
        _sosLifecycle.current.isOpen;
    if (!preserveCurrentLocalSos) {
      _publicSosFallbackIncident = null;
      _clearPendingAppTriggeredSosBridge(reason: 'identity_refreshed');
    }
    _applyPublicSosState(
      _publicSosStateFromRepositoryLoad(
        incoming: await sosRepository.getSosState(),
        source: 'repository_load:refresh_identity',
      ),
      source: 'repository_load:refresh_identity',
      emit: false,
    );
    await sessionStore?.save(refreshed);
    _emitOperationalDiagnostics();
    if (!_deferredRuntimeWorkPending) {
      await _startSessionRuntimeWork(
        trigger: 'refresh_identity',
        session: refreshed,
      );
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
    final profile = await ds.fetchProfile(sessionOverride: session);
    unawaited(_nearbyTextController.setOwnerDisplayName(profile.name));
    return profile;
  }

  @override
  Future<SdkUserProfile> updateSdkUserProfile(
    SdkUserProfileUpdate update,
  ) async {
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
    final profile = await ds.updateProfile(update, sessionOverride: session);
    unawaited(_nearbyTextController.setOwnerDisplayName(profile.name));
    return profile;
  }

  @override
  Future<void> deleteUserData({
    required String userHash,
    required String externalUserId,
  }) async {
    try {
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
          'An SDK session must be configured before deleting user data.',
        );
      }
      final trimmedUserHash = userHash.trim();
      final trimmedExternalUserId = externalUserId.trim();
      if (trimmedUserHash.isEmpty || trimmedExternalUserId.isEmpty) {
        throw const AuthException(
          'E_SDK_DELETE_USER_DATA_SIGNING_REQUIRED',
          'Signed SDK user identity is required before deleting user data.',
        );
      }
      await ds.deleteUserData(
        sessionOverride: EixamSession.signed(
          appId: session.appId,
          externalUserId: trimmedExternalUserId,
          userHash: trimmedUserHash,
        ),
      );
    } finally {
      await clearLocalUserData();
    }
  }

  @override
  Future<AppFeedbackSubmission> submitAppFeedback({
    required String description,
    required String userAccessToken,
  }) async {
    final ds = feedbackRemoteDataSource;
    if (ds == null) {
      throw const AuthException(
        'E_SDK_FEEDBACK_HTTP_UNAVAILABLE',
        'SDK feedback HTTP API is not configured for this runtime.',
      );
    }
    final session = _session;
    if (session == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'An SDK session must be configured before submitting feedback.',
      );
    }
    return ds.submitFeedback(
      session: session,
      description: description,
      userAccessToken: userAccessToken,
    );
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
    _mqttAcceptedSosLifecycleTransitionSub?.cancel();
    _sosStateSub = sosRepository.watchSosState().listen(
      _handleRepositorySosState,
    );
    final repository = sosRepository;
    if (repository is MqttOperationalSosRepository) {
      _mqttAcceptedSosLifecycleTransitionSub = repository
          .watchAcceptedLifecycleTransitions()
          .listen(_handleAcceptedMqttSosLifecycleTransition);
    }
  }

  Future<void> _handleAcceptedMqttSosLifecycleTransition(
    MqttAcceptedSosLifecycleTransition transition,
  ) async {
    if (!_isTerminalPublicSosState(transition.state)) {
      return;
    }
    await _applyAuthoritativeTerminalTransition(
      terminalIncident: transition.incident,
      source: transition.source,
      incomingRawStatus: transition.rawStatus,
      acceptedGeneration: transition.generation,
    );
  }

  Future<void> _handleRepositorySosState(SosState state) async {
    if (await _repositoryTerminalIsStaleForNewGeneration(state)) {
      _scheduleForegroundSosReconciliationIfNeeded();
      return;
    }
    await _syncPublicSosStateFromRepository(state);
    _scheduleForegroundSosReconciliationIfNeeded();
    if (state == SosState.cancelled || state == SosState.resolved) {
      _applyTerminalSosSuppression(
        reason: 'backend_terminal_state:${state.name}',
        terminalState: state,
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
  }

  Future<bool> _repositoryTerminalIsStaleForNewGeneration(
    SosState state,
  ) async {
    if (!_isTerminalPublicSosState(state) ||
        !_hasNewAuthoritativeGenerationSinceTerminal()) {
      return false;
    }
    final lifecycle = _sosLifecycle.current;
    final incident = await sosRepository.getCurrentIncident();
    if (!_sameSosGeneration(lifecycle, _sosLifecycle.current) ||
        !_hasNewAuthoritativeGenerationSinceTerminal()) {
      return false;
    }
    if (incident != null &&
        sosIncidentEvidenceMatchesLifecycle(lifecycle, incident)) {
      return false;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_STALE_TERMINAL_IGNORED_FOR_NEW_GENERATION '
      'terminalGeneration=${_sosLifecycle.activeTerminalWatermark?.generation ?? 0} '
      'activeGeneration=${lifecycle.generation} reason=identity_mismatch',
    );
    return true;
  }

  @override
  Future<void> clearLocalUserData() async {
    await _sosLifecycle.deleteAccountData();
    await _localStore.clearLocalUserData();
  }

  @override
  Future<void> clearSession() async {
    await _stopBackgroundTelemetry(reason: 'clear_session');
    await _operationalTelemetryCoordinator.stop();
    _bleOperationalRuntimeBridge.clearPendingOperationalItems();
    _session = null;
    _clearVerifiedDeviceAssignments();
    _lastSosRehydrationNote = null;
    _publicSosFallbackIncident = null;
    _lastPublicSosIncidentId = null;
    _lastPublicSosDeliveryChannel = null;
    _lastPublicSosTerminalReason = null;
    _clearAppOriginActiveSosBridge(reason: 'session_cleared');
    _clearAppOriginDeviceOwnershipContext(reason: 'session_cleared');
    _remoteTerminalDeviceClearPendingProof = null;
    _remoteTerminalDeviceClearAwaitingAckProof = null;
    _remoteTerminalDeviceClearAcknowledgedProof = null;
    _supersededRemoteTerminalDeviceClearKeys.clear();
    _backendResolvePhysicalTerminalResultKeys.clear();
    _backendResolveWriteSubmittedKeys.clear();
    _backendResolveWriteSuccessKeys.clear();
    _authoritativeTerminalOperationKeys.clear();
    _sosDeviceMirrorState = _SosDeviceMirrorState.synchronized;
    _terminalConvergenceFence = null;
    _freshPhysicalStartSupersededRemoteClearGeneration = null;
    _postResolvePhysicalRxGeneration = null;
    _deviceInactiveBoundaryAfterTerminalGeneration = null;
    _latestOwnDeviceInactiveBoundary = null;
    _terminalDeviceCycleFence = null;
    _pendingFreshPhysicalStartProof = null;
    _acceptedPhysicalStartPacketSignatures.clear();
    _lastOwnDeviceTerminalNativeReceiveSequence = null;
    _lastOwnDeviceTerminalNativeGeneration = null;
    _lastOwnDeviceTerminalReceiveSequenceDomain = null;
    _lastOwnDeviceTerminalProcessSessionId = null;
    _terminalBoundaryFromPreviousProcessGeneration = null;
    _terminalGenerationsEstablishedThisProcess.clear();
    _devicePacketSignaturesByGeneration.clear();
    _deviceMirrorDispatchedGenerations.clear();
    _clearPreSosSession(reason: 'session_cleared', emitIdleState: false);
    _clearPendingAppTriggeredSosBridge(reason: 'session_cleared');
    _clearDeviceRuntimeSosOwnership(reason: 'session_cleared');
    await _clearSosRuntimeForSessionChange();
    _emitPublicSosState(SosState.idle, source: 'clear_session');
    if (sessionContext != null) {
      sessionContext!.currentSession = null;
    }
    await sessionStore?.clear();
    await clearLocalUserData();
    _emitOperationalDiagnostics();
    await realtimeClient.disconnect();
  }

  bool _sameAuthenticatedPrincipal(EixamSession left, EixamSession right) {
    return left.appId == right.appId &&
        left.externalUserId == right.externalUserId &&
        left.sdkUserId == right.sdkUserId;
  }

  Future<void> _clearSosRuntimeForSessionChange() async {
    final repository = sosRepository;
    if (repository is SosRuntimeSessionIsolation) {
      await (repository as SosRuntimeSessionIsolation)
          .clearSosRuntimeForSessionChange();
    }
  }

  @override
  Future<void> enableBackgroundTelemetry({
    String? notificationTitle,
    String? notificationBody,
  }) async {
    if (_backgroundTrackingState == BackgroundTrackingState.starting ||
        (_backgroundTelemetryEnabled &&
            _backgroundTelemetryDiagnostics.serviceRunning)) {
      return;
    }
    _backgroundTrackingState = BackgroundTrackingState.starting;
    _emitOperationalDiagnostics(reason: 'background_telemetry_starting');
    _backgroundTelemetryEnabled = true;
    _backgroundTelemetryNotificationTitle =
        notificationTitle ?? notificationTexts.protectionActiveTitle;
    _backgroundTelemetryNotificationBody =
        notificationBody ?? notificationTexts.protectionActiveBody;
    await _reconcileBackgroundTelemetry(reason: 'enable_background_telemetry');
    await _confirmBackgroundTelemetryStart();
    _backgroundTrackingState = _deriveBackgroundTrackingState();
    _emitOperationalDiagnostics();
  }

  @override
  Future<void> disableBackgroundTelemetry() async {
    if (_backgroundTrackingState == BackgroundTrackingState.stopping) {
      return;
    }
    if (!_backgroundTelemetryEnabled &&
        !_backgroundTelemetryDiagnostics.enabled &&
        !_backgroundTelemetryDiagnostics.serviceRunning) {
      _backgroundTrackingState = BackgroundTrackingState.stopped;
      return;
    }
    _backgroundTrackingState = BackgroundTrackingState.stopping;
    _emitOperationalDiagnostics(reason: 'background_telemetry_stopping');
    _backgroundTelemetryEnabled = false;
    await _stopBackgroundTelemetry(reason: 'disable_background_telemetry');
    _operationalTelemetryCoordinator.setIntervalPublishingEnabled(true);
    _backgroundTrackingState = _deriveBackgroundTrackingState();
    _emitOperationalDiagnostics();
  }

  @override
  Future<LocationPermissionSnapshot> getLocationPermissionSnapshot() {
    return backgroundLocationPlatformAdapter.getLocationPermissionSnapshot();
  }

  @override
  Future<LocationPermissionSnapshot> requestLocationWhenInUsePermission() {
    return backgroundLocationPlatformAdapter
        .requestLocationWhenInUsePermission();
  }

  @override
  Future<LocationPermissionSnapshot> requestLocationAlwaysPermission() {
    return backgroundLocationPlatformAdapter.requestLocationAlwaysPermission();
  }

  @override
  Future<BackgroundLocationRuntimeStatus> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  }) {
    return backgroundLocationPlatformAdapter.setBackgroundLocationContext(
      context,
      active: active,
    );
  }

  @override
  Future<BackgroundLocationRuntimeStatus> getBackgroundLocationStatus() {
    return backgroundLocationPlatformAdapter.getBackgroundLocationStatus();
  }

  @override
  Stream<BackgroundLocationRuntimeStatus> watchBackgroundLocationStatus() {
    return backgroundLocationPlatformAdapter.watchBackgroundLocationStatus();
  }

  Future<SosRuntimeRehydrationResult?> _rehydrateSosRuntimeState({
    String trigger = 'startup',
    bool emitPublicState = false,
    SosState? terminalHint,
    SosLifecycleSnapshot? expectedLifecycle,
  }) async {
    final inFlight = _sosRuntimeRehydrationInFlight;
    if (inFlight != null) {
      final inFlightExpectsTerminal =
          _sosRuntimeRehydrationInFlightExpectsTerminal;
      final result = await inFlight;
      if (terminalHint == null || inFlightExpectsTerminal || _disposed) {
        return result;
      }
      final expected = expectedLifecycle;
      if (expected != null &&
          !_sameSosGeneration(_sosLifecycle.current, expected)) {
        return result;
      }
      return _rehydrateSosRuntimeState(
        trigger: trigger,
        emitPublicState: emitPublicState,
        terminalHint: terminalHint,
        expectedLifecycle: expectedLifecycle,
      );
    }
    final operation = _performSosRuntimeRehydration(
      trigger: trigger,
      emitPublicState: emitPublicState,
      terminalHint: terminalHint,
      expectedLifecycle: expectedLifecycle,
    );
    _sosRuntimeRehydrationInFlight = operation;
    _sosRuntimeRehydrationInFlightExpectsTerminal = terminalHint != null;
    try {
      final result = await operation;
      _scheduleForegroundSosReconciliationIfNeeded();
      return result;
    } finally {
      if (identical(_sosRuntimeRehydrationInFlight, operation)) {
        _sosRuntimeRehydrationInFlight = null;
        _sosRuntimeRehydrationInFlightExpectsTerminal = false;
      }
    }
  }

  Future<SosRuntimeRehydrationResult?> _performSosRuntimeRehydration({
    required String trigger,
    required bool emitPublicState,
    SosState? terminalHint,
    SosLifecycleSnapshot? expectedLifecycle,
  }) async {
    _lastSosRehydrationNote = null;

    if (_session == null) {
      return null;
    }

    if (sosRepository is! SosRuntimeRehydrationSupport) {
      return null;
    }
    final rehydrationRepository = sosRepository as SosRuntimeRehydrationSupport;
    final lifecycleBeforeLookup = expectedLifecycle ?? _sosLifecycle.current;
    if (expectedLifecycle != null &&
        !_sameSosGeneration(_sosLifecycle.current, expectedLifecycle)) {
      return null;
    }

    try {
      final result = await rehydrationRepository
          .rehydrateRuntimeStateFromBackend(
            terminalAbsenceExpected: terminalHint != null,
          );
      if (!_sameSosGeneration(_sosLifecycle.current, lifecycleBeforeLookup)) {
        _recordPublicSosGenerationProjection(
          action: 'ignore_stale_rehydration',
          reason: 'generation_changed_during_lookup',
        );
        return result;
      }
      _lastSosRehydrationNote = result.diagnosticNote;
      await _applySosRuntimeRehydrationResult(
        result,
        trigger: trigger,
        emitPublicState: emitPublicState,
        terminalHint: terminalHint,
        lifecycleBeforeLookup: lifecycleBeforeLookup,
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

  void _handleRejectedTerminalReconciliationRequest(
    SosRejectedTerminalReconciliationRequest request,
  ) {
    // MQTT remains non-authoritative here. The hint is consumed only by the
    // authenticated lookup's explicit absence result.
    unawaited(
      _rehydrateSosRuntimeState(
        trigger: 'mqtt_terminal_identity_unproven',
        emitPublicState: true,
        terminalHint: request.terminalState,
        expectedLifecycle: _sosLifecycle.current,
      ),
    );
  }

  bool _sameSosGeneration(
    SosLifecycleSnapshot current,
    SosLifecycleSnapshot expected,
  ) =>
      current.lifecycleId == expected.lifecycleId &&
      current.generation == expected.generation;

  void _scheduleForegroundSosReconciliationIfNeeded() {
    if (_disposed || !_sosLifecycle.current.isOpen) {
      _foregroundSosReconciliationTimer?.cancel();
      _foregroundSosReconciliationTimer = null;
      _foregroundSosReconciliationAttempt = 0;
      return;
    }
    if (_appLifecycleState != AppLifecycleState.resumed) {
      _foregroundSosReconciliationTimer?.cancel();
      _foregroundSosReconciliationTimer = null;
      return;
    }
    if (_foregroundSosReconciliationTimer != null) {
      return;
    }
    final exponent = _foregroundSosReconciliationAttempt.clamp(0, 2);
    final delaySeconds =
        _foregroundSosReconciliationInitialDelay.inSeconds << exponent;
    final delay = Duration(
      seconds: delaySeconds.clamp(
        _foregroundSosReconciliationInitialDelay.inSeconds,
        _foregroundSosReconciliationMaximumDelay.inSeconds,
      ),
    );
    _foregroundSosReconciliationAttempt++;
    BleDebugRegistry.instance.recordEvent(
      'SOS_FOREGROUND_RECONCILIATION_SCHEDULED '
      'delay_seconds=${delay.inSeconds} attempt=$_foregroundSosReconciliationAttempt',
    );
    _foregroundSosReconciliationTimer = Timer(delay, () {
      _foregroundSosReconciliationTimer = null;
      if (_disposed || !_sosLifecycle.current.isOpen) {
        return;
      }
      unawaited(
        _rehydrateSosRuntimeState(
          trigger: 'foreground_open_backoff',
          emitPublicState: true,
        ),
      );
    });
  }

  Future<void> _applySosRuntimeRehydrationResult(
    SosRuntimeRehydrationResult result, {
    required String trigger,
    required bool emitPublicState,
    SosState? terminalHint,
    SosLifecycleSnapshot? lifecycleBeforeLookup,
  }) async {
    BleDebugRegistry.instance.recordEvent(
      '[SOS_REHYDRATE] trigger=$trigger outcome=${result.outcome.name} '
      'state=${result.resultingState.name} '
      'note=${result.diagnosticNote ?? "-"}',
    );

    switch (result.outcome) {
      case SosRuntimeRehydrationOutcome.clearedToIdle:
        final repositoryState = await sosRepository.getSosState();
        if (_isOpenSosState(repositoryState)) {
          BleDebugRegistry.instance.recordEvent(
            '[SOS_REHYDRATE] action=ignore_superseded_absence '
            'trigger=$trigger backendState=${repositoryState.name} '
            'reason=newer_runtime_evidence',
          );
          return;
        }
        final restoredOpenIncident =
            _publicSosFallbackIncident ?? _lastKnownActiveSosIncident;
        if (_buildCurrentPreSosStatus() != null &&
            _publicSosClosureInFlight == null &&
            !_sosLifecycle.current.isTerminal &&
            (restoredOpenIncident == null ||
                !_isOpenSosState(restoredOpenIncident.state))) {
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
        final lifecycleStillOwned =
            lifecycleBeforeLookup == null ||
            _sameSosGeneration(_sosLifecycle.current, lifecycleBeforeLookup);
        if (!lifecycleStillOwned) {
          BleDebugRegistry.instance.recordEvent(
            'SOS_TERMINAL_RECONCILIATION_IGNORED reason=newer_lifecycle',
          );
          return;
        }
        if (_sosLifecycle.current.isOpen) {
          final lifecycle = _sosLifecycle.current;
          final backendIncidentId = lifecycle.backendIncidentId?.trim();
          final ownedIncident =
              lifecycle.incident ??
              restoredOpenIncident ??
              (backendIncidentId != null && backendIncidentId.isNotEmpty
                  ? SosIncident(
                      id: backendIncidentId,
                      state: _isOpenSosState(_publicSosState)
                          ? _publicSosState
                          : SosState.sent,
                      createdAt:
                          lifecycle.activationTimestamp ??
                          DateTime.now().toUtc(),
                      triggerSource: lifecycle.triggerSource,
                      deviceId: lifecycle.deviceId,
                      originatorNodeId: lifecycle.nodeId,
                      hardwareId: lifecycle.hardwareId,
                      isBackendConfirmed: true,
                    )
                  : null);
          final absenceCorrelatesToOwnedBackendIncident =
              ownedIncident != null &&
              ownedIncident.isBackendConfirmed &&
              backendIncidentId != null &&
              backendIncidentId.isNotEmpty &&
              ownedIncident.id == backendIncidentId;
          final absenceTerminalState = terminalHint ?? SosState.resolved;
          final terminalStage = absenceTerminalState == SosState.cancelled
              ? SosLifecycleStage.cancelled
              : SosLifecycleStage.resolved;
          final absenceAdmitted =
              ownedIncident != null &&
              (terminalHint != null || absenceCorrelatesToOwnedBackendIncident);
          BleDebugRegistry.instance.recordEvent(
            'SOS_BACKEND_EVENT_RX '
            'incidentId=${ownedIncident?.id ?? backendIncidentId ?? "none"} '
            'rawStatus=incident_null '
            'normalizedStatus=${absenceTerminalState.name} '
            'revision=none timestamp=${DateTime.now().toUtc().toIso8601String()} '
            'source=authenticated_active_sos_lookup payloadPresent=true',
          );
          BleDebugRegistry.instance.recordEvent(
            'SOS_BACKEND_EVENT_CORRELATION '
            'incidentId=${ownedIncident?.id ?? "none"} '
            'currentIncidentId=${backendIncidentId ?? "none"} '
            'generation=${lifecycle.generation} '
            'correlated=$absenceAdmitted '
            'reason=${absenceAdmitted ? "same_generation_backend_incident_absent" : "absence_identity_unproven"}',
          );
          BleDebugRegistry.instance.recordEvent(
            'SOS_BACKEND_EVENT_LIFECYCLE_DECISION '
            'rawStatus=incident_null '
            'normalizedStatus=${absenceTerminalState.name} '
            'previousLifecycle=${lifecycle.stage.name} '
            'requestedLifecycle=${terminalStage.name} admitted=$absenceAdmitted '
            'reason=${absenceAdmitted ? "authenticated_backend_absence" : "absence_identity_unproven"}',
          );
          if (absenceAdmitted) {
            final authoritativeTerminalIncident = ownedIncident.copyWith(
              state: absenceTerminalState,
              isBackendConfirmed: true,
              isUsingCachedData: false,
            );
            final handled = await _applyAuthoritativeTerminalTransition(
              terminalIncident: authoritativeTerminalIncident,
              source: 'authenticated_active_sos_lookup',
              incomingRawStatus: 'incident_null',
            );
            if (handled) {
              return;
            }
          }
        } else if (restoredOpenIncident != null &&
            _isOpenSosState(restoredOpenIncident.state)) {
          // Native-only restored evidence has no correlated backend incident,
          // so it requires no device mirror. It still needs a terminal fence
          // before the stale native ACTIVE projection is cleared.
          await _sosLifecycle.confirmTerminal(
            stage: terminalHint == SosState.cancelled
                ? SosLifecycleStage.cancelled
                : SosLifecycleStage.resolved,
            incident: restoredOpenIncident,
            emitToStream: false,
          );
          _sosLifecycle.publishCurrent();
        }
        if (emitPublicState || _publicSosState != SosState.idle) {
          _emitPublicSosState(SosState.idle, source: 'sos_rehydrate:$trigger');
        }
        await _clearPreSosSessionDurably(
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
        _clearAppOriginActiveSosBridge(
          reason: 'backend_rehydration_cleared_to_idle',
        );
        _clearAppOriginDeviceOwnershipContext(
          reason: 'backend_rehydration_cleared_to_idle',
        );
        _clearDeviceRuntimeSosOwnership(
          reason: 'backend_rehydration_cleared_to_idle',
        );
        BleDebugRegistry.instance.recordEvent(
          '[SOS_REHYDRATE] action=stale_countdown_discarded '
          'trigger=$trigger backendState=idle',
        );
        return;
      case SosRuntimeRehydrationOutcome.hydratedFromBackend:
        final state = result.resultingState;
        final incident = await sosRepository.getCurrentIncident();
        _PhysicalSosTerminationTarget? deviceClearProof;
        if (_isExternalOnlySosIncident(
          incident,
          source: 'sos_rehydrate:$trigger',
        )) {
          if (_isTerminalPublicSosState(state)) {
            final reason =
                'backend_rehydration_external_terminal:${state.name}';
            _clearPreSosSession(reason: reason, emitIdleState: false);
            if (deviceSosController.currentStatus.state ==
                DeviceSosState.preConfirm) {
              deviceSosController.clearPreSosLocally(reason: reason);
            }
          }
          _clearExternalOnlyPublicSosResidue(
            reason: 'backend_rehydration_external_only',
          );
          _clearAppOriginActiveSosBridge(
            reason: 'backend_rehydration_external_only',
          );
          _clearAppOriginDeviceOwnershipContext(
            reason: 'backend_rehydration_external_only',
          );
          if (emitPublicState || _publicSosState != SosState.idle) {
            _emitPublicSosState(
              SosState.idle,
              source: 'sos_rehydrate:$trigger:external_only',
            );
          }
          return;
        }
        if (_isTerminalPublicSosState(state)) {
          final lifecycle = _sosLifecycle.current;
          var terminalConfirmed = false;
          if (lifecycle.isOpen &&
              incident != null &&
              sosIncidentEvidenceMatchesLifecycle(lifecycle, incident)) {
            deviceClearProof = _captureCurrentPhysicalSosTarget(
              lifecycle: lifecycle,
              terminalIncident: incident,
            );
            await _sosLifecycle.confirmTerminal(
              stage: state == SosState.cancelled
                  ? SosLifecycleStage.cancelled
                  : SosLifecycleStage.resolved,
              incident: incident,
              deviceCycleKey: _deviceCycleKeyCorrelatedToLifecycle(
                lifecycle,
                incident: incident,
              ),
              emitToStream: false,
            );
            terminalConfirmed = true;
          }
          if (terminalConfirmed) {
            BleDebugRegistry.instance.recordEvent(
              'SOS_TERMINAL_CONFIRMED source=rest_reconciled_terminal '
              'terminal=${state.name}',
            );
            _sosLifecycle.publishCurrent();
            BleDebugRegistry.instance.recordEvent(
              'SOS_TERMINAL_HANDOFF source=rest_reconciled_terminal '
              'terminal=${state.name}',
            );
            BleDebugRegistry.instance.recordEvent(
              'SOS_TERMINAL_LIFECYCLE_PUBLISHED terminal=${state.name}',
            );
          }
          if (!terminalConfirmed &&
              _hasNewAuthoritativeGenerationSinceTerminal()) {
            BleDebugRegistry.instance.recordEvent(
              'SOS_STALE_TERMINAL_IGNORED_FOR_NEW_GENERATION '
              'terminalGeneration=${_sosLifecycle.activeTerminalWatermark?.generation ?? 0} '
              'activeGeneration=${lifecycle.generation} '
              'reason=rehydration_identity_mismatch',
            );
            return;
          }
          _applyTerminalSosSuppression(
            reason: 'backend_terminal_state:${state.name}',
            terminalState: state,
          );
          if (emitPublicState || _publicSosState != state) {
            _emitPublicSosState(state, source: 'sos_rehydrate:$trigger');
          }
          await _clearPreSosSessionDurably(
            reason: 'backend_rehydration_terminal:${state.name}',
            emitIdleState: false,
          );
          _clearAppOriginActiveSosBridge(
            reason: 'backend_rehydration_terminal:${state.name}',
          );
          _clearAppOriginDeviceOwnershipContext(
            reason: 'backend_rehydration_terminal:${state.name}',
          );
          _clearPendingAppTriggeredSosBridge(
            reason: 'backend_rehydration_terminal:${state.name}',
          );
          _clearDeviceRuntimeSosOwnership(
            reason: 'backend_rehydration_terminal:${state.name}',
          );
        } else if (_isOpenSosState(state)) {
          _clearPreSosSession(
            reason: 'backend_rehydration_open:${state.name}',
            emitIdleState: false,
          );
        }
        if (!_isTerminalPublicSosState(state) &&
            (emitPublicState || _publicSosState != state)) {
          _emitPublicSosState(state, source: 'sos_rehydrate:$trigger');
        }
        _scheduleRemoteTerminalDeviceClear(deviceClearProof);
        return;
      case SosRuntimeRehydrationOutcome.keptLocalFallback:
        final repositoryState = await sosRepository.getSosState();
        final repositoryIncident = await sosRepository.getCurrentIncident();
        final lifecycle = _sosLifecycle.current;
        if (_isTerminalPublicSosState(repositoryState) &&
            repositoryIncident != null &&
            lifecycle.isOpen &&
            sosIncidentEvidenceMatchesLifecycle(
              lifecycle,
              repositoryIncident,
            )) {
          final deviceClearProof = _captureCurrentPhysicalSosTarget(
            lifecycle: lifecycle,
            terminalIncident: repositoryIncident,
          );
          await _sosLifecycle.confirmTerminal(
            stage: repositoryState == SosState.cancelled
                ? SosLifecycleStage.cancelled
                : SosLifecycleStage.resolved,
            incident: repositoryIncident,
            deviceCycleKey: _deviceCycleKeyCorrelatedToLifecycle(
              lifecycle,
              incident: repositoryIncident,
            ),
            emitToStream: false,
          );
          BleDebugRegistry.instance.recordEvent(
            'SOS_TERMINAL_CONFIRMED source=rest_reconciled_terminal '
            'terminal=${repositoryState.name}',
          );
          _sosLifecycle.publishCurrent();
          BleDebugRegistry.instance.recordEvent(
            'SOS_TERMINAL_HANDOFF source=rest_reconciled_terminal '
            'terminal=${repositoryState.name}',
          );
          BleDebugRegistry.instance.recordEvent(
            'SOS_TERMINAL_LIFECYCLE_PUBLISHED '
            'terminal=${repositoryState.name}',
          );
          if (emitPublicState || _publicSosState != repositoryState) {
            _emitPublicSosState(
              repositoryState,
              source: 'sos_rehydrate:$trigger:restored_terminal',
            );
          }
          await _clearPreSosSessionDurably(
            reason: 'restored_repository_terminal:${repositoryState.name}',
            emitIdleState: false,
          );
          _clearPendingAppTriggeredSosBridge(
            reason: 'restored_repository_terminal:${repositoryState.name}',
          );
          _clearAppOriginActiveSosBridge(
            reason: 'restored_repository_terminal:${repositoryState.name}',
          );
          _clearAppOriginDeviceOwnershipContext(
            reason: 'restored_repository_terminal:${repositoryState.name}',
          );
          _clearDeviceRuntimeSosOwnership(
            reason: 'restored_repository_terminal:${repositoryState.name}',
          );
          _scheduleRemoteTerminalDeviceClear(deviceClearProof);
        }
        return;
    }
  }

  @override
  Future<EixamSession?> getCurrentSession() async => _session;

  Future<void> _reconcileBackgroundTelemetry({required String reason}) async {
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
      await _flushNativeBackgroundTelemetryQueue(
        reason: 'reconcile_existing:$reason',
      );
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
      await _flushNativeBackgroundTelemetryQueue(
        reason: 'background_telemetry_started:$reason',
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

  Future<void> _updateBackgroundTelemetryState({required String reason}) async {
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
      await _flushNativeBackgroundTelemetryQueue(
        reason: 'background_telemetry_updated:$reason',
      );
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

  Future<void> _flushNativeBackgroundTelemetryQueue({
    required String reason,
  }) async {
    if (_nativeBackgroundTelemetryFlushInFlight) {
      return;
    }
    _nativeBackgroundTelemetryFlushInFlight = true;
    try {
      final pending = await backgroundTelemetryPlatformAdapter
          .peekQueuedBackgroundTelemetry(limit: 25);
      if (pending.isEmpty) {
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'TELEMETRY_NATIVE_MQTT_FLUSH_START reason=$reason '
        'count=${pending.length}',
      );
      for (final item in pending) {
        try {
          await telemetryRepository.publishTelemetry(
            await _enrichOperationalTelemetryPayload(item.payload),
          );
          await backgroundTelemetryPlatformAdapter.ackQueuedBackgroundTelemetry(
            item.signature,
          );
          BleDebugRegistry.instance.recordEvent(
            'TELEMETRY_NATIVE_QUEUE_ACKED handoffId=${item.signature}',
          );
        } catch (error) {
          await backgroundTelemetryPlatformAdapter
              .markQueuedBackgroundTelemetryFlushFailed(
                item.signature,
                error: _compactDiagnosticValue(error),
              );
          BleDebugRegistry.instance.recordEvent(
            'TELEMETRY_NATIVE_MQTT_FLUSH_RESULT success=false '
            'handoffId=${item.signature} error=${_compactDiagnosticValue(error)}',
          );
          return;
        }
      }
      BleDebugRegistry.instance.recordEvent(
        'TELEMETRY_NATIVE_MQTT_FLUSH_RESULT success=true '
        'count=${pending.length}',
      );
    } finally {
      _nativeBackgroundTelemetryFlushInFlight = false;
      await _refreshBackgroundTelemetryDiagnostics();
    }
  }

  Future<void> _stopBackgroundTelemetry({required String reason}) async {
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
      if (!_backgroundTelemetryDiagnostics.enabled) {
        _backgroundTelemetryEnabled = false;
        _backgroundTelemetryStarted = false;
        _backgroundTelemetryStartFingerprint = null;
      } else {
        _backgroundTelemetryEnabled = true;
        _backgroundTelemetryStarted =
            _backgroundTelemetryDiagnostics.serviceRunning;
      }
      if (_backgroundTrackingState != BackgroundTrackingState.starting &&
          _backgroundTrackingState != BackgroundTrackingState.stopping) {
        _backgroundTrackingState = _deriveBackgroundTrackingState();
      }
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

  Future<void> _confirmBackgroundTelemetryStart() async {
    for (
      var attempt = 0;
      attempt < _backgroundTelemetryStartConfirmationAttempts;
      attempt++
    ) {
      await _refreshBackgroundTelemetryDiagnostics();
      final diagnostics = _backgroundTelemetryDiagnostics;
      final permission = diagnostics.permissionStatus.toLowerCase();
      if (diagnostics.serviceRunning ||
          !diagnostics.enabled ||
          diagnostics.lastTelemetryError != null ||
          permission.contains('missing') ||
          permission.contains('denied') ||
          permission.contains('blocked')) {
        return;
      }
      await Future<void>.delayed(_backgroundTelemetryStartConfirmationInterval);
    }
  }

  Future<void> _reconcileBackgroundTrackingFromNative({
    required String reason,
  }) async {
    await _refreshBackgroundTelemetryDiagnostics();
    _backgroundTrackingState = _deriveBackgroundTrackingState();
    _operationalTelemetryCoordinator.setIntervalPublishingEnabled(true);
    _emitOperationalDiagnostics(reason: reason);
  }

  BackgroundTrackingState _deriveBackgroundTrackingState() {
    final diagnostics = _backgroundTelemetryDiagnostics;
    final permission = diagnostics.permissionStatus.toLowerCase();
    if (permission.contains('missing') ||
        permission.contains('denied') ||
        permission.contains('blocked')) {
      return BackgroundTrackingState.permissionBlocked;
    }
    if (diagnostics.enabled && diagnostics.serviceRunning) {
      return _appLifecycleState == AppLifecycleState.resumed
          ? BackgroundTrackingState.activeForeground
          : BackgroundTrackingState.activeBackground;
    }
    if (!diagnostics.enabled && !diagnostics.serviceRunning) {
      return BackgroundTrackingState.stopped;
    }
    if (diagnostics.lastTelemetryError != null) {
      return BackgroundTrackingState.error;
    }
    return BackgroundTrackingState.serviceUnavailable;
  }

  bool _isOpenSosState(SosState state) {
    return switch (state) {
      SosState.arming ||
      SosState.triggerRequested ||
      SosState.triggeredLocal ||
      SosState.sending ||
      SosState.sent ||
      SosState.acknowledged ||
      SosState.cancelRequested => true,
      SosState.idle ||
      SosState.cancelled ||
      SosState.resolved ||
      SosState.failed => false,
    };
  }

  SosState _promotePostTriggerSosState(SosState state) {
    return switch (state) {
      SosState.idle ||
      SosState.arming ||
      SosState.triggerRequested ||
      SosState.triggeredLocal ||
      SosState.sending => SosState.sent,
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
  Future<List<EixamBleScanResult>> scanBleDevices({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final scans = await BleDebugRegistry.instance.startScan();
    return scans.map(_toPublicBleScanResult).toList(growable: false);
  }

  @override
  Future<DeviceMigrationCandidate> inspectDeviceMigrationCandidate({
    required String deviceId,
    String? advertisedName,
  }) async {
    final identityMarker = SecurityDiagnosticsRedactor.stableIdentifierMarker(
      deviceId,
    );
    safeSdkDebugPrint(
      'MIGRATION_INSPECTION_SELECTED brand=meshtastic '
      'selectedMarker=$identityMarker '
      'selectedNamePresent=${advertisedName?.trim().isNotEmpty == true}',
    );
    final coordinator = deviceMigrationCoordinator;
    if (coordinator == null) {
      return DeviceMigrationCandidate(
        deviceId: deviceId,
        advertisedName: advertisedName,
        compatibility: DeviceMigrationCompatibility.unableToVerify,
        identityKind: DeviceMigrationIdentityKind.none,
        detailCode: 'migrationUnavailable',
        inspectedAt: DateTime.now(),
      );
    }
    if (_migrationInspectionInProgress) {
      return DeviceMigrationCandidate(
        deviceId: deviceId,
        advertisedName: advertisedName,
        compatibility: DeviceMigrationCompatibility.unableToVerify,
        identityKind: DeviceMigrationIdentityKind.none,
        detailCode: 'candidateInspectionInProgress',
        inspectedAt: DateTime.now(),
      );
    }

    _migrationInspectionInProgress = true;
    try {
      return await _bleAutoReconnectCoordinator
          .runWithCandidateInspectionPriority<DeviceMigrationCandidate>(
            reason: 'explicit_migration_candidate_inspection',
            selectedMarker: identityMarker,
            operation: () async {
              var ownershipReleaseAttempted = false;
              try {
                final repository = deviceRepository;
                if (repository is InMemoryDeviceRepository) {
                  ownershipReleaseAttempted = true;
                  _lastDeviceStatus = await repository
                      .releaseBleOwnershipToProtectionMode(
                        reason: 'explicit_migration_candidate_inspection',
                      );
                }
                return await coordinator.inspect(
                  deviceId: deviceId,
                  advertisedName: advertisedName,
                );
              } finally {
                final repository = deviceRepository;
                if (ownershipReleaseAttempted &&
                    repository is InMemoryDeviceRepository) {
                  _lastDeviceStatus = await repository
                      .reclaimBleOwnershipFromProtectionMode(
                        reason:
                            'explicit_migration_candidate_inspection_complete',
                      );
                }
              }
            },
          );
    } finally {
      _migrationInspectionInProgress = false;
    }
  }

  @override
  Future<DeviceMigrationResult> migrateDeviceToEixam({
    required DeviceMigrationCandidate candidate,
  }) async {
    final coordinator = deviceMigrationCoordinator;
    if (coordinator == null) {
      return DeviceMigrationResult(
        outcome: DeviceMigrationOutcome.blocked,
        candidate: candidate,
        failureCode: 'migrationUnavailable',
      );
    }
    await _devicePositionBacklogCoordinator.cancel();
    _firmwareOtaInProgress = true;
    try {
      return await coordinator.migrate(candidate);
    } finally {
      _firmwareOtaInProgress = false;
    }
  }

  @override
  Future<EixamBleDiagnostics> getBleDiagnostics() async {
    return _toPublicBleDiagnostics(BleDebugRegistry.instance.currentState);
  }

  @override
  Stream<EixamBleDiagnostics> watchBleDiagnostics() {
    return _seedThenReplayLiveStream<EixamBleDiagnostics>(
      seed: () =>
          _toPublicBleDiagnostics(BleDebugRegistry.instance.currentState),
      live: BleDebugRegistry.instance.watch().map(_toPublicBleDiagnostics),
    );
  }

  @override
  Future<BleCommandChannelStatus> getDeviceCommandChannelStatus() async {
    return _toPublicCommandChannelStatus(
      BleDebugRegistry.instance.currentState,
    );
  }

  @override
  Stream<BleCommandChannelStatus> watchDeviceCommandChannelStatus() {
    bool sameStatus(
      BleCommandChannelStatus previous,
      BleCommandChannelStatus next,
    ) {
      return previous.readiness == next.readiness &&
          previous.hasSelectedDevice == next.hasSelectedDevice &&
          previous.serviceConnected == next.serviceConnected &&
          previous.commandWriterReady == next.commandWriterReady;
    }

    return _seedThenReplayLiveStream<BleCommandChannelStatus>(
      seed: () =>
          _toPublicCommandChannelStatus(BleDebugRegistry.instance.currentState),
      live: BleDebugRegistry.instance
          .watch()
          .map(_toPublicCommandChannelStatus)
          .distinct(sameStatus),
      equals: sameStatus,
    );
  }

  EixamBleDiagnostics _toPublicBleDiagnostics(BleDebugState state) {
    return EixamBleDiagnostics(
      adapterState: state.adapterState.name,
      isScanning: state.isScanning,
      hasSelectedDevice: state.selectedDeviceId != null,
      eixamServiceDetected: state.eixamServiceFound,
      commandChannelStatus: _toPublicCommandChannelStatus(state),
    );
  }

  BleCommandChannelStatus _toPublicCommandChannelStatus(BleDebugState state) {
    return BleCommandChannelStatus(
      readiness: state.cmdFound
          ? BleCommandChannelReadiness.ready
          : BleCommandChannelReadiness.unavailable,
      hasSelectedDevice: state.selectedDeviceId != null,
      serviceConnected: state.eixamServiceFound,
      commandWriterReady: state.commandWriterReady,
    );
  }

  EixamBleScanResult _toPublicBleScanResult(BleScanResult scan) {
    return scan.toPublic();
  }

  @override
  Future<PreferredDevice?> get preferredDevice {
    return preferredBleDeviceStore.getPreferredDevice();
  }

  @override
  Stream<DeviceStatus> get deviceStatusStream => watchDeviceStatus();

  @override
  Future<DeviceReadyResult> ensureDeviceReady() async {
    await _devicePositionBacklogCoordinator.cancel();
    final coordinator = _deviceProvisioningCoordinator ??=
        _buildDeviceProvisioningCoordinator();
    if (coordinator == null) {
      return const DeviceReadyResult.failed(
        DeviceReadyFailure(
          code: DeviceReadyFailureCode.configurationUnavailable,
          retryable: false,
        ),
      );
    }
    final result = await coordinator.ensureReady();
    _recoverBleAfterProvisioningRebootFailure(result.failure?.code);
    unawaited(_maybeCheckDeviceCountryConfig('provisioning_settled'));
    return result;
  }

  @override
  Stream<DeviceProvisioningState> watchDeviceProvisioningState() async* {
    final coordinator = _deviceProvisioningCoordinator ??=
        _buildDeviceProvisioningCoordinator();
    if (coordinator == null) {
      yield const DeviceProvisioningState(
        phase: DeviceProvisioningPhase.failed,
        failure: DeviceReadyFailure(
          code: DeviceReadyFailureCode.configurationUnavailable,
          retryable: false,
        ),
      );
      return;
    }
    yield* coordinator.watchState();
  }

  @override
  Future<DeviceUnprovisionResult> unprovisionDevice() async {
    await _devicePositionBacklogCoordinator.cancel();
    final hold = await _deviceCountryConfigSafetyHold();
    if (hold != null) {
      final firmwareHold = hold == 'firmwareUpdateInProgress';
      return DeviceUnprovisionResult.failed(
        DeviceUnprovisionFailure(
          code: firmwareHold
              ? DeviceUnprovisionFailureCode.busy
              : DeviceUnprovisionFailureCode.safetyActive,
          retryable: true,
        ),
      );
    }
    final coordinator = _deviceProvisioningCoordinator ??=
        _buildDeviceProvisioningCoordinator();
    if (coordinator == null) {
      return const DeviceUnprovisionResult.failed(
        DeviceUnprovisionFailure(
          code: DeviceUnprovisionFailureCode.internal,
          retryable: false,
        ),
      );
    }
    final result = await coordinator.unprovision();
    _recoverBleAfterProvisioningRebootFailure(result.failure?.code);
    unawaited(_maybeCheckDeviceCountryConfig('unprovision_settled'));
    return result;
  }

  DeviceProvisioningCoordinator? _buildDeviceProvisioningCoordinator() {
    final pskSource = networkPskRemoteDataSource;
    final configSource = provisioningConfigSource;
    final apiBaseUrl = provisioningBackendUrl;
    final geoSource = geoCountryRemoteDataSource;
    if (pskSource == null ||
        configSource == null ||
        apiBaseUrl == null ||
        geoSource == null) {
      return null;
    }
    return DeviceProvisioningCoordinator(
      statusProvider: refreshDeviceStatus,
      liveStatusProvider: () async {
        final repository = deviceRepository;
        if (repository is! InMemoryDeviceRepository) {
          throw const DeviceException(
            'E_DEVICE_LIVE_FIRMWARE_UNAVAILABLE',
            'E_DEVICE_LIVE_FIRMWARE_UNAVAILABLE',
          );
        }
        return repository.refreshDeviceStatusForFirmwareValidation(
          reason: 'device_provisioning_live_firmware_gate',
        );
      },
      runtimeStatusProvider: getDeviceRuntimeStatus,
      countryIsoProvider: () async {
        final location = await _resolveLocation(
          useCase: SdkResolvedLocationUseCase.emergencyBackend,
        );
        if (location == null) {
          throw const ProvisioningContractException(
            DeviceReadyFailureDetail.countryLocationUnavailable,
          );
        }
        final country = await geoSource.resolveCountry(
          latitude: location.latitude,
          longitude: location.longitude,
        );
        return country.countryIso;
      },
      pskSource: pskSource,
      configSource: configSource,
      assignmentVerifier: RegisteredDeviceAssignmentVerifier(
        repository: deviceRegistryRepository,
        onAssignmentVerified: _rememberVerifiedDeviceAssignment,
      ),
      assignmentCreator: RegisteredDeviceAssignmentCreator(
        repository: deviceRegistryRepository,
      ),
      backendUrl: apiBaseUrl,
      writeCommand: _sendDeviceCommandThroughActiveOwner,
      incomingPackets: bleIncomingEvents.map((event) => event.payload),
      deviceStatusChanges: deviceRepository.watchDeviceStatus(),
      reboot: _rebootDeviceAndAwaitExpectedDisconnect,
      reconnectSameDevice: _reconnectProvisionedDevice,
      acquireReconnectOwnership:
          _bleAutoReconnectCoordinator.acquireProvisioningReconnectOwnership,
      releaseReconnectOwnership:
          _bleAutoReconnectCoordinator.releaseProvisioningReconnectOwnership,
      diagnosticLog: BleDebugRegistry.instance.recordEvent,
      // Greenfield provisioning has one canonical certified firmware baseline.
      // Devices outside this contract update firmware before mutating writes.
      firmwarePolicy: const ProvisioningFirmwarePolicy.current(),
    );
  }

  void _recoverBleAfterProvisioningRebootFailure(Enum? failureCode) {
    if (failureCode != DeviceReadyFailureCode.rebootFailed &&
        failureCode != DeviceReadyFailureCode.reconnectFailed &&
        failureCode != DeviceUnprovisionFailureCode.rebootFailed &&
        failureCode != DeviceUnprovisionFailureCode.reconnectFailed) {
      return;
    }
    if (_lastDeviceStatus?.connected == true) {
      return;
    }
    unawaited(
      _bleAutoReconnectCoordinator.tryAutoConnect(
        trigger: 'provisioning_reboot_boundary_failed',
      ),
    );
  }

  Future<void> _rebootDeviceAndAwaitExpectedDisconnect() async {
    await const ProvisioningRebootDisconnectPolicy().writeAndAwait(
      writeReboot: rebootDevice,
      statuses: deviceRepository.watchDeviceStatus(),
      alreadyDisconnected: () => _lastDeviceStatus?.connected == false,
      diagnosticLog: BleDebugRegistry.instance.recordEvent,
    );
  }

  Future<bool> _reconnectProvisionedDevice(String platformDeviceId) async {
    final already = _lastDeviceStatus;
    if (already != null &&
        already.connected &&
        already.deviceId == platformDeviceId) {
      return true;
    }
    final result = await _bleAutoReconnectCoordinator
        .reconnectForProvisioningReboot(platformRemoteId: platformDeviceId);
    if (result.connected) {
      return true;
    }
    if (!result.reconnecting) {
      return false;
    }
    try {
      final status = await deviceRepository
          .watchDeviceStatus()
          .firstWhere((candidate) => candidate.connected)
          .timeout(const Duration(seconds: 45));
      return status.deviceId == platformDeviceId;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<PreferredDeviceReconnectResult> bootstrapPreferredDeviceReconnect({
    String reason = 'startup',
    String? attemptId,
    String? platformRemoteId,
  }) async {
    BleDebugRegistry.instance.recordEvent(
      'EIXAM_RECONNECT_TRACE sdk_bootstrap_called '
      'source=$reason alreadyInFlight=unknown connectedKnown=unknown',
    );
    if (await _nativeProtectionOwnsBleAfterRehydrate()) {
      unawaited(
        _delegateBleToNativeProtection(reason: 'startup_native_ble_owner'),
      );
      return const PreferredDeviceReconnectResult.reconnecting(
        reason: 'native_protection_ble_owner',
      );
    }
    return _bleAutoReconnectCoordinator.tryAutoConnectForHandoff(
      trigger: reason,
      attemptId: attemptId,
      platformRemoteId: platformRemoteId,
    );
  }

  @override
  Future<void> startPreferredDeviceReconnectMonitor({
    String reason = 'ble_ready',
  }) {
    BleDebugRegistry.instance.recordEvent(
      'EIXAM_RECONNECT_TRACE sdk_ble_ready_monitor_start source=$reason',
    );
    return _bleAutoReconnectCoordinator.startBleReadinessReconnectMonitor(
      trigger: reason,
    );
  }

  @override
  Future<void> stopPreferredDeviceReconnectMonitor() {
    BleDebugRegistry.instance.recordEvent(
      'EIXAM_RECONNECT_TRACE sdk_ble_ready_monitor_stop',
    );
    _bleAutoReconnectCoordinator.cancelPreferredReconnect(
      reason: 'monitor_stop',
    );
    return _bleAutoReconnectCoordinator.stopBleReadinessReconnectMonitor();
  }

  @override
  Future<PreferredDeviceReconnectResult> reconnectPreferredDevice({
    required String reason,
    String? attemptId,
    String? platformRemoteId,
  }) {
    return bootstrapPreferredDeviceReconnect(
      reason: reason,
      attemptId: attemptId,
      platformRemoteId: platformRemoteId,
    );
  }

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
  Future<DeviceFirmwareInfo> getFirmwareInfo({String? deviceId}) {
    return _firmwareUpdates().getFirmwareInfo(deviceId: deviceId);
  }

  @override
  Future<List<FirmwareRelease>> listFirmwareReleases({String? deviceId}) {
    return _firmwareUpdates().listFirmwareReleases(deviceId: deviceId);
  }

  @override
  Future<FirmwareUpdateCheck> checkFirmwareUpdate({
    String? deviceId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) {
    return _firmwareUpdates().checkFirmwareUpdate(
      deviceId: deviceId,
      policy: policy,
    );
  }

  @override
  Future<FirmwareUpdateSession> startFirmwareUpdate({
    required String deviceId,
    required String releaseId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) async {
    await _devicePositionBacklogCoordinator.cancel();
    _firmwareOtaInProgress = true;
    return _firmwareUpdates()
        .startFirmwareUpdate(
          deviceId: deviceId,
          releaseId: releaseId,
          policy: policy,
        )
        .whenComplete(() {
          _firmwareOtaInProgress = false;
        });
  }

  /// Re-flashes a device stranded in the DFU bootloader (recovery after an
  /// interrupted transfer). [bootloaderDeviceId] is the address the device
  /// advertises while in bootloader mode.
  Future<FirmwareUpdateSession> recoverFirmwareUpdate({
    required String bootloaderDeviceId,
    required String releaseId,
    String targetVersion = '',
  }) async {
    await _devicePositionBacklogCoordinator.cancel();
    _firmwareOtaInProgress = true;
    return _firmwareUpdates()
        .recoverFirmwareUpdate(
          bootloaderDeviceId: bootloaderDeviceId,
          releaseId: releaseId,
          targetVersion: targetVersion,
        )
        .whenComplete(() {
          _firmwareOtaInProgress = false;
        });
  }

  @override
  Stream<FirmwareUpdateProgress> watchFirmwareUpdateProgress({
    String? deviceId,
  }) {
    return _firmwareUpdates().watchProgress(deviceId: deviceId);
  }

  @override
  Future<void> cancelFirmwareUpdate(String sessionId) {
    return _firmwareUpdates().cancelFirmwareUpdate(sessionId);
  }

  FirmwareUpdateCoordinator _firmwareUpdates() {
    final coordinator = firmwareUpdateCoordinator;
    if (coordinator == null) {
      throw const FirmwareUpdateException(
        'E_FIRMWARE_OTA_UNAVAILABLE',
        'Firmware OTA is not configured for this SDK instance.',
      );
    }
    return coordinator;
  }

  Future<DeviceStatus> prepareForFirmwareDfuTransfer({
    required String deviceId,
  }) async {
    final protection = await _protectionModeController.getStatus();
    if (_isFirmwareOtaProtectionOwnershipBlock(protection)) {
      BleDebugRegistry.instance.recordEvent(
        'OTA_COORDINATOR protection_exit_requested deviceId=$deviceId',
      );
      await _protectionModeController.exit();
    }
    _bleAutoReconnectCoordinator.setAppForeground(true);
    var status = await _refreshFirmwareDfuPreparationStatus(
      deviceId: deviceId,
      attempt: 0,
    );
    const maxAttempts = 5;
    const retryDelay = Duration(seconds: 2);
    for (
      var attempt = 1;
      !_isFirmwareDfuPreTransferStatusReady(status) && attempt <= maxAttempts;
      attempt++
    ) {
      await Future<void>.delayed(retryDelay);
      status = await _refreshFirmwareDfuPreparationStatus(
        deviceId: deviceId,
        attempt: attempt,
      );
    }
    return status;
  }

  Future<void> releaseBleForFirmwareDfuTransfer({
    required String deviceId,
  }) async {
    // Suspend ALL auto-reconnect paths for the DFU window. The foreground flag
    // alone is not enough: an activity bounce (bonding dialog, notification)
    // restores it mid-transfer and the resulting reconnect races the native
    // DFU library for the device. Awaited so any in-flight connect settles
    // BEFORE the ownership handoff below, which then tears down whatever it
    // established.
    await _bleAutoReconnectCoordinator.suspendForDfuTransfer(
      reason: 'firmware_dfu_transfer',
    );
    _bleAutoReconnectCoordinator.setAppForeground(false);
    final repository = deviceRepository;
    if (repository is InMemoryDeviceRepository) {
      _lastDeviceStatus = await repository.releaseBleOwnershipToProtectionMode(
        reason: 'firmware_ota_dfu_transfer',
      );
    }
  }

  Future<void> restoreBleAfterFirmwareDfuTransfer({
    required String deviceId,
  }) async {
    // Lift the auto-reconnect suppression FIRST and in a finally: if the BLE
    // ownership reclaim below throws, the suppression must still be cleared —
    // otherwise _dfuTransferSuppressed stays set and every future reconnect is
    // blocked until the app is killed. (The release side suspends before doing
    // its own repository work for the same reason.)
    try {
      final repository = deviceRepository;
      if (repository is InMemoryDeviceRepository) {
        _lastDeviceStatus = await repository
            .reclaimBleOwnershipFromProtectionMode(
              reason: 'firmware_ota_dfu_transfer_complete',
            );
      }
    } finally {
      _bleAutoReconnectCoordinator.resumeAfterDfuTransfer(
        reason: 'firmware_dfu_transfer_complete',
      );
      _bleAutoReconnectCoordinator.setAppForeground(true);
    }
    await _bleAutoReconnectCoordinator.tryAutoConnectOnResume();
  }

  Future<DeviceStatus> refreshFirmwareDfuInstalledVersionStatus({
    required String deviceId,
    required int attempt,
    required String targetVersion,
  }) async {
    await _bleAutoReconnectCoordinator.tryAutoConnectOnResume();
    final repository = deviceRepository;
    final status = repository is InMemoryDeviceRepository
        ? await repository.refreshDeviceStatusForFirmwareValidation(
            reason: 'firmware_ota_post_dfu_verify',
          )
        : await repository.refreshDeviceStatus();
    _lastDeviceStatus = status;
    return status;
  }

  bool _isFirmwareOtaProtectionOwnershipBlock(ProtectionStatus status) {
    return status.modeState != ProtectionModeState.off ||
        status.runtimeState == ProtectionRuntimeState.starting ||
        status.runtimeState == ProtectionRuntimeState.active ||
        status.runtimeState == ProtectionRuntimeState.recovering ||
        status.bleOwner != ProtectionBleOwner.flutter;
  }

  Future<DeviceStatus> _refreshFirmwareDfuPreparationStatus({
    required String deviceId,
    required int attempt,
  }) async {
    await _bleAutoReconnectCoordinator.tryAutoConnectOnResume();
    final status = await _cacheDeviceStatus(
      deviceRepository.refreshDeviceStatus(),
      reason: 'firmware_ota_prepare_dfu',
    );
    return status;
  }

  bool _isFirmwareDfuPreTransferStatusReady(DeviceStatus status) {
    final firmware = status.firmwareVersion?.trim();
    final model = status.model?.trim();
    return status.connected &&
        status.approximateBatteryPercentage != null &&
        firmware != null &&
        firmware.isNotEmpty &&
        model != null &&
        model.isNotEmpty;
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
    final unpairedStatus = currentStatus ?? _lastDeviceStatus;
    if (unpairedStatus != null) {
      await deviceConfigStore?.clear(
        DeviceCountryConfigController.deviceKeyFor(unpairedStatus),
      );
    }
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
    BleDebugRegistry.instance.selectDevice(pairingCode);
    return _cacheDeviceStatus(
      _bleAutoReconnectCoordinator.pairDeviceManually(pairingCode: pairingCode),
      reason: 'pair_device',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    switch (state) {
      case AppLifecycleState.resumed:
        _bleAutoReconnectCoordinator.setAppForeground(true);
        unawaited(_rehydrateSosStateOnAppResume());
        if (_isProtectionPlatformOwningBle) {
          unawaited(_protectionModeController.rehydrate());
          unawaited(
            _flushPendingExternalRelayCancelsFromProtectionPlatform(
              trigger: 'app_foreground_resume',
            ),
          );
        }
        unawaited(_bleAutoReconnectCoordinator.tryAutoConnectOnResume());
        unawaited(
          _flushNativeBackgroundTelemetryQueue(reason: 'app_foreground_resume'),
        );
        unawaited(
          _maybeCheckDeviceCountryConfig('app_foreground_resume', resume: true),
        );
        unawaited(
          _reconcileBackgroundTrackingFromNative(
            reason: 'app_foreground_resume',
          ),
        );
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Focus loss and surface recreation, not a real background. Android
        // cold start fires these around splash/Vulkan surface teardown and
        // while a BLE bond or permission dialog is up. Treating them as
        // background aborts the preferred-reconnect campaign as
        // app_not_foreground (not retryable) while the user is still on
        // Home looking at a paired device that never comes back.
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _bleAutoReconnectCoordinator.setAppForeground(false);
        _scheduleForegroundSosReconciliationIfNeeded();
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
  Stream<DeviceStatus> watchDeviceStatus() {
    return _seedThenReplayLiveStream<DeviceStatus>(
      seed: () async {
        final current =
            _lastDeviceStatus ?? await deviceRepository.getDeviceStatus();
        _lastDeviceStatus = current;
        return _publishPublicDeviceStatus(
          rawStatus: current,
          reason: 'watch_device_status_initial',
          emit: false,
        );
      },
      live: _publicDeviceStatusController.stream,
      equals: (previous, next) =>
          !_hasEffectivePublicDeviceStatusChange(previous, next),
    );
  }

  @override
  Future<DeviceSosStatus> getDeviceSosStatus() {
    return deviceSosController.getStatus();
  }

  @override
  Stream<DeviceSosStatus> watchDeviceSosStatus() {
    return _seedThenReplayLiveStream<DeviceSosStatus>(
      seed: deviceSosController.getStatus,
      live: deviceSosController.watchStatus(),
    );
  }

  @override
  Future<DeviceSosStatus> triggerDeviceSos() {
    return deviceSosController.triggerSos(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  Future<DeviceSosStatus> _activateActiveSosOnDeviceFromApp() {
    if (_isAuthoritativeNativeProtectionBleOwner) {
      return _activateActiveSosOnNativeOwnerFromApp();
    }
    return deviceSosController.activateSosFromApp(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
  }

  Future<DeviceSosStatus> _activateActiveSosOnNativeOwnerFromApp() async {
    final current = await deviceSosController.getStatus();
    if (current.triggerOrigin == DeviceSosTransitionSource.app &&
        !current.derivedFromBlePacket &&
        (current.state == DeviceSosState.preConfirm ||
            current.state == DeviceSosState.active ||
            current.state == DeviceSosState.acknowledged)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_DEVICE_COMMAND_ACK_MISSING '
        'command=SOS_TRIGGER_APP state=${current.state.name} '
        'optimistic=${current.optimistic} derivedFromBlePacket=false '
        'reason=native_owner_activation_requires_device_packet',
      );
      return current;
    }
    return deviceSosController.activateSosFromApp(
      commandWriterOverride: _sendDeviceCommandThroughActiveOwner,
      commandRouteLabel: _currentDeviceCommandOwnerRoute,
    );
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
    bool? waitForDeviceAcknowledgement,
    _CapturedPhysicalDeviceConnection? capturedDeviceConnection,
  }) async {
    final status = await _terminatePhysicalSosOnCurrentDevice(
      intent: intent,
      waitForDeviceAcknowledgement: waitForDeviceAcknowledgement,
      capturedDeviceConnection: capturedDeviceConnection,
    );
    if (syncBackendForDeviceOriginatedCycle) {
      await _applyBackendClosureForDeviceOriginatedCycle(
        status,
        fallbackIntent: intent,
      );
    }
    return status;
  }

  Future<DeviceSosStatus> _terminatePhysicalSosOnCurrentDevice({
    required _SosClosureIntent intent,
    bool? waitForDeviceAcknowledgement,
    _PhysicalSosTerminationTarget? capturedTarget,
    _CapturedPhysicalDeviceConnection? capturedDeviceConnection,
    void Function()? onCommandSubmit,
    void Function()? onCommandDispatch,
  }) async {
    if (capturedTarget == null && capturedDeviceConnection == null) {
      await _loadRuntimeReadyDeviceStatusForSosSync(action: intent.name);
    } else if (capturedTarget != null &&
        !_physicalSosTerminationTargetIsCurrent(capturedTarget)) {
      throw StateError('stale remote terminal device clear');
    } else if (capturedDeviceConnection != null &&
        !_capturedPhysicalDeviceConnectionIsCurrent(capturedDeviceConnection)) {
      throw StateError('stale captured device connection');
    }
    final currentStatus = await deviceSosController.getStatus();
    final shouldWaitForDeviceAcknowledgement =
        waitForDeviceAcknowledgement ??
        (currentStatus.state == DeviceSosState.active ||
            currentStatus.state == DeviceSosState.acknowledged);
    final capabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
      reason: 'device_terminal_${intent.name}_command',
    );
    late final DeviceSosStatus status;
    BleDebugRegistry.instance.recordEvent(
      'device_terminal_command_requested action=${intent.name} '
      'primitive=terminatePhysicalSosOnCurrentDevice',
    );
    try {
      status = await deviceSosController.cancelSos(
        commandWriterOverride: capturedTarget == null
            ? _sendDeviceCommandThroughActiveOwner
            : (command) async {
                if (!_physicalSosTerminationTargetIsCurrent(capturedTarget)) {
                  throw StateError('stale remote terminal device clear');
                }
                onCommandSubmit?.call();
                _remoteTerminalDeviceClearAwaitingAckProof = capturedTarget;
                try {
                  await _sendDeviceCommandThroughActiveOwner(command);
                } catch (_) {
                  if (identical(
                    _remoteTerminalDeviceClearAwaitingAckProof,
                    capturedTarget,
                  )) {
                    _remoteTerminalDeviceClearAwaitingAckProof = null;
                  }
                  rethrow;
                }
                onCommandDispatch?.call();
              },
        commandRouteLabel: _currentDeviceCommandOwnerRoute,
        terminalAction: intent.name,
        terminalCmdAvailable: capabilitySnapshot.longCommandAvailable,
        waitForCloseAcknowledgement: shouldWaitForDeviceAcknowledgement,
        operationIsCurrent: capturedTarget == null
            ? capturedDeviceConnection == null
                  ? null
                  : () => _capturedPhysicalDeviceConnectionIsCurrent(
                      capturedDeviceConnection,
                    )
            : () => _physicalSosTerminationTargetIsCurrent(capturedTarget),
      );
    } catch (error) {
      if (intent == _SosClosureIntent.resolve) {
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_SOS_RESOLVE_PHYSICAL_STATE_PRESERVED '
          'reason=command_failure_without_terminal_evidence '
          'state=${currentStatus.state.name} errorType=${error.runtimeType}',
        );
        return currentStatus;
      }
      if (currentStatus.triggerOrigin != DeviceSosTransitionSource.device ||
          !_canCloseDeviceSosForPublicSos(currentStatus)) {
        rethrow;
      }
      status = currentStatus.copyWith(
        state: intent == _SosClosureIntent.resolve
            ? DeviceSosState.resolved
            : DeviceSosState.inactive,
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
        terminalState: intent == _SosClosureIntent.resolve
            ? SosState.resolved
            : SosState.cancelled,
        nodeId: status.nodeId,
      );
    }
    if (shouldWaitForDeviceAcknowledgement &&
        _isDeviceCloseMissingAcknowledgement(status)) {
      _applyTerminalSosSuppression(
        reason: 'device_close_command_without_ack:${intent.name}',
        terminalState: intent == _SosClosureIntent.resolve
            ? SosState.resolved
            : SosState.cancelled,
        nodeId: status.nodeId,
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
    if (_isProtectionPlatformOwningBle &&
        !_isAuthoritativeNativeProtectionBleOwner) {
      _throwDeviceCommandNotReady();
    }
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
  Future<NearbyTextTxResult> sendNearbyBroadcastText(String text) {
    return _nearbyTextController.sendBroadcast(text);
  }

  @override
  Future<NearbyTextTxResult> sendNearbyDirectText(
    String text, {
    required int destNodeId,
  }) {
    return _nearbyTextController.sendDirect(text, destNodeId: destNodeId);
  }

  @override
  Future<NearbyTextTxResult> sendNearbyGroupText(
    String text, {
    required int groupId,
  }) {
    return _nearbyTextController.sendGroup(text, groupId: groupId);
  }

  @override
  Future<NearbyGroupCommandResult> setNearbyGroup({
    required int groupId,
    required List<int> keyBytes,
    bool replace = false,
  }) {
    return _nearbyTextController.setGroup(
      groupId: groupId,
      psk: keyBytes,
      replace: replace,
    );
  }

  @override
  Future<NearbyGroupCommandResult> removeNearbyGroup(int groupId) {
    return _nearbyTextController.removeGroup(groupId);
  }

  @override
  Stream<NearbyIncomingText> watchNearbyText() {
    return _nearbyTextController.incoming;
  }

  @override
  Stream<NearbyNodeName> watchNearbyNodeNames() {
    return _nearbyTextController.nodeNames;
  }

  @override
  Future<void> setNearbyOwnerDisplayName(String name) {
    return _nearbyTextController.setOwnerDisplayName(name);
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
  Future<DeviceCountryConfigStatus> getDeviceCountryConfigStatus() async {
    return _deviceCountryConfigController?.lastStatus ??
        _lastDeviceCountryConfigStatus;
  }

  @override
  Stream<DeviceCountryConfigStatus> watchDeviceCountryConfigStatus() async* {
    yield _deviceCountryConfigController?.lastStatus ??
        _lastDeviceCountryConfigStatus;
    yield* _deviceCountryConfigStatusController.stream;
  }

  @override
  Future<DeviceCountryConfigStatus> checkDeviceCountryConfig({
    String reason = 'manual',
    String? countryIsoOverride,
  }) async {
    final controller = _deviceCountryConfigController;
    if (controller == null) {
      return _deviceCountryConfigUnavailableStatus(operation: 'check');
    }
    final status = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    if (status?.connected == true) {
      _lastDeviceCountryConfigCheckAt = _clock();
      _lastDeviceCountryConfigCheckDeviceKey =
          DeviceCountryConfigController.deviceKeyFor(status!);
    }
    return controller.check(
      reason: reason,
      countryIsoOverride: countryIsoOverride,
    );
  }

  @override
  Future<DeviceCountryConfigStatus> applyPendingDeviceCountryConfig({
    String reason = 'user_confirmed',
  }) async {
    final controller = _deviceCountryConfigController;
    if (controller == null) {
      return _deviceCountryConfigUnavailableStatus(
        operation: 'apply',
        applyAttempted: true,
      );
    }
    return controller.applyPending(reason: reason);
  }

  @override
  @Deprecated(
    'Use checkDeviceCountryConfig, then applyPendingDeviceCountryConfig after '
    'explicit user confirmation.',
  )
  Future<DeviceCountryConfigStatus> ensureDeviceCountryConfig({
    String reason = 'manual',
  }) async {
    return checkDeviceCountryConfig(reason: reason);
  }

  /// Fire-and-forget best-effort detection used by SDK lifecycle seams.
  ///
  /// This is event-driven: a real BLE connection is checked once after its
  /// command path becomes ready. Foreground resumes are additionally throttled
  /// per device so routine app switching cannot cause repeated backend/device
  /// reads. This never writes or reboots; a mismatch waits for host/user
  /// confirmation.
  Future<void> _maybeCheckDeviceCountryConfig(
    String trigger, {
    int? connectionEpoch,
    bool resume = false,
  }) async {
    final controller = _deviceCountryConfigController;
    if (controller == null) {
      return;
    }
    _queueDeviceCountryConfigCheck(
      trigger: trigger,
      connectionEpoch: connectionEpoch,
      resume: resume,
    );
    if (_deviceCountryConfigCheckDrainRunning) {
      return;
    }
    _deviceCountryConfigCheckDrainRunning = true;
    try {
      while (true) {
        final request = _queuedDeviceCountryConfigCheck;
        if (request == null) {
          break;
        }
        _queuedDeviceCountryConfigCheck = null;
        if (_deviceProvisioningCoordinator?.isBusy == true) {
          _queuedDeviceCountryConfigCheck = request;
          break;
        }
        final status = _lastPublicDeviceStatus ?? _lastDeviceStatus;
        if (status == null || !status.connected) {
          continue;
        }
        if (!_isDeviceCountryConfigCommandPathReady()) {
          continue;
        }

        if (request.connectionEpoch != null &&
            request.connectionEpoch ==
                _lastCheckedDeviceCountryConfigConnectionEpoch) {
          continue;
        }

        final deviceKey = DeviceCountryConfigController.deviceKeyFor(status);
        final now = _clock();
        final lastCheckAt = _lastDeviceCountryConfigCheckAt;
        final sameDevice = deviceKey == _lastDeviceCountryConfigCheckDeviceKey;
        final minimumInterval = request.resume
            ? _deviceCountryConfigResumeMinInterval
            : _deviceCountryConfigDuplicateMinInterval;
        final elapsed = lastCheckAt == null
            ? null
            : now.difference(lastCheckAt);
        if (request.connectionEpoch == null &&
            sameDevice &&
            elapsed != null &&
            !elapsed.isNegative &&
            elapsed < minimumInterval) {
          continue;
        }

        if (request.connectionEpoch != null) {
          _lastCheckedDeviceCountryConfigConnectionEpoch =
              request.connectionEpoch;
        }
        _lastDeviceCountryConfigCheckAt = now;
        _lastDeviceCountryConfigCheckDeviceKey = deviceKey;
        try {
          await controller.check(reason: request.trigger);
        } catch (_) {
          // Best-effort; the controller never throws, but never let this seam
          // surface an error into a lifecycle path.
        }
      }
    } finally {
      _deviceCountryConfigCheckDrainRunning = false;
    }
  }

  void _queueDeviceCountryConfigCheck({
    required String trigger,
    required int? connectionEpoch,
    required bool resume,
  }) {
    final queued = _queuedDeviceCountryConfigCheck;
    final next = (
      trigger: trigger,
      connectionEpoch: connectionEpoch,
      resume: resume,
    );
    if (queued == null || queued.connectionEpoch == null) {
      _queuedDeviceCountryConfigCheck = next;
      return;
    }
    if (connectionEpoch != null && connectionEpoch >= queued.connectionEpoch!) {
      _queuedDeviceCountryConfigCheck = next;
    }
  }

  int _startDeviceCountryConfigConnectionEpoch() {
    _deviceCountryConfigConnectionEpoch += 1;
    return _deviceCountryConfigConnectionEpoch;
  }

  int _ensureDeviceCountryConfigConnectionEpoch() {
    if (_deviceCountryConfigConnectionEpoch == 0) {
      return _startDeviceCountryConfigConnectionEpoch();
    }
    return _deviceCountryConfigConnectionEpoch;
  }

  bool _isDeviceCountryConfigCommandPathReady() {
    final status = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    if (status?.connected != true) {
      return false;
    }
    if (_isAuthoritativeNativeProtectionBleOwner) {
      final protectionStatus = _protectionModeController.currentStatus;
      return protectionStatus.deviceConnected &&
          protectionStatus.serviceBleReady;
    }
    return _lastDeviceControlCommandPathAvailable ||
        deviceSosController.hasCommandChannel;
  }

  DeviceCountryConfigStatus _deviceCountryConfigUnavailableStatus({
    required String operation,
    bool applyAttempted = false,
  }) {
    final status = DeviceCountryConfigStatus(
      outcome: DeviceCountryConfigOutcome.failed,
      updatedAt: DateTime.now(),
      applyAttempted: applyAttempted,
      detail: 'Device country config controller unavailable ($operation).',
    );
    _lastDeviceCountryConfigStatus = status;
    if (!_deviceCountryConfigStatusController.isClosed) {
      _deviceCountryConfigStatusController.add(status);
    }
    return status;
  }

  /// Reuses the firmware coordinator's safety gate so a region change (which
  /// reboots the device) is held off during the same SOS / PreSOS / Death-Man /
  /// protection flows that block OTA. Returns a reason when held, else null.
  Future<String?> _deviceCountryConfigSafetyHold() async {
    final coordinator = firmwareUpdateCoordinator;
    final status = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    if (coordinator == null || status == null) {
      return null;
    }
    // A region change reboots the device; during an OTA transfer or its
    // post-DFU verification that reboot breaks the update.
    if (coordinator.hasActiveSession) {
      return 'firmwareUpdateInProgress';
    }
    final eligibility = await coordinator.evaluateEligibility(
      status: status,
      release: null,
    );
    const safetyBlockers = <FirmwareUpdateBlocker>{
      FirmwareUpdateBlocker.sosActive,
      FirmwareUpdateBlocker.preSosCountdownActive,
      FirmwareUpdateBlocker.dmpActiveOrOverdue,
      FirmwareUpdateBlocker.protectionRuntimeBusy,
    };
    for (final blocker in eligibility.blockers) {
      if (safetyBlockers.contains(blocker)) {
        return blocker.name;
      }
    }
    return null;
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
    final pending = List<EixamNotificationIntent>.unmodifiable(
      _pendingNotificationIntents,
    );
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
  Future<EixamPermissionPreflightResult> preparePermissionPreflight(
    EixamPermissionRequirement requirement,
  ) async {
    final state = await permissionsRepository.getPermissionState();
    return _buildPermissionPreflight(
      requirement: requirement,
      state: state,
      disclosureAcceptedNow: false,
      disclosureDeclinedNow: false,
    );
  }

  @override
  Future<EixamPermissionPreflightResult> acceptPermissionDisclosure(
    EixamPermissionRequirement requirement,
  ) async {
    final state = await permissionsRepository.getPermissionState();
    await _savePermissionDisclosureAck(requirement, state);
    return _buildPermissionPreflight(
      requirement: requirement,
      state: state,
      disclosureAcceptedNow: true,
      disclosureDeclinedNow: false,
    );
  }

  @override
  Future<EixamPermissionPreflightResult> declinePermissionDisclosure(
    EixamPermissionRequirement requirement,
  ) async {
    final state = await permissionsRepository.getPermissionState();
    return _buildPermissionPreflight(
      requirement: requirement,
      state: state,
      disclosureAcceptedNow: false,
      disclosureDeclinedNow: true,
    );
  }

  @override
  Future<PermissionState> requestLocationPermission() async {
    final previous = await permissionsRepository.getPermissionState();
    final state = await permissionsRepository.requestLocationPermission();
    if (!previous.hasLocationAccess && state.hasLocationAccess) {
      await _warmResolvedLocationAfterPermissionGrant(
        reason: 'location_permission_granted',
      );
    }
    return state;
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
  }) async {
    if (_firmwareOtaInProgress) {
      final status = await _protectionModeController.getStatus();
      BleDebugRegistry.instance.recordEvent(
        'OTA_COORDINATOR protection_enter_blocked reason=firmware_ota_in_progress',
      );
      return EnterProtectionModeResult(
        success: false,
        status: status,
        blockingIssues: const <ProtectionBlockingIssue>[
          ProtectionBlockingIssue(
            type: ProtectionBlockingIssueType.hostRuntimeStartFailed,
            message: 'Firmware OTA is in progress.',
            canBeResolvedInline: false,
          ),
        ],
      );
    }
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
    return _protectionModeController.flushQueues().then((result) async {
      await _flushPendingExternalRelayCancelsFromProtectionPlatform(
        trigger: 'manual_flush',
      );
      return result;
    });
  }

  Future<void> _handleDeviceSosStatus(DeviceSosStatus status) async {
    final sosStatusEventSequence = ++_deviceSosStatusEventSequence;
    _recordTerminalFenceDeviceInactiveBoundary(
      status,
      eventSequence: sosStatusEventSequence,
    );
    if (_consumeRemoteTerminalDeviceClearAck(status)) {
      return;
    }
    final acceptedPhysicalStart =
        status.lastPacketSignature != null &&
        _acceptedPhysicalStartPacketSignatures.contains(
          status.lastPacketSignature,
        );
    final statusHasPhysicalStartSemantics =
        status.derivedFromBlePacket &&
        status.transitionSource == DeviceSosTransitionSource.device &&
        (status.state == DeviceSosState.preConfirm ||
            status.state == DeviceSosState.active ||
            status.state == DeviceSosState.acknowledged);
    final convergenceEvaluation = statusHasPhysicalStartSemantics
        ? _evaluateTerminalConvergenceStart(
            incomingNodeId: status.nodeId,
            incomingPacketId: status.packetId,
            incomingPacketSignature: status.lastPacketSignature,
            incomingCycleKey: _runtimeDeviceSosCycleKey(
              status: status,
              nodeId: status.nodeId ?? _knownLocalDeviceNodeId,
            ),
            sameDevice: _terminalConvergenceFenceMatchesStatusDevice(status),
            receiveSequence:
                deviceSosController
                    .lastPhysicalReceiveEvidence
                    ?.receiveSequence ??
                sosStatusEventSequence,
          )
        : null;
    if (!acceptedPhysicalStart && convergenceEvaluation?.suppress == true) {
      _logPostTerminalInflightStartSuppressed(convergenceEvaluation!);
      return;
    }
    _clearRemoteTerminalAcknowledgementForNewDeviceCycle(status);
    _supersedeRemoteTerminalDeviceClearForFreshPhysicalStart(
      status,
      provenNewCycle: convergenceEvaluation?.provenNewCycle == true,
    );
    if (!acceptedPhysicalStart &&
        _shouldSuppressDeviceSosWhileRemoteTerminalClearPending(status)) {
      return;
    }
    if ((status.state == DeviceSosState.preConfirm ||
            status.state == DeviceSosState.active ||
            status.state == DeviceSosState.acknowledged) &&
        !acceptedPhysicalStart &&
        _terminalFenceSuppressesDeviceOpen(
          status,
          eventSequence: sosStatusEventSequence,
        )) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_FENCE_SUPPRESSED_OPEN source=device_active '
        'reason=authoritative_backend_terminal '
        'state=${status.state.name} nodeId=${status.nodeId ?? "none"}',
      );
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_ACTIVE_SUPPRESSED '
        'reason=authoritative_terminal_same_cycle '
        'state=${status.state.name}',
      );
      return;
    }
    if (_isNoOpInactiveDeviceSosStatus(status)) {
      return;
    }
    if (_shouldRejectStalePreSosPhysicalCancel(status)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_PHYSICAL_PRE_SOS_CANCEL_REJECTED '
        'reason=older_terminal_generation currentGeneration=${_sosLifecycle.current.generation} '
        'nodeId=${status.nodeId?.toString() ?? "-"}',
      );
      return;
    }
    _emitOperationalDiagnostics();
    _consumePendingAppTriggeredSosBridge(status);
    final deviceOwnedPreSosActivation =
        _preSosSession?.owner == _SosOwner.device &&
        status.state == DeviceSosState.active &&
        status.previousState == DeviceSosState.preConfirm &&
        status.nodeId != null;
    final isCorrelatedAppTriggeredStatus = _isCorrelatedAppTriggeredSosStatus(
      status,
    );
    final cycleKey = _deriveDeviceSosCycleKey(status);
    await _advanceConnectedLocalDeviceLifecycleBeforeHandoff(
      status,
      cycleKey: cycleKey,
      eventSequence: sosStatusEventSequence,
      acceptedPhysicalStart: acceptedPhysicalStart,
    );
    _recordAcceptedDevicePacketSignature(status);
    final isAppOriginatedStatus =
        status.triggerOrigin == DeviceSosTransitionSource.app;
    final appOwnedBleRuntimeStatus = _isAppOwnedBleRuntimeStatus(
      status,
      cycleKey: cycleKey,
      isCorrelatedAppTriggeredStatus: isCorrelatedAppTriggeredStatus,
    );
    if (appOwnedBleRuntimeStatus) {
      _recordAppOriginBleRuntimeCorrelation(status, runtimeCycleKey: cycleKey);
      _rememberAppOriginDeviceOwnershipContext(status);
    }
    if (_isDeviceSosCycleClosed(status.state) &&
        _shouldIgnoreAppOriginDeviceCancelOfArming(
          status,
          cycleKey: cycleKey,
        )) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_ORIGIN_DEVICE_CANCEL_OF_ARMING_IGNORED '
        'reason=matching_app_origin_bridge '
        'appCycleKey=${_preSosSession?.cycleKey ?? "-"} '
        'runtimeCycleKey=${cycleKey ?? "-"} '
        'nodeId=${_appOriginRuntimeNodeId(status)?.toString() ?? "-"} '
        'packetId=${status.packetId?.toString() ?? "-"}',
      );
      return;
    }
    final appOriginPreSosReachedActive =
        appOwnedBleRuntimeStatus &&
        !deviceOwnedPreSosActivation &&
        status.previousState == DeviceSosState.preConfirm &&
        (status.state == DeviceSosState.active ||
            status.state == DeviceSosState.acknowledged);
    if (status.state == DeviceSosState.preConfirm) {
      _syncPreSosSessionFromDeviceStatus(status);
    } else if (appOriginPreSosReachedActive) {
      _promoteAppOriginPreSosFromBleActive(status, cycleKey: cycleKey);
    } else if (status.previousState == DeviceSosState.preConfirm) {
      _clearPreSosSession(
        reason: 'device_left_pre_confirm:${status.state.name}',
        emitIdleState: false,
      );
    }
    final terminalPreview = _remoteRelayTerminalResidueLabel(status);
    final statusNodeId = _normalizeNodeIdOrNull(
      status.nodeId ??
          _parseDeviceRuntimeNodeId(status.lastPacketSignature) ??
          _parseSosCycleNodeId(status.lastPacketSignature),
    );
    final hasRecentRelayContext = statusNodeId == null
        ? false
        : _recentExternalRelayContextForRelayNode(statusNodeId) != null;
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS device_sos_status_observed '
      'seq=$sosStatusEventSequence '
      'nodeId=${statusNodeId?.toString() ?? "none"} '
      'state=${status.state.name} '
      'previous=${status.previousState?.name ?? "none"} '
      'terminal=${terminalPreview ?? "none"} '
      'sosType=${status.sosType?.toString() ?? "none"} '
      'packetId=${status.packetId?.toString() ?? "none"} '
      'lastPacketAt=${status.lastPacketAt?.toUtc().toIso8601String() ?? "none"} '
      'updatedAt=${status.updatedAt.toUtc().toIso8601String()} '
      'recentRemoteRelayContext=$hasRecentRelayContext '
      'lastPacketSignature=${status.lastPacketSignature ?? "none"}',
    );
    final isDeviceTimeoutPromotion =
        !status.derivedFromBlePacket &&
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
    final connectedLocalTerminal =
        _isConnectedLocalDeviceTerminalForActiveCycle(
          status,
          appOwnedBleRuntimeStatus: appOwnedBleRuntimeStatus,
        );
    if (connectedLocalTerminal) {
      await _acceptConnectedLocalDeviceTerminal(status);
    } else if (!_isOwnDeviceUserDeactivatedEvent(status)) {
      if (await _handleRemoteRelayCancelFromTerminalResidue(
        status,
        eventSequence: sosStatusEventSequence,
      )) {
        return;
      }
    }
    _rememberDeviceRuntimeSosOwnership(status, cycleKey);
    _emitDeviceSosActiveNotificationIntent(status, cycleKey);

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

    // Preserve the established device/pre-SOS publication ordering. Remote
    // or uncorrelated closures stay non-terminal until backend evidence
    // matches. A connected-tag 0xE1 (physical button) is authoritative for
    // the local surface — otherwise the host stays on active/sending after
    // the tag has already stopped.
    await _reconcileAuthoritativeLifecycleFromDeviceStatus(status);

    if (_isSosCycleClosed(status.state)) {
      final terminalState =
          _mapTerminalDeviceStatusToPublicSosState(status) ??
          (status.state == DeviceSosState.resolved
              ? SosState.resolved
              : SosState.cancelled);
      _applyTerminalSosSuppression(
        reason: _deviceTerminalEventReason(status),
        terminalState: terminalState,
        nodeId: status.nodeId,
      );
      final closedCycleKey = _activeDeviceSosCycleKey;
      BleDebugRegistry.instance.recordEvent(
        'SOS notification suppression reset -> reason=cycle_closed clearedCycle=${_activeDeviceSosCycleKey ?? "-"}',
      );
      await _clearSosNotificationsSafely(
        reason: 'device_cycle_closed:${status.state.name}',
      );
      if (appOwnedBleRuntimeStatus) {
        _cleanupAppOriginDeviceTerminalState(
          status,
          cycleKey: closedCycleKey ?? cycleKey,
        );
      }
      _activeDeviceSosCycleKey = null;
      _notifiedDeviceSosCycleKey = null;
      _notifiedDeviceSosState = null;
      _clearRememberedDeviceOriginatedClosureIntent(cycleKey: closedCycleKey);
      _clearPendingAppTriggeredSosBridge(reason: 'device_cycle_closed');
      if (connectedLocalTerminal) {
        _clearDeviceRuntimeSosOwnership(
          reason: 'connected_local_device_terminal',
        );
      }
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

    BleDebugRegistry.instance.recordEvent(
      'SOS local notification skipped -> reason=notification_intents_only cycleKey=$cycleKey state=${status.state.name} policy=${_notificationPolicyLabel(notificationPolicy)}',
    );
  }

  bool _isSosCycleNotifiable(DeviceSosState state) {
    return state == DeviceSosState.preConfirm ||
        state == DeviceSosState.active ||
        state == DeviceSosState.acknowledged;
  }

  Future<void> _advanceConnectedLocalDeviceLifecycleBeforeHandoff(
    DeviceSosStatus status, {
    required String? cycleKey,
    required int eventSequence,
    required bool acceptedPhysicalStart,
  }) async {
    final effectiveCycleKey = cycleKey ??
        (acceptedPhysicalStart
            ? 'accepted:${status.nodeId ?? _knownLocalDeviceNodeId ?? "unknown"}:'
                  '${status.lastPacketSignature ?? status.lastPacketHex ?? status.updatedAt.microsecondsSinceEpoch}'
            : null);
    if (effectiveCycleKey == null ||
        status.triggerOrigin != DeviceSosTransitionSource.device) {
      return;
    }
    final device = _lastDeviceStatus;
    final previousGeneration = _sosLifecycle.current.generation;
    final terminalFence = _sosLifecycle.activeTerminalWatermark;
    final mayStartAfterTerminal =
        acceptedPhysicalStart ||
        _terminalFenceAllowsFreshDeviceGeneration(
          status,
          eventSequence: eventSequence,
        );
    final deferFreshGenerationPublication =
        terminalFence != null && mayStartAfterTerminal;
    void recordPhysicalStartCommit(SosLifecycleSnapshot lifecycle) {
      if (!acceptedPhysicalStart) {
        return;
      }
      final committed = lifecycle.generation > previousGeneration;
      final packetSignature = status.lastPacketSignature;
      if (packetSignature != null) {
        _acceptedPhysicalStartPacketSignatures.remove(packetSignature);
      }
      if (committed && terminalFence == null) {
        _resetPublicSosPresentationForGeneration(
          lifecycle.generation,
          reason: 'accepted_physical_start',
          emitIdle: true,
        );
        BleDebugRegistry.instance.recordEvent(
          'SOS_NEW_GENERATION_ACCEPTED '
          'previousGeneration=$previousGeneration '
          'newGeneration=${lifecycle.generation} source=device',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS_PHYSICAL_START_COMMIT '
        'decision=accept_new_generation '
        'previousGeneration=$previousGeneration '
        'committedGeneration=${lifecycle.generation} '
        'success=$committed '
        'reason=${committed ? "generation_committed" : "newer_generation_won"}',
      );
    }
    if (status.state == DeviceSosState.preConfirm) {
      if (!_sosLifecycle.current.isOpen) {
        final lifecycle = await _sosLifecycle.beginArming(
          origin: SosLifecycleOrigin.connectedLocalDevice,
          lifecycleId: 'device-cycle:$effectiveCycleKey',
          triggerSource: 'ble_device_runtime_status',
          deviceId: device?.deviceId,
          nodeId: status.nodeId ?? device?.nodeId,
          hardwareId: _physicalHardwareIdForStatus(device),
          startNewGenerationAfterTerminal: mayStartAfterTerminal,
          emitToStream: !deferFreshGenerationPublication,
        );
        if (terminalFence != null &&
            lifecycle.generation > terminalFence.generation) {
          _completeAcceptedFreshPhysicalSosGeneration(
            status: status,
            previousTerminal: terminalFence,
            lifecycle: lifecycle,
            publicationWasDeferred: deferFreshGenerationPublication,
          );
        }
      }
      recordPhysicalStartCommit(_sosLifecycle.current);
      _traceConnectedLocalDeviceHandoff(
        action: 'accepted',
        from: 'preconfirm',
        to: 'activating',
        reason: 'authoritative_arming_established',
      );
      return;
    }
    if (status.state != DeviceSosState.active &&
        status.state != DeviceSosState.acknowledged) {
      return;
    }
    var lifecycle = _sosLifecycle.current;
    if (!lifecycle.isOpen || lifecycle.isTerminal) {
      lifecycle = await _sosLifecycle.beginArming(
        origin: SosLifecycleOrigin.connectedLocalDevice,
        lifecycleId: 'device-cycle:$effectiveCycleKey',
        triggerSource: 'ble_device_runtime_status',
        deviceId: device?.deviceId,
        nodeId: status.nodeId ?? device?.nodeId,
        hardwareId: _physicalHardwareIdForStatus(device),
        startNewGenerationAfterTerminal: mayStartAfterTerminal,
        emitToStream: !deferFreshGenerationPublication,
      );
      if (terminalFence != null &&
          lifecycle.generation > terminalFence.generation) {
        _completeAcceptedFreshPhysicalSosGeneration(
          status: status,
          previousTerminal: terminalFence,
          lifecycle: lifecycle,
          publicationWasDeferred: deferFreshGenerationPublication,
        );
      }
    }
    if (lifecycle.stage == SosLifecycleStage.arming) {
      lifecycle = await _sosLifecycle.beginActivating(
        origin: SosLifecycleOrigin.connectedLocalDevice,
        triggerSource: 'ble_device_runtime_status',
        deviceId: device?.deviceId,
        nodeId: status.nodeId ?? device?.nodeId,
        hardwareId: _physicalHardwareIdForStatus(device),
      );
    }
    if (lifecycle.stage == SosLifecycleStage.activating) {
      await _sosLifecycle.confirmActive(
        origin: SosLifecycleOrigin.connectedLocalDevice,
        localIncidentId: 'device-runtime-$effectiveCycleKey',
        triggerSource: 'ble_device_runtime_status',
        deviceId: device?.deviceId,
        nodeId: status.nodeId ?? device?.nodeId,
        hardwareId: _physicalHardwareIdForStatus(device),
      );
    }
    recordPhysicalStartCommit(lifecycle);
    _traceConnectedLocalDeviceHandoff(
      action: 'accepted',
      from: status.previousState == DeviceSosState.preConfirm
          ? 'preconfirm'
          : lifecycle.stage.name,
      to: 'activating',
      reason: 'device_active_precedes_pre_sos_clear',
    );
  }

  bool _isConnectedLocalDeviceTerminalForActiveCycle(
    DeviceSosStatus status, {
    required bool appOwnedBleRuntimeStatus,
  }) {
    if (!_isDeviceSosCycleClosed(status.state) ||
        (status.triggerOrigin != DeviceSosTransitionSource.device &&
            !appOwnedBleRuntimeStatus)) {
      return false;
    }
    final lifecycle = _sosLifecycle.current;
    final connectedLocalLifecycle =
        lifecycle.origin == SosLifecycleOrigin.connectedLocalDevice;
    final lifecycleMatchesLocalTerminal =
        (connectedLocalLifecycle && lifecycle.isOpen) ||
        appOwnedBleRuntimeStatus;
    if (!lifecycleMatchesLocalTerminal) {
      return false;
    }
    final statusNodeId = _normalizeNodeIdOrNull(status.nodeId);
    final ownerNodeId =
        lifecycle.nodeId ??
        _parseSosCycleNodeId(_activeDeviceRuntimeLocalCycleKey) ??
        _parseSosCycleNodeId(_activeDeviceSosCycleKey);
    return statusNodeId == null ||
        ownerNodeId == null ||
        statusNodeId == ownerNodeId;
  }

  Future<void> _acceptConnectedLocalDeviceTerminal(
    DeviceSosStatus status,
  ) async {
    _traceConnectedLocalDeviceCycle(action: 'terminated', status: status);
    _traceDeviceTerminal(
      action: 'accepted',
      classification: 'connected_local',
      matchedActiveOwner: true,
      lifecycleTerminal:
          status.derivedFromBlePacket &&
          status.lastOpcode == EixamBleProtocol.sosEventUserDeactivatedOpcode,
    );
  }

  void _traceConnectedLocalDeviceCycle({
    required String action,
    required DeviceSosStatus status,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'EIXAM_SOS_STATUS event=device_cycle '
      'action=$action origin=connected_local_device '
      'generation_present=${_deviceRuntimeLocalCycleSequence > 0} '
      'packet_identity_present=${status.packetId != null}',
    );
  }

  void _traceConnectedLocalDeviceHandoff({
    required String action,
    required String from,
    required String to,
    required String reason,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'EIXAM_SOS_STATUS event=device_handoff '
      'action=$action from=$from to=$to reason=$reason',
    );
  }

  void _traceDeviceTerminal({
    required String action,
    required String classification,
    required bool matchedActiveOwner,
    required bool lifecycleTerminal,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'EIXAM_SOS_STATUS event=device_terminal '
      'action=$action classification=$classification '
      'matched_active_owner=$matchedActiveOwner '
      'lifecycle_terminal=$lifecycleTerminal',
    );
  }

  String _deviceTerminalEventReason(DeviceSosStatus status) {
    final lastEvent = status.lastEvent.toLowerCase();
    if (lastEvent.contains('missing_ack') ||
        lastEvent.contains('without_ack') ||
        lastEvent.contains('ack_timeout') ||
        lastEvent.contains('forced_terminal_after_missing_ack')) {
      return 'device_terminal_event:missing_ack:${status.state.name}';
    }
    if (_publicSosClosureInFlight == _SosClosureIntent.cancel) {
      return 'device_terminal_event:app_cancel:${status.state.name}';
    }
    if (status.previousState == DeviceSosState.preConfirm) {
      return 'device_terminal_event:pre_sos:${status.state.name}';
    }
    return 'device_terminal_event:${status.state.name}';
  }

  bool _isSosCycleClosed(DeviceSosState state) {
    return state == DeviceSosState.inactive || state == DeviceSosState.resolved;
  }

  bool _isNoOpInactiveDeviceSosStatus(DeviceSosStatus status) {
    if (status.state != DeviceSosState.inactive) {
      return false;
    }
    if (status.previousState != null &&
        status.previousState != DeviceSosState.inactive) {
      return false;
    }
    if (_activeDeviceSosCycleKey != null || _preSosSession != null) {
      return false;
    }
    if (status.nodeId != null) {
      return false;
    }
    if (_remoteRelayTerminalResidueLabel(status) != null) {
      return false;
    }
    return true;
  }

  Future<bool> _handleRemoteRelayCancelFromTerminalResidue(
    DeviceSosStatus status, {
    required int eventSequence,
  }) async {
    final terminal = _remoteRelayTerminalResidueLabel(status);
    if (terminal == null) {
      return false;
    }
    final relayNodeId = _normalizeNodeIdOrNull(
      status.nodeId ??
          _parseDeviceRuntimeNodeId(status.lastPacketSignature) ??
          _parseSosCycleNodeId(status.lastPacketSignature),
    );
    if (relayNodeId == null) {
      return false;
    }
    final observedAt = _relayTerminalResidueObservedAt(status);
    final signature = _relayTerminalResidueSignature(
      status: status,
      relayNodeId: relayNodeId,
      terminal: terminal,
    );
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS relay_terminal_residue_detected '
      'relayNodeId=$relayNodeId terminal=$terminal '
      'observedAt=${observedAt?.toIso8601String() ?? "none"} '
      'signature=${signature ?? "none"}',
    );
    final context = _recentExternalRelayContextForRelayNode(relayNodeId);
    if (context == null) {
      _traceDeviceTerminal(
        action: 'ignored',
        classification: 'remote_relay',
        matchedActiveOwner: false,
        lifecycleTerminal: false,
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS relay_terminal_residue_ignored '
        'reason=no_recent_remote_context relayNodeId=$relayNodeId '
        'terminal=$terminal signature=${signature ?? "none"}',
      );
      return false;
    }
    if (!_isFreshRemoteRelayTerminalResidue(
      context: context,
      signature: signature,
      observedAt: observedAt,
      eventSequence: eventSequence,
    )) {
      _traceDeviceTerminal(
        action: 'ignored',
        classification: 'remote_relay',
        matchedActiveOwner: false,
        lifecycleTerminal: false,
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS relay_terminal_residue_ignored '
        'reason=stale_baseline relayNodeId=$relayNodeId '
        'originatorNodeId=${context.originatorNodeId} '
        'baselineSignature=${context.baselineTerminalSignature ?? "none"} '
        'signature=${signature ?? "none"}',
      );
      return true;
    }
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS relay_terminal_residue_matched '
      'originatorNodeId=${context.originatorNodeId} '
      'relayNodeId=$relayNodeId '
      'backendIncidentId=${context.backendIncidentId ?? "none"}',
    );
    _traceDeviceTerminal(
      action: 'accepted',
      classification: 'remote_relay',
      matchedActiveOwner: false,
      lifecycleTerminal: false,
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_ORIGIN_DECISION source=relay_terminal_residue '
      'actionability=externalOnly localStateMutation=false '
      'publicIncident=false backendCancel=true '
      'reason=remote_lora_cancel_from_tel_clear',
    );
    final payloadHex = status.lastPacketHex?.trim();
    final rawPayload = payloadHex == null || payloadHex.isEmpty
        ? const <int>[]
        : _tryDecodeHexPayload(payloadHex) ?? const <int>[];
    final snapshot = RemoteRelaySosSnapshot(
      kind: RemoteRelaySosKind.cancel,
      originatorNodeId: context.originatorNodeId,
      relayNodeId: relayNodeId,
      source: RemoteRelaySosSource.telRelay,
      sosType: status.sosType ?? 0,
      receivedAt: observedAt ?? status.updatedAt,
      rawPayload: List<int>.unmodifiable(rawPayload),
      payloadHex: payloadHex,
      relayCount: status.relayCount,
      eventOpcode: status.lastOpcode,
    );
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS synthetic_cancel_from_relay_terminal_residue '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=$relayNodeId '
      'kind=${snapshot.kind.name} '
      'backendIncidentId=${context.backendIncidentId ?? "none"}',
    );
    await _handleRemoteRelaySosCancelBackendHandoff(
      snapshot,
      relayHardwareIdOverride: context.relayHardwareId,
    );
    return true;
  }

  String? _remoteRelayTerminalResidueLabel(DeviceSosStatus status) {
    final terminalState = _mapTerminalDeviceStatusToPublicSosState(status);
    if (terminalState != null) {
      return terminalState.name;
    }
    if (status.state == DeviceSosState.resolved) {
      return SosState.resolved.name;
    }
    if (status.state == DeviceSosState.inactive &&
        (status.sosType == 0 ||
            status.previousState == DeviceSosState.active ||
            status.previousState == DeviceSosState.acknowledged ||
            status.previousState == DeviceSosState.preConfirm)) {
      return SosState.cancelled.name;
    }
    return null;
  }

  DateTime? _relayTerminalResidueObservedAt(DeviceSosStatus status) {
    return (status.lastPacketAt ?? status.updatedAt).toUtc();
  }

  String? _relayTerminalResidueSignature({
    required DeviceSosStatus status,
    required int relayNodeId,
    required String terminal,
  }) {
    final explicitSignature = status.lastPacketSignature?.trim();
    if (explicitSignature != null && explicitSignature.isNotEmpty) {
      return explicitSignature;
    }
    final payloadHex = status.lastPacketHex?.trim();
    if (payloadHex != null && payloadHex.isNotEmpty) {
      return 'payload:$payloadHex';
    }
    final packetId = status.packetId?.toString() ?? 'none';
    final sosType = status.sosType?.toString() ?? 'none';
    return 'relay:$relayNodeId:terminal:$terminal:state:${status.state.name}:'
        'sosType:$sosType:packetId:$packetId';
  }

  bool _isFreshRemoteRelayTerminalResidue({
    required _RecentExternalRelaySosContext context,
    required String? signature,
    required DateTime? observedAt,
    required int eventSequence,
  }) {
    final baselineSignature = context.baselineTerminalSignature;
    if (baselineSignature != null &&
        signature != null &&
        baselineSignature == signature) {
      return false;
    }
    final baselineObservedAt = context.baselineTerminalObservedAt;
    if (baselineObservedAt != null &&
        observedAt != null &&
        !observedAt.isAfter(baselineObservedAt)) {
      return false;
    }
    if (observedAt != null &&
        observedAt.isBefore(context.triggerObservedAt) &&
        eventSequence <= context.baselineEventSequence) {
      return false;
    }
    if (signature == null && observedAt == null) {
      return eventSequence > context.baselineEventSequence;
    }
    return true;
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

  String? _deriveDeviceSosCycleKey(DeviceSosStatus status) {
    final nodeId =
        status.nodeId ??
        _parseDeviceRuntimeNodeId(status.lastPacketSignature) ??
        _parseSosCycleNodeId(status.lastPacketSignature) ??
        _knownLocalDeviceNodeId;
    if (!_isSosCycleNotifiable(status.state)) {
      return _resolveLocalDeviceRuntimeCycleKey(status: status, nodeId: nodeId);
    }
    final runtimeCycleKey = _runtimeDeviceSosCycleKey(
      status: status,
      nodeId: nodeId,
    );
    if (_matchesAppOriginMirroredPreSosBridge(
      status,
      runtimeCycleKey: runtimeCycleKey,
      nodeId: nodeId,
    )) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_ORIGIN_DEVICE_CYCLE_SUPPRESSED '
        'reason=matched_app_bridge runtimeCycleKey=${runtimeCycleKey ?? "-"}',
      );
      return runtimeCycleKey;
    }
    final localCycleKey = _resolveLocalDeviceRuntimeCycleKey(
      status: status,
      nodeId: nodeId,
    );
    if (localCycleKey != null) {
      return localCycleKey;
    }
    return runtimeCycleKey;
  }

  String? _runtimeDeviceSosCycleKey({
    required DeviceSosStatus status,
    required int? nodeId,
  }) {
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
        _parseSosCycleNodeId(currentLocalCycle) == nodeId) {
      _traceConnectedLocalDeviceCycle(
        action:
            status.state == DeviceSosState.active ||
                status.state == DeviceSosState.acknowledged
            ? 'promoted'
            : 'reused',
        status: status,
      );
      return currentLocalCycle;
    }
    if (_isDeviceSosCycleClosed(status.state)) {
      final lastClosedCycle = _lastClosedDeviceRuntimeLocalCycleKey;
      if (lastClosedCycle != null &&
          _parseSosCycleNodeId(lastClosedCycle) == nodeId) {
        _traceConnectedLocalDeviceCycle(
          action: 'terminal_reused',
          status: status,
        );
        return lastClosedCycle;
      }
      return null;
    }
    _deviceRuntimeLocalCycleSequence += 1;
    final nextCycle = 'sos:$nodeId:$_deviceRuntimeLocalCycleSequence';
    _activeDeviceRuntimeLocalCycleKey = nextCycle;
    _activeDeviceRuntimeCycleKey = 'sos-cycle:$nextCycle';
    _activeDeviceRuntimeIncidentId = 'device-runtime-$nextCycle';
    _lastDeviceRuntimeCanonicalIncidentSignature = null;
    _lastDeviceRuntimeCanonicalIncident = null;
    _deviceOwnedBackendIncidentId = null;
    _traceConnectedLocalDeviceCycle(action: 'created', status: status);
    return nextCycle;
  }

  bool _isLocalDeviceRuntimeSosStatus(DeviceSosStatus status) {
    return status.triggerOrigin == DeviceSosTransitionSource.device ||
        status.transitionSource == DeviceSosTransitionSource.device ||
        _preSosSession?.owner == _SosOwner.device;
  }

  String? debugDeriveDeviceSosCycleKey(DeviceSosStatus status) {
    return _deriveDeviceSosCycleKey(status);
  }

  Future<void> _handleNotificationAction(
    NotificationActionInvocation invocation,
  ) async {
    final actionId = invocation.actionId;
    BleDebugRegistry.instance.recordEvent(
      'Notification action tapped -> action=$actionId payload=${invocation.payload ?? '-'} launchedApp=${invocation.launchedApp}',
    );

    final deathManPayload = _DeathManNotificationPayload.tryParse(
      invocation.payload,
    );
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
        'BLE_COMMAND_DEFERRED_FROM_NOTIFICATION action=$actionId reason=connection_unavailable',
      );
      await _queueBleNotificationNavigation(
        actionId: actionId,
        reason: 'E_BLE_CONNECTION_UNAVAILABLE',
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

  void _completeAcceptedFreshPhysicalSosGeneration({
    required DeviceSosStatus status,
    required SosLifecycleSnapshot previousTerminal,
    required SosLifecycleSnapshot lifecycle,
    required bool publicationWasDeferred,
  }) {
    _resetPublicSosPresentationForGeneration(
      lifecycle.generation,
      reason: 'proven_new_physical_generation',
      emitIdle: true,
    );
    if (publicationWasDeferred) {
      _sosLifecycle.publishCurrent();
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_NEW_GENERATION_ACCEPTED '
      'previousGeneration=${previousTerminal.generation} '
      'newGeneration=${lifecycle.generation} source=device '
      'strongIdentity=${_hasStrongConnectedOwnDeviceSosIdentity(status, terminal: previousTerminal)} '
      'newCycle=${_deviceStatusHasNewCycleIdentity(status, previousTerminal)} '
      'afterTerminalBoundary=true',
    );
    _setSosDeviceMirrorState(
      _SosDeviceMirrorState.synchronized,
      source: 'new_physical_sos_generation',
    );
    _deviceInactiveBoundaryAfterTerminalGeneration = null;
    _latestOwnDeviceInactiveBoundary = null;
    _terminalBoundaryFromPreviousProcessGeneration = null;
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

  @override
  Future<void> startTracking() {
    return _trackingOwnerArbiter.addOwner(
      AndroidTrackingOwner.legacyPublicTracking,
    );
  }

  @override
  Future<void> stopTracking() {
    return _trackingOwnerArbiter.removeOwner(
      AndroidTrackingOwner.legacyPublicTracking,
    );
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    final rejectionReason = _publicTelemetryPublishRejectionReason(payload);
    LocationDebugLog.telemetryPayload(
      flow: 'public_publishTelemetry',
      payload: payload,
      accepted: rejectionReason == null,
      rejectionReason: rejectionReason,
      sentToBackend: false,
    );
    _assertPublicTelemetryPublishContract(payload);
    await telemetryRepository.publishTelemetry(
      await _enrichOperationalTelemetryPayload(payload),
    );
  }

  void _assertPublicTelemetryPublishContract(SdkTelemetryPayload payload) {
    final rejectionReason = _publicTelemetryPublishRejectionReason(payload);
    if (rejectionReason == null) {
      return;
    }
    throw TrackingException(
      'E_TELEMETRY_SOURCE_NOT_PUBLISHABLE',
      'Telemetry source ${payload.identitySource} is not valid for raw live telemetry publish.',
    );
  }

  String? _publicTelemetryPublishRejectionReason(SdkTelemetryPayload payload) {
    final source = payload.identitySource?.trim().toLowerCase();
    if (source == 'cached_fallback' ||
        source == 'backend_snapshot' ||
        source == 'remote_relay') {
      return 'source_not_publishable';
    }
    return null;
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
    final phonePositionSink = trackingRepository is LatestPhonePositionSink
        ? trackingRepository as LatestPhonePositionSink
        : null;
    return _seedThenReplayLiveStream<TrackingPosition>(
      seed: phonePositionSink?.latestPhonePosition != null
          ? () async => phonePositionSink?.latestPhonePosition
          : trackingRepository.getCurrentPosition,
      live: trackingRepository.watchPositions(),
      emitNullSeed: false,
    );
  }

  @override
  Stream<TrackingState> watchTrackingState() {
    return trackingRepository.watchTrackingState();
  }

  @override
  Future<void> startPreSos({
    Duration countdown = EixamConnectSdk.defaultPreSosCountdown,
  }) {
    return _startPreSos(countdown: countdown);
  }

  Future<void> _startPreSos({
    required Duration countdown,
    SosTriggerPayload? activationPayload,
  }) async {
    BleDebugRegistry.instance.recordEvent(
      'SOS_SDK_TRIGGER_ENTERED api=startPreSos countdown=${countdown.inSeconds}',
    );
    final entryCapability = await _buildSosCapability(
      reason: 'start_pre_sos_entry',
    );
    _logSosPathDecision(entryCapability);
    await _restorePersistedPreSosSession(trigger: 'startPreSos');
    if (await _settleExpiredPreSosSession(trigger: 'startPreSos')) {
      _logSosDeviceMirrorDecision(
        attempt: false,
        reason: 'expired_pre_sos_settled',
      );
      return;
    }
    _clearStaleTerminalRuntimeResidueForFreshAppSosStart();
    final existingIncident = await getCurrentSosIncident();
    final terminalFence = _sosLifecycle.activeTerminalWatermark;
    final existingIsFencedProjection =
        terminalFence != null &&
        !_hasNewAuthoritativeGenerationSinceTerminal() &&
        existingIncident != null &&
        sosIncidentEvidenceMatchesLifecycle(terminalFence, existingIncident);
    if ((_hasBackendVisibleSosIncident(existingIncident) &&
            !existingIsFencedProjection) ||
        _hasActivePreSosSession) {
      _logSosDeviceMirrorDecision(
        attempt: false,
        reason: _hasActivePreSosSession
            ? 'active_pre_sos_session'
            : 'active_backend_incident',
      );
      return;
    }

    final currentDeviceStatus = await deviceSosController.getStatus();
    if (currentDeviceStatus.state == DeviceSosState.preConfirm &&
        !(_sosLifecycle.activeTerminalWatermark != null &&
            !_hasNewAuthoritativeGenerationSinceTerminal())) {
      _syncPreSosSessionFromDeviceStatus(currentDeviceStatus);
      _logSosDeviceMirrorDecision(
        attempt: false,
        reason: 'device_pre_confirm_already_active',
      );
      return;
    }

    var mirroredOnDevice = false;
    final runtimeStatus = await _loadRuntimeReadyDeviceStatusForSosSync(
      action: 'pre_sos_start',
      refreshRuntimeStatus: true,
    );
    final executionCapability = await _buildSosCapability(
      reason: 'start_pre_sos_execution',
    );
    _logSosPathDecision(executionCapability);
    final armingLifecycle = await _sosLifecycle.beginArming(
      origin: SosLifecycleOrigin.localApp,
      triggerSource: activationPayload?.triggerSource ?? 'commercial_app',
      deviceId: runtimeStatus?.deviceId,
      nodeId: runtimeStatus?.nodeId,
      hardwareId: _physicalHardwareIdForStatus(runtimeStatus),
      startNewGenerationAfterTerminal: true,
    );
    _pendingSosActivation = _PendingSosActivationOperation(
      generation: armingLifecycle.generation,
      lifecycleRevision: armingLifecycle.revision,
      operationRevision: ++_pendingSosActivationRevision,
    );
    final canMirrorPreSosOnDevice = runtimeStatus != null;
    _logSosDeviceMirrorDecision(
      attempt: canMirrorPreSosOnDevice,
      reason: canMirrorPreSosOnDevice
          ? 'connected_command_ready_tag'
          : executionCapability.hasConnectedDevice
          ? 'command_channel_not_ready'
          : 'connected_device_not_present',
    );
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
          'SOS_TRIGGER_DEVICE_SOS_ENTERED route=$_currentDeviceCommandOwnerRoute',
        );
        BleDebugRegistry.instance.recordEvent(
          '[APP_PRE_SOS_DEVICE_COMMAND] action=attempt '
          'path=ble_inet_sos_trigger countdown=${countdown.inSeconds}',
        );
        final deviceStatus = await triggerDeviceSos();
        _deviceMirrorDispatchedGenerations.add(armingLifecycle.generation);
        mirroredOnDevice =
            deviceStatus.derivedFromBlePacket &&
            deviceStatus.transitionSource == DeviceSosTransitionSource.device &&
            (deviceStatus.state == DeviceSosState.preConfirm ||
                deviceStatus.state == DeviceSosState.active);
        BleDebugRegistry.instance.recordEvent(
          '[APP_PRE_SOS_DEVICE_COMMAND] action=sent '
          'path=ble_inet_sos_trigger '
          'deviceAcknowledged=$mirroredOnDevice',
        );
        if (!mirroredOnDevice) {
          BleDebugRegistry.instance.recordEvent(
            'SOS_DEVICE_COMMAND_ACK_MISSING '
            'command=SOS_TRIGGER_APP state=${deviceStatus.state.name} '
            'optimistic=${deviceStatus.optimistic} '
            'derivedFromBlePacket=${deviceStatus.derivedFromBlePacket}',
          );
        }
        final observedDeviceCycleKey = mirroredOnDevice
            ? _preSosCycleKeyFromDeviceStatus(deviceStatus)
            : null;
        final localStartedAt =
            deviceStatus.countdownStartedAt ?? DateTime.now();
        _syncPreSosSession(
          startedAt: localStartedAt,
          expectedActivationAt:
              deviceStatus.expectedActivationAt ??
              DateTime.now().add(countdown),
          mirroredOnDevice: mirroredOnDevice,
          origin: DeviceSosTransitionSource.app,
          owner: owner,
          cycleKey:
              observedDeviceCycleKey ?? _newLocalPreSosCycleKey(localStartedAt),
          originatorNodeId: deviceStatus.nodeId ?? runtimeStatus.nodeId,
          packetId: deviceStatus.packetId,
          activationPayload: activationPayload,
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
      activationPayload: activationPayload,
    );
  }

  @override
  Future<SosIncident> confirmPreSos(SosTriggerPayload payload) {
    final pending = _pendingPreSosConfirmation;
    if (pending != null) {
      return pending;
    }
    final pendingActivation = _pendingSosActivation;
    final future = _confirmPreSosInternal(
      payload,
      pendingActivation: pendingActivation,
    );
    _pendingPreSosConfirmation = future;
    return future.whenComplete(() {
      if (pendingActivation != null &&
          pendingActivation.dispatchCommitted &&
          !pendingActivation.dispatchResult.isCompleted) {
        pendingActivation.dispatchResult.complete();
      }
      if (identical(_pendingPreSosConfirmation, future)) {
        _pendingPreSosConfirmation = null;
      }
    });
  }

  @override
  Future<void> cancelPreSos() async {
    final previousClosureInFlight = _publicSosClosureInFlight;
    final lifecycleAtCancellationStart = _sosLifecycle.current;
    final pendingActivationAtCancellationStart = _pendingSosActivation;
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
      final commandAvailable =
          capabilitySnapshot.shortCommandAvailable ||
          capabilitySnapshot.longCommandAvailable;
      final stageIsArming = _publicSosState == SosState.arming;
      final protectionStatus = _protectionModeController.currentStatus;
      final protectionActive =
          protectionStatus.modeState == ProtectionModeState.armed ||
          protectionStatus.runtimeState == ProtectionRuntimeState.active;
      final deviceOwnedCountdown =
          status.state == DeviceSosState.preConfirm ||
          activeSession?.mirroredOnDevice == true ||
          activeSession?.owner == _SosOwner.device ||
          activeSession?.origin == DeviceSosTransitionSource.device ||
          stageIsArming;
      final hasIncidentId =
          _hasBackendVisibleSosIncident(_lastKnownActiveSosIncident) ||
          _hasBackendVisibleSosIncident(_publicSosFallbackIncident);
      final deviceId =
          runtimeStatus?.nodeId?.toString() ??
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
      await _terminalizeCancelledPreSosGeneration(
        expectedLifecycle: lifecycleAtCancellationStart,
        pendingActivation: pendingActivationAtCancellationStart,
        cycleKey: activeSession?.cycleKey,
        hasBackendIncident: hasIncidentId,
      );
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

  Future<void> _terminalizeCancelledPreSosGeneration({
    required SosLifecycleSnapshot expectedLifecycle,
    required _PendingSosActivationOperation? pendingActivation,
    required String? cycleKey,
    required bool hasBackendIncident,
  }) async {
    final current = _sosLifecycle.current;
    final matchingGeneration = _sameSosGeneration(current, expectedLifecycle);
    final pendingMatchesGeneration = pendingActivation == null
        ? _pendingSosActivation == null
        : (identical(_pendingSosActivation, pendingActivation) &&
              pendingActivation.generation == expectedLifecycle.generation &&
              pendingActivation.operationRevision ==
                  _pendingSosActivationRevision);
    final canTerminalize =
        matchingGeneration &&
        pendingMatchesGeneration &&
        current.stage == SosLifecycleStage.arming &&
        !hasBackendIncident &&
        current.backendIncidentId == null &&
        current.incident?.isBackendConfirmed != true &&
        pendingActivation?.dispatchCommitted != true;
    if (!canTerminalize) {
      final reason = !matchingGeneration
          ? 'newer_generation'
          : !pendingMatchesGeneration
          ? 'pending_generation_mismatch'
          : current.stage != SosLifecycleStage.arming
          ? 'not_arming'
          : hasBackendIncident ||
                current.backendIncidentId != null ||
                current.incident?.isBackendConfirmed == true
          ? 'backend_incident_present'
          : 'backend_dispatch_committed';
      BleDebugRegistry.instance.recordEvent(
        'SOS_PRE_SOS_LIFECYCLE_TERMINALIZATION_SKIPPED '
        'reason=$reason generation=${current.generation} '
        'stage=${current.stage.name}',
      );
      return;
    }

    if (pendingActivation != null && !pendingActivation.cancelled) {
      pendingActivation.cancelled = true;
      _pendingSosActivationRevision += 1;
    }
    final terminal = await _sosLifecycle.confirmTerminal(
      stage: SosLifecycleStage.cancelled,
      deviceCycleKey: cycleKey,
    );
    if (identical(_pendingSosActivation, pendingActivation)) {
      _pendingSosActivation = null;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_PRE_SOS_LIFECYCLE_TERMINALIZED '
      'reason=pre_sos_cancelled generation=${terminal.generation} '
      'cycleKey=${cycleKey ?? "-"}',
    );
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
  Stream<PublicPreSosStatus?> watchPreSosStatus() {
    return _seedThenReplayLiveStream<PublicPreSosStatus?>(
      seed: getPreSosStatus,
      live: _publicPreSosStatusController.stream,
      equals: _equivalentPreSosStatus,
    );
  }

  @override
  Future<OsSosWidgetActivationResult> handleOsSosWidgetActivation(
    OsSosWidgetActivation activation, {
    Duration countdown = EixamConnectSdk.defaultPreSosCountdown,
  }) async {
    final idempotencyKey = activation.idempotencyKey;
    if (idempotencyKey.isEmpty) {
      throw const SosException(
        'E_OS_WIDGET_ACTION_ID_REQUIRED',
        'E_OS_WIDGET_ACTION_ID_REQUIRED',
      );
    }

    await _restorePersistedPreSosSession(trigger: 'os_sos_widget');
    await _settleExpiredPreSosSession(trigger: 'os_sos_widget');

    final currentIncident = await getCurrentSosIncident();
    if (_hasBackendVisibleSosIncident(currentIncident) ||
        _isOpenSosState(_publicSosState)) {
      return OsSosWidgetActivationResult.fromActivation(
        activation: activation,
        outcome: OsSosWidgetActivationOutcome.activeSosAlreadyRunning,
        sosState: _publicSosState,
        incident: currentIncident,
      );
    }

    final preSosStatus = _buildCurrentPreSosStatus();
    if (preSosStatus != null) {
      return OsSosWidgetActivationResult.fromActivation(
        activation: activation,
        outcome: OsSosWidgetActivationOutcome.countdownAlreadyRunning,
        sosState: SosState.arming,
        preSosStatus: preSosStatus,
      );
    }

    if (!await _rememberOsSosWidgetAction(idempotencyKey)) {
      return OsSosWidgetActivationResult.fromActivation(
        activation: activation,
        outcome: OsSosWidgetActivationOutcome.duplicateIgnored,
        sosState: _publicSosState,
      );
    }

    final payload = SosTriggerPayload(
      triggerSource: SosTriggerPayload.osWidgetSource,
      osWidgetActivation: activation,
    );

    switch (activation.confirmationMode) {
      case OsSosWidgetConfirmationMode.countdown:
        await _startPreSos(countdown: countdown, activationPayload: payload);
        return OsSosWidgetActivationResult.fromActivation(
          activation: activation,
          outcome: OsSosWidgetActivationOutcome.countdownStarted,
          sosState: SosState.arming,
          preSosStatus: _buildCurrentPreSosStatus(),
        );
      case OsSosWidgetConfirmationMode.hold:
        final incident = await triggerSos(payload);
        return OsSosWidgetActivationResult.fromActivation(
          activation: activation,
          outcome: OsSosWidgetActivationOutcome.activated,
          sosState: incident.state,
          incident: incident,
        );
      case OsSosWidgetConfirmationMode.appOpened:
        return OsSosWidgetActivationResult.fromActivation(
          activation: activation,
          outcome: OsSosWidgetActivationOutcome.confirmationRequired,
          sosState: _publicSosState,
        );
    }
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

  @override
  Future<SosLifecycleSnapshot> getSosLifecycle() async => _sosLifecycle.current;

  @override
  Stream<SosLifecycleSnapshot> get sosLifecycleStream =>
      _seedThenReplayLiveStream<SosLifecycleSnapshot>(
        seed: () => _sosLifecycleConsumerReady
            ? _sosLifecycle.current
            : SosLifecycleSnapshot.idle(DateTime.now().toUtc()),
        live: _sosLifecycle.stream.where((_) => _sosLifecycleConsumerReady),
      );

  @override
  Future<SosActivationResult> triggerSosAuthoritatively(
    SosTriggerPayload payload,
  ) async {
    final selectedCapability = await getSosCapability();
    final identity = await _resolveLocalOperationalSosIdentity();
    final prior = _sosLifecycle.current;
    final hadPersistedLocalProof =
        prior.localActionable &&
        prior.localIncidentId != null &&
        (prior.isOpen || prior.stage == SosLifecycleStage.active);
    final attemptedLifecycle = await _sosLifecycle.beginActivating(
      origin: SosLifecycleOrigin.localApp,
      triggerSource: payload.triggerSource,
      deviceId: identity.deviceId,
      nodeId: identity.originatorNodeId,
      hardwareId: identity.hardwareId,
      startNewGenerationAfterTerminal: true,
    );
    try {
      final incident = await triggerSos(payload);
      final latestRepositoryIncident = await sosRepository.getCurrentIncident();
      final authoritativeIncident =
          latestRepositoryIncident != null &&
              latestRepositoryIncident.isBackendConfirmed &&
              sosIncidentEvidenceMatches(incident, latestRepositoryIncident)
          ? latestRepositoryIncident
          : incident;
      if (!identical(authoritativeIncident, incident)) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_ACTIVATION_CANONICAL_HANDOFF_PRESERVED '
          'reason=backend_confirmation_preceded_activation_return',
        );
      }
      final backendIncidentId =
          _isLocalAppSosIncidentId(authoritativeIncident.id)
          ? null
          : authoritativeIncident.id;
      final lifecycle = await _sosLifecycle.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId:
            authoritativeIncident.provisionalIncidentId ?? incident.id,
        backendIncidentId: backendIncidentId,
        triggerSource: payload.triggerSource,
        deviceId: authoritativeIncident.deviceId ?? identity.deviceId,
        nodeId:
            authoritativeIncident.originatorNodeId ?? identity.originatorNodeId,
        hardwareId:
            attemptedLifecycle.hardwareId ??
            identity.hardwareId ??
            _physicalHardwareIdForStatus(_lastDeviceStatus) ??
            authoritativeIncident.hardwareId,
        incident: authoritativeIncident,
      );
      return SosActivationResult(
        outcome: SosActivationOutcome.activated,
        lifecycle: lifecycle,
        incident: authoritativeIncident,
        selectedPath: selectedCapability.preferredActivationPath,
        usedPaths: _activationPathsForDelivery(
          authoritativeIncident.deliveryChannel,
        ),
      );
    } catch (error) {
      final alreadyActive =
          error is SosException && error.code == 'E_SOS_ALREADY_ACTIVE';
      if (!alreadyActive) {
        final lifecycle = await _sosLifecycle.activationFailed(
          error is EixamSdkException ? error.code : 'E_SOS_ACTIVATION_FAILED',
        );
        return SosActivationResult(
          outcome: SosActivationOutcome.failed,
          lifecycle: lifecycle,
        );
      }

      if (hadPersistedLocalProof) {
        final lifecycle = await _sosLifecycle.confirmActive(
          origin: prior.origin,
          localIncidentId: prior.localIncidentId!,
          backendIncidentId: prior.backendIncidentId,
          triggerSource: prior.triggerSource ?? payload.triggerSource,
          deviceId: prior.deviceId,
          nodeId: prior.nodeId,
          hardwareId: prior.hardwareId,
          incident: prior.incident,
          recoveryStatus: SosRecoveryStatus.restored,
        );
        return SosActivationResult(
          outcome: SosActivationOutcome.alreadyActiveRecovered,
          lifecycle: lifecycle,
          incident: lifecycle.incident,
          selectedPath: SosActivationPath.restoredActiveLifecycle,
          usedPaths: const <SosActivationPath>{
            SosActivationPath.restoredActiveLifecycle,
          },
        );
      }

      final authoritativeActive = await _reconcileAlreadyActiveIncident();
      if (authoritativeActive != null &&
          _matchesAttemptedAppSos(
            attempted: attemptedLifecycle,
            prior: prior,
            incident: authoritativeActive,
          )) {
        final lifecycle = await _sosLifecycle.confirmActive(
          origin: SosLifecycleOrigin.localApp,
          localIncidentId: authoritativeActive.id,
          backendIncidentId: authoritativeActive.id,
          triggerSource:
              authoritativeActive.triggerSource ?? payload.triggerSource,
          deviceId: authoritativeActive.deviceId ?? attemptedLifecycle.deviceId,
          nodeId:
              authoritativeActive.originatorNodeId ?? attemptedLifecycle.nodeId,
          hardwareId:
              attemptedLifecycle.hardwareId ??
              _physicalHardwareIdForStatus(_lastDeviceStatus) ??
              authoritativeActive.hardwareId,
          incident: authoritativeActive,
          recoveryStatus: SosRecoveryStatus.restored,
        );
        return SosActivationResult(
          outcome: SosActivationOutcome.alreadyActiveRecovered,
          lifecycle: lifecycle,
          incident: authoritativeActive,
          selectedPath: SosActivationPath.restoredActiveLifecycle,
          usedPaths: const <SosActivationPath>{
            SosActivationPath.restoredActiveLifecycle,
          },
        );
      }

      final deviceStatus = await deviceSosController.getStatus();
      final deviceProvesLocalActive =
          deviceStatus.state == DeviceSosState.active ||
          deviceStatus.state == DeviceSosState.acknowledged;
      if (deviceProvesLocalActive) {
        final localIncidentId =
            'device-runtime-sos:${deviceStatus.nodeId ?? identity.originatorNodeId ?? "local"}:${_sosLifecycle.current.generation}';
        final lifecycle = await _sosLifecycle.confirmActive(
          origin: SosLifecycleOrigin.connectedLocalDevice,
          localIncidentId: localIncidentId,
          triggerSource: payload.triggerSource,
          deviceId: identity.deviceId,
          nodeId: deviceStatus.nodeId ?? identity.originatorNodeId,
          hardwareId: identity.hardwareId,
          recoveryStatus: SosRecoveryStatus.restored,
        );
        return SosActivationResult(
          outcome: SosActivationOutcome.alreadyActiveRecovered,
          lifecycle: lifecycle,
          selectedPath: SosActivationPath.restoredActiveLifecycle,
          usedPaths: const <SosActivationPath>{
            SosActivationPath.restoredActiveLifecycle,
          },
        );
      }

      final lifecycle = await _sosLifecycle.requireRecovery(
        'E_SOS_ALREADY_ACTIVE_UNMATCHED',
        preserveLocalOwnership: false,
        backendIncidentId: authoritativeActive?.id,
        incident: authoritativeActive,
      );
      return SosActivationResult(
        outcome: SosActivationOutcome.alreadyActiveUnmatched,
        lifecycle: lifecycle,
      );
    }
  }

  static const int _alreadyActiveReconcileAttempts = 3;
  static const Duration _alreadyActiveReconcileDelay = Duration(
    milliseconds: 100,
  );

  Future<SosIncident?> _reconcileAlreadyActiveIncident() async {
    final repository = sosRepository;
    if (repository is! AuthoritativeActiveSosLookup) {
      return null;
    }
    final activeLookup = repository as AuthoritativeActiveSosLookup;
    for (
      var attempt = 0;
      attempt < _alreadyActiveReconcileAttempts;
      attempt += 1
    ) {
      try {
        final incident = await activeLookup.getAuthoritativeActiveSos();
        if (incident != null && _isOpenSosState(incident.state)) {
          return incident;
        }
      } catch (_) {
        // The trigger response remains authoritative: reconciliation failure
        // must not turn an already-active response into Ready.
      }
      if (attempt + 1 < _alreadyActiveReconcileAttempts) {
        await Future<void>.delayed(_alreadyActiveReconcileDelay);
      }
    }
    return null;
  }

  bool _matchesAttemptedAppSos({
    required SosLifecycleSnapshot attempted,
    required SosLifecycleSnapshot prior,
    required SosIncident incident,
  }) {
    return sosIncidentEvidenceMatchesLifecycle(attempted, incident) ||
        sosIncidentEvidenceMatchesLifecycle(prior, incident);
  }

  Set<SosActivationPath> _activationPathsForDelivery(
    SosDeliveryChannel? delivery,
  ) {
    return switch (delivery) {
      SosDeliveryChannel.backendAndDevice => const <SosActivationPath>{
        SosActivationPath.appBackend,
        SosActivationPath.connectedDevice,
      },
      SosDeliveryChannel.backendOnly => const <SosActivationPath>{
        SosActivationPath.appBackend,
      },
      SosDeliveryChannel.deviceOnly => const <SosActivationPath>{
        SosActivationPath.connectedDevice,
      },
      null => const <SosActivationPath>{},
    };
  }

  Future<SosIncident> _activatePublicSos(
    SosTriggerPayload payload, {
    bool skipDeviceAction = false,
    bool deviceAlreadyActive = false,
    bool allowDeviceRuntimeActiveShortCircuit = true,
    _PendingSosActivationOperation? pendingActivation,
  }) async {
    final originDecision = classifySosOrigin(
      triggerSource: payload.triggerSource,
      forBackendPublish: true,
    );
    if (originDecision.isExternalOnly) {
      _logSosOriginDecision(
        source: 'activate_public_sos',
        decision: originDecision,
      );
      _clearExternalOnlyPublicSosResidue(
        reason: 'external_payload_blocked_from_public_trigger',
      );
      throw const SosException(
        'E_EXTERNAL_SOS_NOT_LOCAL_ACTIONABLE',
        'External SOS payloads must use the remote relay backend handoff path.',
      );
    }
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
      if (pendingActivation == null) {
        _emitPublicSosState(
          SosState.sending,
          source: 'public_sos_backend_publish_start',
        );
      }
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
      if (_shouldBlockDeviceOriginPreSosBackendPublish(
        source: '_activatePublicSos',
        triggerSource: payload.triggerSource,
        cycleKey: _preSosSession?.cycleKey ?? _activeDeviceSosCycleKey,
        originatorNodeId:
            _preSosSession?.originatorNodeId ?? identity.originatorNodeId,
        packetId: _preSosSession?.packetId,
      )) {
        _emitPublicSosState(
          SosState.idle,
          source: 'device_pre_sos_cancel_blocked_backend_publish',
        );
        throw const SosException(
          'E_PRE_SOS_CANCELLED_BY_DEVICE',
          'Pre-SOS backend publish blocked by device cancel',
        );
      }
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
      if (pendingActivation != null) {
        if (!_commitPendingSosDispatch(pendingActivation)) {
          throw const SosException(
            'E_SOS_PENDING_ACTIVATION_CANCELLED',
            'Pending SOS activation was cancelled before dispatch.',
          );
        }
        _emitPublicSosState(
          SosState.sending,
          source: 'public_sos_backend_publish_start',
        );
      }
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
          osWidgetActivation: payload.osWidgetActivation,
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
        if (deliveryChannel == SosDeliveryChannel.deviceOnly) {
          const successfulDeliveryChannel = SosDeliveryChannel.deviceOnly;
          BleDebugRegistry.instance.recordEvent(
            'SOS_TRIGGER_FAILURE_BLOCKED_DEVICE_SUCCESS '
            'backendError=${backendError?.runtimeType.toString() ?? "none"} '
            'deviceAttempted=${deviceSync.attempted} '
            'deviceSucceeded=${deviceSync.succeeded}',
          );
          if (backendError != null) {
            BleDebugRegistry.instance.recordEvent(
              'SOS_TRIGGER_DEVICE_ONLY_BACKEND_FAILED_NON_FATAL '
              'errorType=${backendError.runtimeType} '
              'message=${_compactDiagnosticValue(_errorMessageFor(backendError))}',
            );
          }
          BleDebugRegistry.instance.recordEvent(
            'SOS_TRIGGER_DEVICE_ONLY_BACKEND_PENDING '
            'reason=backend_confirmation_unavailable '
            'deviceAttempted=${deviceSync.attempted}',
          );
          final incident = await _updateFallbackPublicSosIncident(
            state: SosState.sent,
            deliveryChannel: successfulDeliveryChannel,
          );
          BleDebugRegistry.instance.recordEvent(
            'SOS_TRIGGER_DEVICE_ONLY_SUCCESS '
            'incidentId=${incident.id} state=${incident.state.name} '
            'delivery=${incident.deliveryChannel?.name ?? "none"} '
            'provisional=true localDevice=true',
          );
          _recordPublicSosResult(
            incident: incident,
            deliveryChannel: successfulDeliveryChannel,
            fallbackState: SosState.sent,
          );
          _emitSosActiveNotificationIntent(incident);
          _registerPendingAppTriggeredSosBridge(incident);
          _publishSdkEvent(SOSTriggeredEvent(incident.id));
          BleDebugRegistry.instance.recordEvent(
            'SOS_TRIGGER_DEVICE_ONLY_SUCCESS_RETURNED '
            'incidentId=${incident.id} state=${incident.state.name}',
          );
          return incident;
        }
        BleDebugRegistry.instance.recordEvent(
          '[BACKGROUND_SOS] backend_required_failed '
          'deviceAvailable=${deviceSync.available} '
          'deviceAttempted=${deviceSync.attempted} '
          'deviceSucceeded=${deviceSync.succeeded} '
          'reason=no_backend_incident',
        );
        final alreadyActiveBackendError =
            backendError is SosException &&
            backendError.code == 'E_SOS_ALREADY_ACTIVE';
        if (!alreadyActiveBackendError) {
          _clearPendingAppTriggeredSosBridge(
            reason: 'public_trigger_backend_failed',
          );
          _clearAppOriginActiveSosBridge(
            reason: 'public_trigger_backend_failed',
          );
          _clearDeviceRuntimeSosOwnership(
            reason: 'public_trigger_backend_failed',
          );
          _setPublicSosFailure(
            source: 'public_sos_backend_failed',
            terminalReason: _publicSosFailureReasonForTriggerError(
              backendError: backendError,
              backendUnavailable: _isBackendUnavailableForTrigger(backendError),
              deviceAvailable: deviceSync.available,
            ),
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

  Future<SosIncident> _confirmPreSosInternal(
    SosTriggerPayload payload, {
    required _PendingSosActivationOperation? pendingActivation,
  }) async {
    final session = _preSosSession;
    var deviceStatus = await deviceSosController.getStatus();
    if (_shouldBlockPreSosActivationForDeviceTerminalCancel(
      session: session,
      deviceStatus: deviceStatus,
      source: 'confirm_pre_sos',
    )) {
      throw const SosException(
        'E_PRE_SOS_CANCELLED_BY_DEVICE',
        'Pre-SOS activation cancelled by device',
      );
    }
    if (session != null &&
        _isPreSosSessionExpired(session) &&
        deviceStatus.state == DeviceSosState.preConfirm) {
      deviceStatus = deviceSosController.settleExpiredPreConfirmCountdown(
        reason: 'sdk_pre_sos_deadline',
      );
      if (_shouldBlockPreSosActivationForDeviceTerminalCancel(
        session: session,
        deviceStatus: deviceStatus,
        source: 'confirm_pre_sos_after_settle',
      )) {
        throw const SosException(
          'E_PRE_SOS_CANCELLED_BY_DEVICE',
          'Pre-SOS activation cancelled by device',
        );
      }
    }
    final hasLocalSession = session != null;
    final devicePreConfirm = deviceStatus.state == DeviceSosState.preConfirm;
    final deviceAlreadyActive =
        deviceStatus.state == DeviceSosState.active ||
        deviceStatus.state == DeviceSosState.acknowledged;
    final deviceOriginatedPreConfirm =
        devicePreConfirm &&
        deviceStatus.triggerOrigin == DeviceSosTransitionSource.device;
    final appMirroredPreConfirm =
        devicePreConfirm &&
        deviceStatus.triggerOrigin == DeviceSosTransitionSource.app;

    if (!hasLocalSession && !devicePreConfirm) {
      return _activatePublicSos(payload, pendingActivation: pendingActivation);
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
          message: 'E_SOS_DEVICE_BACKEND_SYNC_CONFIRMED',
        );
      } else if (deviceAlreadyActive) {
        await _ensureBackendSosForDeviceOriginatedCycle(
          deviceStatus,
          triggerSource: 'ble_device_runtime_countdown_elapsed',
          message: 'E_SOS_DEVICE_BACKEND_SYNC_COUNTDOWN_ELAPSED',
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
        pendingActivation: pendingActivation,
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
        pendingActivation: pendingActivation,
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
          message: 'E_SOS_DEVICE_BACKEND_SYNC_CONFIRMED_FROM_APP',
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
        pendingActivation: pendingActivation,
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
        pendingActivation: pendingActivation,
      );
    }

    _clearPreSosSession(
      reason: 'public_pre_sos_confirmed_local_only',
      emitIdleState: false,
    );
    return _activatePublicSos(payload, pendingActivation: pendingActivation);
  }

  @override
  Future<SosIncident?> getCurrentSosIncident() async {
    final iosSnapshotState = await _mergeIosBleSosSnapshot(
      trigger: 'getCurrentSosIncident',
    );
    if (iosSnapshotState == SosState.idle) {
      return null;
    }
    if (_publicSosFallbackIncident != null) {
      if (_clearStaleCancelledRuntimeFallbackDuringAppArming(
        source: 'get_current_sos_fallback',
      )) {
        return null;
      }
      if (_isExternalOnlySosIncident(
        _publicSosFallbackIncident,
        source: 'get_current_sos_fallback',
      )) {
        _clearExternalOnlyPublicSosResidue(
          reason: 'get_current_sos_fallback_external_only',
        );
        return null;
      }
      final adoptedBackendIncident =
          await _adoptBackendIncidentForDeviceOnlyFallback(
            _publicSosFallbackIncident!,
          );
      if (adoptedBackendIncident != null) {
        return adoptedBackendIncident;
      }
      return _publicSosFallbackIncident;
    }
    DeviceSosStatus? deviceStatus;
    try {
      deviceStatus = await deviceSosController.getStatus();
      await _rehydrateDeviceSosPublicState(
        trigger: 'getCurrentSosIncident',
        deviceStatus: deviceStatus,
        emitResolvedState: false,
      );
    } catch (error) {
      if (kDebugMode) {
        safeSdkDebugPrint(
          '[BACKGROUND_SOS] get_current_sos_device_status_failed '
          'error=$error',
        );
      }
    }
    final repositoryIncident = await sosRepository.getCurrentIncident();
    if (_isExternalOnlySosIncident(
      repositoryIncident,
      source: 'get_current_sos_incident',
    )) {
      _clearExternalOnlyPublicSosResidue(
        reason: 'get_current_sos_incident_external_only',
      );
      if (_isOpenSosState(_publicSosState)) {
        _emitPublicSosState(
          SosState.idle,
          source: 'get_current_sos_incident:external_only',
        );
      }
      return null;
    }
    if (_isAcknowledgedTerminalSosIncident(repositoryIncident)) {
      return null;
    }
    final incident = _decorateIncidentWithPublicDeliveryChannel(
      repositoryIncident,
    );
    final rememberedIncident = _preserveActiveIncidentWhenMissing(
      incident,
      source: 'get_current_sos_incident',
    );
    final deviceDerivedIncident = deviceStatus == null
        ? null
        : _buildDeviceRuntimePublicSosIncident(deviceStatus);
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
    final resolvedDeviceStatus = deviceStatus;
    if (deviceDerivedIncident != null && resolvedDeviceStatus != null) {
      _rememberDeviceRuntimeSosOwnership(
        resolvedDeviceStatus,
        _deriveDeviceSosCycleKey(resolvedDeviceStatus),
      );
    }
    if (deviceDerivedIncident != null &&
        resolvedDeviceStatus != null &&
        _hasActiveDeviceRuntimeSosOwnership() &&
        rememberedIncident != null &&
        _isLocalAppSosIncidentId(rememberedIncident.id) &&
        !_isDeviceOwnedBackendIncidentId(rememberedIncident.id)) {
      _logSosRejectionThrottled(
        cycleId:
            _activeDeviceRuntimeCycleKey ??
            _deriveDeviceSosCycleKey(resolvedDeviceStatus) ??
            deviceDerivedIncident.id,
        source: 'get_current_sos_incident',
        reason: 'duplicate_device_owned_sos',
        message:
            'SOS_BACKEND_PUBLISH_SKIPPED reason=duplicate_owner '
            'owner=device source=get_current_sos_incident '
            'incomingIncident=${rememberedIncident.id} '
            'activeIncident=${deviceDerivedIncident.id}',
      );
      return deviceDerivedIncident;
    }
    if (rememberedIncident == null &&
        deviceStatus != null &&
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
  Future<SosIncidentProgress?> getCurrentSosIncidentProgress() async {
    return (await getCurrentSosIncident())?.progress;
  }

  @override
  Stream<SosIncidentProgress?> get currentSosIncidentProgressStream {
    return sosRepository
        .watchCurrentIncident()
        .map(
          (incident) =>
              _decorateIncidentWithPublicDeliveryChannel(incident)?.progress,
        )
        .distinct(_sameSosIncidentProgress);
  }

  bool _sameSosIncidentProgress(
    SosIncidentProgress? previous,
    SosIncidentProgress? next,
  ) {
    if (identical(previous, next)) {
      return true;
    }
    if (previous == null || next == null) {
      return false;
    }
    return _sosIncidentProgressSignature(previous) ==
        _sosIncidentProgressSignature(next);
  }

  String _sosIncidentProgressSignature(SosIncidentProgress progress) {
    return <String>[
      progress.incidentId,
      progress.revision.toString(),
      progress.isTerminal.toString(),
      progress.isUsingCachedData.toString(),
      progress.provisionalIncidentId ?? '',
      progress.canonicalIncidentId ?? '',
      progress.preservedLocalOwnership.toString(),
      progress.originKind.name,
      progress.actionability.name,
      progress.displaySurface.name,
      for (final step in progress.steps)
        <String>[
          step.type.name,
          step.state.name,
          step.updatedAt?.toUtc().toIso8601String() ?? '',
          step.totalTargets?.toString() ?? '',
          step.successfulTargets?.toString() ?? '',
          step.failedTargets?.toString() ?? '',
          step.detailCode ?? '',
        ].join(':'),
    ].join('|');
  }

  @override
  Future<SosTerminalReason?> getCurrentSosTerminalReason() async {
    if (_lastPublicSosTerminalReason != null) {
      return _lastPublicSosTerminalReason;
    }
    final incident = await getCurrentSosIncident();
    return incident?.terminalReason;
  }

  @override
  Future<SosIncident> cancelSos() async {
    final authoritativeLifecycle = _sosLifecycle.current;
    if (authoritativeLifecycle.isTerminal) {
      final terminalState =
          authoritativeLifecycle.stage == SosLifecycleStage.resolved
          ? SosState.resolved
          : SosState.cancelled;
      final repositoryIncident = await sosRepository.getCurrentIncident();
      final incident =
          authoritativeLifecycle.incident ??
          (repositoryIncident != null &&
                  (repositoryIncident.state == SosState.cancelled ||
                      repositoryIncident.state == SosState.resolved)
              ? repositoryIncident
              : null);
      BleDebugRegistry.instance.recordEvent(
        'SOS_MANUAL_CANCEL_NOOP reason=authoritative_terminal '
        'terminal=${terminalState.name}',
      );
      return (incident ??
              SosIncident(
                id:
                    authoritativeLifecycle.backendIncidentId ??
                    authoritativeLifecycle.localIncidentId ??
                    authoritativeLifecycle.lifecycleId,
                state: terminalState,
                createdAt:
                    authoritativeLifecycle.activationTimestamp ??
                    DateTime.now().toUtc(),
                isBackendConfirmed:
                    authoritativeLifecycle.backendIncidentId != null,
              ))
          .copyWith(state: terminalState);
    }
    _publicSosActionInFlight = true;
    final previousClosureInFlight = _publicSosClosureInFlight;
    _publicSosClosureInFlight = _SosClosureIntent.cancel;
    try {
      _lastPublicSosTerminalReason = SosTerminalReason.cancelledByUser;
      final deviceStatus = await deviceSosController.getStatus();
      final deviceAlreadyActive =
          deviceStatus.state == DeviceSosState.active ||
          deviceStatus.state == DeviceSosState.acknowledged;
      if ((_hasActivePreSosSession && !deviceAlreadyActive) ||
          (_publicSosState == SosState.arming && !deviceAlreadyActive) ||
          (deviceStatus.state == DeviceSosState.preConfirm &&
              !_isOpenSosState(_publicSosState))) {
        final preCancelPublicState = _publicSosState;
        final preCancelHasOpenBackendIncident =
            _hasBackendVisibleSosIncident(_lastKnownActiveSosIncident) ||
            _hasBackendVisibleSosIncident(_publicSosFallbackIncident);
        final preCancelRequiresBackendCancel =
            preCancelPublicState != SosState.arming &&
            (_isOpenSosState(preCancelPublicState) ||
                preCancelHasOpenBackendIncident);
        BleDebugRegistry.instance.recordEvent(
          '[SOS_CANCEL] action=pre_sos_branch '
          'publicState=${preCancelPublicState.name} '
          'deviceState=${deviceStatus.state.name} '
          'hasActivePreSos=$_hasActivePreSosSession '
          'hasOpenBackendIncident=$preCancelHasOpenBackendIncident '
          'requiresBackendCancel=$preCancelRequiresBackendCancel',
        );
        await cancelPreSos();
        // If the public SOS was already published to the backend (e.g. app
        // pressed SOS over HTTP and the device started a separate local
        // pre-SOS countdown right after), the synthetic pre-sos cancel above
        // only cleared the device countdown — the backend incident would
        // still be "active". Cancel it explicitly so the row converges.
        if (preCancelRequiresBackendCancel || preCancelHasOpenBackendIncident) {
          try {
            final backendIncident = await sosRepository.cancelSos();
            if (backendIncident.state != SosState.cancelled &&
                backendIncident.state != SosState.resolved) {
              return backendIncident;
            }
            _applyTerminalSosSuppression(
              reason: 'public_cancel_after_pre_sos',
              terminalState: SosState.cancelled,
            );
            await _clearSosNotificationsSafely(
              reason: 'public_cancel_after_pre_sos',
            );
            final cancelledIncident = backendIncident.copyWith(
              terminalReason:
                  _lastPublicSosTerminalReason ==
                      SosTerminalReason.deviceAckTimeout
                  ? SosTerminalReason.deviceAckTimeout
                  : SosTerminalReason.cancelledByUser,
            );
            _clearCurrentPublicSosAfterCancellation(cancelledIncident);
            _publishCancelledSosEventIfNeeded(cancelledIncident);
            return cancelledIncident;
          } catch (error) {
            BleDebugRegistry.instance.recordEvent(
              'Public SOS backend cancel during pre_sos cancel failed -> error=$error',
            );
            if (preCancelRequiresBackendCancel) {
              rethrow;
            }
          }
        }
        return SosIncident(
          id: 'pre-sos-cancelled:${DateTime.now().toUtc().microsecondsSinceEpoch}',
          state: SosState.cancelled,
          createdAt: DateTime.now().toUtc(),
          triggerSource: 'pre_sos_cancel',
          terminalReason: SosTerminalReason.cancelledByUser,
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
      _lastPublicSosTerminalReason = SosTerminalReason.cancelledByUser;
      final fallbackDeliveryChannel =
          _publicSosFallbackIncident?.deliveryChannel;
      final cancelCapabilitySnapshot = _computeCurrentSosCapabilitySnapshot(
        reason: 'cancel_sos_start',
      );
      _logAppSosRouteDecision(
        action: 'cancel',
        capabilitySnapshot: cancelCapabilitySnapshot,
      );
      final cancellationDeviceSnapshot = _captureTerminalDeviceSnapshot(
        reason: 'public_cancel_acceptance',
      );
      final cancellationLifecycle = _sosLifecycle.current;
      if (cancellationLifecycle.isOpen &&
          cancellationLifecycle.stage != SosLifecycleStage.cancelling) {
        await _sosLifecycle.beginCancellation();
      }
      _emitPublicSosState(
        SosState.cancelRequested,
        source: 'public_cancel_logical_terminal',
      );
      _setSosDeviceMirrorState(
        _SosDeviceMirrorState.pendingCancel,
        source: 'public_cancel_device_mirror_pending',
      );
      _armTerminalConvergenceFence(
        generation: cancellationLifecycle.generation,
        terminalState: SosState.cancelled,
        connection: cancellationDeviceSnapshot.connection,
        deviceSos: cancellationDeviceSnapshot.deviceSos,
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_CANCEL_LOGICAL_TERMINAL '
        'incidentId=${cancellableIncident?.id ?? "none"} '
        'generation=${_sosLifecycle.current.generation} '
        'incidentState=${_publicSosState.name}',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_CANCEL_DEVICE_MIRROR '
        'incidentId=${cancellableIncident?.id ?? "none"} '
        'generation=${_sosLifecycle.current.generation} '
        'deviceMirrorState=${_sosDeviceMirrorState.name} '
        'command=SOS_CANCEL_0x04 action=dispatch',
      );
      final deviceSync = await _attemptPublicSosDeviceAction(
        action: 'cancel',
        capturedDeviceConnection: cancellationDeviceSnapshot.connection,
        shouldRun: (status) => _shouldCloseDeviceForPublicSos(
          status,
          activeIncident: activeIncident,
        ),
        operation: () => _closeDeviceSos(
          intent: _SosClosureIntent.cancel,
          syncBackendForDeviceOriginatedCycle: false,
          capturedDeviceConnection: cancellationDeviceSnapshot.connection,
        ),
        refreshRuntimeStatus: true,
      );
      final deviceMirrorSynchronized =
          !deviceSync.available || deviceSync.succeeded;
      _setSosDeviceMirrorState(
        deviceMirrorSynchronized
            ? _SosDeviceMirrorState.synchronized
            : _SosDeviceMirrorState.failed,
        source: !deviceSync.available
            ? 'public_cancel_no_physical_mirror_required'
            : deviceSync.succeeded
            ? 'public_cancel_device_mirror_E2'
            : 'public_cancel_device_mirror_failed',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_CANCEL_DEVICE_MIRROR '
        'incidentId=${cancellableIncident?.id ?? "none"} '
        'generation=${_sosLifecycle.current.generation} '
        'deviceMirrorState=${_sosDeviceMirrorState.name} '
        'command=SOS_CANCEL_0x04 action=result '
        'success=$deviceMirrorSynchronized attempted=${deviceSync.attempted}',
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

      final deliveryChannel =
          _resolveSuccessfulSosDeliveryChannel(
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
      final deviceStatusAfterCancel = await deviceSosController.getStatus();
      final canSettleLocally = _canConfirmLocalCancelWithoutBackendProof(
        incident: cancellableIncident ?? backendIncident,
        deviceStatus: deviceStatusAfterCancel,
        lifecycle: _sosLifecycle.current,
        deviceCancelSucceeded: deviceSync.succeeded,
      );
      if (deliveryChannel == null) {
        if (canSettleLocally) {
          return _settlePublicCancelLocally(
            incident: cancellableIncident,
            deviceSucceeded: deviceSync.succeeded,
            backendError: backendError,
          );
        }
        if (backendError != null) {
          throw backendError;
        }
        throw const SosException(
          'E_SOS_CANCEL_NOT_ALLOWED',
          'E_SOS_CANCEL_NOT_ALLOWED',
        );
      }

      final backendTerminal =
          backendIncident != null &&
          (backendIncident.state == SosState.cancelled ||
              backendIncident.state == SosState.resolved);
      final incident = backendIncident != null
          ? backendIncident.copyWith(
              deliveryChannel: deliveryChannel,
              terminalReason: backendTerminal
                  ? (_lastPublicSosTerminalReason ==
                            SosTerminalReason.deviceAckTimeout
                        ? SosTerminalReason.deviceAckTimeout
                        : SosTerminalReason.cancelledByUser)
                  : backendIncident.terminalReason,
            )
          : await _updateFallbackPublicSosIncident(
              state: SosState.cancelRequested,
              deliveryChannel: deliveryChannel,
            );
      _recordPublicSosResult(
        incident: incident,
        deliveryChannel: deliveryChannel,
        fallbackState: backendIncident == null
            ? SosState.cancelRequested
            : null,
      );
      if (!backendTerminal && canSettleLocally) {
        return _settlePublicCancelLocally(
          incident: incident,
          deviceSucceeded: deviceSync.succeeded,
          backendError: backendError,
        );
      }
      if (backendTerminal) {
        _applyTerminalSosSuppression(
          reason: 'public_cancel_completed',
          terminalState: SosState.cancelled,
        );
        await _clearSosNotificationsSafely(reason: 'public_cancel_completed');
        _clearCurrentPublicSosAfterCancellation(incident);
        _emitSosTerminalNotificationIntent(
          incident,
          type: EixamNotificationIntentType.sosCancelled,
          severity: EixamNotificationIntentSeverity.info,
          titleKey: 'notification.sos.cancelled.title',
          bodyKey: 'notification.sos.cancelled.body',
        );
        _clearPendingAppTriggeredSosBridge(reason: 'public_cancel_completed');
        _publishCancelledSosEventIfNeeded(incident);
        await _rehydrateSosRuntimeState(
          trigger: 'local_cancel_success',
          emitPublicState: false,
        );
      }
      return incident;
    } finally {
      _publicSosClosureInFlight = previousClosureInFlight;
      _publicSosActionInFlight = false;
    }
  }

  @override
  Future<SosCancellationResult> cancelSosAuthoritatively() async {
    final current = _sosLifecycle.current;
    if (current.stage == SosLifecycleStage.cancelled ||
        current.stage == SosLifecycleStage.resolved ||
        current.stage == SosLifecycleStage.idle) {
      return SosCancellationResult(
        outcome: SosCancellationOutcome.noActionableLifecycle,
        lifecycle: current,
        incident: current.incident,
      );
    }

    final pending = _pendingSosActivation;
    final pendingStage =
        current.stage == SosLifecycleStage.arming ||
        current.stage == SosLifecycleStage.activating;
    if (pendingStage &&
        pending != null &&
        pending.generation == current.generation &&
        !pending.dispatchCommitted) {
      pending.cancelled = true;
      _pendingSosActivationRevision += 1;
      final taskCancelled = _preSosSession != null;
      _clearPreSosSession(
        reason: 'authoritative_pending_activation_cancelled',
        emitIdleState: true,
      );
      try {
        await cancelPreSos();
      } catch (_) {
        // The pending operation is already invalidated. A mirrored device
        // cleanup failure cannot resurrect it or turn this into backend cancel.
      }
      final terminal = await _sosLifecycle.confirmTerminal(
        stage: SosLifecycleStage.cancelled,
      );
      if (identical(_pendingSosActivation, pending)) {
        _pendingSosActivation = null;
      }
      _logPendingSosActivationCancel(
        operation: pending,
        stageBefore: current.stage,
        dispatchCommitted: false,
        taskCancelled: taskCancelled,
        terminalAfter: terminal.stage,
        result: SosCancellationOutcome.pendingActivationCancelled,
        source: 'cancelSosAuthoritatively',
      );
      return SosCancellationResult(
        outcome: SosCancellationOutcome.pendingActivationCancelled,
        lifecycle: terminal,
      );
    }

    if (pendingStage && pending != null && pending.dispatchCommitted) {
      pending.cancellationRequested = true;
      await _sosLifecycle.beginCancellation();
      try {
        await pending.dispatchResult.future;
      } catch (_) {
        // The active cancellation flow below reports the authoritative result.
      }
      final result = await _cancelActiveSosAuthoritatively(
        cancellationAlreadyBegan: true,
      );
      if (identical(_pendingSosActivation, pending)) {
        _pendingSosActivation = null;
      }
      return result;
    }

    return _cancelActiveSosAuthoritatively();
  }

  Future<SosCancellationResult> _cancelActiveSosAuthoritatively({
    bool cancellationAlreadyBegan = false,
  }) async {
    if (!cancellationAlreadyBegan) {
      await _sosLifecycle.beginCancellation();
    }
    final cancellationAttempt = _sosLifecycle.current;
    try {
      final incident = await cancelSos();
      if (!_sameSosGeneration(_sosLifecycle.current, cancellationAttempt)) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_CANCELLATION_SETTLEMENT_IGNORED reason=newer_lifecycle',
        );
        return SosCancellationResult(
          outcome: SosCancellationOutcome.noActionableLifecycle,
          lifecycle: _sosLifecycle.current,
          incident: incident,
        );
      }
      final channel = incident.deliveryChannel;
      final backendConfirmed =
          incident.state == SosState.cancelled ||
          incident.state == SosState.resolved;
      final deviceConfirmed =
          channel == SosDeliveryChannel.deviceOnly ||
          channel == SosDeliveryChannel.backendAndDevice;
      final accepted = await _sosLifecycle.cancellationAccepted(
        backendConfirmed: backendConfirmed,
        deviceConfirmed: deviceConfirmed,
      );
      if (!backendConfirmed) {
        final deviceStatus = await deviceSosController.getStatus();
        if (_canConfirmLocalCancelWithoutBackendProof(
          incident: incident,
          deviceStatus: deviceStatus,
          lifecycle: accepted,
          deviceCancelSucceeded: deviceConfirmed,
        )) {
          final terminal = await _sosLifecycle.confirmTerminal(
            stage: SosLifecycleStage.cancelled,
            incident: incident.copyWith(state: SosState.cancelled),
          );
          return SosCancellationResult(
            outcome: SosCancellationOutcome.activeCancellationConfirmed,
            lifecycle: terminal,
            incident: incident,
          );
        }
        return SosCancellationResult(
          outcome: SosCancellationOutcome.cancellationPending,
          lifecycle: accepted,
          incident: incident,
        );
      }
      final terminal = await _sosLifecycle.confirmTerminal(
        stage: incident.state == SosState.resolved
            ? SosLifecycleStage.resolved
            : SosLifecycleStage.cancelled,
        incident: incident,
      );
      await _clearPreSosSessionDurably(
        reason: 'authoritative_active_cancellation_confirmed',
        emitIdleState: false,
      );
      return SosCancellationResult(
        outcome: SosCancellationOutcome.activeCancellationConfirmed,
        lifecycle: terminal,
        incident: incident,
      );
    } catch (error) {
      final converged = await _settleCancellationFromAuthoritativeAbsence(
        cancellationAttempt: cancellationAttempt,
      );
      if (converged != null) {
        return converged;
      }
      if (!_sameSosGeneration(_sosLifecycle.current, cancellationAttempt)) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_CANCELLATION_FAILURE_IGNORED reason=newer_lifecycle',
        );
        return SosCancellationResult(
          outcome: SosCancellationOutcome.noActionableLifecycle,
          lifecycle: _sosLifecycle.current,
        );
      }
      final incident =
          await sosRepository.getCurrentIncident() ??
          _lastKnownActiveSosIncident ??
          _sosLifecycle.current.incident;
      final deviceStatus = await deviceSosController.getStatus();
      if (_canConfirmLocalCancelWithoutBackendProof(
        incident: incident,
        deviceStatus: deviceStatus,
        lifecycle: _sosLifecycle.current,
        deviceCancelSucceeded: _isDeviceSosCycleClosed(deviceStatus.state),
      )) {
        BleDebugRegistry.instance.recordEvent(
          'Authoritative SOS cancel settled locally after transport failure -> '
          'incidentId=${incident?.id ?? "none"} error=$error',
        );
        final cancelled = incident?.copyWith(
          state: SosState.cancelled,
          terminalReason: SosTerminalReason.cancelledByUser,
        );
        final terminal = await _sosLifecycle.confirmTerminal(
          stage: SosLifecycleStage.cancelled,
          incident: cancelled,
        );
        return SosCancellationResult(
          outcome: SosCancellationOutcome.activeCancellationConfirmed,
          lifecycle: terminal,
          incident: cancelled,
        );
      }
      final lifecycle = await _sosLifecycle.cancellationFailed(
        error is EixamSdkException ? error.code : 'E_SOS_CANCELLATION_FAILED',
      );
      return SosCancellationResult(
        outcome: SosCancellationOutcome.cancellationFailed,
        lifecycle: lifecycle,
      );
    }
  }

  Future<SosCancellationResult?> _settleCancellationFromAuthoritativeAbsence({
    required SosLifecycleSnapshot cancellationAttempt,
  }) async {
    final reconciliation = await _rehydrateSosRuntimeState(
      trigger: 'cancel_failure_authoritative_reconciliation',
      emitPublicState: true,
      terminalHint: SosState.cancelled,
      expectedLifecycle: cancellationAttempt,
    );
    if (reconciliation?.outcome != SosRuntimeRehydrationOutcome.clearedToIdle) {
      return null;
    }
    if (!_sameSosGeneration(_sosLifecycle.current, cancellationAttempt)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_CANCELLATION_ABSENCE_IGNORED reason=newer_lifecycle',
      );
      return null;
    }
    var lifecycle = _sosLifecycle.current;
    if (!lifecycle.isTerminal) {
      lifecycle = await _sosLifecycle.confirmTerminal(
        stage: SosLifecycleStage.cancelled,
      );
    }
    await _clearPreSosSessionDurably(
      reason: 'cancel_failure_authoritative_absence',
      emitIdleState: false,
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_CANCELLATION_CONVERGED reason=authenticated_backend_absence',
    );
    return SosCancellationResult(
      outcome: SosCancellationOutcome.activeCancellationConfirmed,
      lifecycle: lifecycle,
      incident: lifecycle.incident,
    );
  }

  Future<void> _reconcileAuthoritativeLifecycleFromDeviceStatus(
    DeviceSosStatus status,
  ) async {
    final lifecycle = _sosLifecycle.current;
    final terminalDeviceState = _isDeviceSosCycleClosed(status.state);
    final eventAt = terminalDeviceState
        ? status.updatedAt
        : status.lastPacketAt ?? status.updatedAt;
    final activationAt = lifecycle.activationTimestamp;
    if (activationAt != null && eventAt.isBefore(activationAt)) {
      return;
    }
    if (lifecycle.nodeId != null &&
        status.nodeId != null &&
        lifecycle.nodeId != status.nodeId) {
      return;
    }
    final device = _lastDeviceStatus;
    if (status.state == DeviceSosState.active ||
        status.state == DeviceSosState.acknowledged) {
      final repositoryIncident = await sosRepository.getCurrentIncident();
      final currentLifecycle = _sosLifecycle.current;
      if (!currentLifecycle.isOpen) {
        return;
      }
      final confirmedCanonicalIncident =
          currentLifecycle.incident?.isBackendConfirmed == true
          ? currentLifecycle.incident
          : null;
      final matchingRepositoryIncident =
          repositoryIncident != null &&
              currentLifecycle.isOpen &&
              sosIncidentEvidenceMatchesLifecycle(
                currentLifecycle,
                repositoryIncident,
              )
          ? repositoryIncident
          : null;
      // This is the final ACTIVE publication boundary for BLE callbacks. Once
      // this generation owns canonical Backend evidence, a later local/device
      // observation may confirm the device leg but cannot replace that
      // incident with an unconfirmed projection.
      final incident = confirmedCanonicalIncident ?? matchingRepositoryIncident;
      final localIncidentId =
          currentLifecycle.localIncidentId ??
          incident?.id ??
          'device-runtime-sos:${status.nodeId ?? device?.nodeId ?? "local"}:${currentLifecycle.generation == 0 ? _deviceRuntimeLocalCycleSequence : currentLifecycle.generation}';
      await _sosLifecycle.confirmActive(
        origin: status.triggerOrigin == DeviceSosTransitionSource.app
            ? SosLifecycleOrigin.localApp
            : SosLifecycleOrigin.connectedLocalDevice,
        localIncidentId: localIncidentId,
        backendIncidentId:
            incident == null || _isLocalAppSosIncidentId(incident.id)
            ? currentLifecycle.backendIncidentId
            : incident.id,
        triggerSource:
            incident?.triggerSource ?? currentLifecycle.triggerSource,
        deviceId: incident?.deviceId ?? device?.deviceId,
        nodeId: status.nodeId ?? incident?.originatorNodeId ?? device?.nodeId,
        hardwareId:
            currentLifecycle.hardwareId ??
            _physicalHardwareIdForStatus(device) ??
            incident?.hardwareId,
        incident: incident,
        recoveryStatus:
            currentLifecycle.stage == SosLifecycleStage.recoveryRequired
            ? SosRecoveryStatus.restored
            : currentLifecycle.recoveryStatus,
      );
      return;
    }
    if (!_isDeviceSosCycleClosed(status.state) || !lifecycle.isOpen) {
      return;
    }
    final repositoryState = await sosRepository.getSosState();
    final repositoryIncident = await sosRepository.getCurrentIncident();
    final correlatedTerminal =
        repositoryIncident != null &&
        sosIncidentEvidenceMatchesLifecycle(lifecycle, repositoryIncident);
    final ownDeviceUserCancel = _isOwnDeviceUserDeactivatedEvent(status);
    if ((repositoryState == SosState.cancelled &&
            (correlatedTerminal || ownDeviceUserCancel)) ||
        (ownDeviceUserCancel &&
            repositoryState != SosState.resolved &&
            repositoryState != SosState.cancelled)) {
      if (lifecycle.stage != SosLifecycleStage.cancelling &&
          ownDeviceUserCancel) {
        await _sosLifecycle.beginCancellation();
        await _sosLifecycle.cancellationAccepted(
          backendConfirmed: repositoryState == SosState.cancelled,
          deviceConfirmed: true,
        );
      }
      await _sosLifecycle.confirmTerminal(
        stage: SosLifecycleStage.cancelled,
        incident: repositoryIncident,
      );
    } else if (repositoryState == SosState.resolved &&
        (correlatedTerminal || ownDeviceUserCancel)) {
      await _sosLifecycle.confirmTerminal(
        stage: SosLifecycleStage.resolved,
        incident: repositoryIncident,
      );
    } else if (lifecycle.stage == SosLifecycleStage.cancelling) {
      await _sosLifecycle.cancellationAccepted(
        backendConfirmed: false,
        deviceConfirmed: true,
      );
    }
  }

  bool _isOwnDeviceUserDeactivatedEvent(DeviceSosStatus status) {
    return status.derivedFromBlePacket &&
        status.lastOpcode == EixamBleProtocol.sosEventUserDeactivatedOpcode &&
        _isDeviceSosCycleClosed(status.state);
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
      final lifecycleAtResolveStart = _sosLifecycle.current;
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
          'E_SOS_RESOLVE_NOT_ALLOWED',
        );
      }

      if (backendIncident == null) {
        if (backendError != null) throw backendError;
        return;
      }
      final backendTerminal =
          backendIncident.state == SosState.cancelled ||
          backendIncident.state == SosState.resolved;
      final incident = backendIncident.copyWith(
        deliveryChannel: deliveryChannel,
        terminalReason: backendTerminal
            ? SosTerminalReason.unknown
            : backendIncident.terminalReason,
      );
      _recordPublicSosResult(
        incident: incident,
        deliveryChannel: deliveryChannel,
      );
      if (!backendTerminal) return;
      final terminalState = incident.state == SosState.cancelled
          ? SosState.cancelled
          : SosState.resolved;
      final lifecycle = _sosLifecycle.current;
      if (lifecycle.isOpen &&
          lifecycle.lifecycleId == lifecycleAtResolveStart.lifecycleId &&
          lifecycle.generation == lifecycleAtResolveStart.generation &&
          sosIncidentEvidenceMatchesLifecycle(lifecycle, incident)) {
        await _sosLifecycle.confirmTerminal(
          stage: terminalState == SosState.cancelled
              ? SosLifecycleStage.cancelled
              : SosLifecycleStage.resolved,
          incident: incident,
        );
      }
      await _clearPreSosSessionDurably(
        reason: 'public_resolve_completed',
        emitIdleState: false,
      );
      _applyTerminalSosSuppression(
        reason: 'public_resolve_completed',
        terminalState: terminalState,
      );
      await _clearSosNotificationsSafely(reason: 'public_resolve_completed');
      _emitSosTerminalNotificationIntent(
        incident,
        type: terminalState == SosState.cancelled
            ? EixamNotificationIntentType.sosCancelled
            : EixamNotificationIntentType.sosResolved,
        severity: terminalState == SosState.cancelled
            ? EixamNotificationIntentSeverity.info
            : EixamNotificationIntentSeverity.success,
        titleKey: terminalState == SosState.cancelled
            ? 'notification.sos.cancelled.title'
            : 'notification.sos.resolved.title',
        bodyKey: terminalState == SosState.cancelled
            ? 'notification.sos.cancelled.body'
            : 'notification.sos.resolved.body',
      );
      _clearPendingAppTriggeredSosBridge(reason: 'public_resolve_completed');
      await _rehydrateSosRuntimeState(
        trigger: 'local_resolve_success',
        emitPublicState: false,
      );
    } finally {
      _publicSosClosureInFlight = previousClosureInFlight;
      _publicSosActionInFlight = false;
    }
  }

  @override
  Future<SosState> acknowledgeSosSummary() async {
    final repositoryIncident = await sosRepository.getCurrentIncident();
    final terminalIncident =
        _publicSosFallbackIncident ??
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
      final location = await _resolveLocation(
        useCase: SdkResolvedLocationUseCase.emergencyBackend,
      );
      return location?.toTrackingPosition();
    } catch (_) {
      // Best-effort snapshot: SOS should continue even if location lookup fails.
    }
    return null;
  }

  Future<SdkResolvedLocation?> _resolveLocation({
    required SdkResolvedLocationUseCase useCase,
    SdkResolvedLocation? remoteRelayLocation,
  }) async {
    final location = await _resolvedLocationResolver.resolve(
      useCase: useCase,
      remoteRelayLocation: remoteRelayLocation,
      backendSnapshot: useCase == SdkResolvedLocationUseCase.uiPreview
          ? _resolvedLocationFromIncident(_lastKnownActiveSosIncident)
          : null,
      cachedFallback: useCase == SdkResolvedLocationUseCase.uiPreview
          ? _lastResolvedLocation?.copyWith(
              source: SdkLocationSource.cachedFallback,
              authoritativeForBackend: false,
            )
          : null,
    );
    _rememberResolvedLocation(location);
    return location;
  }

  void _rememberResolvedLocation(SdkResolvedLocation? location) {
    if (location == null || !location.isValid) {
      return;
    }
    _lastResolvedLocation = location;
    if (!_resolvedLocationController.isClosed) {
      _resolvedLocationController.add(location);
    }
    if (location.authoritativeForBackend &&
        (location.source == SdkLocationSource.connectedDevice ||
            location.source == SdkLocationSource.phone)) {
      unawaited(_persistResolvedLocationForNative(location));
    } else {
      LocationDebugLog.resolved(
        flow: 'resolver_selected',
        location: location,
        accepted: true,
        persisted: false,
        note: 'not_persisted_for_native',
      );
    }
  }

  Future<void> _warmResolvedLocationAfterPermissionGrant({
    required String reason,
  }) async {
    if (_lastResolvedLocation != null && _lastResolvedLocation!.isValid) {
      return;
    }
    try {
      final permissions = await permissionsRepository.getPermissionState();
      if (!permissions.hasLocationAccess) {
        return;
      }
      final location = await _resolveLocation(
        useCase: SdkResolvedLocationUseCase.uiPreview,
      );
      BleDebugRegistry.instance.recordEvent(
        '[LOCATION_WARM] reason=$reason '
        'resolved=${location != null} '
        'source=${location?.source.name ?? 'none'}',
      );
      if (location != null) {
        final capability = await _buildSosCapability(
          reason: 'location_warm:$reason',
        );
        if (!_sosCapabilityController.isClosed) {
          _sosCapabilityController.add(capability);
        }
      }
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[LOCATION_WARM] reason=$reason failed error=$error',
      );
    }
  }

  Future<void> _persistResolvedLocationForNative(
    SdkResolvedLocation location,
  ) async {
    try {
      final payload = location.toJson()
        ..['persistedAt'] = DateTime.now().toUtc().toIso8601String()
        ..['resolvedLocationHandoffVersion'] =
            SharedPrefsSdkStore.resolvedLocationHandoffVersion
        ..['geoDecoderVersion'] =
            SharedPrefsSdkStore.resolvedLocationGeoDecoderVersion;
      await _localStore.saveJson(
        SharedPrefsSdkStore.resolvedLocationKey,
        payload,
      );
      LocationDebugLog.resolved(
        flow: 'resolver_selected',
        location: location,
        accepted: true,
        persisted: true,
      );
    } catch (_) {}
  }

  SdkResolvedLocation? _resolvedLocationFromIncident(SosIncident? incident) {
    final position = incident?.positionSnapshot;
    if (position == null) {
      return null;
    }
    return SdkResolvedLocation.backendSnapshot(
      position: position,
      isFresh: !position.isStale,
    );
  }

  SdkTelemetryPayload _telemetryPayloadFromResolvedLocation(
    SdkResolvedLocation location,
  ) {
    return SdkTelemetryPayload(
      timestamp: location.timestamp.toUtc(),
      latitude: location.latitude,
      longitude: location.longitude,
      altitude: location.altitudeMeters ?? 0,
      deviceId: location.deviceId,
      hardwareId: location.hardwareId,
      nodeId: location.nodeId,
      identitySource: switch (location.source) {
        SdkLocationSource.connectedDevice => 'ble_node',
        SdkLocationSource.phone => 'app',
        SdkLocationSource.remoteRelayDevice => 'remote_relay',
        SdkLocationSource.backendSnapshot => 'backend_snapshot',
        SdkLocationSource.cachedFallback => 'cached_fallback',
        SdkLocationSource.unknown => null,
      },
    );
  }

  Future<String?> _loadBackendHardwareIdForOperationalPayloads({
    DeviceStatus? runtimeStatus,
  }) async {
    try {
      final status =
          runtimeStatus ??
          _lastDeviceStatus ??
          await deviceRepository.getDeviceStatus();
      _lastDeviceStatus = status;
      if (!status.paired && !status.connected && !status.activated) {
        return null;
      }
      return _physicalHardwareIdForStatus(status);
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
        'hardwareId=${_physicalHardwareIdForStatus(status) ?? "-"} '
        'identitySource=ble_node source=local_sos owner=device',
      );
      return _OperationalSosIdentity(
        deviceId: originatorNodeId.toString(),
        hardwareId: _physicalHardwareIdForStatus(status),
        originatorNodeId: originatorNodeId,
      );
    }
    final hardwareId = status.connected
        ? _physicalHardwareIdForStatus(status)
        : null;
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_IDENTITY_RESOLVED deviceId=none '
      'originatorNodeId=none '
      'hardwareId=${hardwareId ?? "-"} '
      'identitySource=${hardwareId == null ? "app" : "device_hardware_pending"} '
      'source=local_sos owner=app',
    );
    return _OperationalSosIdentity(deviceId: null, hardwareId: hardwareId);
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

  String _sosFingerprintDiagnosticMarker(String? fingerprint) {
    final normalized = fingerprint?.trim();
    if (normalized == null || normalized.isEmpty) {
      return 'none';
    }
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  SdkDeviceBatterySnapshot? _buildDeviceBatterySnapshot(DeviceStatus? status) {
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
      deviceCoverageSnapshot:
          payload.deviceCoverageSnapshot ??
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
    _CapturedPhysicalDeviceConnection? capturedDeviceConnection,
  }) async {
    final runtimeStatus = capturedDeviceConnection == null
        ? await _loadRuntimeReadyDeviceStatusForSosSync(
            action: action,
            refreshRuntimeStatus: refreshRuntimeStatus,
          )
        : capturedDeviceConnection.devicePresent &&
              _capturedPhysicalDeviceConnectionIsCurrent(
                capturedDeviceConnection,
              )
        ? capturedDeviceConnection.device
        : null;
    if (runtimeStatus == null) {
      return _PublicSosDeviceAttempt(
        available: capturedDeviceConnection?.devicePresent ?? false,
        attempted: false,
        succeeded: false,
      );
    }

    final deviceSosStatus = await deviceSosController.getStatus();
    BleDebugRegistry.instance.recordEvent(
      'Public SOS device sync evaluated -> action=$action commandPathAvailable=true deviceId=${runtimeStatus.nodeId?.toString() ?? "-"} nodeId=${runtimeStatus.nodeId?.toString() ?? "-"} hardwareId=${runtimeStatus.deviceId} state=${deviceSosStatus.state.name} origin=${deviceSosStatus.triggerOrigin.name} optimistic=${deviceSosStatus.optimistic} derivedFromBle=${deviceSosStatus.derivedFromBlePacket}',
    );
    if (!shouldRun(deviceSosStatus)) {
      final alreadyClosed =
          action == 'cancel' &&
          (deviceSosStatus.state == DeviceSosState.inactive ||
              deviceSosStatus.state == DeviceSosState.resolved);
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync skipped -> action=$action reason=state_already_converged state=${deviceSosStatus.state.name} origin=${deviceSosStatus.triggerOrigin.name} deviceId=${runtimeStatus.nodeId?.toString() ?? "-"} hardwareId=${runtimeStatus.deviceId} commandPathAvailable=true alreadyClosed=$alreadyClosed',
      );
      return _PublicSosDeviceAttempt(
        available: true,
        attempted: false,
        succeeded: alreadyClosed,
      );
    }

    try {
      BleDebugRegistry.instance.recordEvent(
        'Public SOS device sync attempting -> action=$action deviceId=${runtimeStatus.nodeId?.toString() ?? "-"} hardwareId=${runtimeStatus.deviceId} route=$_currentDeviceCommandOwnerRoute state=${deviceSosStatus.state.name} commandPathAvailable=true',
      );
      final resultingStatus = await operation();
      final deviceStateObserved =
          action != 'trigger' ||
          (resultingStatus.derivedFromBlePacket &&
              resultingStatus.transitionSource ==
                  DeviceSosTransitionSource.device &&
              (resultingStatus.state == DeviceSosState.active ||
                  resultingStatus.state == DeviceSosState.acknowledged));
      if (!deviceStateObserved) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_DEVICE_COMMAND_ACK_MISSING '
          'command=SOS_TRIGGER_APP state=${resultingStatus.state.name} '
          'optimistic=${resultingStatus.optimistic} '
          'derivedFromBlePacket=${resultingStatus.derivedFromBlePacket} '
          'reason=device_activation_not_observed',
        );
        return const _PublicSosDeviceAttempt(
          available: true,
          attempted: true,
          succeeded: false,
        );
      }
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

      final terminalAction =
          action == 'cancel' ||
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
    final path = shortPath
        ? 'ble_inet_sos_trigger'
        : (longPath ? 'ble_cmd' : 'none');
    BleDebugRegistry.instance.recordEvent(
      '[APP_PRE_SOS_ROUTE] origin=app '
      'bleConnected=$bleConnected cmd=$longPath '
      'preSosDevicePath=$path decision=$decision '
      'countdown=${countdown.inSeconds}',
    );
  }

  void _logSosPathDecision(SosCapabilitySnapshot capability) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_PATH_DECISION '
      'primaryPath=${capability.preferredActivationPath?.name ?? "none"} '
      'canTriggerAppSos=${capability.canTriggerAppSos} '
      'canTriggerDeviceSos=${capability.canTriggerDeviceSos} '
      'deviceTransportReady=${capability.deviceTransportReady} '
      'commandChannelReady=${capability.commandChannelReady} '
      'connectedDevicePresent=${capability.hasConnectedDevice}',
    );
  }

  void _logSosDeviceMirrorDecision({
    required bool attempt,
    required String reason,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_DEVICE_MIRROR_DECISION attempt=$attempt reason=$reason',
    );
  }

  void _rememberDeviceRuntimeSosOwnership(
    DeviceSosStatus status,
    String? cycleKey,
  ) {
    if (status.transitionSource != DeviceSosTransitionSource.device ||
        (!status.derivedFromBlePacket &&
            status.triggerOrigin != DeviceSosTransitionSource.device)) {
      return;
    }
    final incident = _buildDeviceRuntimePublicSosIncident(status);
    if (incident == null || !_hasBackendVisibleSosIncident(incident)) {
      return;
    }
    _activeDeviceRuntimeIncidentId = incident.id;
    _activeDeviceRuntimeCycleKey = cycleKey == null
        ? null
        : 'sos-cycle:$cycleKey';
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
        _parseSosCycleNodeId(cycleKey == null ? null : 'sos-cycle:$cycleKey') ??
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
      unawaited(
        _rememberDeviceIdentityMapping(
          nodeId: nodeId,
          hardwareId: hardwareId,
          source: source,
        ),
      );
    }
    if (status == null) {
      return;
    }
    final previousDeviceId =
        status.nodeId?.toString() ??
        (isBleMacDeviceId(status.deviceId) ? null : status.deviceId) ??
        status.deviceId;
    final promotedStatus = status.copyWith(nodeId: nodeId);
    _lastDeviceStatus = promotedStatus;
    _publishPublicDeviceStatus(rawStatus: promotedStatus, reason: source);
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_NODE_ID_PROMOTED source=$source '
      'nodeId=$nodeId hardwareId=${hardwareId ?? status.deviceId} '
      'previousDeviceId=$previousDeviceId nextDeviceId=$nodeId',
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
        unawaited(
          _rememberDeviceIdentityMapping(
            nodeId: status.nodeId!,
            hardwareId: hardwareId,
            source: source,
          ),
        );
      }
      return status;
    }
    final hardwareId = _canonicalHardwareIdForStatus(status);
    final cachedNodeId = hardwareId == null
        ? null
        : _sosRuntimeNodeIdByHardwareId[hardwareId];
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
    final deviceRuntimeIncidentNodeId =
        _parseDeviceRuntimeNodeId(_activeDeviceRuntimeIncidentId) ??
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
    final publicStatusNodeId = _nodeIdFromConnectedRuntimeStatus(
      _lastPublicDeviceStatus,
    );
    if (publicStatusNodeId != null) {
      return _RemoteRelayLocalGuardMatch(
        nodeId: publicStatusNodeId,
        matchedBy: 'promoted_public_device',
      );
    }
    final runtimeStatusNodeId = _nodeIdFromConnectedRuntimeStatus(
      _lastDeviceStatus,
    );
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
    final runtimeCycleNodeId = _parseSosCycleNodeId(
      _activeDeviceRuntimeCycleKey,
    );
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
    final hardwareId = <String?>[status.canonicalHardwareId, status.deviceId]
        .whereType<String>()
        .map((value) => value.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    return hardwareId.isEmpty ? null : hardwareId;
  }

  String? _physicalHardwareIdForStatus(DeviceStatus? status) {
    if (status == null) {
      return null;
    }
    return normalizeCanonicalHardwareId(status.canonicalHardwareId) ??
        normalizeCanonicalHardwareId(status.deviceId);
  }

  bool _samePhysicalHardwareId(String? left, String? right) {
    final normalizedLeft = normalizeCanonicalHardwareId(left);
    final normalizedRight = normalizeCanonicalHardwareId(right);
    return normalizedLeft != null && normalizedLeft == normalizedRight;
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
    _lastClosedDeviceRuntimeLocalCycleKey =
        _activeDeviceRuntimeLocalCycleKey ??
        _lastClosedDeviceRuntimeLocalCycleKey;
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

  bool _isProvisionalLocalSosIncident(SosIncident? incident) {
    if (incident == null || incident.isBackendConfirmed) {
      return false;
    }
    return _isLocalAppSosIncidentId(incident.id) ||
        _isDeviceRuntimeSosIncidentId(incident.id);
  }

  bool _isSyntheticLocalSosIncidentId(String? incidentId) {
    if (incidentId == null || incidentId.isEmpty) {
      return false;
    }
    return _isLocalAppSosIncidentId(incidentId) ||
        _isDeviceRuntimeSosIncidentId(incidentId) ||
        incidentId.startsWith('device-runtime-') ||
        incidentId.startsWith('public-sos-') ||
        incidentId.startsWith('pre-sos-');
  }

  bool _hasCanonicalBackendSosIdentity({
    SosIncident? incident,
    SosLifecycleSnapshot? lifecycle,
  }) {
    final candidates = <String?>[
      if (incident != null && incident.isBackendConfirmed) incident.id,
      lifecycle?.backendIncidentId,
    ];
    for (final id in candidates) {
      if (_isSyntheticLocalSosIncidentId(id)) {
        continue;
      }
      if (id != null && id.isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  bool _canConfirmLocalCancelWithoutBackendProof({
    required SosIncident? incident,
    required DeviceSosStatus deviceStatus,
    required SosLifecycleSnapshot lifecycle,
    required bool deviceCancelSucceeded,
  }) {
    if (_isOwnDeviceUserDeactivatedEvent(deviceStatus)) {
      return true;
    }
    if (_hasCanonicalBackendSosIdentity(
      incident: incident,
      lifecycle: lifecycle,
    )) {
      return false;
    }
    return _isProvisionalLocalSosIncident(incident) ||
        incident == null ||
        deviceCancelSucceeded ||
        _isDeviceSosCycleClosed(deviceStatus.state) ||
        lifecycle.stage == SosLifecycleStage.cancellationFailed;
  }

  Future<SosIncident> _settlePublicCancelLocally({
    required SosIncident? incident,
    required bool deviceSucceeded,
    Object? backendError,
  }) async {
    BleDebugRegistry.instance.recordEvent(
      'Public SOS cancel settled locally -> '
      'incidentId=${incident?.id ?? "none"} '
      'backendError=${backendError ?? "none"} '
      'deviceSucceeded=$deviceSucceeded',
    );
    final cancelled =
        (incident ??
                SosIncident(
                  id:
                      'public-sos-local-cancel:'
                      '${DateTime.now().toUtc().microsecondsSinceEpoch}',
                  state: SosState.cancelled,
                  createdAt: DateTime.now().toUtc(),
                  triggerSource: 'public_cancel_local_settle',
                ))
            .copyWith(
              state: SosState.cancelled,
              deliveryChannel: deviceSucceeded
                  ? SosDeliveryChannel.deviceOnly
                  : SosDeliveryChannel.backendOnly,
              terminalReason: SosTerminalReason.cancelledByUser,
            );
    _applyTerminalSosSuppression(
      reason: 'public_cancel_local_settle',
      terminalState: SosState.cancelled,
    );
    await _clearSosNotificationsSafely(reason: 'public_cancel_local_settle');
    _clearCurrentPublicSosAfterCancellation(cancelled);
    _clearPendingAppTriggeredSosBridge(reason: 'public_cancel_local_settle');
    _publishCancelledSosEventIfNeeded(cancelled);
    return cancelled;
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
      return _canonicalizeDeviceOwnedBackendIncident(incoming, source: source);
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
      _rememberDeviceOwnedBackendIncidentId(backendIncidentId: incoming.id);
      return _canonicalizeDeviceOwnedBackendIncident(incoming, source: source);
    }
    if (_isLocalAppSosIncidentId(incoming.id)) {
      _logSosRejectionThrottled(
        cycleId:
            _activeDeviceRuntimeCycleKey ??
            _activeDeviceRuntimeIncidentId ??
            'unknown',
        source: source,
        reason: 'duplicate_device_owned_sos',
        message:
            'SOS_BACKEND_PUBLISH_SKIPPED reason=duplicate_owner '
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
              actuators: incoming.actuators,
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
      actuators: incident.actuators,
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
    final originatorNodeId =
        _parseDeviceRuntimeNodeId(existingIncidentId) ??
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
    final repositoryIncident = _decorateIncidentWithPublicDeliveryChannel(
      await sosRepository.getCurrentIncident(),
    );
    final fallback =
        _publicSosFallbackIncident ??
        (_hasBackendVisibleSosIncident(repositoryIncident)
            ? repositoryIncident
            : null) ??
        _decorateIncidentWithPublicDeliveryChannel(_lastKnownActiveSosIncident);
    if (fallback != null) {
      return fallback.copyWith(
        state: state,
        deliveryChannel: deliveryChannel,
        terminalReason: _lastPublicSosTerminalReason,
      );
    }
    final now = DateTime.now().toUtc();
    return SosIncident(
      id: 'public-sos-fallback:${now.microsecondsSinceEpoch}',
      state: state,
      createdAt: now,
      source: 'local_device',
      triggerSource: 'public_sos_fallback',
      originKind: SosOriginKind.ownDevice,
      actionability: SosActionability.localActionable,
      displaySurface: SosDisplaySurface.activeAndHistory,
      deliveryChannel: deliveryChannel,
      terminalReason: _lastPublicSosTerminalReason,
    );
  }

  Future<SosIncident?> _adoptBackendIncidentForDeviceOnlyFallback(
    SosIncident fallback,
  ) async {
    if (fallback.deliveryChannel != SosDeliveryChannel.deviceOnly ||
        !_isOpenSosState(fallback.state)) {
      return null;
    }
    SosIncident? repositoryIncident;
    try {
      repositoryIncident = await sosRepository.getCurrentIncident();
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRIGGER_DEVICE_ONLY_BACKEND_PENDING '
        'reason=backend_confirmation_lookup_failed '
        'errorType=${error.runtimeType}',
      );
      return null;
    }
    if (!_hasBackendVisibleSosIncident(repositoryIncident) ||
        repositoryIncident!.id == fallback.id) {
      return null;
    }
    if (_isExternalOnlySosIncident(
      repositoryIncident,
      source: 'device_only_backend_adoption',
    )) {
      return null;
    }
    final adopted = repositoryIncident.copyWith(
      state: _promotePostTriggerSosState(repositoryIncident.state),
      deliveryChannel: SosDeliveryChannel.backendAndDevice,
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_TRIGGER_DEVICE_ONLY_BACKEND_CONFIRMED '
      'fallbackIncidentId=${fallback.id} backendIncidentId=${adopted.id}',
    );
    _recordPublicSosResult(
      incident: adopted,
      deliveryChannel: SosDeliveryChannel.backendAndDevice,
    );
    return adopted;
  }

  void _recordPublicSosResult({
    required SosIncident incident,
    required SosDeliveryChannel deliveryChannel,
    SosState? fallbackState,
  }) {
    if (_isExternalOnlySosIncident(
      incident,
      source: 'record_public_sos_result',
    )) {
      _clearExternalOnlyPublicSosResidue(
        reason: 'record_public_sos_result_external_only',
      );
      if (_isOpenSosState(_publicSosState)) {
        _emitPublicSosState(
          SosState.idle,
          source: 'record_public_sos_result:external_only',
        );
      }
      return;
    }
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
    if (recordedIncident.terminalReason != null) {
      _lastPublicSosTerminalReason = recordedIncident.terminalReason;
    } else if (!_isTerminalPublicSosState(recordedIncident.state)) {
      _lastPublicSosTerminalReason = null;
    }
    if (_isOpenSosState(recordedIncident.state) &&
        (_pendingPreSosConfirmation != null ||
            _recentAppOriginMirroredPreSosBridge != null ||
            _pendingAppTriggeredSosBridge != null ||
            recordedIncident.triggerSource != 'ble_device_runtime_status')) {
      _rememberAppOriginActiveSosBridge(recordedIncident);
    }
    if (deliveryChannel == SosDeliveryChannel.deviceOnly &&
        _isOpenSosState(recordedIncident.state)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_DEVICE_ONLY_INCIDENT_RECORDED '
        'incidentId=${recordedIncident.id} state=${recordedIncident.state.name}',
      );
    }
    if (fallbackState != null) {
      _publicSosFallbackIncident = recordedIncident;
      _emitPublicSosState(fallbackState, source: 'public_sos_result');
    } else {
      _publicSosFallbackIncident = null;
      _emitPublicSosState(recordedIncident.state, source: 'public_sos_result');
    }
    final emittedState = fallbackState ?? recordedIncident.state;
    if (deliveryChannel == SosDeliveryChannel.deviceOnly &&
        _isOpenSosState(emittedState)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_DEVICE_ONLY_PUBLIC_STATE_EMITTED '
        'incidentId=${recordedIncident.id} state=${emittedState.name}',
      );
    }
    _emitOperationalDiagnostics();
  }

  void _clearCurrentPublicSosAfterCancellation(SosIncident incident) {
    _rememberAcknowledgedTerminalSosIncident(incident);
    _lastPublicSosTerminalReason =
        incident.terminalReason ?? SosTerminalReason.cancelledByUser;
    _publicSosFallbackIncident = null;
    _lastKnownActiveSosIncident = null;
    _clearAppOriginActiveSosBridge(reason: 'public_cancel_completed');
    _clearAppOriginDeviceOwnershipContext(reason: 'public_cancel_completed');
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
      if (_isExternalOnlySosIncident(
        incoming,
        source: '$source:preserve_active_incident',
      )) {
        _clearExternalOnlyPublicSosResidue(
          reason: '${source}_external_only_preserve_blocked',
        );
        return null;
      }
      _rememberActiveSosIncident(incoming);
      return incoming;
    }
    final remembered = _lastKnownActiveSosIncident;
    if (remembered == null || !_isOpenSosState(_publicSosState)) {
      return null;
    }
    _logActiveIncidentPreservedOnce(source: source, incident: remembered);
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
    final resolvedCycleKey =
        cycleKey ??
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
        payload: <String, String>{
          'incidentId': incident.id,
          if (incident.deliveryChannel != null)
            'deliveryChannel': incident.deliveryChannel!.name,
          if (incident.terminalReason != null)
            'terminalReason': incident.terminalReason!.name,
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
        payload: <String, String>{
          'deviceSosState': status.state.name,
          'transitionSource': status.transitionSource.name,
          if (cycleKey != null) 'cycleKey': cycleKey,
        },
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

  bool _matchesAppOriginMirroredPreSosBridge(
    DeviceSosStatus status, {
    String? runtimeCycleKey,
    int? nodeId,
  }) {
    if (_matchingRecentAppOriginMirroredPreSosBridge(status, nodeId: nodeId) !=
        null) {
      return true;
    }
    final session = _preSosSession;
    if (session == null ||
        session.owner != _SosOwner.app ||
        !session.mirroredOnDevice) {
      return false;
    }
    final now = DateTime.now();
    if (now.isBefore(
          session.startedAt.subtract(_appTriggeredSosBridgeWindow),
        ) ||
        now.isAfter(
          session.expectedActivationAt.add(_appTriggeredSosBridgeWindow),
        )) {
      return false;
    }
    final effectiveNodeId = nodeId ?? _appOriginRuntimeNodeId(status);
    final sessionNodeId = session.originatorNodeId ?? _knownLocalDeviceNodeId;
    if (sessionNodeId != null &&
        effectiveNodeId != null &&
        sessionNodeId != effectiveNodeId) {
      return false;
    }
    if (sessionNodeId == null && effectiveNodeId == null) {
      final bridge = _pendingAppTriggeredSosBridge;
      if (bridge == null || DateTime.now().isAfter(bridge.expiresAt)) {
        return status.triggerOrigin == DeviceSosTransitionSource.app;
      }
    }
    final effectiveRuntimeCycleKey =
        runtimeCycleKey ??
        _runtimeDeviceSosCycleKey(status: status, nodeId: effectiveNodeId);
    return status.state == DeviceSosState.preConfirm ||
        status.state == DeviceSosState.active ||
        status.state == DeviceSosState.acknowledged ||
        (_isDeviceSosCycleClosed(status.state) &&
            effectiveRuntimeCycleKey != null);
  }

  _AppOriginMirroredPreSosBridge? _matchingRecentAppOriginMirroredPreSosBridge(
    DeviceSosStatus status, {
    int? nodeId,
    int? originatorNodeId,
  }) {
    final bridge = _recentAppOriginMirroredPreSosBridge;
    if (bridge == null || DateTime.now().isAfter(bridge.expiresAt)) {
      return null;
    }
    final effectiveNodeId =
        nodeId ?? originatorNodeId ?? _appOriginRuntimeNodeId(status);
    if (bridge.originatorNodeId != null &&
        effectiveNodeId != null &&
        bridge.originatorNodeId != effectiveNodeId) {
      return null;
    }
    final bridgeDeviceId = bridge.deviceId?.trim();
    final currentDeviceId = _lastDeviceStatus?.deviceId.trim();
    if (bridgeDeviceId != null &&
        bridgeDeviceId.isNotEmpty &&
        currentDeviceId != null &&
        currentDeviceId.isNotEmpty &&
        bridgeDeviceId != currentDeviceId) {
      return null;
    }
    return bridge;
  }

  _AppOriginMirroredPreSosBridge? _matchingRecentAppOriginBridgeForSession({
    required _SosOwner owner,
    required bool mirroredOnDevice,
    required DeviceSosTransitionSource? origin,
    required int? originatorNodeId,
  }) {
    if (owner != _SosOwner.app || mirroredOnDevice) {
      return null;
    }
    if (origin != null && origin != DeviceSosTransitionSource.app) {
      return null;
    }
    final bridge = _recentAppOriginMirroredPreSosBridge;
    if (bridge == null || DateTime.now().isAfter(bridge.expiresAt)) {
      return null;
    }
    if (bridge.originatorNodeId != null &&
        originatorNodeId != null &&
        bridge.originatorNodeId != originatorNodeId) {
      return null;
    }
    final bridgeDeviceId = bridge.deviceId?.trim();
    final currentDeviceId = _lastDeviceStatus?.deviceId.trim();
    if (bridgeDeviceId != null &&
        bridgeDeviceId.isNotEmpty &&
        currentDeviceId != null &&
        currentDeviceId.isNotEmpty &&
        bridgeDeviceId != currentDeviceId) {
      return null;
    }
    return bridge;
  }

  String? _appOriginBridgeCycleKeyFor(
    DeviceSosStatus status, {
    String? runtimeCycleKey,
  }) {
    final session = _preSosSession;
    if (session != null &&
        session.owner == _SosOwner.app &&
        session.mirroredOnDevice &&
        _matchesAppOriginMirroredPreSosBridge(
          status,
          runtimeCycleKey: runtimeCycleKey,
        )) {
      return session.cycleKey;
    }
    return _matchingRecentAppOriginMirroredPreSosBridge(status)?.cycleKey;
  }

  int? _appOriginRuntimeNodeId(DeviceSosStatus status) {
    return status.nodeId ??
        _parseDeviceRuntimeNodeId(status.lastPacketSignature) ??
        _parseSosCycleNodeId(status.lastPacketSignature) ??
        _knownLocalDeviceNodeId;
  }

  void _recordAppOriginBleRuntimeCorrelation(
    DeviceSosStatus status, {
    required String? runtimeCycleKey,
  }) {
    final session = _preSosSession;
    final bridge = _matchingRecentAppOriginMirroredPreSosBridge(status);
    if ((session == null || session.owner != _SosOwner.app) && bridge == null) {
      return;
    }
    final nodeId = _appOriginRuntimeNodeId(status);
    final reason = session?.mirroredOnDevice == true
        ? 'matching_app_pre_sos_bridge'
        : bridge != null
        ? 'recent_app_bridge_even_if_current_session_unmirrored'
        : 'matching_app_pre_sos_bridge';
    final activeBridge = _appOriginActiveSosBridge;
    if (activeBridge != null &&
        activeBridge.generation == _sosLifecycle.current.generation &&
        activeBridge.lifecycleId == _sosLifecycle.current.lifecycleId) {
      final rawRuntimeCycleKey = _runtimeDeviceSosCycleKey(
        status: status,
        nodeId: nodeId,
      );
      _appOriginActiveSosBridge = activeBridge.copyWith(
        runtimeCycleKey: rawRuntimeCycleKey ?? runtimeCycleKey,
        nodeId: nodeId,
        packetId: status.packetId,
      );
      _rememberAppOriginDeviceOwnershipContext(status);
    } else {
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_ORIGIN_DEVICE_OWNERSHIP_SKIPPED '
        'reason=active_bridge_generation_mismatch bridgePresent=${activeBridge != null}',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_BLE_RUNTIME_CORRELATED '
      'reason=$reason '
      'appCycleKey=${bridge?.cycleKey ?? session?.cycleKey ?? "-"} '
      'runtimeCycleKey=${runtimeCycleKey ?? "-"} '
      'nodeId=${nodeId?.toString() ?? "-"} '
      'packetId=${status.packetId?.toString() ?? "-"}',
    );
  }

  void _rememberAppOriginDeviceOwnershipContext(DeviceSosStatus status) {
    final session = _session;
    final lifecycle = _sosLifecycle.current;
    final bridge = _appOriginActiveSosBridge;
    final device = _lastDeviceStatus;
    final deviceId = device?.deviceId.trim();
    final hardwareId = _physicalHardwareIdForStatus(device);
    final lifecycleHardwareId = normalizeCanonicalHardwareId(
      lifecycle.hardwareId,
    );
    final nodeId = _appOriginRuntimeNodeId(status);
    final runtimeCycleKey = _runtimeDeviceSosCycleKey(
      status: status,
      nodeId: nodeId,
    )?.trim();
    final packetId = status.packetId;
    final lifecycleIncidentIds = <String>{
      if (lifecycle.localIncidentId != null) lifecycle.localIncidentId!,
      if (lifecycle.backendIncidentId != null) lifecycle.backendIncidentId!,
      if (lifecycle.incident?.id != null) lifecycle.incident!.id,
      if (lifecycle.incident?.provisionalIncidentId != null)
        lifecycle.incident!.provisionalIncidentId!,
    };
    if (session == null ||
        !lifecycle.isOpen ||
        lifecycle.origin != SosLifecycleOrigin.localApp ||
        bridge == null ||
        bridge.lifecycleId != lifecycle.lifecycleId ||
        bridge.generation != lifecycle.generation ||
        !lifecycleIncidentIds.contains(bridge.incidentId) ||
        device == null ||
        !device.connected ||
        deviceId == null ||
        deviceId.isEmpty ||
        bridge.deviceId?.trim().toLowerCase() != deviceId.toLowerCase() ||
        hardwareId == null ||
        lifecycleHardwareId == null ||
        lifecycleHardwareId.isEmpty ||
        !_samePhysicalHardwareId(hardwareId, lifecycleHardwareId) ||
        nodeId == null ||
        (lifecycle.nodeId != null && lifecycle.nodeId != nodeId) ||
        (device.nodeId != null && device.nodeId != nodeId) ||
        status.nodeId != nodeId ||
        packetId == null ||
        runtimeCycleKey == null ||
        runtimeCycleKey.isEmpty ||
        (status.state != DeviceSosState.active &&
            status.state != DeviceSosState.acknowledged)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_ORIGIN_DEVICE_OWNERSHIP_SKIPPED '
        'reason=ownership_fields_unproven '
        'sessionPresent=${session != null} lifecycleOpen=${lifecycle.isOpen} '
        'localApp=${lifecycle.origin == SosLifecycleOrigin.localApp} '
        'bridgePresent=${bridge != null} '
        'bridgeLifecycleMatch=${bridge?.lifecycleId == lifecycle.lifecycleId && bridge?.generation == lifecycle.generation} '
        'incidentMatch=${bridge != null && lifecycleIncidentIds.contains(bridge.incidentId)} '
        'deviceConnected=${device?.connected == true} '
        'deviceMatch=${deviceId != null && bridge?.deviceId?.trim().toLowerCase() == deviceId.toLowerCase()} '
        'hardwareMatch=${_samePhysicalHardwareId(hardwareId, lifecycleHardwareId)} '
        'nodePresent=${nodeId != null} packetPresent=${packetId != null} '
        'cyclePresent=${runtimeCycleKey?.isNotEmpty == true} '
        'deviceOpen=${status.state == DeviceSosState.active || status.state == DeviceSosState.acknowledged}',
      );
      return;
    }
    _appOriginDeviceOwnershipContext = _AppOriginDeviceOwnershipContext(
      lifecycleId: lifecycle.lifecycleId,
      generation: lifecycle.generation,
      ownerScope: AuthoritativeSosLifecycleController.ownerScopeFor(session),
      bridgeIncidentId: bridge.incidentId,
      deviceId: deviceId,
      hardwareId: hardwareId,
      nodeId: nodeId,
      runtimeCycleKey: runtimeCycleKey,
      packetId: packetId,
      deviceActiveObservedAt: status.lastPacketAt ?? status.updatedAt,
    );
    final acknowledgedProof = _remoteTerminalDeviceClearAcknowledgedProof;
    if (acknowledgedProof != null &&
        acknowledgedProof.generation != lifecycle.generation &&
        acknowledgedProof.runtimeCycleKey != runtimeCycleKey) {
      _remoteTerminalDeviceClearAcknowledgedProof = null;
      BleDebugRegistry.instance.recordEvent(
        'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_GUARD_CLEARED '
        'reason=new_device_cycle',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_DEVICE_OWNERSHIP_CAPTURED '
      'lifecycleGeneration=${lifecycle.generation} packetIdentityPresent=true',
    );
  }

  bool _shouldIgnoreAppOriginDeviceCancelOfArming(
    DeviceSosStatus status, {
    required String? cycleKey,
  }) {
    if (_publicSosClosureInFlight != null) {
      return false;
    }
    final preSosStatus = _buildCurrentPreSosStatus();
    if (preSosStatus == null && _publicSosState != SosState.arming) {
      return false;
    }
    final matchesBridge = _matchesAppOriginMirroredPreSosBridge(
      status,
      runtimeCycleKey: cycleKey,
    );
    if (!matchesBridge) {
      return false;
    }
    if (_isPhysicalPreSosUserCancellation(status)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_PHYSICAL_PRE_SOS_CANCEL_ACCEPTED '
        'reason=matching_app_origin_bridge '
        'generation=${_sosLifecycle.current.generation} '
        'nodeId=${status.nodeId?.toString() ?? "-"}',
      );
      return false;
    }
    return true;
  }

  bool _isPhysicalPreSosUserCancellation(DeviceSosStatus status) {
    final eventBytes = _parseHexBytes(status.lastPacketHex);
    // Firmware subcode 0x01 is the physical countdown-cancel gesture. E2 never
    // reaches this branch because DeviceSosController consumes it as an ACK.
    return _isOwnDeviceUserDeactivatedEvent(status) &&
        status.previousState == DeviceSosState.preConfirm &&
        eventBytes != null &&
        eventBytes.length >= 2 &&
        eventBytes[1] == 0x01;
  }

  bool _shouldRejectStalePreSosPhysicalCancel(DeviceSosStatus status) {
    if (!_isOwnDeviceUserDeactivatedEvent(status)) {
      return false;
    }
    final eventBytes = _parseHexBytes(status.lastPacketHex);
    if (eventBytes == null || eventBytes.length < 2 || eventBytes[1] != 0x01) {
      return false;
    }
    final terminal = _sosLifecycle.activeTerminalWatermark;
    final current = _sosLifecycle.current;
    // An E1/0x01 belongs to a pre-SOS countdown. Once a later generation is
    // already beyond arming, it cannot be allowed to close that generation.
    return terminal != null &&
        current.isOpen &&
        current.generation > terminal.generation &&
        current.stage != SosLifecycleStage.arming &&
        status.previousState != DeviceSosState.preConfirm;
  }

  bool _isAppOwnedBleRuntimeStatus(
    DeviceSosStatus status, {
    String? cycleKey,
    bool? isCorrelatedAppTriggeredStatus,
  }) {
    if (status.triggerOrigin == DeviceSosTransitionSource.app) {
      return true;
    }
    if (isCorrelatedAppTriggeredStatus ??
        _isCorrelatedAppTriggeredSosStatus(status)) {
      return true;
    }
    final session = _preSosSession;
    if (session != null &&
        (session.owner == _SosOwner.app ||
            session.origin == DeviceSosTransitionSource.app)) {
      final sameCycle =
          cycleKey != null &&
          cycleKey.isNotEmpty &&
          session.cycleKey == cycleKey;
      final sameNode =
          session.originatorNodeId != null &&
          status.nodeId != null &&
          session.originatorNodeId == status.nodeId;
      if (sameCycle ||
          sameNode ||
          status.previousState == DeviceSosState.preConfirm ||
          status.state == DeviceSosState.preConfirm) {
        return true;
      }
    }
    if (_matchesAppOriginMirroredPreSosBridge(
      status,
      runtimeCycleKey: cycleKey,
    )) {
      return true;
    }
    return _matchesPendingAppTriggeredSosBridgeIdentity(status);
  }

  bool _matchesPendingAppTriggeredSosBridgeIdentity(DeviceSosStatus status) {
    final bridge = _pendingAppTriggeredSosBridge;
    if (bridge == null || DateTime.now().isAfter(bridge.expiresAt)) {
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
    return bridgeNodeId == null ||
        status.nodeId == null ||
        bridgeNodeId == status.nodeId;
  }

  bool _isAppOwnedBleOpenState({
    required DeviceSosStatus status,
    required SosState? state,
    required String? cycleKey,
  }) {
    return state != null &&
        _isOpenSosState(state) &&
        status.derivedFromBlePacket &&
        status.transitionSource == DeviceSosTransitionSource.device &&
        _isAppOwnedBleRuntimeStatus(status, cycleKey: cycleKey);
  }

  void _promoteAppOriginPreSosFromBleActive(
    DeviceSosStatus status, {
    required String? cycleKey,
  }) {
    if (!status.derivedFromBlePacket ||
        status.transitionSource != DeviceSosTransitionSource.device) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_DEVICE_COMMAND_ACK_MISSING '
        'command=SOS_TRIGGER_APP state=${status.state.name} '
        'optimistic=${status.optimistic} '
        'derivedFromBlePacket=${status.derivedFromBlePacket} '
        'reason=synthetic_device_active_not_accepted',
      );
      if (_preSosSession?.owner == _SosOwner.app &&
          _pendingPreSosConfirmation == null &&
          !_publicSosActionInFlight &&
          _pendingAppTriggeredSosBridge == null) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_APP_PRE_SOS_LOCAL_COUNTDOWN_ELAPSED '
          'action=publish_backend_without_device_ack',
        );
        unawaited(
          confirmPreSos(
            _preSosSession?.activationPayload ?? const SosTriggerPayload(),
          ),
        );
      }
      return;
    }
    final incidentId =
        _lastKnownActiveSosIncident?.id ??
        _publicSosFallbackIncident?.id ??
        _pendingAppTriggeredSosBridge?.incidentId ??
        _appOriginBleRuntimeIncidentId(status, cycleKey: cycleKey);
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_PRE_SOS_PROMOTED source=device_runtime_active '
      'reason=ble_device_reached_active incidentId=$incidentId '
      'cycleKey=${cycleKey ?? "-"}',
    );
    _emitPublicSosState(
      status.state == DeviceSosState.acknowledged
          ? SosState.acknowledged
          : SosState.sent,
      source: 'app_origin_ble_runtime_active',
    );
    if (_pendingPreSosConfirmation == null &&
        !_publicSosActionInFlight &&
        _pendingAppTriggeredSosBridge == null) {
      unawaited(
        confirmPreSos(
          _preSosSession?.activationPayload ?? const SosTriggerPayload(),
        ),
      );
    }
  }

  String _appOriginBleRuntimeIncidentId(
    DeviceSosStatus status, {
    required String? cycleKey,
  }) {
    final key =
        cycleKey ??
        status.lastPacketSignature ??
        status.nodeId?.toString() ??
        'unknown';
    return 'app-ble-sos:$key';
  }

  void _cleanupAppOriginDeviceTerminalState(
    DeviceSosStatus status, {
    required String? cycleKey,
  }) {
    final runtimeIncidentId = _currentDeviceRuntimeUiIncidentId();
    _clearPreSosSession(
      reason: 'app_origin_device_terminal_cleanup',
      emitIdleState: false,
    );
    _clearPendingAppTriggeredSosBridge(
      reason: 'app_origin_device_terminal_cleanup',
    );
    _clearAppOriginActiveSosBridge(
      reason: 'app_origin_device_terminal_cleanup',
    );
    _clearAppOriginDeviceOwnershipContext(
      reason: 'app_origin_device_terminal_cleanup',
    );
    _activeDeviceRuntimeIncidentId = null;
    _activeDeviceRuntimeCycleKey = null;
    _activeDeviceRuntimeLocalCycleKey = null;
    _activeDeviceSosCycleKey = null;
    _notifiedDeviceSosCycleKey = null;
    _notifiedDeviceSosState = null;
    if (_isAppOriginLocalFallbackIncident(_publicSosFallbackIncident) ||
        _publicSosFallbackIncident?.id == runtimeIncidentId) {
      _publicSosFallbackIncident = null;
    }
    if (_isAppOriginLocalFallbackIncident(_lastKnownActiveSosIncident) ||
        _lastKnownActiveSosIncident?.id == runtimeIncidentId) {
      _lastKnownActiveSosIncident = null;
      _lastLoggedActiveIncidentPreservationSignature = null;
    }
    _emitPublicSosState(
      SosState.idle,
      source: 'app_origin_device_terminal_cleanup',
    );
    _emitOperationalDiagnostics();
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_DEVICE_TERMINAL_CLEANUP reason=device_manual_stop '
      'incidentId=${runtimeIncidentId ?? _lastPublicSosIncidentId ?? "none"} '
      'cycleKey=${cycleKey ?? "-"} state=${status.state.name}',
    );
  }

  bool _isAppOriginLocalFallbackIncident(SosIncident? incident) {
    if (incident == null) {
      return false;
    }
    return incident.id.startsWith('app-ble-sos:') ||
        incident.id.startsWith('device-runtime-') ||
        incident.triggerSource == 'ble_device_runtime_status';
  }

  void _clearPendingAppTriggeredSosBridge({required String reason}) {
    final bridge = _pendingAppTriggeredSosBridge;
    if (bridge == null) {
      return;
    }
    _pendingAppTriggeredSosBridge = null;
    BleDebugRegistry.instance.recordEvent(
      'App-triggered SOS bridge cleared -> incidentId=${bridge.incidentId} reason=$reason matched=${bridge.matchedAt != null} nodeId=${_formatNodeId(bridge.nodeId)}',
    );
  }

  void _rememberAppOriginActiveSosBridge(SosIncident incident) {
    if (!_isOpenSosState(incident.state)) {
      return;
    }
    final now = DateTime.now();
    final lifecycle = _sosLifecycle.current;
    if (!lifecycle.isOpen ||
        (_sosLifecycle.activeTerminalWatermark != null &&
            !_hasNewAuthoritativeGenerationSinceTerminal())) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_FENCE_SUPPRESSED_OPEN source=app_origin_bridge '
        'reason=authoritative_backend_terminal',
      );
      return;
    }
    final existingBridge = _appOriginActiveSosBridge;
    final ownership = _appOriginDeviceOwnershipContext;
    if (ownership != null &&
        (ownership.lifecycleId != lifecycle.lifecycleId ||
            ownership.generation != lifecycle.generation)) {
      _clearAppOriginDeviceOwnershipContext(reason: 'new_app_lifecycle');
    }
    if (existingBridge != null &&
        existingBridge.lifecycleId == lifecycle.lifecycleId &&
        existingBridge.generation == lifecycle.generation) {
      _appOriginActiveSosBridge = _AppOriginActiveSosBridge(
        incidentId: existingBridge.incidentId,
        state: incident.state,
        createdAt: existingBridge.createdAt,
        expiresAt: now.add(_appTriggeredSosBridgeWindow),
        lifecycleId: existingBridge.lifecycleId,
        generation: existingBridge.generation,
        deviceId: existingBridge.deviceId ?? _lastDeviceStatus?.deviceId.trim(),
        runtimeCycleKey: existingBridge.runtimeCycleKey,
        nodeId: existingBridge.nodeId,
        packetId: existingBridge.packetId,
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_ORIGIN_ACTIVE_BRIDGE_REFRESHED '
        'incidentPresent=${existingBridge.incidentId.isNotEmpty} '
        'incomingIncidentPreserved=${incident.id != existingBridge.incidentId}',
      );
      return;
    }
    _appOriginActiveSosBridge = _AppOriginActiveSosBridge(
      incidentId: incident.id,
      state: incident.state,
      createdAt: now,
      expiresAt: now.add(_appTriggeredSosBridgeWindow),
      lifecycleId: _sosLifecycle.current.lifecycleId,
      generation: _sosLifecycle.current.generation,
      deviceId: _lastDeviceStatus?.deviceId.trim(),
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_ACTIVE_BRIDGE_REGISTERED '
      'incidentId=${incident.id} state=${incident.state.name} '
      'expiresInMs=${_appTriggeredSosBridgeWindow.inMilliseconds}',
    );
  }

  void _clearAppOriginActiveSosBridge({required String reason}) {
    final bridge = _appOriginActiveSosBridge;
    if (bridge == null) {
      return;
    }
    _appOriginActiveSosBridge = null;
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_ACTIVE_BRIDGE_CLEARED '
      'incidentId=${bridge.incidentId} reason=$reason',
    );
  }

  void _clearAppOriginDeviceOwnershipContext({required String reason}) {
    if (_appOriginDeviceOwnershipContext == null) {
      return;
    }
    _appOriginDeviceOwnershipContext = null;
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_DEVICE_OWNERSHIP_CLEARED reason=$reason',
    );
  }

  _AppOriginActiveSosBridge? _currentAppOriginActiveSosBridge() {
    final bridge = _appOriginActiveSosBridge;
    if (bridge == null) {
      return null;
    }
    if (DateTime.now().isAfter(bridge.expiresAt)) {
      _clearAppOriginActiveSosBridge(reason: 'expired');
      return null;
    }
    return bridge;
  }

  void _rememberRecentAppOriginMirroredPreSosBridge(_PreSosSession session) {
    if (session.owner != _SosOwner.app || !session.mirroredOnDevice) {
      return;
    }
    _recentAppOriginMirroredPreSosBridge = _AppOriginMirroredPreSosBridge(
      cycleKey: session.cycleKey,
      startedAt: session.startedAt,
      expectedActivationAt: session.expectedActivationAt,
      expiresAt: session.expectedActivationAt.add(_appTriggeredSosBridgeWindow),
      originatorNodeId: session.originatorNodeId,
      deviceId: _lastDeviceStatus?.deviceId.trim(),
    );
  }

  void _clearRecentAppOriginMirroredPreSosBridge({required String reason}) {
    final bridge = _recentAppOriginMirroredPreSosBridge;
    if (bridge == null) {
      return;
    }
    _recentAppOriginMirroredPreSosBridge = null;
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_BRIDGE_CLEARED reason=$reason '
      'appCycleKey=${bridge.cycleKey} '
      'nodeId=${bridge.originatorNodeId?.toString() ?? "-"}',
    );
  }

  bool get _hasActivePreSosSession => _buildCurrentPreSosStatus() != null;

  void _syncPreSosSessionFromDeviceStatus(DeviceSosStatus status) {
    if (status.state != DeviceSosState.preConfirm ||
        !status.derivedFromBlePacket ||
        status.transitionSource != DeviceSosTransitionSource.device) {
      if (status.state == DeviceSosState.preConfirm && status.optimistic) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_DEVICE_COMMAND_ACK_MISSING '
          'command=SOS_TRIGGER_APP state=${status.state.name} '
          'optimistic=${status.optimistic} '
          'derivedFromBlePacket=${status.derivedFromBlePacket} '
          'reason=synthetic_device_status_not_accepted',
        );
      }
      return;
    }
    final cycleKey = _preSosCycleKeyFromDeviceStatus(status);
    final existing = _preSosSession;
    final matchesAppOriginBridge = _matchesAppOriginMirroredPreSosBridge(
      status,
      runtimeCycleKey: cycleKey,
    );
    final startedAt = status.countdownStartedAt ?? DateTime.now();
    final expectedActivationAt =
        status.expectedActivationAt ??
        startedAt.add(const Duration(seconds: 20));
    if (matchesAppOriginBridge) {
      _recordAppOriginBleRuntimeCorrelation(status, runtimeCycleKey: cycleKey);
    }
    final appBridgeCycleKey = matchesAppOriginBridge
        ? _appOriginBridgeCycleKeyFor(status)
        : null;
    final owner =
        matchesAppOriginBridge ||
            status.triggerOrigin == DeviceSosTransitionSource.app ||
            existing?.owner == _SosOwner.app
        ? _SosOwner.app
        : _SosOwner.device;
    _syncPreSosSession(
      startedAt: startedAt,
      expectedActivationAt: expectedActivationAt,
      mirroredOnDevice: true,
      origin: matchesAppOriginBridge
          ? DeviceSosTransitionSource.app
          : status.triggerOrigin == DeviceSosTransitionSource.unknown
          ? null
          : status.triggerOrigin,
      owner: owner,
      cycleKey: matchesAppOriginBridge
          ? appBridgeCycleKey ?? existing?.cycleKey ?? cycleKey
          : cycleKey,
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
    final iosSnapshotState = _applyIosBleSosSnapshot(
      snapshot,
      trigger: trigger,
    );
    if (iosSnapshotState == SosState.idle ||
        iosSnapshotState == SosState.arming ||
        iosSnapshotState == SosState.sent) {
      return;
    }
    if (_terminalWatermarkRejectsRestoredEvidence(
      observedAt: snapshot.preSosStartedAt,
      nodeId: snapshot.preSosOriginatorNodeId,
      cycleKey: snapshot.preSosCycleKey,
    )) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_WATERMARK_REJECTED source=platform_pre_sos',
      );
      return;
    }
    // If the public SOS state already reached a terminal outcome (cancelled,
    // resolved, failed), do not let a stale native protection snapshot
    // resurrect the pre-SOS session — that produces phantom arming snapshots
    // that the app then rejects as regressions, leaving the UI stuck on the
    // previous open state.
    if (_isTerminalPublicSosState(_publicSosState)) {
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
        if (snapshot.platform == ProtectionPlatform.ios) {
          await _promoteExpiredIosBlePreSosSnapshot(
            snapshot,
            trigger: 'native_pre_sos_elapsed',
          );
        } else {
          await _syncNativePreSosBackendPending(
            trigger: 'native_pre_sos_elapsed',
          );
        }
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

  Future<SosState?> _mergeIosBleSosSnapshot({required String trigger}) async {
    ProtectionPlatformSnapshot snapshot;
    try {
      snapshot = await protectionPlatformAdapter.getPlatformSnapshot();
    } catch (_) {
      return null;
    }
    return _applyIosBleSosSnapshot(snapshot, trigger: trigger);
  }

  SosState? _applyIosBleSosSnapshot(
    ProtectionPlatformSnapshot snapshot, {
    required String trigger,
  }) {
    if (snapshot.platform != ProtectionPlatform.ios) {
      return null;
    }
    final kind = snapshot.iosBleSosSnapshotKind;
    if (kind == null || kind.trim().isEmpty) {
      return null;
    }
    final normalizedKind = kind.trim();
    BleDebugRegistry.instance.recordEvent(
      'IOS_BLE_SOS_SNAPSHOT_REHYDRATED trigger=$trigger '
      'kind=$normalizedKind nodeId=${snapshot.iosBleSosNodeId ?? "none"} '
      'packetId=${snapshot.iosBleSosPacketId ?? "none"} '
      'cycle=${snapshot.iosBleSosCycleKey ?? "none"}',
    );

    if ((normalizedKind == 'active' || normalizedKind == 'preSos') &&
        _terminalWatermarkRejectsRestoredEvidence(
          observedAt:
              snapshot.iosBleSosReceivedAt ??
              snapshot.preSosStartedAt ??
              snapshot.iosBleSosDeadlineAt?.subtract(
                EixamConnectSdk.defaultPreSosCountdown,
              ),
          nodeId: snapshot.iosBleSosNodeId ?? snapshot.preSosOriginatorNodeId,
          cycleKey: snapshot.iosBleSosCycleKey ?? snapshot.preSosCycleKey,
        )) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_WATERMARK_REJECTED source=ios_snapshot '
        'kind=$normalizedKind',
      );
      return SosState.idle;
    }

    if (normalizedKind == 'cancelled') {
      _applyIosBleSosTerminalSnapshot(snapshot, trigger: trigger);
      return SosState.idle;
    }

    if (normalizedKind == 'active') {
      _applyIosBleSosActiveSnapshot(snapshot, trigger: trigger);
      return SosState.sent;
    }

    if (normalizedKind == 'preSos') {
      final deadline =
          snapshot.iosBleSosDeadlineAt ??
          snapshot.preSosExpectedActivationAt ??
          snapshot.iosBleSosReceivedAt?.add(
            EixamConnectSdk.defaultPreSosCountdown,
          );
      final receivedAt = snapshot.iosBleSosReceivedAt ?? DateTime.now().toUtc();
      if (deadline == null || !DateTime.now().isBefore(deadline)) {
        return null;
      }
      BleDebugRegistry.instance.recordEvent(
        'IOS_BLE_SOS_COUNTDOWN_RECONSTRUCTED trigger=$trigger '
        'startedAt=${receivedAt.toUtc().toIso8601String()} '
        'deadline=${deadline.toUtc().toIso8601String()} '
        'remaining=${deadline.difference(DateTime.now()).inSeconds}',
      );
      final startedAt =
          snapshot.preSosStartedAt ??
          snapshot.iosBleSosReceivedAt ??
          deadline.subtract(EixamConnectSdk.defaultPreSosCountdown);
      _syncPreSosSession(
        startedAt: startedAt,
        expectedActivationAt: deadline,
        mirroredOnDevice: true,
        origin: DeviceSosTransitionSource.device,
        owner: _SosOwner.device,
        cycleKey:
            snapshot.iosBleSosCycleKey ??
            _iosBleSosCycleKey(
              nodeId: snapshot.iosBleSosNodeId,
              packetId: snapshot.iosBleSosPacketId,
              payloadHex: snapshot.iosBleSosPayloadHex,
            ),
        originatorNodeId: snapshot.iosBleSosNodeId,
        packetId: snapshot.iosBleSosPacketId,
      );
      return SosState.arming;
    }
    return null;
  }

  void _applyIosBleSosActiveSnapshot(
    ProtectionPlatformSnapshot snapshot, {
    required String trigger,
  }) {
    final cycleKey =
        snapshot.iosBleSosCycleKey ??
        _iosBleSosCycleKey(
          nodeId: snapshot.iosBleSosNodeId,
          packetId: snapshot.iosBleSosPacketId,
          payloadHex: snapshot.iosBleSosPayloadHex,
        );
    final incidentId = cycleKey == null
        ? 'device-runtime-ios-ble-sos:${snapshot.iosBleSosReceivedAt?.microsecondsSinceEpoch ?? DateTime.now().toUtc().microsecondsSinceEpoch}'
        : 'device-runtime-$cycleKey';
    if (_isClosedDeviceRuntimeIncidentId(incidentId)) {
      BleDebugRegistry.instance.recordEvent(
        'IOS_BLE_SOS_STALE_ACTIVE_SUPPRESSED trigger=$trigger '
        'incidentId=$incidentId cycle=${cycleKey ?? "none"}',
      );
      return;
    }
    final createdAt = (snapshot.iosBleSosReceivedAt ?? DateTime.now()).toUtc();
    final incident = SosIncident(
      id: incidentId,
      state: SosState.sent,
      createdAt: createdAt,
      triggerSource: 'ios_ble_sos_snapshot',
      originatorNodeId: snapshot.iosBleSosNodeId,
      cycleKey: cycleKey,
      deliveryChannel: SosDeliveryChannel.deviceOnly,
    );
    _publicSosFallbackIncident = incident;
    _rememberActiveSosIncident(incident);
    _lastPublicSosIncidentId = incident.id;
    _lastPublicSosDeliveryChannel = SosDeliveryChannel.deviceOnly;
    _emitPublicSosState(SosState.sent, source: 'ios_ble_sos_snapshot_active');
  }

  void _applyIosBleSosTerminalSnapshot(
    ProtectionPlatformSnapshot snapshot, {
    required String trigger,
  }) {
    final cycleKey =
        snapshot.iosBleSosCycleKey ??
        _iosBleSosCycleKey(
          nodeId: snapshot.iosBleSosNodeId,
          packetId: snapshot.iosBleSosPacketId,
          payloadHex: snapshot.iosBleSosPayloadHex,
        );
    final incidentId = cycleKey == null ? null : 'device-runtime-$cycleKey';
    _rememberClosedDeviceRuntimeIncidentIds(
      ids: <String?>[
        incidentId,
        _currentDeviceRuntimeUiIncidentId(),
        _activeDeviceRuntimeIncidentId,
        _activeDeviceRuntimeCycleKey == null
            ? null
            : 'device-runtime-${_activeDeviceRuntimeCycleKey!.replaceFirst('sos-cycle:', '')}',
        _activeDeviceSosCycleKey == null
            ? null
            : 'device-runtime-${_activeDeviceSosCycleKey!}',
      ],
    );
    _clearPreSosSession(
      reason: 'ios_ble_sos_snapshot_cancelled',
      emitIdleState: false,
    );
    _publicSosFallbackIncident = null;
    _lastKnownActiveSosIncident = null;
    _lastLoggedActiveIncidentPreservationSignature = null;
    _activeDeviceSosCycleKey = null;
    _notifiedDeviceSosCycleKey = null;
    _notifiedDeviceSosState = null;
    _clearDeviceRuntimeSosOwnership(reason: 'ios_ble_sos_snapshot_cancelled');
    _emitPublicSosState(
      SosState.idle,
      source: 'ios_ble_sos_snapshot_cancelled',
    );
    BleDebugRegistry.instance.recordEvent(
      'IOS_BLE_SOS_STALE_ACTIVE_SUPPRESSED trigger=$trigger '
      'incidentId=${incidentId ?? "none"} cycle=${cycleKey ?? "none"}',
    );
  }

  String? _iosBleSosCycleKey({
    required int? nodeId,
    required int? packetId,
    required String? payloadHex,
  }) {
    if (nodeId != null && packetId != null) {
      return 'sos:$nodeId:$packetId';
    }
    final raw = payloadHex?.trim();
    if (raw != null && raw.isNotEmpty) {
      return 'sos:$raw';
    }
    return null;
  }

  Future<void> _promoteExpiredIosBlePreSosSnapshot(
    ProtectionPlatformSnapshot snapshot, {
    required String trigger,
  }) async {
    final kind = snapshot.iosBleSosSnapshotKind?.trim();
    final cycleKey =
        snapshot.iosBleSosCycleKey ??
        _iosBleSosCycleKey(
          nodeId: snapshot.iosBleSosNodeId,
          packetId: snapshot.iosBleSosPacketId,
          payloadHex: snapshot.iosBleSosPayloadHex,
        );
    final deadline =
        snapshot.iosBleSosDeadlineAt ??
        snapshot.preSosExpectedActivationAt ??
        snapshot.iosBleSosReceivedAt?.add(
          EixamConnectSdk.defaultPreSosCountdown,
        );
    final nodeId = snapshot.iosBleSosNodeId ?? snapshot.preSosOriginatorNodeId;
    final packetId = snapshot.iosBleSosPacketId ?? snapshot.preSosPacketId;
    final incidentId = cycleKey == null ? null : 'device-runtime-$cycleKey';

    BleDebugRegistry.instance.recordEvent(
      'IOS_BLE_SOS_EXPIRED_PRESOS_DETECTED trigger=$trigger '
      'kind=${kind ?? "none"} cycle=${cycleKey ?? "none"} '
      'nodeId=${nodeId ?? "none"} packetId=${packetId ?? "none"} '
      'deadline=${deadline?.toUtc().toIso8601String() ?? "none"}',
    );

    String? blockedReason;
    if (snapshot.platform != ProtectionPlatform.ios) {
      blockedReason = 'non_ios_platform';
    } else if (kind != 'preSos') {
      blockedReason = 'not_presos_snapshot';
    } else if (deadline == null || DateTime.now().isBefore(deadline)) {
      blockedReason = 'deadline_not_expired';
    } else if (DateTime.now().difference(deadline) >
        _iosExpiredPreSosPromotionTtl) {
      blockedReason = 'stale_presos_snapshot';
    } else if (cycleKey == null || nodeId == null) {
      blockedReason = 'missing_device_cycle_identity';
    } else if (_isClosedDeviceRuntimeIncidentId(incidentId)) {
      blockedReason = 'terminal_cancel_snapshot_wins';
    } else if (_iosExpiredPreSosPromotionKeys.contains(cycleKey)) {
      blockedReason = 'duplicate_cycle';
    } else if (_deviceOriginatedBackendSyncInFlight.contains(cycleKey)) {
      blockedReason = 'backend_publish_in_flight';
    }
    if (blockedReason != null) {
      BleDebugRegistry.instance.recordEvent(
        'IOS_BLE_SOS_EXPIRED_PRESOS_SKIPPED trigger=$trigger '
        'reason=$blockedReason cycle=${cycleKey ?? "none"}',
      );
      return;
    }

    final existingIncident = await sosRepository.getCurrentIncident();
    if (_hasNonRuntimeVisibleSosIncident(existingIncident)) {
      final deliveryChannel =
          existingIncident!.deliveryChannel ??
          SosDeliveryChannel.backendAndDevice;
      _recordPublicSosResult(
        incident: existingIncident.copyWith(deliveryChannel: deliveryChannel),
        deliveryChannel: deliveryChannel,
      );
      _iosExpiredPreSosPromotionKeys.add(cycleKey!);
      BleDebugRegistry.instance.recordEvent(
        'IOS_BLE_SOS_EXPIRED_PRESOS_SKIPPED trigger=$trigger '
        'reason=backend_incident_already_active cycle=$cycleKey '
        'incidentId=${existingIncident.id}',
      );
      return;
    }

    _iosExpiredPreSosPromotionKeys.add(cycleKey!);
    _deviceOriginatedBackendSyncInFlight.add(cycleKey);
    _emitPublicSosState(SosState.sending, source: trigger);
    BleDebugRegistry.instance.recordEvent(
      'IOS_BLE_SOS_EXPIRED_PRESOS_PROMOTE trigger=$trigger '
      'cycle=$cycleKey nodeId=$nodeId packetId=${packetId ?? "none"}',
    );
    BleDebugRegistry.instance.recordEvent(
      'IOS_BLE_SOS_EXPIRED_PRESOS_BACKEND_PUBLISH_START trigger=$trigger '
      'cycle=$cycleKey nodeId=$nodeId',
    );
    try {
      final incident = await sosRepository.triggerSos(
        message: 'Device SOS countdown elapsed',
        triggerSource: 'ble_device_runtime_status',
        deviceId: nodeId.toString(),
        originatorNodeId: nodeId,
        incidentId: incidentId,
        cycleKey: cycleKey,
      );
      final deliveryChannel =
          incident.deliveryChannel ?? SosDeliveryChannel.backendAndDevice;
      _recordPublicSosResult(
        incident: incident.copyWith(
          deliveryChannel: deliveryChannel,
          originatorNodeId: incident.originatorNodeId ?? nodeId,
          cycleKey: incident.cycleKey ?? cycleKey,
        ),
        deliveryChannel: deliveryChannel,
      );
      BleDebugRegistry.instance.recordEvent(
        'IOS_BLE_SOS_EXPIRED_PRESOS_PROMOTE result=backend_published '
        'trigger=$trigger cycle=$cycleKey '
        'incidentId=${incident.id}',
      );
    } catch (error) {
      _iosExpiredPreSosPromotionKeys.remove(cycleKey);
      BleDebugRegistry.instance.recordEvent(
        'IOS_BLE_SOS_EXPIRED_PRESOS_BACKEND_PUBLISH_BLOCKED '
        'trigger=$trigger cycle=$cycleKey '
        'error=${_compactDiagnosticValue(error)}',
      );
      _emitPublicSosState(
        SosState.sending,
        source: '${trigger}_publish_failed',
      );
    } finally {
      _deviceOriginatedBackendSyncInFlight.remove(cycleKey);
    }
  }

  Future<void> _syncNativePreSosBackendPending({
    required String trigger,
    int maxAttempts = 1,
    Duration retryDelay = const Duration(milliseconds: 250),
  }) async {
    Object? lastError;
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final incident = await sosRepository.getCurrentIncident();
        if (_hasNonRuntimeVisibleSosIncident(incident)) {
          final deliveryChannel =
              incident!.deliveryChannel ?? SosDeliveryChannel.backendAndDevice;
          _recordPublicSosResult(
            incident: incident.copyWith(deliveryChannel: deliveryChannel),
            deliveryChannel: deliveryChannel,
          );
          final pending = await protectionPlatformAdapter
              .peekPendingNativeSosCreate();
          if (pending != null &&
              !await _ackPendingNativeSosCreateIfMatchesIncident(
                pending: pending,
                incident: incident,
                source: 'sync_native_pending',
                reason: 'current_incident_confirmed',
              )) {
            await _reconcileUnmatchedPendingNativeSosCreate(
              pending,
              confirmedIncident: incident,
              trigger: trigger,
              source: 'sync_native_pending',
              reason: 'current_incident_mismatch',
            );
          }
          BleDebugRegistry.instance.recordEvent(
            '[NATIVE_PRE_SOS_BACKEND] action=backend_confirmed '
            'trigger=$trigger incidentId=${incident.id} '
            'state=${incident.state.name} attempt=$attempt',
          );
          return;
        }
        await _publishNativePreSosPendingOverMqtt(
          trigger: trigger,
          attempt: attempt,
        );
        BleDebugRegistry.instance.recordEvent(
          '[NATIVE_PRE_SOS_BACKEND] action=await_backend_confirmation '
          'trigger=$trigger reason=no_backend_incident attempt=$attempt',
        );
      } catch (error) {
        lastError = error;
        BleDebugRegistry.instance.recordEvent(
          '[NATIVE_PRE_SOS_BACKEND] action=await_backend_confirmation_failed '
          'trigger=$trigger attempt=$attempt '
          'error=${_compactDiagnosticValue(error)}',
        );
      }
      if (attempt < attempts) {
        await Future<void>.delayed(retryDelay);
      }
    }
    if (lastError != null) {
      BleDebugRegistry.instance.recordEvent(
        '[NATIVE_PRE_SOS_BACKEND] action=backend_confirmation_exhausted '
        'trigger=$trigger attempts=$attempts '
        'lastError=${_compactDiagnosticValue(lastError)}',
      );
    }
    _emitPublicSosState(SosState.sending, source: trigger);
  }

  Future<void> _publishNativePreSosPendingOverMqtt({
    required String trigger,
    required int attempt,
  }) async {
    try {
      await _flushPendingNativeSosCreateOverMqtt(
        trigger: trigger,
        attempt: attempt,
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        '[NATIVE_PRE_SOS_BACKEND] action=mqtt_publish_failed '
        'trigger=$trigger attempt=$attempt '
        'error=${_compactDiagnosticValue(error)}',
      );
    }
  }

  Future<void> _flushPendingNativeSosCreateOverMqtt({
    required String trigger,
    required int attempt,
  }) async {
    final pending = await protectionPlatformAdapter
        .peekPendingNativeSosCreate();
    if (pending == null) {
      return;
    }
    if (!_nativeSosCreateFlushInFlight.add(pending.signature)) {
      BleDebugRegistry.instance.recordEvent(
        'NATIVE_SOS_DUPLICATE_SUPPRESSED signature=${pending.signature} '
        'reason=flush_in_flight trigger=$trigger',
      );
      return;
    }
    try {
      if (_terminalWatermarkRejectsRestoredEvidence(
        observedAt: pending.updatedAt,
        nodeId: pending.nodeId,
        cycleKey: pending.cycleKey,
      )) {
        await protectionPlatformAdapter.dropPendingNativeSosCreate(
          pending.signature,
          reason: 'authoritative_terminal_watermark',
        );
        BleDebugRegistry.instance.recordEvent(
          'SOS_TERMINAL_WATERMARK_REJECTED source=native_pending_create',
        );
        return;
      }
      if (await _dropPendingNativeSosCreateIfCancelled(
        pending,
        trigger: trigger,
      )) {
        return;
      }
      final confirmedIncident = await sosRepository.getCurrentIncident();
      if (_hasNonRuntimeVisibleSosIncident(confirmedIncident)) {
        final acked = await _ackPendingNativeSosCreateIfMatchesIncident(
          pending: pending,
          incident: confirmedIncident!,
          source: 'mqtt_flush',
          reason: 'already_confirmed',
        );
        if (!acked) {
          await _reconcileUnmatchedPendingNativeSosCreate(
            pending,
            confirmedIncident: confirmedIncident,
            trigger: trigger,
            source: 'mqtt_flush',
            reason: 'current_incident_mismatch',
          );
        }
        return;
      }
      if (pending.state == 'mqtt_published_pending_backend_confirm') {
        if (await _dropExpiredPendingNativeSosCreate(
          pending,
          source: 'mqtt_published_pending_backend_confirm',
          reason: 'backend_confirm_timeout',
          ttl: _nativePendingSosBackendConfirmTtl,
          referenceAt: pending.lastPublishedAt ?? pending.updatedAt,
        )) {
          return;
        }
        await _retainPendingNativeSosCreate(
          pending,
          source: 'mqtt_published_pending_backend_confirm',
          reason: 'await_backend_confirm',
          trigger: trigger,
        );
        return;
      }
      if (await _dropStalePendingNativeSosCreate(pending, trigger: trigger)) {
        return;
      }

      await protectionPlatformAdapter
          .markPendingNativeSosCreateMqttFlushStarted(pending.signature);
      final status = await deviceSosController.getStatus();
      BleDebugRegistry.instance.recordEvent(
        'NATIVE_SOS_MQTT_FLUSH_START signature=${pending.signature} '
        'incidentId=${pending.incidentId} cycleKey=${pending.cycleKey} '
        'trigger=$trigger attempt=$attempt state=${status.state.name}',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRANSPORT_DECISION flow=sos_trigger transport=mqtt '
        'source=${pending.triggerSource} reason=native_pending_create_flush '
        'trigger=$trigger attempt=$attempt state=${status.state.name}',
      );

      final positionSnapshot = await _loadPositionSnapshotForSos();
      if (positionSnapshot == null) {
        BleDebugRegistry.instance.recordEvent(
          'NATIVE_SOS_MQTT_FLUSH continuing without position snapshot '
          'signature=${pending.signature} '
          'reason=location_never_blocks_activation',
        );
      }

      final localIdentity = await _resolveLocalOperationalSosIdentity();
      final originatorNodeId =
          pending.nodeId ?? status.nodeId ?? _knownLocalDeviceNodeId;
      if (originatorNodeId != null) {
        _promoteDeviceNodeIdFromSos(
          nodeId: originatorNodeId,
          source: 'native_pending_sos_create',
        );
      }
      if (_shouldBlockDeviceOriginPreSosBackendPublish(
        source: 'native_pending_sos_create',
        triggerSource: pending.triggerSource,
        cycleKey: pending.cycleKey,
        originatorNodeId: originatorNodeId,
        packetId: null,
      )) {
        await protectionPlatformAdapter.retainPendingNativeSosCreate(
          pending.signature,
          reason: 'device_pre_sos_terminal_cancel',
        );
        return;
      }
      await sosRepository.triggerSos(
        message: 'E_SOS_NATIVE_PENDING_BACKEND_SYNC_MQTT',
        triggerSource: pending.triggerSource,
        positionSnapshot: positionSnapshot,
        deviceId:
            pending.deviceId ??
            originatorNodeId?.toString() ??
            localIdentity.deviceId,
        hardwareId: pending.hardwareId ?? localIdentity.hardwareId,
        originatorNodeId: originatorNodeId,
        incidentId: pending.incidentId,
        cycleKey: pending.cycleKey,
      );
      await protectionPlatformAdapter.markPendingNativeSosCreateMqttPublished(
        pending.signature,
      );
      BleDebugRegistry.instance.recordEvent(
        'NATIVE_SOS_MQTT_FLUSH_RESULT signature=${pending.signature} '
        'success=true incidentId=${pending.incidentId}',
      );

      final afterPublishIncident = await sosRepository.getCurrentIncident();
      if (_hasNonRuntimeVisibleSosIncident(afterPublishIncident)) {
        final acked = await _ackPendingNativeSosCreateIfMatchesIncident(
          pending: pending,
          incident: afterPublishIncident!,
          source: 'mqtt_flush',
          reason: 'backend_confirmed',
        );
        if (!acked) {
          await _reconcileUnmatchedPendingNativeSosCreate(
            pending,
            confirmedIncident: afterPublishIncident,
            trigger: trigger,
            source: 'mqtt_flush',
            reason: 'post_publish_current_incident_mismatch',
          );
        }
      } else {
        await _retainPendingNativeSosCreate(
          pending,
          source: 'mqtt_flush',
          reason: 'mqtt_published_pending_backend_confirm',
          trigger: trigger,
        );
      }
    } catch (error) {
      await protectionPlatformAdapter.retainPendingNativeSosCreate(
        pending.signature,
        reason: 'mqtt_flush_failed',
      );
      BleDebugRegistry.instance.recordEvent(
        'NATIVE_SOS_MQTT_FLUSH_RESULT signature=${pending.signature} '
        'success=false error=${_compactDiagnosticValue(error)}',
      );
      rethrow;
    } finally {
      _nativeSosCreateFlushInFlight.remove(pending.signature);
    }
  }

  Future<bool> _ackPendingNativeSosCreateIfMatchesIncident({
    required ProtectionPendingNativeSosCreate pending,
    required SosIncident incident,
    required String source,
    required String reason,
  }) async {
    if (!_pendingNativeSosCreateMatchesIncident(
      pending: pending,
      incident: incident,
    )) {
      return false;
    }
    await protectionPlatformAdapter.ackPendingNativeSosCreate(
      pending.signature,
      backendIncidentId: incident.id,
    );
    BleDebugRegistry.instance.recordEvent(
      'NATIVE_SOS_PENDING_ACKED source=$source reason=$reason '
      'incidentId=${incident.id} cycleKey=${incident.cycleKey ?? pending.cycleKey} '
      'signature=${pending.signature}',
    );
    return true;
  }

  bool _pendingNativeSosCreateMatchesIncident({
    required ProtectionPendingNativeSosCreate pending,
    required SosIncident incident,
  }) {
    if (_sameNonEmptyIdentifier(pending.incidentId, incident.id)) {
      return true;
    }
    if (_sameNonEmptyIdentifier(pending.cycleKey, incident.cycleKey)) {
      return true;
    }
    if (_sameNonEmptyIdentifier(pending.correlationId, incident.message)) {
      return true;
    }
    if (_sameNonEmptyIdentifier(pending.deviceId, incident.deviceId)) {
      return true;
    }
    if (_sameNonEmptyIdentifier(pending.hardwareId, incident.hardwareId)) {
      return true;
    }
    return pending.nodeId != null &&
        incident.originatorNodeId != null &&
        _normalizeNodeId(pending.nodeId!) ==
            _normalizeNodeId(incident.originatorNodeId!);
  }

  bool _sameNonEmptyIdentifier(String? left, String? right) {
    final normalizedLeft = left?.trim();
    final normalizedRight = right?.trim();
    return normalizedLeft != null &&
        normalizedLeft.isNotEmpty &&
        normalizedRight != null &&
        normalizedRight.isNotEmpty &&
        normalizedLeft == normalizedRight;
  }

  Future<void> _reconcileUnmatchedPendingNativeSosCreate(
    ProtectionPendingNativeSosCreate pending, {
    required SosIncident confirmedIncident,
    required String trigger,
    required String source,
    required String reason,
  }) async {
    if (await _dropExpiredPendingNativeSosCreate(
      pending,
      source: source,
      reason: reason,
    )) {
      return;
    }
    await _retainPendingNativeSosCreate(
      pending,
      source: source,
      reason: reason,
      trigger: trigger,
      extra: 'currentIncidentId=${confirmedIncident.id}',
    );
  }

  Future<bool> _dropStalePendingNativeSosCreate(
    ProtectionPendingNativeSosCreate pending, {
    required String trigger,
  }) async {
    if (_publicSosState != SosState.idle &&
        _publicSosState != SosState.failed) {
      return _dropExpiredPendingNativeSosCreate(
        pending,
        source: 'native_pending_cleanup',
        reason: 'pending_create_ttl',
      );
    }
    final status = deviceSosController.currentStatus;
    final runtimeOpen =
        status.state == DeviceSosState.preConfirm ||
        status.state == DeviceSosState.active ||
        status.state == DeviceSosState.acknowledged ||
        _hasActivePreSosSession ||
        _hasActiveDeviceRuntimeSosOwnership();
    if (runtimeOpen) {
      return _dropExpiredPendingNativeSosCreate(
        pending,
        source: 'native_pending_cleanup',
        reason: 'pending_create_ttl',
      );
    }
    if (DateTime.now().toUtc().difference(pending.createdAt.toUtc()) <
        _nativePendingSosCreateTtl) {
      await _retainPendingNativeSosCreate(
        pending,
        source: 'native_pending_cleanup',
        reason: 'recent_idle_or_failed_without_active_incident',
        trigger: trigger,
      );
      return false;
    }
    final dropped = await protectionPlatformAdapter.dropPendingNativeSosCreate(
      pending.signature,
      reason: 'stale_idle_or_failed_without_active_incident',
    );
    if (dropped) {
      BleDebugRegistry.instance.recordEvent(
        'NATIVE_SOS_PENDING_STALE_DROPPED source=native_pending_cleanup '
        'reason=idle_or_failed_without_active_incident '
        'signature=${pending.signature} incidentId=${pending.incidentId} '
        'cycleKey=${pending.cycleKey} trigger=$trigger',
      );
    }
    return dropped;
  }

  Future<bool> _dropExpiredPendingNativeSosCreate(
    ProtectionPendingNativeSosCreate pending, {
    required String source,
    required String reason,
    Duration ttl = _nativePendingSosCreateTtl,
    DateTime? referenceAt,
  }) async {
    final reference = (referenceAt ?? pending.createdAt).toUtc();
    final age = DateTime.now().toUtc().difference(reference);
    if (age < ttl) {
      return false;
    }
    final dropped = await protectionPlatformAdapter.dropPendingNativeSosCreate(
      pending.signature,
      reason: reason,
    );
    if (dropped) {
      BleDebugRegistry.instance.recordEvent(
        'NATIVE_SOS_PENDING_EXPIRED source=$source reason=$reason '
        'signature=${pending.signature} incidentId=${pending.incidentId} '
        'cycleKey=${pending.cycleKey} ageSeconds=${age.inSeconds}',
      );
    }
    return dropped;
  }

  Future<void> _retainPendingNativeSosCreate(
    ProtectionPendingNativeSosCreate pending, {
    required String source,
    required String reason,
    required String trigger,
    String? extra,
  }) async {
    await protectionPlatformAdapter.retainPendingNativeSosCreate(
      pending.signature,
      reason: reason,
    );
    BleDebugRegistry.instance.recordEvent(
      'NATIVE_SOS_PENDING_RETAINED source=$source reason=$reason '
      'signature=${pending.signature} incidentId=${pending.incidentId} '
      'cycleKey=${pending.cycleKey} state=${pending.state} trigger=$trigger'
      '${extra == null ? "" : " $extra"}',
    );
  }

  Future<bool> _dropPendingNativeSosCreateIfCancelled(
    ProtectionPendingNativeSosCreate pending, {
    required String trigger,
  }) async {
    if (_publicSosState == SosState.cancelled ||
        _publicSosState == SosState.resolved) {
      final dropped = await protectionPlatformAdapter
          .dropPendingNativeSosCreate(
            pending.signature,
            reason: 'public_terminal:${_publicSosState.name}',
          );
      if (dropped) {
        BleDebugRegistry.instance.recordEvent(
          'NATIVE_SOS_PENDING_DROPPED_CANCELLED '
          'signature=${pending.signature} trigger=$trigger '
          'state=${_publicSosState.name}',
        );
      }
      return dropped;
    }
    try {
      final snapshot = await protectionPlatformAdapter.getPlatformSnapshot();
      if (snapshot.preSosLifecycleState == 'cancelPending') {
        final dropped = await protectionPlatformAdapter
            .dropPendingNativeSosCreate(
              pending.signature,
              reason: 'native_cancel_pending',
            );
        if (dropped) {
          BleDebugRegistry.instance.recordEvent(
            'NATIVE_SOS_PENDING_DROPPED_CANCELLED '
            'signature=${pending.signature} trigger=$trigger '
            'state=native_cancel_pending',
          );
        }
        return dropped;
      }
    } catch (_) {
      // Keep the pending create if the native snapshot is temporarily unavailable.
    }
    return false;
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
    SosTriggerPayload? activationPayload,
    bool emitNotificationIntent = true,
    bool publishStatus = true,
  }) {
    if (_sosLifecycle.activeTerminalWatermark != null &&
        !_hasNewAuthoritativeGenerationSinceTerminal()) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_FENCE_SUPPRESSED_OPEN source=pre_sos '
        'reason=authoritative_backend_terminal',
      );
      return;
    }
    _clearTerminalPublicSosFallbackForNewOpenFlow();
    final session = _preSosSession;
    final createdSession = session == null;
    final effectiveCycleKey =
        cycleKey ?? session?.cycleKey ?? _newLocalPreSosCycleKey(startedAt);
    final preservedBridge = _matchingRecentAppOriginBridgeForSession(
      owner: owner,
      mirroredOnDevice: mirroredOnDevice,
      origin: origin,
      originatorNodeId: originatorNodeId,
    );
    if (preservedBridge != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_ORIGIN_BRIDGE_PRESERVED '
        'reason=ignore_non_mirrored_duplicate '
        'appCycleKey=${preservedBridge.cycleKey} '
        'nodeId=${preservedBridge.originatorNodeId?.toString() ?? originatorNodeId?.toString() ?? "-"}',
      );
      _syncPreSosSession(
        startedAt: preservedBridge.startedAt,
        expectedActivationAt: preservedBridge.expectedActivationAt,
        mirroredOnDevice: true,
        origin: DeviceSosTransitionSource.app,
        owner: _SosOwner.app,
        cycleKey: preservedBridge.cycleKey,
        originatorNodeId: preservedBridge.originatorNodeId ?? originatorNodeId,
        packetId: packetId,
        activationPayload: activationPayload,
        emitNotificationIntent: false,
        publishStatus: publishStatus,
      );
      return;
    }
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
        activationPayload: activationPayload ?? const SosTriggerPayload(),
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
      final sameOriginNode =
          session.originatorNodeId != null &&
          originatorNodeId != null &&
          session.originatorNodeId == originatorNodeId;
      final preserveExistingCycle =
          sameCycle || (sameCountdownWindow && sameOriginNode);
      final resolvedCycleKey = preserveExistingCycle
          ? session.cycleKey
          : effectiveCycleKey;
      final resolvedPacketId = preserveExistingCycle
          ? session.packetId ?? packetId
          : packetId;
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
        activationPayload: activationPayload ?? session.activationPayload,
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
    _rememberRecentAppOriginMirroredPreSosBridge(_preSosSession!);
    if (createdSession && emitNotificationIntent) {
      _emitPreSosNotificationIntent(_preSosSession!);
    }
    unawaited(_persistPreSosSession(_preSosSession!));
    if (publishStatus) {
      _publishPreSosStatus(_buildCurrentPreSosStatus());
    }
  }

  Future<void> _restorePersistedPreSosSession({required String trigger}) async {
    if (_preSosSession != null) {
      return;
    }
    final raw = await _localStore.readJson(
      SharedPrefsSdkStore.preSosSessionKey,
    );
    if (raw == null) {
      return;
    }
    final startedAt = _parsePersistedDateTime(raw['startedAt']);
    final expectedActivationAt = _parsePersistedDateTime(
      raw['expectedActivationAt'],
    );
    final owner = _parsePersistedPreSosOwner(raw['owner']);
    if (startedAt == null || expectedActivationAt == null || owner == null) {
      await _clearPersistedPreSosSession();
      return;
    }
    if (_terminalWatermarkRejectsRestoredEvidence(
      observedAt: startedAt,
      nodeId: raw['originatorNodeId'] as int?,
      cycleKey: raw['cycleKey'] as String?,
    )) {
      await _clearPersistedPreSosSession();
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_WATERMARK_REJECTED source=persisted_pre_sos',
      );
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
      activationPayload: LocalStateSerializers.sosTriggerPayloadFromJson(
        raw['activationPayload'] is Map<String, dynamic>
            ? raw['activationPayload'] as Map<String, dynamic>
            : null,
      ),
      emitNotificationIntent: false,
      publishStatus: DateTime.now().isBefore(expectedActivationAt),
    );
    if (owner == _SosOwner.app && _pendingSosActivation == null) {
      final lifecycle = await _sosLifecycle.beginArming(
        origin: SosLifecycleOrigin.localApp,
        triggerSource: _preSosSession?.activationPayload.triggerSource,
        nodeId: _preSosSession?.originatorNodeId,
      );
      _pendingSosActivation = _PendingSosActivationOperation(
        generation: lifecycle.generation,
        lifecycleRevision: lifecycle.revision,
        operationRevision: ++_pendingSosActivationRevision,
      );
    }
    BleDebugRegistry.instance.recordEvent(
      '[PRE_SOS_CYCLE] action=restore_persisted trigger=$trigger '
      'cycle=${raw['cycleKey'] ?? "-"} '
      'deadline=${expectedActivationAt.toUtc().toIso8601String()}',
    );
    await _settleExpiredPreSosSession(trigger: 'restore_persisted:$trigger');
  }

  Future<void> _persistPreSosSession(_PreSosSession session) async {
    await _localStore
        .saveJson(SharedPrefsSdkStore.preSosSessionKey, <String, dynamic>{
          'cycleKey': session.cycleKey,
          'owner': session.owner.name,
          'startedAt': session.startedAt.toUtc().toIso8601String(),
          'expectedActivationAt': session.expectedActivationAt
              .toUtc()
              .toIso8601String(),
          'mirroredOnDevice': session.mirroredOnDevice,
          if (session.origin != null) 'origin': session.origin!.name,
          if (session.originatorNodeId != null)
            'originatorNodeId': session.originatorNodeId,
          if (session.packetId != null) 'packetId': session.packetId,
          'activationPayload': LocalStateSerializers.sosTriggerPayloadToJson(
            session.activationPayload,
          ),
        });
  }

  Future<void> _clearPersistedPreSosSession() {
    return _localStore.remove(SharedPrefsSdkStore.preSosSessionKey);
  }

  Future<bool> _rememberOsSosWidgetAction(String idempotencyKey) async {
    final now = DateTime.now().toUtc();
    final persisted = await _localStore.readJson(
      SharedPrefsSdkStore.osSosWidgetRecentActionsKey,
    );
    if (persisted != null) {
      for (final entry in persisted.entries) {
        final seenAtRaw = entry.value;
        if (seenAtRaw is! String) {
          continue;
        }
        final seenAt = DateTime.tryParse(seenAtRaw)?.toUtc();
        if (seenAt != null) {
          _recentOsSosWidgetActions[entry.key] = seenAt;
        }
      }
    }
    _recentOsSosWidgetActions.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _osSosWidgetActionDedupeWindow,
    );
    if (_recentOsSosWidgetActions.containsKey(idempotencyKey)) {
      BleDebugRegistry.instance.recordEvent(
        '[OS_SOS_WIDGET] action=duplicate_ignored key=$idempotencyKey',
      );
      return false;
    }
    _recentOsSosWidgetActions[idempotencyKey] = now;
    await _localStore.saveJson(
      SharedPrefsSdkStore.osSosWidgetRecentActionsKey,
      _recentOsSosWidgetActions.map(
        (key, value) => MapEntry(key, value.toUtc().toIso8601String()),
      ),
    );
    return true;
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

  Future<bool> _settleExpiredPreSosSession({required String trigger}) async {
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

  void _clearStaleTerminalRuntimeResidueForFreshAppSosStart() {
    final fallback = _publicSosFallbackIncident;
    final residueId =
        fallback?.id ??
        (_isTerminalPublicSosState(_publicSosState)
            ? _currentDeviceRuntimeUiIncidentId()
            : null);
    final residueState = fallback?.state ?? _publicSosState;
    if (!_isTerminalPublicSosState(residueState) ||
        !_isDeviceRuntimeSosIncidentId(residueId)) {
      return;
    }
    final status = deviceSosController.currentStatus;
    if (_isSosCycleNotifiable(status.state)) {
      return;
    }
    final residueNodeId = _parseDeviceRuntimeNodeId(residueId);
    final currentNodeId = _appOriginRuntimeNodeId(status);
    if (residueNodeId != null &&
        currentNodeId != null &&
        residueNodeId != currentNodeId) {
      return;
    }
    if (fallback?.id == residueId) {
      _publicSosFallbackIncident = null;
    }
    if (_lastKnownActiveSosIncident?.id == residueId) {
      _lastKnownActiveSosIncident = null;
      _lastLoggedActiveIncidentPreservationSignature = null;
    }
    if (_lastPublicSosIncidentId == residueId) {
      _lastPublicSosIncidentId = null;
      _lastPublicSosDeliveryChannel = null;
      _lastPublicSosTerminalReason = null;
    }
    _closedDeviceRuntimeIncidentIds.remove(residueId);
    _clearDeviceRuntimeSosOwnership(reason: 'fresh_app_sos_start');
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_STALE_TERMINAL_RESIDUE_CLEARED '
      'reason=fresh_app_sos_start '
      'incidentId=$residueId '
      'nodeId=${residueNodeId?.toString() ?? currentNodeId?.toString() ?? "-"}',
    );
  }

  bool _clearStaleCancelledRuntimeFallbackDuringAppArming({
    required String source,
  }) {
    final fallback = _publicSosFallbackIncident;
    if (fallback == null ||
        fallback.state != SosState.cancelled ||
        !_isDeviceRuntimeSosIncidentId(fallback.id)) {
      return false;
    }
    final hasAppArming =
        (_preSosSession?.owner == _SosOwner.app &&
            _buildCurrentPreSosStatus() != null) ||
        (_publicSosState == SosState.arming &&
            _recentAppOriginMirroredPreSosBridge != null);
    if (!hasAppArming || _publicSosClosureInFlight != null) {
      return false;
    }
    final expectedNodeId =
        _preSosSession?.originatorNodeId ??
        _recentAppOriginMirroredPreSosBridge?.originatorNodeId;
    final fallbackNodeId = _parseDeviceRuntimeNodeId(fallback.id);
    if (expectedNodeId != null &&
        fallbackNodeId != null &&
        expectedNodeId != fallbackNodeId) {
      return false;
    }
    _publicSosFallbackIncident = null;
    if (_lastKnownActiveSosIncident?.id == fallback.id) {
      _lastKnownActiveSosIncident = null;
      _lastLoggedActiveIncidentPreservationSignature = null;
    }
    if (_lastPublicSosIncidentId == fallback.id) {
      _lastPublicSosIncidentId = null;
      _lastPublicSosDeliveryChannel = null;
      _lastPublicSosTerminalReason = null;
    }
    _closedDeviceRuntimeIncidentIds.remove(fallback.id);
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_STALE_CANCELLED_RUNTIME_IGNORED '
      'reason=app_arming_active source=$source '
      'incidentId=${fallback.id} '
      'nodeId=${fallbackNodeId?.toString() ?? expectedNodeId?.toString() ?? "-"}',
    );
    if (_publicSosState != SosState.arming) {
      _emitPublicSosState(
        SosState.arming,
        source: '$source:stale_cancelled_runtime_ignored',
      );
    }
    return true;
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
        payload: <String, String>{
          'cycleKey': session.cycleKey,
          'startedAt': session.startedAt.toUtc().toIso8601String(),
          'expectedActivationAt': session.expectedActivationAt
              .toUtc()
              .toIso8601String(),
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
    final session = _preSosSession;
    final operation = _pendingSosActivation;
    final requiresPendingOperation = session?.owner == _SosOwner.app;
    if (requiresPendingOperation &&
        (operation == null || !_isPendingSosActivationCurrent(operation))) {
      _logLateSosActivationRejected(
        operation: operation,
        callbackSource: 'countdown_zero_before_device_status',
      );
      return;
    }
    final deviceStatus = await deviceSosController.getStatus();
    if (requiresPendingOperation &&
        !_isPendingSosActivationCurrent(operation!)) {
      _logLateSosActivationRejected(
        operation: operation,
        callbackSource: 'countdown_zero_after_device_status',
      );
      return;
    }
    if (_shouldBlockPreSosActivationForDeviceTerminalCancel(
      session: session,
      deviceStatus: deviceStatus,
      source: 'countdown_zero',
    )) {
      return;
    }
    final lifecycle = _sosLifecycle.current;
    final lifecycleOrigin = session?.owner == _SosOwner.device
        ? SosLifecycleOrigin.connectedLocalDevice
        : SosLifecycleOrigin.localApp;
    await _sosLifecycle.beginActivating(
      origin: lifecycleOrigin,
      triggerSource:
          session?.activationPayload.triggerSource ?? lifecycle.triggerSource,
      deviceId: lifecycle.deviceId,
      nodeId: session?.originatorNodeId ?? lifecycle.nodeId,
      hardwareId: lifecycle.hardwareId,
    );
    if (requiresPendingOperation &&
        !_isPendingSosActivationCurrent(operation!)) {
      _logLateSosActivationRejected(
        operation: operation,
        callbackSource: 'countdown_zero_after_begin_activating',
      );
      return;
    }
    try {
      final activation = confirmPreSos(
        session?.activationPayload ?? const SosTriggerPayload(),
      );
      final incident = await activation;
      if (operation != null && !operation.dispatchResult.isCompleted) {
        operation.dispatchResult.complete();
      }
      if (operation != null &&
          (!_isPendingSosActivationCurrent(operation) ||
              operation.cancellationRequested)) {
        _logLateSosActivationRejected(
          operation: operation,
          callbackSource: 'countdown_zero_repository_success',
        );
        return;
      }
      await _sosLifecycle.confirmActive(
        origin: lifecycleOrigin,
        localIncidentId: incident.id,
        backendIncidentId: _isLocalAppSosIncidentId(incident.id)
            ? null
            : incident.id,
        triggerSource: incident.triggerSource ?? lifecycle.triggerSource,
        deviceId: incident.deviceId ?? lifecycle.deviceId,
        nodeId:
            incident.originatorNodeId ??
            session?.originatorNodeId ??
            lifecycle.nodeId,
        hardwareId:
            lifecycle.hardwareId ??
            _physicalHardwareIdForStatus(_lastDeviceStatus) ??
            incident.hardwareId,
        incident: incident,
      );
      if (operation != null && identical(_pendingSosActivation, operation)) {
        _pendingSosActivation = null;
      }
    } on SosException catch (error) {
      if (operation != null && !operation.dispatchResult.isCompleted) {
        operation.dispatchResult.complete();
      }
      if ((operation != null && !_isPendingSosActivationCurrent(operation)) ||
          error.code == 'E_SOS_PENDING_ACTIVATION_CANCELLED') {
        _logLateSosActivationRejected(
          operation: operation,
          callbackSource: 'countdown_zero_repository_error',
        );
        return;
      }
      if (error.code != 'E_SOS_ALREADY_ACTIVE') {
        if (error.code == 'E_PRE_SOS_CANCELLED_BY_DEVICE') {
          return;
        }
        BleDebugRegistry.instance.recordEvent(
          '[APP_SOS_COUNTDOWN_ZERO] action=activate_failed '
          'errorType=${error.runtimeType} code=${error.code} '
          'message=${_compactDiagnosticValue(error.message)}',
        );
        _markCountdownZeroActivationFailed(
          terminalReason: _publicSosFailureReasonForTriggerError(
            backendError: error,
            backendUnavailable: _isBackendUnavailableForTrigger(error),
            deviceAvailable: deviceSosController.hasSosCommandPath,
          ),
        );
        await _sosLifecycle.activationFailed(error.code);
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'APP_SOS_COUNTDOWN_ZERO_ALREADY_ACTIVE_HANDLED',
      );
      await _rehydrateDeviceSosPublicState(
        trigger: 'countdown_zero_already_active',
        emitResolvedState: true,
      );
      await _sosLifecycle.requireRecovery(
        'E_SOS_ALREADY_ACTIVE_UNMATCHED',
        preserveLocalOwnership: false,
      );
    } catch (error) {
      if (operation != null && !operation.dispatchResult.isCompleted) {
        operation.dispatchResult.complete();
      }
      if (operation != null && !_isPendingSosActivationCurrent(operation)) {
        _logLateSosActivationRejected(
          operation: operation,
          callbackSource: 'countdown_zero_untyped_error',
        );
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        '[APP_SOS_COUNTDOWN_ZERO] action=activate_failed '
        'errorType=${error.runtimeType} '
        'message=${_compactDiagnosticValue(error)}',
      );
      _markCountdownZeroActivationFailed(
        terminalReason: SosTerminalReason.deliveryFailed,
      );
      await _sosLifecycle.activationFailed('E_SOS_ACTIVATION_FAILED');
    }
  }

  bool _isPendingSosActivationCurrent(
    _PendingSosActivationOperation operation,
  ) {
    final lifecycle = _sosLifecycle.current;
    return identical(_pendingSosActivation, operation) &&
        !operation.cancelled &&
        operation.operationRevision == _pendingSosActivationRevision &&
        lifecycle.generation == operation.generation &&
        !lifecycle.isTerminal;
  }

  bool _commitPendingSosDispatch(_PendingSosActivationOperation operation) {
    if (!_isPendingSosActivationCurrent(operation)) {
      _logLateSosActivationRejected(
        operation: operation,
        callbackSource: 'repository_dispatch_commit',
      );
      return false;
    }
    operation.dispatchCommitted = true;
    return true;
  }

  void _logPendingSosActivationCancel({
    required _PendingSosActivationOperation operation,
    required SosLifecycleStage stageBefore,
    required bool dispatchCommitted,
    required bool taskCancelled,
    required SosLifecycleStage terminalAfter,
    required SosCancellationOutcome result,
    required String source,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_PENDING_ACTIVATION_CANCEL '
      'generationPresent=${operation.generation > 0} '
      'lifecycleRevision=${operation.lifecycleRevision} '
      'stageBefore=${stageBefore.name} '
      'dispatchCommitted=$dispatchCommitted '
      'taskCancelled=$taskCancelled '
      'terminalAfter=${terminalAfter.name} '
      'result=${result.name} source=$source',
    );
  }

  void _logLateSosActivationRejected({
    required _PendingSosActivationOperation? operation,
    required String callbackSource,
  }) {
    final current = _sosLifecycle.current;
    BleDebugRegistry.instance.recordEvent(
      'SOS_LATE_ACTIVATION_REJECTED '
      'staleRevision=${operation?.lifecycleRevision ?? 0} '
      'currentRevision=${current.revision} '
      'staleGenerationPresent=${(operation?.generation ?? 0) > 0} '
      'currentGenerationPresent=${current.generation > 0} '
      'callbackSource=$callbackSource',
    );
  }

  bool _shouldBlockPreSosActivationForDeviceTerminalCancel({
    required _PreSosSession? session,
    required DeviceSosStatus deviceStatus,
    required String source,
  }) {
    if (session == null || session.owner != _SosOwner.device) {
      return false;
    }
    if (_hasMatchingPreSosTerminalCancelContext(
      cycleKey: session.cycleKey,
      originatorNodeId: session.originatorNodeId,
      packetId: session.packetId,
    )) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_PRE_SOS_ACTIVATION_BLOCKED_BY_TERMINAL_CANCEL '
        'source=$source cycleKey=${session.cycleKey} '
        'owner=${session.owner.name} '
        'origin=${session.origin?.name ?? "-"} '
        'originatorNodeId=${session.originatorNodeId?.toString() ?? "-"} '
        'packetId=${session.packetId?.toString() ?? "-"} '
        'deviceState=${deviceStatus.state.name}',
      );
      _clearPreSosSession(
        reason: 'remembered_device_terminal_cancel_blocks_activation',
        emitIdleState: true,
      );
      deviceSosController.clearPreSosLocally(
        reason: 'remembered_device_terminal_cancel_blocks_activation',
      );
      _setPublicSosTerminalSnapshot(
        state: SosState.cancelled,
        source: 'pre_sos_cancelled_by_device',
        terminalReason: SosTerminalReason.preSosCancelledByDevice,
        nodeId: session.originatorNodeId ?? deviceStatus.nodeId,
      );
      return true;
    }
    final terminalCancel =
        deviceStatus.state == DeviceSosState.inactive ||
        deviceStatus.state == DeviceSosState.resolved;
    if (!terminalCancel) {
      return false;
    }
    _rememberPreSosTerminalCancelContext(
      source: source,
      cycleKey: session.cycleKey,
      originatorNodeId: session.originatorNodeId,
      packetId: session.packetId,
      startedAt: session.startedAt,
      expectedActivationAt: session.expectedActivationAt,
    );
    _clearPreSosSession(
      reason: 'device_terminal_cancel_blocks_activation',
      emitIdleState: true,
    );
    deviceSosController.clearPreSosLocally(
      reason: 'device_terminal_cancel_blocks_activation',
    );
    _setPublicSosTerminalSnapshot(
      state: SosState.cancelled,
      source: 'pre_sos_cancelled_by_device',
      terminalReason: SosTerminalReason.preSosCancelledByDevice,
      nodeId: session.originatorNodeId ?? deviceStatus.nodeId,
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_PRE_SOS_ACTIVATION_BLOCKED_BY_TERMINAL_CANCEL '
      'source=$source cycleKey=${session.cycleKey} '
      'owner=${session.owner.name} '
      'origin=${session.origin?.name ?? "-"} '
      'originatorNodeId=${session.originatorNodeId?.toString() ?? "-"} '
      'packetId=${session.packetId?.toString() ?? "-"} '
      'deviceState=${deviceStatus.state.name}',
    );
    return true;
  }

  bool _shouldBlockDeviceOriginPreSosBackendPublish({
    required String source,
    required String? triggerSource,
    required String? cycleKey,
    required int? originatorNodeId,
    required int? packetId,
  }) {
    if (!_isDeviceOriginPreSosPublishCandidate(
      triggerSource: triggerSource,
      cycleKey: cycleKey,
    )) {
      return false;
    }
    if (!_hasMatchingPreSosTerminalCancelContext(
      cycleKey: cycleKey,
      originatorNodeId: originatorNodeId,
      packetId: packetId,
    )) {
      return false;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_PRE_SOS_BACKEND_PUBLISH_BLOCKED_BY_TERMINAL_CANCEL '
      'source=$source triggerSource=${triggerSource ?? "-"} '
      'cycleKey=${cycleKey ?? "-"} '
      'originatorNodeId=${originatorNodeId?.toString() ?? "-"} '
      'packetId=${packetId?.toString() ?? "-"}',
    );
    return true;
  }

  bool _isDeviceOriginPreSosPublishCandidate({
    required String? triggerSource,
    required String? cycleKey,
  }) {
    final normalizedTrigger = triggerSource?.trim();
    final normalizedCycle = cycleKey?.trim();
    return normalizedTrigger == 'ble_device_runtime_status' ||
        (normalizedCycle != null && normalizedCycle.startsWith('sos:'));
  }

  void _rememberPreSosTerminalCancelContext({
    required String source,
    required String? cycleKey,
    required int? originatorNodeId,
    required int? packetId,
    required DateTime? startedAt,
    required DateTime? expectedActivationAt,
  }) {
    final now = DateTime.now().toUtc();
    final expiresAt = (expectedActivationAt?.toUtc() ?? now).add(
      _preSosTerminalCancelGraceWindow,
    );
    final context = _PreSosTerminalCancelContext(
      cycleKey: cycleKey,
      originatorNodeId: originatorNodeId,
      packetId: packetId,
      startedAt: startedAt?.toUtc(),
      expectedActivationAt: expectedActivationAt?.toUtc(),
      observedAt: now,
      expiresAt: expiresAt.isAfter(now)
          ? expiresAt
          : now.add(_preSosTerminalCancelGraceWindow),
      source: source,
    );
    final keys = _preSosTerminalCancelContextKeys(
      cycleKey: cycleKey,
      originatorNodeId: originatorNodeId,
      packetId: packetId,
    ).toList();
    if (keys.isEmpty) {
      return;
    }
    _prunePreSosTerminalCancelContexts(now);
    for (final key in keys) {
      _preSosTerminalCancelContextByKey[key] = context;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_PRE_SOS_TERMINAL_CANCEL_CONTEXT_SET '
      'source=$source cycleKey=${cycleKey ?? "-"} '
      'originatorNodeId=${originatorNodeId?.toString() ?? "-"} '
      'packetId=${packetId?.toString() ?? "-"} '
      'startedAt=${startedAt?.toUtc().toIso8601String() ?? "-"} '
      'deadline=${expectedActivationAt?.toUtc().toIso8601String() ?? "-"} '
      'expiresAt=${context.expiresAt.toIso8601String()}',
    );
  }

  bool _hasMatchingPreSosTerminalCancelContext({
    required String? cycleKey,
    required int? originatorNodeId,
    required int? packetId,
  }) {
    final now = DateTime.now().toUtc();
    _prunePreSosTerminalCancelContexts(now);
    for (final key in _preSosTerminalCancelContextKeys(
      cycleKey: cycleKey,
      originatorNodeId: originatorNodeId,
      packetId: packetId,
    )) {
      final context = _preSosTerminalCancelContextByKey[key];
      if (context == null || now.isAfter(context.expiresAt)) {
        continue;
      }
      final deadline = context.expectedActivationAt;
      if (deadline != null &&
          now.isAfter(deadline.add(_preSosTerminalCancelGraceWindow))) {
        continue;
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS_PRE_SOS_TERMINAL_CANCEL_CONTEXT_MATCHED '
        'requestedCycleKey=${cycleKey ?? "-"} '
        'contextCycleKey=${context.cycleKey ?? "-"} '
        'requestedOriginatorNodeId=${originatorNodeId?.toString() ?? "-"} '
        'contextOriginatorNodeId=${context.originatorNodeId?.toString() ?? "-"} '
        'requestedPacketId=${packetId?.toString() ?? "-"} '
        'contextPacketId=${context.packetId?.toString() ?? "-"} '
        'startedAt=${context.startedAt?.toIso8601String() ?? "-"} '
        'deadline=${context.expectedActivationAt?.toIso8601String() ?? "-"} '
        'observedAt=${context.observedAt.toIso8601String()} '
        'source=${context.source}',
      );
      return true;
    }
    return false;
  }

  Iterable<String> _preSosTerminalCancelContextKeys({
    required String? cycleKey,
    required int? originatorNodeId,
    required int? packetId,
  }) sync* {
    final normalizedCycleKey = cycleKey?.trim();
    if (normalizedCycleKey != null && normalizedCycleKey.isNotEmpty) {
      yield 'cycle:$normalizedCycleKey';
    }
    if (originatorNodeId != null && packetId != null) {
      yield 'node_packet:$originatorNodeId:$packetId';
    }
    if (originatorNodeId != null) {
      yield 'node:$originatorNodeId';
    }
  }

  void _prunePreSosTerminalCancelContexts(DateTime now) {
    _preSosTerminalCancelContextByKey.removeWhere((_, context) {
      if (now.isAfter(context.expiresAt)) {
        return true;
      }
      return now.difference(context.observedAt) >
          _preSosTerminalCancelContextTtl;
    });
  }

  void _markCountdownZeroActivationFailed({
    String source = 'countdown_zero_activation_failed',
    SosTerminalReason terminalReason = SosTerminalReason.deliveryFailed,
  }) {
    _clearPreSosSession(reason: source, emitIdleState: false);
    _clearPendingAppTriggeredSosBridge(reason: source);
    _clearDeviceRuntimeSosOwnership(reason: source);
    _setPublicSosFailure(source: source, terminalReason: terminalReason);
  }

  void _setPublicSosFailure({
    required String source,
    required SosTerminalReason terminalReason,
  }) {
    _setPublicSosTerminalSnapshot(
      state: SosState.failed,
      source: source,
      terminalReason: terminalReason,
    );
  }

  void _setPublicSosTerminalSnapshot({
    required SosState state,
    required String source,
    required SosTerminalReason terminalReason,
    int? nodeId,
  }) {
    final now = DateTime.now().toUtc();
    final referenceIncident =
        _publicSosFallbackIncident ?? _lastKnownActiveSosIncident;
    final incidentId =
        referenceIncident?.id ??
        _lastPublicSosIncidentId ??
        (nodeId == null
            ? 'public-sos-terminal:${now.microsecondsSinceEpoch}'
            : 'device-runtime-sos:$nodeId:terminal');
    final incident = (referenceIncident == null
        ? SosIncident(
            id: incidentId,
            state: state,
            createdAt: now,
            triggerSource: source,
            deliveryChannel: _lastPublicSosDeliveryChannel,
            terminalReason: terminalReason,
            originKind: SosOriginKind.ownDevice,
            actionability: SosActionability.localActionable,
            displaySurface: SosDisplaySurface.activeAndHistory,
          )
        : referenceIncident.copyWith(
            state: state,
            deliveryChannel:
                referenceIncident.deliveryChannel ??
                _lastPublicSosDeliveryChannel,
            terminalReason: terminalReason,
          ));
    _lastPublicSosTerminalReason = terminalReason;
    _publicSosFallbackIncident = incident;
    _lastKnownActiveSosIncident = null;
    _lastPublicSosIncidentId = incident.id;
    _lastPublicSosDeliveryChannel = incident.deliveryChannel;
    _emitPublicSosState(state, source: source);
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

  int _computeRemainingSeconds({required DateTime expectedActivationAt}) {
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
    if (status.triggerOrigin == DeviceSosTransitionSource.device &&
        _activeDeviceRuntimeLocalCycleKey != null) {
      return _activeDeviceRuntimeLocalCycleKey;
    }
    if (status.triggerOrigin == DeviceSosTransitionSource.device &&
        _isDeviceSosCycleClosed(status.state) &&
        _lastClosedDeviceRuntimeLocalCycleKey != null) {
      return _lastClosedDeviceRuntimeLocalCycleKey;
    }
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
      final sameNode =
          session.originatorNodeId != null &&
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

  void _forceClearPublishedPreSosStatus({required String reason}) {
    if (_lastPublishedPreSosStatus == null) {
      return;
    }
    _lastPublishedPreSosStatus = null;
    if (!_publicPreSosStatusController.isClosed) {
      _publicPreSosStatusController.add(null);
    }
    BleDebugRegistry.instance.recordEvent(
      '[APP_PRE_SOS_CANCEL] action=published_status_forced_clear '
      'reason=$reason',
    );
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

  Future<void> _clearSosNotificationsSafely({required String reason}) async {
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
      if (kDebugMode) {
        safeSdkDebugPrint('SOS notification cleanup failed: $error');
      }
    }
  }

  void _clearPreSosSession({
    required String reason,
    required bool emitIdleState,
  }) {
    final session = _preSosSession;
    if (session == null) {
      _forceClearPublishedPreSosStatus(reason: reason);
      if (_shouldClearRecentAppOriginBridge(reason)) {
        _clearRecentAppOriginMirroredPreSosBridge(reason: reason);
      }
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
    _forceClearPublishedPreSosStatus(reason: reason);
    BleDebugRegistry.instance.recordEvent(
      'Public PRE-SOS session cleared -> reason=$reason origin=${session.origin?.name ?? "-"} owner=${session.owner.name} mirroredOnDevice=${session.mirroredOnDevice}',
    );
    BleDebugRegistry.instance.recordEvent(
      '[APP_PRE_SOS_CANCEL] action=state_cleared cycle=$cycleRevision',
    );
    if (_shouldClearRecentAppOriginBridge(reason)) {
      _clearRecentAppOriginMirroredPreSosBridge(reason: reason);
    }
    if (emitIdleState) {
      _emitPublicSosState(SosState.idle, source: reason);
    }
  }

  Future<void> _clearPreSosSessionDurably({
    required String reason,
    required bool emitIdleState,
  }) async {
    _clearPreSosSession(reason: reason, emitIdleState: emitIdleState);
    await _clearPersistedPreSosSession();
  }

  _TerminalDeviceCaptureSnapshot _captureTerminalDeviceSnapshot({
    required String reason,
  }) {
    final protection = _protectionModeController.currentStatus;
    final nativeOwner = _isProtectionPlatformOwningBle;
    final nativeGattConnected =
        protection.serviceBleConnected || protection.serviceBleReady;
    final rawDevice = _lastDeviceStatus;
    final publicDevice = _lastPublicDeviceStatus;
    final device = nativeOwner
        ? (publicDevice ?? rawDevice)
        : (rawDevice ?? publicDevice);
    final commandTarget = publicDevice ?? rawDevice;
    final capability = _computeCurrentSosCapabilitySnapshot(
      reason: reason,
      statusOverride: device,
      recordDiagnostics: false,
    );
    final transportConnected = nativeOwner
        ? nativeGattConnected
        : commandTarget?.connected == true;
    final identityPresent =
        commandTarget?.deviceId.trim().isNotEmpty == true &&
        (_physicalHardwareIdForStatus(commandTarget)?.isNotEmpty == true ||
            commandTarget?.nodeId != null);
    final connection = _CapturedPhysicalDeviceConnection(
      device: commandTarget,
      devicePresent:
          commandTarget?.connected == true &&
          transportConnected &&
          identityPresent,
      shortCommandReady: capability.shortCommandAvailable,
      commandChannelReady: capability.longCommandAvailable,
      nativeGattConnected: nativeGattConnected,
      owner: _currentDeviceCommandOwnerRoute,
      identityMarker: _terminalDeviceIdentityMarker(commandTarget),
    );
    return _TerminalDeviceCaptureSnapshot(
      connection: connection,
      deviceSos: deviceSosController.currentStatus,
      activePhysicalEvidence: deviceSosController.lastPhysicalReceiveEvidence,
    );
  }

  String _terminalDeviceIdentityMarker(DeviceStatus? device) {
    final identity =
        _physicalHardwareIdForStatus(device) ??
        device?.deviceId.trim() ??
        device?.nodeId?.toString() ??
        '';
    return SecurityDiagnosticsRedactor.stableIdentifierMarker(identity);
  }

  bool _capturedPhysicalDeviceConnectionIsCurrent(
    _CapturedPhysicalDeviceConnection captured,
  ) {
    if (!captured.devicePresent || captured.device == null) {
      return false;
    }
    final current = _captureTerminalDeviceSnapshot(
      reason: 'terminal_device_proof_current_validation',
    ).connection;
    final capturedHardwareId = _physicalHardwareIdForStatus(captured.device);
    final currentHardwareId = _physicalHardwareIdForStatus(current.device);
    final nodeMatches =
        captured.device?.nodeId == null ||
        current.device?.nodeId == null ||
        captured.device?.nodeId == current.device?.nodeId;
    return current.devicePresent &&
        nodeMatches &&
        _samePhysicalHardwareId(currentHardwareId, capturedHardwareId);
  }

  _PhysicalSosTerminationTarget? _captureCurrentPhysicalSosTarget({
    required SosLifecycleSnapshot lifecycle,
    required SosIncident terminalIncident,
    _TerminalDeviceCaptureSnapshot? capturedSnapshot,
  }) {
    final session = _session;
    final snapshot =
        capturedSnapshot ??
        _captureTerminalDeviceSnapshot(
          reason: 'remote_terminal_device_target_capture',
        );
    final connection = snapshot.connection;
    final device = connection.device;
    final deviceSos = snapshot.deviceSos;
    final terminalState = terminalIncident.state;
    final isBackendResolve = terminalState == SosState.resolved;
    if (session == null ||
        (!lifecycle.isOpen && !lifecycle.isTerminal) ||
        !lifecycle.localActionable ||
        lifecycle.externalOnly ||
        !terminalIncident.isBackendConfirmed ||
        (terminalState != SosState.cancelled &&
            terminalState != SosState.resolved)) {
      if (isBackendResolve) {
        _logBackendResolveDeviceMirror(
          incidentIdentityPresent: terminalIncident.id.trim().isNotEmpty,
          generation: lifecycle.generation,
          connectedDevicePresent: connection.devicePresent,
          commandChannelReady: connection.commandChannelReady,
          mirrorRequired: false,
          mirrorAttempted: false,
          reason: 'authoritative_lifecycle_identity_unproven',
        );
      }
      _logRemoteTerminalDeviceClearSkipped('lifecycle_unproven');
      return null;
    }
    final ownerScope = AuthoritativeSosLifecycleController.ownerScopeFor(
      session,
    );
    final connectedDeviceId = device?.deviceId.trim();
    final connectedHardwareId = _physicalHardwareIdForStatus(device);
    final lifecycleHardwareId = normalizeCanonicalHardwareId(
      lifecycle.hardwareId,
    );
    final nodeId = deviceSos.nodeId ?? lifecycle.nodeId ?? device?.nodeId;
    final packetId = deviceSos.packetId;
    final currentRuntimeCycleKey = _runtimeDeviceSosCycleKey(
      status: deviceSos,
      nodeId: _appOriginRuntimeNodeId(deviceSos),
    )?.trim();
    final activeObservedAt = deviceSos.lastPacketAt ?? deviceSos.updatedAt;
    final incidentIdentityPresent = terminalIncident.id.trim().isNotEmpty;
    final connectedDevicePresent = connection.devicePresent;
    final commandChannelReady = connection.commandChannelReady;
    final deviceSosOpen =
        deviceSos.state == DeviceSosState.preConfirm ||
        deviceSos.state == DeviceSosState.active ||
        deviceSos.state == DeviceSosState.acknowledged;
    final hardwareConflicts =
        lifecycleHardwareId != null &&
        lifecycleHardwareId.isNotEmpty &&
        connectedHardwareId != null &&
        !_samePhysicalHardwareId(connectedHardwareId, lifecycleHardwareId);
    final nodeConflicts =
        lifecycle.nodeId != null &&
        nodeId != null &&
        lifecycle.nodeId != nodeId;
    if (device == null ||
        !connectedDevicePresent ||
        connectedDeviceId == null ||
        connectedDeviceId.isEmpty ||
        connectedHardwareId == null ||
        (!isBackendResolve &&
            !connection.shortCommandReady &&
            !connection.commandChannelReady) ||
        hardwareConflicts ||
        nodeConflicts) {
      if (isBackendResolve) {
        _logBackendResolveDeviceMirror(
          incidentIdentityPresent: incidentIdentityPresent,
          generation: lifecycle.generation,
          connectedDevicePresent: connectedDevicePresent,
          commandChannelReady: commandChannelReady,
          mirrorRequired: deviceSosOpen && connectedDevicePresent,
          mirrorAttempted: false,
          reason: !connectedDevicePresent
              ? 'device_absence_policy'
              : !commandChannelReady
              ? 'ea04_command_channel_not_ready'
              : 'device_target_identity_mismatch',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS_REMOTE_TERMINAL_DEVICE_TARGET_REJECTED '
        'devicePresent=${device != null} connected=${device?.connected == true} '
        'commandPath=${connection.commandChannelReady} '
        'hardwareMatch=${!hardwareConflicts} nodeMatch=${!nodeConflicts}',
      );
      _logRemoteTerminalDeviceClearSkipped('device_target_mismatch');
      return null;
    }
    if (isBackendResolve && !deviceSosOpen) {
      _logBackendResolveDeviceMirror(
        incidentIdentityPresent: incidentIdentityPresent,
        generation: lifecycle.generation,
        connectedDevicePresent: connectedDevicePresent,
        commandChannelReady: commandChannelReady,
        mirrorRequired: false,
        mirrorAttempted: false,
        reason: 'physical_sos_already_terminal',
      );
      return null;
    }
    final proof = _PhysicalSosTerminationTarget(
      lifecycleId: lifecycle.lifecycleId,
      generation: lifecycle.generation,
      ownerScope: ownerScope,
      terminalState: terminalState,
      incidentId: terminalIncident.id,
      deviceId: connectedDeviceId,
      hardwareId: connectedHardwareId,
      nodeId: nodeId,
      runtimeCycleKey: currentRuntimeCycleKey,
      packetId: packetId,
      packetSignature: deviceSos.lastPacketSignature,
      deviceActiveObservedAt: activeObservedAt,
      activeReceiveSequence: snapshot.activePhysicalEvidence?.receiveSequence,
      activeReceiveSequenceDomain:
          snapshot.activePhysicalEvidence?.receiveSequenceDomain,
      capturedDevicePresent: connection.devicePresent,
      capturedCommandChannelReady: isBackendResolve
          ? connection.commandChannelReady
          : connection.shortCommandReady || connection.commandChannelReady,
      capturedNativeGattConnected: connection.nativeGattConnected,
      capturedOwner: connection.owner,
      capturedIdentityMarker: connection.identityMarker,
    );
    if (isBackendResolve) {
      _logBackendResolveDeviceMirror(
        incidentIdentityPresent: incidentIdentityPresent,
        generation: lifecycle.generation,
        connectedDevicePresent: connectedDevicePresent,
        commandChannelReady: commandChannelReady,
        mirrorRequired: true,
        mirrorAttempted: false,
        reason: commandChannelReady
            ? 'same_tag_active_sos_target_captured'
            : 'same_tag_active_sos_pending_ea04_readiness',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_ELIGIBLE '
      'terminal=${terminalState.name} lifecycleGeneration=${lifecycle.generation}',
    );
    return proof;
  }

  void _logRemoteTerminalDeviceClearSkipped(String reason) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_SKIPPED reason=$reason',
    );
  }

  void _logBackendResolveDeviceMirror({
    required bool incidentIdentityPresent,
    required int generation,
    required bool connectedDevicePresent,
    required bool commandChannelReady,
    required bool mirrorRequired,
    required bool mirrorAttempted,
    required String reason,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_RESOLVE_DEVICE_MIRROR '
      'incidentIdentityPresent=$incidentIdentityPresent generation=$generation '
      'connectedDevicePresent=$connectedDevicePresent '
      'commandChannelReady=$commandChannelReady mirrorRequired=$mirrorRequired '
      'mirrorAttempted=$mirrorAttempted command=SOS_ACK_0x07 reason=$reason',
    );
  }

  void _logBackendResolveDeviceResult({
    required _PhysicalSosTerminationTarget proof,
    required bool writeSubmitted,
    required bool writeSuccess,
    required bool physicalTerminalObserved,
    required String terminalPacketType,
    required String failureReason,
  }) {
    if (physicalTerminalObserved &&
        !_backendResolvePhysicalTerminalResultKeys.add(proof.operationKey)) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_RESOLVE_DEVICE_RESULT command=SOS_ACK_0x07 '
      'writeSubmitted=$writeSubmitted writeSuccess=$writeSuccess '
      'physicalTerminalObserved=$physicalTerminalObserved '
      'terminalPacketType=$terminalPacketType '
      'failureReason=$failureReason generation=${proof.generation}',
    );
  }

  void _logTerminalDeviceProofMismatch({
    required _PhysicalSosTerminationTarget proof,
    required String reason,
  }) {
    final current = _captureTerminalDeviceSnapshot(
      reason: 'terminal_device_proof_mismatch',
    ).connection;
    BleDebugRegistry.instance.recordEvent(
      'SOS_TERMINAL_DEVICE_PROOF_MISMATCH '
      'generation=${proof.generation} '
      'terminalState=${proof.terminalState.name} '
      'capturedDevicePresent=${proof.capturedDevicePresent} '
      'currentDevicePresent=${current.devicePresent} '
      'commandChannelReady=${proof.terminalState == SosState.resolved ? current.commandChannelReady : current.shortCommandReady || current.commandChannelReady} '
      'nativeGattConnected=${current.nativeGattConnected} '
      'owner=${current.owner} '
      'capturedIdentity=${proof.capturedIdentityMarker} '
      'currentIdentity=${current.identityMarker} reason=$reason',
    );
  }

  bool _physicalSosTerminationTargetIsCurrent(
    _PhysicalSosTerminationTarget proof,
  ) {
    final session = _session;
    final lifecycle = _sosLifecycle.current;
    final connection = _captureTerminalDeviceSnapshot(
      reason: 'terminal_device_target_current_validation',
    ).connection;
    final device = connection.device;
    final hardwareId = _physicalHardwareIdForStatus(device);
    return !_disposed &&
        !_supersededRemoteTerminalDeviceClearKeys.contains(
          proof.operationKey,
        ) &&
        session != null &&
        AuthoritativeSosLifecycleController.ownerScopeFor(session) ==
            proof.ownerScope &&
        lifecycle.isTerminal &&
        lifecycle.lifecycleId == proof.lifecycleId &&
        lifecycle.generation == proof.generation &&
        ((proof.terminalState == SosState.cancelled &&
                lifecycle.stage == SosLifecycleStage.cancelled) ||
            (proof.terminalState == SosState.resolved &&
                lifecycle.stage == SosLifecycleStage.resolved)) &&
        (lifecycle.backendIncidentId == proof.incidentId ||
            lifecycle.incident?.id == proof.incidentId) &&
        connection.devicePresent &&
        device != null &&
        (proof.nodeId == null ||
            device.nodeId == null ||
            device.nodeId == proof.nodeId) &&
        _samePhysicalHardwareId(hardwareId, proof.hardwareId);
  }

  bool _consumeRemoteTerminalDeviceClearAck(DeviceSosStatus status) {
    final awaiting = _remoteTerminalDeviceClearAwaitingAckProof;
    final pending = _remoteTerminalDeviceClearPendingProof;
    final acknowledged = _remoteTerminalDeviceClearAcknowledgedProof;
    final candidates = <_PhysicalSosTerminationTarget>[
      if (awaiting != null) awaiting,
      if (pending != null && !identical(pending, awaiting)) pending,
      if (acknowledged != null &&
          !identical(acknowledged, awaiting) &&
          !identical(acknowledged, pending))
        acknowledged,
    ];
    for (final proof in candidates) {
      if (!_deviceTerminalStatusMatchesClearProof(status, proof)) {
        continue;
      }
      if (_remoteTerminalDeviceClearPendingProof?.operationKey ==
          proof.operationKey) {
        _remoteTerminalDeviceClearPendingProof = null;
      }
      if (_remoteTerminalDeviceClearAwaitingAckProof?.operationKey ==
          proof.operationKey) {
        _remoteTerminalDeviceClearAwaitingAckProof = null;
      }
      final newlyAcknowledged =
          _remoteTerminalDeviceClearAcknowledgedProof?.operationKey !=
          proof.operationKey;
      _remoteTerminalDeviceClearAcknowledgedProof = proof;
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_TERMINAL_ACK_CONSUMED '
        'reason=authoritative_terminal_cleanup state=${status.state.name}',
      );
      if (newlyAcknowledged) {
        _setSosDeviceMirrorState(
          _SosDeviceMirrorState.synchronized,
          source:
              'device_terminal_ack:${status.lastOpcode == 0xE3 ? "E3" : "E2"}',
        );
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_ACKNOWLEDGED '
          'terminal=${proof.terminalState.name}',
        );
        if (proof.terminalState == SosState.resolved) {
          _logBackendResolveDeviceResult(
            proof: proof,
            writeSubmitted: _backendResolveWriteSubmittedKeys.contains(
              proof.operationKey,
            ),
            writeSuccess: _backendResolveWriteSuccessKeys.contains(
              proof.operationKey,
            ),
            physicalTerminalObserved: true,
            terminalPacketType: 'E3',
            failureReason: 'none',
          );
        }
      }
      return true;
    }
    return false;
  }

  bool _deviceTerminalStatusMatchesClearProof(
    DeviceSosStatus status,
    _PhysicalSosTerminationTarget proof,
  ) {
    if (!_isDeviceSosCycleClosed(status.state) ||
        !status.derivedFromBlePacket ||
        (proof.terminalState == SosState.resolved &&
            status.lastOpcode != 0xE3) ||
        (proof.nodeId != null && status.nodeId != proof.nodeId) ||
        (proof.packetId != null && status.packetId != proof.packetId)) {
      return false;
    }
    final observedAt = status.lastPacketAt ?? status.updatedAt;
    if (observedAt.isBefore(proof.deviceActiveObservedAt)) {
      return false;
    }
    if (proof.terminalState == SosState.resolved) {
      final terminalEvidence =
          deviceSosController.terminalPhysicalReceiveEvidence;
      if (terminalEvidence == null ||
          !terminalEvidence.hasTerminalSemantics ||
          !terminalEvidence.exactPhysicalIdentityMatch ||
          (proof.activeReceiveSequenceDomain != null &&
              terminalEvidence.receiveSequenceDomain !=
                  proof.activeReceiveSequenceDomain) ||
          (proof.activeReceiveSequence != null &&
              terminalEvidence.receiveSequence <=
                  proof.activeReceiveSequence!)) {
        return false;
      }
    }
    final connection = _captureTerminalDeviceSnapshot(
      reason: 'terminal_device_ack_current_validation',
    ).connection;
    final device = connection.device;
    final hardwareId = _physicalHardwareIdForStatus(device);
    if (!connection.devicePresent ||
        device == null ||
        !_samePhysicalHardwareId(hardwareId, proof.hardwareId)) {
      return false;
    }
    return proof.runtimeCycleKey == null ||
        _runtimeDeviceSosCycleKey(status: status, nodeId: status.nodeId) ==
            proof.runtimeCycleKey;
  }

  bool get _terminalDeviceMirrorIsPending =>
      _sosDeviceMirrorState == _SosDeviceMirrorState.pendingResolve ||
      _sosDeviceMirrorState == _SosDeviceMirrorState.pendingCancel;

  void _armTerminalConvergenceFenceFromProof(
    _PhysicalSosTerminationTarget proof,
  ) {
    _terminalConvergenceFence = _TerminalConvergenceFence(
      generation: proof.generation,
      terminalState: proof.terminalState,
      deviceId: proof.deviceId,
      hardwareId: proof.hardwareId,
      nodeId: proof.nodeId,
      runtimeCycleKey: proof.runtimeCycleKey,
      packetId: proof.packetId,
      packetSignature: proof.packetSignature,
    );
  }

  void _armTerminalConvergenceFence({
    required int generation,
    required SosState terminalState,
    required _CapturedPhysicalDeviceConnection connection,
    required DeviceSosStatus deviceSos,
  }) {
    final device = connection.device;
    final deviceSosOpen =
        deviceSos.state == DeviceSosState.preConfirm ||
        deviceSos.state == DeviceSosState.active ||
        deviceSos.state == DeviceSosState.acknowledged;
    if (!connection.devicePresent || device == null || !deviceSosOpen) {
      _terminalConvergenceFence = null;
      return;
    }
    _terminalConvergenceFence = _TerminalConvergenceFence(
      generation: generation,
      terminalState: terminalState,
      deviceId: device.deviceId.trim(),
      hardwareId: _physicalHardwareIdForStatus(device),
      nodeId: deviceSos.nodeId ?? device.nodeId,
      runtimeCycleKey: _runtimeDeviceSosCycleKey(
        status: deviceSos,
        nodeId: deviceSos.nodeId ?? device.nodeId,
      ),
      packetId: deviceSos.packetId,
      packetSignature: deviceSos.lastPacketSignature,
    );
  }

  bool _terminalConvergenceFenceMatchesStatusDevice(DeviceSosStatus status) {
    final fence = _terminalConvergenceFence;
    if (fence == null) {
      return false;
    }
    final incomingNodeId = _normalizeNodeIdOrNull(status.nodeId);
    final capturedNodeId = _normalizeNodeIdOrNull(fence.nodeId);
    if (incomingNodeId == null ||
        capturedNodeId == null ||
        incomingNodeId != capturedNodeId) {
      return false;
    }
    final current = _captureTerminalDeviceSnapshot(
      reason: 'terminal_convergence_device_match',
    ).connection;
    final currentHardwareId = _physicalHardwareIdForStatus(current.device);
    return current.devicePresent &&
        _samePhysicalHardwareId(currentHardwareId, fence.hardwareId);
  }

  _TerminalConvergenceStartEvaluation? _evaluateTerminalConvergenceStart({
    required int? incomingNodeId,
    required int? incomingPacketId,
    required String? incomingPacketSignature,
    required String? incomingCycleKey,
    required bool sameDevice,
    required int receiveSequence,
  }) {
    final fence = _terminalConvergenceFence;
    if (!_terminalDeviceMirrorIsPending || fence == null) {
      return null;
    }
    final capturedCycleKey = fence.runtimeCycleKey?.trim();
    final normalizedIncomingCycleKey = incomingCycleKey?.trim();
    final sameCycle =
        capturedCycleKey?.isNotEmpty == true &&
        normalizedIncomingCycleKey?.isNotEmpty == true &&
        capturedCycleKey == normalizedIncomingCycleKey;
    final capturedPacketSignature = fence.packetSignature?.trim();
    final normalizedIncomingPacketSignature = incomingPacketSignature?.trim();
    final samePacketIdentity =
        (fence.packetId != null &&
            incomingPacketId != null &&
            fence.packetId == incomingPacketId) ||
        (capturedPacketSignature?.isNotEmpty == true &&
            normalizedIncomingPacketSignature?.isNotEmpty == true &&
            capturedPacketSignature == normalizedIncomingPacketSignature);
    final provenNewCycle =
        sameDevice &&
        capturedCycleKey?.isNotEmpty == true &&
        normalizedIncomingCycleKey?.isNotEmpty == true &&
        capturedCycleKey != normalizedIncomingCycleKey &&
        fence.packetId != null &&
        incomingPacketId != null &&
        fence.packetId != incomingPacketId;
    return _TerminalConvergenceStartEvaluation(
      fence: fence,
      incomingNodeId: incomingNodeId,
      incomingCycleKey: normalizedIncomingCycleKey,
      receiveSequence: receiveSequence,
      sameDevice: sameDevice,
      sameCycle: sameCycle,
      samePacketIdentity: samePacketIdentity,
      provenNewCycle: provenNewCycle,
      suppress: !provenNewCycle,
      reason: sameCycle
          ? 'same_terminalizing_cycle'
          : samePacketIdentity
          ? 'same_packet_identity'
          : 'new_physical_cycle_not_proven',
    );
  }

  PhysicalSosStartAdmission _evaluatePhysicalSosStartAdmission(
    EixamSosPacket packet,
    PhysicalSosReceiveEvidence evidence,
    DeviceSosStatus currentDeviceStatus,
  ) {
    final lifecycle = _sosLifecycle.current;
    final terminal = _sosLifecycle.activeTerminalWatermark;
    final afterTerminalBoundary =
        terminal != null &&
        lifecycle.generation <= terminal.generation &&
        !lifecycle.isOpen;
    final pendingTerminalFence =
        _terminalDeviceMirrorIsPending || _terminalConvergenceFence != null;
    final incomingCycleKey = 'sos:${packet.nodeId}:${packet.packetId}';
    final terminalFence = _terminalDeviceCycleFence;
    final fencedCycleKey =
        (terminalFence?.generation == terminal?.generation
            ? terminalFence?.runtimeCycleKey
            : null) ??
        terminal?.deviceCycleKey?.trim() ??
        _runtimeDeviceSosCycleKey(
          status: currentDeviceStatus,
          nodeId: currentDeviceStatus.nodeId ?? packet.nodeId,
        );
    final packetWasPreviouslyConsumed = _devicePacketSignaturesByGeneration
        .values
        .any((signatures) => signatures.contains(evidence.packetFingerprint));
    final exactCurrentDeviceIdentity =
        evidence.exactPhysicalIdentityMatch &&
        evidence.classification == BleIncomingPayloadKind.ownDeviceSos &&
        evidence.hasStartSemantics &&
        !evidence.hasTerminalSemantics;

    PhysicalSosStartAdmission admission;
    if (_manualDisconnectRequested || !exactCurrentDeviceIdentity) {
      admission = PhysicalSosStartAdmission(
        decision: PhysicalSosStartAdmissionDecision.rejectOther,
        reason: _manualDisconnectRequested
            ? 'manual_disconnect_transport_boundary'
            : 'physical_identity_not_proven',
      );
    } else if (lifecycle.isOpen) {
      admission = const PhysicalSosStartAdmission(
        decision: PhysicalSosStartAdmissionDecision.sameCycle,
        reason: 'current_generation_open',
      );
    } else if (lifecycle.generation == 0) {
      admission = PhysicalSosStartAdmission(
        decision: PhysicalSosStartAdmissionDecision.acceptNewGeneration,
        reason: 'first_physical_generation',
        allowFreshStartAfterTerminal: terminal?.generation == 0,
      );
    } else if (!afterTerminalBoundary) {
      admission = const PhysicalSosStartAdmission(
        decision: PhysicalSosStartAdmissionDecision.acceptNewGeneration,
        reason: 'no_current_generation',
      );
    } else {
      final convergenceEvaluation = _evaluateTerminalConvergenceStart(
        incomingNodeId: packet.nodeId,
        incomingPacketId: packet.packetId,
        incomingPacketSignature: evidence.packetFingerprint,
        incomingCycleKey: incomingCycleKey,
        sameDevice: exactCurrentDeviceIdentity,
        receiveSequence: evidence.receiveSequence,
      );
      final convergenceSuppresses =
          (pendingTerminalFence &&
              _sosDeviceMirrorState != _SosDeviceMirrorState.failed) ||
          convergenceEvaluation?.suppress == true ||
          (_terminalDeviceMirrorIsPending &&
              convergenceEvaluation?.provenNewCycle != true);
      if (convergenceSuppresses) {
        if (convergenceEvaluation != null) {
          _logPostTerminalInflightStartSuppressed(convergenceEvaluation);
        }
        admission = const PhysicalSosStartAdmission(
          decision: PhysicalSosStartAdmissionDecision.suppressInflight,
          reason: 'terminal_convergence_inflight',
        );
      } else {
        final terminalEvidence =
            deviceSosController.terminalPhysicalReceiveEvidence;
        final freshReceiveAfterTerminal =
            terminalEvidence != null &&
            terminalEvidence.hasTerminalSemantics &&
            terminalEvidence.exactPhysicalIdentityMatch &&
            terminalEvidence.receiveSequenceDomain ==
                evidence.receiveSequenceDomain &&
            evidence.receiveSequence > terminalEvidence.receiveSequence;
        final distinctProtocolCycle =
            fencedCycleKey?.isNotEmpty == true &&
            incomingCycleKey != fencedCycleKey;
        final terminalFromPreviousProcess =
            _terminalBoundaryFromPreviousProcessGeneration ==
            terminal.generation;
        final backendOnlyAppGeneration =
            terminal.origin == SosLifecycleOrigin.localApp &&
            !_deviceMirrorDispatchedGenerations.contains(terminal.generation);
        final canAccept =
            (distinctProtocolCycle && !packetWasPreviouslyConsumed) ||
            freshReceiveAfterTerminal ||
            terminalFromPreviousProcess ||
            backendOnlyAppGeneration ||
            (fencedCycleKey == null && !packetWasPreviouslyConsumed);
        if (canAccept) {
          admission = PhysicalSosStartAdmission(
            decision: PhysicalSosStartAdmissionDecision.acceptNewGeneration,
            reason: distinctProtocolCycle
                ? 'new_protocol_cycle_after_terminal'
                : freshReceiveAfterTerminal
                ? 'fresh_physical_receive_after_terminal'
                : terminalFromPreviousProcess
                ? 'current_session_start_after_restored_terminal'
                : backendOnlyAppGeneration
                ? 'backend_only_generation_then_physical_start'
                : 'unconsumed_physical_start_after_terminal',
            allowFreshStartAfterTerminal: true,
          );
          _pendingFreshPhysicalStartProof = _FreshPhysicalStartProof(
            terminalGeneration: terminal.generation,
            receiveSequence: evidence.receiveSequence,
            receiveSequenceDomain: evidence.receiveSequenceDomain,
            terminalBoundaryFromPreviousProcess: terminalFromPreviousProcess,
            // The reducer carries its canonical packet signature (node/id/raw
            // bytes), while the admission fingerprint is a SHA marker used
            // only for evidence deduplication. Keep these domains separate so
            // the active callback can consume the proof.
            packetSignature:
                '${packet.nodeId}:${packet.packetId}:${packet.rawHex}',
          );
          _supersedeRemoteTerminalDeviceClearAtAdmission(
            terminalGeneration: terminal.generation,
            receiveSequence: evidence.receiveSequence,
          );
        } else {
          admission = PhysicalSosStartAdmission(
            decision: PhysicalSosStartAdmissionDecision.rejectReplay,
            reason: packetWasPreviouslyConsumed
                ? 'packet_fingerprint_consumed_by_terminal_generation'
                : 'same_protocol_cycle_without_new_physical_edge',
          );
        }
      }
    }
    _logPhysicalSosStartAdmission(
      packet: packet,
      evidence: evidence,
      lifecycle: lifecycle,
      terminal: terminal,
      currentDeviceStatus: currentDeviceStatus,
      runtimeCycleKey: incomingCycleKey,
      afterTerminalBoundary: afterTerminalBoundary,
      pendingTerminalFence: pendingTerminalFence,
      admission: admission,
    );
    if (admission.decision ==
        PhysicalSosStartAdmissionDecision.acceptNewGeneration) {
      _acceptedPhysicalStartPacketSignatures.add(
        '${packet.nodeId}:${packet.packetId}:${packet.rawHex}',
      );
    }
    return admission;
  }

  void _logPhysicalSosStartAdmission({
    required EixamSosPacket packet,
    required PhysicalSosReceiveEvidence evidence,
    required SosLifecycleSnapshot lifecycle,
    required SosLifecycleSnapshot? terminal,
    required DeviceSosStatus currentDeviceStatus,
    required String runtimeCycleKey,
    required bool afterTerminalBoundary,
    required bool pendingTerminalFence,
    required PhysicalSosStartAdmission admission,
  }) {
    final currentTerminalState = lifecycle.isTerminal
        ? lifecycle.stage.name
        : _isDeviceSosCycleClosed(currentDeviceStatus.state)
        ? currentDeviceStatus.state.name
        : 'none';
    BleDebugRegistry.instance.recordEvent(
      'SOS_PHYSICAL_START_ADMISSION '
      'producer=${evidence.producer} '
      'lifecycleGeneration=${lifecycle.generation} '
      'publicGeneration=$_publicSosStateGeneration '
      'currentTerminalState=$currentTerminalState '
      'terminalSummaryGeneration=${_publicTerminalGeneration ?? terminal?.generation ?? "none"} '
      'deviceMirrorState=${_sosDeviceMirrorState.name} '
      'nodeId=${packet.nodeId} packetId=${packet.packetId} '
      'runtimeCycleKey=$runtimeCycleKey '
      'packetFingerprint=${_sosFingerprintDiagnosticMarker(evidence.packetFingerprint)} '
      'receiveSequence=${evidence.receiveSequence} '
      'afterTerminalBoundary=$afterTerminalBoundary '
      'pendingTerminalFence=$pendingTerminalFence '
      'decision=${switch (admission.decision) {
        PhysicalSosStartAdmissionDecision.acceptNewGeneration => "accept_new_generation",
        PhysicalSosStartAdmissionDecision.sameCycle => "same_cycle",
        PhysicalSosStartAdmissionDecision.suppressInflight => "suppress_inflight",
        PhysicalSosStartAdmissionDecision.rejectReplay => "reject_replay",
        PhysicalSosStartAdmissionDecision.rejectOther => "reject_other",
      }} '
      'reason=${admission.reason}',
    );
  }

  void _supersedeRemoteTerminalDeviceClearAtAdmission({
    required int terminalGeneration,
    required int receiveSequence,
  }) {
    final proof = _remoteTerminalDeviceClearPendingProof;
    if (proof == null || proof.generation != terminalGeneration) {
      return;
    }
    _supersededRemoteTerminalDeviceClearKeys.add(proof.operationKey);
    _freshPhysicalStartSupersededRemoteClearGeneration = proof.generation;
    _remoteTerminalDeviceClearPendingProof = null;
    if (_remoteTerminalDeviceClearAwaitingAckProof?.operationKey ==
        proof.operationKey) {
      _remoteTerminalDeviceClearAwaitingAckProof = null;
    }
    if (_remoteTerminalDeviceClearAcknowledgedProof?.operationKey ==
        proof.operationKey) {
      _remoteTerminalDeviceClearAcknowledgedProof = null;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_SUPERSEDED '
      'reason=fresh_physical_start terminalGeneration=${proof.generation} '
      'receiveSequence=$receiveSequence boundary=shared_admission',
    );
  }

  void _logPostTerminalInflightStartSuppressed(
    _TerminalConvergenceStartEvaluation evaluation,
  ) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_POST_TERMINAL_INFLIGHT_START_SUPPRESSED '
      'terminalGeneration=${evaluation.fence.generation} '
      'incomingGenerationCandidate=${evaluation.fence.generation + 1} '
      'terminalState=${evaluation.fence.terminalState.name} '
      'deviceMirrorState=${_sosDeviceMirrorState.name} '
      'sameDevice=${evaluation.sameDevice} '
      'sameCycle=${evaluation.sameCycle} '
      'samePacketIdentity=${evaluation.samePacketIdentity} '
      'capturedCycleKey=${SecurityDiagnosticsRedactor.stableIdentifierMarker(evaluation.fence.runtimeCycleKey)} '
      'incomingCycleKey=${SecurityDiagnosticsRedactor.stableIdentifierMarker(evaluation.incomingCycleKey)} '
      'receiveSequence=${evaluation.receiveSequence} '
      'reason=${evaluation.reason}',
    );
  }

  void _clearRemoteTerminalAcknowledgementForNewDeviceCycle(
    DeviceSosStatus status,
  ) {
    final proof = _remoteTerminalDeviceClearAcknowledgedProof;
    final lifecycle = _sosLifecycle.current;
    if (proof == null ||
        !lifecycle.isOpen ||
        lifecycle.generation == proof.generation ||
        !status.derivedFromBlePacket ||
        (status.state != DeviceSosState.preConfirm &&
            status.state != DeviceSosState.active &&
            status.state != DeviceSosState.acknowledged) ||
        status.nodeId != proof.nodeId) {
      return;
    }
    final cycleKey = _runtimeDeviceSosCycleKey(
      status: status,
      nodeId: status.nodeId,
    );
    if (cycleKey == null || cycleKey == proof.runtimeCycleKey) {
      return;
    }
    _remoteTerminalDeviceClearAcknowledgedProof = null;
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_GUARD_CLEARED '
      'reason=new_device_cycle',
    );
  }

  bool _shouldSuppressDeviceSosWhileRemoteTerminalClearPending(
    DeviceSosStatus status,
  ) {
    final proof = _remoteTerminalDeviceClearPendingProof;
    if (proof == null) {
      return false;
    }
    if (!_physicalSosTerminationTargetIsCurrent(proof)) {
      _remoteTerminalDeviceClearPendingProof = null;
      BleDebugRegistry.instance.recordEvent(
        'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_GUARD_CLEARED '
        'reason=newer_lifecycle_or_owner',
      );
      return false;
    }
    if (_isDeviceSosCycleClosed(status.state)) {
      final statusObservedAt = status.lastPacketAt ?? status.updatedAt;
      if (statusObservedAt.isBefore(proof.deviceActiveObservedAt)) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_STATUS_IGNORED '
          'reason=predates_owned_active state=${status.state.name}',
        );
        return true;
      }
      if (!status.derivedFromBlePacket) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_STATUS_IGNORED '
          'reason=terminal_not_observed_from_device state=${status.state.name}',
        );
        return true;
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_SKIPPED '
        'reason=terminal_ack_identity_mismatch',
      );
      return false;
    }
    if (status.state == DeviceSosState.preConfirm ||
        status.state == DeviceSosState.active ||
        status.state == DeviceSosState.acknowledged) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_ACTIVE_SUPPRESSED '
        'reason=remote_terminal_device_clear_pending '
        'state=${status.state.name} nodeId=${status.nodeId ?? "none"}',
      );
      return true;
    }
    return false;
  }

  void _supersedeRemoteTerminalDeviceClearForFreshPhysicalStart(
    DeviceSosStatus status, {
    required bool provenNewCycle,
  }) {
    final proof = _remoteTerminalDeviceClearPendingProof;
    final freshStart = _pendingFreshPhysicalStartProof;
    final packetSignature = status.lastPacketSignature?.trim();
    final nativeFreshStartMatches =
        freshStart != null &&
        proof != null &&
        freshStart.terminalGeneration == proof.generation &&
        packetSignature != null &&
        packetSignature == freshStart.packetSignature;
    if (proof == null ||
        (!nativeFreshStartMatches && !provenNewCycle) ||
        !status.derivedFromBlePacket ||
        status.transitionSource != DeviceSosTransitionSource.device ||
        (status.state != DeviceSosState.preConfirm &&
            status.state != DeviceSosState.active)) {
      return;
    }
    _supersededRemoteTerminalDeviceClearKeys.add(proof.operationKey);
    _freshPhysicalStartSupersededRemoteClearGeneration = proof.generation;
    _remoteTerminalDeviceClearPendingProof = null;
    if (_remoteTerminalDeviceClearAwaitingAckProof?.operationKey ==
        proof.operationKey) {
      _remoteTerminalDeviceClearAwaitingAckProof = null;
    }
    if (_remoteTerminalDeviceClearAcknowledgedProof?.operationKey ==
        proof.operationKey) {
      _remoteTerminalDeviceClearAcknowledgedProof = null;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_SUPERSEDED '
      'reason=fresh_physical_start terminalGeneration=${proof.generation} '
      'receiveSequence=${freshStart?.receiveSequence ?? deviceSosController.lastPhysicalReceiveEvidence?.receiveSequence ?? -1}',
    );
  }

  void _scheduleRemoteTerminalDeviceClear(
    _PhysicalSosTerminationTarget? proof,
  ) {
    if (proof == null ||
        _remoteTerminalDeviceClearInFlightKey == proof.operationKey) {
      return;
    }
    _remoteTerminalDeviceClearPendingProof = proof;
    _remoteTerminalDeviceClearAcknowledgedProof = null;
    _clearAppOriginDeviceOwnershipContext(
      reason: 'remote_terminal_device_clear_scheduled',
    );
    _remoteTerminalDeviceClearInFlightKey = proof.operationKey;
    unawaited(_runRemoteTerminalDeviceClear(proof));
  }

  Future<void> _runRemoteTerminalDeviceClear(
    _PhysicalSosTerminationTarget proof,
  ) async {
    var submitted = false;
    var dispatched = false;
    try {
      if (!_physicalSosTerminationTargetIsCurrent(proof)) {
        _logTerminalDeviceProofMismatch(
          proof: proof,
          reason: 'stale_before_dispatch',
        );
        _logRemoteTerminalDeviceClearSkipped('stale_before_dispatch');
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_REQUESTED '
        'terminal=${proof.terminalState.name}',
      );
      if (proof.terminalState == SosState.resolved) {
        final capability = _computeCurrentSosCapabilitySnapshot(
          reason: 'backend_resolve_device_mirror_dispatch',
        );
        _logBackendResolveDeviceMirror(
          incidentIdentityPresent: proof.incidentId.trim().isNotEmpty,
          generation: proof.generation,
          connectedDevicePresent: true,
          commandChannelReady: capability.longCommandAvailable,
          mirrorRequired: true,
          mirrorAttempted: true,
          reason: 'dispatching_same_tag_terminal_command',
        );
      }
      final status = await _terminatePhysicalSosOnCurrentDevice(
        intent: proof.terminalState == SosState.resolved
            ? _SosClosureIntent.resolve
            : _SosClosureIntent.cancel,
        waitForDeviceAcknowledgement: true,
        capturedTarget: proof,
        onCommandSubmit: () {
          submitted = true;
          if (proof.terminalState == SosState.resolved) {
            _backendResolveWriteSubmittedKeys.add(proof.operationKey);
          }
        },
        onCommandDispatch: () {
          dispatched = true;
          if (proof.terminalState == SosState.resolved) {
            _backendResolveWriteSuccessKeys.add(proof.operationKey);
          }
          BleDebugRegistry.instance.recordEvent(
            'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_DISPATCHED '
            'terminal=${proof.terminalState.name} channel=existing_device_path',
          );
        },
      );
      if (!_physicalSosTerminationTargetIsCurrent(proof)) {
        if (identical(_remoteTerminalDeviceClearPendingProof, proof)) {
          _remoteTerminalDeviceClearPendingProof = null;
        }
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_COMPLETION_IGNORED '
          'reason=newer_lifecycle_or_owner',
        );
        return;
      }
      if (_isDeviceSosCycleClosed(status.state) &&
          status.derivedFromBlePacket) {
        // The device-status listener owns ACK consumption. Clearing these
        // guards here races that listener and can make the same E1 packet look
        // like an unrelated device-only terminal lifecycle.
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_COMPLETED '
          'terminal=${proof.terminalState.name} deviceState=${status.state.name} '
          'observed=${status.derivedFromBlePacket}',
        );
        if (proof.terminalState == SosState.resolved) {
          _logBackendResolveDeviceResult(
            proof: proof,
            writeSubmitted: submitted,
            writeSuccess: dispatched,
            physicalTerminalObserved: _deviceTerminalStatusMatchesClearProof(
              status,
              proof,
            ),
            terminalPacketType: status.lastOpcode == 0xE3 ? 'E3' : 'none',
            failureReason: status.lastOpcode == 0xE3
                ? 'none'
                : 'terminal_identity_mismatch',
          );
        }
      } else {
        _setSosDeviceMirrorState(
          _SosDeviceMirrorState.failed,
          source: 'remote_terminal_device_clear_deferred',
        );
        if (!dispatched) {
          BleDebugRegistry.instance.recordEvent(
            'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_FAILED '
            'terminal=${proof.terminalState.name} '
            'reason=device_command_not_dispatched uiAuthority=backend_terminal',
          );
        }
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_DEFERRED '
          'terminal=${proof.terminalState.name} deviceState=${status.state.name} '
          'uiAuthority=backend_terminal retryOwner=device_controller',
        );
        if (proof.terminalState == SosState.resolved) {
          _logBackendResolveDeviceResult(
            proof: proof,
            writeSubmitted: submitted,
            writeSuccess: dispatched,
            physicalTerminalObserved: false,
            terminalPacketType: 'none',
            failureReason: dispatched
                ? 'terminal_evidence_timeout'
                : submitted
                ? 'gatt_write_failed'
                : 'command_not_submitted',
          );
        }
      }
    } catch (error) {
      _setSosDeviceMirrorState(
        _SosDeviceMirrorState.failed,
        source: 'remote_terminal_device_clear_failed',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_REMOTE_TERMINAL_DEVICE_CLEAR_FAILED '
        'terminal=${proof.terminalState.name} '
        'reason=device_command_failure errorType=${error.runtimeType} '
        'uiAuthority=backend_terminal',
      );
      if (proof.terminalState == SosState.resolved) {
        _logBackendResolveDeviceResult(
          proof: proof,
          writeSubmitted: submitted,
          writeSuccess: dispatched,
          physicalTerminalObserved: false,
          terminalPacketType: 'none',
          failureReason: 'device_command_failure',
        );
      }
    } finally {
      if (_remoteTerminalDeviceClearInFlightKey == proof.operationKey) {
        _remoteTerminalDeviceClearInFlightKey = null;
      }
      _supersededRemoteTerminalDeviceClearKeys.remove(proof.operationKey);
    }
  }

  String? _deviceCycleKeyCorrelatedToLifecycle(
    SosLifecycleSnapshot lifecycle, {
    SosIncident? incident,
  }) {
    final persistedCycleKey = lifecycle.deviceCycleKey?.trim();
    if (persistedCycleKey != null && persistedCycleKey.isNotEmpty) {
      return persistedCycleKey;
    }
    final ownership = _appOriginDeviceOwnershipContext;
    final ownershipOwnsLifecycle =
        ownership != null &&
        ownership.lifecycleId == lifecycle.lifecycleId &&
        ownership.generation == lifecycle.generation &&
        (ownership.bridgeIncidentId == lifecycle.localIncidentId ||
            ownership.bridgeIncidentId == lifecycle.backendIncidentId ||
            ownership.bridgeIncidentId == incident?.id ||
            ownership.bridgeIncidentId == incident?.provisionalIncidentId);
    if (ownershipOwnsLifecycle && ownership.runtimeCycleKey.isNotEmpty) {
      return ownership.runtimeCycleKey;
    }
    final activeBridge = _currentAppOriginActiveSosBridge();
    final bridgeOwnsLifecycle =
        activeBridge != null &&
        activeBridge.lifecycleId == lifecycle.lifecycleId &&
        activeBridge.generation == lifecycle.generation &&
        (activeBridge.incidentId == lifecycle.localIncidentId ||
            activeBridge.incidentId == lifecycle.backendIncidentId ||
            activeBridge.incidentId == incident?.id ||
            activeBridge.incidentId == incident?.provisionalIncidentId);
    if (bridgeOwnsLifecycle) {
      final correlatedCycle = activeBridge.runtimeCycleKey?.trim();
      if (correlatedCycle != null && correlatedCycle.isNotEmpty) {
        return correlatedCycle;
      }
      final status = deviceSosController.currentStatus;
      final statusNodeId = _appOriginRuntimeNodeId(status);
      if ((activeBridge.nodeId == null ||
              statusNodeId == null ||
              activeBridge.nodeId == statusNodeId) &&
          (activeBridge.packetId == null ||
              status.packetId == null ||
              activeBridge.packetId == status.packetId)) {
        final runtimeCycle = _runtimeDeviceSosCycleKey(
          status: status,
          nodeId: statusNodeId,
        )?.trim();
        if (runtimeCycle != null && runtimeCycle.isNotEmpty) {
          return runtimeCycle;
        }
      }
    }

    if (lifecycle.origin == SosLifecycleOrigin.connectedLocalDevice) {
      final status = deviceSosController.currentStatus;
      final statusNodeId = _appOriginRuntimeNodeId(status);
      if (lifecycle.nodeId == null ||
          statusNodeId == null ||
          lifecycle.nodeId == statusNodeId) {
        final runtimeCycle = _runtimeDeviceSosCycleKey(
          status: status,
          nodeId: statusNodeId,
        )?.trim();
        if (runtimeCycle != null && runtimeCycle.isNotEmpty) {
          return runtimeCycle;
        }
      }
    }
    const deviceLifecyclePrefix = 'device-cycle:';
    if (lifecycle.lifecycleId.startsWith(deviceLifecyclePrefix)) {
      final value = lifecycle.lifecycleId.substring(
        deviceLifecyclePrefix.length,
      );
      if (value.isNotEmpty) {
        return value;
      }
    }
    final incidentCycleKey = incident?.cycleKey?.trim();
    if (incidentCycleKey != null &&
        incidentCycleKey.isNotEmpty &&
        incidentCycleKey.startsWith('sos:')) {
      return incidentCycleKey;
    }
    return null;
  }

  bool _terminalWatermarkRejectsRestoredEvidence({
    required DateTime? observedAt,
    required int? nodeId,
    String? cycleKey,
  }) {
    final activeWatermark = _sosLifecycle.activeTerminalWatermark;
    final current = _sosLifecycle.current;
    final terminal = activeWatermark ?? (current.isTerminal ? current : null);
    if (terminal == null) {
      return false;
    }
    if (current.isOpen && current.generation > terminal.generation) {
      return false;
    }
    if (_deviceInactiveBoundaryAfterTerminalGeneration == terminal.generation &&
        observedAt != null &&
        observedAt.toUtc().isAfter(terminal.lastAuthoritativeObservation)) {
      return false;
    }
    final normalizedCycleKey = cycleKey?.trim();
    if (normalizedCycleKey != null && normalizedCycleKey.isNotEmpty) {
      final incomingCycleIds = <String>{
        normalizedCycleKey,
        'device-runtime-$normalizedCycleKey',
        'device-cycle:$normalizedCycleKey',
      };
      final terminalCycleIds = <String>{
        if (terminal.deviceCycleKey?.trim() case final value?
            when value.isNotEmpty)
          value,
        if (terminal.incident?.cycleKey?.trim() case final value?
            when value.isNotEmpty)
          value,
        if (terminal.localIncidentId?.trim() case final value?
            when value.isNotEmpty)
          value,
        if (terminal.lifecycleId.trim() case final value when value.isNotEmpty)
          value,
      };
      if (incomingCycleIds.any(terminalCycleIds.contains)) {
        return true;
      }
    }
    // A changed packet/cycle key and a later timestamp are not sufficient to
    // distinguish a retransmission from a new physical SOS. A different node
    // identifier also cannot create an implicit third new-generation path:
    // only the explicit inactive boundary handled above can authorize device
    // generation B.
    return true;
  }

  void _recordTerminalFenceDeviceInactiveBoundary(
    DeviceSosStatus status, {
    required int eventSequence,
  }) {
    final explicitDeviceTerminalBoundary = _isExplicitBleDeviceTerminalBoundary(
      status,
    );
    if (!_isDeviceSosCycleClosed(status.state) ||
        (!_isDeviceSosCycleOpenState(status.previousState) &&
            !explicitDeviceTerminalBoundary) ||
        !status.derivedFromBlePacket ||
        status.transitionSource != DeviceSosTransitionSource.device ||
        !_isConnectedOwnDeviceSosStatus(status)) {
      return;
    }
    final observedAt = (status.lastPacketAt ?? status.updatedAt).toUtc();
    final nodeId = _normalizeNodeIdOrNull(
      status.nodeId ?? _knownLocalDeviceNodeId ?? _lastDeviceStatus?.nodeId,
    );
    final boundary = _ObservedOwnDeviceInactiveBoundary(
      lifecycleGeneration: _sosLifecycle.current.generation,
      eventSequence: eventSequence,
      nodeId: nodeId,
      observedAt: observedAt,
      runtimeCycleKey: _runtimeDeviceSosCycleKey(
        status: status,
        nodeId: nodeId,
      ),
      terminalState: status.state,
      previousState: status.previousState!,
      observedBeforeTerminal:
          _sosLifecycle.activeTerminalWatermark?.generation !=
          _sosLifecycle.current.generation,
    );
    _latestOwnDeviceInactiveBoundary = boundary;
    BleDebugRegistry.instance.recordEvent(
      'SOS_DEVICE_INACTIVE_BOUNDARY_RECORDED '
      'lifecycleGeneration=${boundary.lifecycleGeneration} '
      'eventSeq=${boundary.eventSequence} '
      'nodeId=${boundary.nodeId?.toString() ?? "none"} '
      'previous=${boundary.previousState.name} state=${boundary.terminalState.name} '
      'cycle=${boundary.runtimeCycleKey ?? "none"}',
    );
    final terminal = _sosLifecycle.activeTerminalWatermark;
    final current = _sosLifecycle.current;
    if (terminal == null ||
        current.generation > terminal.generation ||
        !_inactiveBoundaryBelongsToTerminal(boundary, terminal: terminal)) {
      return;
    }
    _associateInactiveBoundaryWithTerminal(
      boundary,
      terminal: terminal,
      fallbackCycleKey: boundary.runtimeCycleKey,
      ordering: boundary.observedBeforeTerminal
          ? 'before_terminal'
          : 'after_terminal',
    );
  }

  bool _isExplicitBleDeviceTerminalBoundary(DeviceSosStatus status) {
    if (!status.derivedFromBlePacket ||
        status.transitionSource != DeviceSosTransitionSource.device) {
      return false;
    }
    final opcode = status.lastOpcode;
    return opcode == EixamBleProtocol.sosEventUserDeactivatedOpcode ||
        opcode == EixamBleProtocol.sosEventBackendResolvedOpcode;
  }

  bool _isDeviceSosCycleOpenState(DeviceSosState? state) {
    return state == DeviceSosState.preConfirm ||
        state == DeviceSosState.active ||
        state == DeviceSosState.acknowledged;
  }

  bool _isConnectedOwnDeviceSosStatus(DeviceSosStatus status) {
    final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    if (connectedDevice?.connected != true) {
      return false;
    }
    final statusNodeId = _normalizeNodeIdOrNull(status.nodeId);
    final knownNodeId = _normalizeNodeIdOrNull(
      _knownLocalDeviceNodeId ?? connectedDevice?.nodeId,
    );
    return statusNodeId == null ||
        knownNodeId == null ||
        statusNodeId == knownNodeId;
  }

  bool _inactiveBoundaryBelongsToTerminal(
    _ObservedOwnDeviceInactiveBoundary boundary, {
    required SosLifecycleSnapshot terminal,
  }) {
    if (boundary.lifecycleGeneration != terminal.generation) {
      return false;
    }
    final terminalNodeId = _normalizeNodeIdOrNull(
      terminal.nodeId ??
          (_terminalDeviceCycleFence?.generation == terminal.generation
              ? _terminalDeviceCycleFence?.nodeId
              : null) ??
          _knownLocalDeviceNodeId,
    );
    if (terminalNodeId != null &&
        boundary.nodeId != null &&
        terminalNodeId != boundary.nodeId) {
      return false;
    }
    final activatedAt = terminal.activationTimestamp?.toUtc();
    return activatedAt == null || !boundary.observedAt.isBefore(activatedAt);
  }

  void _associateInactiveBoundaryWithTerminal(
    _ObservedOwnDeviceInactiveBoundary boundary, {
    required SosLifecycleSnapshot terminal,
    required String? fallbackCycleKey,
    required String ordering,
  }) {
    _deviceInactiveBoundaryAfterTerminalGeneration = terminal.generation;
    final existingFence = _terminalDeviceCycleFence;
    final normalizedFallback = fallbackCycleKey?.trim();
    final terminalCycleKey = terminal.deviceCycleKey?.trim();
    _terminalDeviceCycleFence = _TerminalDeviceCycleFence(
      generation: terminal.generation,
      nodeId: terminal.nodeId ?? boundary.nodeId,
      runtimeCycleKey: terminalCycleKey?.isNotEmpty == true
          ? terminalCycleKey
          : existingFence?.generation == terminal.generation
          ? existingFence?.runtimeCycleKey
          : normalizedFallback?.isNotEmpty == true
          ? normalizedFallback
          : boundary.runtimeCycleKey,
      terminalBoundaryEventSequence:
          existingFence?.generation == terminal.generation
          ? existingFence?.terminalBoundaryEventSequence ??
                _deviceSosStatusEventSequence
          : _deviceSosStatusEventSequence,
      inactiveBoundaryEventSequence: boundary.eventSequence,
      inactiveBoundaryObservedAt: boundary.observedAt,
      consumedPacketSignatures: existingFence?.generation == terminal.generation
          ? existingFence!.consumedPacketSignatures
          : _devicePacketSignaturesForGeneration(terminal.generation),
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_TERMINAL_FENCE_DEVICE_CLEANUP_PRESERVED '
      'generation=${terminal.generation} state=${boundary.terminalState.name} '
      'boundarySeq=${boundary.eventSequence} ordering=$ordering',
    );
  }

  Set<String> _devicePacketSignaturesForGeneration(int generation) {
    return Set<String>.unmodifiable(
      _devicePacketSignaturesByGeneration[generation] ?? const <String>{},
    );
  }

  void _recordAcceptedDevicePacketSignature(DeviceSosStatus status) {
    final lifecycle = _sosLifecycle.current;
    final signature = status.lastPacketSignature?.trim();
    if (!lifecycle.isOpen ||
        !status.derivedFromBlePacket ||
        status.transitionSource != DeviceSosTransitionSource.device ||
        !_isConnectedOwnDeviceSosStatus(status) ||
        (status.relayCount ?? 0) != 0 ||
        signature == null ||
        signature.isEmpty) {
      return;
    }
    _devicePacketSignaturesByGeneration
        .putIfAbsent(lifecycle.generation, () => <String>{})
        .add(signature);
    _devicePacketSignaturesByGeneration.removeWhere(
      (generation, _) => generation < lifecycle.generation - 1,
    );
  }

  bool _terminalFenceAllowsFreshDeviceGeneration(
    DeviceSosStatus status, {
    required int eventSequence,
  }) {
    final terminal = _sosLifecycle.activeTerminalWatermark;
    final current = _sosLifecycle.current;
    if (terminal == null || current.generation > terminal.generation) {
      return false;
    }
    if (terminal.generation == 0 && current.generation == 0) {
      return true;
    }
    if (!status.derivedFromBlePacket ||
        status.transitionSource != DeviceSosTransitionSource.device ||
        status.triggerOrigin != DeviceSosTransitionSource.device ||
        !_isConnectedOwnDeviceSosStatus(status)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_REPLAY_REJECTED reason=weak_identity '
        'terminalGeneration=${terminal.generation}',
      );
      return false;
    }
    final observedAt = (status.lastPacketAt ?? status.updatedAt).toUtc();
    final hasInactiveBoundary =
        _deviceInactiveBoundaryAfterTerminalGeneration == terminal.generation;
    final fence = _terminalDeviceCycleFence;
    final nodeId = status.nodeId ?? _knownLocalDeviceNodeId;
    final fencedNodeId = fence?.generation == terminal.generation
        ? fence?.nodeId
        : terminal.nodeId;
    if (fencedNodeId != null && nodeId != null && fencedNodeId != nodeId) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_REPLAY_REJECTED reason=weak_identity '
        'terminalGeneration=${terminal.generation}',
      );
      return false;
    }
    final incomingCycleKey = _runtimeDeviceSosCycleKey(
      status: status,
      nodeId: nodeId,
    );
    final fencedCycleKey =
        (fence?.generation == terminal.generation
            ? fence?.runtimeCycleKey
            : null) ??
        terminal.deviceCycleKey?.trim();
    final validFreshPhysicalEdgeWithoutReplayCheck =
        hasInactiveBoundary &&
        fence != null &&
        fence.generation == terminal.generation &&
        status.state == DeviceSosState.preConfirm &&
        (status.previousState == DeviceSosState.inactive ||
            status.previousState == DeviceSosState.resolved) &&
        fence.inactiveBoundaryEventSequence != null &&
        isStrictlyNewerSosReceiveSequence(
          incomingSequence: eventSequence,
          terminalBoundarySequence: fence.inactiveBoundaryEventSequence!,
        );
    final terminalBoundaryEventSequence =
        (fence?.generation == terminal.generation
            ? fence?.terminalBoundaryEventSequence
            : null) ??
        0;
    final hasStrongConnectedIdentity = _hasStrongConnectedOwnDeviceSosIdentity(
      status,
      terminal: terminal,
    );
    final incomingPacketSignature = status.lastPacketSignature?.trim();
    final terminalConsumedPacketSignatures =
        fence?.generation == terminal.generation
        ? fence!.consumedPacketSignatures
        : const <String>{};
    final hasPacketFingerprint =
        incomingPacketSignature != null && incomingPacketSignature.isNotEmpty;
    final packetWasConsumedByTerminalGeneration =
        hasPacketFingerprint &&
        terminalConsumedPacketSignatures.contains(incomingPacketSignature);
    final packetWasPreviouslyConsumed =
        hasPacketFingerprint &&
        _devicePacketSignaturesByGeneration.values.any(
          (signatures) => signatures.contains(incomingPacketSignature),
        );
    final hasUnconsumedPacketFingerprint =
        hasPacketFingerprint && !packetWasPreviouslyConsumed;
    final freshPhysicalStartProof = _pendingFreshPhysicalStartProof;
    final hasFreshNativeReceiveEdge =
        freshPhysicalStartProof != null &&
        freshPhysicalStartProof.terminalGeneration == terminal.generation &&
        freshPhysicalStartProof.packetSignature == incomingPacketSignature;
    final incomingPhysicalEvidence =
        deviceSosController.lastPhysicalReceiveEvidence;
    final evidenceMatchesStatus =
        incomingPhysicalEvidence != null &&
        incomingPhysicalEvidence.packetFingerprint == incomingPacketSignature;
    final samePhysicalReceiveDomain =
        evidenceMatchesStatus &&
        _lastOwnDeviceTerminalNativeGeneration == terminal.generation &&
        _lastOwnDeviceTerminalNativeReceiveSequence != null &&
        _lastOwnDeviceTerminalReceiveSequenceDomain != null &&
        incomingPhysicalEvidence.receiveSequenceDomain ==
            _lastOwnDeviceTerminalReceiveSequenceDomain;
    final hasFreshTypedPhysicalReceiveEdge =
        incomingPhysicalEvidence != null &&
        _lastOwnDeviceTerminalNativeReceiveSequence != null &&
        samePhysicalReceiveDomain &&
        incomingPhysicalEvidence.hasStartSemantics &&
        !incomingPhysicalEvidence.hasTerminalSemantics &&
        incomingPhysicalEvidence.exactPhysicalIdentityMatch &&
        incomingPhysicalEvidence.classification ==
            BleIncomingPayloadKind.ownDeviceSos &&
        incomingPhysicalEvidence.receiveSequence >
            _lastOwnDeviceTerminalNativeReceiveSequence!;
    final hasFreshPhysicalReceiveEdge =
        hasFreshNativeReceiveEdge || hasFreshTypedPhysicalReceiveEdge;
    final localReceiveAfterTerminal = isStrictlyNewerSosReceiveSequence(
      incomingSequence: eventSequence,
      terminalBoundarySequence: terminalBoundaryEventSequence,
    );
    final exactHardwareMatch = _hasExactConnectedHardwareIdentity(terminal);
    final exactIncomingPhysicalIdentity =
        _hasExactConnectedPhysicalIdentityForStatus(status);
    final terminalWasBackendOnlyAppGeneration =
        terminal.origin == SosLifecycleOrigin.localApp &&
        !_deviceMirrorDispatchedGenerations.contains(terminal.generation) &&
        terminalConsumedPacketSignatures.isEmpty;
    final validFreshPhysicalEdge =
        validFreshPhysicalEdgeWithoutReplayCheck &&
        status.lastPacketAt != null &&
        status.sosType != null &&
        (status.relayCount ?? 0) == 0 &&
        hasStrongConnectedIdentity &&
        exactHardwareMatch &&
        incomingCycleKey != null &&
        fencedCycleKey != null &&
        (hasUnconsumedPacketFingerprint || hasFreshPhysicalReceiveEdge);
    final validStrongNewCycle =
        status.state == DeviceSosState.preConfirm &&
        status.previousState == DeviceSosState.inactive &&
        (status.relayCount ?? 0) == 0 &&
        hasStrongConnectedIdentity &&
        exactHardwareMatch &&
        incomingCycleKey != null &&
        fencedCycleKey != null &&
        incomingCycleKey != fencedCycleKey &&
        localReceiveAfterTerminal &&
        (hasUnconsumedPacketFingerprint || hasFreshPhysicalReceiveEdge);
    // Firmware resets its packet/retry counters only when countdown promotes
    // to ACTIVE. The first BLE countdown packet can therefore legitimately
    // reuse generation N's raw identity. On that first packet the strongest
    // available edge is the composite below: real direct-device BLE evidence,
    // exact connected identity, an inactive -> preConfirm reducer edge, and
    // receive order strictly after N's terminal watermark, plus either a full
    // packet fingerprint not consumed by N or a distinct native receive edge
    // after N's terminal packet. The latter permits firmware to reuse its raw
    // packet identity across real button activations. retryCount is
    // deliberately excluded because it is not a per-activation counter.
    // Elapsed wall-clock time is not an admission input: a proven edge may
    // reopen immediately.
    final validStrongReusedPhysicalRisingEdge =
        status.state == DeviceSosState.preConfirm &&
        status.previousState == DeviceSosState.inactive &&
        status.lastPacketAt != null &&
        status.sosType != null &&
        (status.relayCount ?? 0) == 0 &&
        hasStrongConnectedIdentity &&
        exactHardwareMatch &&
        incomingCycleKey != null &&
        fencedCycleKey != null &&
        incomingCycleKey == fencedCycleKey &&
        localReceiveAfterTerminal &&
        terminalConsumedPacketSignatures.isNotEmpty &&
        (hasUnconsumedPacketFingerprint || hasFreshPhysicalReceiveEdge);
    final validBackendOnlyAppThenPhysicalRisingEdge =
        terminalWasBackendOnlyAppGeneration &&
        status.state == DeviceSosState.preConfirm &&
        status.previousState == DeviceSosState.inactive &&
        status.lastPacketAt != null &&
        status.sosType != null &&
        (status.relayCount ?? 0) == 0 &&
        hasStrongConnectedIdentity &&
        exactIncomingPhysicalIdentity &&
        incomingCycleKey != null &&
        localReceiveAfterTerminal &&
        (hasUnconsumedPacketFingerprint || hasFreshPhysicalReceiveEdge);
    // A terminal lifecycle is itself a completed physical boundary. After
    // process recreation its native receive sequence and consumed-fingerprint
    // set are intentionally unavailable, so a current-domain raw BLE edge is
    // the ordering proof. The platform admission that creates this proof has
    // already required START semantics, exact connected identity, a closed
    // lifecycle, and a receive sequence newer than this domain's baseline.
    final validTerminalBoundaryPhysicalRisingEdge =
        status.state == DeviceSosState.preConfirm &&
        (status.previousState == DeviceSosState.inactive ||
            status.previousState == DeviceSosState.resolved ||
            (_freshPhysicalStartSupersededRemoteClearGeneration ==
                    terminal.generation &&
                (status.previousState == DeviceSosState.active ||
                    status.previousState == DeviceSosState.acknowledged))) &&
        status.lastPacketAt != null &&
        status.sosType != null &&
        (status.relayCount ?? 0) == 0 &&
        hasStrongConnectedIdentity &&
        exactHardwareMatch &&
        exactIncomingPhysicalIdentity &&
        incomingCycleKey != null &&
        localReceiveAfterTerminal &&
        hasFreshPhysicalReceiveEdge;
    final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    final normalizedStatusNodeId = _normalizeNodeIdOrNull(status.nodeId);
    final normalizedConnectedNodeId = _normalizeNodeIdOrNull(
      connectedDevice?.nodeId ?? _knownLocalDeviceNodeId,
    );
    final nodeMatch =
        normalizedStatusNodeId != null &&
        normalizedConnectedNodeId != null &&
        normalizedStatusNodeId == normalizedConnectedNodeId;
    final terminalDeviceId = terminal.deviceId?.trim();
    final connectedDeviceId = connectedDevice?.deviceId.trim();
    final deviceMatch =
        terminalDeviceId?.isNotEmpty != true ||
        (connectedDeviceId?.isNotEmpty == true &&
            (connectedDeviceId!.toLowerCase() ==
                    terminalDeviceId!.toLowerCase() ||
                _samePhysicalHardwareId(connectedDeviceId, terminalDeviceId)));
    final terminalHardwareId = terminal.hardwareId?.trim();
    final connectedHardwareId = _physicalHardwareIdForStatus(connectedDevice);
    final hardwareMatch =
        terminalHardwareId?.isNotEmpty != true ||
        (connectedHardwareId?.isNotEmpty == true &&
            _samePhysicalHardwareId(connectedHardwareId!, terminalHardwareId!));
    BleDebugRegistry.instance.recordEvent(
      'SOS_FRESH_GENERATION_EVAL '
      'terminalGeneration=${terminal.generation} '
      'currentGeneration=${current.generation} '
      'rawPacketId=${status.packetId?.toString() ?? "none"} '
      'fingerprintSha256=${_sosFingerprintDiagnosticMarker(incomingPacketSignature)} '
      'fingerprintConsumed=$packetWasPreviouslyConsumed '
      'consumedByTerminal=$packetWasConsumedByTerminalGeneration '
      'freshNativeReceiveEdge=$hasFreshNativeReceiveEdge '
      'freshPhysicalReceiveEdge=$hasFreshPhysicalReceiveEdge '
      'physicalReceiveSequence=${freshPhysicalStartProof?.receiveSequence ?? incomingPhysicalEvidence?.receiveSequence ?? -1} '
      'receiveSequenceDomain=${freshPhysicalStartProof?.receiveSequenceDomain ?? incomingPhysicalEvidence?.receiveSequenceDomain ?? "none"} '
      'terminalReceiveSequence=${_lastOwnDeviceTerminalNativeReceiveSequence ?? -1} '
      'terminalReceiveSequenceDomain=${_lastOwnDeviceTerminalReceiveSequenceDomain ?? "none"} '
      'sameReceiveDomain=$samePhysicalReceiveDomain '
      'terminalBoundaryFromPreviousProcess=${freshPhysicalStartProof?.terminalBoundaryFromPreviousProcess ?? false} '
      'receiveSequence=$eventSequence '
      'terminalBoundarySequence=$terminalBoundaryEventSequence '
      'reducerPrevious=${status.previousState?.name ?? "none"} '
      'reducerNext=${status.state.name} '
      'nodeMatch=$nodeMatch deviceMatch=$deviceMatch '
      'hardwareMatch=$hardwareMatch exactHardwareMatch=$exactHardwareMatch '
      'exactIncomingPhysicalIdentity=$exactIncomingPhysicalIdentity '
      'relayCount=${status.relayCount ?? 0} '
      'sourceBle=${status.derivedFromBlePacket && status.transitionSource == DeviceSosTransitionSource.device} '
      'localReceiveAfterTerminal=$localReceiveAfterTerminal '
      'inactiveBoundary=$hasInactiveBoundary '
      'terminalDeviceMirrorDispatched=${_deviceMirrorDispatchedGenerations.contains(terminal.generation)} '
      'terminalBackendOnlyApp=$terminalWasBackendOnlyAppGeneration '
      'admitInactiveBoundary=$validFreshPhysicalEdge '
      'admitDistinctProtocolCounter=$validStrongNewCycle '
      'admitReusedProtocolCounter=$validStrongReusedPhysicalRisingEdge '
      'admitBackendOnlyAppEdge=$validBackendOnlyAppThenPhysicalRisingEdge '
      'admitTerminalBoundaryEdge=$validTerminalBoundaryPhysicalRisingEdge',
    );
    if (!validFreshPhysicalEdge &&
        !validStrongNewCycle &&
        !validStrongReusedPhysicalRisingEdge &&
        !validBackendOnlyAppThenPhysicalRisingEdge &&
        !validTerminalBoundaryPhysicalRisingEdge) {
      final rejectionReason = !localReceiveAfterTerminal
          ? 'old_sequence'
          : packetWasPreviouslyConsumed && !hasFreshPhysicalReceiveEdge
          ? 'packet_replay'
          : incomingCycleKey == null ||
                fencedCycleKey == null ||
                incomingCycleKey == fencedCycleKey
          ? 'same_cycle'
          : 'weak_identity';
      BleDebugRegistry.instance.recordEvent(
        'SOS_REPLAY_REJECTED reason=$rejectionReason '
        'terminalGeneration=${terminal.generation}',
      );
      return false;
    }
    final rawIdentityReused = incomingCycleKey == fencedCycleKey;
    BleDebugRegistry.instance.recordEvent(
      'SOS_TERMINAL_FENCE_FRESH_PHYSICAL_EDGE_ACCEPTED '
      'terminalGeneration=${terminal.generation} '
      'admission=${validFreshPhysicalEdge
          ? "inactive_boundary"
          : validStrongReusedPhysicalRisingEdge
          ? "direct_device_rising_edge"
          : validBackendOnlyAppThenPhysicalRisingEdge
          ? "backend_only_app_then_physical_edge"
          : validTerminalBoundaryPhysicalRisingEdge
          ? "terminal_boundary_current_physical_edge"
          : "strong_new_cycle"} '
      'eventSeq=$eventSequence rawIdentityReused=$rawIdentityReused '
      'strongIdentity=$hasStrongConnectedIdentity newCycle=${!rawIdentityReused} '
      'afterTerminalBoundary=true '
      'wallClockAfterTerminal=${observedAt.isAfter(terminal.lastAuthoritativeObservation)}',
    );
    return true;
  }

  bool _hasStrongConnectedOwnDeviceSosIdentity(
    DeviceSosStatus status, {
    SosLifecycleSnapshot? terminal,
  }) {
    final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    if (connectedDevice?.connected != true) {
      return false;
    }
    final statusNodeId = _normalizeNodeIdOrNull(status.nodeId);
    final connectedNodeId = _normalizeNodeIdOrNull(
      connectedDevice?.nodeId ?? _knownLocalDeviceNodeId,
    );
    if (statusNodeId == null ||
        connectedNodeId == null ||
        statusNodeId != connectedNodeId ||
        (terminal?.nodeId != null && terminal?.nodeId != statusNodeId)) {
      return false;
    }
    final connectedDeviceId = connectedDevice?.deviceId.trim();
    final terminalDeviceId = terminal?.deviceId?.trim();
    if (connectedDeviceId?.isNotEmpty == true &&
        terminalDeviceId?.isNotEmpty == true &&
        connectedDeviceId != terminalDeviceId) {
      return false;
    }
    final connectedHardwareId = _physicalHardwareIdForStatus(connectedDevice);
    final terminalHardwareId = terminal?.hardwareId?.trim();
    return connectedHardwareId == null ||
        terminalHardwareId == null ||
        connectedHardwareId == terminalHardwareId;
  }

  bool _hasExactConnectedHardwareIdentity(SosLifecycleSnapshot terminal) {
    final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    if (connectedDevice?.connected != true) {
      return false;
    }
    final connectedDeviceId = connectedDevice?.deviceId.trim();
    final terminalDeviceId = terminal.deviceId?.trim();
    final connectedHardwareId = _physicalHardwareIdForStatus(connectedDevice);
    final terminalNodeId = _normalizeNodeIdOrNull(
      terminal.nodeId ??
          (_terminalDeviceCycleFence?.generation == terminal.generation
              ? _terminalDeviceCycleFence?.nodeId
              : null) ??
          _knownLocalDeviceNodeId,
    );
    final lifecycleHardwareId = terminal.hardwareId?.trim();
    final nodeMappedHardwareId = terminalNodeId == null
        ? null
        : _hardwareIdByNodeId[terminalNodeId]?.trim();
    final terminalHardwareId = lifecycleHardwareId?.isNotEmpty == true
        ? lifecycleHardwareId
        : nodeMappedHardwareId;
    final terminalDeviceMatches = terminalDeviceId?.isNotEmpty == true
        ? connectedDeviceId?.isNotEmpty == true &&
              (connectedDeviceId!.toLowerCase() ==
                      terminalDeviceId!.toLowerCase() ||
                  _samePhysicalHardwareId(connectedDeviceId, terminalDeviceId))
        : terminalNodeId != null && nodeMappedHardwareId?.isNotEmpty == true;
    return connectedDeviceId?.isNotEmpty == true &&
        terminalDeviceMatches &&
        connectedHardwareId?.isNotEmpty == true &&
        terminalHardwareId?.isNotEmpty == true &&
        _samePhysicalHardwareId(connectedHardwareId!, terminalHardwareId!);
  }

  bool _hasExactConnectedPhysicalIdentityForStatus(DeviceSosStatus status) {
    final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    if (connectedDevice?.connected != true) {
      return false;
    }
    final connectedDeviceId = connectedDevice?.deviceId.trim();
    final connectedHardwareId = _physicalHardwareIdForStatus(connectedDevice);
    final statusNodeId = _normalizeNodeIdOrNull(status.nodeId);
    final connectedNodeId = _normalizeNodeIdOrNull(
      connectedDevice?.nodeId ?? _knownLocalDeviceNodeId,
    );
    return connectedDeviceId?.isNotEmpty == true &&
        connectedHardwareId?.isNotEmpty == true &&
        statusNodeId != null &&
        connectedNodeId != null &&
        statusNodeId == connectedNodeId;
  }

  bool _deviceStatusHasNewCycleIdentity(
    DeviceSosStatus status,
    SosLifecycleSnapshot terminal,
  ) {
    final nodeId = status.nodeId ?? _knownLocalDeviceNodeId;
    final incomingCycleKey = _runtimeDeviceSosCycleKey(
      status: status,
      nodeId: nodeId,
    );
    final fence = _terminalDeviceCycleFence;
    final fencedCycleKey =
        (fence?.generation == terminal.generation
            ? fence?.runtimeCycleKey
            : null) ??
        terminal.deviceCycleKey?.trim();
    return incomingCycleKey != null &&
        fencedCycleKey != null &&
        incomingCycleKey != fencedCycleKey;
  }

  bool _terminalFenceSuppressesDeviceOpen(
    DeviceSosStatus status, {
    required int eventSequence,
  }) {
    final terminal = _sosLifecycle.activeTerminalWatermark;
    final current = _sosLifecycle.current;
    if (terminal == null || current.generation > terminal.generation) {
      return false;
    }
    return !_terminalFenceAllowsFreshDeviceGeneration(
      status,
      eventSequence: eventSequence,
    );
  }

  bool _shouldClearRecentAppOriginBridge(String reason) {
    final normalized = reason.toLowerCase();
    return normalized.contains('cancel') ||
        normalized.contains('terminal') ||
        normalized.contains('session_cleared') ||
        normalized.contains('public_trigger_backend_failed') ||
        normalized.contains('countdown_zero_activation_failed') ||
        normalized.contains('app_origin_device_terminal_cleanup');
  }

  void _emitPublicSosState(SosState state, {String source = 'unspecified'}) {
    _alignPublicSosProjectionWithCurrentGeneration(source: source);
    if (state == SosState.idle &&
        _shouldPreserveAuthoritativeTerminalSummary(source)) {
      _logPublicSosLifecycleState(source: '$source:terminal_summary_preserved');
      return;
    }
    if (_isOpenSosState(state) &&
        _publicSosState == SosState.cancelRequested &&
        _publicSosStateGeneration == _sosLifecycle.current.generation &&
        (_publicSosClosureInFlight == _SosClosureIntent.cancel ||
            _sosLifecycle.current.stage == SosLifecycleStage.cancelling)) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_ACTIVE_SUPPRESSED reason=logical_cancel_pending '
        'state=${state.name} source=$source',
      );
      return;
    }
    // An authenticated Backend/Web terminal is an absolute lifecycle fence.
    // Open projections may resume only after the authoritative controller has
    // created a newer generation (explicit App SOS or device inactive->ACTIVE).
    if (_isOpenSosState(state) &&
        _sosLifecycle.activeTerminalWatermark != null &&
        !_hasNewAuthoritativeGenerationSinceTerminal()) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_FENCE_SUPPRESSED_OPEN source=$source '
        'reason=authoritative_backend_terminal '
        'current=${_publicSosState.name} incoming=${state.name}',
      );
      _logTerminalRegressionBlocked(incoming: state, source: source);
      _logPublicSosStateMachineBypassBlocked(
        from: _publicSosState,
        to: state,
        source: source,
        reason: 'authoritative_terminal_fence',
      );
      return;
    }
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
    _applyPublicSosState(nextState, source: source, emit: true);
  }

  bool _hasNewAuthoritativeGenerationSinceTerminal() {
    final watermark = _sosLifecycle.activeTerminalWatermark;
    final current = _sosLifecycle.current;
    return watermark != null &&
        current.isOpen &&
        current.generation > watermark.generation;
  }

  bool _applyPublicSosState(
    SosState nextState, {
    required String source,
    required bool emit,
  }) {
    _alignPublicSosProjectionWithCurrentGeneration(source: source);
    if (_publicSosState == SosState.acknowledged &&
        nextState == SosState.sent &&
        _publicAcknowledgedGeneration == _sosLifecycle.current.generation) {
      _recordSosAckPresentationContinuity(
        source: source,
        action: 'preserve_acknowledged',
      );
      return false;
    }
    if (nextState == SosState.idle &&
        _shouldPreserveAuthoritativeTerminalSummary(source)) {
      _logPublicSosLifecycleState(source: '$source:terminal_summary_preserved');
      return false;
    }
    if (_isOpenSosState(nextState) &&
        _publicSosState == SosState.cancelRequested &&
        _publicSosStateGeneration == _sosLifecycle.current.generation &&
        (_publicSosClosureInFlight == _SosClosureIntent.cancel ||
            _sosLifecycle.current.stage == SosLifecycleStage.cancelling)) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_ACTIVE_SUPPRESSED reason=logical_cancel_pending '
        'state=${nextState.name} source=$source',
      );
      return false;
    }
    if (_isOpenSosState(nextState) &&
        _sosLifecycle.activeTerminalWatermark != null &&
        !_hasNewAuthoritativeGenerationSinceTerminal()) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_FENCE_SUPPRESSED_OPEN source=$source '
        'reason=authoritative_backend_terminal '
        'current=${_publicSosState.name} incoming=${nextState.name}',
      );
      _logTerminalRegressionBlocked(incoming: nextState, source: source);
      return false;
    }
    if (nextState == _publicSosState) {
      return false;
    }
    if (!_validatePublicSosTransition(
      from: _publicSosState,
      to: nextState,
      source: source,
    )) {
      return false;
    }
    _publicSosState = nextState;
    _publicSosStateGeneration = _sosLifecycle.current.generation;
    if (_isTerminalPublicSosState(nextState)) {
      _publicTerminalGeneration = _publicSosStateGeneration;
    } else {
      _publicTerminalGeneration = null;
    }
    if (nextState == SosState.acknowledged) {
      _publicAcknowledgedGeneration = _sosLifecycle.current.generation;
      _recordSosAckPresentationContinuity(
        source: source,
        action: 'apply_acknowledged',
      );
    } else {
      _publicAcknowledgedGeneration = null;
    }
    _logPublicSosLifecycleState(source: source);
    if (emit && !_publicSosStateController.isClosed) {
      _publicSosStateController.add(nextState);
    }
    unawaited(
      _updateBackgroundTelemetryState(reason: 'sos_state:${nextState.name}'),
    );
    return true;
  }

  void _alignPublicSosProjectionWithCurrentGeneration({
    required String source,
  }) {
    final lifecycle = _sosLifecycle.current;
    if (!lifecycle.isOpen ||
        lifecycle.generation <= _publicSosStateGeneration) {
      return;
    }
    if (_publicSosStateGeneration == 0 &&
        _publicSosState == SosState.idle &&
        _publicTerminalGeneration == null &&
        _publicAcknowledgedGeneration == null &&
        _publicSosFallbackIncident == null &&
        _lastKnownActiveSosIncident == null &&
        _lastPublicSosIncidentId == null) {
      _publicSosStateGeneration = lifecycle.generation;
      return;
    }
    _resetPublicSosPresentationForGeneration(
      lifecycle.generation,
      reason: 'lifecycle_generation_advanced:$source',
      emitIdle: false,
    );
  }

  void _resetPublicSosPresentationForGeneration(
    int generation, {
    required String reason,
    required bool emitIdle,
  }) {
    if (_publicSosStateGeneration == generation) {
      return;
    }
    final previousState = _publicSosState;
    _publicSosState = SosState.idle;
    _publicSosStateGeneration = generation;
    _publicTerminalGeneration = null;
    _publicAcknowledgedGeneration = null;
    _publicSosFallbackIncident = null;
    _lastKnownActiveSosIncident = null;
    _lastLoggedActiveIncidentPreservationSignature = null;
    _lastPublicSosIncidentId = null;
    _lastPublicSosDeliveryChannel = null;
    _lastPublicSosTerminalReason = null;
    _pendingCancelledIncidentId = null;
    _lastSosRehydrationNote = null;
    _clearAcknowledgedTerminalSosSummaries(reason: reason);
    _sosDeviceMirrorState = _SosDeviceMirrorState.synchronized;
    _terminalConvergenceFence = null;
    _recordPublicSosGenerationProjection(
      action: 'reset_previous_generation',
      reason: reason,
    );
    if (emitIdle &&
        previousState != SosState.idle &&
        !_publicSosStateController.isClosed) {
      _publicSosStateController.add(SosState.idle);
    }
  }

  void _recordPublicSosGenerationProjection({
    required String action,
    required String reason,
  }) {
    final lifecycle = _sosLifecycle.current;
    BleDebugRegistry.instance.recordEvent(
      'SOS_PUBLIC_GENERATION_PROJECTION '
      'lifecycleGeneration=${lifecycle.generation} '
      'projectedGeneration=$_publicSosStateGeneration '
      'lifecycleState=${lifecycle.stage.name} '
      'publicSosState=${_publicSosState.name} '
      'latchedTerminalGeneration=${_publicTerminalGeneration ?? "none"} '
      'ackLatchGeneration=${_publicAcknowledgedGeneration ?? "none"} '
      'action=$action reason=$reason',
    );
  }

  void _recordSosAckPresentationContinuity({
    required String source,
    required String action,
  }) {
    final protectionStatus = _protectionModeController.currentStatus;
    BleDebugRegistry.instance.recordEvent(
      'SOS_ACK_PRESENTATION_CONTINUITY '
      'generation=${_sosLifecycle.current.generation} '
      'sdkPublicState=${_publicSosState.name} '
      'owner=${_deviceConnectionOwner(protectionStatus)} '
      'visibleConnected=${(_lastPublicDeviceStatus ?? _lastDeviceStatus)?.connected == true} '
      'source=$source action=$action',
    );
  }

  bool _shouldPreserveAuthoritativeTerminalSummary(String source) {
    final terminal = _sosLifecycle.activeTerminalWatermark;
    if (terminal == null ||
        !_isTerminalPublicSosState(_publicSosState) ||
        _publicTerminalGeneration != _sosLifecycle.current.generation ||
        _hasNewAuthoritativeGenerationSinceTerminal()) {
      return false;
    }
    return source != 'clear_session' &&
        source != 'terminal_summary_acknowledged' &&
        source != 'public_cancel_completed:clear_current_sos';
  }

  void _setSosDeviceMirrorState(
    _SosDeviceMirrorState state, {
    required String source,
  }) {
    _sosDeviceMirrorState = state;
    if (state != _SosDeviceMirrorState.pendingResolve &&
        state != _SosDeviceMirrorState.pendingCancel) {
      _terminalConvergenceFence = null;
    }
    _logPublicSosLifecycleState(source: source);
  }

  void _logPublicSosLifecycleState({required String source}) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_PUBLIC_LIFECYCLE_STATE incidentState=${_publicSosState.name} '
      'deviceMirrorState=${_sosDeviceMirrorState.name} '
      'generation=${_sosLifecycle.current.generation} source=$source',
    );
  }

  void _logTerminalRegressionBlocked({
    required SosState incoming,
    required String source,
  }) {
    final terminal = _sosLifecycle.activeTerminalWatermark;
    if (terminal == null) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_TERMINAL_REGRESSION_BLOCKED '
      'incidentId=${terminal.backendIncidentId ?? terminal.incident?.id ?? "none"} '
      'generation=${terminal.generation} terminalState=${terminal.stage.name} '
      'incomingRawStatus=${incoming.name} '
      'incomingNormalizedStatus=${incoming.name} source=$source '
      'reason=same_generation_authoritative_terminal_fence',
    );
  }

  bool _validatePublicSosTransition({
    required SosState from,
    required SosState to,
    required String source,
  }) {
    if (from == to) {
      return true;
    }
    if (SosStateMachine.canTransition(from: from, to: to)) {
      BleDebugRegistry.instance.recordEvent(
        'SDK_SOS_STATE_MACHINE_TRANSITION_ACCEPTED '
        'source=$source from=${from.name} to=${to.name}',
      );
      return true;
    }
    BleDebugRegistry.instance.recordEvent(
      'SDK_SOS_STATE_MACHINE_TRANSITION_REJECTED '
      'source=$source from=${from.name} to=${to.name}',
    );
    final retainedBypass = _retainedPublicSosStateMachineBypass(
      to: to,
      source: source,
    );
    if (retainedBypass != null) {
      BleDebugRegistry.instance.recordEvent(
        'SDK_SOS_STATE_MACHINE_BYPASS_RETAINED '
        'source=$source from=${from.name} to=${to.name} '
        'reason=${retainedBypass.reason} '
        'authority=${retainedBypass.authority} '
        'origin=${retainedBypass.origin} '
        'policy=${retainedBypass.policy}',
      );
      return true;
    }
    _logPublicSosStateMachineBypassBlocked(
      from: from,
      to: to,
      source: source,
      reason: 'invalid_public_sos_transition',
    );
    return false;
  }

  _PublicSosStateMachineBypass? _retainedPublicSosStateMachineBypass({
    required SosState to,
    required String source,
  }) {
    if (_isAuthoritativePublicSosTerminalBypass(to: to, source: source)) {
      return _PublicSosStateMachineBypass(
        reason: _publicSosTerminalBypassReason(source),
        authority: _publicSosBypassAuthority(source),
        origin: _publicSosBypassOrigin(source),
        policy: 'authoritative_terminal',
      );
    }
    if (to == SosState.failed && _isAuthoritativePublicSosFailure(source)) {
      return _PublicSosStateMachineBypass(
        reason: _publicSosFailureBypassReason(source),
        authority: _publicSosBypassAuthority(source),
        origin: _publicSosBypassOrigin(source),
        policy: 'authoritative_failure',
      );
    }
    if (to == SosState.idle && _isAuthoritativePublicSosClear(source)) {
      return _PublicSosStateMachineBypass(
        reason: _publicSosClearBypassReason(source),
        authority: _publicSosBypassAuthority(source),
        origin: _publicSosBypassOrigin(source),
        policy: 'authoritative_clear',
      );
    }
    if (_isAuthoritativePublicSosOpenBypass(source)) {
      return _PublicSosStateMachineBypass(
        reason: _publicSosOpenBypassReason(source),
        authority: _publicSosBypassAuthority(source),
        origin: _publicSosBypassOrigin(source),
        policy: 'sdk_public_lifecycle_shortcut',
      );
    }
    return null;
  }

  bool _isAuthoritativePublicSosTerminalBypass({
    required SosState to,
    required String source,
  }) {
    if (!_isTerminalPublicSosState(to)) {
      return false;
    }
    return source == 'sos_state_stream' ||
        source.startsWith('repository_load:') ||
        source.startsWith('sos_rehydrate:') ||
        source.startsWith('fetch_sos_state') ||
        source.startsWith('device_sos_status:') ||
        source == 'public_sos_result' ||
        source == 'pre_sos_cancelled_by_device' ||
        source == 'device_terminal_event' ||
        source == 'protection_platform_event_terminal' ||
        source == 'native_backend_sync_queued_cancel_backstop';
  }

  bool _isAuthoritativePublicSosFailure(String source) {
    return source == 'public_sos_backend_failed' ||
        source == 'countdown_zero_activation_failed';
  }

  bool _isAuthoritativePublicSosClear(String source) {
    return source == 'clear_session' ||
        source.startsWith('repository_load:') ||
        source.startsWith('sos_rehydrate:') ||
        source.startsWith('fetch_sos_state') ||
        source.endsWith(':external_only') ||
        source == 'record_public_sos_result:external_only' ||
        source == 'get_current_sos_incident:external_only' ||
        source == 'fetch_sos_state:external_fallback' ||
        source == 'terminal_summary_acknowledged' ||
        source == 'public_cancel_completed:clear_current_sos' ||
        source == 'app_origin_device_terminal_cleanup' ||
        source == 'ios_ble_sos_snapshot_cancelled' ||
        source == 'public_pre_sos_cancelled' ||
        source == 'device_pre_sos_cancel_blocked_backend_publish' ||
        source == 'remembered_device_terminal_cancel_blocks_activation' ||
        source == 'device_terminal_cancel_blocks_activation' ||
        source.endsWith(':stale_cancelled_runtime_ignored') ||
        source.endsWith(':pre_sos_guard') ||
        source == 'pre_sos_clear_empty';
  }

  bool _isAuthoritativePublicSosOpenBypass(String source) {
    return source == 'public_sos_backend_publish_start' ||
        source == 'public_sos_result' ||
        source.startsWith('repository_load:') ||
        source.startsWith('sos_rehydrate:') ||
        source == 'fetch_sos_state:device_override' ||
        source.startsWith('device_sos_status:') ||
        source == 'sos_state_stream:device_override' ||
        source == 'app_origin_ble_runtime_active' ||
        source == 'ios_ble_sos_snapshot_active';
  }

  String _publicSosTerminalBypassReason(String source) {
    if (source == 'sos_state_stream') {
      return 'repository_terminal_stream';
    }
    if (source.startsWith('repository_load:')) {
      return 'repository_rehydration_terminal';
    }
    if (source.startsWith('sos_rehydrate:')) {
      return 'backend_rehydration_terminal';
    }
    if (source.startsWith('fetch_sos_state')) {
      return 'repository_fetch_terminal';
    }
    if (source.startsWith('device_sos_status:') ||
        source == 'device_terminal_event' ||
        source == 'pre_sos_cancelled_by_device' ||
        source == 'protection_platform_event_terminal' ||
        source == 'native_backend_sync_queued_cancel_backstop') {
      return 'device_runtime_terminal';
    }
    if (source == 'public_sos_result') {
      return 'app_public_terminal_result';
    }
    return 'authoritative_terminal';
  }

  String _publicSosFailureBypassReason(String source) {
    if (source == 'public_sos_backend_failed') {
      return 'app_public_backend_failure';
    }
    if (source == 'countdown_zero_activation_failed') {
      return 'countdown_zero_activation_failure';
    }
    return 'authoritative_failure';
  }

  String _publicSosClearBypassReason(String source) {
    if (source.endsWith(':external_only') ||
        source == 'record_public_sos_result:external_only' ||
        source == 'get_current_sos_incident:external_only' ||
        source == 'fetch_sos_state:external_fallback') {
      return 'external_remote_relay_isolation';
    }
    if (source == 'clear_session' ||
        source == 'terminal_summary_acknowledged' ||
        source == 'pre_sos_clear_empty') {
      return 'explicit_idle_reset';
    }
    if (source.startsWith('repository_load:')) {
      return 'repository_rehydration_clear';
    }
    if (source.startsWith('sos_rehydrate:')) {
      return 'backend_rehydration_clear';
    }
    if (source.startsWith('fetch_sos_state')) {
      return 'repository_fetch_clear';
    }
    if (source == 'public_cancel_completed:clear_current_sos' ||
        source == 'public_pre_sos_cancelled') {
      return 'app_public_clear';
    }
    if (source == 'app_origin_device_terminal_cleanup' ||
        source == 'ios_ble_sos_snapshot_cancelled' ||
        source == 'device_pre_sos_cancel_blocked_backend_publish' ||
        source == 'remembered_device_terminal_cancel_blocks_activation' ||
        source == 'device_terminal_cancel_blocks_activation' ||
        source.endsWith(':stale_cancelled_runtime_ignored') ||
        source.endsWith(':pre_sos_guard')) {
      return 'device_runtime_clear';
    }
    return 'authoritative_clear';
  }

  String _publicSosOpenBypassReason(String source) {
    if (source == 'public_sos_backend_publish_start' ||
        source == 'public_sos_result') {
      return 'app_trigger_publish_shortcut';
    }
    if (source.startsWith('repository_load:')) {
      return 'repository_rehydration_open';
    }
    if (source.startsWith('sos_rehydrate:')) {
      return 'backend_rehydration_open';
    }
    if (source == 'fetch_sos_state:device_override' ||
        source == 'sos_state_stream:device_override' ||
        source.startsWith('device_sos_status:') ||
        source == 'app_origin_ble_runtime_active' ||
        source == 'ios_ble_sos_snapshot_active') {
      return 'device_runtime_open_override';
    }
    return 'sdk_public_lifecycle_shortcut';
  }

  String _publicSosBypassAuthority(String source) {
    if (source.startsWith('repository_load:') ||
        source == 'sos_state_stream' ||
        source.startsWith('fetch_sos_state') ||
        source == 'public_sos_result') {
      return 'repository';
    }
    if (source.startsWith('sos_rehydrate:')) {
      return 'backend_rehydration';
    }
    if (source.startsWith('device_sos_status:') ||
        source == 'device_terminal_event' ||
        source == 'protection_platform_event_terminal' ||
        source == 'native_backend_sync_queued_cancel_backstop' ||
        source == 'app_origin_ble_runtime_active' ||
        source == 'ios_ble_sos_snapshot_active' ||
        source == 'ios_ble_sos_snapshot_cancelled' ||
        source == 'app_origin_device_terminal_cleanup' ||
        source == 'device_pre_sos_cancel_blocked_backend_publish' ||
        source == 'remembered_device_terminal_cancel_blocks_activation' ||
        source == 'device_terminal_cancel_blocks_activation' ||
        source.endsWith(':stale_cancelled_runtime_ignored') ||
        source.endsWith(':pre_sos_guard')) {
      return 'device_runtime';
    }
    if (source.startsWith('public_') ||
        source == 'terminal_summary_acknowledged' ||
        source == 'clear_session' ||
        source == 'countdown_zero_activation_failed' ||
        source == 'pre_sos_clear_empty') {
      return 'sdk_app_action';
    }
    if (source.endsWith(':external_only')) {
      return 'external_relay_guard';
    }
    return 'sdk';
  }

  String _publicSosBypassOrigin(String source) {
    if (source.endsWith(':external_only') ||
        source == 'record_public_sos_result:external_only' ||
        source == 'get_current_sos_incident:external_only' ||
        source == 'fetch_sos_state:external_fallback') {
      return 'external_remote_relay';
    }
    if (source.startsWith('device_sos_status:') ||
        source == 'device_terminal_event' ||
        source == 'protection_platform_event_terminal' ||
        source == 'native_backend_sync_queued_cancel_backstop' ||
        source == 'app_origin_ble_runtime_active' ||
        source == 'ios_ble_sos_snapshot_active' ||
        source == 'ios_ble_sos_snapshot_cancelled' ||
        source == 'app_origin_device_terminal_cleanup' ||
        source == 'device_pre_sos_cancel_blocked_backend_publish' ||
        source == 'remembered_device_terminal_cancel_blocks_activation' ||
        source == 'device_terminal_cancel_blocks_activation' ||
        source.endsWith(':stale_cancelled_runtime_ignored') ||
        source.endsWith(':pre_sos_guard')) {
      return 'own_ble_device';
    }
    if (source.startsWith('public_') ||
        source == 'terminal_summary_acknowledged' ||
        source == 'clear_session' ||
        source == 'countdown_zero_activation_failed' ||
        source == 'pre_sos_clear_empty') {
      return 'app';
    }
    if (source.startsWith('repository_load:') ||
        source == 'sos_state_stream' ||
        source.startsWith('fetch_sos_state') ||
        source.startsWith('sos_rehydrate:')) {
      return 'backend_repository';
    }
    return 'unknown';
  }

  void _logPublicSosStateMachineBypassBlocked({
    required SosState from,
    required SosState to,
    required String source,
    required String reason,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SDK_SOS_STATE_MACHINE_BYPASS_BLOCKED '
      'source=$source from=${from.name} to=${to.name} reason=$reason',
    );
  }

  SosState _applyPublicSosRuntimePrecedence({
    required SosState incoming,
    required String source,
  }) {
    if (!_shouldKeepSdkPreSosArmingState(incoming: incoming, source: source)) {
      final appOriginBridge = _currentAppOriginActiveSosBridge();
      if (appOriginBridge != null &&
          incoming == SosState.idle &&
          _isOpenSosState(_publicSosState) &&
          _publicSosClosureInFlight == null) {
        _logSosRuntimePrecedence(
          incomingSource: source,
          incoming: incoming,
          decision: 'keep_app_origin_active',
          reason: 'app_origin_backend_trigger_confirmed',
        );
        return appOriginBridge.state;
      }
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
    // If the public lifecycle already advanced past arming (the SOS was
    // triggered / sending / sent / acknowledged), the runtime should never
    // degrade an incoming close back into "arming". The stale
    // _lastPublishedPreSosStatus left over from the original countdown can
    // otherwise pin the precedence layer to arming and swallow cancelled.
    if (_publicSosState == SosState.triggerRequested ||
        _publicSosState == SosState.triggeredLocal ||
        _publicSosState == SosState.sending ||
        _publicSosState == SosState.sent ||
        _publicSosState == SosState.acknowledged ||
        _publicSosState == SosState.cancelRequested) {
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
    final deviceId =
        _lastDeviceStatus?.nodeId?.toString() ??
        status.activeDeviceId ??
        status.protectedDeviceId ??
        _lastDeviceStatus?.deviceId ??
        'none';
    final commandAvailable =
        deviceSosController.shortCommandAvailable ||
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
    DeviceSosStatus? status,
    String? cycleKey,
  }) {
    if (state == null || !_isOpenSosState(state)) {
      return false;
    }
    if (_publicSosState == SosState.cancelRequested &&
        _publicSosStateGeneration == _sosLifecycle.current.generation &&
        (_publicSosClosureInFlight == _SosClosureIntent.cancel ||
            _sosLifecycle.current.stage == SosLifecycleStage.cancelling)) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_ACTIVE_SUPPRESSED reason=logical_cancel_pending '
        'state=${status?.state.name ?? state.name} source=$source',
      );
      return true;
    }
    if (status != null) {
      final nodeId = _appOriginRuntimeNodeId(status);
      final rawRuntimeCycleKey = _runtimeDeviceSosCycleKey(
        status: status,
        nodeId: nodeId,
      );
      if (_terminalWatermarkRejectsRestoredEvidence(
        observedAt: status.lastPacketAt ?? status.updatedAt,
        nodeId: nodeId,
        cycleKey: rawRuntimeCycleKey ?? cycleKey,
      )) {
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_SOS_ACTIVE_SUPPRESSED '
          'reason=authoritative_terminal_same_cycle '
          'state=${status.state.name}',
        );
        return true;
      }
    }
    if (status != null &&
        _isAppOwnedBleOpenState(
          status: status,
          state: state,
          cycleKey: cycleKey,
        )) {
      _rememberAppOriginDeviceOwnershipContext(status);
      final incidentId =
          _lastKnownActiveSosIncident?.id ??
          _publicSosFallbackIncident?.id ??
          _pendingAppTriggeredSosBridge?.incidentId ??
          _appOriginBleRuntimeIncidentId(status, cycleKey: cycleKey);
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_ORIGIN_BLE_ACTIVE_SURFACED '
        'reason=app_owned_ble_runtime incidentId=$incidentId '
        'cycleKey=${cycleKey ?? "-"} source=$source state=${state.name}',
      );
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
    final cycleId =
        _activeDeviceRuntimeCycleKey ??
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

  Future<bool> _applyAuthoritativeTerminalTransition({
    required SosIncident terminalIncident,
    required String source,
    String? incomingRawStatus,
    int? acceptedGeneration,
  }) async {
    final terminalState = terminalIncident.state;
    if (!_isTerminalPublicSosState(terminalState) ||
        !terminalIncident.isBackendConfirmed) {
      return false;
    }
    final lifecycle = _sosLifecycle.current;
    final evidenceMatches = sosIncidentEvidenceMatchesLifecycle(
      lifecycle,
      terminalIncident,
    );
    final immutableRepositoryAcceptanceMatchesGeneration =
        acceptedGeneration != null &&
        acceptedGeneration == lifecycle.generation &&
        lifecycle.isOpen &&
        lifecycle.localActionable &&
        !lifecycle.externalOnly;
    final sameTerminalLifecycle =
        lifecycle.isTerminal &&
        ((lifecycle.backendIncidentId ?? lifecycle.incident?.id) ==
            terminalIncident.id) &&
        ((terminalState == SosState.resolved &&
                lifecycle.stage == SosLifecycleStage.resolved) ||
            (terminalState == SosState.cancelled &&
                lifecycle.stage == SosLifecycleStage.cancelled));
    if (!lifecycle.isOpen ||
        !lifecycle.localActionable ||
        lifecycle.externalOnly ||
        !(evidenceMatches || immutableRepositoryAcceptanceMatchesGeneration)) {
      if (sameTerminalLifecycle) {
        _emitPublicSosState(terminalState, source: 'sos_state_stream');
        _logPublicSosLifecycleState(source: '$source:terminal_duplicate');
        return true;
      }
      return false;
    }

    final operationKey =
        '${terminalIncident.id}|${lifecycle.generation}|${terminalState.name}';
    if (!_authoritativeTerminalOperationKeys.add(operationKey)) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_SIDE_EFFECT_DEDUPED incidentId=${terminalIncident.id} '
        'generation=${lifecycle.generation} terminalState=${terminalState.name} '
        'source=$source',
      );
      return true;
    }

    if (terminalState == SosState.resolved) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_BACKEND_RESOLVE_HANDLER_ENTERED '
        'incidentId=${terminalIncident.id} '
        'generation=${lifecycle.generation} '
        'currentLifecycle=${lifecycle.stage.name} '
        'connectedDevicePresent=${(_lastPublicDeviceStatus ?? _lastDeviceStatus)?.connected == true} '
        'source=$source rawStatus=${incomingRawStatus ?? terminalState.name}',
      );
    }

    final deviceCycleKey = _deviceCycleKeyCorrelatedToLifecycle(
      lifecycle,
      incident: terminalIncident,
    );
    final capturedDeviceSnapshot = _captureTerminalDeviceSnapshot(
      reason: 'authoritative_terminal_acceptance',
    );
    final confirmation = _sosLifecycle.confirmTerminal(
      stage: terminalState == SosState.cancelled
          ? SosLifecycleStage.cancelled
          : SosLifecycleStage.resolved,
      incident: terminalIncident,
      deviceCycleKey: deviceCycleKey,
      emitToStream: false,
    );
    _setSosDeviceMirrorState(
      terminalState == SosState.resolved
          ? _SosDeviceMirrorState.pendingResolve
          : _SosDeviceMirrorState.pendingCancel,
      source: '$source:terminal_accepted',
    );
    _emitPublicSosState(terminalState, source: 'sos_state_stream');
    final deviceClearProof = _captureCurrentPhysicalSosTarget(
      lifecycle: lifecycle,
      terminalIncident: terminalIncident,
      capturedSnapshot: capturedDeviceSnapshot,
    );
    if (deviceClearProof != null) {
      _armTerminalConvergenceFenceFromProof(deviceClearProof);
    }

    final acceptedTerminal = await confirmation;
    if (!acceptedTerminal.isTerminal ||
        acceptedTerminal.lifecycleId != lifecycle.lifecycleId ||
        acceptedTerminal.generation != lifecycle.generation) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_SETTLEMENT_IGNORED reason=newer_lifecycle '
        'terminal=${terminalState.name}',
      );
      return true;
    }

    BleDebugRegistry.instance.recordEvent(
      'SOS_TERMINAL_CONFIRMED source=$source '
      'terminal=${terminalState.name} '
      'deviceCycleCorrelated=${deviceCycleKey != null}',
    );
    _sosLifecycle.publishCurrent();
    BleDebugRegistry.instance.recordEvent(
      'SOS_TERMINAL_HANDOFF source=$source terminal=${terminalState.name}',
    );
    BleDebugRegistry.instance.recordEvent(
      'SOS_TERMINAL_LIFECYCLE_PUBLISHED terminal=${terminalState.name}',
    );
    if (terminalState == SosState.resolved) {
      _recordBackendTerminalTransportState(
        backendAction: 'resolve',
        lifecycleStage: acceptedTerminal.stage,
        terminalState: terminalState.name,
      );
      _postResolvePhysicalRxGeneration = acceptedTerminal.generation;
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRANSPORT_TEARDOWN_DECISION '
        'trigger=backend_resolved action=preserve '
        'reason=incident_terminal_transport_persistent '
        'lifecycleGeneration=${acceptedTerminal.generation}',
      );
    }
    _applyTerminalSosSuppression(
      reason: 'backend_terminal_state:${terminalState.name}',
      terminalState: terminalState,
      nodeId: terminalIncident.originatorNodeId,
    );
    await _clearPreSosSessionDurably(
      reason: 'repository_terminal_stream:${terminalState.name}',
      emitIdleState: false,
    );
    _clearPendingAppTriggeredSosBridge(
      reason: 'repository_terminal_stream:${terminalState.name}',
    );
    _clearAppOriginActiveSosBridge(
      reason: 'repository_terminal_stream:${terminalState.name}',
    );
    _clearAppOriginDeviceOwnershipContext(
      reason: 'repository_terminal_stream:${terminalState.name}',
    );
    _clearDeviceRuntimeSosOwnership(
      reason: 'repository_terminal_stream:${terminalState.name}',
    );
    if (deviceClearProof == null) {
      _setSosDeviceMirrorState(
        _SosDeviceMirrorState.synchronized,
        source: '$source:no_physical_mirror_required',
      );
    } else {
      _scheduleRemoteTerminalDeviceClear(deviceClearProof);
    }
    return true;
  }

  Future<void> _syncPublicSosStateFromRepository(SosState state) async {
    if (_isOpenSosState(state) &&
        _sosLifecycle.activeTerminalWatermark != null &&
        !_hasNewAuthoritativeGenerationSinceTerminal()) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TERMINAL_FENCE_SUPPRESSED_OPEN source=repository_${state.name} '
        'reason=authoritative_backend_terminal',
      );
      return;
    }
    SosIncident? repositoryIncident;
    if (state != SosState.idle) {
      repositoryIncident = await sosRepository.getCurrentIncident();
      if (_isExternalOnlySosIncident(
        repositoryIncident,
        source: 'sos_state_stream',
      )) {
        _clearExternalOnlyPublicSosResidue(
          reason: 'sos_state_stream_external_only',
        );
        if (_publicSosState != SosState.idle) {
          _emitPublicSosState(
            SosState.idle,
            source: 'sos_state_stream:external_only',
          );
        }
        return;
      }
    }
    final lifecycle = _sosLifecycle.current;
    final repositoryIncidentMatchesLifecycle =
        repositoryIncident != null &&
        sosIncidentEvidenceMatchesLifecycle(lifecycle, repositoryIncident);
    final repositoryHasTerminalIncident =
        repositoryIncident != null &&
        (repositoryIncident.state == SosState.cancelled ||
            repositoryIncident.state == SosState.resolved);
    final productionMqttTerminalAccepted =
        sosRepository is MqttOperationalSosRepository &&
        repositoryHasTerminalIncident &&
        repositoryIncident.isBackendConfirmed &&
        lifecycle.isOpen &&
        lifecycle.localActionable &&
        !lifecycle.externalOnly &&
        !_hasNewAuthoritativeGenerationSinceTerminal();
    final requestedLifecycle = switch (state) {
      SosState.resolved => SosLifecycleStage.resolved,
      SosState.cancelled => SosLifecycleStage.cancelled,
      SosState.arming => SosLifecycleStage.arming,
      SosState.triggerRequested ||
      SosState.triggeredLocal ||
      SosState.sending ||
      SosState.sent ||
      SosState.acknowledged ||
      SosState.cancelRequested => SosLifecycleStage.active,
      SosState.idle || SosState.failed => SosLifecycleStage.idle,
    };
    final terminalLifecycleAdmitted =
        repositoryHasTerminalIncident &&
        (repositoryIncidentMatchesLifecycle || productionMqttTerminalAccepted);
    final activeLifecycleAdmitted =
        repositoryIncident != null &&
        lifecycle.isOpen &&
        (repositoryIncident.state == SosState.sent ||
            repositoryIncident.state == SosState.acknowledged) &&
        repositoryIncidentMatchesLifecycle &&
        repositoryIncident.isBackendConfirmed;
    final lifecycleAdmitted =
        terminalLifecycleAdmitted || activeLifecycleAdmitted;
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_EVENT_LIFECYCLE_DECISION '
      'rawStatus=${state.name} normalizedStatus=${state.name} '
      'previousLifecycle=${lifecycle.stage.name} '
      'requestedLifecycle=${requestedLifecycle.name} '
      'admitted=$lifecycleAdmitted '
      'reason=${terminalLifecycleAdmitted
          ? "correlated_terminal_incident"
          : activeLifecycleAdmitted
          ? "correlated_active_incident"
          : "repository_evidence_not_admitted"}',
    );
    if (repositoryHasTerminalIncident &&
        lifecycle.isOpen &&
        _hasNewAuthoritativeGenerationSinceTerminal() &&
        !repositoryIncidentMatchesLifecycle) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_STALE_TERMINAL_IGNORED_FOR_NEW_GENERATION '
        'terminalGeneration=${_sosLifecycle.activeTerminalWatermark?.generation ?? 0} '
        'activeGeneration=${lifecycle.generation} reason=identity_mismatch',
      );
      return;
    }
    if (repositoryHasTerminalIncident &&
        (repositoryIncidentMatchesLifecycle ||
            productionMqttTerminalAccepted) &&
        await _applyAuthoritativeTerminalTransition(
          terminalIncident: repositoryIncident,
          source: sosRepository is MqttOperationalSosRepository
              ? 'mqtt_correlated_terminal'
              : 'repository_correlated_terminal',
          incomingRawStatus: state.name,
        )) {
      return;
    }
    if (repositoryIncident != null && lifecycle.isOpen) {
      if ((repositoryIncident.state == SosState.sent ||
              repositoryIncident.state == SosState.acknowledged) &&
          repositoryIncidentMatchesLifecycle &&
          repositoryIncident.isBackendConfirmed &&
          lifecycle.stage != SosLifecycleStage.cancelling) {
        final confirmedLifecycle = await _sosLifecycle.confirmActive(
          origin: lifecycle.origin,
          localIncidentId:
              lifecycle.localIncidentId ??
              repositoryIncident.provisionalIncidentId ??
              repositoryIncident.id,
          backendIncidentId: repositoryIncident.id,
          triggerSource:
              repositoryIncident.triggerSource ?? lifecycle.triggerSource,
          deviceId: repositoryIncident.deviceId ?? lifecycle.deviceId,
          nodeId: repositoryIncident.originatorNodeId ?? lifecycle.nodeId,
          hardwareId:
              lifecycle.hardwareId ??
              _physicalHardwareIdForStatus(_lastDeviceStatus) ??
              repositoryIncident.hardwareId,
          incident: repositoryIncident,
          recoveryStatus: lifecycle.recoveryStatus,
        );
        if (repositoryIncident.state == SosState.acknowledged) {
          _recordBackendTerminalTransportState(
            backendAction: 'ack',
            lifecycleStage: confirmedLifecycle.stage,
            terminalState: repositoryIncident.state.name,
          );
        }
        final deviceSosStatus = deviceSosController.currentStatus;
        if (confirmedLifecycle.origin == SosLifecycleOrigin.localApp &&
            confirmedLifecycle.incident?.isBackendConfirmed == true &&
            (deviceSosStatus.state == DeviceSosState.active ||
                deviceSosStatus.state == DeviceSosState.acknowledged)) {
          // Device ACTIVE can arrive before the processed handoff. Re-evaluate
          // its already strict identity proof now that the lifecycle exposes
          // both provisional and canonical incident identities.
          _rememberAppOriginDeviceOwnershipContext(deviceSosStatus);
        }
      }
    }
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
    if (_clearStaleCancelledRuntimeFallbackDuringAppArming(
      source: 'sos_state_stream',
    )) {
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
      _emitPublicSosState(
        SosState.idle,
        source: 'sos_state_stream:acknowledged',
      );
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
    if (_preSosSession?.owner == _SosOwner.app ||
        _recentAppOriginMirroredPreSosBridge != null) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_APP_ORIGIN_STALE_CANCELLED_RUNTIME_IGNORED '
        'reason=app_arming_active source=$source',
      );
    }
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
    final incomingIncidentId =
        _publicSosFallbackIncident?.id ??
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
    final deviceCountdownExpired =
        status.expectedActivationAt != null &&
        !DateTime.now().isBefore(status.expectedActivationAt!);
    final cycleKey = _deriveDeviceSosCycleKey(status);
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
          (status.state != DeviceSosState.preConfirm || sessionExpired) &&
          !_isAppOwnedBleRuntimeStatus(status, cycleKey: cycleKey)) {
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

    if (chosenPublicState != null && _isOpenSosState(chosenPublicState)) {
      final latestRepositoryIncident = await sosRepository.getCurrentIncident();
      final latestIsCorrelatedAcknowledgement =
          latestRepositoryIncident?.state == SosState.acknowledged &&
          latestRepositoryIncident!.isBackendConfirmed &&
          sosIncidentEvidenceMatchesLifecycle(
            _sosLifecycle.current,
            latestRepositoryIncident,
          );
      if (latestIsCorrelatedAcknowledgement &&
          chosenPublicState != SosState.acknowledged) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_BACKEND_ACK_PUBLIC_PROJECTION '
          'action=preserve_acknowledged '
          'deviceState=${status.state.name} '
          'incomingPublicState=${chosenPublicState.name}',
        );
        chosenPublicState = SosState.acknowledged;
      }
      final latestIsCorrelatedTerminal =
          latestRepositoryIncident != null &&
          (latestRepositoryIncident.state == SosState.cancelled ||
              latestRepositoryIncident.state == SosState.resolved) &&
          sosIncidentEvidenceMatchesLifecycle(
            _sosLifecycle.current,
            latestRepositoryIncident,
          );
      if (latestIsCorrelatedTerminal) {
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_SOS_ACTIVE_SUPPRESSED '
          'reason=authoritative_terminal_same_cycle '
          'state=${status.state.name} source=$trigger',
        );
        return null;
      }
    }

    if (_shouldSuppressDeviceRuntimeOpenSosState(
      state: chosenPublicState,
      source: trigger,
      status: status,
      cycleKey: cycleKey,
    )) {
      chosenPublicState = null;
    }

    if (chosenPublicState != null &&
        _isTerminalPublicSosState(chosenPublicState) &&
        _remoteTerminalDeviceClearAcknowledgedProof != null &&
        _deviceTerminalStatusMatchesClearProof(
          status,
          _remoteTerminalDeviceClearAcknowledgedProof!,
        )) {
      BleDebugRegistry.instance.recordEvent(
        '[DEVICE_SOS_REHYDRATE] trigger=$trigger '
        'decision=suppress_authoritative_terminal_cleanup_ack '
        'incoming=${chosenPublicState.name}',
      );
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
        _publicTerminalGeneration == _sosLifecycle.current.generation &&
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
      DeviceSosState.unknown => null,
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
    if (_shouldIgnoreStaleCancelledRuntimeDuringAppArming(status)) {
      _recordStaleCancelledRuntimeIgnored(status);
      return null;
    }
    if (status.triggerOrigin == DeviceSosTransitionSource.app &&
        status.previousState == DeviceSosState.preConfirm) {
      return null;
    }
    // Device-side closures are always treated as cancellations: the physical
    // device has no "resolve" gesture, so opcode/subcode variants all map to
    // SosState.cancelled. This keeps the backend incident, the public state
    // stream, and the terminal notification intent in agreement.
    return SosState.cancelled;
  }

  bool _shouldIgnoreStaleCancelledRuntimeDuringAppArming(
    DeviceSosStatus status,
  ) {
    if (_publicSosClosureInFlight != null) {
      return false;
    }
    final hasAppArming =
        (_preSosSession?.owner == _SosOwner.app &&
            _buildCurrentPreSosStatus() != null) ||
        (_publicSosState == SosState.arming &&
            _recentAppOriginMirroredPreSosBridge != null);
    if (!hasAppArming) {
      return false;
    }
    final bridge = _recentAppOriginMirroredPreSosBridge;
    final expectedNodeId =
        _preSosSession?.originatorNodeId ?? bridge?.originatorNodeId;
    final statusNodeId = _appOriginRuntimeNodeId(status);
    if (expectedNodeId != null &&
        statusNodeId != null &&
        expectedNodeId != statusNodeId) {
      return false;
    }
    return true;
  }

  void _recordStaleCancelledRuntimeIgnored(DeviceSosStatus status) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_APP_ORIGIN_STALE_CANCELLED_RUNTIME_IGNORED '
      'reason=app_arming_active '
      'nodeId=${_appOriginRuntimeNodeId(status)?.toString() ?? "-"} '
      'packetId=${status.packetId?.toString() ?? "-"}',
    );
  }

  bool _isBleTerminalSosEventStatus(DeviceSosStatus status) {
    if (!status.derivedFromBlePacket) {
      return false;
    }
    final opcode = status.lastOpcode;
    if (opcode == EixamBleProtocol.sosEventUserDeactivatedOpcode) {
      return true;
    }
    final eventBytes = _parseHexBytes(status.lastPacketHex);
    if (eventBytes == null || eventBytes.isEmpty) {
      return false;
    }
    return eventBytes.first == EixamBleProtocol.sosEventUserDeactivatedOpcode;
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
    if (status.transitionSource != DeviceSosTransitionSource.device ||
        (!status.derivedFromBlePacket &&
            status.triggerOrigin != DeviceSosTransitionSource.device)) {
      return null;
    }
    final deviceCountdownExpired =
        status.expectedActivationAt != null &&
        !DateTime.now().isBefore(status.expectedActivationAt!);
    final publicState =
        status.state == DeviceSosState.preConfirm && deviceCountdownExpired
        ? SosState.sent
        : _mapDeviceStatusToPublicSosState(status);
    if (publicState == null || publicState == SosState.arming) {
      return null;
    }
    final cycleKey =
        _deriveDeviceSosCycleKey(status) ??
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
    SosIncident? incident,
  ) {
    if (incident == null) {
      return null;
    }
    if (_lastPublicSosIncidentId != null &&
        incident.id == _lastPublicSosIncidentId &&
        _lastPublicSosDeliveryChannel != null) {
      return incident.copyWith(deliveryChannel: _lastPublicSosDeliveryChannel);
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

  SosTerminalReason _publicSosFailureReasonForTriggerError({
    required Object? backendError,
    required bool backendUnavailable,
    required bool deviceAvailable,
  }) {
    if (backendUnavailable && !deviceAvailable) {
      return SosTerminalReason.notAvailable;
    }
    if (backendError is SosHttpException) {
      return switch (backendError.statusCode) {
        400 || 422 => SosTerminalReason.backendValidationFailed,
        401 || 403 || 409 => SosTerminalReason.backendRejected,
        _ => SosTerminalReason.deliveryFailed,
      };
    }
    if (backendError is SosException) {
      return switch (backendError.code) {
        'E_SOS_NOT_AVAILABLE' => SosTerminalReason.notAvailable,
        'E_PRE_SOS_CANCELLED_BY_DEVICE' =>
          SosTerminalReason.preSosCancelledByDevice,
        'E_SOS_POSITION_REQUIRED' ||
        'E_HTTP_SOS_POSITION_REQUIRED' ||
        'E_HTTP_SOS_TRIGGER_MISSING_SESSION' =>
          SosTerminalReason.backendValidationFailed,
        'E_SOS_TRIGGER_FAILED' ||
        'E_SOS_BACKEND_NOT_CONFIRMED' => SosTerminalReason.deliveryFailed,
        _ => SosTerminalReason.backendRejected,
      };
    }
    if (backendError is NetworkException) {
      return SosTerminalReason.deliveryFailed;
    }
    return SosTerminalReason.deliveryFailed;
  }

  Never _throwTriggerSosFailure({
    required Object? backendError,
    required bool backendUnavailable,
    required bool deviceAvailable,
  }) {
    if (backendUnavailable && !deviceAvailable) {
      throw const SosException('E_SOS_NOT_AVAILABLE', 'E_SOS_NOT_AVAILABLE');
    }
    if (backendError != null) {
      throw backendError;
    }
    throw const SosException(
      'E_SOS_BACKEND_NOT_CONFIRMED',
      'E_SOS_BACKEND_NOT_CONFIRMED',
    );
  }

  bool _hasAuthenticatedDeviceRegistrySession() {
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

  Future<void> _seedPreferredBleDeviceFromSystemAssociationIfNeeded({
    required String trigger,
  }) async {
    final manualDisconnectRequested = await preferredBleDeviceStore
        .readManualDisconnectRequested();
    _manualDisconnectRequested = manualDisconnectRequested;
    if (manualDisconnectRequested) {
      return;
    }
    final existingPreferred = await preferredBleDeviceStore
        .getPreferredDevice();
    if (existingPreferred != null) {
      return;
    }
    final status =
        _lastDeviceStatus ?? await deviceRepository.getDeviceStatus();
    if (status.paired && status.deviceId.trim().isNotEmpty) {
      return;
    }
    if (deviceRepository is! InMemoryDeviceRepository) {
      return;
    }
    final recovered = await (deviceRepository as InMemoryDeviceRepository)
        .recoverPreferredFromSystemAssociation();
    if (recovered == null || recovered.deviceId.trim().isEmpty) {
      return;
    }
    await preferredBleDeviceStore.savePreferredDevice(recovered);
    await preferredBleDeviceStore.saveManualDisconnectRequested(false);
    BleDebugRegistry.instance.recordEvent(
      'Preferred BLE device restored from system association -> '
      'trigger=$trigger bleHardwareId=${recovered.deviceId}',
    );
  }

  Future<void> _seedPreferredBleDeviceFromBackendRegistryIfNeeded({
    required String trigger,
  }) async {
    final manualDisconnectRequested = await preferredBleDeviceStore
        .readManualDisconnectRequested();
    _manualDisconnectRequested = manualDisconnectRequested;
    if (manualDisconnectRequested) {
      await preferredBleDeviceStore.clearPreferredDevice();
      _clearDeviceRuntimeResidueAfterManualDisconnect();

      return;
    }
    final existingPreferred = await preferredBleDeviceStore
        .getPreferredDevice();
    if (existingPreferred != null) {
      return;
    }
    final status =
        _lastDeviceStatus ?? await deviceRepository.getDeviceStatus();
    if (status.paired && status.deviceId.trim().isNotEmpty) {
      return;
    }
    if (!_hasAuthenticatedDeviceRegistrySession()) {
      return;
    }

    final registeredDevices = await deviceRegistryRepository
        .listRegisteredDevices();
    final candidate = _preferredReconnectCandidateFromRegistry(
      registeredDevices,
    );
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
    final candidates = devices
        .where((device) {
          final hardwareId = device.hardwareId.trim();
          return hardwareId.isNotEmpty &&
              hardwareId != bleHardwareId &&
              !isBleMacDeviceId(hardwareId) &&
              int.tryParse(hardwareId) != null;
        })
        .toList(growable: false);
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
    final statusNodeId =
        status.nodeId ??
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

  Future<void> _rememberDeviceIdentityMapping({
    required int nodeId,
    required String hardwareId,
    required String source,
    bool persist = true,
  }) async {
    final normalizedNodeId = _normalizeNodeId(nodeId);
    final normalizedHardwareId = hardwareId.trim();
    if (normalizedHardwareId.isEmpty) {
      return;
    }
    _hardwareIdByNodeId[normalizedNodeId] = normalizedHardwareId;
    _sosRuntimeNodeIdByHardwareId[normalizedHardwareId] = normalizedNodeId;
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS identity_mapping_registered '
      'originatorNodeId=$normalizedNodeId hardwareId=$normalizedHardwareId '
      'source=$source',
    );
    if (persist) {
      await _persistDeviceIdentityMappings();
    }
  }

  Future<void> _restoreDeviceIdentityMappings() async {
    final persisted = await _localStore.readJson(
      SharedPrefsSdkStore.deviceIdentityMappingsKey,
    );
    if (persisted == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    var restored = 0;
    for (final entry in persisted.entries) {
      final nodeId = int.tryParse(entry.key);
      final value = entry.value;
      if (nodeId == null || value is! Map<String, dynamic>) {
        continue;
      }
      final normalizedNodeId = _normalizeNodeId(nodeId);
      final hardwareId = value['hardwareId'] as String?;
      final observedAtRaw = value['observedAt'] as String?;
      final observedAt = observedAtRaw == null
          ? null
          : DateTime.tryParse(observedAtRaw)?.toUtc();
      if (observedAt != null &&
          now.difference(observedAt) > _externalRelayIdentityTtl) {
        continue;
      }
      final normalizedHardwareId = hardwareId?.trim();
      if (normalizedHardwareId == null || normalizedHardwareId.isEmpty) {
        continue;
      }
      _hardwareIdByNodeId[normalizedNodeId] = normalizedHardwareId;
      _sosRuntimeNodeIdByHardwareId[normalizedHardwareId] = normalizedNodeId;
      restored++;
    }
    if (restored > 0) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS identity_mappings_restored count=$restored',
      );
    }
  }

  Future<void> _persistDeviceIdentityMappings() async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _localStore.saveJson(
      SharedPrefsSdkStore.deviceIdentityMappingsKey,
      <String, dynamic>{
        for (final entry in _hardwareIdByNodeId.entries)
          entry.key.toString(): <String, dynamic>{
            'hardwareId': entry.value,
            'observedAt': now,
          },
      },
    );
  }

  Future<String?> _resolveOriginatorHardwareId(int originatorNodeId) async {
    final normalizedOriginatorNodeId = _normalizeNodeId(originatorNodeId);
    final cached = _hardwareIdByNodeId[normalizedOriginatorNodeId]?.trim();
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    await _restoreDeviceIdentityMappings();
    final restored = _hardwareIdByNodeId[normalizedOriginatorNodeId]?.trim();
    if (restored != null && restored.isNotEmpty) {
      return restored;
    }
    final status = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    if (_normalizeNodeIdOrNull(status?.nodeId) == normalizedOriginatorNodeId) {
      final hardwareId = _canonicalHardwareIdForStatus(status);
      if (hardwareId != null && hardwareId.isNotEmpty) {
        await _rememberDeviceIdentityMapping(
          nodeId: normalizedOriginatorNodeId,
          hardwareId: hardwareId,
          source: 'current_device_status',
        );
        return hardwareId;
      }
    }
    return null;
  }

  Future<void> _restoreRecentExternalRelaySosContexts() async {
    final persisted = await _localStore.readJson(
      SharedPrefsSdkStore.externalRelaySosContextsKey,
    );
    if (persisted == null) {
      return;
    }
    final now = DateTime.now().toUtc();
    var restored = 0;
    for (final entry in persisted.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) {
        continue;
      }
      final originatorNodeId = (value['originatorNodeId'] as num?)?.toInt();
      final relayNodeId = (value['relayNodeId'] as num?)?.toInt();
      final relayHardwareId = value['relayHardwareId'] as String?;
      final backendIncidentId = value['backendIncidentId'] as String?;
      final triggerDeviceId =
          (value['acceptedTriggerDeviceId'] as String?) ??
          (value['triggerDeviceId'] as String?);
      final triggerObservedAtRaw = value['triggerObservedAt'] as String?;
      final triggerObservedAt = triggerObservedAtRaw == null
          ? null
          : DateTime.tryParse(triggerObservedAtRaw)?.toUtc();
      final baselineTerminal = value['baselineTerminal'] as String?;
      final baselineTerminalSignature =
          value['baselineTerminalSignature'] as String?;
      final baselineTerminalObservedAtRaw =
          value['baselineTerminalObservedAt'] as String?;
      final baselineTerminalObservedAt = baselineTerminalObservedAtRaw == null
          ? null
          : DateTime.tryParse(baselineTerminalObservedAtRaw)?.toUtc();
      final baselineEventSequence =
          (value['baselineEventSequence'] as num?)?.toInt() ?? 0;
      final expiresAtRaw = value['expiresAt'] as String?;
      final expiresAt = expiresAtRaw == null
          ? null
          : DateTime.tryParse(expiresAtRaw)?.toUtc();
      if (originatorNodeId == null ||
          expiresAt == null ||
          !expiresAt.isAfter(now)) {
        continue;
      }
      final normalizedOriginatorNodeId = _normalizeNodeId(originatorNodeId);
      final normalizedRelayNodeId = _normalizeNodeIdOrNull(relayNodeId);
      final contextKey = _remoteRelaySosContextKey(
        originatorNodeId: normalizedOriginatorNodeId,
        relayNodeId: normalizedRelayNodeId,
        relayHardwareId: relayHardwareId,
      );
      final restoredContext = _RecentExternalRelaySosContext(
        originatorNodeId: normalizedOriginatorNodeId,
        relayNodeId: normalizedRelayNodeId,
        relayHardwareId: relayHardwareId,
        backendIncidentId: backendIncidentId,
        triggerDeviceId: _normalizeNodeIdDeviceIdString(triggerDeviceId),
        triggerObservedAt: triggerObservedAt ?? now,
        baselineTerminal: baselineTerminal,
        baselineTerminalSignature: baselineTerminalSignature,
        baselineTerminalObservedAt: baselineTerminalObservedAt,
        baselineEventSequence: baselineEventSequence,
        expiresAt: expiresAt,
      );
      _recentExternalRelaySosContexts[contextKey] =
          _mergeRecentExternalRelaySosContext(
            previous: _recentExternalRelaySosContexts[contextKey],
            incoming: restoredContext,
          );
      restored++;
    }
    if (restored > 0) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS recent_contexts_restored count=$restored',
      );
    }
  }

  Future<void> _persistRecentExternalRelaySosContexts() async {
    final now = DateTime.now().toUtc();
    _recentExternalRelaySosContexts.removeWhere(
      (_, context) => now.isAfter(context.expiresAt),
    );
    await _localStore.saveJson(
      SharedPrefsSdkStore.externalRelaySosContextsKey,
      <String, dynamic>{
        for (final entry in _recentExternalRelaySosContexts.entries)
          entry.key: <String, dynamic>{
            'originatorNodeId': entry.value.originatorNodeId,
            if (entry.value.relayNodeId != null)
              'relayNodeId': entry.value.relayNodeId,
            if (entry.value.relayHardwareId != null)
              'relayHardwareId': entry.value.relayHardwareId,
            if (entry.value.backendIncidentId != null)
              'backendIncidentId': entry.value.backendIncidentId,
            if (entry.value.triggerDeviceId != null)
              'acceptedTriggerDeviceId': entry.value.triggerDeviceId,
            'triggerObservedAt': entry.value.triggerObservedAt
                .toUtc()
                .toIso8601String(),
            if (entry.value.baselineTerminal != null)
              'baselineTerminal': entry.value.baselineTerminal,
            if (entry.value.baselineTerminalSignature != null)
              'baselineTerminalSignature':
                  entry.value.baselineTerminalSignature,
            if (entry.value.baselineTerminalObservedAt != null)
              'baselineTerminalObservedAt': entry
                  .value
                  .baselineTerminalObservedAt!
                  .toUtc()
                  .toIso8601String(),
            'baselineEventSequence': entry.value.baselineEventSequence,
            'expiresAt': entry.value.expiresAt.toUtc().toIso8601String(),
          },
      },
    );
  }

  void _clearVerifiedDeviceAssignments() {
    _verifiedAssignedNodeIdsForSession.clear();
    _assignmentClaimInFlight.clear();
  }

  void _rememberVerifiedDeviceAssignment(int nodeId) {
    _verifiedAssignedNodeIdsForSession.add(nodeId.toString());
  }

  void _scheduleConnectedDeviceAssignmentClaim({
    required DeviceStatus status,
    DeviceStatus? previous,
  }) {
    if (!status.connected || status.nodeId == null) {
      return;
    }
    final nodeIdChanged = previous?.nodeId != status.nodeId;
    final becameConnected = previous?.connected != true;
    if (!nodeIdChanged && !becameConnected) {
      return;
    }
    unawaited(_claimConnectedDeviceAssignment(status));
  }

  Future<void> _claimConnectedDeviceAssignment(DeviceStatus status) async {
    final nodeId = status.nodeId;
    if (nodeId == null || !_hasAuthenticatedDeviceRegistrySession()) {
      return;
    }
    if (_verifiedAssignedNodeIdsForSession.contains(nodeId.toString())) {
      return;
    }
    if (!_assignmentClaimInFlight.add(nodeId)) {
      return;
    }
    try {
      var matched = false;
      try {
        final devices = await deviceRegistryRepository.listRegisteredDevices();
        matched = devices.any(
          (device) =>
              registeredHardwareIdMatchesNodeId(device.hardwareId, nodeId),
        );
      } catch (_) {
        matched = false;
      }
      if (matched) {
        _rememberVerifiedDeviceAssignment(nodeId);
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_ASSIGNMENT result=matched action=auto_claim',
        );
        return;
      }
      final firmwareVersion = status.firmwareVersion?.trim();
      final hardwareModel = (status.model ?? status.deviceAlias)?.trim();
      final registered = await deviceRegistryRepository.upsertRegisteredDevice(
        hardwareId: nodeId.toString(),
        firmwareVersion: firmwareVersion == null || firmwareVersion.isEmpty
            ? 'unknown'
            : firmwareVersion,
        hardwareModel: hardwareModel == null || hardwareModel.isEmpty
            ? 'EIXAM R1'
            : hardwareModel,
        pairedAt: (status.lastSeen ?? DateTime.now()).toUtc(),
      );
      if (registeredHardwareIdMatchesNodeId(registered.hardwareId, nodeId)) {
        _rememberVerifiedDeviceAssignment(nodeId);
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_ASSIGNMENT result=created action=auto_claim',
        );
        return;
      }
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_ASSIGNMENT result=mismatch action=auto_claim',
      );
    } catch (_) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_ASSIGNMENT result=failed action=auto_claim',
      );
    } finally {
      _assignmentClaimInFlight.remove(nodeId);
    }
  }

  Future<bool> _verifyExistingDeviceAssignment(int nodeId) async {
    if (_verifiedAssignedNodeIdsForSession.contains(nodeId.toString())) {
      return true;
    }
    try {
      final devices = await deviceRegistryRepository.listRegisteredDevices();
      final matched = devices.any(
        (device) =>
            registeredHardwareIdMatchesNodeId(device.hardwareId, nodeId),
      );
      if (matched) {
        _rememberVerifiedDeviceAssignment(nodeId);
      }
      return matched;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _retrySosAfterAssignmentVerification({
    required String originalCorrelationId,
    required String retryCorrelationId,
    required String signature,
    required String triggerSource,
    required String message,
    required TrackingPosition? positionSnapshot,
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
    final assignmentVerified = await _verifyExistingDeviceAssignment(nodeId);
    if (!assignmentVerified) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_ASSIGNMENT result=unverified action=retry_blocked',
      );
      return false;
    }
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_SOS_ASSIGNMENT result=matched action=retry_allowed',
    );
    try {
      if (_shouldBlockDeviceOriginPreSosBackendPublish(
        source: 'sos_backend_retry_after_assignment_verify',
        triggerSource: triggerSource,
        cycleKey: cycleKey,
        originatorNodeId: originatorNodeId,
        packetId: null,
      )) {
        return false;
      }
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
    } catch (_) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_ASSIGNMENT result=matched action=retry_failed',
      );
      return false;
    }
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

    final cycleKey =
        _deriveDeviceSosCycleKey(status) ??
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
    if (originatorNodeId == null ||
        !await _verifyExistingDeviceAssignment(originatorNodeId)) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_ASSIGNMENT result=unverified action=backend_sync_blocked',
      );
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_SOS_ASSIGNMENT result=matched action=backend_sync_allowed',
    );
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
          message:
              'SOS_BACKEND_PUBLISH_SKIPPED reason=duplicate_owner '
              'owner=device cycle=$cycleKey activeIncident=${incident!.id} '
              'state=${incident.state.name}',
        );
        return;
      }

      final positionSnapshot = await _loadPositionSnapshotForSos();
      if (positionSnapshot == null) {
        BleDebugRegistry.instance.recordEvent(
          'Device SOS backend sync continuing without position snapshot '
          'triggerSource=$triggerSource '
          'reason=location_never_blocks_activation',
        );
      }

      final relayContext = _relayContextFrom(status);
      final relayNodeId = relayContext == null
          ? null
          : _lastDeviceStatus?.nodeId ?? _knownLocalDeviceNodeId;
      final created = await _bleOperationalRuntimeBridge.promoteDeviceOriginatedSos(
        signature: 'device_sos:$cycleKey:$triggerSource',
        triggerSource: triggerSource,
        message: message,
        positionSnapshot: positionSnapshot,
        deviceId: originatorNodeId.toString(),
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
              message:
                  'SOS_BACKEND_PUBLISH_SKIPPED reason=duplicate_owner '
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
    try {
      final terminalIncident = await _runBackendTerminalClosure(
        intent: intent,
        status: status,
        cycleKey: cycleKey,
      );
      BleDebugRegistry.instance.recordEvent(
        'Device SOS backend ${intent.name} applied -> '
        'incidentId=${terminalIncident.id}',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Device SOS backend ${intent.name} failed -> '
        'incidentId=${incident?.id ?? "-"} error=$error',
      );
    }
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
    final incidentBeforeClosure = await sosRepository.getCurrentIncident();
    final lifecycleBeforeClosure = _sosLifecycle.current;
    final SosIncident terminal;
    final EixamNotificationIntentType notificationType;
    final EixamNotificationIntentSeverity severity;
    final String titleKey;
    final String bodyKey;
    switch (intent) {
      case _SosClosureIntent.cancel:
        terminal = await sosRepository.cancelSos();
        notificationType = EixamNotificationIntentType.sosCancelled;
        severity = EixamNotificationIntentSeverity.info;
        titleKey = 'notification.sos.cancelled.title';
        bodyKey = 'notification.sos.cancelled.body';
        break;
      case _SosClosureIntent.resolve:
        terminal = await sosRepository.resolveSos();
        notificationType = EixamNotificationIntentType.sosResolved;
        severity = EixamNotificationIntentSeverity.success;
        titleKey = 'notification.sos.resolved.title';
        bodyKey = 'notification.sos.resolved.body';
        break;
    }
    if (terminal.state != SosState.cancelled &&
        terminal.state != SosState.resolved) {
      return terminal;
    }
    final lifecycle = _sosLifecycle.current;
    final lifecycleNodeMatches =
        lifecycle.nodeId == null ||
        status.nodeId == null ||
        lifecycle.nodeId == status.nodeId;
    final terminalMatchesClosedRepositoryIncident =
        _hasBackendVisibleSosIncident(incidentBeforeClosure) &&
        incidentBeforeClosure != null &&
        sosIncidentEvidenceMatches(incidentBeforeClosure, terminal);
    if (lifecycle.isOpen &&
        lifecycle.lifecycleId == lifecycleBeforeClosure.lifecycleId &&
        lifecycle.generation == lifecycleBeforeClosure.generation &&
        lifecycleNodeMatches &&
        (sosIncidentEvidenceMatchesLifecycle(lifecycle, terminal) ||
            terminalMatchesClosedRepositoryIncident)) {
      await _sosLifecycle.confirmTerminal(
        stage: terminal.state == SosState.cancelled
            ? SosLifecycleStage.cancelled
            : SosLifecycleStage.resolved,
        incident: terminal,
      );
      await _clearPreSosSessionDurably(
        reason: 'device_backend_terminal:${terminal.state.name}',
        emitIdleState: false,
      );
    }
    _emitSosTerminalNotificationIntent(
      terminal,
      type: notificationType,
      severity: severity,
      titleKey: titleKey,
      bodyKey: bodyKey,
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
    final backendOrAppSosActive =
        _hasBackendVisibleSosIncident(activeIncident) ||
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

  bool _isExternalOnlySosIncident(
    SosIncident? incident, {
    required String source,
  }) {
    if (incident == null) {
      return false;
    }
    final decision = classifySosIncidentOrigin(
      incident,
      boundNodeId: _knownLocalDeviceNodeId ?? _lastDeviceStatus?.nodeId,
      boundDeviceId: _lastDeviceStatus?.deviceId,
      boundHardwareId: _lastDeviceStatus?.canonicalHardwareId,
    );
    if (!decision.isExternalOnly) {
      final recentExternalContext = _recentExternalRelaySosContextForIncident(
        incident,
      );
      if (recentExternalContext != null) {
        _correlateRemoteRelayBackendIncidentFromContext(
          context: recentExternalContext,
          incident: incident,
        );
        _logSosOriginDecision(
          source: source,
          decision: _externalSosOriginDecision(
            'recent_remote_lora_relay_backend_open_blocked',
          ),
        );
        return true;
      }
      return false;
    }
    _logSosOriginDecision(source: source, decision: decision);
    return true;
  }

  SosOriginDecision _externalSosOriginDecision(String reason) {
    return SosOriginDecision(
      actionability: SosActionability.externalOnly,
      originKind: SosOriginKind.remoteRelay,
      displaySurface: SosDisplaySurface.historyOnly,
      localStateMutation: false,
      publicIncident: false,
      backendPublish: false,
      reason: reason,
    );
  }

  _RecentExternalRelaySosContext? _recentExternalRelaySosContextForIncident(
    SosIncident incident,
  ) {
    final now = DateTime.now().toUtc();
    _recentExternalRelaySosContexts.removeWhere(
      (_, context) => now.isAfter(context.expiresAt),
    );
    if (_recentExternalRelaySosContexts.isEmpty) {
      return null;
    }
    // Explicit local-app/own-device provenance outranks a coincidental match
    // with the relay context's gateway hardware. A local SOS may be triggered
    // while the remote relay handoff is still settling on that same gateway.
    if (_hasPositiveLocalSosOriginProof(incident)) {
      return null;
    }
    final incidentDeviceId = incident.deviceId?.trim();
    final incidentHardwareId = incident.hardwareId?.trim().toLowerCase();
    final incidentOriginatorNodeId = _normalizeNodeIdOrNull(
      incident.originatorNodeId,
    );
    for (final context in _recentExternalRelaySosContexts.values) {
      if (incidentOriginatorNodeId == context.originatorNodeId) {
        return context;
      }
      if (incidentDeviceId == context.originatorNodeId.toString()) {
        return context;
      }
      final incidentDeviceIdAsNode = int.tryParse(incidentDeviceId ?? '');
      if (incidentDeviceIdAsNode != null &&
          _normalizeNodeId(incidentDeviceIdAsNode) ==
              context.originatorNodeId) {
        return context;
      }
      if (incidentHardwareId != null &&
          incidentHardwareId.isNotEmpty &&
          incidentHardwareId == context.relayHardwareId?.toLowerCase()) {
        return context;
      }
    }
    if (_isOpenSosState(incident.state)) {
      return _recentExternalRelaySosContexts.values.first;
    }
    return null;
  }

  bool _hasPositiveLocalSosOriginProof(SosIncident incident) {
    final decision = classifySosIncidentOrigin(
      incident,
      boundNodeId: _knownLocalDeviceNodeId ?? _lastDeviceStatus?.nodeId,
      boundDeviceId: _lastDeviceStatus?.deviceId,
      boundHardwareId: _lastDeviceStatus?.canonicalHardwareId,
    );
    return decision.actionability == SosActionability.localActionable;
  }

  int _normalizeNodeId(int nodeId) => nodeId & 0xFFFFFFFF;

  int? _normalizeNodeIdOrNull(int? nodeId) {
    if (nodeId == null) {
      return null;
    }
    return _normalizeNodeId(nodeId);
  }

  void _rememberRecentExternalRelaySosContext({
    required RemoteRelaySosSnapshot snapshot,
    String? relayHardwareId,
    String? backendIncidentId,
    String? triggerDeviceId,
  }) {
    final now = DateTime.now().toUtc();
    final originatorNodeId = _normalizeNodeId(snapshot.originatorNodeId);
    final relayNodeId = _normalizeNodeIdOrNull(snapshot.relayNodeId);
    final key = _remoteRelaySosContextKey(
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      relayHardwareId: relayHardwareId,
    );
    final exactExisting = _recentExternalRelaySosContexts[key];
    final bestExisting = _bestRecentExternalRelayContext(
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
    );
    final existing = exactExisting?.backendIncidentId?.trim().isNotEmpty == true
        ? exactExisting
        : bestExisting?.backendIncidentId?.trim().isNotEmpty == true
        ? bestExisting
        : exactExisting ?? bestExisting;
    final triggerObservedAt =
        existing?.triggerObservedAt ?? snapshot.receivedAt.toUtc();
    final normalizedBackendIncidentId = backendIncidentId?.trim();
    final acceptedTriggerDeviceId =
        _normalizeNodeIdDeviceIdString(triggerDeviceId) ??
        _normalizeNodeIdDeviceIdString(existing?.triggerDeviceId);
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS remote_context_remember_attempt '
      'originatorNodeId=$originatorNodeId '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'kind=${snapshot.kind.name} '
      'existing=${existing != null} '
      'backendIncidentId=${normalizedBackendIncidentId ?? existing?.backendIncidentId ?? "none"} '
      'acceptedTriggerDeviceId=${acceptedTriggerDeviceId ?? "none"}',
    );
    final shouldCaptureBaseline =
        existing == null ||
        existing.baselineTerminalSignature == null &&
            existing.baselineTerminalObservedAt == null;
    final baseline = shouldCaptureBaseline
        ? _captureRemoteRelayTerminalBaseline(
            snapshot: snapshot,
            triggerObservedAt: triggerObservedAt,
          )
        : null;
    final incomingContext = _RecentExternalRelaySosContext(
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      relayHardwareId: relayHardwareId ?? existing?.relayHardwareId,
      backendIncidentId: normalizedBackendIncidentId?.isNotEmpty == true
          ? normalizedBackendIncidentId
          : existing?.backendIncidentId,
      triggerDeviceId: acceptedTriggerDeviceId,
      triggerObservedAt: triggerObservedAt,
      baselineTerminal: baseline?.terminal ?? existing?.baselineTerminal,
      baselineTerminalSignature:
          baseline?.signature ?? existing?.baselineTerminalSignature,
      baselineTerminalObservedAt:
          baseline?.observedAt ?? existing?.baselineTerminalObservedAt,
      baselineEventSequence:
          baseline?.eventSequence ?? existing?.baselineEventSequence ?? 0,
      expiresAt: now.add(const Duration(minutes: 10)),
    );
    final remembered = _mergeRecentExternalRelaySosContext(
      previous: existing,
      incoming: incomingContext,
    );
    _removeRecentExternalRelayContextsFor(
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
    );
    _recentExternalRelaySosContexts[key] = remembered;
    if (existing?.backendIncidentId != null &&
        normalizedBackendIncidentId == null) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS remote_context_merge_preserved '
        'backendIncidentId=${remembered.backendIncidentId ?? "none"} '
        'acceptedTriggerDeviceId=${remembered.triggerDeviceId ?? "none"}',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS remote_context_baseline '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'originatorNodeId=$originatorNodeId '
      'baselineTerminal=${remembered.baselineTerminal ?? "none"} '
      'baselineSignature=${remembered.baselineTerminalSignature ?? "none"} '
      'baselineObservedAt=${remembered.baselineTerminalObservedAt?.toIso8601String() ?? "none"}',
    );
    unawaited(_persistRecentExternalRelaySosContexts());
  }

  _RemoteRelayTerminalBaseline? _captureRemoteRelayTerminalBaseline({
    required RemoteRelaySosSnapshot snapshot,
    required DateTime triggerObservedAt,
  }) {
    final relayNodeId = _normalizeNodeIdOrNull(snapshot.relayNodeId);
    if (relayNodeId == null) {
      return _RemoteRelayTerminalBaseline(
        terminal: null,
        signature: null,
        observedAt: triggerObservedAt,
        eventSequence: _deviceSosStatusEventSequence,
      );
    }
    final status = deviceSosController.currentStatus;
    final statusRelayNodeId = _normalizeNodeIdOrNull(
      status.nodeId ??
          _parseDeviceRuntimeNodeId(status.lastPacketSignature) ??
          _parseSosCycleNodeId(status.lastPacketSignature),
    );
    if (statusRelayNodeId != relayNodeId) {
      return _RemoteRelayTerminalBaseline(
        terminal: null,
        signature: null,
        observedAt: triggerObservedAt,
        eventSequence: _deviceSosStatusEventSequence,
      );
    }
    final terminal = _remoteRelayTerminalResidueLabel(status);
    if (terminal == null) {
      return _RemoteRelayTerminalBaseline(
        terminal: null,
        signature: null,
        observedAt: triggerObservedAt,
        eventSequence: _deviceSosStatusEventSequence,
      );
    }
    return _RemoteRelayTerminalBaseline(
      terminal: terminal,
      signature: _relayTerminalResidueSignature(
        status: status,
        relayNodeId: relayNodeId,
        terminal: terminal,
      ),
      observedAt: _relayTerminalResidueObservedAt(status),
      eventSequence: _deviceSosStatusEventSequence,
    );
  }

  _RecentExternalRelaySosContext? _bestRecentExternalRelayContext({
    required int originatorNodeId,
    required int? relayNodeId,
  }) {
    final now = DateTime.now().toUtc();
    _recentExternalRelaySosContexts.removeWhere(
      (_, context) => now.isAfter(context.expiresAt),
    );
    final matches = _recentExternalRelaySosContexts.values
        .where((context) {
          if (context.originatorNodeId != originatorNodeId) {
            return false;
          }
          if (relayNodeId != null &&
              context.relayNodeId != null &&
              context.relayNodeId != relayNodeId) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
    if (matches.isEmpty) {
      return null;
    }
    matches.sort((left, right) {
      final leftCorrelated = left.backendIncidentId?.trim().isNotEmpty == true
          ? 0
          : 1;
      final rightCorrelated = right.backendIncidentId?.trim().isNotEmpty == true
          ? 0
          : 1;
      if (leftCorrelated != rightCorrelated) {
        return leftCorrelated.compareTo(rightCorrelated);
      }
      final leftAccepted = left.triggerDeviceId?.trim().isNotEmpty == true
          ? 0
          : 1;
      final rightAccepted = right.triggerDeviceId?.trim().isNotEmpty == true
          ? 0
          : 1;
      if (leftAccepted != rightAccepted) {
        return leftAccepted.compareTo(rightAccepted);
      }
      return right.triggerObservedAt.compareTo(left.triggerObservedAt);
    });
    return matches.first;
  }

  _RecentExternalRelaySosContext _mergeRecentExternalRelaySosContext({
    required _RecentExternalRelaySosContext? previous,
    required _RecentExternalRelaySosContext incoming,
  }) {
    if (previous == null) {
      return incoming;
    }
    final previousIncidentId = previous.backendIncidentId?.trim();
    final incomingIncidentId = incoming.backendIncidentId?.trim();
    final previousTriggerDeviceId = _normalizeNodeIdDeviceIdString(
      previous.triggerDeviceId,
    );
    final incomingTriggerDeviceId = _normalizeNodeIdDeviceIdString(
      incoming.triggerDeviceId,
    );
    return _RecentExternalRelaySosContext(
      originatorNodeId: incoming.originatorNodeId,
      relayNodeId: incoming.relayNodeId ?? previous.relayNodeId,
      relayHardwareId: incoming.relayHardwareId ?? previous.relayHardwareId,
      backendIncidentId: incomingIncidentId?.isNotEmpty == true
          ? incomingIncidentId
          : previousIncidentId?.isNotEmpty == true
          ? previousIncidentId
          : null,
      triggerDeviceId: incomingTriggerDeviceId?.isNotEmpty == true
          ? incomingTriggerDeviceId
          : previousTriggerDeviceId?.isNotEmpty == true
          ? previousTriggerDeviceId
          : null,
      triggerObservedAt:
          previous.triggerObservedAt.isBefore(incoming.triggerObservedAt)
          ? previous.triggerObservedAt
          : incoming.triggerObservedAt,
      baselineTerminal: previous.baselineTerminal ?? incoming.baselineTerminal,
      baselineTerminalSignature:
          previous.baselineTerminalSignature ??
          incoming.baselineTerminalSignature,
      baselineTerminalObservedAt:
          previous.baselineTerminalObservedAt ??
          incoming.baselineTerminalObservedAt,
      baselineEventSequence: previous.baselineEventSequence != 0
          ? previous.baselineEventSequence
          : incoming.baselineEventSequence,
      expiresAt: incoming.expiresAt.isAfter(previous.expiresAt)
          ? incoming.expiresAt
          : previous.expiresAt,
    );
  }

  void _removeRecentExternalRelayContextsFor({
    required int originatorNodeId,
    required int? relayNodeId,
  }) {
    _recentExternalRelaySosContexts.removeWhere((_, context) {
      if (context.originatorNodeId != originatorNodeId) {
        return false;
      }
      if (relayNodeId == null) {
        return true;
      }
      return context.relayNodeId == null || context.relayNodeId == relayNodeId;
    });
  }

  void _correlateRemoteRelayBackendIncident({
    required RemoteRelaySosSnapshot snapshot,
    required String? backendIncidentId,
    required String? relayHardwareId,
    String? acceptedTriggerDeviceId,
  }) {
    final normalizedIncidentId = backendIncidentId?.trim();
    if (normalizedIncidentId == null || normalizedIncidentId.isEmpty) {
      return;
    }
    _rememberRecentExternalRelaySosContext(
      snapshot: snapshot,
      relayHardwareId: relayHardwareId,
      backendIncidentId: normalizedIncidentId,
      triggerDeviceId: acceptedTriggerDeviceId,
    );
    final context = _recentExternalRelayContextForSnapshot(snapshot);
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS incident_correlated '
      'originatorNodeId=${_normalizeNodeId(snapshot.originatorNodeId)} '
      'relayNodeId=${_normalizeNodeIdOrNull(snapshot.relayNodeId)?.toString() ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"} '
      'backendIncidentId=$normalizedIncidentId '
      'acceptedTriggerDeviceId=${context?.triggerDeviceId ?? acceptedTriggerDeviceId ?? "none"}',
    );
    _flushPendingExternalRelayCancel(
      snapshot: snapshot,
      backendIncidentId: normalizedIncidentId,
      relayHardwareId: relayHardwareId,
    );
  }

  void _correlateRemoteRelayBackendIncidentFromContext({
    required _RecentExternalRelaySosContext context,
    required SosIncident incident,
  }) {
    final normalizedIncidentId = incident.id.trim();
    if (normalizedIncidentId.isEmpty) {
      return;
    }
    final snapshot = RemoteRelaySosSnapshot(
      kind: RemoteRelaySosKind.sos,
      originatorNodeId: context.originatorNodeId,
      relayNodeId: context.relayNodeId,
      source: RemoteRelaySosSource.sosNotify,
      sosType: 1,
      receivedAt: incident.createdAt,
      rawPayload: const <int>[],
      payloadHex: null,
    );
    _correlateRemoteRelayBackendIncident(
      snapshot: snapshot,
      backendIncidentId: normalizedIncidentId,
      relayHardwareId: context.relayHardwareId,
      acceptedTriggerDeviceId: context.triggerDeviceId,
    );
  }

  RemoteRelaySosSnapshot? _remoteRelayCancelSnapshotForRelayTerminalEvent({
    required EixamSosEventPacket packet,
    required DateTime receivedAt,
    required List<int> rawPayload,
    required String payloadHex,
  }) {
    if (packet.opcode != EixamBleProtocol.sosEventUserDeactivatedOpcode ||
        packet.subcode != 0x02) {
      return null;
    }
    final context = _recentExternalRelayContextForOriginatorNode(packet.nodeId);
    if (context == null) {
      return null;
    }
    BleDebugRegistry.instance.recordEvent(
      'REMOTE_RELAY_CANCEL_DETECT source=ble_sos_event_e1_02 '
      'classifiedAs=remoteRelay '
      'originatorNodeId=${context.originatorNodeId} '
      'relayNodeId=${context.relayNodeId?.toString() ?? "none"}',
    );
    return RemoteRelaySosSnapshot(
      kind: RemoteRelaySosKind.cancel,
      originatorNodeId: context.originatorNodeId,
      relayNodeId: context.relayNodeId,
      source: RemoteRelaySosSource.sosNotify,
      sosType: 0,
      receivedAt: receivedAt,
      rawPayload: List<int>.unmodifiable(rawPayload),
      payloadHex: payloadHex,
      eventOpcode: packet.opcode,
      eventSubcode: packet.subcode,
    );
  }

  _RecentExternalRelaySosContext? _recentExternalRelayContextForOriginatorNode(
    int nodeId,
  ) {
    return _bestRecentExternalRelayContext(
      originatorNodeId: _normalizeNodeId(nodeId),
      relayNodeId: null,
    );
  }

  _RecentExternalRelaySosContext? _recentExternalRelayContextForSnapshot(
    RemoteRelaySosSnapshot snapshot,
  ) {
    return _bestRecentExternalRelayContext(
      originatorNodeId: _normalizeNodeId(snapshot.originatorNodeId),
      relayNodeId: _normalizeNodeIdOrNull(snapshot.relayNodeId),
    );
  }

  _RecentExternalRelaySosContext? _recentExternalRelayContextForRelayNode(
    int relayNodeId,
  ) {
    final normalizedRelayNodeId = _normalizeNodeId(relayNodeId);
    final now = DateTime.now().toUtc();
    _recentExternalRelaySosContexts.removeWhere(
      (_, context) => now.isAfter(context.expiresAt),
    );
    final matches = _recentExternalRelaySosContexts.values
        .where(
          (context) =>
              context.relayNodeId == normalizedRelayNodeId &&
              context.originatorNodeId != normalizedRelayNodeId,
        )
        .toList(growable: false);
    if (matches.isEmpty) {
      return null;
    }
    matches.sort((left, right) {
      final leftCorrelated = left.backendIncidentId?.trim().isNotEmpty == true
          ? 0
          : 1;
      final rightCorrelated = right.backendIncidentId?.trim().isNotEmpty == true
          ? 0
          : 1;
      return leftCorrelated.compareTo(rightCorrelated);
    });
    return matches.first;
  }

  String? _remoteRelayTriggerDeviceIdForContext(
    _RecentExternalRelaySosContext? context,
  ) {
    final triggerDeviceId = _normalizeNodeIdDeviceIdString(
      context?.triggerDeviceId,
    );
    if (triggerDeviceId == null || triggerDeviceId.isEmpty) {
      return null;
    }
    final backendIncidentId = context?.backendIncidentId?.trim();
    if (backendIncidentId == null || backendIncidentId.isEmpty) {
      return null;
    }
    return triggerDeviceId;
  }

  String? _remoteRelayAcceptedTriggerDeviceIdForContext(
    _RecentExternalRelaySosContext? context,
  ) {
    final triggerDeviceId = _normalizeNodeIdDeviceIdString(
      context?.triggerDeviceId,
    );
    if (triggerDeviceId == null || triggerDeviceId.isEmpty) {
      return null;
    }
    return triggerDeviceId;
  }

  bool _isNumericNodeDeviceId(String deviceId) {
    final parsed = int.tryParse(deviceId.trim());
    return parsed != null;
  }

  bool _isKnownRegisteredBackendHardwareId(String deviceId) {
    final normalizedDeviceId = _normalizeNodeIdDeviceIdString(deviceId);
    return normalizedDeviceId != null &&
        _verifiedAssignedNodeIdsForSession.contains(normalizedDeviceId);
  }

  String? _normalizeNodeIdDeviceIdString(String? deviceId) {
    final trimmed = deviceId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null) {
      return trimmed;
    }
    return _normalizeNodeId(parsed).toString();
  }

  Future<_RemoteRelayCancelDeviceIdentity?> _resolveRemoteRelayCancelDeviceId({
    required RemoteRelaySosSnapshot snapshot,
    required _RecentExternalRelaySosContext? context,
  }) async {
    final hardwareId = (await _resolveOriginatorHardwareId(
      snapshot.originatorNodeId,
    ))?.trim();
    if (hardwareId != null && hardwareId.isNotEmpty) {
      if (_isNumericNodeDeviceId(hardwareId) &&
          !_isKnownRegisteredBackendHardwareId(hardwareId)) {
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS remote_cancel_numeric_device_id_rejected '
          'originatorNodeId=${_normalizeNodeId(snapshot.originatorNodeId)} '
          'relayNodeId=${_normalizeNodeIdOrNull(snapshot.relayNodeId)?.toString() ?? "none"} '
          'deviceId=$hardwareId reason=not_registered_backend_hardware_id',
        );
      } else {
        return _RemoteRelayCancelDeviceIdentity(
          deviceId: hardwareId,
          source: 'originator_hardware_id',
        );
      }
    }
    final acceptedTriggerDeviceId =
        _remoteRelayAcceptedTriggerDeviceIdForContext(context);
    if (acceptedTriggerDeviceId != null &&
        _isNumericNodeDeviceId(acceptedTriggerDeviceId) &&
        _isKnownRegisteredBackendHardwareId(acceptedTriggerDeviceId)) {
      return _RemoteRelayCancelDeviceIdentity(
        deviceId: acceptedTriggerDeviceId,
        source: 'registered_numeric_trigger_device_id',
      );
    }
    final triggerDeviceId = _remoteRelayTriggerDeviceIdForContext(context);
    if (triggerDeviceId != null && !_isNumericNodeDeviceId(triggerDeviceId)) {
      return _RemoteRelayCancelDeviceIdentity(
        deviceId: triggerDeviceId,
        source: 'correlated_trigger_device_id',
      );
    }
    if (_canUseBackendIncidentForRemoteRelayCancel(
      snapshot: snapshot,
      context: context,
    )) {
      return const _RemoteRelayCancelDeviceIdentity(
        deviceId: null,
        source: 'backend_incident_id',
      );
    }
    final originatorDeviceId = _remoteRelayOriginatorDeviceId(snapshot);
    if (acceptedTriggerDeviceId != null &&
        !_isNumericNodeDeviceId(acceptedTriggerDeviceId) &&
        acceptedTriggerDeviceId != originatorDeviceId &&
        _canUseTrustedRemoteRelayContextForCancel(
          snapshot: snapshot,
          context: context,
        )) {
      return _RemoteRelayCancelDeviceIdentity(
        deviceId: acceptedTriggerDeviceId,
        source: 'accepted_trigger_device_id',
      );
    }
    if (_canUseGatewayScopeRemoteRelayCancelFallback(
      snapshot: snapshot,
      context: context,
    )) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS remote_cancel_gateway_scope_fallback '
        'originatorNodeId=${_normalizeNodeId(snapshot.originatorNodeId)} '
        'relayNodeId=${_normalizeNodeIdOrNull(snapshot.relayNodeId)?.toString() ?? "none"} '
        'reason=unknown_discovered_remote_device localSosInactive=true',
      );
      return const _RemoteRelayCancelDeviceIdentity(
        deviceId: null,
        source: 'gateway_scope_fallback',
      );
    }
    return null;
  }

  bool _canUseBackendIncidentForRemoteRelayCancel({
    required RemoteRelaySosSnapshot snapshot,
    required _RecentExternalRelaySosContext? context,
  }) {
    if (!_remoteRelayCancelMatchesContext(
      snapshot: snapshot,
      context: context,
    )) {
      return false;
    }
    final backendIncidentId = context?.backendIncidentId?.trim();
    return backendIncidentId != null && backendIncidentId.isNotEmpty;
  }

  bool _canUseTrustedRemoteRelayContextForCancel({
    required RemoteRelaySosSnapshot snapshot,
    required _RecentExternalRelaySosContext? context,
  }) {
    if (!_remoteRelayCancelMatchesContext(
      snapshot: snapshot,
      context: context,
    )) {
      return false;
    }
    final acceptedTriggerDeviceId =
        _remoteRelayAcceptedTriggerDeviceIdForContext(context);
    if (acceptedTriggerDeviceId != null) {
      return true;
    }
    final backendIncidentId = context?.backendIncidentId?.trim();
    return backendIncidentId != null && backendIncidentId.isNotEmpty;
  }

  bool _canUseGatewayScopeRemoteRelayCancelFallback({
    required RemoteRelaySosSnapshot snapshot,
    required _RecentExternalRelaySosContext? context,
  }) {
    if (!_remoteRelayCancelMatchesContext(
      snapshot: snapshot,
      context: context,
    )) {
      return false;
    }
    final backendIncidentId = context?.backendIncidentId?.trim();
    if (backendIncidentId != null && backendIncidentId.isNotEmpty) {
      return false;
    }
    final acceptedTriggerDeviceId =
        _remoteRelayAcceptedTriggerDeviceIdForContext(context);
    final originatorDeviceId = _remoteRelayOriginatorDeviceId(snapshot);
    if (acceptedTriggerDeviceId == null ||
        acceptedTriggerDeviceId != originatorDeviceId ||
        !_isNumericNodeDeviceId(acceptedTriggerDeviceId)) {
      return false;
    }
    if (_hasLocalSosActiveForRemoteRelayGatewayScopeFallback(context)) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS remote_cancel_gateway_scope_blocked_local_sos_active '
        'originatorNodeId=${_normalizeNodeId(snapshot.originatorNodeId)} '
        'relayNodeId=${_normalizeNodeIdOrNull(snapshot.relayNodeId)?.toString() ?? "none"} '
        'reason=local_sos_active localSosInactive=false',
      );
      return false;
    }
    return true;
  }

  bool _hasLocalSosActiveForRemoteRelayGatewayScopeFallback(
    _RecentExternalRelaySosContext? context,
  ) {
    if (_publicSosActionInFlight || _publicSosClosureInFlight != null) {
      return true;
    }
    if (_isOpenSosState(_publicSosState)) {
      return true;
    }
    final candidates = <SosIncident?>[
      _lastKnownActiveSosIncident,
      _publicSosFallbackIncident,
    ];
    for (final incident in candidates) {
      if (incident == null || !_isOpenSosState(incident.state)) {
        continue;
      }
      if (_hasPositiveLocalSosOriginProof(incident)) {
        return true;
      }
      final incidentContext = _recentExternalRelaySosContextForIncident(
        incident,
      );
      if (context == null ||
          incidentContext == null ||
          incidentContext.originatorNodeId != context.originatorNodeId ||
          incidentContext.relayNodeId != context.relayNodeId) {
        return true;
      }
    }
    return false;
  }

  bool _remoteRelayCancelMatchesContext({
    required RemoteRelaySosSnapshot snapshot,
    required _RecentExternalRelaySosContext? context,
  }) {
    if (context == null) {
      return false;
    }
    if (!_isRemoteRelayCancelSnapshot(snapshot)) {
      return false;
    }
    if (context.originatorNodeId !=
        _normalizeNodeId(snapshot.originatorNodeId)) {
      return false;
    }
    final snapshotRelayNodeId = _normalizeNodeIdOrNull(snapshot.relayNodeId);
    if (snapshotRelayNodeId != null &&
        context.relayNodeId != null &&
        context.relayNodeId != snapshotRelayNodeId) {
      return false;
    }
    return true;
  }

  String _remoteRelaySosCancelHandoffSignature({
    required RemoteRelaySosSnapshot snapshot,
    required String? backendIncidentId,
    required String? relayHardwareId,
  }) {
    return <String>[
      'remote_lora_relay_cancel',
      _normalizeNodeId(snapshot.originatorNodeId).toString(),
      _normalizeNodeIdOrNull(snapshot.relayNodeId)?.toString() ?? 'none',
      relayHardwareId?.trim() ?? 'none',
      backendIncidentId?.trim() ?? 'active',
    ].join(':');
  }

  String _externalRelayCancelContextKey(RemoteRelaySosSnapshot snapshot) {
    final originatorNodeId = _normalizeNodeId(snapshot.originatorNodeId);
    final relayNodeId = _normalizeNodeIdOrNull(snapshot.relayNodeId);
    return 'remote_lora_relay_cancel:$originatorNodeId:'
        '${relayNodeId?.toString() ?? "none"}';
  }

  String _externalRelayRearmKey({
    required int originatorNodeId,
    required int? relayNodeId,
  }) {
    return '${_normalizeNodeId(originatorNodeId)}:'
        '${_normalizeNodeIdOrNull(relayNodeId)?.toString() ?? "none"}';
  }

  void _rearmExternalRelayAfterCancelSuccess({
    required RemoteRelaySosSnapshot snapshot,
    required String? backendIncidentId,
  }) {
    final originatorNodeId = _normalizeNodeId(snapshot.originatorNodeId);
    final relayNodeId = _normalizeNodeIdOrNull(snapshot.relayNodeId);
    final normalizedIncidentId = backendIncidentId?.trim();
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS external_cancel_success_rearm_start '
      'originatorNodeId=$originatorNodeId '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'backendIncidentId=${normalizedIncidentId?.isNotEmpty == true ? normalizedIncidentId : "none"}',
    );

    _remoteRelaySosBackendHandoffBySignature.removeWhere((signature, _) {
      final parts = signature.split(':');
      if (parts.length < 4) {
        return false;
      }
      return parts[0] == originatorNodeId.toString() &&
          parts[2] == (relayNodeId?.toString() ?? 'none');
    });
    _remoteRelaySosBackendHandoffInFlightBySignature.removeWhere((
      signature,
      _,
    ) {
      final parts = signature.split(':');
      if (parts.length < 4) {
        return false;
      }
      return parts[0] == originatorNodeId.toString() &&
          parts[2] == (relayNodeId?.toString() ?? 'none');
    });
    _pendingExternalRelayCancels.removeWhere((_, pending) {
      if (_normalizeNodeId(pending.snapshot.originatorNodeId) !=
          originatorNodeId) {
        return false;
      }
      final pendingRelayNodeId = _normalizeNodeIdOrNull(
        pending.snapshot.relayNodeId,
      );
      if (relayNodeId != null &&
          pendingRelayNodeId != null &&
          pendingRelayNodeId != relayNodeId) {
        return false;
      }
      return true;
    });

    var closedContext = false;
    _recentExternalRelaySosContexts.removeWhere((_, context) {
      if (context.originatorNodeId != originatorNodeId) {
        return false;
      }
      if (relayNodeId != null &&
          context.relayNodeId != null &&
          context.relayNodeId != relayNodeId) {
        return false;
      }
      final contextIncidentId = context.backendIncidentId?.trim();
      if (normalizedIncidentId != null &&
          normalizedIncidentId.isNotEmpty &&
          contextIncidentId != normalizedIncidentId) {
        return false;
      }
      closedContext = true;
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS external_context_closed reason=cancel_success '
        'originatorNodeId=$originatorNodeId '
        'relayNodeId=${context.relayNodeId?.toString() ?? "none"} '
        'backendIncidentId=${contextIncidentId?.isNotEmpty == true ? contextIncidentId : "none"}',
      );
      return true;
    });
    if (!closedContext) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS external_context_closed reason=cancel_success '
        'originatorNodeId=$originatorNodeId '
        'relayNodeId=${relayNodeId?.toString() ?? "none"} '
        'backendIncidentId=${normalizedIncidentId?.isNotEmpty == true ? normalizedIncidentId : "none"} '
        'contextFound=false',
      );
    }
    _externalRelayRearmedAtByKey[_externalRelayRearmKey(
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
    )] = DateTime.now()
        .toUtc();
    unawaited(_persistRecentExternalRelaySosContexts());
  }

  void _storePendingExternalRelayCancel({
    required RemoteRelaySosSnapshot snapshot,
    required String? relayHardwareId,
    String? nativePendingSignature,
  }) {
    snapshot = _normalizeRemoteRelaySosSnapshot(snapshot);
    final key = _externalRelayCancelContextKey(snapshot);
    final now = DateTime.now().toUtc();
    _pendingExternalRelayCancels[key] = _PendingExternalRelayCancel(
      snapshot: snapshot,
      relayHardwareId: relayHardwareId,
      nativePendingSignature: nativePendingSignature,
      expiresAt: now.add(const Duration(minutes: 10)),
    );
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS pending_cancel_stored '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"} '
      'backendIncidentId=none',
    );
  }

  void _flushPendingExternalRelayCancel({
    required RemoteRelaySosSnapshot snapshot,
    required String backendIncidentId,
    required String? relayHardwareId,
  }) {
    snapshot = _normalizeRemoteRelaySosSnapshot(snapshot);
    final now = DateTime.now().toUtc();
    _pendingExternalRelayCancels.removeWhere(
      (_, pending) => now.isAfter(pending.expiresAt),
    );
    final key = _externalRelayCancelContextKey(snapshot);
    var pending = _pendingExternalRelayCancels.remove(key);
    if (pending == null) {
      final originatorNodeId = _normalizeNodeId(snapshot.originatorNodeId);
      final relayNodeId = _normalizeNodeIdOrNull(snapshot.relayNodeId);
      String? matchedKey;
      for (final entry in _pendingExternalRelayCancels.entries) {
        final pendingOriginatorNodeId = _normalizeNodeId(
          entry.value.snapshot.originatorNodeId,
        );
        final pendingRelayNodeId = _normalizeNodeIdOrNull(
          entry.value.snapshot.relayNodeId,
        );
        if (pendingOriginatorNodeId != originatorNodeId) {
          continue;
        }
        if (relayNodeId != null &&
            pendingRelayNodeId != null &&
            pendingRelayNodeId != relayNodeId) {
          continue;
        }
        matchedKey = entry.key;
        pending = entry.value;
        break;
      }
      if (matchedKey != null) {
        _pendingExternalRelayCancels.remove(matchedKey);
      }
    }
    if (pending == null) {
      return;
    }
    final flushSnapshot = RemoteRelaySosSnapshot(
      kind: RemoteRelaySosKind.cancel,
      originatorNodeId: _normalizeNodeId(pending.snapshot.originatorNodeId),
      relayNodeId: _normalizeNodeIdOrNull(pending.snapshot.relayNodeId),
      source: pending.snapshot.source,
      sosType: pending.snapshot.sosType,
      location: pending.snapshot.location,
      receivedAt: pending.snapshot.receivedAt,
      rawPayload: pending.snapshot.rawPayload,
      payloadHex: pending.snapshot.payloadHex,
      eventOpcode: pending.snapshot.eventOpcode,
      eventSubcode: pending.snapshot.eventSubcode,
      relayCount: pending.snapshot.relayCount,
    );
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS pending_cancel_flushed '
      'originatorNodeId=${flushSnapshot.originatorNodeId} '
      'relayNodeId=${flushSnapshot.relayNodeId?.toString() ?? "none"} '
      'relayHardwareId=${pending.relayHardwareId ?? relayHardwareId ?? "none"} '
      'backendIncidentId=$backendIncidentId',
    );
    unawaited(
      _handleRemoteRelaySosCancelBackendHandoff(
        flushSnapshot,
        nativePendingSignature: pending.nativePendingSignature,
        relayHardwareIdOverride: pending.relayHardwareId ?? relayHardwareId,
      ),
    );
  }

  Future<void> _flushPendingExternalRelayCancelsForOriginator({
    required int originatorNodeId,
    required String trigger,
  }) async {
    final normalizedOriginatorNodeId = _normalizeNodeId(originatorNodeId);
    final now = DateTime.now().toUtc();
    _pendingExternalRelayCancels.removeWhere(
      (_, pending) => now.isAfter(pending.expiresAt),
    );
    final matches = _pendingExternalRelayCancels.entries
        .where(
          (entry) =>
              _normalizeNodeId(entry.value.snapshot.originatorNodeId) ==
              normalizedOriginatorNodeId,
        )
        .map((entry) => entry.value)
        .toList(growable: false);
    if (matches.isEmpty) {
      return;
    }
    _pendingExternalRelayCancels.removeWhere(
      (_, pending) =>
          _normalizeNodeId(pending.snapshot.originatorNodeId) ==
          normalizedOriginatorNodeId,
    );
    for (final pending in matches) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS pending_cancel_flushed '
        'originatorNodeId=${pending.snapshot.originatorNodeId} '
        'relayNodeId=${pending.snapshot.relayNodeId?.toString() ?? "none"} '
        'relayHardwareId=${pending.relayHardwareId ?? "none"} '
        'trigger=$trigger',
      );
      await _handleRemoteRelaySosCancelBackendHandoff(
        pending.snapshot,
        nativePendingSignature: pending.nativePendingSignature,
        relayHardwareIdOverride: pending.relayHardwareId,
      );
    }
  }

  Future<void> _flushPendingExternalRelayCancelsFromProtectionPlatform({
    required String trigger,
  }) async {
    final pending = await protectionPlatformAdapter
        .peekPendingExternalRelayCancels();
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS pending_cancel_peeked count=${pending.length} '
      'trigger=$trigger',
    );
    if (pending.isEmpty) {
      return;
    }
    for (final event in pending) {
      final payloadHex = event.payloadHex?.trim();
      final rawPayload = payloadHex == null || payloadHex.isEmpty
          ? const <int>[]
          : _tryDecodeHexPayload(payloadHex) ?? const <int>[];
      final snapshot = RemoteRelaySosSnapshot(
        kind: RemoteRelaySosKind.cancel,
        originatorNodeId: _normalizeNodeId(event.originatorNodeId),
        relayNodeId: _normalizeNodeIdOrNull(event.relayNodeId),
        source: RemoteRelaySosSource.sosNotify,
        sosType: 0,
        receivedAt: event.timestamp,
        rawPayload: List<int>.unmodifiable(rawPayload),
        payloadHex: payloadHex,
        eventOpcode: EixamBleProtocol.sosEventUserDeactivatedOpcode,
        eventSubcode: 0x02,
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS pending_cancel_flushed '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
        'relayHardwareId=${event.relayHardwareId ?? "none"} '
        'trigger=$trigger',
      );
      await _handleRemoteRelaySosCancelBackendHandoff(
        snapshot,
        nativePendingSignature: event.signature,
        relayHardwareIdOverride: event.relayHardwareId,
      );
    }
  }

  Future<void> _ackPendingExternalRelayCancelFromProtectionPlatform(
    String? signature,
  ) async {
    final normalizedSignature = signature?.trim();
    if (normalizedSignature == null || normalizedSignature.isEmpty) {
      return;
    }
    try {
      final acknowledged = await protectionPlatformAdapter
          .ackPendingExternalRelayCancel(normalizedSignature);
      if (acknowledged) {
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS pending_cancel_ack signature=$normalizedSignature',
        );
      } else {
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS pending_cancel_ack_missing '
          'signature=$normalizedSignature',
        );
      }
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS pending_cancel_ack_failed '
        'signature=$normalizedSignature error=$error',
      );
    }
  }

  void _logRemoteRelayCancelDetection({
    required String source,
    required String rawType,
    required int? nodeId,
    required int? originatorNodeId,
    required int? relayNodeId,
    required String? relayHardwareId,
    required String classifiedAs,
    required String action,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'REMOTE_RELAY_CANCEL_DETECT source=$source rawType=$rawType '
      'nodeId=${nodeId?.toString() ?? "none"} '
      'originatorNodeId=${originatorNodeId?.toString() ?? "none"} '
      'relayNodeId=${relayNodeId?.toString() ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"} '
      'classifiedAs=$classifiedAs action=$action',
    );
  }

  String _remoteRelaySosContextKey({
    required int originatorNodeId,
    required int? relayNodeId,
    required String? relayHardwareId,
  }) {
    final normalizedOriginatorNodeId = _normalizeNodeId(originatorNodeId);
    final normalizedRelayNodeId = _normalizeNodeIdOrNull(relayNodeId);
    return 'remote_lora_relay:$normalizedOriginatorNodeId:'
        '${normalizedRelayNodeId?.toString() ?? "none"}:'
        '${relayHardwareId?.trim() ?? "none"}';
  }

  void _logSosOriginDecision({
    required String source,
    required SosOriginDecision decision,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'SOS_ORIGIN_DECISION source=$source '
      'actionability=${decision.actionability.name} '
      'localStateMutation=${decision.localStateMutation} '
      'publicIncident=${decision.publicIncident} '
      'backendPublish=${decision.backendPublish} '
      'reason=${decision.reason}',
    );
  }

  void _clearExternalOnlyPublicSosResidue({required String reason}) {
    _publicSosFallbackIncident = null;
    _lastKnownActiveSosIncident = null;
    _lastPublicSosIncidentId = null;
    _lastPublicSosTerminalReason = null;
    _clearPendingAppTriggeredSosBridge(reason: reason);
    _clearDeviceRuntimeSosOwnership(reason: reason);
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
        message: 'E_SOS_DEVICE_BACKEND_SYNC_RUNTIME_ACTIVE',
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
    final iosSnapshotState = await _mergeIosBleSosSnapshot(
      trigger: 'getSosState',
    );
    if (iosSnapshotState == SosState.idle ||
        iosSnapshotState == SosState.arming ||
        iosSnapshotState == SosState.sent) {
      return _publicSosState;
    }
    final deviceSosStatus = await deviceSosController.getStatus();
    final deviceOverride = await _rehydrateDeviceSosPublicState(
      trigger: 'getSosState',
      deviceStatus: deviceSosStatus,
      emitResolvedState: false,
    );
    if (deviceOverride != null) {
      final effectiveState = _applyPublicSosRuntimePrecedence(
        incoming: deviceOverride,
        source: 'fetch_sos_state:device_override',
      );
      _applyPublicSosState(
        effectiveState,
        source: 'fetch_sos_state:device_override',
        emit: false,
      );
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> deviceOverride=${deviceOverride.name} '
        'effectiveState=${_publicSosState.name}',
      );
      return _publicSosState;
    }
    if (_publicSosFallbackIncident != null) {
      if (_clearStaleCancelledRuntimeFallbackDuringAppArming(
        source: 'fetch_sos_state:fallback',
      )) {
        return _publicSosState;
      }
      if (_isExternalOnlySosIncident(
        _publicSosFallbackIncident,
        source: 'fetch_sos_state:fallback',
      )) {
        _clearExternalOnlyPublicSosResidue(
          reason: 'fetch_sos_state_external_fallback',
        );
        _emitPublicSosState(
          SosState.idle,
          source: 'fetch_sos_state:external_fallback',
        );
        return _publicSosState;
      }
      BleDebugRegistry.instance.recordEvent(
        'getSosState() -> fallbackState=${_publicSosState.name}',
      );
      return _publicSosState;
    }
    final repositoryState = await sosRepository.getSosState();
    SosIncident? repositoryIncident;
    if (repositoryState != SosState.idle) {
      repositoryIncident = await sosRepository.getCurrentIncident();
      if (_isExternalOnlySosIncident(
        repositoryIncident,
        source: 'fetch_sos_state',
      )) {
        _clearExternalOnlyPublicSosResidue(
          reason: 'fetch_sos_state_external_only',
        );
        _emitPublicSosState(SosState.idle, source: 'fetch_sos_state');
        BleDebugRegistry.instance.recordEvent(
          'getSosState() -> repositoryState=${repositoryState.name} '
          'effectiveState=idle reason=external_only',
        );
        return _publicSosState;
      }
    }
    if (_isTerminalPublicSosState(repositoryState) &&
        _hasNewAuthoritativeGenerationSinceTerminal() &&
        (repositoryIncident == null ||
            !sosIncidentEvidenceMatchesLifecycle(
              _sosLifecycle.current,
              repositoryIncident,
            ))) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_STALE_TERMINAL_IGNORED_FOR_NEW_GENERATION '
        'terminalGeneration=${_sosLifecycle.activeTerminalWatermark?.generation ?? 0} '
        'activeGeneration=${_sosLifecycle.current.generation} '
        'source=getSosState reason=identity_mismatch',
      );
      _recordPublicSosGenerationProjection(
        action: 'ignore_stale_terminal',
        reason: 'getSosState_identity_mismatch',
      );
      return _publicSosState;
    }
    final runtimePrecedenceState = _applyPublicSosRuntimePrecedence(
      incoming: repositoryState,
      source: 'fetch_sos_state',
    );
    if (runtimePrecedenceState != repositoryState) {
      _applyPublicSosState(
        runtimePrecedenceState,
        source: 'fetch_sos_state',
        emit: false,
      );
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
      _applyPublicSosState(
        SosState.idle,
        source: 'fetch_sos_state:terminal_acknowledged',
        emit: false,
      );
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
    final effectiveState = _preserveDeviceRuntimeSosStateIfNeeded(
      incoming: repositoryState,
      source: 'fetch_sos_state',
    );
    _applyPublicSosState(
      effectiveState,
      source: 'fetch_sos_state',
      emit: false,
    );
    BleDebugRegistry.instance.recordEvent(
      'getSosState() -> repositoryState=${repositoryState.name} '
      'effectiveState=${_publicSosState.name}',
    );
    return _publicSosState;
  }

  @override
  Future<SosHistoryPage> listSosHistory({
    String? cursor,
    int limit = 20,
  }) async {
    return sosRepository.listSosHistory(cursor: cursor, limit: limit);
  }

  @override
  Stream<SosState> get currentSosStateStream {
    return _seedThenReplayLiveStream<SosState>(
      seed: () => _publicSosState,
      live: _publicSosStateController.stream,
    );
  }

  @override
  Stream<EixamSdkEvent> get lastSosEventStream {
    return _seedThenReplayLiveStream<EixamSdkEvent>(
      seed: () => _lastSosEvent,
      live: _eventsController.stream.where(_isSosSdkEvent),
      emitNullSeed: false,
    );
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
  }) async {
    final registered = await deviceRegistryRepository.upsertRegisteredDevice(
      hardwareId: hardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
    );
    final nodeId = int.tryParse(hardwareId.trim(), radix: 10);
    if (nodeId != null &&
        registeredHardwareIdMatchesNodeId(registered.hardwareId, nodeId)) {
      _rememberVerifiedDeviceAssignment(nodeId);
    }
    return registered;
  }

  @override
  Future<void> registerDeviceIdentityMapping({
    required String hardwareId,
    required int nodeId,
    String? source,
  }) async {
    final normalizedHardwareId = hardwareId.trim();
    if (normalizedHardwareId.isEmpty) {
      return;
    }
    await _rememberDeviceIdentityMapping(
      nodeId: nodeId,
      hardwareId: normalizedHardwareId,
      source: source ?? 'public_api',
      persist: true,
    );
    unawaited(
      _flushPendingExternalRelayCancelsForOriginator(
        originatorNodeId: nodeId,
        trigger: 'identity_mapping_registered',
      ),
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
  List<EmergencyContact> peekEmergencyContacts() {
    return contactsRepository.peekEmergencyContacts();
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
    await _transitionDeathManPlanTo(plan, DeathManStatus.monitoring);
    _startDeathManMonitoring(plan.id);
    return (await deathManRepository.getActiveDeathManPlan())!;
  }

  @override
  Future<DeathManPlan?> getActiveDeathManPlan() {
    return deathManRepository.getActiveDeathManPlan();
  }

  @override
  Future<void> confirmDeathManCheckIn(String planId) async {
    final plan = await deathManRepository.getActiveDeathManPlan();
    if (plan == null || plan.id != planId) {
      return;
    }
    if (!_canTransitionDeathManPlanTo(plan, DeathManStatus.confirmedSafe)) {
      return;
    }
    await deathManRepository.confirmDeathManCheckIn(planId);
    _publishSdkEvent(
      DeathManStatusChangedEvent(planId, DeathManStatus.confirmedSafe.name),
    );
    _stopDeathManMonitoring();
  }

  @override
  Future<void> cancelDeathMan(String planId) async {
    final plan = await deathManRepository.getActiveDeathManPlan();
    if (plan == null || plan.id != planId) {
      return;
    }
    if (!_canTransitionDeathManPlanTo(plan, DeathManStatus.cancelled)) {
      return;
    }
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
  Stream<SdkOperationalDiagnostics> watchOperationalDiagnostics() {
    return _seedThenReplayLiveStream<SdkOperationalDiagnostics>(
      seed: () {
        BleDebugRegistry.instance.recordEvent(
          'watchOperationalDiagnostics.initial -> passive diagnostics snapshot requested; live refresh skipped',
        );
        return _refreshOperationalDiagnostics(
          trigger: 'watchOperationalDiagnostics.initial',
          refreshRuntimeStatus: false,
          emit: false,
        );
      },
      live: _operationalDiagnosticsController.stream,
    );
  }

  @override
  Future<SdkResolvedLocation?> getResolvedLocationForEmergencyContext() {
    return _resolveLocation(
      useCase: SdkResolvedLocationUseCase.emergencyBackend,
    );
  }

  @override
  Stream<SdkResolvedLocation?> watchResolvedLocation() {
    return _seedThenReplayLiveStream<SdkResolvedLocation?>(
      seed: getResolvedLocationForEmergencyContext,
      live: _resolvedLocationController.stream,
    );
  }

  @override
  Stream<EixamDevicePositionBatch> watchDevicePositionBatches() {
    return _devicePositionBatchController.stream;
  }

  @override
  Future<DevicePositionBacklogSyncResult> syncDevicePositionBacklog({
    required DateTime since,
    DateTime? until,
    Duration timeout = const Duration(seconds: 5),
  }) {
    return _devicePositionBacklogCoordinator.sync(
      since: since,
      until: until,
      timeout: timeout,
    );
  }

  Future<void> _writePositionBacklogCommand(EixamDeviceCommand command) async {
    if (_isProtectionPlatformOwningBle ||
        _firmwareOtaInProgress ||
        (_deviceProvisioningCoordinator?.isBusy ?? false)) {
      throw const DeviceException(
        'E_DEVICE_BACKLOG_SYNC_OWNER_UNAVAILABLE',
        'E_DEVICE_BACKLOG_SYNC_OWNER_UNAVAILABLE',
      );
    }
    await _ensureCommandCapableDeviceRepository(action: 'position_backlog');
    await _sendDeviceCommandThroughActiveOwner(command);
  }

  @override
  Future<SdkTelemetryPayload?> getResolvedTelemetryPreview({
    bool includeCachedFallback = true,
  }) async {
    final location = await _resolveLocation(
      useCase: includeCachedFallback
          ? SdkResolvedLocationUseCase.uiPreview
          : SdkResolvedLocationUseCase.telemetryBackend,
    );
    if (location == null) {
      return null;
    }
    final payload = _telemetryPayloadFromResolvedLocation(location);
    LocationDebugLog.telemetryPayload(
      flow: 'telemetry_publish_candidate',
      payload: payload,
      accepted: location.authoritativeForBackend,
      source: location.source.name,
      rejectionReason: location.authoritativeForBackend
          ? null
          : 'preview_display_only',
      authoritativeForBackend: location.authoritativeForBackend,
      sentToBackend: false,
      note: 'getResolvedTelemetryPreview',
    );
    return payload;
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
    return _seedThenReplayLiveStream<RealtimeConnectionState>(
      seed: () => _lastRealtimeConnectionState,
      live: _realtimeConnectionStateController.stream,
    );
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

  void _emitDeathManNotificationIntent(
    EixamNotificationIntentType type, {
    String? planId,
    bool includeConfirmAction = false,
  }) {
    final createdAt = DateTime.now().toUtc();
    _emitNotificationIntent(
      _buildNotificationIntent(
        type: type,
        dedupeKey:
            'death_man:${type.name}:${planId ?? createdAt.microsecondsSinceEpoch}',
        severity: type == EixamNotificationIntentType.deathManEscalated
            ? EixamNotificationIntentSeverity.critical
            : EixamNotificationIntentSeverity.warning,
        titleKey: 'notification.${type.name}.title',
        bodyKey: 'notification.${type.name}.body',
        payload: <String, String>{
          if (planId != null) 'planId': planId,
          'includeConfirmAction': includeConfirmAction.toString(),
        },
      ),
    );
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
    final previous = _lastDeviceStatus;
    _lastDeviceStatus = status;
    if (status.nodeId != null) {
      _knownLocalDeviceNodeId = status.nodeId;
    }
    final publicStatus = _publishPublicDeviceStatus(
      rawStatus: status,
      reason: reason,
      emit: emitPublicStatus,
    );
    _scheduleConnectedDeviceAssignmentClaim(
      status: publicStatus,
      previous: previous,
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
    if (previous == null || previous.connected != publicStatus.connected) {
      _recordDeviceConnectionProjection(
        rawStatus: rawStatus,
        publicStatus: publicStatus,
        previousVisibleConnected: previous?.connected ?? false,
        source: reason,
      );
    }
    return publicStatus;
  }

  DeviceStatus _toPublicDeviceStatus(
    DeviceStatus rawStatus, {
    required String reason,
  }) {
    final protectionStatus = _protectionModeController.currentStatus;
    final nativeOwnerDeclared = _protectionNativeOwnerDeclared(
      protectionStatus,
    );
    final nativeCommandReady = _nativeCommandReadinessForStatus(
      protectionStatus,
    ).ready;
    final sameDeviceIdentity = _nativeProtectionTargetMatchesDeviceStatus(
      baseStatus: rawStatus,
      protectionStatus: protectionStatus,
    );
    final previousConnectionOwner = _lastProjectedDeviceConnectionOwner;
    final currentConnectionOwner = _deviceConnectionOwner(protectionStatus);
    final nativeConnectionContinuityProven =
        _refreshCanonicalNativeConnectionProof(
          rawStatus: rawStatus,
          protectionStatus: protectionStatus,
          nativeCommandReady: nativeCommandReady,
          sameDeviceIdentity: sameDeviceIdentity,
        );
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: rawStatus.connected,
      nativeOwnerDeclared: nativeOwnerDeclared,
      nativeOwnerReady: nativeOwnerDeclared && nativeCommandReady,
      nativeGattConnected: protectionStatus.serviceBleConnected,
      sameDeviceIdentity: sameDeviceIdentity,
      nativeConnectionContinuityProven: nativeConnectionContinuityProven,
    );
    if (projection.reason ==
            DeviceConnectionProjectionReason.sameNativeSessionContinuity &&
        previousConnectionOwner == 'nativeReady' &&
        currentConnectionOwner == 'nativePreparing') {
      _recordDeviceConnectionTransitionPreserved(
        previousOwner: previousConnectionOwner!,
        nextOwner: currentConnectionOwner,
        protectionStatus: protectionStatus,
        reason: reason,
      );
    } else if (currentConnectionOwner == 'nativeReady') {
      _lastConnectionTransitionPreservedSignature = null;
    }
    _lastProjectedDeviceConnectionOwner = currentConnectionOwner;
    if (!projection.falseDisconnectBlocked &&
        !rawStatus.connected &&
        _protectionReportsLiveBleConnection(protectionStatus) &&
        sameDeviceIdentity &&
        protectionStatus.bleOwner == ProtectionBleOwner.flutter) {
      BleDebugRegistry.instance.recordEvent(
        '[DEVICE_FLOW] protection_connection_bridge_skipped '
        'reason=flutter_ble_owner',
      );
    }
    final publicStatus = projection.visibleConnected && !rawStatus.connected
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
    if (projection.falseDisconnectBlocked) {
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
      _recordFalseDeviceDisconnectBlocked(
        rawStatus: rawStatus,
        protectionStatus: protectionStatus,
        source: reason,
        projectionReason: projection.reason.name,
        sameDeviceIdentity: sameDeviceIdentity,
      );
    }
    return publicStatus;
  }

  bool _protectionNativeOwnerDeclared(ProtectionStatus status) {
    return status.modeState != ProtectionModeState.off &&
        status.bleOwner != ProtectionBleOwner.flutter;
  }

  bool _nativeProtectionTargetMatchesDeviceStatus({
    required DeviceStatus baseStatus,
    required ProtectionStatus protectionStatus,
  }) {
    final expectedTargets =
        <String?>[baseStatus.deviceId, baseStatus.canonicalHardwareId]
            .whereType<String>()
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet();
    final nativeTargets =
        <String?>[
              protectionStatus.activeDeviceId,
              protectionStatus.protectedDeviceId,
            ]
            .whereType<String>()
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet();
    return expectedTargets.isNotEmpty &&
        nativeTargets.isNotEmpty &&
        expectedTargets.any(
          (expected) => nativeTargets.any(
            (actual) =>
                expected.toLowerCase() == actual.toLowerCase() ||
                _samePhysicalHardwareId(expected, actual),
          ),
        );
  }

  String _deviceConnectionOwner(ProtectionStatus status) {
    if (_protectionNativeOwnerDeclared(status)) {
      return _nativeCommandReadinessForStatus(status).ready
          ? 'nativeReady'
          : 'nativePreparing';
    }
    return _lastDeviceStatus?.connected == true ? 'flutter' : 'none';
  }

  bool _protectionRuntimeRunning(ProtectionStatus status) {
    return status.protectionRuntimeActive ||
        status.foregroundServiceRunning ||
        status.runtimeState == ProtectionRuntimeState.starting ||
        status.runtimeState == ProtectionRuntimeState.active ||
        status.runtimeState == ProtectionRuntimeState.recovering;
  }

  String _nativeConnectedIdentity(ProtectionStatus status) {
    return SecurityDiagnosticsRedactor.stableIdentifierMarker(
      status.activeDeviceId ??
          status.protectedDeviceId ??
          _lastNativeRawConnectedDeviceMarker,
    );
  }

  bool _refreshCanonicalNativeConnectionProof({
    required DeviceStatus rawStatus,
    required ProtectionStatus protectionStatus,
    required bool nativeCommandReady,
    required bool sameDeviceIdentity,
  }) {
    final existing = _canonicalNativeConnectionProof;
    if (existing != null &&
        !_canonicalNativeConnectionProofIsValid(
          rawStatus: rawStatus,
          protectionStatus: protectionStatus,
        )) {
      _clearCanonicalNativeConnectionProof(
        reason: _canonicalNativeConnectionProofInvalidationReason(
          rawStatus: rawStatus,
          protectionStatus: protectionStatus,
          proof: existing,
        ),
      );
    }

    if (_canonicalNativeConnectionProof == null &&
        _protectionNativeOwnerDeclared(protectionStatus) &&
        nativeCommandReady &&
        protectionStatus.serviceBleConnected &&
        sameDeviceIdentity &&
        _protectionRuntimeRunning(protectionStatus)) {
      final identity = _matchingNativeConnectionIdentity(
        rawStatus: rawStatus,
        protectionStatus: protectionStatus,
      );
      if (identity != null) {
        _canonicalNativeConnectionProofSequence += 1;
        _canonicalNativeConnectionProof = _CanonicalNativeConnectionProof(
          physicalIdentity: identity,
          nativeOwner: protectionStatus.bleOwner,
          establishedAt: _clock().toUtc(),
          sequence: _canonicalNativeConnectionProofSequence,
        );
        _lastConnectionTransitionPreservedSignature = null;
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_CONNECTION_CONTINUITY_ESTABLISHED '
          'owner=nativeReady retainedIdentityPresent=true '
          'nativeGattConnected=${protectionStatus.serviceBleConnected} '
          'nativeCommandReady=$nativeCommandReady '
          'runtimeRunning=${_protectionRuntimeRunning(protectionStatus)} '
          'proofSequence=$_canonicalNativeConnectionProofSequence',
        );
      }
    }

    return _canonicalNativeConnectionProofIsValid(
      rawStatus: rawStatus,
      protectionStatus: protectionStatus,
    );
  }

  bool _canonicalNativeConnectionProofIsValid({
    required DeviceStatus rawStatus,
    required ProtectionStatus protectionStatus,
  }) {
    final proof = _canonicalNativeConnectionProof;
    if (proof == null ||
        !_protectionNativeOwnerDeclared(protectionStatus) ||
        protectionStatus.bleOwner != proof.nativeOwner ||
        !protectionStatus.serviceBleConnected ||
        !_protectionRuntimeRunning(protectionStatus)) {
      return false;
    }
    return _deviceStatusContainsConnectionIdentity(
          rawStatus,
          proof.physicalIdentity,
        ) &&
        _protectionStatusContainsConnectionIdentity(
          protectionStatus,
          proof.physicalIdentity,
        );
  }

  String? _matchingNativeConnectionIdentity({
    required DeviceStatus rawStatus,
    required ProtectionStatus protectionStatus,
  }) {
    final expectedTargets = <String?>[
      rawStatus.canonicalHardwareId,
      rawStatus.deviceId,
    ].whereType<String>();
    final nativeTargets = <String?>[
      protectionStatus.activeDeviceId,
      protectionStatus.protectedDeviceId,
    ].whereType<String>();
    for (final expected in expectedTargets) {
      final normalizedExpected = expected.trim();
      if (normalizedExpected.isEmpty) {
        continue;
      }
      for (final actual in nativeTargets) {
        final normalizedActual = actual.trim();
        if (normalizedActual.isNotEmpty &&
            _connectionIdentitiesMatch(normalizedExpected, normalizedActual)) {
          return normalizedExpected;
        }
      }
    }
    return null;
  }

  bool _deviceStatusContainsConnectionIdentity(
    DeviceStatus status,
    String identity,
  ) {
    return <String?>[status.canonicalHardwareId, status.deviceId]
        .whereType<String>()
        .any((candidate) => _connectionIdentitiesMatch(candidate, identity));
  }

  bool _protectionStatusContainsConnectionIdentity(
    ProtectionStatus status,
    String identity,
  ) {
    return <String?>[status.activeDeviceId, status.protectedDeviceId]
        .whereType<String>()
        .any((candidate) => _connectionIdentitiesMatch(candidate, identity));
  }

  bool _connectionIdentitiesMatch(String left, String right) {
    final normalizedLeft = left.trim();
    final normalizedRight = right.trim();
    if (normalizedLeft.isEmpty || normalizedRight.isEmpty) {
      return false;
    }
    return normalizedLeft.toLowerCase() == normalizedRight.toLowerCase() ||
        _samePhysicalHardwareId(normalizedLeft, normalizedRight);
  }

  String _canonicalNativeConnectionProofInvalidationReason({
    required DeviceStatus rawStatus,
    required ProtectionStatus protectionStatus,
    required _CanonicalNativeConnectionProof proof,
  }) {
    if (!protectionStatus.serviceBleConnected) {
      return 'explicit_native_gatt_disconnect';
    }
    if (!_protectionNativeOwnerDeclared(protectionStatus)) {
      return rawStatus.connected
          ? 'flutter_owner_connected'
          : 'native_session_terminated';
    }
    if (protectionStatus.bleOwner != proof.nativeOwner) {
      return 'native_owner_changed';
    }
    if (!_deviceStatusContainsConnectionIdentity(
          rawStatus,
          proof.physicalIdentity,
        ) ||
        !_protectionStatusContainsConnectionIdentity(
          protectionStatus,
          proof.physicalIdentity,
        )) {
      return 'physical_identity_changed_or_lost';
    }
    if (!_protectionRuntimeRunning(protectionStatus)) {
      return rawStatus.connected
          ? 'runtime_stopped_flutter_connected'
          : 'runtime_stopped_without_flutter_connection';
    }
    return 'native_session_no_longer_authoritative';
  }

  void _clearCanonicalNativeConnectionProof({required String reason}) {
    final proof = _canonicalNativeConnectionProof;
    if (proof == null) {
      return;
    }
    _canonicalNativeConnectionProof = null;
    _lastConnectionTransitionPreservedSignature = null;
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_CONNECTION_CONTINUITY_CLEARED reason=$reason '
      'proofSequence=${proof.sequence} '
      'proofAgeMs=${_clock().toUtc().difference(proof.establishedAt).inMilliseconds}',
    );
  }

  void _recordDeviceConnectionTransitionPreserved({
    required String previousOwner,
    required String nextOwner,
    required ProtectionStatus protectionStatus,
    required String reason,
  }) {
    final proof = _canonicalNativeConnectionProof;
    if (proof == null) {
      return;
    }
    final transitionReason =
        protectionStatus.lastPlatformEvent ??
        protectionStatus.lastBleServiceEvent ??
        reason;
    final signature =
        '${proof.sequence}|$previousOwner|$nextOwner|$transitionReason';
    if (_lastConnectionTransitionPreservedSignature == signature) {
      return;
    }
    _lastConnectionTransitionPreservedSignature = signature;
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_CONNECTION_TRANSITION_PRESERVED '
      'previousOwner=$previousOwner nextOwner=$nextOwner '
      'visibleConnected=true retainedIdentityPresent=true '
      'nativeGattConnected=${protectionStatus.serviceBleConnected} '
      'nativeCommandReady=${_nativeCommandReadinessForStatus(protectionStatus).ready} '
      'runtimeRunning=${_protectionRuntimeRunning(protectionStatus)} '
      'reason=$transitionReason '
      'preservationReason=same_native_session_internal_transition',
    );
  }

  void _recordDeviceConnectionProjection({
    required DeviceStatus rawStatus,
    required DeviceStatus publicStatus,
    required bool previousVisibleConnected,
    required String source,
  }) {
    final protection = _protectionModeController.currentStatus;
    final nativeCommandReady = _nativeCommandReadinessForStatus(
      protection,
    ).ready;
    final sameDeviceIdentity = _nativeProtectionTargetMatchesDeviceStatus(
      baseStatus: rawStatus,
      protectionStatus: protection,
    );
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: rawStatus.connected,
      nativeOwnerDeclared: _protectionNativeOwnerDeclared(protection),
      nativeOwnerReady:
          _protectionNativeOwnerDeclared(protection) && nativeCommandReady,
      nativeGattConnected: protection.serviceBleConnected,
      sameDeviceIdentity: sameDeviceIdentity,
      nativeConnectionContinuityProven: _canonicalNativeConnectionProofIsValid(
        rawStatus: rawStatus,
        protectionStatus: protection,
      ),
    );
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_CONNECTION_PROJECTION '
      'visibleConnected=${publicStatus.connected} '
      'previousVisibleConnected=$previousVisibleConnected source=$source '
      'bleOwner=${_deviceConnectionOwner(protection)} '
      'nativeGattConnected=${protection.serviceBleConnected} '
      'flutterGattConnected=${rawStatus.connected} '
      'protectionRuntimeRunning=${_protectionRuntimeRunning(protection)} '
      'nativeCommandReady=$nativeCommandReady '
      'connectedIdentityPresent=$sameDeviceIdentity '
      'nativeConnectedIdentity=${_nativeConnectedIdentity(protection)} '
      'flutterRepositoryConnected=${rawStatus.connected} '
      'lifecycleGeneration=${_sosLifecycle.current.generation} '
      'deviceMirrorState=${_sosDeviceMirrorState.name} '
      'reason=${projection.reason.name}',
    );
    if (!publicStatus.connected) {
      final nativeOwner = _protectionNativeOwnerDeclared(protection);
      _recordDeviceConnectionReconnectDecision(
        rawStatus: rawStatus,
        protectionStatus: protection,
        requested: !nativeOwner,
        trigger: source,
        action: nativeOwner ? 'handoff' : 'reconnect',
        reason: projection.reason.name,
        sameDeviceIdentity: sameDeviceIdentity,
      );
    }
  }

  void _recordFalseDeviceDisconnectBlocked({
    required DeviceStatus rawStatus,
    required ProtectionStatus protectionStatus,
    required String source,
    required String projectionReason,
    required bool sameDeviceIdentity,
  }) {
    final nativeCommandReady = _nativeCommandReadinessForStatus(
      protectionStatus,
    ).ready;
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_CONNECTION_FALSE_DISCONNECT_BLOCKED '
      'source=$source bleOwner=${_deviceConnectionOwner(protectionStatus)} '
      'nativeGattConnected=${protectionStatus.serviceBleConnected} '
      'flutterGattConnected=${rawStatus.connected} '
      'nativeCommandReady=$nativeCommandReady '
      'sameDeviceIdentity=$sameDeviceIdentity '
      'lifecycleGeneration=${_sosLifecycle.current.generation} '
      'deviceMirrorState=${_sosDeviceMirrorState.name} '
      'reason=$projectionReason',
    );
    _recordDeviceConnectionReconnectDecision(
      rawStatus: rawStatus,
      protectionStatus: protectionStatus,
      requested: false,
      trigger: source,
      action: 'preserve_native',
      reason: projectionReason,
      sameDeviceIdentity: sameDeviceIdentity,
    );
  }

  void _recordDeviceConnectionReconnectDecision({
    required DeviceStatus rawStatus,
    required ProtectionStatus protectionStatus,
    required bool requested,
    required String trigger,
    required String action,
    required String reason,
    required bool sameDeviceIdentity,
  }) {
    final nativeCommandReady = _nativeCommandReadinessForStatus(
      protectionStatus,
    ).ready;
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_CONNECTION_RECONNECT_DECISION requested=$requested '
      'trigger=$trigger bleOwner=${_deviceConnectionOwner(protectionStatus)} '
      'nativeGattConnected=${protectionStatus.serviceBleConnected} '
      'flutterGattConnected=${rawStatus.connected} '
      'nativeCommandReady=$nativeCommandReady '
      'sameDeviceIdentity=$sameDeviceIdentity action=$action '
      'lifecycleGeneration=${_sosLifecycle.current.generation} '
      'deviceMirrorState=${_sosDeviceMirrorState.name} reason=$reason',
    );
  }

  bool _protectionReportsLiveBleConnection(ProtectionStatus status) {
    return status.deviceConnected ||
        status.serviceBleConnected ||
        status.serviceBleReady;
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
    _deathManOverdueNotified =
        activePlan.status == DeathManStatus.overdue ||
        activePlan.status == DeathManStatus.awaitingConfirmation;
    _startDeathManMonitoring(activePlan.id);
  }

  bool get _isProtectionPlatformOwningBle {
    final status = _protectionModeController.currentStatus;
    return status.modeState != ProtectionModeState.off &&
        status.bleOwner != ProtectionBleOwner.flutter;
  }

  bool get _isAppBackgrounded {
    return _appLifecycleState == AppLifecycleState.paused ||
        _appLifecycleState == AppLifecycleState.detached;
  }

  bool get _shouldSkipFlutterBleReconnect {
    // Declared native ownership is exclusive while the native GATT is still
    // preparing. Starting Flutter reconnects in that window recreates the
    // dual-GATT race that delays service discovery and EA04 readiness.
    return _isProtectionPlatformOwningBle;
  }

  Future<bool> _nativeProtectionOwnsBleAfterRehydrate() async {
    try {
      await _protectionModeController.rehydrate();
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'Protection rehydrate before BLE reconnect failed: $error',
      );
    }
    return _shouldSkipFlutterBleReconnect;
  }

  Future<void> _delegateBleToNativeProtection({required String reason}) {
    final isYield = reason.contains('flutter_yielded');
    final flutterConnected =
        (_lastPublicDeviceStatus ?? _lastDeviceStatus)?.connected == true;
    if (!isYield && flutterConnected && !_isAppBackgrounded) {
      BleDebugRegistry.instance.recordEvent(
        'EIXAM_RECONNECT_TRACE sdk_native_ble_ensure_skipped '
        'reason=flutter_foreground_connected source=$reason',
      );
      return Future<void>.value();
    }
    if (!isYield) {
      final last = _lastNativeProtectionEnsureAt;
      final now = DateTime.now();
      if (last != null &&
          now.difference(last) < _nativeProtectionEnsureDebounce) {
        BleDebugRegistry.instance.recordEvent(
          'EIXAM_RECONNECT_TRACE sdk_native_ble_ensure_skipped '
          'reason=debounced source=$reason',
        );
        return Future<void>.value();
      }
      _lastNativeProtectionEnsureAt = now;
    }
    BleDebugRegistry.instance.recordEvent(
      'EIXAM_RECONNECT_TRACE sdk_native_ble_ensure source=$reason',
    );
    return protectionPlatformAdapter.ensureProtectionRuntimeActive(
      reason: reason,
    );
  }

  String get _currentDeviceCommandOwnerRoute {
    switch (_sosBleOwnershipState) {
      case SosBleOwnershipState.flutterOwner:
        return 'flutter_writer';
      case SosBleOwnershipState.nativePreparing:
        return 'native_preparing';
      case SosBleOwnershipState.nativeReadyOwner:
        return 'native_protection';
    }
  }

  bool _nativeProtectionTargetMatchesConnectedDevice(
    ProtectionStatus protectionStatus,
  ) {
    final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    return connectedDevice != null &&
        _nativeProtectionTargetMatchesDeviceStatus(
          baseStatus: connectedDevice,
          protectionStatus: protectionStatus,
        );
  }

  NativeProtectionCommandReadiness _nativeCommandReadinessForStatus(
    ProtectionStatus status,
  ) {
    final legacyIosCommandReady =
        status.bleOwner == ProtectionBleOwner.iosPlugin &&
        status.serviceBleReady;
    return evaluateNativeProtectionCommandReadiness(
      declaredOwner: status.bleOwner,
      serviceBleConnected: status.serviceBleConnected,
      serviceReady: status.nativeCommandServiceReady || legacyIosCommandReady,
      cmdEa04Ready: status.nativeCommandEa04Ready || legacyIosCommandReady,
      exactTargetIdentityMatch:
          (status.nativeCommandIdentityReady || legacyIosCommandReady) &&
          _nativeProtectionTargetMatchesConnectedDevice(status),
      operationQueueOperational:
          status.nativeCommandQueueHealthy &&
          status.lastCommandError?.trim().isNotEmpty != true,
    );
  }

  SosBleOwnershipState get _sosBleOwnershipState {
    final status = _protectionModeController.currentStatus;
    if (status.modeState == ProtectionModeState.off) {
      return SosBleOwnershipState.flutterOwner;
    }
    return resolveSosBleOwnershipState(
      declaredOwner: status.bleOwner,
      nativeCommandReady: _nativeCommandReadinessForStatus(status).ready,
    );
  }

  bool get _isAuthoritativeNativeProtectionBleOwner {
    return _sosBleOwnershipState == SosBleOwnershipState.nativeReadyOwner;
  }

  Future<void> _sendDeviceCommandThroughActiveOwner(
    EixamDeviceCommand command,
  ) async {
    final ownerRoute = _currentDeviceCommandOwnerRoute;
    BleDebugRegistry.instance.recordEvent(
      'Device leg owner chosen -> owner=$ownerRoute command=${command.label}',
    );
    if (_sosBleOwnershipState == SosBleOwnershipState.nativePreparing) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_DEVICE_COMMAND_REJECTED owner=native_preparing '
        'reason=native_command_not_ready command=${command.label}',
      );
      _throwDeviceCommandNotReady();
    }
    if (_isAuthoritativeNativeProtectionBleOwner) {
      final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
      final protectionStatus = _protectionModeController.currentStatus;
      final expectedTargets =
          <String?>[
                connectedDevice?.deviceId,
                connectedDevice?.canonicalHardwareId,
              ]
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet();
      final nativeTargets =
          <String?>[
                protectionStatus.activeDeviceId,
                protectionStatus.protectedDeviceId,
              ]
              .whereType<String>()
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toSet();
      final targetMatches =
          expectedTargets.isNotEmpty &&
          nativeTargets.isNotEmpty &&
          expectedTargets.any(
            (expected) => nativeTargets.any(
              (actual) =>
                  expected.toLowerCase() == actual.toLowerCase() ||
                  _samePhysicalHardwareId(expected, actual),
            ),
          );
      if (!targetMatches) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_DEVICE_COMMAND_TARGET_REJECTED '
          'owner=$ownerRoute command=${command.label} '
          'connectedTargets=${expectedTargets.join(",")} '
          'nativeTargets=${nativeTargets.join(",")}',
        );
        throw const DeviceException(
          'E_SOS_DEVICE_COMMAND_TARGET_MISMATCH',
          'E_SOS_DEVICE_COMMAND_TARGET_MISMATCH',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'SOS_DEVICE_COMMAND_TARGET_CONFIRMED '
        'owner=$ownerRoute command=${command.label} '
        'connectedTargets=${expectedTargets.join(",")} '
        'nativeTargets=${nativeTargets.join(",")}',
      );
      final result = await protectionPlatformAdapter.sendProtectionCommand(
        request: ProtectionPlatformCommandRequest(
          label: command.label,
          bytes: command.encode(),
          forceCmdCharacteristic: command.usesCmdCharacteristic,
        ),
      );
      if (command.opcode != EixamBleProtocol.nearbyTextTxOpcode &&
          command.opcode != EixamBleProtocol.nearbyTextGroupOpcode &&
          command.opcode != EixamBleProtocol.nearbyOwnerNameOpcode) {
        await _protectionModeController.rehydrate();
      }
      if (!result.success) {
        BleDebugRegistry.instance.recordEvent(
          'Native owner command rejected -> owner=$ownerRoute command=${command.label} route=${result.route ?? "-"} error=${result.error ?? result.result ?? "-"}',
        );
        final message =
            result.error ?? 'E_PROTECTION_NATIVE_COMMAND_SEND_FAILED';
        throw DeviceException(message, message);
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
      throw const DeviceException(
        'E_BLE_COMMAND_WRITER_NOT_READY',
        'E_BLE_COMMAND_WRITER_NOT_READY',
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
    if (_bleOwnershipHandoffInFlight) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_BLE_OWNER_DECISION owner=${owner.name} action=dedupe_handoff',
      );
      return;
    }
    _bleOwnershipHandoffInFlight = true;
    try {
      final protectionStatus = _protectionModeController.currentStatus;
      _logSosBleOwnerState(
        reason: 'handoff_requested:${owner.name}',
        status: protectionStatus,
      );
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
      if (owner != ProtectionBleOwner.flutter) {
        final nativeLive = _protectionReportsLiveBleConnection(
          protectionStatus,
        );
        _bleAutoReconnectCoordinator.cancelPreferredReconnect(
          reason: 'native_protection_ble_owner',
        );
        BleDebugRegistry.instance.recordEvent(
          'SOS_BLE_OWNER_DECISION owner=native_protection '
          'action=release_flutter '
          'reason=${nativeLive ? "native_live" : "native_preparing"}',
        );
        if (deviceRepository is InMemoryDeviceRepository) {
          final repository = deviceRepository as InMemoryDeviceRepository;
          _lastDeviceStatus = await repository
              .releaseBleOwnershipToProtectionMode(
                reason: 'Protection Mode native runtime is armed',
              );
          _publishPublicDeviceStatus(
            rawStatus: _lastDeviceStatus!,
            reason: 'protection_ble_ownership_released',
          );
          _flutterBleReleaseCompletedForNativeOwnership = true;
          _logSosBleOwnerState(
            reason: 'flutter_release_completed',
            status: protectionStatus,
          );
        }
        final nativeReady = _nativeCommandReadinessForStatus(
          protectionStatus,
        ).ready;
        if (!nativeReady && !_nativePreparationRequestedForOwnership) {
          _nativePreparationRequestedForOwnership = true;
          try {
            await _delegateBleToNativeProtection(
              reason: 'flutter_yielded_ble_to_native_preparation',
            );
          } catch (_) {
            _nativePreparationRequestedForOwnership = false;
            rethrow;
          }
        } else if (nativeReady) {
          _bleAutoReconnectCoordinator.setAppForeground(false);
        }
        return;
      }
      if (deviceRepository is! InMemoryDeviceRepository) {
        return;
      }
      final repository = deviceRepository as InMemoryDeviceRepository;
      await repository.reclaimBleOwnershipFromProtectionMode(
        reason: 'Protection Mode returned BLE ownership to Flutter',
      );
      _flutterBleReleaseCompletedForNativeOwnership = false;
      BleDebugRegistry.instance.recordEvent(
        'SOS_BLE_OWNER_DECISION owner=flutter action=reclaim '
        'reason=platform_owner_returned',
      );
      _logSosBleOwnerState(
        reason: 'flutter_reclaim_requested',
        status: protectionStatus,
      );
      _bleAutoReconnectCoordinator.setAppForeground(true);
      unawaited(
        _bleAutoReconnectCoordinator.tryAutoConnect(
          trigger: 'flutter_ble_ownership_reclaimed',
        ),
      );
      if ((_lastPublicDeviceStatus ?? _lastDeviceStatus)?.connected == true) {
        unawaited(
          _maybeCheckDeviceCountryConfig('flutter_ble_ownership_reclaimed'),
        );
      }
    } finally {
      _bleOwnershipHandoffInFlight = false;
    }
  }

  void _logSosBleOwnerState({
    required String reason,
    required ProtectionStatus status,
  }) {
    final nativeDeclared =
        status.modeState != ProtectionModeState.off &&
        status.bleOwner != ProtectionBleOwner.flutter;
    final flutterGattConnected = _lastDeviceStatus?.connected == true;
    final nativeGattConnected =
        status.serviceBleConnected || status.serviceBleReady;
    final nativeReady =
        nativeDeclared && _nativeCommandReadinessForStatus(status).ready;
    final owner = nativeDeclared
        ? nativeReady
              ? 'nativeReady'
              : 'nativePreparing'
        : flutterGattConnected
        ? 'flutter'
        : 'none';
    if (_lastSosBleOwnerDiagnostic != owner) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_BLE_OWNER_TRANSITION '
        'previous=${_lastSosBleOwnerDiagnostic ?? "none"} '
        'next=$owner reason=$reason',
      );
      if (owner == 'nativeReady') {
        BleDebugRegistry.instance.recordEvent(
          'SOS_NATIVE_GATT_ISOLATION owner=nativeReady '
          'nativeRuntime=ProtectionBleRuntimeOwner '
          'flutterPluginGattIndependent=true '
          'subscriptionsActive=${status.serviceBleReady}',
        );
      }
      _lastSosBleOwnerDiagnostic = owner;
    }
    final invariant = evaluateSosBleSingleOwnerInvariant(
      nativeDeclared: nativeDeclared,
      flutterOwner: owner == 'flutter',
      flutterReleaseSettled: _flutterBleReleaseCompletedForNativeOwnership,
      nativeGattConnected: nativeGattConnected,
      flutterGattConnected: flutterGattConnected,
    );
    if (invariant == SosBleSingleOwnerViolation.none) {
      _lastSosBleSingleOwnerViolationSignature = null;
    } else {
      final violation = invariant.name;
      final violationSignature =
          '$violation|$owner|$nativeGattConnected|$flutterGattConnected';
      if (_lastSosBleSingleOwnerViolationSignature != violationSignature) {
        _lastSosBleSingleOwnerViolationSignature = violationSignature;
        BleDebugRegistry.instance.recordEvent(
          'SOS_BLE_SINGLE_OWNER_VIOLATION violation=$violation '
          'owner=$owner reason=$reason '
          'nativeGattConnected=$nativeGattConnected '
          'flutterGattConnected=$flutterGattConnected',
        );
      }
    }
    final signature = '$owner|$nativeGattConnected|$flutterGattConnected';
    if (_lastSosBleOwnerStateSignature == signature) {
      return;
    }
    _lastSosBleOwnerStateSignature = signature;
    BleDebugRegistry.instance.recordEvent(
      'SOS_BLE_OWNER_STATE owner=$owner reason=$reason '
      'nativeGattConnected=$nativeGattConnected '
      'flutterGattConnected=$flutterGattConnected',
    );
  }

  void _recordBackendTerminalTransportState({
    required String backendAction,
    required SosLifecycleStage lifecycleStage,
    required String terminalState,
  }) {
    final protection = _protectionModeController.currentStatus;
    final debug = BleDebugRegistry.instance.currentState;
    final nativeOwner =
        protection.modeState != ProtectionModeState.off &&
        protection.bleOwner != ProtectionBleOwner.flutter;
    final nativeGattConnected =
        protection.serviceBleConnected || protection.serviceBleReady;
    final flutterGattConnected = _lastDeviceStatus?.connected == true;
    final owner = nativeOwner
        ? _nativeCommandReadinessForStatus(protection).ready
              ? 'nativeReady'
              : 'nativePreparing'
        : flutterGattConnected
        ? 'flutter'
        : 'none';
    final ea01Subscribed = nativeOwner
        ? protection.serviceBleReady
        : debug.telNotifySubscribed;
    final ea02Subscribed = nativeOwner
        ? protection.serviceBleReady
        : debug.sosNotifySubscribed;
    final commandReady = nativeOwner
        ? _nativeCommandReadinessForStatus(protection).ready
        : debug.commandWriterReady ||
              deviceSosController.shortCommandAvailable ||
              deviceSosController.longCommandAvailable;
    final deviceTransportReady =
        (owner == 'nativeReady' && nativeGattConnected) ||
        (owner == 'flutter' && flutterGattConnected && commandReady);
    final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
    final connectedIdentityPresent =
        connectedDevice?.deviceId.trim().isNotEmpty == true &&
        (_physicalHardwareIdForStatus(connectedDevice)?.isNotEmpty == true ||
            connectedDevice?.nodeId != null);
    BleDebugRegistry.instance.recordEvent(
      'SOS_BACKEND_TERMINAL_TRANSPORT_STATE '
      'backendAction=$backendAction lifecycleStage=${lifecycleStage.name} '
      'terminalState=$terminalState '
      'lifecycleGeneration=${_sosLifecycle.current.generation} owner=$owner '
      'nativeGattConnected=$nativeGattConnected '
      'flutterGattConnected=$flutterGattConnected '
      'ea01Subscribed=$ea01Subscribed ea02Subscribed=$ea02Subscribed '
      'commandReady=$commandReady deviceTransportReady=$deviceTransportReady '
      'connectedIdentityPresent=$connectedIdentityPresent',
    );
  }

  void _handleProtectionPlatformSosEvent(ProtectionPlatformEvent event) {
    if (event.type == ProtectionPlatformEventType.bleNotificationReceived) {
      _lastNativeRawPayloadHex = event.payloadHex;
      _lastNativeRawReceiveCorrelation = event.receiveCorrelation;
      _lastNativeRawReceiveSequence = event.receiveSequence;
      _lastNativeRawCharacteristicUuid = event.characteristicUuid;
      _lastNativeRawConnectedDeviceMarker = event.connectedDeviceMarker;
      final receiveSequence = event.receiveSequence;
      if (receiveSequence != null) {
        _latestNativeReceiveSequence = receiveSequence;
      }
      BleDebugRegistry.instance.recordEvent(
        'EIXAM_BLE_NOTIFICATION_RX '
        'producer=native_bridge owner=native_protection '
        'correlation=${event.receiveCorrelation ?? "none"} '
        'processSessionId=$_processSessionId '
        'receiveSequenceDomain=process:$_processSessionId '
        'characteristic=${event.characteristicUuid ?? "unknown"} '
        'byteLength=${event.byteLength ?? 0} '
        'packetType=${event.packetType ?? "unknown"} '
        'firstOpcode=${event.firstOpcode ?? "none"} '
        'receiveSequence=${event.receiveSequence ?? -1} '
        'connectedDevice=${event.connectedDeviceMarker ?? "none"}',
      );
      final characteristic = event.characteristicUuid?.toLowerCase();
      final isTelNotification =
          characteristic == EixamBleProtocol.telNotifyCharacteristicUuid ||
          characteristic == 'ea01' ||
          event.source == 'tel_fragment' ||
          event.source == 'd2_relay' ||
          event.source == 'tel_notify';
      final rawPayload = event.payloadHex == null
          ? null
          : _tryDecodeHexPayload(event.payloadHex!);
      final repository = deviceRepository;
      if (isTelNotification &&
          rawPayload != null &&
          rawPayload.isNotEmpty &&
          repository is InMemoryDeviceRepository) {
        unawaited(
          repository.ingestNativeBridgeTelNotification(
            payload: rawPayload,
            receivedAt: event.timestamp,
            receiveSequence: event.receiveSequence ?? -1,
            connectedDeviceMarker: event.connectedDeviceMarker,
          ),
        );
      }
      return;
    }
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
      _logSosTrace('dart_platform_event_ignored reason=not_sos_event_type');
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
      _logSosTrace('dart_platform_event_ignored reason=missing_hex_payload');
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
      _logSosTrace('dart_platform_event_ignored reason=invalid_hex_payload');
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
    final originatorNodeId =
        remoteRelaySnapshot?.originatorNodeId ??
        remoteClassification.sosPacket?.nodeId ??
        remoteClassification.sosEventPacket?.nodeId ??
        EixamSosPacket.tryParse(bytes)?.nodeId ??
        EixamSosEventPacket.tryParse(bytes)?.nodeId;
    final platformSosEventPacket = EixamSosEventPacket.tryParse(bytes);
    final effectiveClassificationKind = isNativeApprovedOwnLifecycle
        ? BleIncomingPayloadKind.ownDeviceSos
        : remoteClassification.kind;
    final matchesRawNotification =
        _lastNativeRawPayloadHex?.toLowerCase() == rawHex.toLowerCase();
    final receiveCorrelation = matchesRawNotification
        ? _lastNativeRawReceiveCorrelation
        : null;
    final receiveSequence = matchesRawNotification
        ? _lastNativeRawReceiveSequence
        : null;
    final characteristicUuid = matchesRawNotification
        ? _lastNativeRawCharacteristicUuid
        : null;
    final connectedDeviceMarker = matchesRawNotification
        ? _lastNativeRawConnectedDeviceMarker
        : null;
    BleDebugRegistry.instance.recordEvent(
      'BLE_SOS_CLASSIFY_DECISION raw=$rawHex '
      'packetType=${platformSosEventPacket == null ? "sos" : "sos_event"} '
      'classification=${effectiveClassificationKind.name} '
      'source=native_protection '
      'correlation=${receiveCorrelation ?? "none"} '
      'receiveSequence=${receiveSequence ?? -1} '
      'characteristic=${characteristicUuid ?? "unknown"}',
    );
    SosLifecycleSnapshot? admissionLifecycle;
    SosLifecycleSnapshot? admissionTerminalLifecycle;
    var physicalIdentityMatch = false;
    var exactPhysicalIdentityMatch = false;
    var hasCurrentBleSessionEvidence = false;
    if (isNativeApprovedOwnLifecycle) {
      final currentLifecycle = _sosLifecycle.current;
      final terminalLifecycle = _sosLifecycle.activeTerminalWatermark;
      admissionLifecycle = currentLifecycle;
      admissionTerminalLifecycle = terminalLifecycle;
      physicalIdentityMatch =
          payloadReason.identityOwn &&
          (platformConnectedBleNodeId == null ||
              originatorNodeId == null ||
              platformConnectedBleNodeId == originatorNodeId);
      final connectedDevice = _lastPublicDeviceStatus ?? _lastDeviceStatus;
      final connectedNodeId = _normalizeNodeIdOrNull(
        connectedDevice?.nodeId ?? _knownLocalDeviceNodeId,
      );
      final normalizedOriginatorNodeId = _normalizeNodeIdOrNull(
        originatorNodeId,
      );
      exactPhysicalIdentityMatch =
          physicalIdentityMatch &&
          connectedDevice?.connected == true &&
          connectedNodeId != null &&
          normalizedOriginatorNodeId != null &&
          connectedNodeId == normalizedOriginatorNodeId &&
          _physicalHardwareIdForStatus(connectedDevice)?.isNotEmpty == true;
      hasCurrentBleSessionEvidence =
          matchesRawNotification &&
          receiveSequence != null &&
          _lastNativeRawReceiveCorrelation?.trim().isNotEmpty == true &&
          characteristicUuid?.trim().isNotEmpty == true &&
          connectedDeviceMarker?.trim().isNotEmpty == true &&
          !event.timestamp.toUtc().isBefore(_processSessionStartedAt);
      if (platformSosEventPacket != null &&
          physicalIdentityMatch &&
          receiveSequence != null) {
        _lastOwnDeviceTerminalNativeReceiveSequence = receiveSequence;
        _lastOwnDeviceTerminalNativeGeneration = currentLifecycle.generation;
        _lastOwnDeviceTerminalReceiveSequenceDomain =
            'process:$_processSessionId';
        _lastOwnDeviceTerminalProcessSessionId = _processSessionId;
      }
    }
    if (matchesRawNotification) {
      _lastNativeRawPayloadHex = null;
      _lastNativeRawReceiveCorrelation = null;
      _lastNativeRawReceiveSequence = null;
      _lastNativeRawCharacteristicUuid = null;
      _lastNativeRawConnectedDeviceMarker = null;
    }
    final parsedPhysicalSosPacket = EixamSosPacket.tryParse(bytes);
    final physicalReceiveEvidence = receiveSequence == null
        ? null
        : PhysicalSosReceiveEvidence(
            classification: effectiveClassificationKind,
            receiveSequence: receiveSequence,
            receiveSequenceDomain: 'process:$_processSessionId',
            processSessionId: _processSessionId,
            producer: 'native_bridge',
            characteristic: characteristicUuid ?? 'unknown',
            correlationId: receiveCorrelation ?? 'none',
            exactPhysicalIdentityMatch: exactPhysicalIdentityMatch,
            packetType: platformSosEventPacket == null ? 'sos' : 'sos_event',
            hasStartSemantics:
                parsedPhysicalSosPacket != null &&
                parsedPhysicalSosPacket.sosType != 0,
            hasTerminalSemantics:
                platformSosEventPacket != null &&
                (_isTerminalSosEventPacket(platformSosEventPacket) ||
                    platformSosEventPacket.isAppCancelAck),
            packetFingerprint: platformSosEventPacket == null
                ? '${parsedPhysicalSosPacket?.nodeId ?? originatorNodeId}:${parsedPhysicalSosPacket?.packetId ?? "unknown"}:$rawHex'
                : '${platformSosEventPacket.nodeId}:${platformSosEventPacket.opcode}:${platformSosEventPacket.subcode}:$rawHex',
            cycleIdentity: platformSosEventPacket == null
                ? '${parsedPhysicalSosPacket?.nodeId ?? originatorNodeId}:${parsedPhysicalSosPacket?.packetId ?? "unknown"}'
                : '${platformSosEventPacket.nodeId}:event:${platformSosEventPacket.opcode}',
            receivedAt: event.timestamp,
          );
    final isLocalPlatformSosClassification =
        isNativeApprovedOwnLifecycle ||
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
      if (!_admitRemoteRelayLifecycleEvidence(
        remoteRelaySnapshot,
        evidenceRoute: 'native:${event.type.name}',
      )) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_LIFECYCLE_ADMISSION admitted=false '
          'reason=duplicate_cross_owner_evidence '
          'remoteIdentity=${remoteRelaySnapshot.originatorNodeId} '
          'cycleCorrelation=${_remoteRelayCycleCorrelation(remoteRelaySnapshot)}',
        );
        return;
      }
      if (remoteRelaySnapshot.kind != RemoteRelaySosKind.sos) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_RELAY_CLASSIFICATION classification=remoteRelayCancel '
          'remoteOriginator=${remoteRelaySnapshot.originatorNodeId} '
          'connectedRelay=${remoteRelaySnapshot.relayNodeId?.toString() ?? "unknown"} '
          'lifecycleAction=CANCEL',
        );
        BleDebugRegistry.instance.recordEvent(
          'SOS_REMOTE_LIFECYCLE_ADMISSION admitted=true '
          'reason=external_relay_terminal_evidence '
          'remoteIdentity=${remoteRelaySnapshot.originatorNodeId} '
          'cycleCorrelation=${_remoteRelayCycleCorrelation(remoteRelaySnapshot)}',
        );
      }
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
      unawaited(_handleRemoteRelaySosBackendHandoff(remoteRelaySnapshot));
      return;
    }
    if (payloadReason.identityOwn && !isOwnDeviceSosLifecycleEvent) {
      _logSosTrace(
        'dart_platform_event_route route=ignored reason=native_own_device_sos',
      );
      _logSosTrace('dart_platform_event_ignored reason=native_own_device_sos');
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
      if (_isTerminalSosEventPacket(sosEventPacket)) {
        final synthesizedRemoteCancel =
            _remoteRelayCancelSnapshotForRelayTerminalEvent(
              packet: sosEventPacket,
              receivedAt: event.timestamp,
              rawPayload: bytes,
              payloadHex: rawHex,
            );
        _logRemoteRelayCancelDetection(
          source: 'protection_platform_event_terminal',
          rawType: event.type.name,
          nodeId: sosEventPacket.nodeId,
          originatorNodeId:
              synthesizedRemoteCancel?.originatorNodeId ??
              sosEventPacket.nodeId,
          relayNodeId:
              synthesizedRemoteCancel?.relayNodeId ?? payloadReason.relayNodeId,
          relayHardwareId: _lastDeviceStatus?.canonicalHardwareId,
          classifiedAs: synthesizedRemoteCancel == null
              ? 'ownDevice'
              : 'remoteRelay',
          action: synthesizedRemoteCancel == null
              ? 'local_terminal_only'
              : 'external_cancel_handoff',
        );
        if (synthesizedRemoteCancel != null) {
          _publishSdkEvent(
            RemoteRelaySosObservedEvent(synthesizedRemoteCancel),
          );
          unawaited(
            _handleRemoteRelaySosCancelBackendHandoff(synthesizedRemoteCancel),
          );
          return;
        }
      }
      _logSosTrace(
        'dart_platform_event_route route=local_sos reason=sos_event_packet',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload forwarded -> type=sosDeviceEvent payload=${sosEventPacket.rawHex}',
      );
      deviceSosController.handleIncomingSosEventPacket(
        sosEventPacket,
        source: DeviceSosTransitionSource.device,
        resolutionContext: physicalReceiveEvidence == null
            ? null
            : DeviceSosStateResolutionContext.fromPhysicalEvidence(
                physicalReceiveEvidence,
                incomingPacketType: 'sos_event',
              ),
      );
      // The device status listener classifies the terminal against the
      // still-owned local cycle before applying terminal suppression. Doing
      // that here would clear ownership first and make the same-device packet
      // look like relay residue.
      return;
    }

    final sosPacket = EixamSosPacket.tryParse(bytes);
    if (sosPacket != null) {
      final currentLifecycle = admissionLifecycle ?? _sosLifecycle.current;
      final terminalLifecycle =
          admissionTerminalLifecycle ?? _sosLifecycle.activeTerminalWatermark;
      final afterTerminalBoundary =
          terminalLifecycle != null && !currentLifecycle.isOpen;
      final physicalStartAdmission = physicalReceiveEvidence == null
          ? null
          : deviceSosController.evaluatePhysicalSosStartAdmission(
              sosPacket,
              physicalReceiveEvidence,
            );
      final legacyAdmissionPredicate = afterTerminalBoundary
          ? physicalStartAdmission?.shouldProcess == true
                ? 'terminal_boundary_current_physical_start'
                : 'terminal_without_physical_inactive_boundary'
          : currentLifecycle.isOpen &&
                currentLifecycle.origin == SosLifecycleOrigin.localApp &&
                _deviceMirrorDispatchedGenerations.contains(
                  currentLifecycle.generation,
                )
          ? 'open_app_generation'
          : currentLifecycle.isOpen
          ? 'open_device_generation'
          : 'no_terminal_fence';
      final legacyAdmissionReason = afterTerminalBoundary
          ? physicalStartAdmission?.shouldProcess == true
                ? _deviceInactiveBoundaryAfterTerminalGeneration ==
                          terminalLifecycle.generation
                      ? 'immediate_physical_restart_after_terminal'
                      : 'fresh_physical_start_after_terminal'
                : 'authoritative_terminal_fence'
          : currentLifecycle.isOpen &&
                currentLifecycle.origin == SosLifecycleOrigin.localApp &&
                _deviceMirrorDispatchedGenerations.contains(
                  currentLifecycle.generation,
                )
          ? 'app_triggered_tag_evidence'
          : currentLifecycle.isOpen
          ? 'same_active_cycle_evidence'
          : 'fresh_physical_start';
      BleDebugRegistry.instance.recordEvent(
        'SOS_OWN_DEVICE_LIFECYCLE_ADMISSION '
        'lifecycleStage=${currentLifecycle.stage.name} '
        'terminalState=${terminalLifecycle?.stage.name ?? "none"} '
        'currentGeneration=${currentLifecycle.generation} '
        'terminalGeneration=${terminalLifecycle?.generation ?? 0} '
        'localAppSosActive=${currentLifecycle.isOpen && currentLifecycle.origin == SosLifecycleOrigin.localApp} '
        'appTagMirrorDispatched=${_deviceMirrorDispatchedGenerations.contains(currentLifecycle.generation)} '
        'incomingSource=${payloadReason.source?.name ?? "unknown"} '
        'producer=native_bridge '
        'receiveSequence=${receiveSequence ?? -1} '
        'processSessionId=$_processSessionId '
        'receiveSequenceDomain=process:$_processSessionId '
        'terminalBoundaryFromPreviousProcess=${terminalLifecycle != null && _terminalBoundaryFromPreviousProcessGeneration == terminalLifecycle.generation} '
        'currentBleSessionEvidence=$hasCurrentBleSessionEvidence '
        'characteristic=${characteristicUuid ?? "unknown"} '
        'physicalIdentityMatch=$physicalIdentityMatch '
        'exactPhysicalIdentityMatch=$exactPhysicalIdentityMatch '
        'packetIdentity=${originatorNodeId ?? "none"}:${sosPacket.packetId} '
        'fingerprintSha256=${_sosFingerprintDiagnosticMarker(rawHex)} '
        'suppressionPredicate=$legacyAdmissionPredicate '
        'reason=$legacyAdmissionReason '
        'admitted=${physicalStartAdmission?.shouldProcess == true}',
      );
      if (terminalLifecycle != null &&
          _postResolvePhysicalRxGeneration == terminalLifecycle.generation &&
          sosPacket.sosType != 0) {
        final admitted = physicalStartAdmission?.shouldProcess == true;
        BleDebugRegistry.instance.recordEvent(
          'SOS_POST_RESOLVE_PHYSICAL_RX '
          'producer=native_bridge '
          'characteristic=${characteristicUuid ?? "unknown"} '
          'byteLength=${bytes.length} packetType=sos '
          'receiveSequence=${receiveSequence ?? -1} '
          'classification=${effectiveClassificationKind.name} '
          'admitted=$admitted rejected=${!admitted} '
          'reason=${physicalStartAdmission?.reason ?? "missing_physical_evidence"}',
        );
        if (admitted) {
          _postResolvePhysicalRxGeneration = null;
        }
      }
      _logSosTrace(
        'dart_platform_event_route route=local_sos reason=sos_mesh_packet',
      );
      BleDebugRegistry.instance.recordEvent(
        'Protection SOS payload forwarded -> type=sosMeshPacket payload=${sosPacket.rawHex}',
      );
      deviceSosController.handleIncomingSosPacket(
        sosPacket,
        source: DeviceSosTransitionSource.device,
        resolutionContext: DeviceSosStateResolutionContext(
          incomingPacketType: 'sos',
          incomingClassification: effectiveClassificationKind.name,
          incomingReceiveSequence: receiveSequence,
          previousLifecycleState: currentLifecycle.stage.name,
          terminalGeneration: terminalLifecycle?.generation ?? 0,
          currentGeneration: currentLifecycle.generation,
          appOwnedGeneration:
              currentLifecycle.isOpen &&
                  currentLifecycle.origin == SosLifecycleOrigin.localApp
              ? currentLifecycle.generation
              : null,
          appMirrorDispatched: _deviceMirrorDispatchedGenerations.contains(
            currentLifecycle.generation,
          ),
          afterTerminalBoundary: afterTerminalBoundary,
          allowFreshPhysicalStartAfterTerminal:
              physicalStartAdmission?.allowFreshStartAfterTerminal == true,
          physicalEvidence: physicalReceiveEvidence,
          physicalStartAdmission: physicalStartAdmission,
        ),
      );
      return;
    }

    _logSosTrace(
      'dart_platform_event_route route=ignored reason=unrecognized_payload',
    );
    _logSosTrace('dart_platform_event_ignored reason=unrecognized_payload');
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
          'reason_category=${_isCancelBackendSyncReason(event.reason) ? "cancel" : "sync"} '
          'reason_present=${event.reason?.trim().isNotEmpty == true}',
        );
        _clearPreSosSession(
          reason: 'native_backend_sync_queued',
          emitIdleState: false,
        );
        if (_isCancelBackendSyncReason(event.reason)) {
          // Optimistic cancel: the native protection service already detected
          // the device cycle close from the BLE packet and queued the backend
          // cancel. Surface SosState.cancelled to the UI immediately instead
          // of waiting for the HTTP round-trip to complete.
          _applyTerminalSosSuppression(
            reason: 'backend_terminal_state:native_cancel_queued',
            terminalState: SosState.cancelled,
            nodeId: deviceSosController.currentStatus.nodeId,
          );
          // Defensive backstop: in disconnect-during-cancel scenarios the
          // suppression path can early-return when the incident id cannot be
          // resolved. Force the public state to cancelled so downstream
          // snapshot composition stops emitting arming/active and the
          // pre-SOS sync guard at getPreSosStatus() short-circuits.
          if (!_isTerminalPublicSosState(_publicSosState)) {
            _lastKnownActiveSosIncident = null;
            _activeDeviceSosCycleKey = null;
            _notifiedDeviceSosCycleKey = null;
            _notifiedDeviceSosState = null;
            _clearDeviceRuntimeSosOwnership(reason: 'native_cancel_queued');
            _emitPublicSosState(
              SosState.cancelled,
              source: 'native_backend_sync_queued_cancel_backstop',
            );
          }
        } else {
          _emitPublicSosState(
            SosState.sending,
            source: 'native_backend_sync_queued',
          );
          unawaited(
            _syncNativePreSosBackendPending(
              trigger: 'native_backend_sync_queued',
              maxAttempts: 1,
            ),
          );
        }
        return true;
      case ProtectionPlatformEventType.nativeBackendSyncSucceeded:
        BleDebugRegistry.instance.recordEvent(
          '[NATIVE_PRE_SOS_BACKEND] action=succeeded '
          'reason_category=${_isCancelBackendSyncReason(event.reason) ? "cancel" : "sync"} '
          'reason_present=${event.reason?.trim().isNotEmpty == true}',
        );
        _clearPreSosSession(
          reason: 'native_backend_sync_succeeded',
          emitIdleState: false,
        );
        if (_isCancelBackendSyncReason(event.reason)) {
          _applyTerminalSosSuppression(
            reason: 'backend_terminal_state:native_cancel_synced',
            terminalState: SosState.cancelled,
            nodeId: deviceSosController.currentStatus.nodeId,
          );
        } else {
          unawaited(
            _syncNativePreSosBackendPending(
              trigger: 'native_backend_sync_succeeded',
              maxAttempts: 3,
            ),
          );
        }
        return true;
      case ProtectionPlatformEventType.nativeBackendSyncFailed:
        BleDebugRegistry.instance.recordEvent(
          '[NATIVE_PRE_SOS_BACKEND] action=failed '
          'reason_category=native_backend_sync_failed '
          'reason_present=${event.reason?.trim().isNotEmpty == true}',
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
      case ProtectionPlatformEventType.gattCacheCleared:
      case ProtectionPlatformEventType.servicesDiscovered:
      case ProtectionPlatformEventType.subscriptionsActive:
      case ProtectionPlatformEventType.nativeCommandReadinessChanged:
      case ProtectionPlatformEventType.bleNotificationReceived:
      case ProtectionPlatformEventType.packetReceived:
      case ProtectionPlatformEventType.sosEventReceived:
      case ProtectionPlatformEventType.ownDeviceSosLifecycleObserved:
      case ProtectionPlatformEventType.ownDeviceSosLifecycleSuppressed:
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
    required SosState terminalState,
    int? nodeId,
  }) {
    if (_manualDisconnectRequested) {
      _clearDeviceRuntimeResidueAfterManualDisconnect();
      return;
    }
    final status = deviceSosController.currentStatus;
    final effectiveNodeId = nodeId ?? status.nodeId ?? _knownLocalDeviceNodeId;
    _rememberTerminalDeviceCycleFence(
      status: status,
      effectiveNodeId: effectiveNodeId,
    );
    if (terminalState == SosState.cancelled) {
      final session = _preSosSession;
      if (session != null && session.owner == _SosOwner.device) {
        _rememberPreSosTerminalCancelContext(
          source: reason,
          cycleKey: session.cycleKey,
          originatorNodeId: session.originatorNodeId ?? effectiveNodeId,
          packetId: session.packetId,
          startedAt: session.startedAt,
          expectedActivationAt: session.expectedActivationAt,
        );
      } else if (status.previousState == DeviceSosState.preConfirm ||
          status.state == DeviceSosState.inactive ||
          status.state == DeviceSosState.resolved) {
        _rememberPreSosTerminalCancelContext(
          source: reason,
          cycleKey: _deriveDeviceSosCycleKey(status),
          originatorNodeId: effectiveNodeId,
          packetId: status.packetId,
          startedAt: status.countdownStartedAt,
          expectedActivationAt: status.expectedActivationAt,
        );
      }
    }
    _applyDeviceTerminalPublicSosClose(
      reason: reason,
      terminalState: terminalState,
      nodeId: effectiveNodeId,
      terminalReason: _publicSosTerminalReasonForClose(
        source: reason,
        terminalState: terminalState,
      ),
    );
  }

  void _rememberTerminalDeviceCycleFence({
    required DeviceSosStatus status,
    required int? effectiveNodeId,
  }) {
    final terminal = _sosLifecycle.activeTerminalWatermark;
    if (terminal == null) {
      return;
    }
    final cycleKey = _runtimeDeviceSosCycleKey(
      status: status,
      nodeId: effectiveNodeId,
    );
    final boundary = _latestOwnDeviceInactiveBoundary;
    final usableBoundary =
        boundary != null &&
            _deviceSosStatusEventSequence == boundary.eventSequence &&
            _isDeviceSosCycleClosed(status.state) &&
            _inactiveBoundaryBelongsToTerminal(boundary, terminal: terminal)
        ? boundary
        : null;
    if (cycleKey == null && usableBoundary == null) {
      return;
    }
    final existingFence = _terminalDeviceCycleFence;
    final matchingExistingFence =
        existingFence?.generation == terminal.generation ? existingFence : null;
    _terminalDeviceCycleFence = _TerminalDeviceCycleFence(
      generation: terminal.generation,
      nodeId: effectiveNodeId ?? matchingExistingFence?.nodeId,
      runtimeCycleKey: cycleKey?.trim().isNotEmpty == true
          ? cycleKey
          : matchingExistingFence?.runtimeCycleKey ??
                usableBoundary?.runtimeCycleKey,
      terminalBoundaryEventSequence:
          matchingExistingFence?.terminalBoundaryEventSequence ??
          _deviceSosStatusEventSequence,
      inactiveBoundaryEventSequence:
          usableBoundary?.eventSequence ??
          matchingExistingFence?.inactiveBoundaryEventSequence,
      inactiveBoundaryObservedAt:
          usableBoundary?.observedAt ??
          matchingExistingFence?.inactiveBoundaryObservedAt,
      consumedPacketSignatures:
          matchingExistingFence?.consumedPacketSignatures ??
          _devicePacketSignaturesForGeneration(terminal.generation),
    );
    if (usableBoundary != null) {
      _associateInactiveBoundaryWithTerminal(
        usableBoundary,
        terminal: terminal,
        fallbackCycleKey: cycleKey,
        ordering: usableBoundary.observedBeforeTerminal
            ? 'before_terminal'
            : 'after_terminal',
      );
    }
  }

  void _recordRestoredTerminalBoundaryFromPreviousProcess() {
    final terminal = _sosLifecycle.activeTerminalWatermark;
    final current = _sosLifecycle.current;
    if (terminal == null || !current.isTerminal) {
      return;
    }
    if (_terminalGenerationsEstablishedThisProcess.contains(
      terminal.generation,
    )) {
      return;
    }
    _terminalBoundaryFromPreviousProcessGeneration = terminal.generation;
    _lastOwnDeviceTerminalNativeReceiveSequence = null;
    _lastOwnDeviceTerminalNativeGeneration = null;
    _lastOwnDeviceTerminalReceiveSequenceDomain = null;
    _lastOwnDeviceTerminalProcessSessionId = null;
    BleDebugRegistry.instance.recordEvent(
      'SOS_RECEIVE_SEQUENCE_DOMAIN_RESTORED '
      'processSessionId=$_processSessionId '
      'receiveSequenceDomain=process:$_processSessionId '
      'terminalGeneration=${terminal.generation} '
      'terminalBoundaryFromPreviousProcess=true',
    );
  }

  void _recordTerminalNativeReceiveBoundary(SosLifecycleSnapshot terminal) {
    if (_terminalBoundaryFromPreviousProcessGeneration == terminal.generation) {
      return;
    }
    _terminalGenerationsEstablishedThisProcess.add(terminal.generation);
    final terminalEvidence =
        deviceSosController.terminalPhysicalReceiveEvidence;
    final hasCurrentTerminalEvidence =
        terminalEvidence != null &&
        terminalEvidence.hasTerminalSemantics &&
        terminalEvidence.exactPhysicalIdentityMatch;
    _lastOwnDeviceTerminalNativeReceiveSequence = hasCurrentTerminalEvidence
        ? terminalEvidence.receiveSequence
        : _latestNativeReceiveSequence;
    _lastOwnDeviceTerminalNativeGeneration = terminal.generation;
    _lastOwnDeviceTerminalReceiveSequenceDomain = hasCurrentTerminalEvidence
        ? terminalEvidence.receiveSequenceDomain
        : 'process:$_processSessionId';
    _lastOwnDeviceTerminalProcessSessionId = hasCurrentTerminalEvidence
        ? terminalEvidence.processSessionId
        : _processSessionId;
    BleDebugRegistry.instance.recordEvent(
      'SOS_RECEIVE_SEQUENCE_TERMINAL_BOUNDARY '
      'processSessionId=${_lastOwnDeviceTerminalProcessSessionId ?? _processSessionId} '
      'receiveSequenceDomain=${_lastOwnDeviceTerminalReceiveSequenceDomain ?? "process:$_processSessionId"} '
      'terminalGeneration=${terminal.generation} '
      'terminalReceiveSequence=${_lastOwnDeviceTerminalNativeReceiveSequence ?? -1} '
      'terminalBoundaryFromPreviousProcess=false',
    );
  }

  void _applyDeviceTerminalPublicSosClose({
    required String reason,
    required SosState terminalState,
    required int? nodeId,
    required SosTerminalReason terminalReason,
  }) {
    if (!_isTerminalSuppressionCloseReason(reason)) {
      return;
    }
    final currentRuntimeIncidentId = _currentDeviceRuntimeUiIncidentId();
    final activeIncident = _lastKnownActiveSosIncident;
    final fallbackIncident = _publicSosFallbackIncident;
    final incidentId =
        currentRuntimeIncidentId ??
        fallbackIncident?.id ??
        activeIncident?.id ??
        _lastPublicSosIncidentId ??
        (nodeId == null ? null : 'device-runtime-sos:$nodeId:1');
    if (incidentId == null || incidentId.trim().isEmpty) {
      return;
    }
    final shouldClose =
        _isOpenSosState(_publicSosState) ||
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
        _isTerminalPublicSosState(_publicSosState)) {
      final existingReason =
          _publicSosFallbackIncident?.terminalReason ??
          _lastKnownActiveSosIncident?.terminalReason ??
          _lastPublicSosTerminalReason;
      if (existingReason != null &&
          existingReason != SosTerminalReason.unknown &&
          existingReason != terminalReason) {
        BleDebugRegistry.instance.recordEvent(
          '[APP_SOS_TERMINAL_EVENT] source=device_terminal_event '
          'decision=keep_existing_terminal_reason '
          'existing=${_publicSosState.name} '
          'existingReason=${existingReason.name} '
          'incoming=${terminalState.name} incomingReason=${terminalReason.name} '
          'reason=$reason',
        );
        return;
      }
      if (_publicSosState != terminalState) {
        BleDebugRegistry.instance.recordEvent(
          '[APP_SOS_TERMINAL_EVENT] source=device_terminal_event '
          'decision=keep_existing_terminal existing=${_publicSosState.name} '
          'incoming=${terminalState.name} reason=$reason',
        );
        return;
      }
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
      terminalReason: terminalReason,
      actuators: referenceIncident?.actuators,
    );
    _publicSosFallbackIncident = terminalIncident;
    _lastKnownActiveSosIncident = null;
    _lastPublicSosIncidentId = terminalIncident.id;
    _lastPublicSosDeliveryChannel =
        terminalIncident.deliveryChannel ?? SosDeliveryChannel.deviceOnly;
    _lastPublicSosTerminalReason = terminalReason;
    _clearDeviceRuntimeSosOwnership(reason: 'device_terminal_event');
    BleDebugRegistry.instance.recordEvent(
      '[APP_SOS_TERMINAL_EVENT] source=device_terminal_event '
      'decision=accept_terminal incidentId=${terminalIncident.id} '
      'canonicalIncidentId=${terminalIncident.id} reason=$reason',
    );
    _emitPublicSosState(terminalState, source: 'device_terminal_event');
    _emitOperationalDiagnostics();
  }

  SosTerminalReason _publicSosTerminalReasonForClose({
    required String source,
    required SosState terminalState,
  }) {
    final normalized = source.toLowerCase();
    if (normalized.contains('without_ack') ||
        normalized.contains('missing_ack')) {
      return SosTerminalReason.deviceAckTimeout;
    }
    if (normalized.contains('pre_sos') ||
        normalized.contains('pre-confirm') ||
        normalized.contains('pre_confirm')) {
      return SosTerminalReason.preSosCancelledByDevice;
    }
    if (terminalState == SosState.cancelled) {
      if ((normalized.contains('device_terminal_event') ||
              normalized.contains('own_device_terminal_packet') ||
              normalized.contains('backend_terminal_state')) &&
          (_lastPublicSosTerminalReason == SosTerminalReason.cancelledByUser ||
              _lastPublicSosTerminalReason ==
                  SosTerminalReason.deviceAckTimeout)) {
        return _lastPublicSosTerminalReason!;
      }
      if (_publicSosClosureInFlight == _SosClosureIntent.cancel) {
        return _lastPublicSosTerminalReason ==
                SosTerminalReason.deviceAckTimeout
            ? SosTerminalReason.deviceAckTimeout
            : SosTerminalReason.cancelledByUser;
      }
      if (normalized.contains('public_cancel') ||
          normalized.contains('app_cancel') ||
          normalized.contains('cancelpre')) {
        return SosTerminalReason.cancelledByUser;
      }
      return SosTerminalReason.cancelledByDevice;
    }
    return SosTerminalReason.unknown;
  }

  bool _isDeviceCloseMissingAcknowledgement(DeviceSosStatus status) {
    final lastEvent = status.lastEvent.toLowerCase();
    return lastEvent.contains('missing_ack') ||
        lastEvent.contains('ack_timeout') ||
        lastEvent.contains('forced_terminal_after_missing_ack') ||
        lastEvent.contains('without waiting for a close acknowledgement');
  }

  bool _isCancelBackendSyncReason(String? reason) {
    if (reason == null) {
      return false;
    }
    final normalized = reason.toLowerCase();
    return normalized.startsWith('cancel:') ||
        normalized.startsWith('cancel_') ||
        normalized == 'cancel';
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

  void _clearDeviceRuntimeResidueAfterManualDisconnect() {
    _sosRuntimeNodeIdByHardwareId.clear();
    _knownLocalDeviceNodeId = null;
    _activeDeviceSosCycleKey = null;
    _notifiedDeviceSosCycleKey = null;
    _notifiedDeviceSosState = null;
    _activeDeviceRuntimeIncidentId = null;
    _activeDeviceRuntimeCycleKey = null;
    _activeDeviceRuntimeLocalCycleKey = null;
    _lastClosedDeviceRuntimeLocalCycleKey = null;
    _deviceInactiveBoundaryAfterTerminalGeneration = null;
    _latestOwnDeviceInactiveBoundary = null;
    _terminalDeviceCycleFence = null;
    _pendingFreshPhysicalStartProof = null;
    _acceptedPhysicalStartPacketSignatures.clear();
    _freshPhysicalStartSupersededRemoteClearGeneration = null;
    _lastOwnDeviceTerminalNativeReceiveSequence = null;
    _lastOwnDeviceTerminalNativeGeneration = null;
    _lastOwnDeviceTerminalReceiveSequenceDomain = null;
    _lastOwnDeviceTerminalProcessSessionId = null;
    _terminalBoundaryFromPreviousProcessGeneration = null;
    _terminalGenerationsEstablishedThisProcess.clear();
    _devicePacketSignaturesByGeneration.clear();
    _deviceMirrorDispatchedGenerations.clear();
    _deviceOwnedBackendIncidentId = null;
    _lastDeviceRuntimeCanonicalIncidentSignature = null;
    _lastDeviceRuntimeCanonicalIncident = null;
  }

  bool _isTerminalSosEventPacket(EixamSosEventPacket packet) {
    return packet.opcode == EixamBleProtocol.sosEventUserDeactivatedOpcode ||
        packet.opcode == EixamBleProtocol.sosEventBackendResolvedOpcode;
  }

  Future<void> _evaluateDeathManPlan(String planId) async {
    var plan = await deathManRepository.getActiveDeathManPlan();
    if (plan == null || plan.id != planId) {
      return;
    }

    final now = DateTime.now();
    final overdueAt = plan.expectedReturnAt.add(plan.gracePeriod);
    final expiresAt = overdueAt.add(plan.checkInWindow);

    if (plan.status == DeathManStatus.scheduled) {
      plan =
          await _transitionDeathManPlanTo(plan, DeathManStatus.monitoring) ??
          plan;
    }

    if (plan.status == DeathManStatus.monitoring &&
        now.isAfter(plan.expectedReturnAt)) {
      final transitioned = await _transitionDeathManPlanTo(
        plan,
        DeathManStatus.awaitingConfirmation,
      );
      if (transitioned == null) {
        return;
      }
      plan = transitioned;
      if (!_deathManCheckInNotified) {
        _deathManCheckInNotified = true;
        _emitDeathManNotificationIntent(
          EixamNotificationIntentType.deathManConfirmationRequired,
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
        now.isAfter(overdueAt)) {
      final transitioned = await _transitionDeathManPlanTo(
        plan,
        DeathManStatus.overdue,
      );
      if (transitioned == null) {
        return;
      }
      plan = transitioned;
      if (!_deathManOverdueNotified) {
        _deathManOverdueNotified = true;
        _emitDeathManNotificationIntent(
          EixamNotificationIntentType.deathManOverdue,
          planId: plan.id,
          includeConfirmAction: true,
        );
        _publishSdkEvent(
          DeathManStatusChangedEvent(plan.id, DeathManStatus.overdue.name),
        );
      }
    }

    if (plan.status == DeathManStatus.overdue && now.isAfter(expiresAt)) {
      final escalated = await _transitionDeathManPlanTo(
        plan,
        DeathManStatus.escalated,
      );
      if (escalated == null) {
        return;
      }
      _publishSdkEvent(DeathManEscalatedEvent(plan.id));
      _emitDeathManNotificationIntent(
        EixamNotificationIntentType.deathManEscalated,
        planId: plan.id,
      );
      if (plan.autoTriggerSos) {
        await triggerSos(
          const SosTriggerPayload(triggerSource: 'death_man_protocol'),
        );
      }
      final expired = await _transitionDeathManPlanTo(
        escalated,
        DeathManStatus.expired,
      );
      if (expired != null) {
        _publishSdkEvent(
          DeathManStatusChangedEvent(plan.id, DeathManStatus.expired.name),
        );
      }
      _stopDeathManMonitoring();
    }
  }

  Future<DeathManPlan?> _transitionDeathManPlanTo(
    DeathManPlan plan,
    DeathManStatus next,
  ) async {
    if (!_canTransitionDeathManPlanTo(plan, next)) {
      return null;
    }
    try {
      return await deathManRepository.updatePlanStatus(plan.id, next);
    } on DeathManException catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'DMP transition persistence failed '
        'from=${plan.status.name} to=${next.name} code=${error.code}',
      );
      return null;
    }
  }

  bool _canTransitionDeathManPlanTo(DeathManPlan plan, DeathManStatus next) {
    try {
      DeathManStateMachine(initialState: plan.status).transitionTo(next);
      return true;
    } on DeathManException catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'DMP transition rejected '
        'from=${plan.status.name} to=${next.name} code=${error.code}',
      );
      return false;
    }
  }

  bool _shouldMonitorDeathManPlan(DeathManStatus status) {
    return status == DeathManStatus.scheduled ||
        status == DeathManStatus.monitoring ||
        status == DeathManStatus.overdue ||
        status == DeathManStatus.awaitingConfirmation;
  }

  Future<void> _handleRemoteRelaySosBackendHandoff(
    RemoteRelaySosSnapshot snapshot,
  ) async {
    snapshot = _normalizeRemoteRelaySosSnapshot(snapshot);
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS remote_relay_handoff_enter '
      'kind=${snapshot.kind.name} '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'source=${snapshot.source.name} '
      'sosType=${snapshot.sosType} '
      'payloadHex=${snapshot.payloadHex ?? "none"}',
    );
    if (snapshot.kind != RemoteRelaySosKind.sos) {
      if (_isRemoteRelayCancelSnapshot(snapshot)) {
        _logRemoteRelayTelClearDetected(snapshot);
        await _handleRemoteRelaySosCancelBackendHandoff(snapshot);
      }
      return;
    }
    final guardMatch = _resolveConnectedDeviceNodeGuardMatch();
    final connectedDeviceNodeId = guardMatch.nodeId;
    final hardwareId =
        _canonicalHardwareIdForStatus(_lastPublicDeviceStatus) ??
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
    final rearmKey = _externalRelayRearmKey(
      originatorNodeId: snapshot.originatorNodeId,
      relayNodeId: snapshot.relayNodeId,
    );
    final now = DateTime.now().toUtc();
    _remoteRelaySosBackendHandoffBySignature.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(minutes: 5),
    );
    _remoteRelaySosBackendHandoffInFlightBySignature.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(seconds: 30),
    );
    _externalRelayRearmedAtByKey.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(minutes: 5),
    );
    if (_remoteRelaySosBackendHandoffBySignature.containsKey(signature)) {
      BleDebugRegistry.instance.recordEvent(
        'REMOTE_RELAY_SOS_HANDOFF_DUPLICATE_SUPPRESSED_AFTER_SUCCESS '
        'signature=$signature '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"}',
      );
      _logSosTrace(
        'remote_backend_handoff_decision '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId ?? "none"} '
        'hasLocation=${snapshot.location != null} '
        'locationSource=none willAttemptBackend=false skipReason=duplicate',
      );
      if (_externalRelayRearmedAtByKey.containsKey(rearmKey)) {
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS external_trigger_blocked_after_cancel '
          'reason=duplicate_handoff_signature '
          'originatorNodeId=${snapshot.originatorNodeId} '
          'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"}',
        );
      }
      return;
    }
    if (_remoteRelaySosBackendHandoffInFlightBySignature.containsKey(
      signature,
    )) {
      _logSosTrace(
        'remote_backend_handoff_decision '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId ?? "none"} '
        'hasLocation=${snapshot.location != null} '
        'locationSource=none willAttemptBackend=false '
        'skipReason=in_flight',
      );
      return;
    }
    _remoteRelaySosBackendHandoffInFlightBySignature[signature] = now;
    BleDebugRegistry.instance.recordEvent(
      'REMOTE_RELAY_SOS_HANDOFF_IN_FLIGHT_SET '
      'signature=$signature '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"}',
    );
    if (_externalRelayRearmedAtByKey.remove(rearmKey) != null) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS external_trigger_allowed_after_cancel '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"}',
      );
    }

    final deviceId = _remoteRelayOriginatorDeviceId(snapshot);
    final relayNodeId = snapshot.relayNodeId ?? _lastDeviceStatus?.nodeId;
    final relayDeviceId = relayNodeId?.toString();
    final relayHardwareId = _lastDeviceStatus?.canonicalHardwareId;
    _rememberRecentExternalRelaySosContext(
      snapshot: snapshot,
      relayHardwareId: relayHardwareId,
      triggerDeviceId: deviceId,
    );
    final location = snapshot.location;
    final positionSnapshot = _hasValidRemoteRelayLocation(location)
        ? _remoteRelayBackendPosition(location: location!)
        : null;
    final livePacket = EixamSosPacket.tryParse(snapshot.rawPayload);
    final locationSource = positionSnapshot == null
        ? 'none'
        : (livePacket != null && livePacket.hasValidPosition
              ? 'packet_12b'
              : 'last_known');
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
    _logSosOriginDecision(
      source: 'remote_lora_relay',
      decision: const SosOriginDecision(
        actionability: SosActionability.externalOnly,
        originKind: SosOriginKind.remoteRelay,
        displaySurface: SosDisplaySurface.historyOnly,
        localStateMutation: false,
        publicIncident: false,
        backendPublish: true,
        reason: 'remote_lora_relay_backend_handoff',
      ),
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
      _remoteRelaySosBackendHandoffInFlightBySignature.remove(signature);
      BleDebugRegistry.instance.recordEvent(
        'REMOTE_RELAY_SOS_HANDOFF_IN_FLIGHT_CLEARED '
        'signature=$signature reason=success '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"}',
      );
      _remoteRelaySosBackendHandoffBySignature[signature] = DateTime.now()
          .toUtc();
      BleDebugRegistry.instance.recordEvent(
        'REMOTE_RELAY_SOS_HANDOFF_DEDUP_RECORDED_AFTER_SUCCESS '
        'signature=$signature '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"}',
      );
      _correlateRemoteRelayBackendIncident(
        snapshot: snapshot,
        backendIncidentId: backendResult.incidentId,
        relayHardwareId: relayHardwareId,
        acceptedTriggerDeviceId: deviceId,
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
      _remoteRelaySosBackendHandoffInFlightBySignature.remove(signature);
      BleDebugRegistry.instance.recordEvent(
        'REMOTE_RELAY_SOS_HANDOFF_IN_FLIGHT_CLEARED '
        'signature=$signature reason=failure '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"}',
      );
      BleDebugRegistry.instance.recordEvent(
        'REMOTE_RELAY_SOS_HANDOFF_DEDUP_NOT_RECORDED_ON_FAILURE '
        'signature=$signature '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
        'error=${_compactDiagnosticValue(error)}',
      );
      BleDebugRegistry.instance.recordEvent(
        'REMOTE_RELAY_SOS_HANDOFF_RETRY_ALLOWED_AFTER_FAILURE '
        'signature=$signature '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"}',
      );
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
          terminalReason: _remoteRelayTerminalReasonForError(error),
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
        dedupeKey:
            'external_sos_sent:'
            '${snapshot.originatorNodeId}:$relayNodeId:$dedupeToken',
        severity: EixamNotificationIntentSeverity.critical,
        incidentId: trimmedIncidentId,
        deviceId: snapshot.relayNodeId?.toString(),
        nodeId: snapshot.originatorNodeId,
        originatorNodeId: snapshot.originatorNodeId,
        relayNodeId: snapshot.relayNodeId,
        titleKey: 'notification.external_sos.sent.title',
        bodyKey: 'notification.external_sos.sent.body',
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

  void _emitExternalSosCancelledNotificationIntent({
    required RemoteRelaySosSnapshot snapshot,
    required String? deviceId,
    required String? incidentId,
  }) {
    final trimmedIncidentId = incidentId?.trim();
    final hasIncidentId =
        trimmedIncidentId != null && trimmedIncidentId.isNotEmpty;
    final relayNodeId = snapshot.relayNodeId?.toString() ?? 'none';
    final dedupeToken = hasIncidentId
        ? trimmedIncidentId
        : snapshot.receivedAt.toUtc().microsecondsSinceEpoch.toString();
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS external_cancel_notification_requested '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=$relayNodeId '
      'backendIncidentId=${trimmedIncidentId ?? "none"}',
    );
    _emitNotificationIntent(
      _buildNotificationIntent(
        type: EixamNotificationIntentType.sosCancelled,
        dedupeKey:
            'external_sos_cancelled:'
            '${snapshot.originatorNodeId}:$relayNodeId:$dedupeToken',
        severity: EixamNotificationIntentSeverity.info,
        incidentId: trimmedIncidentId,
        deviceId: deviceId,
        nodeId: snapshot.originatorNodeId,
        originatorNodeId: snapshot.originatorNodeId,
        relayNodeId: snapshot.relayNodeId,
        titleKey: 'notification.sos.cancelled.title',
        bodyKey: 'notification.sos.cancelled.body',
        shouldClearSosNotifications: true,
        payload: <String, String>{
          'source': 'remote_lora_relay',
          'terminal': 'cancelled',
          'externalOnly': 'true',
          'originatorNodeId': snapshot.originatorNodeId.toString(),
          if (snapshot.relayNodeId != null)
            'relayNodeId': snapshot.relayNodeId!.toString(),
          if (hasIncidentId) 'incidentId': trimmedIncidentId,
          'receivedAt': snapshot.receivedAt.toUtc().toIso8601String(),
        },
      ),
    );
  }

  Future<void> _showRemoteRelaySosNotification(
    RemoteRelaySosSnapshot snapshot,
  ) async {
    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS] notification_skipped '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'reason=notification_intents_only '
      'policy=${_notificationPolicyLabel(notificationPolicy)}',
    );
    BleDebugRegistry.instance.recordEvent(
      '[NOTIFICATION_FLOW] sdk_local_notification_skip '
      'type=${EixamNotificationIntentType.externalSosSent.name} '
      'reason=notificationIntentsOnly',
    );
  }

  bool _isRemoteRelayCancelSnapshot(RemoteRelaySosSnapshot snapshot) {
    return snapshot.kind == RemoteRelaySosKind.cancel ||
        snapshot.kind == RemoteRelaySosKind.clear;
  }

  RemoteRelaySosSnapshot _normalizeRemoteRelaySosSnapshot(
    RemoteRelaySosSnapshot snapshot,
  ) {
    final originatorNodeId = _normalizeNodeId(snapshot.originatorNodeId);
    final relayNodeId = _normalizeNodeIdOrNull(snapshot.relayNodeId);
    if (originatorNodeId == snapshot.originatorNodeId &&
        relayNodeId == snapshot.relayNodeId) {
      return snapshot;
    }
    return RemoteRelaySosSnapshot(
      kind: snapshot.kind,
      originatorNodeId: originatorNodeId,
      relayNodeId: relayNodeId,
      source: snapshot.source,
      sosType: snapshot.sosType,
      location: snapshot.location,
      receivedAt: snapshot.receivedAt,
      rawPayload: snapshot.rawPayload,
      payloadHex: snapshot.payloadHex,
      relayCount: snapshot.relayCount,
      eventOpcode: snapshot.eventOpcode,
      eventSubcode: snapshot.eventSubcode,
    );
  }

  void _logRemoteRelayTelClearDetected(RemoteRelaySosSnapshot snapshot) {
    if (snapshot.kind != RemoteRelaySosKind.clear && snapshot.sosType != 0) {
      return;
    }
    if (snapshot.source != RemoteRelaySosSource.telRelay) {
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS tel_clear_detected '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'sosType=${snapshot.sosType}',
    );
  }

  Future<void> _handleRemoteRelaySosCancelBackendHandoff(
    RemoteRelaySosSnapshot snapshot, {
    String? nativePendingSignature,
    String? relayHardwareIdOverride,
  }) async {
    snapshot = _normalizeRemoteRelaySosSnapshot(snapshot);
    final relayHardwareId =
        relayHardwareIdOverride ?? _lastDeviceStatus?.canonicalHardwareId;
    _rememberRecentExternalRelaySosContext(
      snapshot: snapshot,
      relayHardwareId: relayHardwareId,
    );
    final context = _recentExternalRelayContextForSnapshot(snapshot);
    final backendIncidentId = context?.backendIncidentId;
    BleDebugRegistry.instance.recordEvent(
      'REMOTE_RELAY_CANCEL_DETECT source=remote_relay_cancel_handoff '
      'status=external_context_allows_unknown_device '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'backendIncidentId=${backendIncidentId ?? "none"}',
    );
    final signature = _remoteRelaySosCancelHandoffSignature(
      snapshot: snapshot,
      backendIncidentId: backendIncidentId,
      relayHardwareId: relayHardwareId,
    );
    final now = DateTime.now().toUtc();
    _remoteRelaySosCancelSucceededBySignature.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(seconds: 30),
    );
    _remoteRelaySosCancelInFlightBySignature.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(seconds: 30),
    );
    if (_remoteRelaySosCancelSucceededBySignature.containsKey(signature)) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS cancel_dedupe_skip '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
        'relayHardwareId=${relayHardwareId ?? "none"} '
        'backendIncidentId=${backendIncidentId ?? "none"}',
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS pending_cancel_dedupe_skip '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
        'signature=$signature',
      );
      await _ackPendingExternalRelayCancelFromProtectionPlatform(
        nativePendingSignature,
      );
      return;
    }
    if (_remoteRelaySosCancelInFlightBySignature.containsKey(signature)) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS cancel_in_flight_skip '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
        'relayHardwareId=${relayHardwareId ?? "none"} '
        'backendIncidentId=${backendIncidentId ?? "none"}',
      );
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'SOS_ORIGIN_DECISION source=remote_lora_cancel '
      'actionability=externalOnly localStateMutation=false '
      'publicIncident=false backendCancel=true '
      'originatorNodeId=${snapshot.originatorNodeId}',
    );
    final resolvedIdentity = await _resolveRemoteRelayCancelDeviceId(
      snapshot: snapshot,
      context: context,
    );
    final deviceId = resolvedIdentity?.deviceId?.trim();
    if (resolvedIdentity == null || deviceId?.isEmpty == true) {
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS cancel_identity_missing '
        'originatorNodeId=${snapshot.originatorNodeId}',
      );
      _storePendingExternalRelayCancel(
        snapshot: snapshot,
        relayHardwareId: relayHardwareId,
        nativePendingSignature: nativePendingSignature,
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS pending_cancel_kept reason=identity_missing '
        'originatorNodeId=${snapshot.originatorNodeId}',
      );
      _publishRemoteRelaySosCancelHandoffResult(
        snapshot: snapshot,
        deviceId: null,
        status: RemoteRelaySosBackendHandoffStatus.skipped,
        reason: 'missing_device_id',
      );
      return;
    }
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS cancel_identity_resolved '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'hardwareId=${resolvedIdentity.source == "originator_hardware_id" ? deviceId : "none"} '
      'deviceId=${deviceId ?? "none"} identitySource=${resolvedIdentity.source} '
      'backendIncidentId=${backendIncidentId ?? "none"}',
    );

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
      _storePendingExternalRelayCancel(
        snapshot: snapshot,
        relayHardwareId: relayHardwareId,
        nativePendingSignature: nativePendingSignature,
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS pending_cancel_kept reason=backend_failure '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'detail=backend_transport_unavailable',
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS cancel_backend_failed_retry_kept '
        'httpStatus=none originatorNodeId=${snapshot.originatorNodeId} '
        'detail=backend_transport_unavailable',
      );
      return;
    }

    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS cancel_start '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"} '
      'backendIncidentId=${backendIncidentId ?? "none"}',
    );
    BleDebugRegistry.instance.recordEvent(
      'EXTERNAL_SOS cancel_payload '
      'deviceId=${deviceId ?? "none"} nodeId=${snapshot.originatorNodeId} '
      'originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'relayHardwareId=${relayHardwareId ?? "none"} '
      'incidentId=${backendIncidentId ?? "none"} '
      'source=remote_lora_relay triggerSource=remote_lora_relay '
      'relaySource=remote_lora_relay owner=device reason=remote_lora_cancel',
    );
    BleDebugRegistry.instance.recordEvent(
      '[REMOTE_RELAY_SOS] cancel_backend_payload '
      'deviceId=${deviceId ?? "none"} originatorNodeId=${snapshot.originatorNodeId} '
      'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
      'backendIncidentId=${backendIncidentId ?? "none"}',
    );

    _remoteRelaySosCancelInFlightBySignature[signature] = now;
    try {
      final cancelledIncident = await dataSource.cancelSos(
        deviceId: deviceId,
        source: 'remote_lora_relay',
        triggerSource: 'remote_lora_relay',
        relaySource: 'remote_lora_relay',
        originatorNodeId: snapshot.originatorNodeId,
        relayNodeId: snapshot.relayNodeId,
        relayHardwareId: relayHardwareId,
        incidentId: backendIncidentId,
      );
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] remote_cancel_handoff_success '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'deviceId=${deviceId ?? "none"}',
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS cancel_result httpStatus=none success=true '
        'responseIncidentId=${cancelledIncident?.id ?? "none"}'
        '${resolvedIdentity.source == "gateway_scope_fallback" ? " fallback=gateway_scope" : ""}',
      );
      _remoteRelaySosCancelInFlightBySignature.remove(signature);
      _remoteRelaySosCancelSucceededBySignature[signature] = DateTime.now()
          .toUtc();
      _remoteRelaySosCancelSucceededBySignature[_remoteRelaySosCancelHandoffSignature(
        snapshot: snapshot,
        backendIncidentId: null,
        relayHardwareId: relayHardwareId,
      )] = DateTime.now()
          .toUtc();
      final completedOriginatorNodeId = _normalizeNodeId(
        snapshot.originatorNodeId,
      );
      final completedRelayNodeId = _normalizeNodeIdOrNull(snapshot.relayNodeId);
      _pendingExternalRelayCancels.removeWhere((_, pending) {
        if (_normalizeNodeId(pending.snapshot.originatorNodeId) !=
            completedOriginatorNodeId) {
          return false;
        }
        final pendingRelayNodeId = _normalizeNodeIdOrNull(
          pending.snapshot.relayNodeId,
        );
        if (completedRelayNodeId != null &&
            pendingRelayNodeId != null &&
            pendingRelayNodeId != completedRelayNodeId) {
          return false;
        }
        return true;
      });
      await _ackPendingExternalRelayCancelFromProtectionPlatform(
        nativePendingSignature,
      );
      _rearmExternalRelayAfterCancelSuccess(
        snapshot: snapshot,
        backendIncidentId: backendIncidentId,
      );
      _publishSdkEvent(
        RemoteRelaySosCancelledEvent(
          originatorNodeId: snapshot.originatorNodeId,
          relayNodeId: snapshot.relayNodeId,
          backendIncidentId: backendIncidentId,
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS external_cancel_event_emitted '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'relayNodeId=${snapshot.relayNodeId?.toString() ?? "none"} '
        'backendIncidentId=${backendIncidentId ?? "none"} '
        'externalOnly=true terminal=cancelled',
      );
      _emitExternalSosCancelledNotificationIntent(
        snapshot: snapshot,
        deviceId: deviceId,
        incidentId: backendIncidentId ?? cancelledIncident?.id,
      );
      _publishRemoteRelaySosCancelHandoffResult(
        snapshot: snapshot,
        deviceId: deviceId,
        status: RemoteRelaySosBackendHandoffStatus.submitted,
      );
    } catch (error) {
      _remoteRelaySosCancelInFlightBySignature.remove(signature);
      final statusCode = error is SosHttpException ? error.statusCode : null;
      if (statusCode == 422 && backendIncidentId == null) {
        BleDebugRegistry.instance.recordEvent(
          'REMOTE_RELAY_CANCEL_DETECT source=remote_relay_cancel_handoff '
          'status=external_context_allows_unknown_device '
          'originatorNodeId=${snapshot.originatorNodeId} '
          'backendIncidentId=none action=pending_correlation',
        );
        _storePendingExternalRelayCancel(
          snapshot: snapshot,
          relayHardwareId: relayHardwareId,
          nativePendingSignature: nativePendingSignature,
        );
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS pending_cancel_kept reason=backend_failure '
          'originatorNodeId=${snapshot.originatorNodeId} '
          'detail=pending_backend_incident_correlation',
        );
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS cancel_backend_failed_retry_kept '
          'httpStatus=422 originatorNodeId=${snapshot.originatorNodeId}',
        );
        _publishRemoteRelaySosCancelHandoffResult(
          snapshot: snapshot,
          deviceId: deviceId,
          status: RemoteRelaySosBackendHandoffStatus.skipped,
          reason: 'pending_backend_incident_correlation',
          terminalReason: SosTerminalReason.relayTerminalRejected,
          errorMessage: error.toString(),
        );
        return;
      }
      final reason = _remoteRelaySosCancelFailureReason(error);
      BleDebugRegistry.instance.recordEvent(
        '[REMOTE_RELAY_SOS] remote_cancel_handoff_failed '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'statusCode=${statusCode ?? "-"} '
        'error=$error',
      );
      if (deviceId == null) {
        BleDebugRegistry.instance.recordEvent(
          'EXTERNAL_SOS remote_cancel_no_device_id_failed '
          'httpStatus=${statusCode?.toString() ?? "none"} '
          'originatorNodeId=${snapshot.originatorNodeId} '
          'backendIncidentId=${backendIncidentId ?? "none"} '
          'error=$error',
        );
      }
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS cancel_result '
        'httpStatus=${statusCode?.toString() ?? "none"} success=false '
        'responseIncidentId=none error=$error',
      );
      _storePendingExternalRelayCancel(
        snapshot: snapshot,
        relayHardwareId: relayHardwareId,
        nativePendingSignature: nativePendingSignature,
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS pending_cancel_kept reason=backend_failure '
        'originatorNodeId=${snapshot.originatorNodeId} '
        'httpStatus=${statusCode?.toString() ?? "none"}',
      );
      BleDebugRegistry.instance.recordEvent(
        'EXTERNAL_SOS cancel_backend_failed_retry_kept '
        'httpStatus=${statusCode?.toString() ?? "none"} '
        'originatorNodeId=${snapshot.originatorNodeId}',
      );
      _publishRemoteRelaySosCancelHandoffResult(
        snapshot: snapshot,
        deviceId: deviceId,
        status: RemoteRelaySosBackendHandoffStatus.failed,
        reason: reason,
        terminalReason: _remoteRelayTerminalReasonForError(error),
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

  SosTerminalReason _remoteRelayTerminalReasonForError(Object error) {
    if (error is SosHttpException && error.statusCode == 422) {
      return SosTerminalReason.relayTerminalRejected;
    }
    if (error is SosHttpException && error.statusCode == 400) {
      return SosTerminalReason.backendValidationFailed;
    }
    return SosTerminalReason.deliveryFailed;
  }

  void _publishRemoteRelaySosCancelHandoffResult({
    required RemoteRelaySosSnapshot snapshot,
    required String? deviceId,
    required RemoteRelaySosBackendHandoffStatus status,
    String? reason,
    SosTerminalReason? terminalReason,
    String? errorMessage,
  }) {
    _publishSdkEvent(
      RemoteRelaySosCancelHandoffResultEvent(
        originatorNodeId: snapshot.originatorNodeId,
        relayNodeId: snapshot.relayNodeId,
        deviceId: deviceId,
        status: status,
        reason: reason,
        terminalReason: terminalReason,
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
          triggerSource: relaySource,
          relaySource: relaySource,
          owner: 'device',
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
    return 'remote-relay-${_normalizeNodeId(snapshot.originatorNodeId)}-'
        '${snapshot.receivedAt.toUtc().microsecondsSinceEpoch}';
  }

  String _remoteRelayCycleCorrelation(RemoteRelaySosSnapshot snapshot) {
    final packet = EixamSosPacket.tryParse(snapshot.rawPayload);
    if (packet != null) {
      return '${_normalizeNodeId(snapshot.originatorNodeId)}:${packet.packetId}';
    }
    if (snapshot.eventOpcode != null) {
      return '${_normalizeNodeId(snapshot.originatorNodeId)}:event:'
          '${snapshot.eventOpcode}:${snapshot.eventSubcode ?? 0}';
    }
    return '${_normalizeNodeId(snapshot.originatorNodeId)}:unknown';
  }

  bool _admitRemoteRelayLifecycleEvidence(
    RemoteRelaySosSnapshot snapshot, {
    required String evidenceRoute,
  }) {
    final now = DateTime.now().toUtc();
    final expiredSignatures = _remoteRelayLifecycleAdmissionBySignature.entries
        .where(
          (entry) => now.difference(entry.value) > const Duration(seconds: 2),
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final expiredSignature in expiredSignatures) {
      _remoteRelayLifecycleAdmissionBySignature.remove(expiredSignature);
      _remoteRelayLifecycleAdmissionRouteBySignature.remove(expiredSignature);
    }
    final signature = <String>[
      snapshot.kind.name,
      _normalizeNodeId(snapshot.originatorNodeId).toString(),
      _normalizeNodeIdOrNull(snapshot.relayNodeId)?.toString() ?? 'none',
      _remoteRelayCycleCorrelation(snapshot),
      snapshot.payloadHex ?? EixamBleProtocol.hex(snapshot.rawPayload),
    ].join(':');
    final priorRoute =
        _remoteRelayLifecycleAdmissionRouteBySignature[signature];
    if (priorRoute != null && priorRoute != evidenceRoute) {
      return false;
    }
    _remoteRelayLifecycleAdmissionBySignature[signature] = now;
    _remoteRelayLifecycleAdmissionRouteBySignature[signature] = evidenceRoute;
    return true;
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
    final containsRemoteSos =
        expectedIncidentId != null &&
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
    return _normalizeNodeId(snapshot.originatorNodeId).toString();
  }

  bool _hasValidRemoteRelayLocation(TrackingPosition? location) {
    return location != null && location.hasValidFix;
  }

  TrackingPosition _remoteRelayBackendPosition({
    required TrackingPosition location,
  }) {
    return TrackingPosition(
      latitude: location.latitude,
      longitude: location.longitude,
      altitude: location.altitude,
      accuracy: location.accuracy,
      speed: location.speed,
      heading: location.heading,
      source: location.source,
      timestamp: location.timestamp.toUtc(),
    );
  }

  String _remoteRelaySosBackendHandoffSignature(
    RemoteRelaySosSnapshot snapshot,
  ) {
    return '${_normalizeNodeId(snapshot.originatorNodeId)}:'
        '${snapshot.sosType}:'
        '${_normalizeNodeIdOrNull(snapshot.relayNodeId)?.toString() ?? "none"}:'
        '${_lastDeviceStatus?.canonicalHardwareId ?? "none"}';
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
        event is RemoteRelaySosCancelledEvent ||
        event is RemoteRelaySosBackendHandoffResultEvent ||
        event is RemoteRelaySosCancelHandoffResultEvent;
  }

  bool _isBackendSosChannelAvailable() {
    if (sosRepository is MqttOperationalSosRepository) {
      // Operational MQTT publish establishes its connection on demand. A
      // temporarily disconnected realtime socket therefore does not make the
      // configured app SOS path unusable.
      return _session != null;
    }
    if (sosRepository is ApiSosRepository) {
      return _session != null;
    }
    return true;
  }

  bool _lifecycleAllowsNewSos(SosLifecycleSnapshot lifecycle) {
    return lifecycle.stage == SosLifecycleStage.idle ||
        lifecycle.stage == SosLifecycleStage.cancelled ||
        lifecycle.stage == SosLifecycleStage.resolved ||
        lifecycle.stage == SosLifecycleStage.activationFailed;
  }

  Future<SosCapabilitySnapshot> _buildSosCapability({
    required String reason,
  }) async {
    await _refreshNativeProtectionCommandReadiness(reason: reason);
    final route = _computeCurrentSosCapabilitySnapshot(
      reason: reason,
      recordDiagnostics: reason != 'lifecycle_change',
    );
    final lifecycle = _sosLifecycle.current;
    final authenticated = _session != null;
    final initialized = _sdkInitialized;
    final lifecycleAllowsActivation = _lifecycleAllowsNewSos(lifecycle);
    final appTransportReady = authenticated && route.backendAvailable;
    final deviceTransportReady =
        route.deviceConnected && route.deviceSosAvailable;
    PreferredDevice? preferred;
    try {
      preferred = await preferredDevice;
    } catch (_) {
      preferred = null;
    }
    final hasRegisteredDevice =
        preferred != null || _verifiedAssignedNodeIdsForSession.isNotEmpty;
    final locationAvailable =
        _lastResolvedLocation != null ||
        _bridgeDiagnostics.latestOwnDeviceLocation != null;
    final canTriggerAppSos =
        initialized && appTransportReady && lifecycleAllowsActivation;
    final canTriggerDeviceSos =
        initialized && deviceTransportReady && lifecycleAllowsActivation;
    final paths = <SosActivationPath>{
      if (canTriggerAppSos) SosActivationPath.appBackend,
      if (canTriggerDeviceSos) SosActivationPath.connectedDevice,
      if (lifecycle.isOpen) SosActivationPath.restoredActiveLifecycle,
    };
    final degraded = <SosCapabilityDegradedReason>{
      if (!hasRegisteredDevice) SosCapabilityDegradedReason.deviceNotRegistered,
      if (!route.deviceConnected)
        SosCapabilityDegradedReason.deviceDisconnected,
      if (route.deviceConnected && !route.shortCommandAvailable)
        SosCapabilityDegradedReason.commandChannelUnavailable,
      if (!locationAvailable) SosCapabilityDegradedReason.locationUnavailable,
    };
    final blockingReason = canTriggerAppSos || canTriggerDeviceSos
        ? null
        : !initialized
        ? SosCapabilityBlockingReason.initializing
        : !authenticated
        ? SosCapabilityBlockingReason.authenticationRequired
        : !lifecycleAllowsActivation
        ? SosCapabilityBlockingReason.lifecycleDoesNotAllowActivation
        : !appTransportReady && !hasRegisteredDevice
        ? SosCapabilityBlockingReason.appTransportUnavailable
        : !appTransportReady && !deviceTransportReady
        ? SosCapabilityBlockingReason.noActivationPath
        : SosCapabilityBlockingReason.appTransportUnavailable;
    final capability = SosCapabilitySnapshot(
      revision: lifecycle.revision,
      canTriggerAppSos: canTriggerAppSos,
      canTriggerDeviceSos: canTriggerDeviceSos,
      canCancelCurrentSos:
          lifecycle.isOpen &&
          (lifecycle.localActionable ||
              lifecycle.backendIncidentId != null ||
              lifecycle.localIncidentId != null) &&
          (appTransportReady ||
              deviceTransportReady ||
              lifecycle.stage == SosLifecycleStage.cancellationFailed),
      appTransportReady: appTransportReady,
      deviceTransportReady: deviceTransportReady,
      hasAuthenticatedSession: authenticated,
      hasRegisteredDevice: hasRegisteredDevice,
      hasConnectedDevice: route.deviceConnected,
      commandChannelReady: route.shortCommandAvailable,
      locationAvailable: locationAvailable,
      lifecycleAllowsActivation: lifecycleAllowsActivation,
      availableActivationPaths: Set<SosActivationPath>.unmodifiable(paths),
      preferredActivationPath: canTriggerAppSos
          ? SosActivationPath.appBackend
          : canTriggerDeviceSos
          ? SosActivationPath.connectedDevice
          : lifecycle.isOpen
          ? SosActivationPath.restoredActiveLifecycle
          : null,
      blockingReason: blockingReason,
      degradedReasons: Set<SosCapabilityDegradedReason>.unmodifiable(degraded),
      transient: !initialized,
      retryable:
          blockingReason == SosCapabilityBlockingReason.initializing ||
          blockingReason ==
              SosCapabilityBlockingReason.appTransportUnavailable ||
          blockingReason == SosCapabilityBlockingReason.noActivationPath,
    );
    return capability;
  }

  Future<void> _refreshNativeProtectionCommandReadiness({
    required String reason,
  }) async {
    // A rehydration publishes a protection status of its own. Do not let that
    // publication recursively start another native snapshot read when the
    // command path is still unavailable.
    if (reason.startsWith('protection_status:')) {
      return;
    }
    final status = _protectionModeController.currentStatus;
    if (status.modeState == ProtectionModeState.off ||
        status.bleOwner == ProtectionBleOwner.flutter ||
        _nativeCommandReadinessRefreshInFlight) {
      return;
    }
    final currentReadiness = _nativeCommandReadinessForStatus(status);
    if (currentReadiness.ready) {
      return;
    }
    _nativeCommandReadinessRefreshInFlight = true;
    try {
      final refreshed = await _protectionModeController.rehydrate();
      BleDebugRegistry.instance.recordEvent(
        'SOS_NATIVE_COMMAND_READINESS_REFRESH '
        'reason=$reason connected=${refreshed.serviceBleConnected} '
        'serviceReady=${refreshed.nativeCommandServiceReady} '
        'cmdEa04Ready=${refreshed.nativeCommandEa04Ready} '
        'identityReady=${refreshed.nativeCommandIdentityReady} '
        'queueHealthy=${refreshed.nativeCommandQueueHealthy} '
        'targetMatch=${_nativeProtectionTargetMatchesConnectedDevice(refreshed)} '
        'operationQueueOperational=${refreshed.lastCommandError?.trim().isNotEmpty != true}',
      );
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_NATIVE_COMMAND_READINESS_REFRESH_FAILED '
        'reason=$reason errorType=${error.runtimeType}',
      );
    } finally {
      _nativeCommandReadinessRefreshInFlight = false;
    }
  }

  void _logSosCapabilityEvaluation({
    required String source,
    required SosCapabilitySnapshot capability,
  }) {
    final signature = <Object?>[
      _sdkInitialized,
      capability.hasAuthenticatedSession,
      capability.appTransportReady,
      capability.deviceTransportReady,
      capability.hasRegisteredDevice,
      capability.hasConnectedDevice,
      capability.commandChannelReady,
      capability.locationAvailable,
      capability.lifecycleAllowsActivation,
      capability.canTriggerAppSos,
      capability.canTriggerDeviceSos,
      capability.canTriggerSos,
      capability.blockingReason,
      capability.transient,
      capability.preferredActivationPath,
    ].join('|');
    if (_lastSosCapabilityEvaluationSignature == signature) {
      return;
    }
    _lastSosCapabilityEvaluationSignature = signature;
    BleDebugRegistry.instance.recordEvent(
      'SOS_CAPABILITY_EVAL source=$source '
      'sdkInitialized=$_sdkInitialized '
      'authenticated=${capability.hasAuthenticatedSession} '
      'appTransportReady=${capability.appTransportReady} '
      'deviceTransportReady=${capability.deviceTransportReady} '
      'hasRegisteredDevice=${capability.hasRegisteredDevice} '
      'hasConnectedDevice=${capability.hasConnectedDevice} '
      'commandChannelReady=${capability.commandChannelReady} '
      'locationAvailable=${capability.locationAvailable} '
      'lifecycleAllowsActivation=${capability.lifecycleAllowsActivation} '
      'canTriggerAppSos=${capability.canTriggerAppSos} '
      'canTriggerDeviceSos=${capability.canTriggerDeviceSos} '
      'canTriggerSos=${capability.canTriggerSos} '
      'blockingReason=${capability.blockingReason?.name ?? "none"} '
      'transient=${capability.transient} '
      'selectedPath=${capability.preferredActivationPath?.name ?? "none"}',
    );
  }

  Future<void> _emitSosCapability({required String reason}) async {
    if (_sosCapabilityController.isClosed) {
      return;
    }
    final revision = ++_sosCapabilityEmissionRevision;
    final capability = await _buildSosCapability(reason: reason);
    if (revision == _sosCapabilityEmissionRevision &&
        !_sosCapabilityController.isClosed) {
      _logSosCapabilityEvaluation(source: reason, capability: capability);
      if (reason == 'native_command_readiness_changed' ||
          reason == 'native_owner_ready') {
        BleDebugRegistry.instance.recordEvent(
          'SOS_NATIVE_COMMAND_READINESS_PROPAGATED '
          'deviceTransportReady=${capability.deviceTransportReady} '
          'commandChannelReady=${capability.commandChannelReady} '
          'canTriggerDeviceSos=${capability.canTriggerDeviceSos}',
        );
      }
      _sosCapabilityController.add(capability);
    }
  }

  @override
  Future<SosCapabilitySnapshot> getSosCapability() async {
    final capability = await _buildSosCapability(reason: 'get_sos_capability');
    _logSosCapabilityEvaluation(
      source: 'get_sos_capability',
      capability: capability,
    );
    return capability;
  }

  @override
  Stream<SosCapabilitySnapshot> watchSosCapability() {
    return _seedThenReplayLiveStream<SosCapabilitySnapshot>(
      seed: getSosCapability,
      live: _sosCapabilityController.stream,
    );
  }

  @override
  Future<SosCapabilitySnapshot> retrySosCapability() async {
    final revision = ++_sosCapabilityEmissionRevision;
    await _refreshOperationalDiagnostics(
      trigger: 'retry_sos_capability',
      refreshRuntimeStatus: true,
    );
    await _warmResolvedLocationAfterPermissionGrant(
      reason: 'retry_sos_capability',
    );
    final capability = await _buildSosCapability(
      reason: 'retry_sos_capability_result',
    );
    _logSosCapabilityEvaluation(
      source: 'retry_sos_capability_result',
      capability: capability,
    );
    if (revision == _sosCapabilityEmissionRevision &&
        !_sosCapabilityController.isClosed) {
      _sosCapabilityController.add(capability);
    }
    return capability;
  }

  _CurrentSosCapabilitySnapshot _computeCurrentSosCapabilitySnapshot({
    required String reason,
    DeviceStatus? statusOverride,
    bool recordDiagnostics = true,
  }) {
    final backendAvailable = _isBackendSosChannelAvailable();
    final protectionStatus = _protectionModeController.currentStatus;
    final platformOwnsBle = _isProtectionPlatformOwningBle;
    final nativeCommandReadiness = _nativeCommandReadinessForStatus(
      protectionStatus,
    );
    final chosenConnected =
        statusOverride?.connected ?? _lastDeviceStatus?.connected;
    final flutterShortCommandPath = deviceSosController.shortCommandAvailable;
    final flutterLongCommandPath = deviceSosController.longCommandAvailable;
    final serviceBleConnected = platformOwnsBle
        ? protectionStatus.serviceBleConnected
        : null;
    final serviceBleReady = platformOwnsBle
        ? nativeCommandReadiness.ready
        : null;
    final deviceConnected = platformOwnsBle
        ? protectionStatus.deviceConnected ||
              protectionStatus.serviceBleConnected ||
              protectionStatus.serviceBleReady
        : (chosenConnected ?? false) ||
              flutterShortCommandPath ||
              flutterLongCommandPath;
    final shortCommandAvailable = platformOwnsBle
        ? nativeCommandReadiness.ready
        : flutterShortCommandPath;
    final longCommandAvailable = platformOwnsBle
        ? nativeCommandReadiness.ready
        : flutterLongCommandPath;
    final deviceSosAvailable = deviceConnected && shortCommandAvailable;
    final capability = backendAvailable
        ? (deviceSosAvailable
              ? SosDeliveryChannel.backendAndDevice
              : SosDeliveryChannel.backendOnly)
        : (deviceSosAvailable ? SosDeliveryChannel.deviceOnly : null);

    if (recordDiagnostics) {
      BleDebugRegistry.instance.recordEvent(
        '[SDK_SOS_CAPABILITY] recompute reason=$reason '
        'backendAvailable=$backendAvailable '
        'deviceConnected=$deviceConnected '
        'chosenConnected=${chosenConnected ?? false} '
        'serviceBleConnected=${serviceBleConnected ?? false} '
        'serviceBleReady=${serviceBleReady ?? false} '
        'nativeCommandReady=${nativeCommandReadiness.ready} '
        'nativeReadinessFailure=${nativeCommandReadiness.failure.name} '
        'shortCommandAvailable=$shortCommandAvailable '
        'longCommandAvailable=$longCommandAvailable '
        'result=${capability?.name ?? "unavailable"}',
      );
    }

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
    return status.copyWith(devicePaired: false, deviceConnected: false);
  }

  bool _protectionStatusIndicatesMissingMobileBond(ProtectionStatus status) {
    return <String?>[
      status.readinessFailureReason,
      status.degradationReason,
      status.lastCommandError,
    ].whereType<String>().any(
      (value) => value == 'E_DEVICE_MOBILE_BOND_REQUIRED',
    );
  }

  Future<void> _sendDeviceControlCommandThroughActiveOwner({
    required String action,
    required EixamDeviceCommand command,
  }) async {
    if (_isProtectionPlatformOwningBle &&
        !_isAuthoritativeNativeProtectionBleOwner) {
      _throwDeviceCommandNotReady();
    }
    if (!_isProtectionPlatformOwningBle) {
      await _ensureCommandCapableDeviceRepository(action: action);
    }
    await _sendDeviceCommandThroughActiveOwner(command);
  }

  void _validateDeviceVolume(int volume) {
    if (volume < 0 || volume > 100) {
      throw const DeviceException(
        'E_DEVICE_INVALID_VOLUME',
        'E_DEVICE_INVALID_VOLUME',
      );
    }
  }

  Never _throwDeviceCommandNotReady() {
    throw const DeviceException(
      'E_DEVICE_COMMAND_NOT_READY',
      'E_DEVICE_COMMAND_NOT_READY',
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
      backgroundTrackingState: _backgroundTrackingState,
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
      resolvedLocation:
          _lastResolvedLocation ?? _bridgeDiagnostics.latestOwnDeviceLocation,
      deviceCountryConfig: _lastDeviceCountryConfigStatus,
      bridge: _bridgeDiagnostics,
    );
  }

  _ProtectionSosPayloadReason _protectionSosPayloadReasonFromPlatformEvent(
    ProtectionPlatformEvent event,
  ) {
    final reason = _parseProtectionSosPayloadReason(event.reason);
    final payloadHex = reason.payloadHex ?? event.payloadHex?.trim();
    final source =
        reason.source ??
        (event.source == null
            ? null
            : _remoteRelaySourceFromPlatform(event.source!.trim()));
    final allowNativeOwnClassification =
        event.type == ProtectionPlatformEventType.ownDeviceSosLifecycleObserved;
    final identityOwn =
        reason.identityOwn ||
        allowNativeOwnClassification &&
            (event.classification == 'ownDeviceSos' ||
                event.classification == 'own_device');
    final identityUnknown =
        reason.identityUnknown ||
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

  _ProtectionSosPayloadReason _parseProtectionSosPayloadReason(String? reason) {
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
    final eventPacket = EixamSosEventPacket.tryParse(bytes);
    final sosPacket = EixamSosPacket.tryParse(bytes);
    return _protectionSosPayloadClassifier.classifySosPayload(
      payload: bytes,
      payloadHex: rawHex,
      receivedAt: DateTime.now().toUtc(),
      source: DeviceSosTransitionSource.device,
      channel: channel,
      connectedBleTagNodeId: forceUnknownIdentity
          ? null
          : relayNodeId ?? _knownLocalDeviceNodeId,
      hasRecentExternalRelayContext: eventPacket != null
          ? _recentExternalRelayContextForOriginatorNode(eventPacket.nodeId) !=
                null
          : sosPacket != null
          ? _recentExternalRelayContextForOriginatorNode(sosPacket.nodeId) !=
                null
          : false,
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
    if (sosPacket == null) {
      return null;
    }
    if (sosPacket.isClear) {
      final context = _recentExternalRelayContextForOriginatorNode(
        sosPacket.nodeId,
      );
      if (context == null) {
        return null;
      }
      return RemoteRelaySosSnapshot(
        kind: RemoteRelaySosKind.clear,
        originatorNodeId: context.originatorNodeId,
        relayNodeId: context.relayNodeId,
        source: source ?? RemoteRelaySosSource.telRelay,
        sosType: 0,
        receivedAt: DateTime.now().toUtc(),
        rawPayload: List<int>.unmodifiable(bytes),
        payloadHex: rawHex,
        relayCount: sosPacket.relayCount,
      );
    }
    final receivedAt = DateTime.now().toUtc();
    return RemoteRelaySosSnapshot(
      kind: RemoteRelaySosKind.sos,
      originatorNodeId: sosPacket.nodeId,
      relayNodeId: null,
      source: source ?? RemoteRelaySosSource.sosNotify,
      sosType: sosPacket.sosType,
      location:
          sosPacket.trackingPositionAt(receivedAt) ??
          _lastKnownTrackingPositionForNode(sosPacket.nodeId),
      receivedAt: receivedAt,
      rawPayload: List<int>.unmodifiable(bytes),
      payloadHex: rawHex,
      relayCount: sosPacket.relayCount,
    );
  }

  TrackingPosition? _lastKnownTrackingPositionForNode(int nodeId) {
    final own = _bridgeDiagnostics.latestOwnDeviceLocation;
    if (own != null && own.isValid && own.nodeId == nodeId) {
      return own.toTrackingPosition();
    }
    final last = _lastResolvedLocation;
    if (last != null && last.isValid && last.nodeId == nodeId) {
      return last.toTrackingPosition();
    }
    return null;
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

  void _emitOperationalDiagnostics({String reason = 'emit'}) {
    if (_operationalDiagnosticsController.isClosed) {
      return;
    }
    final diagnostics = _buildOperationalDiagnostics(reason: reason);
    _logCurrentSosCapabilityPublication(
      diagnostics: diagnostics,
      reason: reason,
    );
    _operationalDiagnosticsController.add(diagnostics);
    unawaited(_emitSosCapability(reason: reason));
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
    if (_disposed) {
      return;
    }
    _disposed = true;
    SosLocationTrace.emit('sdk_runtime', {
      'action': 'dispose_begin',
      'recurring_publication_owner': 'sdk',
    });
    await _stopBackgroundTelemetry(reason: 'dispose');
    _cancelProtectionDisconnectGraceTimer();
    WidgetsBinding.instance.removeObserver(this);
    _deathManTimer?.cancel();
    _foregroundSosReconciliationTimer?.cancel();
    _preSosSession?.timer.cancel();
    await _bleAutoReconnectCoordinator.dispose();
    await _realtimeConnectionSub?.cancel();
    await _realtimeEventsSub?.cancel();
    await _deviceStatusSub?.cancel();
    await _deviceSosSub?.cancel();
    await _deviceControlCommandPathSub?.cancel();
    await _sosStateSub?.cancel();
    await _mqttAcceptedSosLifecycleTransitionSub?.cancel();
    await _rejectedTerminalReconciliationSub?.cancel();
    await _bridgeDiagnosticsSub?.cancel();
    await _bleIncomingEventDiagnosticsSub?.cancel();
    await _devicePositionBacklogCoordinator.cancel();
    await _nearbyTextController.dispose();
    await _protectionStatusSub?.cancel();
    await _protectionRawSosEventsSub?.cancel();
    await _sosCapabilityLifecycleSub?.cancel();
    await _sosLocationOwnershipStatusSub?.cancel();
    await _nativeLocationSampleSub?.cancel();
    _nativeLocationSampleSub = null;
    await _bleOperationalRuntimeBridge.dispose();
    await _protectionModeController.dispose();
    await _sosLifecycle.dispose();
    await backgroundLocationPlatformAdapter.dispose();
    await _deviceCountryConfigStatusSub?.cancel();
    await _deviceCountryConfigController?.dispose();
    await _deviceProvisioningCoordinator?.dispose();
    await firmwareUpdateCoordinator?.dispose();
    await _operationalTelemetryCoordinator.stop();
    await _trackingOwnerArbiter.dispose();
    await deviceSosController.dispose();
    await realtimeClient.disconnect();
    await disposeCallback?.call();
    await _realtimeConnectionStateController.close();
    await _realtimeEventsController.close();
    await _operationalDiagnosticsController.close();
    await _deviceCountryConfigStatusController.close();
    await _sosCapabilityController.close();
    await _resolvedLocationController.close();
    await _devicePositionBatchController.close();
    await _bleNotificationNavigationController.close();
    await _publicDeviceStatusController.close();
    await _publicSosStateController.close();
    await _publicPreSosStatusController.close();
    await _notificationIntentController.close();
    await _eventsController.close();
    SosLocationTrace.emit('sdk_runtime', {
      'action': 'dispose_done',
      'recurring_publication_loops': 0,
      'ownership_accepting': false,
      'tracking_owners': 0,
    });
  }

  Future<EixamPermissionPreflightResult> _buildPermissionPreflight({
    required EixamPermissionRequirement requirement,
    required PermissionState state,
    required bool disclosureAcceptedNow,
    required bool disclosureDeclinedNow,
  }) async {
    final status = _permissionStatusForPurpose(requirement.purpose, state);
    final nativeAction =
        requirement.nativeAction ??
        _defaultNativeActionForPurpose(requirement.purpose);
    final alreadySatisfied = _isPermissionSatisfied(requirement.purpose, state);
    final texts = permissionDisclosureConfig.textsFor(requirement.purpose);
    final disclosure = EixamPermissionDisclosure.fromTexts(
      purpose: requirement.purpose,
      texts: texts,
      visibleFeatures: _visibleFeaturesForPurpose(requirement.purpose),
    );
    final ackMatchesCurrentStatus =
        disclosureAcceptedNow ||
        await _permissionDisclosureAckMatches(requirement, state);
    final requiresDisclosure =
        !alreadySatisfied && !ackMatchesCurrentStatus && !disclosureDeclinedNow;
    final nativePromptAllowed =
        alreadySatisfied || disclosureAcceptedNow || ackMatchesCurrentStatus;

    return EixamPermissionPreflightResult(
      requirement: requirement,
      permissionState: state,
      permissionStatus: status,
      nativeAction: nativeAction,
      nativePermissionAlreadySatisfied: alreadySatisfied,
      requiresDisclosure: requiresDisclosure,
      nativePromptAllowed: nativePromptAllowed,
      disclosure: requiresDisclosure || disclosureDeclinedNow
          ? disclosure
          : null,
      limitedFeatureMessage: alreadySatisfied
          ? null
          : texts.limitedFeatureMessage,
    );
  }

  SdkPermissionStatus _permissionStatusForPurpose(
    EixamPermissionPurpose purpose,
    PermissionState state,
  ) {
    return switch (purpose) {
      EixamPermissionPurpose.locationForeground ||
      EixamPermissionPurpose.locationBackground => state.location,
      EixamPermissionPurpose.nearbyDevicesBluetooth => state.bluetooth,
      EixamPermissionPurpose.notifications => state.notifications,
    };
  }

  bool _isPermissionSatisfied(
    EixamPermissionPurpose purpose,
    PermissionState state,
  ) {
    return switch (purpose) {
      EixamPermissionPurpose.locationForeground => state.hasLocationAccess,
      EixamPermissionPurpose.locationBackground => false,
      EixamPermissionPurpose.nearbyDevicesBluetooth => state.canUseBluetooth,
      EixamPermissionPurpose.notifications => state.hasNotificationAccess,
    };
  }

  EixamPermissionNativeAction _defaultNativeActionForPurpose(
    EixamPermissionPurpose purpose,
  ) {
    return switch (purpose) {
      EixamPermissionPurpose.locationForeground =>
        EixamPermissionNativeAction.requestLocationWhenInUse,
      EixamPermissionPurpose.locationBackground =>
        EixamPermissionNativeAction.openAppSettings,
      EixamPermissionPurpose.nearbyDevicesBluetooth =>
        EixamPermissionNativeAction.requestBluetoothNearbyDevices,
      EixamPermissionPurpose.notifications =>
        EixamPermissionNativeAction.requestNotifications,
    };
  }

  List<String> _visibleFeaturesForPurpose(EixamPermissionPurpose purpose) {
    return switch (purpose) {
      EixamPermissionPurpose.locationForeground => const <String>[
        'SOS',
        'safety status',
      ],
      EixamPermissionPurpose.locationBackground => const <String>[
        'SOS',
        'protection mode',
        'safety tracking',
        'connected TAG monitoring',
      ],
      EixamPermissionPurpose.nearbyDevicesBluetooth => const <String>[
        'TAG pairing',
        'device monitoring',
        'physical SOS trigger',
        'physical SOS cancel',
      ],
      EixamPermissionPurpose.notifications => const <String>[
        'SOS status',
        'device alerts',
        'protection events',
        'safety updates',
      ],
    };
  }

  Future<bool> _permissionDisclosureAckMatches(
    EixamPermissionRequirement requirement,
    PermissionState state,
  ) async {
    final acks = await _localStore.readJson(_permissionDisclosureAcksKey);
    final stored = acks?[_permissionDisclosureAckKey(requirement)];
    if (stored is! Map<String, dynamic>) {
      return false;
    }
    return stored['permissionSignature'] ==
        _permissionDisclosureSignature(requirement, state);
  }

  Future<void> _savePermissionDisclosureAck(
    EixamPermissionRequirement requirement,
    PermissionState state,
  ) async {
    final existing =
        await _localStore.readJson(_permissionDisclosureAcksKey) ??
        <String, dynamic>{};
    existing[_permissionDisclosureAckKey(requirement)] = <String, dynamic>{
      'permissionSignature': _permissionDisclosureSignature(requirement, state),
      'acceptedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await _localStore.saveJson(_permissionDisclosureAcksKey, existing);
  }

  String _permissionDisclosureAckKey(EixamPermissionRequirement requirement) {
    final featureKey = requirement.featureKey?.trim();
    if (featureKey == null || featureKey.isEmpty) {
      return requirement.purpose.name;
    }
    return '${requirement.purpose.name}:$featureKey';
  }

  String _permissionDisclosureSignature(
    EixamPermissionRequirement requirement,
    PermissionState state,
  ) {
    final status = _permissionStatusForPurpose(requirement.purpose, state);
    final service =
        requirement.purpose == EixamPermissionPurpose.nearbyDevicesBluetooth
        ? 'bt:${state.bluetoothEnabled}'
        : 'loc:${state.location != SdkPermissionStatus.serviceDisabled}';
    return '${requirement.purpose.name}:${status.name}:$service';
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

enum _SosDeviceMirrorState {
  synchronized,
  pendingCancel,
  pendingResolve,
  failed,
}

final class _TerminalConvergenceFence {
  const _TerminalConvergenceFence({
    required this.generation,
    required this.terminalState,
    required this.deviceId,
    required this.hardwareId,
    required this.nodeId,
    required this.runtimeCycleKey,
    required this.packetId,
    required this.packetSignature,
  });

  final int generation;
  final SosState terminalState;
  final String? deviceId;
  final String? hardwareId;
  final int? nodeId;
  final String? runtimeCycleKey;
  final int? packetId;
  final String? packetSignature;
}

final class _TerminalConvergenceStartEvaluation {
  const _TerminalConvergenceStartEvaluation({
    required this.fence,
    required this.incomingNodeId,
    required this.incomingCycleKey,
    required this.receiveSequence,
    required this.sameDevice,
    required this.sameCycle,
    required this.samePacketIdentity,
    required this.provenNewCycle,
    required this.suppress,
    required this.reason,
  });

  final _TerminalConvergenceFence fence;
  final int? incomingNodeId;
  final String? incomingCycleKey;
  final int receiveSequence;
  final bool sameDevice;
  final bool sameCycle;
  final bool samePacketIdentity;
  final bool provenNewCycle;
  final bool suppress;
  final String reason;
}

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

class _AppOriginMirroredPreSosBridge {
  const _AppOriginMirroredPreSosBridge({
    required this.cycleKey,
    required this.startedAt,
    required this.expectedActivationAt,
    required this.expiresAt,
    this.originatorNodeId,
    this.deviceId,
  });

  final String cycleKey;
  final DateTime startedAt;
  final DateTime expectedActivationAt;
  final DateTime expiresAt;
  final int? originatorNodeId;
  final String? deviceId;
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

class _AppOriginActiveSosBridge {
  const _AppOriginActiveSosBridge({
    required this.incidentId,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
    required this.lifecycleId,
    required this.generation,
    this.deviceId,
    this.runtimeCycleKey,
    this.nodeId,
    this.packetId,
  });

  final String incidentId;
  final SosState state;
  final DateTime createdAt;
  final DateTime expiresAt;
  final String lifecycleId;
  final int generation;
  final String? deviceId;
  final String? runtimeCycleKey;
  final int? nodeId;
  final int? packetId;

  _AppOriginActiveSosBridge copyWith({
    String? runtimeCycleKey,
    int? nodeId,
    int? packetId,
  }) => _AppOriginActiveSosBridge(
    incidentId: incidentId,
    state: state,
    createdAt: createdAt,
    expiresAt: expiresAt,
    lifecycleId: lifecycleId,
    generation: generation,
    deviceId: deviceId,
    runtimeCycleKey: runtimeCycleKey ?? this.runtimeCycleKey,
    nodeId: nodeId ?? this.nodeId,
    packetId: packetId ?? this.packetId,
  );
}

class _PhysicalSosTerminationTarget {
  const _PhysicalSosTerminationTarget({
    required this.lifecycleId,
    required this.generation,
    required this.ownerScope,
    required this.terminalState,
    required this.incidentId,
    required this.deviceId,
    required this.hardwareId,
    required this.nodeId,
    required this.runtimeCycleKey,
    required this.packetId,
    required this.packetSignature,
    required this.deviceActiveObservedAt,
    required this.activeReceiveSequence,
    required this.activeReceiveSequenceDomain,
    required this.capturedDevicePresent,
    required this.capturedCommandChannelReady,
    required this.capturedNativeGattConnected,
    required this.capturedOwner,
    required this.capturedIdentityMarker,
  });

  final String lifecycleId;
  final int generation;
  final String ownerScope;
  final SosState terminalState;
  final String incidentId;
  final String deviceId;
  final String hardwareId;
  final int? nodeId;
  final String? runtimeCycleKey;
  final int? packetId;
  final String? packetSignature;
  final DateTime deviceActiveObservedAt;
  final int? activeReceiveSequence;
  final String? activeReceiveSequenceDomain;
  final bool capturedDevicePresent;
  final bool capturedCommandChannelReady;
  final bool capturedNativeGattConnected;
  final String capturedOwner;
  final String capturedIdentityMarker;

  String get operationKey => '$lifecycleId:$generation:${terminalState.name}';
}

class _CapturedPhysicalDeviceConnection {
  const _CapturedPhysicalDeviceConnection({
    required this.device,
    required this.devicePresent,
    required this.shortCommandReady,
    required this.commandChannelReady,
    required this.nativeGattConnected,
    required this.owner,
    required this.identityMarker,
  });

  final DeviceStatus? device;
  final bool devicePresent;
  final bool shortCommandReady;
  final bool commandChannelReady;
  final bool nativeGattConnected;
  final String owner;
  final String identityMarker;
}

class _CanonicalNativeConnectionProof {
  const _CanonicalNativeConnectionProof({
    required this.physicalIdentity,
    required this.nativeOwner,
    required this.establishedAt,
    required this.sequence,
  });

  final String physicalIdentity;
  final ProtectionBleOwner nativeOwner;
  final DateTime establishedAt;
  final int sequence;
}

class _TerminalDeviceCaptureSnapshot {
  const _TerminalDeviceCaptureSnapshot({
    required this.connection,
    required this.deviceSos,
    required this.activePhysicalEvidence,
  });

  final _CapturedPhysicalDeviceConnection connection;
  final DeviceSosStatus deviceSos;
  final PhysicalSosReceiveEvidence? activePhysicalEvidence;
}

class _AppOriginDeviceOwnershipContext {
  const _AppOriginDeviceOwnershipContext({
    required this.lifecycleId,
    required this.generation,
    required this.ownerScope,
    required this.bridgeIncidentId,
    required this.deviceId,
    required this.hardwareId,
    required this.nodeId,
    required this.runtimeCycleKey,
    required this.packetId,
    required this.deviceActiveObservedAt,
  });

  final String lifecycleId;
  final int generation;
  final String ownerScope;
  final String bridgeIncidentId;
  final String deviceId;
  final String hardwareId;
  final int nodeId;
  final String runtimeCycleKey;
  final int packetId;
  final DateTime deviceActiveObservedAt;
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
    required this.activationPayload,
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
  final SosTriggerPayload activationPayload;
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
    SosTriggerPayload? activationPayload,
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
      activationPayload: activationPayload ?? this.activationPayload,
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

class _TerminalDeviceCycleFence {
  const _TerminalDeviceCycleFence({
    required this.generation,
    required this.nodeId,
    required this.runtimeCycleKey,
    required this.terminalBoundaryEventSequence,
    required this.inactiveBoundaryEventSequence,
    required this.inactiveBoundaryObservedAt,
    required this.consumedPacketSignatures,
  });

  final int generation;
  final int? nodeId;
  final String? runtimeCycleKey;
  final int terminalBoundaryEventSequence;
  final int? inactiveBoundaryEventSequence;
  final DateTime? inactiveBoundaryObservedAt;
  final Set<String> consumedPacketSignatures;
}

final class _FreshPhysicalStartProof {
  const _FreshPhysicalStartProof({
    required this.terminalGeneration,
    required this.receiveSequence,
    required this.receiveSequenceDomain,
    required this.terminalBoundaryFromPreviousProcess,
    required this.packetSignature,
  });

  final int terminalGeneration;
  final int receiveSequence;
  final String receiveSequenceDomain;
  final bool terminalBoundaryFromPreviousProcess;
  final String packetSignature;
}

class _ObservedOwnDeviceInactiveBoundary {
  const _ObservedOwnDeviceInactiveBoundary({
    required this.lifecycleGeneration,
    required this.eventSequence,
    required this.nodeId,
    required this.observedAt,
    required this.runtimeCycleKey,
    required this.terminalState,
    required this.previousState,
    required this.observedBeforeTerminal,
  });

  final int lifecycleGeneration;
  final int eventSequence;
  final int? nodeId;
  final DateTime observedAt;
  final String? runtimeCycleKey;
  final DeviceSosState terminalState;
  final DeviceSosState previousState;
  final bool observedBeforeTerminal;
}

class _PreSosTerminalCancelContext {
  const _PreSosTerminalCancelContext({
    required this.cycleKey,
    required this.originatorNodeId,
    required this.packetId,
    required this.startedAt,
    required this.expectedActivationAt,
    required this.observedAt,
    required this.expiresAt,
    required this.source,
  });

  final String? cycleKey;
  final int? originatorNodeId;
  final int? packetId;
  final DateTime? startedAt;
  final DateTime? expectedActivationAt;
  final DateTime observedAt;
  final DateTime expiresAt;
  final String source;
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

class _RecentExternalRelaySosContext {
  const _RecentExternalRelaySosContext({
    required this.originatorNodeId,
    required this.relayNodeId,
    required this.relayHardwareId,
    required this.backendIncidentId,
    required this.triggerDeviceId,
    required this.triggerObservedAt,
    required this.baselineTerminal,
    required this.baselineTerminalSignature,
    required this.baselineTerminalObservedAt,
    required this.baselineEventSequence,
    required this.expiresAt,
  });

  final int originatorNodeId;
  final int? relayNodeId;
  final String? relayHardwareId;
  final String? backendIncidentId;
  final String? triggerDeviceId;
  final DateTime triggerObservedAt;
  final String? baselineTerminal;
  final String? baselineTerminalSignature;
  final DateTime? baselineTerminalObservedAt;
  final int baselineEventSequence;
  final DateTime expiresAt;
}

class _RemoteRelayTerminalBaseline {
  const _RemoteRelayTerminalBaseline({
    required this.terminal,
    required this.signature,
    required this.observedAt,
    required this.eventSequence,
  });

  final String? terminal;
  final String? signature;
  final DateTime? observedAt;
  final int eventSequence;
}

class _PublicSosStateMachineBypass {
  const _PublicSosStateMachineBypass({
    required this.reason,
    required this.authority,
    required this.origin,
    required this.policy,
  });

  final String reason;
  final String authority;
  final String origin;
  final String policy;
}

class _RemoteRelayCancelDeviceIdentity {
  const _RemoteRelayCancelDeviceIdentity({
    required this.deviceId,
    required this.source,
  });

  final String? deviceId;
  final String source;
}

class _PendingExternalRelayCancel {
  const _PendingExternalRelayCancel({
    required this.snapshot,
    required this.relayHardwareId,
    required this.expiresAt,
    this.nativePendingSignature,
  });

  final RemoteRelaySosSnapshot snapshot;
  final String? relayHardwareId;
  final String? nativePendingSignature;
  final DateTime expiresAt;
}

Stream<T> _seedThenReplayLiveStream<T>({
  required FutureOr<T?> Function() seed,
  required Stream<T> live,
  bool emitNullSeed = true,
  bool Function(T previous, T next)? equals,
}) {
  late final StreamController<T> controller;
  StreamSubscription<T>? liveSubscription;
  final buffered = <_BufferedLiveEvent<T>>[];
  var seedDelivered = false;
  var liveDone = false;
  var cancelled = false;

  bool isDuplicate(T previous, T next) {
    return equals?.call(previous, next) ?? previous == next;
  }

  Future<void> closeIfDone() async {
    if (liveDone && !controller.isClosed) {
      await controller.close();
    }
  }

  Future<void> emitSeedAndBuffered() async {
    try {
      final seedValue = await Future<T?>.sync(seed);
      if (cancelled) {
        return;
      }
      seedDelivered = true;
      final shouldEmitSeed = seedValue != null || emitNullSeed;
      if (shouldEmitSeed) {
        controller.add(seedValue as T);
      }

      var hasLastEmitted = shouldEmitSeed;
      var lastEmitted = seedValue;
      for (final event in buffered) {
        if (cancelled || controller.isClosed) {
          return;
        }
        if (event.isError) {
          controller.addError(event.error!, event.stackTrace);
          continue;
        }
        final data = event.data as T;
        if (hasLastEmitted && isDuplicate(lastEmitted as T, data)) {
          lastEmitted = data;
          continue;
        }
        controller.add(data);
        hasLastEmitted = true;
        lastEmitted = data;
      }
      buffered.clear();
      await closeIfDone();
    } catch (error, stackTrace) {
      if (cancelled || controller.isClosed) {
        return;
      }
      buffered.clear();
      controller.addError(error, stackTrace);
      await liveSubscription?.cancel();
      await controller.close();
    }
  }

  controller = StreamController<T>(
    onListen: () {
      liveSubscription = live.listen(
        (event) {
          if (cancelled || controller.isClosed) {
            return;
          }
          if (!seedDelivered) {
            buffered.add(_BufferedLiveEvent<T>.data(event));
            return;
          }
          controller.add(event);
        },
        onError: (Object error, StackTrace stackTrace) {
          if (cancelled || controller.isClosed) {
            return;
          }
          if (!seedDelivered) {
            buffered.add(_BufferedLiveEvent<T>.error(error, stackTrace));
            return;
          }
          controller.addError(error, stackTrace);
        },
        onDone: () {
          liveDone = true;
          if (seedDelivered) {
            unawaited(closeIfDone());
          }
        },
      );
      unawaited(emitSeedAndBuffered());
    },
    onPause: () {
      liveSubscription?.pause();
    },
    onResume: () {
      liveSubscription?.resume();
    },
    onCancel: () async {
      cancelled = true;
      buffered.clear();
      await liveSubscription?.cancel();
      liveSubscription = null;
    },
  );

  return controller.stream;
}

class _BufferedLiveEvent<T> {
  const _BufferedLiveEvent.data(this.data) : error = null, stackTrace = null;

  const _BufferedLiveEvent.error(this.error, this.stackTrace) : data = null;

  final T? data;
  final Object? error;
  final StackTrace? stackTrace;

  bool get isError => error != null;
}

final class _PendingSosActivationOperation {
  _PendingSosActivationOperation({
    required this.generation,
    required this.lifecycleRevision,
    required this.operationRevision,
  });

  final int generation;
  final int lifecycleRevision;
  final int operationRevision;
  final Completer<void> dispatchResult = Completer<void>();
  bool cancelled = false;
  bool dispatchCommitted = false;
  bool cancellationRequested = false;
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
