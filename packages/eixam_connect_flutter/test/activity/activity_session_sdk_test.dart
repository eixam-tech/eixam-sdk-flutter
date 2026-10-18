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
import 'activity_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('activity end preserves active SOS ownership on $platform', () async {
      final h = _Harness(platform: platform);
      addTearDown(h.dispose);
      await h.sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: '', deferRuntimeStartup: true),
      );
      await h.sdk.setSession(userA, deferRuntimeWork: true);
      final activity = await h.sdk.startActivitySession(activityKey: 'ski');
      await h.sdk.triggerSosAuthoritatively(const SosTriggerPayload());
      await pumpEventQueue();
      expect(
        (await h.sdk.getActiveActivitySession())?.sessionId,
        activity.sessionId,
      );
      final calls = [
        h.tracking.startCallCount,
        h.tracking.stopCallCount,
        h.location.contextCalls,
        h.sos.triggerCallCount,
        h.deathMan.calls,
      ];
      if (platform == TargetPlatform.android) {
        expect(h.tracking.startCallCount, greaterThan(0));
      } else {
        expect(
          (await h.location.getBackgroundLocationStatus()).activeContexts,
          contains(BackgroundLocationContext.sos),
        );
      }
      await h.sdk.endActivitySession(sessionId: activity.sessionId);
      expect([
        h.tracking.startCallCount,
        h.tracking.stopCallCount,
        h.location.contextCalls,
        h.sos.triggerCallCount,
        h.deathMan.calls,
      ], calls);
      expect((await h.sdk.getSosLifecycle()).isOpen, isTrue);
    });
  }

  test(
    'SDK facade exposes only the optional capability and keeps safety resources intact',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.sdk.setSession(userA, deferRuntimeWork: true);
      final EixamConnectSdk facade = h.sdk;
      expect(facade, isA<ActivitySessionControl>());
      expect(await h.sdk.getActiveActivitySession(), isNull);
      await h.sdk.startTracking();
      final baseline = [
        h.tracking.startCallCount,
        h.tracking.stopCallCount,
        h.location.contextCalls,
        h.permissions.locationRequests,
        h.deathMan.calls,
      ];
      final a = await h.sdk.startActivitySession(
        activityKey: 'org.example.paddling',
      );
      await h.sdk.endActivitySession(sessionId: a.sessionId);
      await h.sdk.startActivitySession(activityKey: 'mountain');
      expect([
        h.tracking.startCallCount,
        h.tracking.stopCallCount,
        h.location.contextCalls,
        h.permissions.locationRequests,
        h.deathMan.calls,
      ], baseline);
      expect(await h.sdk.getTrackingState(), TrackingState.tracking);
    },
  );

  test(
    'SDK account APIs clear activity and dispose preserves it for initialize restoration',
    () async {
      final local = MemorySharedPrefsSdkStore();
      var h = _Harness(local: local);
      await h.sdk.setSession(userA, deferRuntimeWork: true);
      final a = await h.sdk.startActivitySession(activityKey: 'ski');
      await h.dispose();
      h = _Harness(local: local);
      addTearDown(() => h.dispose());
      await h.sdk.initialize(
        const EixamSdkConfig(apiBaseUrl: '', deferRuntimeStartup: true),
      );
      expect((await h.sdk.getActiveActivitySession())?.sessionId, a.sessionId);
      await h.sdk.setSession(userB, deferRuntimeWork: true);
      expect(await h.sdk.getActiveActivitySession(), isNull);
      await h.sdk.startActivitySession(activityKey: 'hunting');
      await h.sdk.clearLocalUserData();
      expect(await h.sdk.getActiveActivitySession(), isNull);
      await h.sdk.startActivitySession(activityKey: 'hunting');
      await h.sdk.clearSession();
      expect(await h.sdk.getActiveActivitySession(), isNull);
      expect(await h.sdk.getCurrentSession(), isNull);
    },
  );

  test(
    'activity implementation has no tracking, SOS, DMP, or native dependency',
    () {
      final source = File(
        'lib/src/sdk/activity_session_controller.dart',
      ).readAsStringSync();
      for (final forbidden in [
        'startTracking(',
        'stopTracking(',
        'AndroidTrackingOwner',
        'BackgroundLocationContext',
        'MethodChannel',
        'DeathMan',
        'SosLifecycle',
        'requestLocation',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: forbidden);
      }
    },
  );
}

class _Harness {
  _Harness({MemorySharedPrefsSdkStore? local, TargetPlatform? platform}) {
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
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
      backgroundLocationPlatformAdapter: location,
      sosLocationOwnershipPlatform: platform,
      sosLocationOwnershipIsWeb: false,
    );
  }
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
