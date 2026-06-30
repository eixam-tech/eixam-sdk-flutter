import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_profile_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SDK local user data wipe', () {
    test('SharedPrefsSdkStore removes all SDK local PII keys idempotently',
        () async {
      final store = MemorySharedPrefsSdkStore();
      _seedLocalUserData(store);
      store.stringValues['eixam.diagnostics.last_event'] = 'kept';

      await store.clearLocalUserData();
      await store.clearLocalUserData();

      _expectLocalUserDataRemoved(store);
      expect(store.stringValues['eixam.diagnostics.last_event'], 'kept');
    });

    test('clearSession removes SDK local PII keys', () async {
      final harness = _SdkHarness();
      addTearDown(harness.dispose);
      _seedLocalUserData(harness.localStore);

      await harness.sdk.clearSession();

      _expectLocalUserDataRemoved(harness.localStore);
    });

    test('deleteUserData clears SDK local PII when remote delete fails',
        () async {
      final harness = _SdkHarness(
        profileRemoteDataSource: _FailingProfileRemoteDataSource(),
      );
      addTearDown(harness.dispose);
      await harness.setSession();
      _seedLocalUserData(harness.localStore);

      await expectLater(
        harness.sdk.deleteUserData(
          userHash: ' signed-user ',
          externalUserId: ' canonical-user ',
        ),
        throwsStateError,
      );

      _expectLocalUserDataRemoved(harness.localStore);
    });

    test('all SharedPrefsSdkStore eixam keys are covered by local wipe',
        () async {
      final source = await File(
        'lib/src/data/datasources_local/shared_prefs_sdk_store.dart',
      ).readAsString();
      final sdkKeyLiterals = RegExp("'(eixam\\.[^']+)'")
          .allMatches(source)
          .map((match) => match.group(1)!)
          .toSet();

      expect(
        SharedPrefsSdkStore.localUserDataKeys.toSet(),
        containsAll(sdkKeyLiterals),
      );
    });
  });
}

void _seedLocalUserData(MemorySharedPrefsSdkStore store) {
  for (final key in SharedPrefsSdkStore.localUserDataKeys) {
    store.stringValues[key] = 'pii';
  }
  store.jsonValues[SharedPrefsSdkStore.sosIncidentKey] = <String, dynamic>{
    'id': 'sos-1',
    'message': 'help',
  };
  store.jsonValues[SharedPrefsSdkStore.trackingPositionKey] = <String, dynamic>{
    'latitude': 41.38,
    'longitude': 2.17,
  };
  store.jsonValues[SharedPrefsSdkStore.resolvedLocationKey] = <String, dynamic>{
    'address': 'Carrer Example 1',
  };
  store.jsonValues[SharedPrefsSdkStore.deviceIdentityMappingsKey] =
      <String, dynamic>{
    'hardware-1': 7,
  };
  store.jsonValues[SharedPrefsSdkStore.emergencyContactsKey] =
      <String, dynamic>{
    'contacts': <Map<String, Object?>>[
      <String, Object?>{'name': 'Pilot', 'phone': '+34600000000'},
    ],
  };
  store.boolValues[SharedPrefsSdkStore.osSosWidgetRecentActionsKey] = true;
}

void _expectLocalUserDataRemoved(MemorySharedPrefsSdkStore store) {
  for (final key in SharedPrefsSdkStore.localUserDataKeys) {
    expect(store.jsonValues.containsKey(key), isFalse, reason: key);
    expect(store.stringValues.containsKey(key), isFalse, reason: key);
    expect(store.boolValues.containsKey(key), isFalse, reason: key);
  }
}

final class _SdkHarness {
  _SdkHarness({SdkProfileRemoteDataSource? profileRemoteDataSource})
      : sosRepository = FakeSosRepository(),
        trackingRepository = FakeTrackingRepository(),
        telemetryRepository = FakeTelemetryRepository(),
        contactsRepository = FakeContactsRepository(),
        deviceRepository = FakeDeviceRepository(
          initialStatus: buildDeviceStatus(
            connected: false,
            paired: false,
            activated: false,
          ),
        ),
        deviceRegistryRepository = FakeSdkDeviceRegistryRepository(),
        deathManRepository = FakeDeathManRepository(),
        permissionsRepository = FakePermissionsRepository(),
        notificationsRepository = FakeNotificationsRepository(),
        realtimeClient = FakeRealtimeClient(),
        deviceSosController = DeviceSosController(),
        localStore = MemorySharedPrefsSdkStore() {
    sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: telemetryRepository,
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deviceRegistryRepository: deviceRegistryRepository,
      deathManRepository: deathManRepository,
      permissionsRepository: permissionsRepository,
      notificationsRepository: notificationsRepository,
      realtimeClient: realtimeClient,
      deviceSosController: deviceSosController,
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(
        localStore: localStore,
      ),
      profileRemoteDataSource: profileRemoteDataSource,
      localStore: localStore,
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
    );
  }

  final FakeSosRepository sosRepository;
  final FakeTrackingRepository trackingRepository;
  final FakeTelemetryRepository telemetryRepository;
  final FakeContactsRepository contactsRepository;
  final FakeDeviceRepository deviceRepository;
  final FakeSdkDeviceRegistryRepository deviceRegistryRepository;
  final FakeDeathManRepository deathManRepository;
  final FakePermissionsRepository permissionsRepository;
  final FakeNotificationsRepository notificationsRepository;
  final FakeRealtimeClient realtimeClient;
  final DeviceSosController deviceSosController;
  final MemorySharedPrefsSdkStore localStore;
  late final EixamConnectSdkImpl sdk;

  Future<void> setSession() {
    return sdk.setSession(
      const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'external-user',
        userHash: 'user-hash',
      ),
      deferRuntimeWork: true,
    );
  }

  Future<void> dispose() async {
    await sdk.dispose();
    await sosRepository.dispose();
    await trackingRepository.dispose();
    await contactsRepository.dispose();
    await deviceRepository.dispose();
    await deathManRepository.dispose();
    await realtimeClient.dispose();
  }
}

final class _FailingProfileRemoteDataSource
    implements SdkProfileRemoteDataSource {
  @override
  Future<void> deleteUserData({required EixamSession sessionOverride}) {
    throw StateError('remote delete failed');
  }

  @override
  Future<SdkUserProfile> fetchProfile({EixamSession? sessionOverride}) {
    throw UnimplementedError();
  }

  @override
  Future<SdkUserProfile> updateProfile(
    SdkUserProfileUpdate update, {
    EixamSession? sessionOverride,
  }) {
    throw UnimplementedError();
  }
}
