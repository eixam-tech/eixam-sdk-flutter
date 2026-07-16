import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/device_config_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_device_config_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_geo_country_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('device country config lifecycle detection', () {
    test(
      'checks the backend on each disconnected-to-connected epoch',
      () async {
        final harness = _LifecycleHarness(
          initialStatus: buildDeviceStatus(
            connected: false,
            lifecycleState: DeviceLifecycleState.paired,
          ),
        );
        await harness.attachCommandChannel();
        await harness.initialize();
        await pumpEventQueue(times: 5);
        expect(harness.configSource.callCount, 0);

        harness.sdk.didChangeAppLifecycleState(AppLifecycleState.paused);
        harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue(times: 10);
        expect(harness.configSource.callCount, 0);

        harness.deviceRepository.emitStatus(buildDeviceStatus());
        await _waitUntil(() => harness.configSource.callCount == 1);

        harness.deviceRepository.emitStatus(
          buildDeviceStatus(
            connected: false,
            lifecycleState: DeviceLifecycleState.paired,
          ),
        );
        harness.deviceRepository.emitStatus(buildDeviceStatus());
        await _waitUntil(() => harness.configSource.callCount == 2);
        harness.deviceRepository.emitStatus(buildDeviceStatus());
        await pumpEventQueue(times: 5);
        expect(harness.configSource.callCount, 2);

        await harness.dispose();
      },
    );

    test('uses CMD readiness rather than the short INET SOS path', () async {
      final harness = _LifecycleHarness(initialStatus: buildDeviceStatus());
      await harness.initialize();
      await pumpEventQueue(times: 5);
      expect(harness.configSource.callCount, 0);

      await harness.deviceSosController.attach(
        commandWriter: (_) async {},
        shortCommandAvailable: true,
        longCommandAvailable: false,
      );
      await pumpEventQueue(times: 5);
      expect(harness.configSource.callCount, 0);

      await harness.deviceSosController.attach(
        commandWriter: (_) async {},
        shortCommandAvailable: true,
        longCommandAvailable: true,
      );
      await _waitUntil(() => harness.configSource.callCount == 1);

      await harness.dispose();
    });

    test('throttles resume checks per device for fifteen minutes', () async {
      final harness = _LifecycleHarness(initialStatus: buildDeviceStatus());
      await harness.attachCommandChannel();
      await harness.initialize();
      await _waitUntil(() => harness.configSource.callCount == 1);

      harness.sdk.didChangeAppLifecycleState(AppLifecycleState.paused);
      harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 10);
      expect(harness.configSource.callCount, 1);

      harness.advance(const Duration(minutes: 15));
      harness.sdk.didChangeAppLifecycleState(AppLifecycleState.paused);
      harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _waitUntil(() => harness.configSource.callCount == 2);

      harness.sdk.didChangeAppLifecycleState(AppLifecycleState.paused);
      harness.sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue(times: 10);
      expect(harness.configSource.callCount, 2);

      await harness.dispose();
    });
  });
}

class _LifecycleHarness {
  _LifecycleHarness({required DeviceStatus initialStatus})
    : now = DateTime.utc(2026, 1, 1, 10),
      trackingRepository = FakeTrackingRepository(
        currentPosition: TrackingPosition(
          latitude: 41.3874,
          longitude: 2.1686,
          timestamp: DateTime.now(),
          source: DeliveryMode.mobile,
        ),
      ),
      deviceRepository = FakeDeviceRepository(initialStatus: initialStatus) {
    sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
      deathManRepository: deathManRepository,
      permissionsRepository: FakePermissionsRepository(),
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: realtimeClient,
      deviceSosController: deviceSosController,
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: localStore),
      localStore: localStore,
      geoCountryRemoteDataSource: geoSource,
      deviceConfigRemoteDataSource: configSource,
      deviceConfigStore: DeviceConfigStore(localStore: localStore),
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
      clock: () => now,
    );
  }

  DateTime now;
  final FakeSosRepository sosRepository = FakeSosRepository();
  final FakeTrackingRepository trackingRepository;
  final FakeContactsRepository contactsRepository = FakeContactsRepository();
  final FakeDeviceRepository deviceRepository;
  final FakeDeathManRepository deathManRepository = FakeDeathManRepository();
  final FakeRealtimeClient realtimeClient = FakeRealtimeClient();
  final DeviceSosController deviceSosController = DeviceSosController();
  final MemorySharedPrefsSdkStore localStore = MemorySharedPrefsSdkStore();
  final _CountingGeoSource geoSource = _CountingGeoSource();
  final _CountingConfigSource configSource = _CountingConfigSource();
  late final EixamConnectSdkImpl sdk;

  void advance(Duration duration) {
    now = now.add(duration);
  }

  Future<void> attachCommandChannel() {
    return deviceSosController.attach(
      commandWriter: (_) async {},
      shortCommandAvailable: true,
      longCommandAvailable: true,
    );
  }

  Future<void> initialize() {
    return sdk.initialize(
      const EixamSdkConfig(
        apiBaseUrl: 'https://api.example.test',
        deferRuntimeStartup: true,
      ),
    );
  }

  Future<void> dispose() async {
    await sdk.dispose();
    await sosRepository.dispose();
    await trackingRepository.dispose();
    await contactsRepository.dispose();
    await deviceRepository.dispose();
    await deathManRepository.dispose();
    await realtimeClient.dispose();
  }
}

class _CountingGeoSource implements SdkGeoCountryRemoteDataSource {
  @override
  Future<ResolvedCountry> resolveCountry({
    required double latitude,
    required double longitude,
  }) async {
    return ResolvedCountry(
      countryIso: 'ES',
      latitude: latitude,
      longitude: longitude,
    );
  }
}

class _CountingConfigSource implements SdkDeviceConfigRemoteDataSource {
  int callCount = 0;

  @override
  Future<DeviceCountryConfig?> fetchByCountry({String? countryIso}) async {
    callCount += 1;
    return const DeviceCountryConfig(
      country: 'ES',
      deviceConfig: 'EU868',
      loraRegionByte: 3,
    );
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
