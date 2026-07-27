import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/android_tracking_owner_arbiter.dart';
import 'package:eixam_connect_flutter/src/sdk/authoritative_sos_lifecycle_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_location_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_location_ownership_effect.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_location_ownership_platform_sink.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS SOS sink', () {
    test('adds and removes only SOS while preserving sharing and DMP',
        () async {
      final adapter = _BackgroundLocationAdapter(
        contexts: <BackgroundLocationContext>{
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
        },
      );
      final sink = IosSosLocationOwnershipEffectSink(
        platformAdapter: adapter,
      );

      await sink.apply(SosLocationOwnershipEffect.activateSosLocation);
      expect(adapter.contexts, <BackgroundLocationContext>{
        BackgroundLocationContext.sharing,
        BackgroundLocationContext.dmp,
        BackgroundLocationContext.sos,
      });
      await sink.apply(SosLocationOwnershipEffect.deactivateSosLocation);

      expect(adapter.contexts, <BackgroundLocationContext>{
        BackgroundLocationContext.sharing,
        BackgroundLocationContext.dmp,
      });
      expect(
        adapter.setCalls,
        <({BackgroundLocationContext context, bool active})>[
          (context: BackgroundLocationContext.sos, active: true),
          (context: BackgroundLocationContext.sos, active: false),
        ],
      );
    });

    test('degraded permission retains requested SOS without toggling',
        () async {
      final adapter = _BackgroundLocationAdapter(
        contexts: <BackgroundLocationContext>{
          BackgroundLocationContext.sos,
        },
        running: false,
      );
      final sink = IosSosLocationOwnershipEffectSink(
        platformAdapter: adapter,
      );

      await sink.reconcile(
        true,
        SosLocationOwnershipReconciliationReason.permissionOrStatusChange,
      );

      expect(adapter.setCalls, isEmpty);
      expect(sink.platformState.requestedOwnership, isTrue);
      expect(sink.platformState.appliedOwnership, isTrue);
      expect(sink.platformState.running, isFalse);
    });

    test('failed channel call is retryable on later reconciliation', () async {
      final adapter = _BackgroundLocationAdapter(
        contexts: <BackgroundLocationContext>{},
      )..failNextSet = true;
      final sink = IosSosLocationOwnershipEffectSink(
        platformAdapter: adapter,
      );

      await expectLater(
        sink.apply(SosLocationOwnershipEffect.activateSosLocation),
        throwsA(isA<BackgroundLocationAdapterException>()),
      );
      await sink.reconcile(
        true,
        SosLocationOwnershipReconciliationReason.sdkRuntime,
      );

      expect(adapter.setCalls.length, 2);
      expect(adapter.contexts, contains(BackgroundLocationContext.sos));
    });

    test('aligned reconciliation performs no platform mutation', () async {
      final adapter = _BackgroundLocationAdapter(
        contexts: <BackgroundLocationContext>{
          BackgroundLocationContext.sos,
        },
      );
      final sink = IosSosLocationOwnershipEffectSink(
        platformAdapter: adapter,
      );

      await sink.reconcile(
        true,
        SosLocationOwnershipReconciliationReason.sdkRuntime,
      );
      await sink.reconcile(
        true,
        SosLocationOwnershipReconciliationReason.sdkRuntime,
      );

      expect(adapter.setCalls, isEmpty);
    });

    test('lifecycle disposal drains a delayed effect before adapter disposal',
        () async {
      final adapter = _BackgroundLocationAdapter(
        contexts: <BackgroundLocationContext>{},
      );
      final delayedSet = Completer<void>();
      adapter.delayNextSet = delayedSet;
      final controller = AuthoritativeSosLifecycleController(
        secureStore: InMemorySecureKeyValueStore(),
        locationOwnershipEffectSink: IosSosLocationOwnershipEffectSink(
          platformAdapter: adapter,
        ),
        locationOwnershipEffectMode: SosLocationOwnershipEffectMode.enabled,
      );
      const owner = EixamSession.signed(
        appId: 'partner',
        externalUserId: 'owner',
        userHash: 'hash',
      );

      await controller.restoreFor(owner);
      await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'local-1',
      );
      final disposal = () async {
        await controller.dispose();
        await adapter.dispose();
      }();
      await pumpEventQueue();

      expect(adapter.setCalls, hasLength(1));
      expect(adapter.disposed, isFalse);
      delayedSet.complete();
      await disposal.timeout(const Duration(seconds: 1));

      expect(adapter.disposed, isTrue);
      expect(adapter.callsAfterDisposal, 0);
    });
  });

  group('Android SOS sink', () {
    test('uses only the SOS owner and preserves legacy public tracking',
        () async {
      final repository = _TrackingRepository();
      final arbiter = AndroidTrackingOwnerArbiter(
        trackingRepository: repository,
      );
      addTearDown(arbiter.dispose);
      final sink = AndroidSosLocationOwnershipEffectSink(
        trackingOwnerArbiter: arbiter,
      );

      await arbiter.addOwner(AndroidTrackingOwner.legacyPublicTracking);
      await sink.apply(SosLocationOwnershipEffect.activateSosLocation);
      await sink.apply(SosLocationOwnershipEffect.deactivateSosLocation);

      expect(repository.startCount, 1);
      expect(repository.stopCount, 0);
      expect(
        arbiter.diagnostics.requestedOwners,
        <AndroidTrackingOwner>{AndroidTrackingOwner.legacyPublicTracking},
      );
    });

    test('reconciliation adds, retries, and removes only SOS', () async {
      final repository = _TrackingRepository();
      final arbiter = AndroidTrackingOwnerArbiter(
        trackingRepository: repository,
      );
      addTearDown(arbiter.dispose);
      final sink = AndroidSosLocationOwnershipEffectSink(
        trackingOwnerArbiter: arbiter,
      );

      await sink.reconcile(
        true,
        SosLocationOwnershipReconciliationReason
            .initializationAfterLifecycleRestoration,
      );
      repository.state = TrackingState.idle;
      await sink.reconcile(
        true,
        SosLocationOwnershipReconciliationReason.sdkRuntime,
      );
      await sink.reconcile(
        false,
        SosLocationOwnershipReconciliationReason.sdkRuntime,
      );

      expect(repository.startCount, 2);
      expect(repository.stopCount, 1);
    });

    test('lifecycle tail drains before tracking repository disposal', () async {
      final repository = _TrackingRepository();
      final delayedStart = Completer<void>();
      repository.delayNextStart = delayedStart;
      final arbiter = AndroidTrackingOwnerArbiter(
        trackingRepository: repository,
      );
      final controller = AuthoritativeSosLifecycleController(
        secureStore: InMemorySecureKeyValueStore(),
        locationOwnershipEffectSink: AndroidSosLocationOwnershipEffectSink(
          trackingOwnerArbiter: arbiter,
        ),
        locationOwnershipEffectMode: SosLocationOwnershipEffectMode.enabled,
      );
      const owner = EixamSession.signed(
        appId: 'partner',
        externalUserId: 'owner',
        userHash: 'hash',
      );

      await controller.restoreFor(owner);
      await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'local-1',
      );
      final disposal = () async {
        await controller.dispose();
        await arbiter.dispose();
        repository.dispose();
      }();
      await pumpEventQueue();

      expect(repository.startCount, 1);
      expect(repository.disposed, isFalse);
      delayedStart.complete();
      await disposal.timeout(const Duration(seconds: 1));

      expect(repository.disposed, isTrue);
      expect(repository.callsAfterDisposal, 0);
    });
  });

  group('factory and effect modes', () {
    late _TrackingRepository repository;
    late AndroidTrackingOwnerArbiter arbiter;
    late _BackgroundLocationAdapter adapter;

    setUp(() {
      repository = _TrackingRepository();
      arbiter = AndroidTrackingOwnerArbiter(
        trackingRepository: repository,
      );
      adapter = _BackgroundLocationAdapter(
        contexts: <BackgroundLocationContext>{},
      );
    });

    tearDown(() => arbiter.dispose());

    SosLocationOwnershipEffectSink build(
      TargetPlatform platform,
      SosLocationOwnershipEffectMode mode, {
      bool isWeb = false,
    }) =>
        createSosLocationOwnershipEffectSink(
          platform: platform,
          isWeb: isWeb,
          effectMode: mode,
          trackingOwnerArbiter: arbiter,
          backgroundLocationPlatformAdapter: adapter,
        );

    test('disabled is no-op on Android and iOS', () {
      expect(
        build(TargetPlatform.android, SosLocationOwnershipEffectMode.disabled),
        isA<NoopSosLocationOwnershipEffectSink>(),
      );
      expect(
        build(TargetPlatform.iOS, SosLocationOwnershipEffectMode.disabled),
        isA<NoopSosLocationOwnershipEffectSink>(),
      );
    });

    test('observe records prediction without platform effects', () async {
      for (final platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final sink = build(
          platform,
          SosLocationOwnershipEffectMode.observe,
        );
        await sink.apply(SosLocationOwnershipEffect.activateSosLocation);
      }

      expect(repository.startCount, 0);
      expect(adapter.setCalls, isEmpty);
    });

    test('production-enabled mode selects Android and iOS implementations', () {
      expect(
        build(TargetPlatform.android, SosLocationOwnershipEffectMode.enabled),
        isA<AndroidSosLocationOwnershipEffectSink>(),
      );
      expect(
        build(TargetPlatform.iOS, SosLocationOwnershipEffectMode.enabled),
        isA<IosSosLocationOwnershipEffectSink>(),
      );
    });

    test('web and unsupported platforms remain no-op', () {
      expect(
        build(
          TargetPlatform.android,
          SosLocationOwnershipEffectMode.enabled,
          isWeb: true,
        ),
        isA<NoopSosLocationOwnershipEffectSink>(),
      );
      expect(
        build(TargetPlatform.linux, SosLocationOwnershipEffectMode.enabled),
        isA<NoopSosLocationOwnershipEffectSink>(),
      );
    });
  });
}

final class _TrackingRepository implements TrackingRepository {
  int startCount = 0;
  int stopCount = 0;
  TrackingState state = TrackingState.idle;
  Completer<void>? delayNextStart;
  bool disposed = false;
  int callsAfterDisposal = 0;

  @override
  Future<TrackingPosition?> getCurrentPosition() async => null;

  @override
  Future<TrackingState> getTrackingState() async => state;

  @override
  Future<void> startTracking() async {
    if (disposed) {
      callsAfterDisposal += 1;
      throw StateError('repository disposed');
    }
    startCount += 1;
    final delay = delayNextStart;
    delayNextStart = null;
    if (delay != null) {
      await delay.future;
    }
    if (disposed) {
      callsAfterDisposal += 1;
      throw StateError('repository disposed');
    }
    state = TrackingState.tracking;
  }

  @override
  Future<void> stopTracking() async {
    stopCount += 1;
    state = TrackingState.idle;
  }

  @override
  Stream<TrackingPosition> watchPositions() => const Stream.empty();

  @override
  Stream<TrackingState> watchTrackingState() => const Stream.empty();

  void dispose() {
    disposed = true;
  }
}

final class _BackgroundLocationAdapter
    implements BackgroundLocationPlatformAdapter {
  _BackgroundLocationAdapter({
    required Set<BackgroundLocationContext> contexts,
    this.running = true,
  }) : contexts = Set<BackgroundLocationContext>.of(contexts);

  final Set<BackgroundLocationContext> contexts;
  final bool running;
  bool failNextSet = false;
  Completer<void>? delayNextSet;
  bool disposed = false;
  int callsAfterDisposal = 0;
  final List<({BackgroundLocationContext context, bool active})> setCalls =
      <({BackgroundLocationContext context, bool active})>[];

  BackgroundLocationRuntimeStatus get status => BackgroundLocationRuntimeStatus(
        activeContexts: contexts,
        isNativePlatformSupported: true,
        isNativeServiceRunning: running,
        permission: const LocationPermissionSnapshot(
          locationServicesEnabled: true,
          authorizationStatus: LocationAuthorizationStatus.always,
          accuracyAuthorization: LocationAccuracyAuthorization.full,
        ),
      );

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<BackgroundLocationRuntimeStatus> getBackgroundLocationStatus() async =>
      status;

  @override
  Future<LocationPermissionSnapshot> getLocationPermissionSnapshot() async =>
      status.permission;

  @override
  Future<LocationPermissionSnapshot> requestLocationAlwaysPermission() async =>
      status.permission;

  @override
  Future<LocationPermissionSnapshot>
      requestLocationWhenInUsePermission() async => status.permission;

  @override
  Future<BackgroundLocationRuntimeStatus> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  }) async {
    if (disposed) {
      callsAfterDisposal += 1;
      throw StateError('adapter disposed');
    }
    setCalls.add((context: context, active: active));
    if (failNextSet) {
      failNextSet = false;
      throw const BackgroundLocationAdapterException(
        'controlled_channel_failure',
        'controlled',
      );
    }
    final delay = delayNextSet;
    delayNextSet = null;
    if (delay != null) {
      await delay.future;
    }
    if (disposed) {
      callsAfterDisposal += 1;
      throw StateError('adapter disposed');
    }
    if (active) {
      contexts.add(context);
    } else {
      contexts.remove(context);
    }
    return status;
  }

  @override
  Stream<BackgroundLocationRuntimeStatus> watchBackgroundLocationStatus() =>
      const Stream.empty();
}
