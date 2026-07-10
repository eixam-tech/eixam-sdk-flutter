import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../data/datasources_local/preferred_ble_device_store.dart';
import '../data/datasources_local/sdk_session_store.dart';
import '../data/datasources_remote/http_sos_remote_data_source.dart';
import '../data/datasources_remote/sdk_feedback_remote_data_source.dart';
import '../data/datasources_remote/sdk_identity_remote_data_source.dart';
import '../data/datasources_remote/sdk_profile_remote_data_source.dart';
import '../data/datasources_remote/sdk_session_context.dart';
import '../data/datasources_remote/sdk_contacts_remote_data_source.dart';
import '../data/datasources_remote/sdk_devices_remote_data_source.dart';
import '../data/datasources_remote/sdk_firmware_remote_data_source.dart';
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
import '../device/lazy_initializing_ble_client.dart';
import '../device/real_ble_client.dart';
import 'eixam_connect_sdk_impl.dart';
import 'firmware_dfu_transport_factory.dart';
import 'firmware_update_coordinator.dart';
import 'mqtt5_sdk_transport.dart';
import 'mqtt_realtime_client.dart';
import 'eixam_bootstrap_resolver.dart';
import 'protection_platform_adapter.dart';
import 'protection_platform_adapter_factory.dart';
import 'transport_security_validator.dart';

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
    required EixamNotificationTexts notificationTexts,
    EixamPermissionDisclosureConfig permissionDisclosureConfig =
        const EixamPermissionDisclosureConfig(),
    bool enableLogging = false,
    bool allowInsecureLocalEndpoints = false,
    bool deferRuntimeStartup = false,
  }) async {
    BleDebugRegistry.instance.reset();

    final store = SharedPrefsSdkStore();
    final sessionStore = SdkSessionStore(localStore: store);
    final sessionContext = SdkSessionContext();
    final preferredBleDeviceStore = PreferredBleDeviceStore(localStore: store);
    final bleClient = LazyInitializingBleClient(RealBleClient());
    final permissionsRepository = PlatformPermissionsRepository(
      bleClient: bleClient,
    );
    final config = EixamSdkConfig(
      apiBaseUrl: apiBaseUrl,
      websocketUrl: websocketUrl,
      enableLogging: enableLogging,
      allowInsecureLocalEndpoints: allowInsecureLocalEndpoints,
      deferRuntimeStartup: deferRuntimeStartup,
    );
    SdkTransportSecurityValidator.validateConfig(config);
    final httpClient = http.Client();
    final httpTransport = SdkHttpTransport(
      client: httpClient,
      config: config,
      sessionContext: sessionContext,
    );
    final profileRemoteDataSource =
        HttpSdkProfileRemoteDataSource(transport: httpTransport);
    final feedbackRemoteDataSource =
        HttpSdkFeedbackRemoteDataSource(transport: httpTransport);
    final firmwareRemoteDataSource =
        HttpSdkFirmwareRemoteDataSource(transport: httpTransport);
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

    late final EixamConnectSdkImpl sdk;
    sdk = EixamConnectSdkImpl(
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
      feedbackRemoteDataSource: feedbackRemoteDataSource,
      firmwareUpdateCoordinator: FirmwareUpdateCoordinator(
        deviceRepository: deviceRepository,
        sosRepository: sosRepository,
        deathManRepository: deathManRepository,
        remoteDataSource: firmwareRemoteDataSource,
        dfuTransport: buildDefaultFirmwareDfuTransport(),
        protectionStatusProvider: () => sdk.getProtectionStatus(),
        deviceSosStatusProvider:
            deviceRuntimeProvider.deviceSosController.getStatus,
        preSosStatusProvider: () => sdk.getPreSosStatus(),
        appLifecycleStateProvider: () => WidgetsBinding.instance.lifecycleState,
        prepareForDfuTransfer: ({required deviceId}) =>
            sdk.prepareForFirmwareDfuTransfer(deviceId: deviceId),
        releaseBleForDfuTransfer: ({required deviceId}) =>
            sdk.releaseBleForFirmwareDfuTransfer(deviceId: deviceId),
        restoreBleAfterDfuTransfer: ({required deviceId}) =>
            sdk.restoreBleAfterFirmwareDfuTransfer(deviceId: deviceId),
        postDfuStatusRefresh: ({
          required deviceId,
          required attempt,
          required targetVersion,
        }) =>
            sdk.refreshFirmwareDfuInstalledVersionStatus(
          deviceId: deviceId,
          attempt: attempt,
          targetVersion: targetVersion,
        ),
      ),
      notificationPolicy: notificationPolicy,
      notificationTexts: notificationTexts,
      permissionDisclosureConfig: permissionDisclosureConfig,
      protectionPlatformAdapter:
          protectionPlatformAdapter ?? buildDefaultProtectionPlatformAdapter(),
      disposeCallback: () async {
        httpClient.close();
        await contactsRepository.dispose();
        await trackingRepository.dispose();
        await deviceRepository.dispose();
        await deviceRuntimeProvider.dispose();
        await sosRepository.dispose();
        await realtimeClient.dispose();
        await BleDebugRegistry.instance.resetForLifecycle();
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
      notificationTexts: config.notificationTexts,
      permissionDisclosureConfig: config.permissionDisclosureConfig,
      enableLogging: resolved.sdkConfig.enableLogging,
      allowInsecureLocalEndpoints:
          resolved.sdkConfig.allowInsecureLocalEndpoints,
      deferRuntimeStartup: config.featureFlags['defer_runtime_startup'] == true,
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
      await sdk.setSession(
        initialSession,
        deferRuntimeWork: config.featureFlags['defer_runtime_startup'] == true,
      );
    }

    return sdk;
  }
}
