import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/device_country_config_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_alert_notification_ids.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import 'tag_battery_test_support.dart';
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
  late StreamController<BleIncomingEvent> incoming;
  late DateTime clock;
  var probeCalls = 0;
  int probePercent = 20;
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
      bleIncomingEvents: incoming.stream,
      clock: () => clock,
      tagBatteryProbeRequest: () async {
        probeCalls++;
        return runtimeStatus(percent: probePercent, receivedAt: clock);
      },
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
    incoming = StreamController<BleIncomingEvent>.broadcast();
    clock = DateTime.utc(2026, 11, 2, 12);
    probeCalls = 0;
    probePercent = 20;
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
    await incoming.close();
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

  test('the SDK re-keys TAG alert state on device migration', () async {
    await start();
    await control().updateTagAlertSettings(
      TagAlertSettings(deviceId: 'old-key', batteryAlerts: false),
    );
    notifier.calls.clear();
    await sdk.rekeyTagAlertDevice('old-key', 'new-key');
    expect(notifier.calls, ['cancelAllForDevice:old-key']);
    expect(
      (await control().getTagAlertSettings('new-key')).batteryAlerts,
      isFalse,
    );
    expect(
      (await control().getTagAlertSettings('old-key')).batteryAlerts,
      isTrue,
    );
  });

  group('device key stability (iOS-like: no hardware id)', () {
    DeviceStatus iosStatus({int? nodeId}) => buildDeviceStatus(
      deviceId: 'CB-UUID-1',
      canonicalHardwareId: null,
      nodeId: nodeId,
    );

    test(
      'the key does not change when the pair-time 0x23 arrives late',
      () async {
        await start();
        expect(
          tagAlertDeviceKey(iosStatus()),
          tagAlertDeviceKey(iosStatus(nodeId: 42)),
        );
        expect(tagAlertDeviceKey(iosStatus(nodeId: 42)), 'CB-UUID-1');
      },
    );

    test(
      'a disabled setting stays disabled across the hydrate timeout',
      () async {
        await start();
        devices.emitStatus(iosStatus());
        await pumpEventQueue();
        final disabled = TagAlertSettings(
          deviceId: tagAlertDeviceKey(iosStatus()),
          batteryAlerts: false,
          disconnectAfter: null,
        );
        await control().updateTagAlertSettings(disabled);
        // The first 0x23 times out at pair time; the node id shows up later.
        devices.emitStatus(iosStatus(nodeId: 42));
        await pumpEventQueue();
        final later = await control().getTagAlertSettings(
          tagAlertDeviceKey(iosStatus(nodeId: 42)),
        );
        expect(later, disabled);
        expect(later.batteryAlerts, isFalse);
      },
    );

    test(
      'unpair cleanup targets the same key before and after the node id',
      () async {
        await start();
        devices.emitStatus(iosStatus(nodeId: 42));
        await pumpEventQueue();
        await control().updateTagAlertSettings(
          TagAlertSettings(deviceId: 'CB-UUID-1', batteryAlerts: false),
        );
        notifier.calls.clear();
        await sdk.unpairDevice();
        expect(notifier.calls, ['cancelAllForDevice:CB-UUID-1']);
        expect(
          await control().getTagAlertSettings('CB-UUID-1'),
          TagAlertSettings(deviceId: 'CB-UUID-1'),
        );
      },
    );

    test('device country config keeps its own node-aware key', () {
      expect(
        DeviceCountryConfigController.deviceKeyFor(iosStatus(nodeId: 42)),
        'node:42',
      );
      expect(
        DeviceCountryConfigController.deviceKeyFor(iosStatus()),
        'CB-UUID-1',
      );
    });
  });

  group('low-battery alerts from live TAG data', () {
    Future<void> connectTag({bool connected = true}) async {
      devices.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-id',
          canonicalHardwareId: _tagHardware,
          nodeId: tagNodeId,
          connected: connected,
        ),
      );
      await pumpEventQueue();
    }

    Future<void> deliver(BleIncomingEvent event) async {
      incoming.add(event);
      await pumpEventQueue();
    }

    var counter = 0;

    /// A live D3 whose newest sample is [secondsAgo] old.
    BleIncomingEvent d3(int level, {int secondsAgo = 5}) {
      final at = clock.subtract(Duration(seconds: secondsAgo));
      return liveBatchEvent(clock, [
        (
          timestamp: unixOf(at),
          wire: telWire(level: level, packetId: (counter++) % 16),
        ),
      ]);
    }

    Iterable<String> shown() =>
        notifier.calls.where((c) => c.startsWith('show:'));

    setUp(() async {
      counter = 0;
      permissions.next = TagAlertPermissionState.granted;
      await start();
      await connectTag();
      notifier.calls.clear();
    });

    test('two live batches in the same band show one alert', () async {
      await deliver(d3(1));
      expect(shown(), isEmpty);
      await deliver(d3(1, secondsAgo: 1));
      expect(shown(), ['show:$_tagHardware:batteryLow']);
      expect(
        notifier.shown.single.batteryThreshold,
        TagAlertBatteryThreshold.below30,
      );
      await deliver(d3(1, secondsAgo: 2));
      expect(shown(), hasLength(1));
    });

    test('stale (late-flushed) batches never alert', () async {
      await deliver(d3(0, secondsAgo: 60 * 20));
      await deliver(d3(0, secondsAgo: 60 * 19));
      await deliver(d3(0, secondsAgo: 60 * 18));
      expect(shown(), isEmpty);
    });

    test('backlog, relay and SOS traffic are never readings', () async {
      for (final type in [
        BleIncomingEventType.telPositionBacklog,
        BleIncomingEventType.telRelayRx,
        BleIncomingEventType.sosMeshPacket,
        BleIncomingEventType.clusterHeartbeat,
      ]) {
        await deliver(eventOfType(type, clock));
        await deliver(eventOfType(type, clock));
      }
      expect(shown(), isEmpty);
    });

    test('another TAG\'s telemetry is never attributed to this TAG', () async {
      await deliver(classicTelEvent(clock, telWire(level: 0, nodeId: 99)));
      await deliver(
        classicTelEvent(clock, telWire(level: 0, nodeId: 99, packetId: 2)),
      );
      expect(shown(), isEmpty);
    });

    test('a disconnect between readings restarts confirmation', () async {
      await deliver(d3(1));
      await connectTag(connected: false);
      await connectTag();
      await deliver(d3(1, secondsAgo: 1));
      expect(shown(), isEmpty);
      await deliver(d3(1, secondsAgo: 2));
      expect(shown(), hasLength(1));
    });

    test('a connect-time 0x23 counts toward confirmation', () async {
      await deliver(runtimeStatusEvent(clock, percent: 25));
      expect(shown(), isEmpty);
      await deliver(d3(1));
      expect(shown(), hasLength(1));
    });

    test('nothing is evaluated without a connected TAG', () async {
      await connectTag(connected: false);
      await deliver(d3(0));
      await deliver(d3(0, secondsAgo: 1));
      expect(shown(), isEmpty);
    });

    test('the SDK does not alert after logout', () async {
      await sdk.clearSession();
      notifier.calls.clear();
      await deliver(d3(0));
      await deliver(d3(0, secondsAgo: 1));
      expect(shown(), isEmpty);
    });

    test('battery alerts never touch SOS flows', () async {
      await deliver(d3(0));
      await deliver(d3(0, secondsAgo: 1));
      expect(shown(), hasLength(1));
      expect(
        await sdk.consumePendingBleNotificationNavigationRequest(),
        isNull,
      );
      expect(notifications.notifications, isEmpty);
    });
  });

  group('key stability and device scoping for battery readings', () {
    DeviceStatus ios({int? nodeId}) => buildDeviceStatus(
      deviceId: 'ble-id',
      canonicalHardwareId: null,
      nodeId: nodeId,
    );

    setUp(() async {
      permissions.next = TagAlertPermissionState.granted;
      await start();
      notifier.calls.clear();
    });

    test(
      'no duplicate alert when the node id arrives mid-confirmation',
      () async {
        devices.emitStatus(ios());
        await pumpEventQueue();
        // Reading 1: the connect-time 0x23, before the node id is known.
        incoming.add(runtimeStatusEvent(clock, percent: 20));
        await pumpEventQueue();
        devices.emitStatus(ios(nodeId: tagNodeId));
        await pumpEventQueue();
        // Reading 2: a live batch after the node id arrived.
        incoming.add(
          liveBatchEvent(clock, [
            (
              timestamp: unixOf(clock.subtract(const Duration(seconds: 4))),
              wire: telWire(level: 1),
            ),
          ]),
        );
        await pumpEventQueue();
        final shown = notifier.calls.where((c) => c.startsWith('show:'));
        expect(shown, ['show:ble-id:batteryLow']);
        // Further readings under the same key never repeat it.
        incoming.add(
          liveBatchEvent(clock, [
            (
              timestamp: unixOf(clock.subtract(const Duration(seconds: 2))),
              wire: telWire(level: 1, packetId: 5),
            ),
          ]),
        );
        await pumpEventQueue();
        expect(
          notifier.calls.where((c) => c.startsWith('show:')),
          hasLength(1),
        );
      },
    );

    test(
      'a setting disabled before the node id arrived still applies',
      () async {
        devices.emitStatus(ios());
        await pumpEventQueue();
        await control().updateTagAlertSettings(
          TagAlertSettings(deviceId: 'ble-id', batteryAlerts: false),
        );
        devices.emitStatus(ios(nodeId: tagNodeId));
        await pumpEventQueue();
        for (var i = 0; i < 3; i++) {
          incoming.add(
            liveBatchEvent(clock, [
              (
                timestamp: unixOf(clock.subtract(Duration(seconds: 4 - i))),
                wire: telWire(level: 0, packetId: i),
              ),
            ]),
          );
          await pumpEventQueue();
        }
        expect(notifier.calls.where((c) => c.startsWith('show:')), isEmpty);
      },
    );

    test(
      'a reply from another device id is never credited to this TAG',
      () async {
        devices.emitStatus(ios(nodeId: tagNodeId));
        await pumpEventQueue();
        for (var i = 0; i < 3; i++) {
          incoming.add(
            runtimeStatusEvent(
              clock.add(Duration(seconds: i)),
              percent: 5,
              deviceId: 'some-other-tag',
            ),
          );
          await pumpEventQueue();
        }
        expect(notifier.calls.where((c) => c.startsWith('show:')), isEmpty);
      },
    );

    test(
      'the TEL interval learned from 0x23 widens the freshness window',
      () async {
        devices.emitStatus(ios(nodeId: tagNodeId));
        await pumpEventQueue();
        BleIncomingEvent late(int secondsAgo, int packetId) =>
            liveBatchEvent(clock, [
              (
                timestamp: unixOf(
                  clock.subtract(Duration(seconds: secondsAgo)),
                ),
                wire: telWire(level: 1, packetId: packetId),
              ),
            ]);
        // Default window (3 min): a 6-minute-old newest sample is not live.
        incoming.add(late(360, 1));
        incoming.add(late(350, 2));
        await pumpEventQueue();
        expect(notifier.calls.where((c) => c.startsWith('show:')), isEmpty);
        // A 5-minute TEL interval is learned from the 0x23 reply...
        incoming.add(
          runtimeStatusEvent(clock, percent: 55, telIntervalSeconds: 300),
        );
        await pumpEventQueue();
        // ...so the same age is live now (window 7.5 min).
        incoming.add(late(360, 3));
        incoming.add(late(350, 4));
        await pumpEventQueue();
        expect(
          notifier.calls.where((c) => c.startsWith('show:')),
          hasLength(1),
        );
      },
    );
  });

  group('foreground battery probe', () {
    Future<void> resume() async {
      sdk.didChangeAppLifecycleState(AppLifecycleState.paused);
      sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
    }

    Future<void> connectTag() async {
      devices.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-id',
          canonicalHardwareId: _tagHardware,
          nodeId: tagNodeId,
        ),
      );
      await pumpEventQueue();
    }

    setUp(() async {
      permissions.next = TagAlertPermissionState.granted;
      await start();
      await connectTag();
      notifier.calls.clear();
    });

    test(
      'requests 0x23 once on resume and treats it as a live reading',
      () async {
        await resume();
        expect(probeCalls, 1);
        // One probe reading + one live batch = two confirmed readings.
        incoming.add(
          liveBatchEvent(clock, [
            (
              timestamp: unixOf(clock.subtract(const Duration(seconds: 3))),
              wire: telWire(level: 1),
            ),
          ]),
        );
        await pumpEventQueue();
        expect(
          notifier.calls.where((c) => c.startsWith('show:')),
          hasLength(1),
        );
      },
    );

    test('at most once per 10 minutes per device, no polling', () async {
      await resume();
      clock = clock.add(const Duration(minutes: 9, seconds: 59));
      await resume();
      expect(probeCalls, 1);
      clock = clock.add(const Duration(seconds: 2));
      await resume();
      expect(probeCalls, 2);
    });

    test('a failed probe still waits out the interval', () async {
      await sdk.dispose();
      probeCalls = 0;
      // Rebuild with a failing request.
      localStore = MemorySharedPrefsSdkStore();
      sdk = EixamConnectSdkImpl(
        sosRepository: FakeSosRepository(),
        trackingRepository: FakeTrackingRepository(),
        telemetryRepository: FakeTelemetryRepository(),
        contactsRepository: FakeContactsRepository(),
        deviceRepository: devices,
        deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
        deathManRepository: FakeDeathManRepository(),
        permissionsRepository: permissionsRepository,
        notificationsRepository: notifications,
        realtimeClient: FakeRealtimeClient(),
        deviceSosController: DeviceSosController(),
        bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
        preferredBleDeviceStore: PreferredBleDeviceStore(
          localStore: localStore,
        ),
        localStore: localStore,
        clock: () => clock,
        tagBatteryProbeRequest: () async {
          probeCalls++;
          throw StateError('E_DEVICE_STATUS_TIMEOUT');
        },
        tagAlertNotifier: notifier,
        protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
        backgroundTelemetryPlatformAdapter:
            const NoopBackgroundTelemetryPlatformAdapter(),
      );
      await start();
      await connectTag();
      await resume();
      await resume();
      expect(probeCalls, 1);
    });

    test('is skipped without a connected TAG or without a session', () async {
      devices.emitStatus(
        buildDeviceStatus(
          deviceId: 'ble-id',
          canonicalHardwareId: _tagHardware,
          connected: false,
        ),
      );
      await pumpEventQueue();
      await resume();
      expect(probeCalls, 0);
      await connectTag();
      await sdk.clearSession();
      await resume();
      expect(probeCalls, 0);
    });

    test(
      'inactive/hidden focus changes never probe; a real background return does',
      () async {
        sdk.didChangeAppLifecycleState(AppLifecycleState.inactive);
        sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        sdk.didChangeAppLifecycleState(AppLifecycleState.hidden);
        sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue();
        expect(probeCalls, 0);
        await resume();
        expect(probeCalls, 1);
      },
    );
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
