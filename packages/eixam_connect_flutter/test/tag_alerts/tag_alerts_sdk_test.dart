import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_alert_notification_ids.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';
import 'tag_alert_test_support.dart';

const _tagHardware = 'AA:BB:CC:DD:EE:01';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySharedPrefsSdkStore localStore;
  late RecordingTagAlertNotifier notifier;
  late CountingPermissionGateway permissions;
  late FakeNotificationsRepository notifications;
  late FakeDeviceRepository devices;
  late FakePermissionsRepository permissionsRepository;
  late EixamConnectSdkImpl sdk;
  final trackers = <Future<void> Function()>[];

  EixamConnectSdkImpl build({SdkSessionStore? sessionStore}) {
    final sosRepository = FakeSosRepository();
    final trackingRepository = FakeTrackingRepository();
    final contactsRepository = FakeContactsRepository();
    final deathManRepository = FakeDeathManRepository();
    final realtimeClient = FakeRealtimeClient();
    trackers
      ..clear()
      ..addAll([
        sosRepository.dispose,
        trackingRepository.dispose,
        contactsRepository.dispose,
        deathManRepository.dispose,
        realtimeClient.dispose,
        devices.dispose,
      ]);
    return EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: contactsRepository,
      deviceRepository: devices,
      deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
      deathManRepository: deathManRepository,
      permissionsRepository: permissionsRepository,
      notificationsRepository: notifications,
      realtimeClient: realtimeClient,
      deviceSosController: DeviceSosController(),
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: localStore),
      localStore: localStore,
      sessionStore: sessionStore,
      tagAlertNotifier: notifier,
      tagAlertPermissions: permissions,
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
    );
  }

  Future<void> start([EixamSession session = sessionA]) async {
    await sdk.initialize(
      const EixamSdkConfig(
        apiBaseUrl: 'https://sdk.test',
        deferRuntimeStartup: true,
      ),
    );
    await sdk.setSession(session, deferRuntimeWork: true);
  }

  setUp(() {
    localStore = MemorySharedPrefsSdkStore();
    notifier = RecordingTagAlertNotifier();
    permissions = CountingPermissionGateway();
    notifications = FakeNotificationsRepository();
    permissionsRepository = FakePermissionsRepository(
      permissionState: const PermissionState(
        location: SdkPermissionStatus.denied,
        notifications: SdkPermissionStatus.denied,
        bluetooth: SdkPermissionStatus.denied,
        bluetoothEnabled: true,
      ),
    );
    devices = FakeDeviceRepository(
      initialStatus: buildDeviceStatus(
        deviceId: 'ble-id',
        canonicalHardwareId: _tagHardware,
      ),
    );
    sdk = build();
  });

  tearDown(() async {
    await sdk.dispose();
    for (final dispose in trackers) {
      await dispose();
    }
  });

  TagAlertsControl control() => sdk as TagAlertsControl;

  test('the SDK exposes TagAlertsControl as an optional capability', () {
    expect(sdk, isA<TagAlertsControl>());
  });

  test(
    'starting the SDK never prompts and never touches notifications',
    () async {
      await start();
      expect(permissions.requestCalls, 0);
      expect(permissions.stateCalls, 0);
      expect(notifications.requestPermissionCallCount, 0);
      expect(permissionsRepository.requestNotificationPermissionCallCount, 0);
      // A signed-out cold start may clear stale alerts; nothing is ever shown
      // or scheduled by the foundation.
      expect(notifier.calls.every((call) => call == 'cancelAll'), isTrue);
      await control().updateTagAlertSettings(
        TagAlertSettings(deviceId: _tagHardware),
      );
      expect(permissions.requestCalls, 0);
    },
  );

  test('permission calls reach the gateway only when the host asks', () async {
    await start();
    expect(
      await control().getTagAlertPermissionState(),
      TagAlertPermissionState.notDetermined,
    );
    expect(permissions.requestCalls, 0);
    expect(
      await control().requestTagAlertPermission(),
      TagAlertPermissionState.granted,
    );
    expect(permissions.requestCalls, 1);
  });

  group('cleanup through the public SDK', () {
    final custom = TagAlertSettings(
      deviceId: _tagHardware,
      batteryAlerts: false,
      disconnectAfter: const Duration(minutes: 60),
    );

    test('clearSession wipes settings and cancels every alert', () async {
      await start();
      await control().updateTagAlertSettings(custom);
      notifier.calls.clear();
      await sdk.clearSession();
      expect(notifier.calls, contains('cancelAll'));
      expect(localStore.stringValues[SharedPrefsSdkStore.tagAlertsKey], isNull);
      await sdk.setSession(sessionA, deferRuntimeWork: true);
      expect(
        await control().getTagAlertSettings(_tagHardware),
        TagAlertSettings(deviceId: _tagHardware),
      );
    });

    test('clearLocalUserData wipes settings and cancels every alert', () async {
      await start();
      await control().updateTagAlertSettings(custom);
      notifier.calls.clear();
      await sdk.clearLocalUserData();
      expect(notifier.calls, contains('cancelAll'));
      expect(localStore.stringValues[SharedPrefsSdkStore.tagAlertsKey], isNull);
    });

    test(
      'an app id change (different signed app) drops the old data',
      () async {
        await start();
        await control().updateTagAlertSettings(custom);
        notifier.calls.clear();
        await sdk.setSession(sessionOtherApp, deferRuntimeWork: true);
        expect(notifier.calls, contains('cancelAll'));
        expect(
          await control().getTagAlertSettings(_tagHardware),
          TagAlertSettings(deviceId: _tagHardware),
        );
      },
    );

    test(
      'unpair cancels that TAG\'s alerts and forgets only its settings',
      () async {
        await start();
        await control().updateTagAlertSettings(custom);
        await control().updateTagAlertSettings(
          TagAlertSettings(deviceId: 'other-tag', batteryAlerts: false),
        );
        notifier.calls.clear();
        await sdk.unpairDevice();
        expect(devices.unpairCallCount, 1);
        expect(notifier.calls, ['cancelAllForDevice:$_tagHardware']);
        expect(
          await control().getTagAlertSettings(_tagHardware),
          TagAlertSettings(deviceId: _tagHardware),
        );
        expect(
          (await control().getTagAlertSettings('other-tag')).batteryAlerts,
          isFalse,
        );
      },
    );

    test('unpair completes even if alert cleanup fails', () async {
      await start();
      notifier.failCancelAllForDevice = true;
      await sdk.unpairDevice();
      expect(devices.unpairCallCount, 1);
    });

    test('dispose keeps persisted settings and scheduled alerts', () async {
      await start();
      await control().updateTagAlertSettings(custom);
      notifier.calls.clear();
      await sdk.dispose();
      expect(notifier.calls, isEmpty);
      expect(
        localStore.stringValues[SharedPrefsSdkStore.tagAlertsKey],
        isNotNull,
      );
    });
  });

  group('cold start with a persisted session', () {
    late _MemorySecureStore secure;

    SdkSessionStore sessionStoreFor() =>
        SdkSessionStore(localStore: localStore, secureStore: secure);

    Future<void> disposeCurrent() async {
      await sdk.dispose();
      for (final dispose in trackers) {
        await dispose();
      }
    }

    setUp(() => secure = _MemorySecureStore());

    Future<TagAlertSettings> seedPersistedSession() async {
      await disposeCurrent();
      sdk = build(sessionStore: sessionStoreFor());
      await start();
      final stored = TagAlertSettings(
        deviceId: _tagHardware,
        batteryAlerts: false,
        disconnectAfter: const Duration(minutes: 60),
      );
      await control().updateTagAlertSettings(stored);
      await disposeCurrent();
      notifier.calls.clear();
      return stored;
    }

    test('a normal restore keeps settings and alerts', () async {
      final stored = await seedPersistedSession();
      sdk = build(sessionStore: sessionStoreFor());
      await sdk.initialize(
        const EixamSdkConfig(
          apiBaseUrl: 'https://sdk.test',
          deferRuntimeStartup: true,
        ),
      );
      expect(notifier.calls, isNot(contains('cancelAll')));
      expect(await control().getTagAlertSettings(_tagHardware), stored);
    });

    for (final failure in <SecureKeyValueStoreException>[
      const SecureKeyValueStoreUnavailableException(),
      const SecureKeyValueStoreEntryUnreadableException(),
    ]) {
      test('a transient session read failure (${failure.code}) does not wipe '
          'settings or scheduled alerts', () async {
        final stored = await seedPersistedSession();
        secure.readFailure = failure;
        sdk = build(sessionStore: sessionStoreFor());
        await expectLater(
          sdk.initialize(
            const EixamSdkConfig(
              apiBaseUrl: 'https://sdk.test',
              deferRuntimeStartup: true,
            ),
          ),
          throwsA(isA<SecureKeyValueStoreException>()),
        );
        expect(notifier.calls, isNot(contains('cancelAll')));
        expect(
          localStore.stringValues[SharedPrefsSdkStore.tagAlertsKey],
          isNotNull,
        );
        // The retry succeeds once the keychain is readable again.
        secure.readFailure = null;
        await disposeCurrent();
        sdk = build(sessionStore: sessionStoreFor());
        await sdk.initialize(
          const EixamSdkConfig(
            apiBaseUrl: 'https://sdk.test',
            deferRuntimeStartup: true,
          ),
        );
        expect(await control().getTagAlertSettings(_tagHardware), stored);
        expect(notifier.calls, isNot(contains('cancelAll')));
      });
    }

    test(
      'a failed restore followed by a different user still isolates data',
      () async {
        await seedPersistedSession();
        secure.readFailure = const SecureKeyValueStoreUnavailableException();
        sdk = build(sessionStore: sessionStoreFor());
        await expectLater(
          sdk.initialize(
            const EixamSdkConfig(
              apiBaseUrl: 'https://sdk.test',
              deferRuntimeStartup: true,
            ),
          ),
          throwsA(isA<SecureKeyValueStoreException>()),
        );
        secure.readFailure = null;
        await sdk.setSession(sessionB, deferRuntimeWork: true);
        expect(
          await control().getTagAlertSettings(_tagHardware),
          TagAlertSettings(deviceId: _tagHardware),
        );
      },
    );

    test('a signed-out cold start (nothing persisted) still wipes', () async {
      await disposeCurrent();
      localStore.stringValues[SharedPrefsSdkStore.tagAlertsKey] = 'stale';
      sdk = build(sessionStore: sessionStoreFor());
      await sdk.initialize(
        const EixamSdkConfig(
          apiBaseUrl: 'https://sdk.test',
          deferRuntimeStartup: true,
        ),
      );
      expect(notifier.calls, contains('cancelAll'));
      expect(localStore.stringValues[SharedPrefsSdkStore.tagAlertsKey], isNull);
    });
  });

  group('notification taps', () {
    test('a tag alert tap never queues SOS/BLE navigation', () async {
      await start();
      await sdk.initializeNotifications();
      final handler = notifications.lastOnAction!;
      await handler(
        NotificationActionInvocation(
          actionId: 'open_app',
          payload: TagAlertPayload.encode(
            _tagHardware,
            TagAlertKind.tagDisconnected,
          ),
          launchedApp: false,
        ),
      );
      expect(
        await sdk.consumePendingBleNotificationNavigationRequest(),
        isNull,
      );
    });

    test(
      'control: an unrecognized payload still queues, so the guard matters',
      () async {
        await start();
        await sdk.initializeNotifications();
        await notifications.lastOnAction!(
          const NotificationActionInvocation(
            actionId: 'open_app',
            payload: '{"kind":"other"}',
            launchedApp: false,
          ),
        );
        expect(
          await sdk.consumePendingBleNotificationNavigationRequest(),
          isNotNull,
        );
      },
    );
  });

  test(
    'SOS notification behavior is unchanged: ids stay out of the tag range',
    () {
      // The generic id generator is the only SOS-side change; it must still
      // return the same value for every id outside the reserved range.
      for (final id in <int>[1, 42001, 999999999, 1000100000, 2147483646]) {
        expect(TagAlertNotificationIds.outsideRange(id), id);
      }
    },
  );
}

final class _MemorySecureStore implements SecureKeyValueStore {
  final Map<String, String> values = {};
  SecureKeyValueStoreException? readFailure;

  @override
  Future<String?> read(String key) async {
    final failure = readFailure;
    if (failure != null) throw failure;
    return values[key];
  }

  @override
  Future<bool> containsKey(String key) async => values.containsKey(key);

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<void> deleteAll({String? namespace}) async => values.clear();
}
