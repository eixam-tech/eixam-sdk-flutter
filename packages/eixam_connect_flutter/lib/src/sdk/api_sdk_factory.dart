import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/datasources_local/sdk_session_store.dart';
import '../data/datasources_remote/http_sos_remote_data_source.dart';
import '../data/datasources_remote/mock_sos_remote_data_source.dart';
import '../data/datasources_remote/sdk_identity_remote_data_source.dart';
import '../data/datasources_remote/sdk_session_context.dart';
import '../data/datasources_remote/sdk_contacts_remote_data_source.dart';
import '../data/datasources_remote/sdk_devices_remote_data_source.dart';
import '../data/datasources_remote/sdk_http_transport.dart';
import '../data/repositories/api_sos_repository.dart';
import '../data/repositories/api_contacts_repository.dart';
import '../data/repositories/api_sdk_device_registry_repository.dart';
import '../data/repositories/geolocator_tracking_repository.dart';
import '../data/repositories/in_memory_contacts_repository.dart';
import '../data/repositories/in_memory_death_man_repository.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/in_memory_sdk_device_registry_repository.dart';
import '../data/repositories/in_memory_telemetry_repository.dart';
import '../data/repositories/local_notifications_repository.dart';
import '../data/repositories/mqtt_operational_sos_repository.dart';
import '../data/repositories/mqtt_telemetry_repository.dart';
import '../data/repositories/platform_permissions_repository.dart';
import '../device/ble_device_runtime_provider.dart';
import '../device/ble_debug_registry.dart';
import '../device/mock_ble_client.dart';
import '../device/real_ble_client.dart';
import 'eixam_connect_sdk_impl.dart';
import 'mqtt5_sdk_transport.dart';
import 'mqtt_realtime_client.dart';
import 'mock_realtime_client.dart';
import 'protection_platform_adapter.dart';
import 'protection_platform_adapter_factory.dart';

/// Factory helpers for API-backed and mock-API-backed SDK instances.
class ApiSdkFactory {
  static Future<EixamConnectSdk> createMockApi() async {
    BleDebugRegistry.instance.reset();

    final store = SharedPrefsSdkStore();
    final sessionStore = SdkSessionStore(localStore: store);
    final sessionContext = SdkSessionContext();
    final preferredBleDeviceStore = PreferredBleDeviceStore(localStore: store);
    final permissionsRepository = PlatformPermissionsRepository();

    final sosRepository = ApiSosRepository(
      remoteDataSource: MockSosRemoteDataSource(),
      localStore: store,
    );

    final trackingRepository = GeolocatorTrackingRepository(
      permissionsRepository: permissionsRepository,
      localStore: store,
    );
    final telemetryRepository = InMemoryTelemetryRepository();

    final deathManRepository = InMemoryDeathManRepository(localStore: store);

    final contactsRepository = InMemoryContactsRepository(localStore: store);

    final bleClient = MockBleClient();
    await bleClient.initialize();

    final deviceRuntimeProvider =
        BleDeviceRuntimeProvider(bleClient: bleClient);
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
      protectionPlatformAdapter: buildDefaultProtectionPlatformAdapter(),
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
    ProtectionPlatformAdapter? protectionPlatformAdapter,
  }) async {
    BleDebugRegistry.instance.reset();

    final store = SharedPrefsSdkStore();
    final sessionStore = SdkSessionStore(localStore: store);
    final sessionContext = SdkSessionContext();
    final preferredBleDeviceStore = PreferredBleDeviceStore(localStore: store);
    final permissionsRepository = PlatformPermissionsRepository();
    final config = EixamSdkConfig(
      apiBaseUrl: apiBaseUrl,
      websocketUrl: websocketUrl,
    );
    final httpClient = http.Client();
    final httpTransport = SdkHttpTransport(
      client: httpClient,
      config: config,
      sessionContext: sessionContext,
    );
    final realtimeClient = MqttRealtimeClient(
      config: config,
      sessionContext: sessionContext,
      transportFactory: (request) => Mqtt5SdkTransport(
        request: request,
        enableLogging: config.enableLogging,
      ),
    );
    final sosRepository = MqttOperationalSosRepository(
      realtimeClient: realtimeClient,
      cancelRemoteDataSource: HttpSosRemoteDataSource(
        transport: httpTransport,
      ),
      localStore: store,
    );
    final telemetryRepository = MqttTelemetryRepository(
      realtimeClient: realtimeClient,
    );

    final trackingRepository = GeolocatorTrackingRepository(
      permissionsRepository: permissionsRepository,
      localStore: store,
    );

    final deathManRepository = InMemoryDeathManRepository(localStore: store);

    final bleClient = RealBleClient();
    try {
      await bleClient.initialize();
    } catch (_) {
      // Keep SDK bootstrap resilient even when BLE is temporarily unavailable.
    }

    final deviceRuntimeProvider =
        BleDeviceRuntimeProvider(bleClient: bleClient);
    final deviceRepository = InMemoryDeviceRepository(
      runtimeProvider: deviceRuntimeProvider,
      localStore: store,
    );

    await sosRepository.restoreState();
    await trackingRepository.restoreState();
    await deathManRepository.restoreState();
    await deviceRepository.restoreState();

    final sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: telemetryRepository,
      contactsRepository: ApiContactsRepository(
        remoteDataSource: HttpSdkContactsRemoteDataSource(
          transport: httpTransport,
        ),
      ),
      deviceRepository: deviceRepository,
      deviceRegistryRepository: ApiSdkDeviceRegistryRepository(
        remoteDataSource: HttpSdkDevicesRemoteDataSource(
          transport: httpTransport,
        ),
      ),
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
      identityRemoteDataSource: HttpSdkIdentityRemoteDataSource(
        transport: httpTransport,
      ),
      protectionPlatformAdapter:
          protectionPlatformAdapter ?? buildDefaultProtectionPlatformAdapter(),
      disposeCallback: () async {
        httpClient.close();
        await sosRepository.dispose();
        await realtimeClient.dispose();
      },
    );

    await sdk.initialize(config);

    return sdk;
  }
}
