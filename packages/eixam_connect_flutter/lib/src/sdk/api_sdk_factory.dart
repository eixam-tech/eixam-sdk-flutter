import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_remote/mock_sos_remote_data_source.dart';
import '../data/repositories/api_sos_repository.dart';
import '../data/repositories/geolocator_tracking_repository.dart';
import '../data/repositories/in_memory_contacts_repository.dart';
import '../data/repositories/in_memory_death_man_repository.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/local_notifications_repository.dart';
import '../data/repositories/platform_permissions_repository.dart';
import '../device/ble_device_runtime_provider.dart';
import '../device/ble_debug_registry.dart';
import '../device/mock_ble_client.dart';
import '../device/real_ble_client.dart';
import 'eixam_connect_sdk_impl.dart';
import 'mock_realtime_client.dart';

/// Factory helpers for API-backed and mock-API-backed SDK instances.
///
/// For now both factory methods use mock SOS remote data while the realtime
/// layer and SDK plumbing are stabilized. The HTTP remote datasource can be
/// reintroduced once its constructor contract is confirmed.
class ApiSdkFactory {
  static Future<EixamConnectSdk> createMockApi() async {
    BleDebugRegistry.instance.reset();

    final store = SharedPrefsSdkStore();
    final permissionsRepository = PlatformPermissionsRepository();

    final sosRepository = ApiSosRepository(
      remoteDataSource: MockSosRemoteDataSource(),
      localStore: store,
    );

    final trackingRepository = GeolocatorTrackingRepository(
      permissionsRepository: permissionsRepository,
      localStore: store,
    );

    final deathManRepository = InMemoryDeathManRepository(localStore: store);

    final contactsRepository = InMemoryContactsRepository(localStore: store);

    final bleClient = MockBleClient();
    await bleClient.initialize();

    final deviceRuntimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
    final deviceRepository = InMemoryDeviceRepository(
      runtimeProvider: deviceRuntimeProvider,
      localStore: store,
    );

    final realtimeClient = MockRealtimeClient();

    await sosRepository.restoreState();
    await trackingRepository.restoreState();
    await deathManRepository.restoreState();
    await contactsRepository.restoreState();
    await deviceRepository.restoreState();

    final sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deathManRepository: deathManRepository,
      permissionsRepository: permissionsRepository,
      notificationsRepository: LocalNotificationsRepository(),
      realtimeClient: realtimeClient,
      deviceSosController: deviceRuntimeProvider.deviceSosController,
    );

    await sdk.initialize(
      const EixamSdkConfig(
        apiBaseUrl: 'https://demo.eixam.local',
        websocketUrl: 'wss://demo.eixam.local/ws',
      ),
    );

    return sdk;
  }

  static Future<EixamConnectSdk> createHttpApi({
    required String apiBaseUrl,
    required String websocketUrl,
  }) async {
    BleDebugRegistry.instance.reset();

    final store = SharedPrefsSdkStore();
    final permissionsRepository = PlatformPermissionsRepository();

    // Temporary mock fallback until the real HTTP datasource constructor
    // is confirmed and aligned with the SDK.
    final sosRepository = ApiSosRepository(
      remoteDataSource: MockSosRemoteDataSource(),
      localStore: store,
    );

    final trackingRepository = GeolocatorTrackingRepository(
      permissionsRepository: permissionsRepository,
      localStore: store,
    );

    final deathManRepository = InMemoryDeathManRepository(localStore: store);

    final contactsRepository = InMemoryContactsRepository(localStore: store);

    final bleClient = RealBleClient();
    try {
      await bleClient.initialize();
    } catch (_) {
      // no tombis l'app al bootstrap
    }

    final deviceRuntimeProvider = BleDeviceRuntimeProvider(bleClient: bleClient);
    final deviceRepository = InMemoryDeviceRepository(
      runtimeProvider: deviceRuntimeProvider,
      localStore: store,
    );

    final realtimeClient = MockRealtimeClient();

    await sosRepository.restoreState();
    await trackingRepository.restoreState();
    await deathManRepository.restoreState();
    await contactsRepository.restoreState();
    await deviceRepository.restoreState();

    final sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deathManRepository: deathManRepository,
      permissionsRepository: permissionsRepository,
      notificationsRepository: LocalNotificationsRepository(),
      realtimeClient: realtimeClient,
      deviceSosController: deviceRuntimeProvider.deviceSosController,
    );

    await sdk.initialize(
      EixamSdkConfig(apiBaseUrl: apiBaseUrl, websocketUrl: websocketUrl),
    );

    return sdk;
  }
}
