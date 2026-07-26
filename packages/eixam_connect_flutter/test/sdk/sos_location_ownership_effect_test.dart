import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/authoritative_sos_lifecycle_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_location_ownership_effect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const owner = EixamSession.signed(
    appId: 'partner',
    externalUserId: 'owner',
    userHash: 'hash',
  );

  group('authoritative lifecycle effect wiring', () {
    late InMemorySecureKeyValueStore store;
    late RecordingSosLocationOwnershipEffectSink sink;
    late AuthoritativeSosLifecycleController controller;

    setUp(() {
      store = InMemorySecureKeyValueStore();
      sink = RecordingSosLocationOwnershipEffectSink();
      controller = AuthoritativeSosLifecycleController(
        secureStore: store,
        clock: () => DateTime.utc(2026, 7, 26),
        locationOwnershipEffectSink: sink,
      );
    });

    tearDown(() => controller.dispose());

    Future<void> activate({String incidentId = 'local-1'}) async {
      await controller.restoreFor(owner);
      await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: incidentId,
      );
      await controller.locationOwnershipEffectDispatcher.whenIdle;
    }

    test('local active emits one typed activation command', () async {
      await activate();

      expect(sink.effects, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
      ]);
    });

    test('duplicate and newer-revision active do not duplicate activation',
        () async {
      await activate();
      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'local-1',
      );
      await controller.locationOwnershipEffectDispatcher.whenIdle;

      expect(sink.effects, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
      ]);
    });

    test('cancelling and cancellation failure retain active ownership',
        () async {
      await activate();
      await controller.beginCancellation();
      await controller.cancellationFailed('E_CONTROLLED');
      await controller.locationOwnershipEffectDispatcher.whenIdle;

      expect(sink.effects, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
      ]);
    });

    test('cancelled and resolved each deactivate current ownership once',
        () async {
      await activate();
      await controller.confirmTerminal(stage: SosLifecycleStage.cancelled);
      await controller.confirmTerminal(stage: SosLifecycleStage.resolved);
      await controller.locationOwnershipEffectDispatcher.whenIdle;

      expect(sink.effects, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
        SosLocationOwnershipEffect.deactivateSosLocation,
      ]);
    });

    test('activation failure while inactive emits no command', () async {
      await controller.restoreFor(owner);
      await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
      await controller.activationFailed('E_CONTROLLED');
      await controller.locationOwnershipEffectDispatcher.whenIdle;

      expect(sink.effects, isEmpty);
    });

    test('restored locally owned lifecycle emits activation', () async {
      await activate();
      final restoredSink = RecordingSosLocationOwnershipEffectSink();
      final restored = AuthoritativeSosLifecycleController(
        secureStore: store,
        clock: () => DateTime.utc(2026, 7, 26, 0, 1),
        locationOwnershipEffectSink: restoredSink,
      );
      addTearDown(restored.dispose);

      await restored.restoreFor(owner);
      await restored.locationOwnershipEffectDispatcher.whenIdle;

      expect(restoredSink.effects, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
      ]);
    });

    test('idle restoration does not emit unnecessary deactivation', () async {
      await controller.restoreFor(owner);
      await controller.locationOwnershipEffectDispatcher.whenIdle;

      expect(sink.effects, isEmpty);
    });

    test('activate then terminal is delivered in order', () async {
      await activate();
      await controller.confirmTerminal(stage: SosLifecycleStage.resolved);
      await controller.locationOwnershipEffectDispatcher.whenIdle;

      expect(sink.effects, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
        SosLocationOwnershipEffect.deactivateSosLocation,
      ]);
    });

    test('disposal prevents commands from later publications', () async {
      await controller.dispose();

      await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'after-dispose',
      );
      await controller.locationOwnershipEffectDispatcher.whenIdle;

      expect(sink.effects, isEmpty);
      expect(
        controller.locationOwnershipEffectDispatcher.diagnostics.disposed,
        isTrue,
      );
    });

    test('default production boundary is a completed no-op', () async {
      final production = AuthoritativeSosLifecycleController(
        secureStore: InMemorySecureKeyValueStore(),
      );
      addTearDown(production.dispose);

      await production.restoreFor(owner);
      await production.beginActivating(origin: SosLifecycleOrigin.localApp);
      await production.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'production-noop',
      );
      await production.locationOwnershipEffectDispatcher.whenIdle;

      final diagnostics =
          production.locationOwnershipEffectDispatcher.diagnostics;
      expect(diagnostics.emittedCommandCount, 1);
      expect(diagnostics.completedCommandCount, 1);
      expect(diagnostics.failureCount, 0);
      expect(
        diagnostics.lastEffect,
        SosLocationOwnershipEffect.activateSosLocation,
      );
    });
  });

  group('serialized effect delivery', () {
    test('delayed activation completes before deactivation starts', () async {
      final sink = DelayedSosLocationOwnershipEffectSink();
      final dispatcher = SosLocationOwnershipEffectDispatcher(sink: sink);

      dispatcher.offer(SosLocationOwnershipEffect.activateSosLocation);
      dispatcher.offer(SosLocationOwnershipEffect.deactivateSosLocation);
      await pumpEventQueue();

      expect(sink.started, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
      ]);
      sink.completeNext();
      await pumpEventQueue();
      expect(sink.completed, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
      ]);
      expect(sink.started, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
        SosLocationOwnershipEffect.deactivateSosLocation,
      ]);

      sink.completeNext();
      await dispatcher.whenIdle;
      expect(sink.completed, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
        SosLocationOwnershipEffect.deactivateSosLocation,
      ]);
    });

    test('failing activation is isolated and later command continues',
        () async {
      final sink = FailingSosLocationOwnershipEffectSink();
      final dispatcher = SosLocationOwnershipEffectDispatcher(sink: sink);

      dispatcher.offer(SosLocationOwnershipEffect.activateSosLocation);
      dispatcher.offer(SosLocationOwnershipEffect.deactivateSosLocation);
      await dispatcher.whenIdle;

      expect(sink.effects, <SosLocationOwnershipEffect>[
        SosLocationOwnershipEffect.activateSosLocation,
        SosLocationOwnershipEffect.deactivateSosLocation,
      ]);
      expect(dispatcher.diagnostics.failureCount, 2);
      expect(dispatcher.diagnostics.completedCommandCount, 0);
    });

    test('sink failure cannot alter authoritative lifecycle or public stream',
        () async {
      final errors = <Object>[];
      final controller = AuthoritativeSosLifecycleController(
        secureStore: InMemorySecureKeyValueStore(),
        locationOwnershipEffectSink: FailingSosLocationOwnershipEffectSink(),
      );
      final subscription =
          controller.stream.listen((_) {}, onError: errors.add);
      addTearDown(subscription.cancel);
      addTearDown(controller.dispose);

      await controller.restoreFor(owner);
      await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'failure-isolated',
      );
      await controller.locationOwnershipEffectDispatcher.whenIdle;
      expect(controller.current.stage, SosLifecycleStage.active);

      await controller.confirmTerminal(stage: SosLifecycleStage.cancelled);
      await controller.locationOwnershipEffectDispatcher.whenIdle;

      expect(controller.current.stage, SosLifecycleStage.cancelled);
      expect(errors, isEmpty);
      expect(
        controller.locationOwnershipEffectDispatcher.diagnostics.failureCount,
        2,
      );
    });
  });

  group('future iOS mapping contract', () {
    test('activate maps only to SOS context true and preserves sharing/DMP',
        () async {
      final control = FakeBackgroundLocationContextControl(
        activeContexts: <BackgroundLocationContext>{
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
        },
      );
      final sink = FutureIosSosLocationOwnershipEffectSink(control);

      await sink.apply(SosLocationOwnershipEffect.activateSosLocation);

      expect(
          control.calls, <({BackgroundLocationContext context, bool active})>[
        (
          context: BackgroundLocationContext.sos,
          active: true,
        ),
      ]);
      expect(control.activeContexts, <BackgroundLocationContext>{
        BackgroundLocationContext.sharing,
        BackgroundLocationContext.dmp,
        BackgroundLocationContext.sos,
      });
    });

    test('deactivate maps only to SOS context false and preserves sharing/DMP',
        () async {
      final control = FakeBackgroundLocationContextControl(
        activeContexts: <BackgroundLocationContext>{
          BackgroundLocationContext.sharing,
          BackgroundLocationContext.dmp,
          BackgroundLocationContext.sos,
        },
      );
      final sink = FutureIosSosLocationOwnershipEffectSink(control);

      await sink.apply(SosLocationOwnershipEffect.deactivateSosLocation);

      expect(
          control.calls, <({BackgroundLocationContext context, bool active})>[
        (
          context: BackgroundLocationContext.sos,
          active: false,
        ),
      ]);
      expect(control.activeContexts, <BackgroundLocationContext>{
        BackgroundLocationContext.sharing,
        BackgroundLocationContext.dmp,
      });
    });
  });

  group('future Android compatibility characterization', () {
    test('activation reuses tracking without permissions or native service',
        () {
      const planner = FutureAndroidSosLocationCompatibilityPlanner();

      expect(
        planner.plan(
          SosLocationOwnershipEffect.activateSosLocation,
          manualSharingActive: false,
        ),
        AndroidSosCompatibilityOperation.startExistingSdkTracking,
      );
      expect(
        planner.forbiddenOperations,
        containsAll(<AndroidSosCompatibilityOperation>{
          AndroidSosCompatibilityOperation.requestLocationPermission,
          AndroidSosCompatibilityOperation.startNativeForegroundService,
          AndroidSosCompatibilityOperation.changeNativeCadence,
        }),
      );
    });

    test('deactivation never stops manually owned sharing', () {
      const planner = FutureAndroidSosLocationCompatibilityPlanner();

      expect(
        planner.plan(
          SosLocationOwnershipEffect.deactivateSosLocation,
          manualSharingActive: true,
        ),
        AndroidSosCompatibilityOperation.noOperation,
      );
      expect(
        planner.plan(
          SosLocationOwnershipEffect.deactivateSosLocation,
          manualSharingActive: false,
        ),
        AndroidSosCompatibilityOperation.stopExistingSdkTracking,
      );
      expect(
        planner.forbiddenOperations,
        contains(AndroidSosCompatibilityOperation.disableBackgroundTelemetry),
      );
    });

    test('current arming ownership remains an explicit temporary divergence',
        () {
      expect(
        AndroidSosTrackingOwnership.currentAppArmingBased,
        isNot(AndroidSosTrackingOwnership.futureAuthoritativeActive),
      );
    });
  });
}

final class RecordingSosLocationOwnershipEffectSink
    implements SosLocationOwnershipEffectSink {
  final List<SosLocationOwnershipEffect> effects =
      <SosLocationOwnershipEffect>[];

  @override
  Future<void> apply(SosLocationOwnershipEffect effect) async {
    effects.add(effect);
  }
}

final class FailingSosLocationOwnershipEffectSink
    implements SosLocationOwnershipEffectSink {
  final List<SosLocationOwnershipEffect> effects =
      <SosLocationOwnershipEffect>[];

  @override
  Future<void> apply(SosLocationOwnershipEffect effect) async {
    effects.add(effect);
    throw StateError('raw controlled sink failure');
  }
}

final class DelayedSosLocationOwnershipEffectSink
    implements SosLocationOwnershipEffectSink {
  final List<SosLocationOwnershipEffect> started =
      <SosLocationOwnershipEffect>[];
  final List<SosLocationOwnershipEffect> completed =
      <SosLocationOwnershipEffect>[];
  final List<Completer<void>> _pending = <Completer<void>>[];

  @override
  Future<void> apply(SosLocationOwnershipEffect effect) async {
    started.add(effect);
    final completer = Completer<void>();
    _pending.add(completer);
    await completer.future;
    completed.add(effect);
  }

  void completeNext() {
    _pending.removeAt(0).complete();
  }
}

abstract interface class TestBackgroundLocationContextControl {
  Future<void> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  });
}

final class FakeBackgroundLocationContextControl
    implements TestBackgroundLocationContextControl {
  FakeBackgroundLocationContextControl({
    required Set<BackgroundLocationContext> activeContexts,
  }) : activeContexts = Set<BackgroundLocationContext>.of(activeContexts);

  final Set<BackgroundLocationContext> activeContexts;
  final List<({BackgroundLocationContext context, bool active})> calls =
      <({BackgroundLocationContext context, bool active})>[];

  @override
  Future<void> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  }) async {
    calls.add((context: context, active: active));
    if (active) {
      activeContexts.add(context);
    } else {
      activeContexts.remove(context);
    }
  }
}

final class FutureIosSosLocationOwnershipEffectSink
    implements SosLocationOwnershipEffectSink {
  const FutureIosSosLocationOwnershipEffectSink(this.control);

  final TestBackgroundLocationContextControl control;

  @override
  Future<void> apply(SosLocationOwnershipEffect effect) {
    return control.setBackgroundLocationContext(
      BackgroundLocationContext.sos,
      active: effect == SosLocationOwnershipEffect.activateSosLocation,
    );
  }
}

enum AndroidSosCompatibilityOperation {
  noOperation,
  startExistingSdkTracking,
  stopExistingSdkTracking,
  requestLocationPermission,
  startNativeForegroundService,
  disableBackgroundTelemetry,
  changeNativeCadence,
}

final class FutureAndroidSosLocationCompatibilityPlanner {
  const FutureAndroidSosLocationCompatibilityPlanner();

  Set<AndroidSosCompatibilityOperation> get forbiddenOperations =>
      const <AndroidSosCompatibilityOperation>{
        AndroidSosCompatibilityOperation.requestLocationPermission,
        AndroidSosCompatibilityOperation.startNativeForegroundService,
        AndroidSosCompatibilityOperation.disableBackgroundTelemetry,
        AndroidSosCompatibilityOperation.changeNativeCadence,
      };

  AndroidSosCompatibilityOperation plan(
    SosLocationOwnershipEffect effect, {
    required bool manualSharingActive,
  }) {
    return switch (effect) {
      SosLocationOwnershipEffect.activateSosLocation =>
        AndroidSosCompatibilityOperation.startExistingSdkTracking,
      SosLocationOwnershipEffect.deactivateSosLocation
          when manualSharingActive =>
        AndroidSosCompatibilityOperation.noOperation,
      SosLocationOwnershipEffect.deactivateSosLocation =>
        AndroidSosCompatibilityOperation.stopExistingSdkTracking,
    };
  }
}

enum AndroidSosTrackingOwnership {
  currentAppArmingBased,
  futureAuthoritativeActive,
}
