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

    test('restart adopts a genuinely active persisted session', () async {
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

    test('explicit enable is not duplicated for the same session', () async {
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

    test('notification stop becomes authoritative and is not restored',
        () async {
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

    test('explicit stop is idempotent', () async {
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
