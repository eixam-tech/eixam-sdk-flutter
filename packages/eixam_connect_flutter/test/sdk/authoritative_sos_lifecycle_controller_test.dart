import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/authoritative_sos_lifecycle_controller.dart';
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

  setUp(() {
    store = InMemorySecureKeyValueStore();
    now = DateTime.utc(2026, 7, 15, 10);
    controller = AuthoritativeSosLifecycleController(
      secureStore: store,
      clock: () => now,
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
}
