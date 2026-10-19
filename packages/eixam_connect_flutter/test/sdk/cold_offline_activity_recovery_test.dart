import 'dart:async';
import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_activity_availability_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_identity_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_location_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

const _backend = 'https://sdk.test';
const _identity = EixamSession.signed(
  appId: 'partner-app',
  externalUserId: 'user-a',
  userHash: 'signed-a',
  sdkUserId: 'sdk-a',
  canonicalExternalUserId: 'user-a',
);
final _appSnapshot = _identity.copyWith(
  sdkUserId: null,
  canonicalExternalUserId: null,
);
const _watchdog = Duration(seconds: 2);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final pending in [false, true]) {
    test(
      'cold rebind exposes local state before ${pending ? 'pending' : 'failed'} identity HTTP',
      () async {
        final disk = _Disk();
        final original = await _seed(disk);
        final h = _Harness(disk);
        Future<void>? binding;
        try {
          await h.initialize();
          if (pending) {
            h.identityGate = Completer<http.Response>();
          } else {
            h.offline = true;
          }
          binding = h.sdk.setSession(_appSnapshot, deferRuntimeWork: true);
          await binding.timeout(_watchdog);
          final session = await h.sdk.getActiveActivitySession().timeout(
            _watchdog,
          );
          expect(session?.sessionId, original.sessionId);
          expect(session?.startedAt, original.startedAt);
          expect(session?.activityKey, 'mountain');
          final cache = await h.sdk.getCachedActivityAvailability().timeout(
            _watchdog,
          );
          expect(cache?.fromCache, isTrue);
          expect(cache?.activities.single.key, 'mountain');
          expect(
            (await h.sdk.watchActivityAvailability().first.timeout(
              _watchdog,
            ))?.fromCache,
            isTrue,
          );
          // These assertions precede network completion and cleanup.
          expect(h.identityRequests, 0);
          expect(h.tracking.startCallCount, 0);
          expect(h.sos.triggerCallCount, 0);
          expect(await h.sdk.getTrackingState(), TrackingState.idle);
        } finally {
          h.releaseIdentity();
          if (binding != null) await binding.catchError((Object _) {});
          await h.dispose();
        }
      },
    );
  }

  test(
    'pending canonical readiness neither invalidates nor blocks local Activity state',
    () async {
      final disk = _Disk();
      final original = await _seed(disk);
      final h = _Harness(disk);
      Future<EixamSession>? refresh;
      final seen = <SdkActivityAvailability?>[];
      StreamSubscription<SdkActivityAvailability?>? sub;
      try {
        await h.initialize();
        await h.sdk.setSession(_appSnapshot, deferRuntimeWork: true);
        sub = h.sdk.watchActivityAvailability().listen(seen.add);
        await pumpEventQueue();
        h.identityGate = Completer<http.Response>();
        refresh = h.sdk.refreshCanonicalIdentity();
        await pumpEventQueue();
        expect(h.identityRequests, 1);
        expect(
          (await h.sdk.getActiveActivitySession().timeout(
            _watchdog,
          ))?.sessionId,
          original.sessionId,
        );
        expect(
          (await h.sdk.getCachedActivityAvailability().timeout(
            _watchdog,
          ))?.fromCache,
          isTrue,
        );
        expect(seen.where((value) => value == null), isEmpty);
        h.releaseIdentity();
        await refresh;
        expect(
          (await h.sdk.getActiveActivitySession())?.sessionId,
          original.sessionId,
        );
        expect(seen.where((value) => value == null), isEmpty);
      } finally {
        h.releaseIdentity();
        if (refresh != null) await refresh.catchError((Object _) => _identity);
        await sub?.cancel();
        await h.dispose();
      }
    },
  );

  for (final cacheKind in [
    'mountain',
    'empty',
    'unsupported',
    'absent',
    'corrupt',
  ]) {
    test(
      'offline $cacheKind cache remains independent from session recovery',
      () async {
        final disk = _Disk();
        final original = await _seed(
          disk,
          keys: cacheKind == 'empty'
              ? []
              : cacheKind == 'unsupported'
              ? ['ski']
              : ['mountain'],
        );
        if (cacheKind == 'absent') {
          disk.local.stringValues.remove(
            SharedPrefsSdkStore.activityAvailabilityKey,
          );
        }
        if (cacheKind == 'corrupt') {
          disk.local.stringValues[SharedPrefsSdkStore.activityAvailabilityKey] =
              '{broken';
        }
        final h = _Harness(disk)..offline = true;
        try {
          await h.initialize();
          await h.sdk.setSession(_appSnapshot, deferRuntimeWork: true);
          expect(
            (await h.sdk.getActiveActivitySession())?.sessionId,
            original.sessionId,
          );
          if (cacheKind == 'corrupt') {
            await expectLater(
              h.sdk.getCachedActivityAvailability(),
              throwsA(isA<ActivityAvailabilityException>()),
            );
          } else {
            final cache = await h.sdk.getCachedActivityAvailability();
            if (cacheKind == 'absent') {
              expect(cache, isNull);
            } else {
              expect(cache?.fromCache, isTrue);
              expect(
                cache?.activities.map((a) => a.key),
                cacheKind == 'empty'
                    ? isEmpty
                    : [cacheKind == 'unsupported' ? 'ski' : 'mountain'],
              );
            }
          }
          await expectLater(
            h.sdk.refreshActivityAvailability(),
            throwsA(isA<NetworkException>()),
          );
          expect(
            (await h.sdk.getActiveActivitySession())?.sessionId,
            original.sessionId,
          );
        } finally {
          await h.dispose();
        }
      },
    );
  }

  test(
    'transient canonical failure retains cache; explicit rejection invalidates it',
    () async {
      final disk = _Disk();
      final original = await _seed(disk);
      final h = _Harness(disk);
      try {
        await h.initialize();
        h.offline = true;
        await expectLater(
          h.sdk.refreshCanonicalIdentity(),
          throwsA(isA<NetworkException>()),
        );
        expect(await h.sdk.getCachedActivityAvailability(), isNotNull);
        expect(
          (await h.sdk.getActiveActivitySession())?.sessionId,
          original.sessionId,
        );
        h.offline = false;
        h.identityStatus = 401;
        await expectLater(
          h.sdk.refreshCanonicalIdentity(),
          throwsA(isA<AuthException>()),
        );
        expect(await h.sdk.getCachedActivityAvailability(), isNull);
      } finally {
        await h.dispose();
      }
    },
  );

  for (final operation in [
    'account',
    'app',
    'logout',
    'backend',
    'credential',
    'dispose',
  ]) {
    test(
      'late canonical result after $operation cannot resurrect old identity',
      () async {
        final disk = _Disk();
        await _seed(disk);
        final h = _Harness(disk);
        Future<EixamSession>? refresh;
        var disposed = false;
        try {
          await h.initialize();
          h.identityGate = Completer<http.Response>();
          refresh = h.sdk.refreshCanonicalIdentity();
          final rejected = expectLater(refresh, throwsA(isA<Exception>()));
          await pumpEventQueue();
          if (operation == 'logout') {
            await h.sdk.clearSession().timeout(_watchdog);
          } else if (operation == 'backend') {
            await h
                .initialize(backend: 'https://other.test')
                .timeout(_watchdog);
          } else if (operation == 'dispose') {
            await h.dispose().timeout(_watchdog);
            disposed = true;
          } else {
            await h.sdk
                .setSession(
                  _identity.copyWith(
                    externalUserId: operation == 'account' ? 'user-b' : null,
                    appId: operation == 'app' ? 'other-app' : null,
                    userHash: operation == 'credential' ? 'rotated' : null,
                    sdkUserId: operation == 'account' ? 'sdk-b' : 'sdk-a',
                  ),
                  deferRuntimeWork: true,
                )
                .timeout(_watchdog);
          }
          h.releaseIdentity();
          await rejected;
          if (!disposed) {
            final current = await h.sdk.getCurrentSession();
            if (operation == 'logout' || operation == 'backend') {
              expect(current, isNull);
            } else {
              expect(
                current?.externalUserId,
                operation == 'account' ? 'user-b' : 'user-a',
              );
              expect(
                current?.userHash,
                operation == 'credential' ? 'rotated' : 'signed-a',
              );
            }
            if (operation != 'credential') {
              expect(await h.sdk.getActiveActivitySession(), isNull);
              expect(await h.sdk.getCachedActivityAvailability(), isNull);
            }
          }
        } finally {
          h.releaseIdentity();
          if (refresh != null) {
            await refresh.catchError((Object _) => _identity);
          }
          if (!disposed) await h.dispose();
        }
      },
    );
  }

  test(
    'same principal signing rotation preserves identity; explicit canonical conflict fails closed',
    () async {
      final disk = _Disk();
      final original = await _seed(disk);
      final h = _Harness(disk)..offline = true;
      try {
        await h.initialize();
        await h.sdk.setSession(
          _appSnapshot.copyWith(userHash: 'rotated'),
          deferRuntimeWork: true,
        );
        expect(
          (await h.sdk.getActiveActivitySession())?.sessionId,
          original.sessionId,
        );
        expect((await h.sdk.getCurrentSession())?.userHash, 'rotated');
        expect((await h.sdk.getCurrentSession())?.sdkUserId, 'sdk-a');
        await expectLater(
          h.sdk.setSession(
            _identity.copyWith(sdkUserId: 'contradictory'),
            deferRuntimeWork: true,
          ),
          throwsA(isA<AuthException>()),
        );
      } finally {
        await h.dispose();
      }
    },
  );

  test(
    'authorization rejection fences availability HTTP already pending',
    () async {
      final disk = _Disk();
      await _seed(disk);
      final h = _Harness(disk);
      Future<SdkActivityAvailability>? pending;
      try {
        await h.initialize();
        h.availabilityGate = Completer<http.Response>();
        pending = h.sdk.refreshActivityAvailability();
        final rejected = expectLater(
          pending,
          throwsA(isA<ActivityAvailabilityException>()),
        );
        await pumpEventQueue();
        h.identityStatus = 401;
        await expectLater(
          h.sdk.refreshCanonicalIdentity(),
          throwsA(isA<AuthException>()),
        );
        expect(await h.sdk.getCachedActivityAvailability(), isNull);
        h.availabilityGate!.complete(http.Response('{"activities":[]}', 200));
        await rejected;
        expect(await h.sdk.getCachedActivityAvailability(), isNull);
      } finally {
        if (h.availabilityGate?.isCompleted == false) {
          h.availabilityGate!.complete(http.Response('{"activities":[]}', 200));
        }
        if (pending != null) {
          await pending.catchError(
            (Object _) => SdkActivityAvailability(
              activities: [],
              fetchedAt: DateTime.now(),
              fromCache: false,
            ),
          );
        }
        await h.dispose();
      }
    },
  );

  test(
    'deferred runtime cannot reconnect A after logout during registry HTTP',
    () async {
      final disk = _Disk();
      await _seed(disk);
      final registry = _PendingRegistry();
      final h = _Harness(disk, registry: registry);
      Future<void>? runtime;
      try {
        await h.initialize();
        await h.sdk.setSession(_appSnapshot, deferRuntimeWork: true);
        runtime = h.sdk.startDeferredRuntime();
        final rejected = expectLater(runtime, throwsA(isA<AuthException>()));
        await registry.entered.future.timeout(_watchdog);
        await h.sdk.clearSession().timeout(_watchdog);
        registry.gate.complete([]);
        await rejected;
        expect(h.realtime.connectCallCount, 0);
        expect(await h.sdk.getCurrentSession(), isNull);
      } finally {
        if (!registry.gate.isCompleted) registry.gate.complete([]);
        if (runtime != null) await runtime.catchError((Object _) {});
        await h.dispose();
      }
    },
  );

  test(
    'queued stale authorization rejection cannot clear replacement credentials cache',
    () async {
      final local = _GatedLocalStore();
      final disk = _Disk(local: local);
      await _seed(disk);
      final h = _Harness(disk);
      try {
        await h.initialize();
        local.readGate = Completer<void>();
        final read = h.sdk.getCachedActivityAvailability();
        final readRejected = expectLater(
          read,
          throwsA(isA<ActivityAvailabilityException>()),
        );
        await pumpEventQueue();
        h.identityStatus = 401;
        final auth = expectLater(
          h.sdk.refreshCanonicalIdentity(),
          throwsA(isA<Exception>()),
        );
        await pumpEventQueue();
        final binding = h.sdk.setSession(
          _identity.copyWith(userHash: 'new-signature'),
          deferRuntimeWork: true,
        );
        local.readGate!.complete();
        await readRejected;
        await auth;
        await binding;
        expect(
          (await h.sdk.getCachedActivityAvailability())?.activities.single.key,
          'mountain',
        );
        expect((await h.sdk.getCurrentSession())?.userHash, 'new-signature');
      } finally {
        if (local.readGate?.isCompleted == false) local.readGate!.complete();
        await h.dispose();
      }
    },
  );

  test('legacy identity requires online backend provenance upgrade', () async {
    final disk = _Disk();
    await _seed(disk);
    await SdkSessionStore(
      localStore: disk.local,
      secureStore: disk.secure,
    ).save(_identity);
    final offline = _Harness(disk)..offline = true;
    try {
      await expectLater(offline.initialize(), throwsA(isA<NetworkException>()));
    } finally {
      await offline.dispose();
    }
    final online = _Harness(disk);
    try {
      await online.initialize();
      expect(online.identityRequests, 1);
    } finally {
      await online.dispose();
    }
    final recovered = _Harness(disk)..offline = true;
    try {
      await recovered.initialize();
      await recovered.sdk.setSession(_appSnapshot, deferRuntimeWork: true);
      expect(await recovered.sdk.getActiveActivitySession(), isNotNull);
      expect(recovered.identityRequests, 0);
    } finally {
      await recovered.dispose();
    }
  });

  test(
    'persisted backend mismatch cannot lend canonical metadata to incomplete snapshot',
    () async {
      final disk = _Disk();
      await _seed(disk);
      final h = _Harness(disk)..offline = true;
      try {
        await h.initialize(backend: 'https://other.test');
        expect(await h.sdk.getCurrentSession(), isNull);
        expect(await h.sdk.getActiveActivitySession(), isNull);
        expect(await h.sdk.getCachedActivityAvailability(), isNull);
        await expectLater(
          h.sdk.setSession(_appSnapshot, deferRuntimeWork: true),
          throwsA(isA<NetworkException>()),
        );
      } finally {
        await h.dispose();
      }
    },
  );

  test(
    'deferred binding exposes local state before pending SOS reconciliation',
    () async {
      final disk = _Disk();
      final original = await _seed(disk);
      final sos = _PendingSos();
      final h = _Harness(disk, sos: sos);
      Future<void>? runtime;
      try {
        await h.initialize();
        await h.sdk.setSession(_appSnapshot, deferRuntimeWork: true);
        expect(sos.rehydrateCallCount, 0);
        runtime = h.sdk.startDeferredRuntime();
        await pumpEventQueue();
        expect(sos.rehydrateCallCount, 1);
        expect(
          (await h.sdk.getActiveActivitySession().timeout(
            _watchdog,
          ))?.sessionId,
          original.sessionId,
        );
        expect(
          (await h.sdk.getCachedActivityAvailability().timeout(
            _watchdog,
          ))?.fromCache,
          isTrue,
        );
        expect(h.tracking.startCallCount, 0);
        expect(sos.triggerCallCount, 0);
        sos.gate.complete(sos.rehydrationResult);
        await runtime;
      } finally {
        if (!sos.gate.isCompleted) sos.gate.complete(sos.rehydrationResult);
        if (runtime != null) await runtime;
        await h.dispose();
      }
    },
  );

  test(
    'offline new Start and End stay local; reconnect preserves existing identity',
    () async {
      final disk = _Disk();
      final original = await _seed(disk);
      final h = _Harness(disk)..offline = true;
      try {
        await h.initialize();
        await h.sdk.setSession(_appSnapshot, deferRuntimeWork: true);
        await h.sdk.endActivitySession(sessionId: original.sessionId);
        final started = await h.sdk.startActivitySession(
          activityKey: 'mountain',
        );
        expect(started.sessionId, isNot(original.sessionId));
        expect(
          (await h.sdk.getCachedActivityAvailability())?.activities.single.key,
          'mountain',
        );
        h.offline = false;
        await h.sdk.refreshCanonicalIdentity();
        expect((await h.sdk.refreshActivityAvailability()).fromCache, isFalse);
        expect(
          (await h.sdk.getActiveActivitySession())?.sessionId,
          started.sessionId,
        );
        expect(h.tracking.startCallCount, 0);
        expect(h.sos.triggerCallCount, 0);
        await h.sdk.endActivitySession(sessionId: started.sessionId);
      } finally {
        await h.dispose();
      }
    },
  );
}

class _Disk {
  _Disk({MemorySharedPrefsSdkStore? local})
    : local = local ?? MemorySharedPrefsSdkStore();
  final MemorySharedPrefsSdkStore local;
  final secure = InMemorySecureKeyValueStore();
}

Future<SdkActivitySession> _seed(
  _Disk disk, {
  List<String> keys = const ['mountain'],
}) async {
  final h = _Harness(disk)..keys = keys;
  try {
    await h.initialize();
    await h.sdk.setSession(_identity, deferRuntimeWork: true);
    await h.sdk.refreshActivityAvailability();
    return await h.sdk.startActivitySession(activityKey: 'mountain');
  } finally {
    await h.dispose();
  }
}

class _Harness {
  _Harness(
    _Disk disk, {
    FakeSosRepository? sos,
    SdkDeviceRegistryRepository? registry,
  }) : sos = sos ?? FakeSosRepository() {
    client = MockClient((request) async {
      if (request.url.path == '/v1/sdk/me') {
        identityRequests++;
        if (identityGate case final gate?) return gate.future;
        if (offline) throw http.ClientException('offline', request.url);
        return identityResponse();
      }
      expect(request.url.path, '/v1/sdk/activities');
      if (availabilityGate case final gate?) return gate.future;
      if (offline) throw http.ClientException('offline', request.url);
      return http.Response(
        jsonEncode({
          'activities': [
            for (final key in keys)
              {'id': '2abf4d30-534c-48bf-acd2-fcb38a0a00ed', 'key': key},
          ],
        }),
        200,
      );
    });
    final context = SdkSessionContext();
    final transport = SdkHttpTransport(
      client: client,
      config: const EixamSdkConfig(apiBaseUrl: _backend),
      sessionContext: context,
    );
    sdk = EixamConnectSdkImpl(
      sosRepository: this.sos,
      trackingRepository: tracking,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: contacts,
      deviceRepository: device,
      deviceRegistryRepository: registry ?? FakeSdkDeviceRegistryRepository(),
      deathManRepository: deathMan,
      permissionsRepository: FakePermissionsRepository(),
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: realtime,
      deviceSosController: DeviceSosController(),
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: disk.local),
      sessionStore: SdkSessionStore(
        localStore: disk.local,
        secureStore: disk.secure,
      ),
      sessionContext: context,
      localStore: disk.local,
      identityRemoteDataSource: HttpSdkIdentityRemoteDataSource(
        transport: transport,
      ),
      activityAvailabilityRemoteDataSource:
          HttpSdkActivityAvailabilityRemoteDataSource(transport: transport),
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
      backgroundLocationPlatformAdapter:
          UnsupportedBackgroundLocationPlatformAdapter(),
    );
  }
  final FakeSosRepository sos;
  final tracking = FakeTrackingRepository();
  final contacts = FakeContactsRepository();
  final device = FakeDeviceRepository(
    initialStatus: buildDeviceStatus(
      connected: false,
      paired: false,
      activated: false,
    ),
  );
  final deathMan = FakeDeathManRepository();
  final realtime = FakeRealtimeClient();
  late final MockClient client;
  late final EixamConnectSdkImpl sdk;
  bool offline = false;
  int identityStatus = 200;
  int identityRequests = 0;
  List<String> keys = ['mountain'];
  Completer<http.Response>? identityGate;
  Completer<http.Response>? availabilityGate;
  http.Response identityResponse() => http.Response(
    jsonEncode({
      'user': {'id': 'sdk-a', 'external_user_id': 'user-a'},
    }),
    identityStatus,
  );
  void releaseIdentity() {
    final gate = identityGate;
    if (gate != null && !gate.isCompleted) gate.complete(identityResponse());
  }

  Future<void> initialize({String backend = _backend}) => sdk.initialize(
    EixamSdkConfig(apiBaseUrl: backend, deferRuntimeStartup: true),
  );
  Future<void> dispose() async {
    await sdk.dispose();
    await tracking.dispose();
    await contacts.dispose();
    await device.dispose();
    await deathMan.dispose();
    await realtime.dispose();
    await sos.dispose();
    client.close();
  }
}

class _GatedLocalStore extends MemorySharedPrefsSdkStore {
  Completer<void>? readGate;
  @override
  Future<String?> readFreshString(String key) async {
    if (key == SharedPrefsSdkStore.activityAvailabilityKey &&
        readGate != null) {
      await readGate!.future;
    }
    return super.readFreshString(key);
  }
}

class _PendingSos extends FakeRehydratingSosRepository {
  final gate = Completer<SosRuntimeRehydrationResult>();
  @override
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend({
    bool terminalAbsenceExpected = false,
  }) {
    rehydrateCallCount++;
    return gate.future;
  }
}

class _PendingRegistry extends FakeSdkDeviceRegistryRepository {
  final gate = Completer<List<BackendRegisteredDevice>>();
  final entered = Completer<void>();
  @override
  Future<List<BackendRegisteredDevice>> listRegisteredDevices() {
    if (!entered.isCompleted) entered.complete();
    return gate.future;
  }
}
