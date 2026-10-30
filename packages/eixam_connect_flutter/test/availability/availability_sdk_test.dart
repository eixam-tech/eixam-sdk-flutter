import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_location_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';
import '../activity/activity_test_support.dart';
import 'availability_test_support.dart' as availability;
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart' as public;
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('public Flutter exports support typed optional detection', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.sdk.setSession(userA, deferRuntimeWork: true);
    final EixamConnectSdk facade = h.sdk;
    expect(facade, isA<public.ActivityAvailabilityControl>());
    final public.ActivityAvailabilityControl capability = h.sdk;
    final public.SdkActivityAvailability fresh = await capability
        .refreshActivityAvailability();
    final public.SdkAvailableActivity activity = fresh.activities.single;
    expect(activity.key, 'mountain');
    const error = public.ActivityAvailabilityException('code', 'message');
    expect(error.code, 'code');
  });

  test(
    'availability refresh/cache/watch have zero session or safety side effects',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.sdk.setSession(userA, deferRuntimeWork: true);
      expect(await h.sdk.getActiveActivitySession(), isNull);
      final baseline = [
        h.tracking.startCallCount,
        h.tracking.stopCallCount,
        h.location.contextCalls,
        h.sos.triggerCallCount,
        h.deathMan.calls,
        h.permissions.locationRequests,
      ];
      await h.sdk.refreshActivityAvailability();
      await h.sdk.getCachedActivityAvailability();
      await h.sdk.watchActivityAvailability().first;
      expect(await h.sdk.getActiveActivitySession(), isNull);
      final session = await h.sdk.startActivitySession(activityKey: 'ski');
      h.remote.activities = [];
      await h.sdk.refreshActivityAvailability();
      h.remote.error = const AuthException('unauthorized', '401');
      await expectLater(
        h.sdk.refreshActivityAvailability(),
        throwsA(isA<AuthException>()),
      );
      expect(
        (await h.sdk.getActiveActivitySession())!.sessionId,
        session.sessionId,
      );
      expect([
        h.tracking.startCallCount,
        h.tracking.stopCallCount,
        h.location.contextCalls,
        h.sos.triggerCallCount,
        h.deathMan.calls,
        h.permissions.locationRequests,
      ], baseline);
    },
  );

  test(
    'facade restores offline and clears availability in all identity hooks',
    () async {
      final local = MemorySharedPrefsSdkStore();
      var h = _Harness(local: local);
      await h.sdk.setSession(userA, deferRuntimeWork: true);
      await h.sdk.refreshActivityAvailability();
      await h.dispose();
      h = _Harness(local: local);
      addTearDown(() => h.dispose());
      await h.sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: '', deferRuntimeStartup: true),
      );
      expect((await h.sdk.getCachedActivityAvailability())!.fromCache, isTrue);
      expect(h.remote.calls, 0);
      await h.sdk.refreshCanonicalIdentity();
      expect(await h.sdk.getCachedActivityAvailability(), isNotNull);
      await h.sdk.setSession(userB, deferRuntimeWork: true);
      expect(await h.sdk.getCachedActivityAvailability(), isNull);
      await h.sdk.refreshActivityAvailability();
      await h.sdk.clearLocalUserData();
      expect(await h.sdk.getCachedActivityAvailability(), isNull);
      await h.sdk.refreshActivityAvailability();
      await h.sdk.clearSession();
      expect(await h.sdk.getCachedActivityAvailability(), isNull);
      expect(
        local.stringValues[SharedPrefsSdkStore.activityAvailabilityKey],
        isNull,
      );
      expect(await h.sdk.getCurrentSession(), isNull);
    },
  );

  test(
    'facade fences availability and ActivitySession synchronously at account switch',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.sdk.setSession(userA, deferRuntimeWork: true);
      final gate = Completer<List<SdkAvailableActivity>>();
      h.remote.next = gate;
      final oldRefresh = expectLater(
        h.sdk.refreshActivityAvailability(),
        throwsA(availability.availabilityError('UNAVAILABLE')),
      );
      await pumpEventQueue();
      final switching = h.sdk.setSession(userB, deferRuntimeWork: true);
      final starting = h.sdk.startActivitySession(activityKey: 'ski');
      await switching;
      await starting;
      gate.complete([availability.ski]);
      await oldRefresh;
      expect(await h.sdk.getCachedActivityAvailability(), isNull);
    },
  );

  test(
    'availability implementation has no session/tracking/SOS/DMP/native calls',
    () {
      for (final path in [
        'lib/src/sdk/activity_availability_controller.dart',
        'lib/src/data/datasources_local/activity_availability_store.dart',
        'lib/src/data/datasources_remote/sdk_activity_availability_remote_data_source.dart',
      ]) {
        final source = File(path).readAsStringSync();
        for (final forbidden in [
          'startActivitySession(',
          'endActivitySession(',
          'startTracking(',
          'stopTracking(',
          'MethodChannel',
          'triggerSos(',
          'DeathManRepository',
          'TrackingOwner',
          'requestLocation',
        ]) {
          expect(
            source,
            isNot(contains(forbidden)),
            reason: '$path: $forbidden',
          );
        }
      }
      expect(
        File('lib/src/sdk/activity_session_controller.dart').readAsStringSync(),
        isNot(contains('ActivityAvailability')),
      );
    },
  );
  test(
    'failed availability deletion still completes existing SDK teardown',
    () async {
      final store = availability.MemoryStore();
      final h = _Harness(availabilityStore: store);
      addTearDown(h.dispose);
      await h.sdk.setSession(userA, deferRuntimeWork: true);
      await h.sdk.refreshActivityAvailability();
      store.rejectRemove = true;
      h.remote.error = const AuthException('unauthorized', '401');
      await expectLater(
        h.sdk.refreshActivityAvailability(),
        throwsA(availability.availabilityError('PERSISTENCE_FAILED')),
      );
      final baseline = h.realtime.disconnectCallCount;
      await expectLater(
        h.sdk.dispose(),
        throwsA(availability.availabilityError('PERSISTENCE_FAILED')),
      );
      expect(h.cleanupCompleted, isTrue);
      expect(h.location.disposed, isTrue);
      expect(h.realtime.disconnectCallCount, greaterThan(baseline));
      store.rejectRemove = false;
    },
  );
}

class _Harness {
  _Harness({
    MemorySharedPrefsSdkStore? local,
    TargetPlatform? platform,
    availability.MemoryStore? availabilityStore,
  }) {
    final store = local ?? MemorySharedPrefsSdkStore();
    sdk = EixamConnectSdkImpl(
      sosRepository: sos,
      trackingRepository: tracking,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: contacts,
      deviceRepository: device,
      deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
      deathManRepository: deathMan,
      permissionsRepository: permissions,
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: realtime,
      deviceSosController: deviceSos,
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: store),
      sessionStore: SdkSessionStore(localStore: store),
      localStore: store,
      activityAvailabilityRemoteDataSource: remote,
      activityAvailabilityStore: availabilityStore,
      disposeCallback: () async {
        cleanupCompleted = true;
      },
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
      backgroundLocationPlatformAdapter: location,
      sosLocationOwnershipPlatform: platform,
      sosLocationOwnershipIsWeb: false,
    );
  }
  bool cleanupCompleted = false;
  final remote = availability.Remote();
  final sos = FakeSosRepository();
  final tracking = FakeTrackingRepository();
  final contacts = FakeContactsRepository();
  final device = FakeDeviceRepository(
    initialStatus: buildDeviceStatus(
      connected: false,
      paired: false,
      activated: false,
    ),
  );
  final deathMan = _DeathMan();
  final permissions = _Permissions();
  final realtime = FakeRealtimeClient();
  final deviceSos = DeviceSosController();
  final location = _Location();
  late final EixamConnectSdkImpl sdk;
  Future<void> dispose() async {
    await sdk.dispose();
    await tracking.dispose();
    await contacts.dispose();
    await device.dispose();
    await deathMan.dispose();
    await realtime.dispose();
    await sos.dispose();
  }
}

class _Permissions extends FakePermissionsRepository {
  int locationRequests = 0;
  @override
  Future<PermissionState> requestLocationPermission() {
    locationRequests++;
    return super.requestLocationPermission();
  }
}

class _DeathMan extends FakeDeathManRepository {
  int calls = 0;
  @override
  Future<DeathManPlan?> getActiveDeathManPlan() {
    calls++;
    return super.getActiveDeathManPlan();
  }
}

class _Location extends UnsupportedBackgroundLocationPlatformAdapter {
  bool disposed = false;
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  int contextCalls = 0;
  @override
  Future<BackgroundLocationRuntimeStatus> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  }) {
    contextCalls++;
    return super.setBackgroundLocationContext(context, active: active);
  }
}
