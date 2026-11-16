import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveE1RecoveryStrategy', () {
    test('bootloader 0.4.3 resolves to cable recovery', () {
      expect(
        resolveE1RecoveryStrategy('0.4.3 s140 6.1.1'),
        E1RecoveryStrategy.cableRecovery,
      );
      expect(
        resolveE1RecoveryStrategy('0.4.3'),
        E1RecoveryStrategy.cableRecovery,
      );
    });

    test('unknown, empty and unparseable versions resolve to cable', () {
      for (final version in <String?>[null, '', '   ', 'garbage', '9.9.9']) {
        expect(
          resolveE1RecoveryStrategy(version),
          E1RecoveryStrategy.cableRecovery,
          reason: '$version',
        );
      }
    });

    test('the shipped allowlist is empty (nothing is proven to restart)', () {
      expect(kBleRestartCapableBootloaderVersions, isEmpty);
    });

    test('a proven version in an injected allowlist resolves to restart', () {
      const proven = <String>{'9.9.9'};
      expect(
        resolveE1RecoveryStrategy('9.9.9 s140 6.1.1', restartCapable: proven),
        E1RecoveryStrategy.restartFromScratch,
      );
      expect(
        resolveE1RecoveryStrategy('0.4.3 s140 6.1.1', restartCapable: proven),
        E1RecoveryStrategy.cableRecovery,
      );
      expect(
        resolveE1RecoveryStrategy(null, restartCapable: proven),
        E1RecoveryStrategy.cableRecovery,
      );
    });
  });

  group('DfuRecoveryStatus', () {
    test('equality ignores updatedAt and compares warnings', () {
      final a = DfuRecoveryStatus(
        state: DfuRecoveryState.resumable,
        reason: DfuRecoveryReason.bootloaderVisible,
        updatedAt: DateTime(2026),
      );
      final b = DfuRecoveryStatus(
        state: DfuRecoveryState.resumable,
        reason: DfuRecoveryReason.bootloaderVisible,
        updatedAt: DateTime(2027),
      );
      expect(a, b);
      expect(
        a.copyWith(warnings: [DfuPreflightWarning.deviceBatteryUnknown]),
        isNot(b),
      );
    });

    test('DfuRecoveryException code equals the failure name', () {
      final error = DfuRecoveryException(DfuPreflightFailure.bluetoothOff);
      expect(error.code, 'bluetoothOff');
    });
  });

  group('F19: never a recovery state without a way forward', () {
    test('every state, reason, action, progress and device has an action', () {
      for (final state in DfuRecoveryState.values) {
        for (final reason in DfuRecoveryReason.values) {
          for (final action in DfuRecoveryAction.values) {
            for (final progress in <double?>[null, 0, 0.5]) {
              for (final deviceId in <String?>[null, 'tag']) {
                final status = DfuRecoveryStatus(
                  state: state,
                  reason: reason,
                  availableAction: action,
                  progressFraction: progress,
                  deviceId: deviceId,
                );
                expect(
                  status.forwardActions,
                  isNotEmpty,
                  reason: '$status progress=$progress device=$deviceId',
                );
                expect(
                  status.forwardActions,
                  isNot(contains(DfuRecoveryAction.none)),
                );
              }
            }
          }
        }
      }
    });

    test('E1 offers the SDK action first, then the cable page', () {
      const status = DfuRecoveryStatus(
        state: DfuRecoveryState.resumable,
        reason: DfuRecoveryReason.bootloaderVisible,
        availableAction: DfuRecoveryAction.prepareCableRecovery,
      );
      expect(status.forwardActions, [
        DfuRecoveryAction.prepareCableRecovery,
        DfuRecoveryAction.openCableRecoveryGuide,
      ]);
    });

    test('E1 without a fresh sighting still offers the cable page', () {
      const status = DfuRecoveryStatus(
        state: DfuRecoveryState.resumable,
        reason: DfuRecoveryReason.bootloaderVisible,
      );
      expect(status.forwardActions, [DfuRecoveryAction.openCableRecoveryGuide]);
    });

    test('an interrupted update held by another owner keeps the cable page '
        '(2026-11-06 iPhone dead end)', () {
      const status = DfuRecoveryStatus(
        state: DfuRecoveryState.unknown,
        reason: DfuRecoveryReason.updateInProgress,
        deviceId: 'tag',
      );
      expect(
        status.forwardActions.first,
        DfuRecoveryAction.openCableRecoveryGuide,
      );
    });

    test('the SDK recovery run itself and a healthy TAG only re-check', () {
      const running = DfuRecoveryStatus(
        state: DfuRecoveryState.unknown,
        reason: DfuRecoveryReason.updateInProgress,
        progressFraction: 0,
        deviceId: 'tag',
      );
      const none = DfuRecoveryStatus.unknown();
      expect(running.forwardActions, [DfuRecoveryAction.checkAgain]);
      expect(none.forwardActions, [DfuRecoveryAction.checkAgain]);
    });

    test('E2 and waiting for evidence always include the cable page', () {
      for (final reason in [
        DfuRecoveryReason.cableRecoveryPrepared,
        DfuRecoveryReason.deviceSilent,
      ]) {
        expect(
          DfuRecoveryStatus(
            state: DfuRecoveryState.silentNeedsCable,
            reason: reason,
          ).forwardActions,
          contains(DfuRecoveryAction.openCableRecoveryGuide),
        );
      }
      expect(
        const DfuRecoveryStatus(
          state: DfuRecoveryState.unknown,
          reason: DfuRecoveryReason.awaitingEvidence,
        ).forwardActions,
        contains(DfuRecoveryAction.openCableRecoveryGuide),
      );
    });
  });
}
