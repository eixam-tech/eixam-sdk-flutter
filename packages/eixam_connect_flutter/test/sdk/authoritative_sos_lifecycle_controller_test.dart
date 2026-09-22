import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/authoritative_sos_lifecycle_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_location_ownership_orchestrator.dart';
import 'package:flutter/foundation.dart';
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

  test('confirmed canonical incident is monotonic across stale active evidence',
      () async {
    await controller.restoreFor(owner);
    await controller.beginActivating(
      origin: SosLifecycleOrigin.localApp,
      triggerSource: 'commercial_app',
      deviceId: 'device-1',
      nodeId: 7,
      hardwareId: 'hardware-1',
    );
    final provisional = SosIncident(
      id: 'sos-provisional-1',
      state: SosState.sent,
      createdAt: now,
      triggerSource: 'commercial_app',
    );
    await controller.confirmActive(
      origin: SosLifecycleOrigin.localApp,
      localIncidentId: provisional.id,
      triggerSource: provisional.triggerSource,
      deviceId: 'device-1',
      nodeId: 7,
      hardwareId: 'hardware-1',
      incident: provisional,
    );
    final canonical = SosIncident(
      id: '7c9e6679-7425-40de-944b-e07fc1f90ab1',
      state: SosState.sent,
      createdAt: now,
      triggerSource: 'commercial_app',
      isBackendConfirmed: true,
      provisionalIncidentId: provisional.id,
      preservedLocalOwnership: true,
    );
    final confirmed = await controller.confirmActive(
      origin: SosLifecycleOrigin.localApp,
      localIncidentId: provisional.id,
      backendIncidentId: canonical.id,
      triggerSource: canonical.triggerSource,
      deviceId: 'device-1',
      nodeId: 7,
      hardwareId: 'hardware-1',
      incident: canonical,
    );

    final afterStaleActive = await controller.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'device-runtime-sos:7:1',
      triggerSource: 'ble_device_runtime_status',
      deviceId: null,
      nodeId: 7,
      hardwareId: null,
      incident: provisional,
      recoveryStatus: SosRecoveryStatus.restored,
    );

    expect(afterStaleActive.lifecycleId, confirmed.lifecycleId);
    expect(afterStaleActive.generation, confirmed.generation);
    expect(afterStaleActive.origin, SosLifecycleOrigin.localApp);
    expect(afterStaleActive.localIncidentId, provisional.id);
    expect(afterStaleActive.backendIncidentId, canonical.id);
    expect(afterStaleActive.incident?.id, canonical.id);
    expect(afterStaleActive.incident?.isBackendConfirmed, isTrue);
    expect(afterStaleActive.deviceId, 'device-1');
    expect(afterStaleActive.hardwareId, 'hardware-1');
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

  test('successful cancellation persists an authoritative terminal fence',
      () async {
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
      contains(SecureStorageKeys.sdkSosLifecycleProvenance.value),
    );
    final encoded = store.values.values.single;
    expect(encoded, contains('"stage":"cancelled"'));
    expect(encoded, contains('"terminalTimestamp"'));

    final restoredController = AuthoritativeSosLifecycleController(
      secureStore: store,
      clock: () => now.add(const Duration(hours: 1)),
    );
    addTearDown(restoredController.dispose);
    final restored = await restoredController.restoreFor(owner);
    expect(restored.stage, SosLifecycleStage.cancelled);
    expect(restored.localActionable, isFalse);
  });

  test('terminal fence does not expire and restores after a long delay',
      () async {
    await activate();
    await controller.confirmTerminal(stage: SosLifecycleStage.resolved);
    expect(controller.hasActiveTerminalWatermark, isTrue);
    now = now.add(const Duration(days: 365));
    expect(controller.hasActiveTerminalWatermark, isTrue);

    final restoredController = AuthoritativeSosLifecycleController(
      secureStore: store,
      clock: () => now,
    );
    addTearDown(restoredController.dispose);

    final restored = await restoredController.restoreFor(owner);

    expect(restored.stage, SosLifecycleStage.resolved);
    expect(restoredController.hasActiveTerminalWatermark, isTrue);
    expect(
      store.values,
      contains(SecureStorageKeys.sdkSosLifecycleProvenance.value),
    );
  });

  test('new lifecycle after terminal advances generation and retains watermark',
      () async {
    final active = await activate();
    await controller.confirmTerminal(
      stage: SosLifecycleStage.cancelled,
      deviceCycleKey: 'sos:7:3',
    );

    final next = await controller.beginArming(
      origin: SosLifecycleOrigin.localApp,
      triggerSource: 'commercial_app',
      startNewGenerationAfterTerminal: true,
    );

    expect(next.stage, SosLifecycleStage.arming);
    expect(next.generation, active.generation + 1);
    expect(controller.hasActiveTerminalWatermark, isTrue);
    expect(
      controller.activeTerminalWatermark?.deviceCycleKey,
      'sos:7:3',
    );
  });

  test('admitted generation scopes a reused terminal lifecycle identity',
      () async {
    const reusedLifecycleId = 'device-cycle:sos:7:3';
    final first = await controller.beginArming(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      lifecycleId: reusedLifecycleId,
      nodeId: 7,
    );
    await controller.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'device-runtime-sos:7:3',
      nodeId: 7,
    );
    await controller.confirmTerminal(
      stage: SosLifecycleStage.cancelled,
      deviceCycleKey: 'sos:7:3',
    );

    final next = await controller.beginArming(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      lifecycleId: reusedLifecycleId,
      nodeId: 7,
      startNewGenerationAfterTerminal: true,
    );

    expect(next.stage, SosLifecycleStage.arming);
    expect(next.generation, first.generation + 1);
    expect(next.lifecycleId, '$reusedLifecycleId:g${next.generation}');
    expect(controller.activeTerminalWatermark?.lifecycleId, reusedLifecycleId);
    expect(controller.activeTerminalWatermark?.deviceCycleKey, 'sos:7:3');
  });

  test('terminal device cycle identity is persisted across restart', () async {
    await activate();
    await controller.confirmTerminal(
      stage: SosLifecycleStage.resolved,
      deviceCycleKey: 'sos:7:9',
    );

    final restoredController = AuthoritativeSosLifecycleController(
      secureStore: store,
      clock: () => now.add(const Duration(minutes: 1)),
    );
    addTearDown(restoredController.dispose);
    final restored = await restoredController.restoreFor(owner);

    expect(restored.deviceCycleKey, 'sos:7:9');
    expect(
      restoredController.activeTerminalWatermark?.deviceCycleKey,
      'sos:7:9',
    );
    expect(restored.displaySurface, SosDisplaySurface.historyOnly);
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

  test('terminal fence rejects ambiguous TAG open without inactive boundary',
      () async {
    final first = await activate();
    await controller.confirmTerminal(stage: SosLifecycleStage.cancelled);
    now = now.add(const Duration(seconds: 1));
    final activating = await controller.beginActivating(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      nodeId: 7,
    );
    final second = await controller.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'local-2',
      nodeId: 7,
    );

    expect(activating.stage, SosLifecycleStage.cancelled);
    expect(second.stage, SosLifecycleStage.cancelled);
    expect(second.generation, first.generation);
    expect(second.lifecycleId, first.lifecycleId);
  });

  test('inactive boundary authority permits a fresh TAG generation', () async {
    final first = await activate();
    await controller.confirmTerminal(stage: SosLifecycleStage.cancelled);
    now = now.add(const Duration(seconds: 1));
    final activating = await controller.beginActivating(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      nodeId: 7,
      startNewGenerationAfterTerminal: true,
    );
    final second = await controller.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'local-2',
      nodeId: 7,
    );

    expect(activating.generation, first.generation + 1);
    expect(second.stage, SosLifecycleStage.active);
    expect(second.lifecycleId, isNot(first.lifecycleId));
  });

  test('terminal fence rejects every non-terminal transition in generation',
      () async {
    final active = await activate();
    final terminal = await controller.confirmTerminal(
      stage: SosLifecycleStage.resolved,
    );

    final rejected = <SosLifecycleSnapshot>[
      await controller.beginArming(origin: SosLifecycleOrigin.localApp),
      await controller.beginActivating(origin: SosLifecycleOrigin.localApp),
      await controller.confirmActive(
        origin: SosLifecycleOrigin.connectedLocalDevice,
        localIncidentId: 'stale-device-active',
      ),
      await controller.requireRecovery('E_STALE_RECOVERY'),
      await controller.activationFailed('E_STALE_ACTIVATION'),
      await controller.beginCancellation(),
      await controller.cancellationAccepted(
        backendConfirmed: false,
        deviceConfirmed: true,
      ),
      await controller.cancellationFailed('E_STALE_CANCEL'),
    ];

    for (final snapshot in rejected) {
      expect(snapshot.lifecycleId, active.lifecycleId);
      expect(snapshot.generation, active.generation);
      expect(snapshot.stage, terminal.stage);
    }
    expect(controller.current.stage, SosLifecycleStage.resolved);
  });

  test('terminal fence rejects stale callback while persistence is pending',
      () async {
    final delayedStore = _DelayedWriteSecureStore();
    final delayedController = AuthoritativeSosLifecycleController(
      secureStore: delayedStore,
      clock: () => now,
    );
    addTearDown(delayedController.dispose);
    await delayedController.restoreFor(owner);
    await delayedController.beginActivating(
      origin: SosLifecycleOrigin.localApp,
    );
    await delayedController.confirmActive(
      origin: SosLifecycleOrigin.localApp,
      localIncidentId: 'local-before-terminal',
    );
    delayedStore.delayNextWrite();

    final confirmation = delayedController.confirmTerminal(
      stage: SosLifecycleStage.cancelled,
    );
    await delayedStore.writeStarted;
    final stale = await delayedController.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'stale-device-callback',
    );

    expect(stale.stage, SosLifecycleStage.cancelled);
    expect(delayedController.current.stage, SosLifecycleStage.active);
    delayedStore.completeWrite();
    expect((await confirmation).stage, SosLifecycleStage.cancelled);
    expect(delayedController.current.stage, SosLifecycleStage.cancelled);
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

  test('secure SOS provenance read failure logs only operation and type',
      () async {
    final failure = _privateSecureStoreFailure();
    final failingController = AuthoritativeSosLifecycleController(
      secureStore: _FailingSecureStore(readFailure: failure),
      clock: () => now,
    );
    addTearDown(failingController.dispose);

    final captured = await _captureSecureStoreFailure(
      () => failingController.restoreFor(owner),
    );

    _expectSafeSecureStoreDiagnostic(
      captured,
      failure: failure,
      operation: 'sos_lifecycle_read',
    );
  });

  test('secure SOS provenance delete failure logs only operation and type',
      () async {
    final failure = _privateSecureStoreFailure();
    final failingController = AuthoritativeSosLifecycleController(
      secureStore: _FailingSecureStore(deleteFailure: failure),
      clock: () => now,
    );
    addTearDown(failingController.dispose);

    final captured = await _captureSecureStoreFailure(
      failingController.deleteAccountData,
    );

    _expectSafeSecureStoreDiagnostic(
      captured,
      failure: failure,
      operation: 'sos_lifecycle_delete',
    );
  });

  test('terminal write failure retains the in-memory terminal fence', () async {
    final secureStore = _FailingSecureStore();
    final failingController = AuthoritativeSosLifecycleController(
      secureStore: secureStore,
      clock: () => now,
    );
    addTearDown(failingController.dispose);
    await failingController.restoreFor(owner);
    await failingController.beginActivating(
      origin: SosLifecycleOrigin.localApp,
    );
    await failingController.confirmActive(
      origin: SosLifecycleOrigin.localApp,
      localIncidentId: 'local-write-failure',
    );
    final active = failingController.current;
    final failure = _privateSecureStoreFailure();
    secureStore.writeFailure = failure;

    final captured = await _captureSecureStoreFailure(
      () => failingController.confirmTerminal(
        stage: SosLifecycleStage.resolved,
      ),
    );

    _expectSafeSecureStoreDiagnostic(
      captured,
      failure: failure,
      operation: 'sos_lifecycle_write',
    );
    expect(failingController.current.lifecycleId, active.lifecycleId);
    expect(failingController.current.stage, SosLifecycleStage.resolved);
    expect(failingController.current.isOpen, isFalse);
    expect(failingController.hasActiveTerminalWatermark, isTrue);
  });

  test('terminal watermark is visible while durable write is pending',
      () async {
    final delayedStore = _DelayedWriteSecureStore();
    final delayedController = AuthoritativeSosLifecycleController(
      secureStore: delayedStore,
      clock: () => now,
    );
    addTearDown(delayedController.dispose);
    await delayedController.restoreFor(owner);
    await delayedController.beginActivating(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      nodeId: 7,
    );
    await delayedController.confirmActive(
      origin: SosLifecycleOrigin.connectedLocalDevice,
      localIncidentId: 'local-delayed-terminal',
      nodeId: 7,
    );
    delayedStore.delayNextWrite();

    final confirmation = delayedController.confirmTerminal(
      stage: SosLifecycleStage.cancelled,
      deviceCycleKey: 'sos:7:4',
    );
    await delayedStore.writeStarted;

    expect(delayedController.current.stage, SosLifecycleStage.active);
    expect(
      delayedController.activeTerminalWatermark?.stage,
      SosLifecycleStage.cancelled,
    );
    expect(
      delayedController.activeTerminalWatermark?.deviceCycleKey,
      'sos:7:4',
    );

    delayedStore.completeWrite();
    final terminal = await confirmation;
    expect(terminal.stage, SosLifecycleStage.cancelled);
  });

  test('unreadable SOS provenance remains fatal and is never cleared',
      () async {
    const failure = SecureKeyValueStoreEntryUnreadableException();
    final secureStore = _FailingSecureStore(readFailure: failure);
    final failingController = AuthoritativeSosLifecycleController(
      secureStore: secureStore,
      clock: () => now,
    );
    addTearDown(failingController.dispose);

    final captured = await _captureSecureStoreFailure(
      () => failingController.restoreFor(owner),
    );

    expect(captured.error, same(failure));
    expect(failingController.current.stage, SosLifecycleStage.idle);
    expect(secureStore.deletedKeys, isEmpty);
    expect(
      captured.diagnostics,
      <String>[
        'SECURE_STORE_OPERATION_FAILED operation=sos_lifecycle_read '
            'reason=SecureKeyValueStoreEntryUnreadableException',
      ],
    );
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
      await pumpEventQueue();

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

final class _DelayedWriteSecureStore implements SecureKeyValueStore {
  final Map<String, String> _values = <String, String>{};
  Completer<void>? _pendingWrite;
  Completer<void>? _writeStarted;

  Future<void> get writeStarted => _writeStarted!.future;

  void delayNextWrite() {
    _pendingWrite = Completer<void>();
    _writeStarted = Completer<void>();
  }

  void completeWrite() => _pendingWrite!.complete();

  @override
  Future<bool> containsKey(String key) async => _values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> deleteAll({String? namespace}) async => _values.clear();

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    final pendingWrite = _pendingWrite;
    if (pendingWrite != null) {
      _writeStarted!.complete();
      await pendingWrite.future;
      _pendingWrite = null;
    }
    _values[key] = value;
  }
}

SecureKeyValueStoreUnavailableException _privateSecureStoreFailure() =>
    const SecureKeyValueStoreUnavailableException(
      message: 'private-message private-token private-value private-key',
    );

Future<({Object? error, List<String> diagnostics})> _captureSecureStoreFailure(
  Future<Object?> Function() operation,
) async {
  final diagnostics = <String>[];
  final originalDebugPrint = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message != null) diagnostics.add(message);
  };
  Object? error;
  try {
    await operation();
  } catch (caught) {
    error = caught;
  } finally {
    debugPrint = originalDebugPrint;
  }
  return (error: error, diagnostics: diagnostics);
}

void _expectSafeSecureStoreDiagnostic(
  ({Object? error, List<String> diagnostics}) captured, {
  required Object failure,
  required String operation,
}) {
  expect(captured.error, same(failure));
  expect(
    captured.diagnostics,
    <String>[
      'SECURE_STORE_OPERATION_FAILED operation=$operation '
          'reason=SecureKeyValueStoreUnavailableException',
    ],
  );
  final diagnostic = captured.diagnostics.single;
  for (final privateText in <String>[
    'private-message',
    'private-token',
    'private-value',
    'private-key',
    'owner-a',
    'secret-hash',
    SecureStorageKeys.sdkSosLifecycleProvenance.value,
  ]) {
    expect(diagnostic, isNot(contains(privateText)));
  }
}

final class _FailingSecureStore implements SecureKeyValueStore {
  _FailingSecureStore({
    this.readFailure,
    this.deleteFailure,
  });

  final Object? readFailure;
  Object? writeFailure;
  final Object? deleteFailure;
  final List<String> deletedKeys = <String>[];

  @override
  Future<bool> containsKey(String key) async => false;

  @override
  Future<void> delete(String key) async {
    if (deleteFailure case final failure?) throw failure;
    deletedKeys.add(key);
  }

  @override
  Future<void> deleteAll({String? namespace}) async {}

  @override
  Future<String?> read(String key) async {
    if (readFailure case final failure?) throw failure;
    return null;
  }

  @override
  Future<void> write(String key, String value) async {
    if (writeFailure case final failure?) throw failure;
  }
}
