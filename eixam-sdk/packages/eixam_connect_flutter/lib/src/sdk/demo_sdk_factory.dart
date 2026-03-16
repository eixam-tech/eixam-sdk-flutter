import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/repositories/geolocator_tracking_repository.dart';
import '../data/repositories/in_memory_contacts_repository.dart';
import '../data/repositories/in_memory_death_man_repository.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/in_memory_sos_repository.dart';
import '../data/repositories/local_notifications_repository.dart';
import '../data/repositories/platform_permissions_repository.dart';
import '../device/ble_device_runtime_provider.dart';
import '../device/mock_ble_client.dart';
import 'eixam_connect_sdk_impl.dart';

/// Factory that wires a fully local SDK instance for demos and development.
class DemoSdkFactory {
  static Future<EixamConnectSdk> create() async {
    final store = SharedPrefsSdkStore();
    final permissionsRepository = PlatformPermissionsRepository();
    final sosRepository = InMemorySosRepository(localStore: store);
    final trackingRepository = GeolocatorTrackingRepository(
      permissionsRepository: permissionsRepository,
      localStore: store,
    );
    final deathManRepository = InMemoryDeathManRepository(localStore: store);
    final contactsRepository = InMemoryContactsRepository(localStore: store);
    final bleClient = MockBleClient();
    await bleClient.initialize();
    final deviceRepository = InMemoryDeviceRepository(
      runtimeProvider: BleDeviceRuntimeProvider(bleClient: bleClient),
      localStore: store,
    );

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
        apiBaseUrl: 'https://demo.eixam.local',
        websocketUrl: 'wss://demo.eixam.local/ws',
      ),
    );

    return sdk;
  }
}
