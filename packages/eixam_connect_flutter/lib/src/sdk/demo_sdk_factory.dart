import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/datasources_local/sdk_session_store.dart';
import '../data/datasources_remote/sdk_contacts_remote_data_source.dart';
import '../data/datasources_remote/sdk_http_transport.dart';
import '../data/datasources_remote/sdk_session_context.dart';
import '../data/repositories/api_contacts_repository.dart';
import '../data/repositories/geolocator_tracking_repository.dart';
import '../data/repositories/in_memory_death_man_repository.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/in_memory_sdk_device_registry_repository.dart';
import '../data/repositories/in_memory_sos_repository.dart';
import '../data/repositories/in_memory_telemetry_repository.dart';
import '../data/repositories/local_notifications_repository.dart';
import '../data/repositories/platform_permissions_repository.dart';
import '../device/ble_device_runtime_provider.dart';
import '../device/ble_debug_registry.dart';
import '../device/real_ble_client.dart';
import 'eixam_connect_sdk_impl.dart';
import 'mock_realtime_client.dart';
import 'stable_app_device_id_store.dart';

/// Factory that wires a mostly local SDK instance for demos and development.
///
/// Emergency contacts are loaded from the backend SDK HTTP API when a
/// session is configured.
///
/// Important:
/// For now, demo bootstrap always starts with a clean SOS persisted state.
/// This avoids blocking the whole app because of stale or incompatible
/// SOS transitions stored locally during previous runs.
class DemoSdkFactory {
  static Future<EixamConnectSdk> create() async {
    BleDebugRegistry.instance.reset();

    final store = SharedPrefsSdkStore();
    final sessionStore = SdkSessionStore(localStore: store);
    final sessionContext = SdkSessionContext();
    final appDeviceIdStore = StableAppDeviceIdStore(localStore: store);
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
    final telemetryRepository = InMemoryTelemetryRepository();

    final deathManRepository = InMemoryDeathManRepository(localStore: store);

    final config = const EixamSdkConfig(
      apiBaseUrl: 'https://demo.eixam.local',
      websocketUrl: 'wss://demo.eixam.local/ws',
    );
    final httpClient = http.Client();
    final httpTransport = SdkHttpTransport(
      client: httpClient,
      config: config,
      sessionContext: sessionContext,
    );
    final contactsRepository = ApiContactsRepository(
      remoteDataSource: HttpSdkContactsRemoteDataSource(
        transport: httpTransport,
      ),
    );

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
    await deviceRepository.restoreState();

    final sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: telemetryRepository,
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deviceRegistryRepository: InMemorySdkDeviceRegistryRepository(),
      deathManRepository: deathManRepository,
      permissionsRepository: permissionsRepository,
      notificationsRepository: LocalNotificationsRepository(),
      realtimeClient: realtimeClient,
      guidedRescueRuntime: deviceRuntimeProvider,
      deviceSosController: deviceRuntimeProvider.deviceSosController,
      bleIncomingEvents: deviceRuntimeProvider.watchIncomingEvents(),
      preferredBleDeviceStore: preferredBleDeviceStore,
      sessionStore: sessionStore,
      sessionContext: sessionContext,
      stableAppDeviceIdProvider: appDeviceIdStore.getOrCreate,
    );

    await sdk.initialize(config);

    return sdk;
  }
}
