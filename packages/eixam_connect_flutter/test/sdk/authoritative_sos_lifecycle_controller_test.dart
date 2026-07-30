import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/authoritative_sos_lifecycle_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_location_ownership_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const owner = EixamSession.signed(
    appId: 'partner',
    externalUserId: 'owner-a',
    userHash: 'secret-hash',
  );
  const otherOwner = EixamSession.signed(
    appId: 'partner',
    externalUserId: 'owner-b',
    userHash: 'other-secret-hash',
  );
  late InMemorySecureKeyValueStore store;
  late DateTime now;
  late AuthoritativeSosLifecycleController controller;
  late SosLocationOwnershipOrchestrator shadow;

  setUp(() {
    store = InMemorySecureKeyValueStore();
    now = DateTime.utc(2026, 7, 15, 10);
    shadow = SosLocationOwnershipOrchestrator();
    controller = AuthoritativeSosLifecycleController(
      secureStore: store,
      clock: () => now,
      locationOwnershipOrchestrator: shadow,
    );
  });

  tearDown(() => controller.dispose());

  Future<SosLifecycleSnapshot> activate({String id = 'local-1'}) async {
    await controller.restoreFor(owner);
    await controller.beginActivating(
      origin: SosLifecycleOrigin.localApp,
      triggerSource: 'commercial_app',
      deviceId: 'device-1',
      nodeId: 7,
      hardwareId: 'hardware-1',
    );
    return controller.confirmActive(
      origin: SosLifecycleOrigin.localApp,
      localIncidentId: id,
      backendIncidentId: 'backend-$id',
      triggerSource: 'commercial_app',
      deviceId: 'device-1',
      nodeId: 7,
      hardwareId: 'hardware-1',
    );
  }

  test('local activation persists minimal authoritative provenance', () async {
    final active = await activate();

    expect(active.stage, SosLifecycleStage.active);
    expect(active.localActionable, isTrue);
    expect(
      store.values,
      contains(SecureStorageKeys.sdkSosLifecycleProvenance.value),
    );
    final encoded = store.values.values.single;
    expect(encoded, contains('local-1'));
    expect(encoded, isNot(contains('owner-a')));
    expect(encoded, isNot(contains('secret-hash')));
    expect(encoded, isNot(contains('latitude')));
    expect(encoded, isNot(contains('longitude')));
    expect(encoded, isNot(contains('contacts')));
    expect(encoded, isNot(contains('payload')));
    expect(encoded, isNot(contains('token')));
  });

  test('cadence follows accepted desired ownership across the lifecycle',
      () async {
    final decisions = <(SosLifecycleStage, bool)>[];
    final subscription = controller.cadenceStream.listen(
      (cadence) => decisions.add(
        (
          cadence.lifecycleStage,
          cadence.desiredLocalSosOwnership,
        ),
      ),
    );
    addTearDown(subscription.cancel);

    await controller.restoreFor(owner);
    await controller.beginArming(origin: SosLifecycleOrigin.localApp);
    await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
    await controller.confirmActive(
      origin: SosLifecycleOrigin.localApp,
      localIncidentId: 'local-cadence',
    );
    await controller.beginCancellation();
    await controller.cancellationFailed('E_CONTROLLED');
    await controller.confirmTerminal(stage: SosLifecycleStage.cancelled);

    expect(decisions, <(SosLifecycleStage, bool)>[
      (SosLifecycleStage.idle, false),
      (SosLifecycleStage.arming, false),
      (SosLifecycleStage.activating, false),
      (SosLifecycleStage.active, true),
      (SosLifecycleStage.cancelling, true),
      (SosLifecycleStage.cancellationFailed, true),
      (SosLifecycleStage.cancelled, false),
    ]);
  });

  test('external and ambiguous lifecycle decisions cannot enable cadence',
      () async {
    await controller.restoreFor(owner);
    await controller.beginArming(origin: SosLifecycleOrigin.remoteRelay);
    await controller.beginActivating(origin: SosLifecycleOrigin.remoteRelay);
    await controller.confirmActive(
      origin: SosLifecycleOrigin.remoteRelay,
      localIncidentId: 'relay',
    );

    expect(controller.currentCadence.desiredLocalSosOwnership, isFalse);

    await controller.detachAccount();
    await controller.beginArming(origin: SosLifecycleOrigin.unknown);
    await controller.beginActivating(origin: SosLifecycleOrigin.unknown);
    await controller.confirmActive(
      origin: SosLifecycleOrigin.unknown,
      localIncidentId: 'ambiguous',
    );

    expect(controller.currentCadence.desiredLocalSosOwnership, isFalse);
  });

  test('SDK recreation restores active ownership as recovery required',
      () async {
    final active = await activate();
    final restoredController = AuthoritativeSosLifecycleController(
      secureStore: store,
      clock: () => now.add(const Duration(minutes: 1)),
    );
    addTearDown(restoredController.dispose);

    final restored = await restoredController.restoreFor(owner);

    expect(restored.lifecycleId, active.lifecycleId);
    expect(restored.stage, SosLifecycleStage.recoveryRequired);
    expect(restored.localActionable, isTrue);
    expect(restored.externalOnly, isFalse);
    expect(restored.recoveryStatus, SosRecoveryStatus.reconciling);
  });

  test('temporary disconnect does not mutate active ownership', () async {
    final active = await activate();
    now = now.add(const Duration(minutes: 5));

    expect(controller.current, same(active));
    expect(controller.current.localActionable, isTrue);
  });

  test('reconnect enrichment preserves lifecycle and does not duplicate',
      () async {
    final active = await activate();
    final enriched = await controller.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'local-1',
      backendIncidentId: 'backend-local-1',
      deviceId: 'device-1',
      nodeId: 7,
      hardwareId: 'hardware-1',
    );

    expect(enriched.lifecycleId, active.lifecycleId);
    expect(enriched.generation, active.generation);
  });

  test('pending cancellation persists and restores as cancelling', () async {
    final active = await activate();
    await controller.beginCancellation();
    final restoredController = AuthoritativeSosLifecycleController(
      secureStore: store,
      clock: () => now.add(const Duration(minutes: 1)),
    );
    addTearDown(restoredController.dispose);

    final restored = await restoredController.restoreFor(owner);

    expect(restored.lifecycleId, active.lifecycleId);
    expect(restored.stage, SosLifecycleStage.cancelling);
    expect(restored.cancellationPhase, SosCancellationPhase.requested);
  });

  test('successful cancellation clears persistence', () async {
    await activate();
    await controller.beginCancellation();
    await controller.cancellationAccepted(
      backendConfirmed: true,
      deviceConfirmed: true,
    );
    final terminal = await controller.confirmTerminal(
      stage: SosLifecycleStage.cancelled,
    );

    expect(terminal.stage, SosLifecycleStage.cancelled);
    expect(
      store.values,
      isNot(contains(SecureStorageKeys.sdkSosLifecycleProvenance.value)),
    );
  });

  test('failed cancellation retains actionable persistence for retry',
      () async {
    final active = await activate();
    final failed = await controller.cancellationFailed('E_TRANSPORT');

    expect(failed.lifecycleId, active.lifecycleId);
    expect(failed.stage, SosLifecycleStage.cancellationFailed);
    expect(failed.localActionable, isTrue);
    expect(
      store.values,
      contains(SecureStorageKeys.sdkSosLifecycleProvenance.value),
    );
  });

  test('confirmed terminal boundary creates a new generation', () async {
    final first = await activate();
    await controller.confirmTerminal(stage: SosLifecycleStage.cancelled);
    now = now.add(const Duration(seconds: 1));
    await controller.beginActivating(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      nodeId: 7,
    );
    final second = await controller.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'local-2',
      nodeId: 7,
    );

    expect(second.generation, first.generation + 1);
    expect(second.lifecycleId, isNot(first.lifecycleId));
  });

  test('account change cannot restore another account provenance', () async {
    await activate();
    final otherController = AuthoritativeSosLifecycleController(
      secureStore: store,
      clock: () => now,
    );
    addTearDown(otherController.dispose);

    final other = await otherController.restoreFor(otherOwner);

    expect(other.stage, SosLifecycleStage.idle);
    expect(other.localIncidentId, isNull);
  });

  test('account deletion clears provenance', () async {
    await activate();
    await controller.deleteAccountData();

    expect(store.values, isEmpty);
    expect(controller.current.stage, SosLifecycleStage.idle);
  });

  test('arming and unmatched recovery without proof are not persisted',
      () async {
    await controller.restoreFor(owner);
    await controller.beginArming(origin: SosLifecycleOrigin.localApp);
    await controller.requireRecovery('E_SOS_ALREADY_ACTIVE_UNMATCHED');

    expect(store.values, isEmpty);
    expect(controller.current.stage, SosLifecycleStage.recoveryRequired);
    expect(controller.current.localIncidentId, isNull);
  });

  test(
      'same-session auth restoration cannot reset arming and dispatch reaches active',
      () async {
    final snapshots = <SosLifecycleSnapshot>[];
    final subscription = controller.stream.listen(snapshots.add);
    addTearDown(subscription.cancel);

    final idle = await controller.restoreFor(owner);
    final arming = await controller.beginArming(
      origin: SosLifecycleOrigin.localApp,
    );
    final afterAuthRestore = await controller.restoreFor(owner);
    final activating = await controller.beginActivating(
      origin: SosLifecycleOrigin.localApp,
    );
    final active = await controller.confirmActive(
      origin: SosLifecycleOrigin.localApp,
      localIncidentId: 'local-race',
      backendIncidentId: 'backend-race',
    );
    await Future<void>.delayed(Duration.zero);

    expect(idle.stage, SosLifecycleStage.idle);
    expect(afterAuthRestore, same(arming));
    expect(afterAuthRestore.revision, 2);
    expect(activating.stage, SosLifecycleStage.activating);
    expect(active.stage, SosLifecycleStage.active);
    expect(
      snapshots.map((snapshot) => snapshot.stage),
      <SosLifecycleStage>[
        SosLifecycleStage.idle,
        SosLifecycleStage.arming,
        SosLifecycleStage.activating,
        SosLifecycleStage.active,
      ],
    );
  });

  test('late restoration finishing after arming is rejected', () async {
    final delayedStore = _DelayedReadSecureStore();
    final delayedController = AuthoritativeSosLifecycleController(
      secureStore: delayedStore,
      clock: () => now,
    );
    addTearDown(delayedController.dispose);
    final snapshots = <SosLifecycleSnapshot>[];
    final subscription = delayedController.stream.listen(snapshots.add);
    addTearDown(subscription.cancel);

    final restoration = delayedController.restoreFor(owner);
    await delayedStore.readStarted.future;
    final arming = await delayedController.beginArming(
      origin: SosLifecycleOrigin.localApp,
    );
    delayedStore.completeRead();
    final restored = await restoration;

    expect(restored, same(arming));
    expect(delayedController.current.stage, SosLifecycleStage.arming);
    expect(snapshots, <SosLifecycleSnapshot>[arming]);
  });

  group('runtime shadow wiring', () {
    test('restoration is accepted once at the canonical publish point',
        () async {
      final snapshots = <SosLifecycleSnapshot>[];
      final subscription = controller.stream.listen(snapshots.add);
      addTearDown(subscription.cancel);

      final restored = await controller.restoreFor(owner);

      expect(shadow.shadowState.acceptedSnapshotCount, 1);
      expect(
          shadow.shadowState.lastAcceptedLifecycleRevision, restored.revision);
      expect(shadow.shadowState.lastDirective,
          SosLocationOwnershipDirective.deactivate);
      expect(shadow.shadowState.activateTransitionCount, 0);
      expect(shadow.shadowState.deactivateTransitionCount, 0);
      expect(snapshots, <SosLifecycleSnapshot>[restored]);
    });

    test('each authoritative publication reaches shadow exactly once',
        () async {
      final snapshots = <SosLifecycleSnapshot>[];
      final subscription = controller.stream.listen(snapshots.add);
      addTearDown(subscription.cancel);

      await controller.restoreFor(owner);
      await controller.beginArming(origin: SosLifecycleOrigin.localApp);
      await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'local-shadow',
      );
      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'local-shadow',
      );
      await controller.beginCancellation();
      await controller.cancellationFailed('E_TRANSPORT');
      await controller.confirmTerminal(stage: SosLifecycleStage.cancelled);

      expect(
        shadow.shadowState.acceptedSnapshotCount,
        snapshots.length,
      );
      expect(
        snapshots.map((snapshot) => snapshot.revision),
        orderedEquals(
            List<int>.generate(snapshots.length, (index) => index + 1)),
      );
      expect(shadow.shadowState.activateTransitionCount, 1);
      expect(shadow.shadowState.deactivateTransitionCount, 1);
      expect(shadow.shadowState.desiredSosOwnership, isFalse);
      expect(
        shadow.shadowState.lastEmittedOwnershipTransition,
        SosLocationOwnershipTransition.deactivate,
      );
    });

    test('pre-authoritative stages retain and local active activates once',
        () async {
      await controller.restoreFor(owner);

      await controller.beginArming(origin: SosLifecycleOrigin.localApp);
      expect(shadow.shadowState.lastDirective,
          SosLocationOwnershipDirective.retain);
      expect(shadow.shadowState.activateTransitionCount, 0);

      await controller.beginActivating(origin: SosLifecycleOrigin.localApp);
      expect(shadow.shadowState.lastDirective,
          SosLocationOwnershipDirective.retain);
      expect(shadow.shadowState.activateTransitionCount, 0);

      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'local-shadow',
      );
      expect(shadow.shadowState.activateTransitionCount, 1);
      expect(shadow.shadowState.desiredSosOwnership, isTrue);

      await controller.confirmActive(
        origin: SosLifecycleOrigin.localApp,
        localIncidentId: 'local-shadow',
      );
      expect(shadow.shadowState.activateTransitionCount, 1);
      expect(shadow.shadowState.currentGeneration, 1);
    });

    test('connected local device activates and current terminal deactivates',
        () async {
      await controller.restoreFor(owner);
      await controller.beginActivating(
        origin: SosLifecycleOrigin.connectedLocalDevice,
        nodeId: 7,
      );
      await controller.confirmActive(
        origin: SosLifecycleOrigin.connectedLocalDevice,
        localIncidentId: 'device-runtime-sos:7:1',
        nodeId: 7,
      );

      expect(shadow.shadowState.activateTransitionCount, 1);
      expect(shadow.shadowState.desiredSosOwnership, isTrue);

      await controller.confirmTerminal(stage: SosLifecycleStage.resolved);

      expect(shadow.shadowState.deactivateTransitionCount, 1);
      expect(shadow.shadowState.desiredSosOwnership, isFalse);
    });

    test('cancellation progress retains ownership until confirmed terminal',
        () async {
      await activate();
      expect(shadow.shadowState.activateTransitionCount, 1);

      await controller.beginCancellation();
      expect(shadow.shadowState.desiredSosOwnership, isTrue);
      expect(shadow.shadowState.deactivateTransitionCount, 0);

      await controller.cancellationFailed('E_TRANSPORT');
      expect(shadow.shadowState.desiredSosOwnership, isTrue);
      expect(shadow.shadowState.deactivateTransitionCount, 0);

      await controller.confirmTerminal(stage: SosLifecycleStage.cancelled);
      expect(shadow.shadowState.desiredSosOwnership, isFalse);
      expect(shadow.shadowState.deactivateTransitionCount, 1);
    });

    test('restored local provenance reconstructs shadow ownership once',
        () async {
      await activate();
      final restoredShadow = SosLocationOwnershipOrchestrator();
      final restoredController = AuthoritativeSosLifecycleController(
        secureStore: store,
        clock: () => now.add(const Duration(minutes: 1)),
        locationOwnershipOrchestrator: restoredShadow,
      );
      addTearDown(restoredController.dispose);

      final restored = await restoredController.restoreFor(owner);

      expect(restored.stage, SosLifecycleStage.recoveryRequired);
      expect(restoredShadow.shadowState.acceptedSnapshotCount, 1);
      expect(restoredShadow.shadowState.activateTransitionCount, 1);
      expect(restoredShadow.shadowState.desiredSosOwnership, isTrue);
    });

    test('disposal resets shadow and prevents later shadow mutation', () async {
      await activate();

      await controller.dispose();
      final disposedState = shadow.shadowState;
      expect(disposedState.disposed, isTrue);
      expect(disposedState.acceptedSnapshotCount, 0);
      expect(disposedState.desiredSosOwnership, isFalse);

      await controller.beginArming(origin: SosLifecycleOrigin.localApp);

      expect(shadow.shadowState.disposed, isTrue);
      expect(shadow.shadowState.acceptedSnapshotCount, 0);
      expect(shadow.shadowState.lastAcceptedLifecycleRevision, isNull);
    });

    test('new controller owns a fresh independent shadow', () async {
      await activate();
      final firstShadow = shadow;
      final secondController = AuthoritativeSosLifecycleController(
        secureStore: InMemorySecureKeyValueStore(),
        clock: () => now,
      );
      addTearDown(secondController.dispose);

      expect(
        secondController.locationOwnershipOrchestrator,
        isNot(same(firstShadow)),
      );
      expect(
        secondController
            .locationOwnershipOrchestrator.shadowState.acceptedSnapshotCount,
        0,
      );

      await secondController.restoreFor(owner);

      expect(
        secondController
            .locationOwnershipOrchestrator.shadowState.acceptedSnapshotCount,
        1,
      );
      expect(shadow.shadowState.desiredSosOwnership, isTrue);
    });
  });
}

final class _DelayedReadSecureStore implements SecureKeyValueStore {
  final Completer<void> readStarted = Completer<void>();
  final Completer<String?> _readResult = Completer<String?>();

  void completeRead([String? value]) => _readResult.complete(value);

  @override
  Future<String?> read(String key) {
    if (!readStarted.isCompleted) {
      readStarted.complete();
    }
    return _readResult.future;
  }

  @override
  Future<bool> containsKey(String key) async => false;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> deleteAll({String? namespace}) async {}

  @override
  Future<void> write(String key, String value) async {}
}
