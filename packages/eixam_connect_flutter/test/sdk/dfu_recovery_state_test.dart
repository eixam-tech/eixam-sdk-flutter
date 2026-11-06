import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/dfu_recovery_state.dart';
import 'package:flutter_test/flutter_test.dart';

DfuRecoveryStatus derive(
  DfuRecoveryEvidence evidence, {
  E1RecoveryStrategy strategy = E1RecoveryStrategy.cableRecovery,
}) => deriveDfuRecoveryStatus(
  evidence,
  strategy: strategy,
  silenceWindow: const Duration(minutes: 2),
);

void main() {
  group('deriveDfuRecoveryStatus', () {
    test('unknown without an interrupted update', () {
      final status = derive(const DfuRecoveryEvidence());
      expect(status.state, DfuRecoveryState.unknown);
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(status.availableAction, DfuRecoveryAction.none);
      expect(status.needsCable, isFalse);
    });

    test('resumable (E1) offers only prepareCableRecovery by default', () {
      final status = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          bootloaderMatches: 1,
        ),
      );
      expect(status.state, DfuRecoveryState.resumable);
      expect(status.reason, DfuRecoveryReason.bootloaderVisible);
      expect(status.availableAction, DfuRecoveryAction.prepareCableRecovery);
      expect(status.needsCable, isTrue);
    });

    test('resumable offers only restartDfuFromScratch for that strategy', () {
      final status = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          bootloaderMatches: 1,
        ),
        strategy: E1RecoveryStrategy.restartFromScratch,
      );
      expect(status.state, DfuRecoveryState.resumable);
      expect(status.availableAction, DfuRecoveryAction.restartDfuFromScratch);
      expect(status.needsCable, isFalse);
    });

    test('iosStaleLink asks to forget the device', () {
      final status = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          iosStaleLinkSuspected: true,
        ),
      );
      expect(status.state, DfuRecoveryState.iosStaleLink);
      expect(status.availableAction, DfuRecoveryAction.forgetDevice);
    });

    test('silentNeedsCable after the silence window', () {
      final early = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          silentFor: Duration(minutes: 1),
        ),
      );
      expect(early.state, DfuRecoveryState.unknown);
      expect(early.reason, DfuRecoveryReason.awaitingEvidence);
      final silent = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          silentFor: Duration(minutes: 2),
        ),
      );
      expect(silent.state, DfuRecoveryState.silentNeedsCable);
      expect(silent.reason, DfuRecoveryReason.deviceSilent);
      expect(silent.needsCable, isTrue);
      expect(silent.availableAction, DfuRecoveryAction.none);
    });

    test('silentNeedsCable immediately after a cable preparation', () {
      final status = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          cablePrepared: true,
        ),
      );
      expect(status.state, DfuRecoveryState.silentNeedsCable);
      expect(status.reason, DfuRecoveryReason.cableRecoveryPrepared);
    });

    test('a visible bootloader beats a stale cable preparation', () {
      final status = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          cablePrepared: true,
          bootloaderMatches: 1,
        ),
      );
      expect(status.state, DfuRecoveryState.resumable);
    });

    test('recovered only when the verified latch is set', () {
      expect(
        derive(const DfuRecoveryEvidence(recoveredLatched: true)).state,
        DfuRecoveryState.recovered,
      );
      // Transfer finished but nothing verified: never recovered.
      expect(
        derive(
          const DfuRecoveryEvidence(
            hasInterruptedUpdate: true,
            silentFor: Duration.zero,
          ),
        ).state,
        isNot(DfuRecoveryState.recovered),
      );
    });

    test('stock firmware observed is a completed physical recovery', () {
      final status = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          stockObserved: true,
          silentFor: Duration(hours: 1),
        ),
      );
      expect(status.state, DfuRecoveryState.unknown);
      expect(status.reason, DfuRecoveryReason.physicalRecoveryCompleted);
    });

    test('operation in progress and ambiguity are unknown', () {
      final running = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          bootloaderMatches: 1,
          operationInProgress: true,
          progressFraction: 0.4,
        ),
      );
      expect(running.state, DfuRecoveryState.unknown);
      expect(running.reason, DfuRecoveryReason.updateInProgress);
      expect(running.progressFraction, 0.4);
      expect(running.availableAction, DfuRecoveryAction.none);
      final ambiguous = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          bootloaderMatches: 2,
        ),
      );
      expect(ambiguous.state, DfuRecoveryState.unknown);
      expect(ambiguous.reason, DfuRecoveryReason.awaitingEvidence);
    });

    test('dismissed hides everything', () {
      final status = derive(
        const DfuRecoveryEvidence(
          hasInterruptedUpdate: true,
          bootloaderMatches: 1,
          dismissed: true,
        ),
      );
      expect(status.state, DfuRecoveryState.unknown);
    });

    test('transition chain E1 -> cable prepared -> stock', () {
      var evidence = const DfuRecoveryEvidence(
        hasInterruptedUpdate: true,
        bootloaderMatches: 1,
      );
      expect(derive(evidence).state, DfuRecoveryState.resumable);
      evidence = const DfuRecoveryEvidence(
        hasInterruptedUpdate: true,
        cablePrepared: true,
      );
      expect(derive(evidence).state, DfuRecoveryState.silentNeedsCable);
      evidence = const DfuRecoveryEvidence(
        hasInterruptedUpdate: true,
        cablePrepared: true,
        stockObserved: true,
      );
      expect(
        derive(evidence).reason,
        DfuRecoveryReason.physicalRecoveryCompleted,
      );
    });
  });
}
