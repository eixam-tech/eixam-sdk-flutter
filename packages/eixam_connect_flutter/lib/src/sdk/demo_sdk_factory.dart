import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/repositories/geolocator_tracking_repository.dart';
import '../data/repositories/in_memory_contacts_repository.dart';
import '../data/repositories/in_memory_death_man_repository.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/in_memory_sos_repository.dart';
import '../data/repositories/local_notifications_repository.dart';
import '../data/repositories/platform_permissions_repository.dart';
import '../device/ble_device_runtime_provider.dart';
import '../device/ble_debug_registry.dart';
import '../device/real_ble_client.dart';
import 'eixam_connect_sdk_impl.dart';
import 'mock_realtime_client.dart';

/// Factory that wires a fully local SDK instance for demos and development.
///
/// Important:
/// For now, demo bootstrap always starts with a clean SOS persisted state.
/// This avoids blocking the whole app because of stale or incompatible
/// SOS transitions stored locally during previous runs.
class DemoSdkFactory {
  static Future<EixamConnectSdk> create() async {
    BleDebugRegistry.instance.reset();

    final store = SharedPrefsSdkStore();
    final preferredBleDeviceStore = PreferredBleDeviceStore(localStore: store);
    final permissionsRepository = PlatformPermissionsRepository();

    // Defensive demo bootstrap:
    // always clear persisted SOS state before creating the demo SDK.
    await store.remove(SharedPrefsSdkStore.sosStateKey);
    await store.remove(SharedPrefsSdkStore.sosIncidentKey);

    final sosRepository = InMemorySosRepository(localStore: store);

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

    final deviceRuntimeProvider =
        BleDeviceRuntimeProvider(bleClient: bleClient);
    final deviceRepository = InMemoryDeviceRepository(
      runtimeProvider: deviceRuntimeProvider,
      localStore: store,
    );

    final realtimeClient = MockRealtimeClient();

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
      bleIncomingEvents: deviceRuntimeProvider.watchIncomingEvents(),
      preferredBleDeviceStore: preferredBleDeviceStore,
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
