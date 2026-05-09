import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
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
      final localStore = MemorySharedPrefsSdkStore();
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

    test('start background telemetry is not duplicated for same session',
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

      expect(backgroundAdapter.startCallCount, 1);
      expect(backgroundAdapter.updateCallCount, 1);
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

      await sdk.clearSession();

      expect(backgroundAdapter.stopCallCount, greaterThanOrEqualTo(1));
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
  bool running = false;

  @override
  Future<void> startBackgroundTelemetry(
    BackgroundTelemetryStartRequest request,
  ) async {
    startCallCount++;
    running = true;
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
    running = false;
  }

  @override
  Future<BackgroundTelemetryDiagnostics>
      getBackgroundTelemetryDiagnostics() async {
    return BackgroundTelemetryDiagnostics(
      enabled: running,
      serviceRunning: running,
      permissionStatus: 'granted',
    );
  }
}
