import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_identity_remote_data_source.dart';
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

  group('factory bootstrap secure-session recovery sequence', () {
    test('fresh session recovers, enriches, verifies, and attaches', () async {
      final secureStore = _RecoverySecureStore();
      final identitySource = _IdentitySource();
      final harness = _SdkHarness(
        secureStore: secureStore,
        identitySource: identitySource,
        recoverUnreadablePersistedSession: true,
      );
      addTearDown(harness.dispose);

      await harness.initialize();
      await harness.attachFreshSession();

      final attached = await harness.sdk.getCurrentSession();
      expect(identitySource.callCount, 1);
      expect(attached?.sdkUserId, 'fresh-sdk-user');
      expect(attached?.canonicalExternalUserId, 'fresh-canonical-user');
      expect(
        secureStore.deletedKeys,
        <String>[SecureStorageKeys.sdkSessionIdentity.value],
      );
      expect(secureStore.sessionWriteCount, 2);
      expect(secureStore.sessionVerificationReadCount, 2);
    });

    test('unreadable session without a fresh-session gate fails initialize',
        () async {
      final secureStore = _RecoverySecureStore();
      final harness = _SdkHarness(
        secureStore: secureStore,
        identitySource: _IdentitySource(),
        recoverUnreadablePersistedSession: false,
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.initialize(),
        throwsA(isA<SecureKeyValueStoreEntryUnreadableException>()),
      );

      expect(secureStore.deletedKeys, isEmpty);
      expect(secureStore.sessionWriteCount, 0);
    });

    test('backend identity failure remains fatal after stale deletion',
        () async {
      final secureStore = _RecoverySecureStore();
      final backendFailure = AuthException('E_TEST_AUTH', 'private-message');
      final harness = _SdkHarness(
        secureStore: secureStore,
        identitySource: _IdentitySource(failure: backendFailure),
        recoverUnreadablePersistedSession: true,
      );
      addTearDown(harness.dispose);

      await harness.initialize();
      await expectLater(
          harness.attachFreshSession(), throwsA(same(backendFailure)));

      expect(secureStore.sessionWriteCount, 0);
    });

    test('fresh secure write failure remains fatal after recovery', () async {
      const writeFailure = SecureKeyValueStoreWriteException();
      final secureStore = _RecoverySecureStore(writeFailure: writeFailure);
      final harness = _SdkHarness(
        secureStore: secureStore,
        identitySource: _IdentitySource(),
        recoverUnreadablePersistedSession: true,
      );
      addTearDown(harness.dispose);

      await harness.initialize();
      await expectLater(
          harness.attachFreshSession(), throwsA(same(writeFailure)));

      expect(await harness.sdk.getCurrentSession(), isNull);
    });

    test('fresh verification read failure remains fatal after recovery',
        () async {
      const verificationFailure = SecureKeyValueStoreUnavailableException();
      final secureStore = _RecoverySecureStore(
        verificationReadFailure: verificationFailure,
      );
      final harness = _SdkHarness(
        secureStore: secureStore,
        identitySource: _IdentitySource(),
        recoverUnreadablePersistedSession: true,
      );
      addTearDown(harness.dispose);

      await harness.initialize();
      await expectLater(
        harness.attachFreshSession(),
        throwsA(same(verificationFailure)),
      );

      expect(await harness.sdk.getCurrentSession(), isNull);
    });
  });
}

final class _SdkHarness {
  _SdkHarness({
    required _RecoverySecureStore secureStore,
    required _IdentitySource identitySource,
    required bool recoverUnreadablePersistedSession,
  })  : _sosRepository = FakeSosRepository(),
        _trackingRepository = FakeTrackingRepository(),
        _contactsRepository = FakeContactsRepository(),
        _deviceRepository = FakeDeviceRepository(
          initialStatus: buildDeviceStatus(
            paired: false,
            activated: false,
            connected: false,
            lifecycleState: DeviceLifecycleState.unpaired,
          ),
        ),
        _deathManRepository = FakeDeathManRepository(),
        _realtimeClient = FakeRealtimeClient(),
        _localStore = MemorySharedPrefsSdkStore() {
    sdk = EixamConnectSdkImpl(
      sosRepository: _sosRepository,
      trackingRepository: _trackingRepository,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: _contactsRepository,
      deviceRepository: _deviceRepository,
      deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
      deathManRepository: _deathManRepository,
      permissionsRepository: FakePermissionsRepository(),
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: _realtimeClient,
      deviceSosController: DeviceSosController(),
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: _localStore),
      sessionStore: SdkSessionStore(
        localStore: _localStore,
        secureStore: secureStore,
      ),
      recoverUnreadablePersistedSession: recoverUnreadablePersistedSession,
      sosLifecycleSecureStore: secureStore,
      identityRemoteDataSource: identitySource,
      localStore: _localStore,
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
    );
  }

  final FakeSosRepository _sosRepository;
  final FakeTrackingRepository _trackingRepository;
  final FakeContactsRepository _contactsRepository;
  final FakeDeviceRepository _deviceRepository;
  final FakeDeathManRepository _deathManRepository;
  final FakeRealtimeClient _realtimeClient;
  final MemorySharedPrefsSdkStore _localStore;
  late final EixamConnectSdkImpl sdk;

  Future<void> initialize() => sdk.initialize(
        const EixamSdkConfig(
          apiBaseUrl: 'https://api.example.test',
          deferRuntimeStartup: true,
        ),
      );

  Future<void> attachFreshSession() => sdk.setSession(
        const EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'fresh-user',
          userHash: 'fresh-signed-hash',
        ),
        deferRuntimeWork: true,
      );

  Future<void> dispose() async {
    await sdk.dispose();
    await _sosRepository.dispose();
    await _trackingRepository.dispose();
    await _contactsRepository.dispose();
    await _deviceRepository.dispose();
    await _deathManRepository.dispose();
    await _realtimeClient.dispose();
  }
}

final class _IdentitySource implements SdkIdentityRemoteDataSource {
  _IdentitySource({this.failure});

  final Object? failure;
  int callCount = 0;

  @override
  Future<EixamSession> bootstrapSession(EixamSession session) async {
    callCount++;
    if (failure case final error?) throw error;
    return session.copyWith(
      sdkUserId: 'fresh-sdk-user',
      canonicalExternalUserId: 'fresh-canonical-user',
    );
  }
}

final class _RecoverySecureStore implements SecureKeyValueStore {
  _RecoverySecureStore({
    this.writeFailure,
    this.verificationReadFailure,
  }) : _values = <String, String>{
          SecureStorageKeys.sdkSessionIdentity.value: 'unreadable-session',
        };

  final Object? writeFailure;
  final Object? verificationReadFailure;
  final Map<String, String> _values;
  final List<String> deletedKeys = <String>[];
  bool _sessionReadRecovered = false;
  int sessionWriteCount = 0;
  int sessionVerificationReadCount = 0;

  @override
  Future<bool> containsKey(String key) async => _values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    deletedKeys.add(key);
    _values.remove(key);
    if (key == SecureStorageKeys.sdkSessionIdentity.value) {
      _sessionReadRecovered = true;
    }
  }

  @override
  Future<void> deleteAll({String? namespace}) async {
    throw StateError('Session recovery must never call deleteAll.');
  }

  @override
  Future<String?> read(String key) async {
    if (key == SecureStorageKeys.sdkSessionIdentity.value) {
      if (!_sessionReadRecovered) {
        throw const SecureKeyValueStoreEntryUnreadableException();
      }
      if (sessionWriteCount > sessionVerificationReadCount) {
        sessionVerificationReadCount++;
        if (verificationReadFailure case final error?) throw error;
      }
    }
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == SecureStorageKeys.sdkSessionIdentity.value) {
      if (writeFailure case final error?) throw error;
      sessionWriteCount++;
    }
    _values[key] = value;
  }
}
