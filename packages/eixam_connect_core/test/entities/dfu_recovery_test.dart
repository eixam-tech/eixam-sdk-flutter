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
}
