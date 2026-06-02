import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('permission disclosure preflight', () {
    late FakePermissionsRepository permissionsRepository;
    late FakeSosRepository sosRepository;
    late FakeTrackingRepository trackingRepository;
    late FakeContactsRepository contactsRepository;
    late FakeDeviceRepository deviceRepository;
    late FakeDeathManRepository deathManRepository;
    late FakeRealtimeClient realtimeClient;
    late EixamConnectSdkImpl sdk;

    setUp(() {
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
        notificationsRepository: FakeNotificationsRepository(),
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
    });

    tearDown(() async {
      await sdk.dispose();
      await sosRepository.dispose();
      await trackingRepository.dispose();
      await contactsRepository.dispose();
      await deviceRepository.dispose();
      await deathManRepository.dispose();
      await realtimeClient.dispose();
    });

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
      expect(
        result.limitedFeatureMessage,
        contains('TAG pairing'),
      );
    });

    test('accepted disclosure is not repeated while permission status matches',
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
    });
  });
}
