import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_remote/http_sos_remote_data_source.dart';
import '../data/datasources_remote/mock_sos_remote_data_source.dart';
import '../data/repositories/api_sos_repository.dart';
import '../data/repositories/geolocator_tracking_repository.dart';
import '../data/repositories/in_memory_contacts_repository.dart';
import '../data/repositories/in_memory_death_man_repository.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/local_notifications_repository.dart';
import '../data/repositories/platform_permissions_repository.dart';
import '../device/mock_device_runtime_provider.dart';
import 'eixam_connect_sdk_impl.dart';

/// Factory helpers for SDK instances that use a mock or real remote SOS API.
class ApiSdkFactory {
  static Future<EixamConnectSdk> createMockApi() async {
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
    final deviceRepository = InMemoryDeviceRepository(runtimeProvider: MockDeviceRuntimeProvider(), localStore: store);

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
    );

    await sdk.initialize(
      const EixamSdkConfig(
        apiBaseUrl: 'https://mock-api.eixam.local',
        websocketUrl: 'wss://mock-api.eixam.local/ws',
      ),
    );

    return sdk;
  }

  static Future<EixamConnectSdk> createHttp({
    required EixamSdkConfig config,
    String? authToken,
    http.Client? client,
  }) async {
    final store = SharedPrefsSdkStore();
    final permissionsRepository = PlatformPermissionsRepository();
    final sosRepository = ApiSosRepository(
      remoteDataSource: HttpSosRemoteDataSource(
        client: client ?? http.Client(),
        config: config,
        authToken: authToken,
      ),
      localStore: store,
    );
    final trackingRepository = GeolocatorTrackingRepository(
      permissionsRepository: permissionsRepository,
      localStore: store,
    );
    final deathManRepository = InMemoryDeathManRepository(localStore: store);
    final contactsRepository = InMemoryContactsRepository(localStore: store);
    final deviceRepository = InMemoryDeviceRepository(runtimeProvider: MockDeviceRuntimeProvider(), localStore: store);

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
    );

    await sdk.initialize(config);
    return sdk;
  }
}
