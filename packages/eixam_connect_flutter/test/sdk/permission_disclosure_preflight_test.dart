import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/local_notifications_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();

  group('permission disclosure preflight', () {
    late FakePermissionsRepository permissionsRepository;
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
    late FakeContactsRepository contactsRepository;
    late FakeDeviceRepository deviceRepository;
    late FakeDeathManRepository deathManRepository;
    late FakeRealtimeClient realtimeClient;
    late FakeNotificationsRepository notificationsRepository;
    late EixamConnectSdkImpl sdk;

    void createSdk({
      EixamNotificationPolicy notificationPolicy =
          EixamNotificationPolicy.sdkManaged,
      NotificationsRepository? notificationAdapter,
    }) {
      permissionsRepository = FakePermissionsRepository(
        permissionState: const PermissionState(
          location: SdkPermissionStatus.denied,
          notifications: SdkPermissionStatus.denied,
          bluetooth: SdkPermissionStatus.denied,
          bluetoothEnabled: true,
        ),
      );
      sosRepository = FakeSosRepository();
      trackingRepository = FakeTrackingRepository();
      contactsRepository = FakeContactsRepository();
      deviceRepository = FakeDeviceRepository(
        initialStatus: buildDeviceStatus(),
      );
      deathManRepository = FakeDeathManRepository();
      realtimeClient = FakeRealtimeClient();
      notificationsRepository = FakeNotificationsRepository();
      final localStore = MemorySharedPrefsSdkStore();
      sdk = EixamConnectSdkImpl(
        sosRepository: sosRepository,
        trackingRepository: trackingRepository,
        telemetryRepository: FakeTelemetryRepository(),
        contactsRepository: contactsRepository,
        deviceRepository: deviceRepository,
        deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
        deathManRepository: deathManRepository,
        permissionsRepository: permissionsRepository,
        notificationsRepository: notificationAdapter ?? notificationsRepository,
        notificationPolicy: notificationPolicy,
        realtimeClient: realtimeClient,
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: PreferredBleDeviceStore(
          localStore: localStore,
        ),
        localStore: localStore,
        protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
        backgroundTelemetryPlatformAdapter:
            const NoopBackgroundTelemetryPlatformAdapter(),
      );
    }

    Future<void> disposeSdk() async {
      await sdk.dispose();
      await sosRepository.dispose();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deviceRepository.dispose();
      await deathManRepository.dispose();
      await realtimeClient.dispose();
    }

    setUp(createSdk);

    tearDown(disposeSdk);

    test(
      'iOS host receives activity taps after SDK permission request',
      () async {
        await disposeSdk();
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final previousPlatform = FlutterLocalNotificationsPlatform.instance;
        FlutterLocalNotificationsPlatform.instance =
            IOSFlutterLocalNotificationsPlugin();
        const channel = MethodChannel(
          'dexterous.com/flutter/local_notifications',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getNotificationAppLaunchDetails') {
            return <String, Object?>{'notificationLaunchedApp': false};
          }
          return true;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          channel.setMethodCallHandler(null);
          FlutterLocalNotificationsPlatform.instance = previousPlatform;
          debugDefaultTargetPlatformOverride = null;
        });
        final responses = <NotificationResponse>[];
        final plugin = FlutterLocalNotificationsPlugin();
        await plugin.initialize(
          settings: const InitializationSettings(
            iOS: DarwinInitializationSettings(
              requestAlertPermission: false,
              requestBadgePermission: false,
              requestSoundPermission: false,
            ),
          ),
          onDidReceiveNotificationResponse: responses.add,
        );
        createSdk(
          notificationPolicy: EixamNotificationPolicy.hostAppManaged,
          notificationAdapter: LocalNotificationsRepository(plugin: plugin),
        );

        await sdk.requestNotificationPermission();
        await messenger.handlePlatformMessage(
          channel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall(
              'didReceiveNotificationResponse',
              <String, Object?>{
                'notificationId': 44001,
                'payload': 'activity',
                'notificationResponseType': 0,
              },
            ),
          ),
          (_) {},
        );

        expect(responses, hasLength(1));
        expect(responses.single.payload, 'activity');
        expect(permissionsRepository.requestNotificationPermissionCallCount, 1);
      },
    );

    test(
      'host-managed permission request preserves the host tap handler',
      () async {
        await disposeSdk();
        createSdk(notificationPolicy: EixamNotificationPolicy.hostAppManaged);

        final result = await sdk.requestNotificationPermission();

        expect(result, same(permissionsRepository.permissionState));
        expect(permissionsRepository.requestNotificationPermissionCallCount, 1);
        // The local notification adapter initializes its plugin when requesting
        // permission, replacing the process-wide host response callback.
        expect(notificationsRepository.requestPermissionCallCount, 0);
        expect(notificationsRepository.initializeCallCount, 0);
      },
    );

    test(
      'SDK-managed permission request retains notification initialization',
      () async {
        await sdk.requestNotificationPermission();

        expect(notificationsRepository.requestPermissionCallCount, 1);
        expect(permissionsRepository.requestNotificationPermissionCallCount, 1);
      },
    );

    test('returns disclosure before native permission request', () async {
      final result = await sdk.preparePermissionPreflight(
        const EixamPermissionRequirement.locationForeground(),
      );

      expect(result.requiresDisclosure, isTrue);
      expect(result.nativePromptAllowed, isFalse);
      expect(result.disclosure?.title, 'Allow location for SOS');
    });

    test('declining disclosure does not allow native prompt', () async {
      final result = await sdk.declinePermissionDisclosure(
        const EixamPermissionRequirement.nearbyDevicesBluetooth(),
      );

      expect(result.requiresDisclosure, isFalse);
      expect(result.nativePromptAllowed, isFalse);
      expect(result.limitedFeatureMessage, contains('TAG pairing'));
    });

    test(
      'accepted disclosure is not repeated while permission status matches',
      () async {
        await sdk.acceptPermissionDisclosure(
          const EixamPermissionRequirement.notifications(),
        );

        final result = await sdk.preparePermissionPreflight(
          const EixamPermissionRequirement.notifications(),
        );

        expect(result.requiresDisclosure, isFalse);
        expect(result.nativePromptAllowed, isTrue);
        expect(result.nativePermissionAlreadySatisfied, isFalse);
      },
    );
  });
}
