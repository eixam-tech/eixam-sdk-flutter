import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_geo_country_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_network_psk_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/provisioning/strict_device_provisioning_config.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/device/mock_ble_client.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('device assignment orchestration', () {
    late MockBleClient bleClient;
    late BleDeviceRuntimeProvider runtimeProvider;
    late InMemoryDeviceRepository deviceRepository;
    late FakeSdkDeviceRegistryRepository registryRepository;
    late EixamConnectSdkImpl sdk;

    setUp(() async {
      bleClient = MockBleClient();
      runtimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
      deviceRepository = InMemoryDeviceRepository(
        runtimeProvider: runtimeProvider,
      );
      registryRepository = FakeSdkDeviceRegistryRepository();
      final localStore = MemorySharedPrefsSdkStore();
      sdk = EixamConnectSdkImpl(
        sosRepository: FakeSosRepository(),
        trackingRepository: FakeTrackingRepository(),
        telemetryRepository: FakeTelemetryRepository(),
        contactsRepository: FakeContactsRepository(),
        deviceRepository: deviceRepository,
        deviceRegistryRepository: registryRepository,
        deathManRepository: FakeDeathManRepository(),
        permissionsRepository: FakePermissionsRepository(),
        notificationsRepository: FakeNotificationsRepository(),
        realtimeClient: FakeRealtimeClient(),
        deviceSosController: runtimeProvider.deviceSosController,
        bleIncomingEvents: runtimeProvider.watchIncomingEvents(),
        preferredBleDeviceStore: PreferredBleDeviceStore(
          localStore: localStore,
        ),
        sessionStore: SdkSessionStore(localStore: localStore),
        localStore: localStore,
        networkPskRemoteDataSource: const _UnusedPskSource(),
        provisioningConfigSource: const _UnusedConfigSource(),
        provisioningBackendUrl: 'https://api.example.test',
        geoCountryRemoteDataSource: const _UnusedGeoSource(),
        protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
        backgroundTelemetryPlatformAdapter:
            const NoopBackgroundTelemetryPlatformAdapter(),
        disposeCallback: () async {
          await deviceRepository.dispose();
          await runtimeProvider.dispose();
        },
      );
      await sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      );
      await sdk.setSession(
        const EixamSession.signed(
          appId: 'app-b',
          externalUserId: 'user-b',
          userHash: 'signed-hash',
        ),
      );
    });

    tearDown(() async {
      await sdk.dispose();
      await bleClient.dispose();
    });

    test(
        'already-provisioned unknown connection is claimed with assignment POST',
        () async {
      expect(registryRepository.upsertCallCount, 0);
      await sdk.connectDevice(pairingCode: MockBleClient.demoDeviceId);
      await Future<void>.delayed(Duration.zero);

      final result = await sdk.ensureDeviceReady();

      expect(result.disposition, DeviceReadyDisposition.ready);
      expect(registryRepository.upsertCallCount, 1);

      await sdk.getDeviceStatus();
      await sdk.refreshDeviceStatus();
      await sdk.activateDevice(activationCode: 'activate');
      await Future<void>.delayed(Duration.zero);
      expect(registryRepository.upsertCallCount, 1);
    });

    test('already-provisioned exact assignment is ready without POST',
        () async {
      registryRepository.devices.add(_registeredDevice('4660'));
      await sdk.connectDevice(pairingCode: MockBleClient.demoDeviceId);

      final result = await sdk.ensureDeviceReady();

      expect(result.disposition, DeviceReadyDisposition.ready);
      expect(registryRepository.upsertCallCount, 0);
    });
  });
}

BackendRegisteredDevice _registeredDevice(String hardwareId) {
  final timestamp = DateTime.utc(2026);
  return BackendRegisteredDevice(
    id: 'device-$hardwareId',
    hardwareId: hardwareId,
    firmwareVersion: '2.7.37',
    hardwareModel: 'EIXAM R1',
    pairedAt: timestamp,
    createdAt: timestamp,
    updatedAt: timestamp,
  );
}

final class _UnusedPskSource implements SdkNetworkPskRemoteDataSource {
  const _UnusedPskSource();

  @override
  Future<EffectiveNetworkPsk> fetchEffectivePsk() {
    throw StateError('PSK must not be fetched for an already-provisioned TAG.');
  }
}

final class _UnusedConfigSource
    implements StrictDeviceProvisioningConfigSource {
  const _UnusedConfigSource();

  @override
  Future<StrictDeviceProvisioningConfig> fetch({required String countryIso}) {
    throw StateError(
      'Configuration must not be fetched for an already-provisioned TAG.',
    );
  }
}

final class _UnusedGeoSource implements SdkGeoCountryRemoteDataSource {
  const _UnusedGeoSource();

  @override
  Future<ResolvedCountry> resolveCountry({
    required double latitude,
    required double longitude,
  }) {
    throw StateError(
      'Country must not be resolved for an already-provisioned TAG.',
    );
  }
}
