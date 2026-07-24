import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('background telemetry orchestration', () {
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
    late FakeTelemetryRepository telemetryRepository;
    late FakeContactsRepository contactsRepository;
    late FakeDeviceRepository deviceRepository;
    late FakeSdkDeviceRegistryRepository deviceRegistryRepository;
    late FakeDeathManRepository deathManRepository;
    late FakePermissionsRepository permissionsRepository;
    late FakeNotificationsRepository notificationsRepository;
    late FakeRealtimeClient realtimeClient;
    late DeviceSosController deviceSosController;
    late _FakeBackgroundTelemetryAdapter backgroundAdapter;
    late MemorySharedPrefsSdkStore localStore;
    late EixamConnectSdkImpl sdk;

    setUp(() {
      sosRepository = FakeSosRepository();
      trackingRepository = FakeTrackingRepository(
        currentPosition: TrackingPosition(
          latitude: 41.38,
          longitude: 2.17,
          timestamp: DateTime.utc(2026, 1, 1),
          source: DeliveryMode.mobile,
        ),
      );
      telemetryRepository = FakeTelemetryRepository();
      contactsRepository = FakeContactsRepository();
      deviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(
          connected: false,
          paired: false,
          activated: false,
        ),
      );
      deviceRegistryRepository = FakeSdkDeviceRegistryRepository();
      deathManRepository = FakeDeathManRepository();
      permissionsRepository = FakePermissionsRepository();
      notificationsRepository = FakeNotificationsRepository();
      realtimeClient = FakeRealtimeClient();
      deviceSosController = DeviceSosController();
      backgroundAdapter = _FakeBackgroundTelemetryAdapter();
      localStore = MemorySharedPrefsSdkStore();
      sdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: telemetryRepository,
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: deviceRegistryRepository,
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationsRepository,
        realtimeClient: realtimeClient,
        deviceSosController: deviceSosController,
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: PreferredBleDeviceStore(
          localStore: localStore,
        ),
        sessionStore: SdkSessionStore(localStore: localStore),
        localStore: localStore,
        protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
        backgroundTelemetryPlatformAdapter: backgroundAdapter,
      );
    });

    tearDown(() async {
      await sdk.dispose();
      await sosRepository.dispose();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deviceRepository.dispose();
      await deathManRepository.dispose();
      await realtimeClient.dispose();
    });

    test('session initialization does not start background telemetry',
        () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );

      expect(backgroundAdapter.startCallCount, 0);
      expect(backgroundAdapter.running, isFalse);
    });

    test(
        'current Android semantics: initialization adopts an already-running '
        'native service', () async {
      const session = EixamSession.signed(
        appId: 'partner-app',
        externalUserId: 'user-1',
        userHash: 'hash-1',
      );
      await SdkSessionStore(localStore: localStore).save(session);
      backgroundAdapter.enabled = true;
      backgroundAdapter.running = true;

      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      final diagnostics = await sdk.getOperationalDiagnostics();

      expect(backgroundAdapter.startCallCount, 0);
      expect(backgroundAdapter.running, isTrue);
      expect(
        diagnostics.backgroundTrackingState,
        BackgroundTrackingState.activeForeground,
      );
    });

    test(
        'current Android semantics: duplicate enables share one global '
        'Boolean owner', () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );
      await sdk.enableBackgroundTelemetry();
      await sdk.enableBackgroundTelemetry();

      expect(backgroundAdapter.startCallCount, 1);
      expect(backgroundAdapter.updateCallCount, 0);
      expect(backgroundAdapter.startRequests.single.sosOpen, isFalse);
      expect(
        (await sdk.getOperationalDiagnostics()).backgroundTelemetryEnabled,
        isTrue,
      );
    });

    test(
        'current Android semantics: enabled-but-stopped native service is '
        'restarted during initialization', () async {
      const session = EixamSession.signed(
        appId: 'partner-app',
        externalUserId: 'user-1',
        userHash: 'hash-1',
      );
      await SdkSessionStore(localStore: localStore).save(session);
      backgroundAdapter.enabled = true;
      backgroundAdapter.running = false;

      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );

      expect(backgroundAdapter.startCallCount, 1);
      expect(backgroundAdapter.running, isTrue);
    });

    test(
        'current Android semantics: disabled and stopped service is not '
        'restarted during initialization', () async {
      await SdkSessionStore(localStore: localStore).save(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );

      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );

      expect(backgroundAdapter.startCallCount, 0);
      expect(backgroundAdapter.running, isFalse);
    });

    test('explicit enable waits for native running confirmation', () async {
      backgroundAdapter.diagnosticReadsUntilRunning = 2;
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );

      await sdk.enableBackgroundTelemetry();
      final diagnostics = await sdk.getOperationalDiagnostics();

      expect(backgroundAdapter.startCallCount, 1);
      expect(backgroundAdapter.running, isTrue);
      expect(
        diagnostics.backgroundTrackingState,
        BackgroundTrackingState.activeForeground,
      );
    });

    test('stop background telemetry is called on clearSession', () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );
      await sdk.enableBackgroundTelemetry();

      await sdk.clearSession();

      expect(backgroundAdapter.stopCallCount, greaterThanOrEqualTo(1));
      expect(backgroundAdapter.running, isFalse);
    });

    test(
        'current Android semantics: notification stop is authoritative and '
        'is not restored', () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      const session = EixamSession.signed(
        appId: 'partner-app',
        externalUserId: 'user-1',
        userHash: 'hash-1',
      );
      await sdk.setSession(session);
      await sdk.enableBackgroundTelemetry();

      backgroundAdapter.simulateNotificationStop();
      final stopped = await sdk.getOperationalDiagnostics();
      await sdk.setSession(session);
      deviceRepository.emitStatus(
        buildDeviceStatus(connected: true, paired: true, activated: true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(stopped.backgroundTrackingState, BackgroundTrackingState.stopped);
      expect(stopped.backgroundTelemetryEnabled, isFalse);
      expect(backgroundAdapter.startCallCount, 1);
      expect(backgroundAdapter.running, isFalse);
    });

    test('permission revocation produces a truthful blocked state', () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );
      await sdk.enableBackgroundTelemetry();

      backgroundAdapter.simulatePermissionRevocation();
      final diagnostics = await sdk.getOperationalDiagnostics();

      expect(
        diagnostics.backgroundTrackingState,
        BackgroundTrackingState.permissionBlocked,
      );
      expect(diagnostics.androidForegroundServiceRunning, isFalse);
    });

    test('start failure never reports tracking as active', () async {
      backgroundAdapter.failStart = true;
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );

      await sdk.enableBackgroundTelemetry();
      final diagnostics = await sdk.getOperationalDiagnostics();

      expect(
          diagnostics.backgroundTrackingState, BackgroundTrackingState.error);
      expect(diagnostics.androidForegroundServiceRunning, isFalse);
    });

    test(
        'current Android semantics: duplicate disables clear the one global '
        'Boolean owner idempotently', () async {
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );
      await sdk.enableBackgroundTelemetry();
      final stopCallsBeforeExplicitStop = backgroundAdapter.stopCallCount;

      await sdk.disableBackgroundTelemetry();
      await sdk.disableBackgroundTelemetry();

      expect(
        backgroundAdapter.stopCallCount,
        stopCallsBeforeExplicitStop + 1,
      );
      expect(
        (await sdk.getOperationalDiagnostics()).backgroundTrackingState,
        BackgroundTrackingState.stopped,
      );
      expect(
        (await sdk.getOperationalDiagnostics()).backgroundTelemetryEnabled,
        isFalse,
      );
    });

    test(
        'current Android semantics: open, cancelling, and terminal SOS update '
        'an already-running service without restarting or stopping it',
        () async {
      await _initializeWithSession(sdk);
      await sdk.enableBackgroundTelemetry();
      final startsAfterEnable = backgroundAdapter.startCallCount;
      final stopsAfterEnable = backgroundAdapter.stopCallCount;

      await sdk.triggerSos(
        const SosTriggerPayload(triggerSource: 'commercial_app'),
      );
      await pumpEventQueue(times: 3);
      await _emitRepositorySosState(sosRepository, SosState.cancelRequested);
      await _emitRepositorySosState(sosRepository, SosState.cancelled);

      expect(backgroundAdapter.sosOpenUpdates, <bool>[
        true,
        true,
        true,
        false,
      ]);
      expect(backgroundAdapter.startCallCount, startsAfterEnable);
      expect(backgroundAdapter.stopCallCount, stopsAfterEnable);
      expect(backgroundAdapter.running, isTrue);
      expect(
        (await sdk.getOperationalDiagnostics()).backgroundTelemetryEnabled,
        isTrue,
      );
    });

    test(
        'current Android semantics: cancelling retains SOS cadence while '
        'cancellation is pending', () async {
      await _initializeWithSession(sdk);
      await sdk.enableBackgroundTelemetry();

      await sdk.triggerSos(
        const SosTriggerPayload(triggerSource: 'commercial_app'),
      );
      await pumpEventQueue(times: 3);
      backgroundAdapter.sosOpenUpdates.clear();
      await _emitRepositorySosState(sosRepository, SosState.cancelRequested);

      expect(backgroundAdapter.sosOpenUpdates, <bool>[true]);
      expect(backgroundAdapter.running, isTrue);
    });

    test(
        'current Android semantics: duplicate SOS revisions do not duplicate '
        'native starts or updates', () async {
      await _initializeWithSession(sdk);
      await sdk.enableBackgroundTelemetry();
      final startsAfterEnable = backgroundAdapter.startCallCount;

      await sdk.triggerSos(
        const SosTriggerPayload(triggerSource: 'commercial_app'),
      );
      await pumpEventQueue(times: 3);
      final updatesAfterFirstRevision = backgroundAdapter.updateCallCount;
      await _emitRepositorySosState(sosRepository, SosState.sent);

      expect(backgroundAdapter.startCallCount, startsAfterEnable);
      expect(backgroundAdapter.updateCallCount, updatesAfterFirstRevision);
    });

    test(
        'current Android semantics: SOS state alone neither starts nor creates '
        'the foreground service', () async {
      await _initializeWithSession(sdk);
      final startsBeforeSos = backgroundAdapter.startCallCount;

      await sdk.triggerSos(
        const SosTriggerPayload(triggerSource: 'commercial_app'),
      );
      await pumpEventQueue(times: 3);

      expect(backgroundAdapter.startCallCount, startsBeforeSos);
      expect(backgroundAdapter.updateCallCount, 0);
      expect(backgroundAdapter.running, isFalse);
    });

    test('foreground interval is not paused after native background start',
        () async {
      BleDebugRegistry.instance.reset();

      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'hash-1',
        ),
      );
      await sdk.enableBackgroundTelemetry();

      final debugMessages = BleDebugRegistry.instance.currentState.events
          .map((event) => event.message)
          .toList();

      expect(backgroundAdapter.running, isTrue);
      expect(
        debugMessages,
        isNot(
          contains(
            '[SDK_TELEMETRY_LOOP] action=pause reason=native_background_owner',
          ),
        ),
      );
    });
  });
}

class _FakeBackgroundTelemetryAdapter
    implements BackgroundTelemetryPlatformAdapter {
  final List<BackgroundTelemetryStartRequest> startRequests =
      <BackgroundTelemetryStartRequest>[];
  final List<bool> sosOpenUpdates = <bool>[];
  int startCallCount = 0;
  int updateCallCount = 0;
  int stopCallCount = 0;
  bool enabled = false;
  bool running = false;
  bool failStart = false;
  int diagnosticReadsUntilRunning = 0;
  String permissionStatus = 'granted';
  String? lastError;

  @override
  Future<void> startBackgroundTelemetry(
    BackgroundTelemetryStartRequest request,
  ) async {
    startCallCount++;
    startRequests.add(request);
    if (failStart) {
      enabled = true;
      lastError = 'foreground_start_failed';
      throw StateError(lastError!);
    }
    enabled = true;
    running = diagnosticReadsUntilRunning == 0;
  }

  @override
  Future<void> updateBackgroundTelemetry({
    required bool sosOpen,
    String? deviceId,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
  }) async {
    updateCallCount++;
    sosOpenUpdates.add(sosOpen);
  }

  @override
  Future<void> stopBackgroundTelemetry() async {
    stopCallCount++;
    enabled = false;
    running = false;
  }

  @override
  Future<BackgroundTelemetryDiagnostics>
      getBackgroundTelemetryDiagnostics() async {
    if (enabled && diagnosticReadsUntilRunning > 0) {
      diagnosticReadsUntilRunning--;
      if (diagnosticReadsUntilRunning == 0) {
        running = true;
      }
    }
    return BackgroundTelemetryDiagnostics(
      enabled: enabled,
      serviceRunning: running,
      permissionStatus: permissionStatus,
      lastTelemetryError: lastError,
    );
  }

  void simulateNotificationStop() {
    enabled = false;
    running = false;
  }

  void simulatePermissionRevocation() {
    permissionStatus = 'location_missing';
    running = false;
  }

  @override
  Future<List<NativeBackgroundTelemetryItem>> peekQueuedBackgroundTelemetry({
    int limit = 25,
  }) async =>
      const <NativeBackgroundTelemetryItem>[];

  @override
  Future<bool> ackQueuedBackgroundTelemetry(String signature) async => false;

  @override
  Future<void> markQueuedBackgroundTelemetryFlushFailed(
    String signature, {
    required String error,
  }) async {}
}

Future<void> _initializeWithSession(EixamConnectSdkImpl sdk) async {
  await sdk.initialize(
    const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
  );
  await sdk.setSession(
    const EixamSession.signed(
      appId: 'partner-app',
      externalUserId: 'user-1',
      userHash: 'hash-1',
    ),
  );
}

Future<void> _emitRepositorySosState(
  FakeSosRepository repository,
  SosState state,
) async {
  repository.currentIncident = repository.currentIncident.copyWith(
    state: state,
    triggerSource: 'commercial_app',
  );
  repository.stateController.add(state);
  await pumpEventQueue(times: 3);
}
