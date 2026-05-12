import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/datasources_local/sdk_session_store.dart';
import '../data/datasources_remote/http_sos_remote_data_source.dart';
import '../data/datasources_remote/sdk_identity_remote_data_source.dart';
import '../data/datasources_remote/sdk_profile_remote_data_source.dart';
import '../data/datasources_remote/sdk_session_context.dart';
import '../data/datasources_remote/sdk_contacts_remote_data_source.dart';
import '../data/datasources_remote/sdk_devices_remote_data_source.dart';
import '../data/datasources_remote/sdk_http_transport.dart';
import '../data/repositories/api_contacts_repository.dart';
import '../data/repositories/api_sdk_device_registry_repository.dart';
import '../data/repositories/geolocator_tracking_repository.dart';
import '../data/repositories/in_memory_death_man_repository.dart';
import '../data/repositories/in_memory_device_repository.dart';
import '../data/repositories/local_notifications_repository.dart';
import '../data/repositories/mqtt_operational_sos_repository.dart';
import '../data/repositories/mqtt_telemetry_repository.dart';
import '../data/repositories/platform_permissions_repository.dart';
import '../device/ble_device_runtime_provider.dart';
import '../device/ble_debug_registry.dart';
import '../device/real_ble_client.dart';
import 'eixam_connect_sdk_impl.dart';
import 'mqtt5_sdk_transport.dart';
import 'mqtt_realtime_client.dart';
import 'eixam_bootstrap_resolver.dart';
import 'protection_platform_adapter.dart';
import 'protection_platform_adapter_factory.dart';

/// Factory helpers for API-backed SDK instances.
class ApiSdkFactory {
  /// Advanced constructor retained for controlled and internal setups.
  ///
  /// Partner apps should prefer `EixamConnectSdk.bootstrap(...)`.
  static Future<EixamConnectSdk> createHttpApi({
    required String apiBaseUrl,
    required String websocketUrl,
    ProtectionPlatformAdapter? protectionPlatformAdapter,
    EixamNotificationPolicy notificationPolicy =
        EixamNotificationPolicy.sdkManaged,
    bool enableLogging = false,
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
      enableLogging: enableLogging,
    );
    final httpClient = http.Client();
    final httpTransport = SdkHttpTransport(
      client: httpClient,
      config: config,
      sessionContext: sessionContext,
    );
    final profileRemoteDataSource =
        HttpSdkProfileRemoteDataSource(transport: httpTransport);
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

    final contactsRepository = ApiContactsRepository(
      remoteDataSource: HttpSdkContactsRemoteDataSource(
        transport: httpTransport,
      ),
    );

    final sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: telemetryRepository,
      contactsRepository: contactsRepository,
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
      deviceSosController: deviceRuntimeProvider.deviceSosController,
      bleIncomingEvents: deviceRuntimeProvider.watchIncomingEvents(),
      preferredBleDeviceStore: preferredBleDeviceStore,
      sessionStore: sessionStore,
      sessionContext: sessionContext,
      identityRemoteDataSource: HttpSdkIdentityRemoteDataSource(
        transport: httpTransport,
      ),
      profileRemoteDataSource: profileRemoteDataSource,
      notificationPolicy: notificationPolicy,
      protectionPlatformAdapter:
          protectionPlatformAdapter ?? buildDefaultProtectionPlatformAdapter(),
      disposeCallback: () async {
        httpClient.close();
        await contactsRepository.dispose();
        await sosRepository.dispose();
        await realtimeClient.dispose();
      },
    );

    await sdk.initialize(config);

    return sdk;
  }

  static Future<EixamConnectSdk> bootstrap(EixamBootstrapConfig config) async {
    final resolved = EixamBootstrapResolver.resolve(config);

    final sdk = await createHttpApi(
      apiBaseUrl: resolved.sdkConfig.apiBaseUrl,
      websocketUrl: resolved.sdkConfig.websocketUrl ?? '',
      notificationPolicy: config.notificationPolicy,
      enableLogging: resolved.sdkConfig.enableLogging,
    );

    final restoredSession = await sdk.getCurrentSession();
    if (!EixamBootstrapResolver.restoredSessionMatchesApp(
      restoredSession,
      resolved.appId,
    )) {
      await sdk.clearSession();
    }

    final initialSession = resolved.initialSession;
    if (initialSession != null) {
      await sdk.setSession(initialSession);
    }

    return sdk;
  }
}
