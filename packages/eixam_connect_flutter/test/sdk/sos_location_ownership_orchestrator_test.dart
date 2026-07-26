import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_location_ownership_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveSosLocationOwnershipDirective', () {
    test('activates proven open local ownership', () {
      for (final snapshot in <SosLifecycleSnapshot>[
        _snapshot(stage: SosLifecycleStage.active),
        _snapshot(
          stage: SosLifecycleStage.active,
          origin: SosLifecycleOrigin.connectedLocalDevice,
        ),
        _snapshot(stage: SosLifecycleStage.cancelling),
        _snapshot(stage: SosLifecycleStage.cancellationFailed),
        _snapshot(
          stage: SosLifecycleStage.recoveryRequired,
          recoveryStatus: SosRecoveryStatus.reconciling,
        ),
      ]) {
        expect(
          resolveSosLocationOwnershipDirective(snapshot),
          SosLocationOwnershipDirective.activate,
          reason: '${snapshot.stage}/${snapshot.origin}',
        );
      }
    });

    test('retains pre-authoritative and ambiguous ownership', () {
      for (final snapshot in <SosLifecycleSnapshot>[
        _snapshot(stage: SosLifecycleStage.arming),
        _snapshot(stage: SosLifecycleStage.activating),
        _snapshot(
          stage: SosLifecycleStage.recoveryRequired,
          localActionable: false,
          recoveryStatus: SosRecoveryStatus.unresolved,
        ),
        _snapshot(
          stage: SosLifecycleStage.active,
          origin: SosLifecycleOrigin.unknown,
        ),
        _snapshot(
          stage: SosLifecycleStage.active,
          origin: SosLifecycleOrigin.remoteRelay,
          localActionable: false,
          externalOnly: true,
        ),
        _snapshot(
          stage: SosLifecycleStage.active,
          origin: SosLifecycleOrigin.externalBackend,
          localActionable: false,
          externalOnly: true,
        ),
        _snapshot(
          stage: SosLifecycleStage.active,
          localActionable: false,
        ),
      ]) {
        expect(
          resolveSosLocationOwnershipDirective(snapshot),
          SosLocationOwnershipDirective.retain,
          reason: '${snapshot.stage}/${snapshot.origin}',
        );
      }
    });

    test('external-only overrides superficially active local fields', () {
      final snapshot = _snapshot(
        stage: SosLifecycleStage.active,
        externalOnly: true,
      );

      expect(
        resolveSosLocationOwnershipDirective(snapshot),
        SosLocationOwnershipDirective.retain,
      );
    });

    test('deactivates conclusive local closure and authoritative idle', () {
      for (final snapshot in <SosLifecycleSnapshot>[
        _snapshot(
          stage: SosLifecycleStage.cancelled,
          localActionable: false,
          cancellationPhase: SosCancellationPhase.fullyResolved,
        ),
        _snapshot(
          stage: SosLifecycleStage.resolved,
          localActionable: false,
        ),
        _snapshot(
          stage: SosLifecycleStage.activationFailed,
          localActionable: false,
          localIncidentId: null,
        ),
        _snapshot(
          stage: SosLifecycleStage.idle,
          origin: SosLifecycleOrigin.unknown,
          localActionable: false,
          lifecycleId: '',
          generation: 0,
        ),
      ]) {
        expect(
          resolveSosLocationOwnershipDirective(snapshot),
          SosLocationOwnershipDirective.deactivate,
          reason: '${snapshot.stage}/${snapshot.origin}',
        );
      }
    });

    test('activation failure with a surviving incident retains ownership', () {
      expect(
        resolveSosLocationOwnershipDirective(
          _snapshot(
            stage: SosLifecycleStage.activationFailed,
            localIncidentId: 'local-incident',
          ),
        ),
        SosLocationOwnershipDirective.retain,
      );
    });

    test('cancelling remains active before terminal lifecycle authority', () {
      final snapshot = _snapshot(
        stage: SosLifecycleStage.cancelling,
        cancellationPhase: SosCancellationPhase.fullyResolved,
      );

      expect(
        resolveSosLocationOwnershipDirective(snapshot),
        SosLocationOwnershipDirective.activate,
      );
    });
  });

  group('SosLocationOwnershipOrchestrator', () {
    late SosLocationOwnershipOrchestrator orchestrator;

    setUp(() {
      orchestrator = SosLocationOwnershipOrchestrator();
    });

    tearDown(() {
      orchestrator.dispose();
    });

    test('emits only the first activation and current terminal closure', () {
      expect(
        orchestrator.accept(
          _snapshot(stage: SosLifecycleStage.active, revision: 1),
        ),
        SosLocationOwnershipTransition.activate,
      );
      expect(
        orchestrator.accept(
          _snapshot(stage: SosLifecycleStage.active, revision: 1),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(
        orchestrator.accept(
          _snapshot(stage: SosLifecycleStage.active, revision: 2),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.lastAcceptedLifecycleRevision, 2);
      expect(orchestrator.currentGeneration, 1);
      expect(orchestrator.desiredSosOwnership, isTrue);
      expect(
        orchestrator.lastEmittedOwnershipTransition,
        SosLocationOwnershipTransition.activate,
      );

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.cancelled,
            revision: 3,
            localActionable: false,
            cancellationPhase: SosCancellationPhase.fullyResolved,
          ),
        ),
        SosLocationOwnershipTransition.deactivate,
      );
      expect(orchestrator.desiredSosOwnership, isFalse);
      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.cancelled,
            revision: 4,
            localActionable: false,
            cancellationPhase: SosCancellationPhase.fullyResolved,
          ),
        ),
        SosLocationOwnershipTransition.none,
      );
    });

    test('ignores stale snapshots', () {
      orchestrator.accept(
        _snapshot(stage: SosLifecycleStage.active, revision: 5),
      );

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.cancelled,
            revision: 4,
            localActionable: false,
          ),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.lastAcceptedLifecycleRevision, 5);
      expect(orchestrator.desiredSosOwnership, isTrue);
    });

    test('older generation terminal cannot close newer ownership', () {
      orchestrator.accept(
        _snapshot(
          stage: SosLifecycleStage.active,
          generation: 1,
          revision: 1,
        ),
      );
      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.active,
            generation: 2,
            revision: 2,
          ),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.currentGeneration, 2);

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.cancelled,
            generation: 1,
            revision: 3,
            localActionable: false,
          ),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.currentGeneration, 2);
      expect(orchestrator.desiredSosOwnership, isTrue);

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.resolved,
            generation: 2,
            revision: 4,
            localActionable: false,
          ),
        ),
        SosLocationOwnershipTransition.deactivate,
      );
    });

    test('external generation cannot replace local generation', () {
      orchestrator.accept(
        _snapshot(
          stage: SosLifecycleStage.active,
          generation: 4,
          revision: 1,
        ),
      );

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.active,
            origin: SosLifecycleOrigin.remoteRelay,
            localActionable: false,
            externalOnly: true,
            generation: 99,
            revision: 2,
          ),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.lastAcceptedLifecycleRevision, 2);
      expect(orchestrator.currentGeneration, 4);
      expect(orchestrator.desiredSosOwnership, isTrue);
    });

    test('external terminal cannot deactivate local ownership', () {
      orchestrator.accept(
        _snapshot(
          stage: SosLifecycleStage.active,
          generation: 4,
          revision: 1,
        ),
      );

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.cancelled,
            origin: SosLifecycleOrigin.remoteRelay,
            localActionable: false,
            externalOnly: true,
            generation: 99,
            revision: 2,
          ),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.currentGeneration, 4);
      expect(orchestrator.desiredSosOwnership, isTrue);
    });

    test('unresolved newer recovery conservatively retains current state', () {
      orchestrator.accept(
        _snapshot(
          stage: SosLifecycleStage.active,
          generation: 4,
          revision: 1,
        ),
      );

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.recoveryRequired,
            origin: SosLifecycleOrigin.unknown,
            localActionable: false,
            generation: 5,
            revision: 2,
            recoveryStatus: SosRecoveryStatus.unresolved,
          ),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.currentGeneration, 4);
      expect(orchestrator.desiredSosOwnership, isTrue);
    });

    test('ambiguous recovery cannot activate or deactivate ownership', () {
      final ambiguous = _snapshot(
        stage: SosLifecycleStage.recoveryRequired,
        origin: SosLifecycleOrigin.unknown,
        localActionable: false,
        recoveryStatus: SosRecoveryStatus.unresolved,
        revision: 1,
      );

      expect(
        orchestrator.accept(ambiguous),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.desiredSosOwnership, isFalse);

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.active,
            revision: 2,
          ),
        ),
        SosLocationOwnershipTransition.activate,
      );
      expect(
        orchestrator.accept(ambiguous.copyWith(revision: 3)),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.desiredSosOwnership, isTrue);
    });

    test('authoritative idle closes ownership independent of generation', () {
      orchestrator.accept(
        _snapshot(
          stage: SosLifecycleStage.active,
          generation: 7,
          revision: 1,
        ),
      );

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.idle,
            origin: SosLifecycleOrigin.unknown,
            localActionable: false,
            lifecycleId: '',
            generation: 0,
            revision: 2,
          ),
        ),
        SosLocationOwnershipTransition.deactivate,
      );
    });

    test('rearming after closure does not reactivate ownership', () {
      orchestrator.accept(
        _snapshot(stage: SosLifecycleStage.active, revision: 1),
      );
      orchestrator.accept(
        _snapshot(
          stage: SosLifecycleStage.cancelled,
          revision: 2,
          localActionable: false,
        ),
      );

      expect(
        orchestrator.accept(
          _snapshot(
            stage: SosLifecycleStage.arming,
            generation: 2,
            revision: 3,
          ),
        ),
        SosLocationOwnershipTransition.none,
      );
      expect(orchestrator.desiredSosOwnership, isFalse);
    });

    test('reset clears all internal ownership state', () {
      orchestrator.accept(
        _snapshot(stage: SosLifecycleStage.active, revision: 8),
      );

      orchestrator.reset();

      expect(orchestrator.lastAcceptedLifecycleRevision, isNull);
      expect(orchestrator.currentGeneration, isNull);
      expect(orchestrator.desiredSosOwnership, isFalse);
      expect(orchestrator.lastEmittedOwnershipTransition, isNull);
      expect(
        orchestrator.accept(
          _snapshot(stage: SosLifecycleStage.active, revision: 1),
        ),
        SosLocationOwnershipTransition.activate,
      );
    });

    test('dispose clears state and rejects future snapshots', () {
      orchestrator.accept(
        _snapshot(stage: SosLifecycleStage.active, revision: 1),
      );

      orchestrator.dispose();

      expect(orchestrator.isDisposed, isTrue);
      expect(orchestrator.lastAcceptedLifecycleRevision, isNull);
      expect(orchestrator.currentGeneration, isNull);
      expect(orchestrator.desiredSosOwnership, isFalse);
      expect(orchestrator.lastEmittedOwnershipTransition, isNull);
      expect(
        () => orchestrator.accept(
          _snapshot(stage: SosLifecycleStage.active, revision: 2),
        ),
        throwsStateError,
      );
    });

    test('transitions represent only SOS ownership context', () {
      expect(SosLocationOwnershipTransition.values, <Object>[
        SosLocationOwnershipTransition.activate,
        SosLocationOwnershipTransition.deactivate,
        SosLocationOwnershipTransition.none,
      ]);
      expect(
        SosLocationOwnershipTransition.values.map((value) => value.name),
        isNot(contains('sharing')),
      );
      expect(
        SosLocationOwnershipTransition.values.map((value) => value.name),
        isNot(contains('dmp')),
      );
    });

    test('shadow acceptance is synchronous and requires no collaborators', () {
      final Object transition = orchestrator.accept(
        _snapshot(stage: SosLifecycleStage.active),
      );

      expect(transition, SosLocationOwnershipTransition.activate);
      expect(transition, isNot(isA<Future<Object?>>()));
    });
  });
}

SosLifecycleSnapshot _snapshot({
  required SosLifecycleStage stage,
  int revision = 1,
  String lifecycleId = 'sos:local:1',
  int generation = 1,
  SosLifecycleOrigin origin = SosLifecycleOrigin.localApp,
  bool localActionable = true,
  bool externalOnly = false,
  String? localIncidentId = 'local-incident',
  SosCancellationPhase cancellationPhase = SosCancellationPhase.none,
  SosRecoveryStatus recoveryStatus = SosRecoveryStatus.none,
}) {
  return SosLifecycleSnapshot(
    revision: revision,
    stage: stage,
    lifecycleId: lifecycleId,
    generation: generation,
    origin: origin,
    localActionable: localActionable,
    externalOnly: externalOnly,
    displaySurface: externalOnly
        ? SosDisplaySurface.historyOnly
        : SosDisplaySurface.activeAndHistory,
    localIncidentId: localIncidentId,
    lastAuthoritativeObservation: DateTime.utc(2026, 7, 24),
    cancellationPhase: cancellationPhase,
    recoveryStatus: recoveryStatus,
  );
}
