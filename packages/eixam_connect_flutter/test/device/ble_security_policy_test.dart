import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_security_policy.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BLE command criticality', () {
    test('SOS trigger command is critical', () {
      expect(EixamDeviceCommand.sosTriggerApp().criticality,
          BleCommandCriticality.critical);
    });

    test('SOS cancel command is critical', () {
      expect(
        EixamDeviceCommand.sosCancel().criticality,
        BleCommandCriticality.critical,
      );
    });

    test('shutdown and reboot commands are critical', () {
      expect(
        EixamDeviceCommand.shutdown().criticality,
        BleCommandCriticality.critical,
      );
      expect(
        EixamDeviceCommand.reboot().criticality,
        BleCommandCriticality.critical,
      );
    });

    test('read and status commands are non-critical', () {
      expect(
        EixamDeviceCommand.getDeviceStatus().criticality,
        BleCommandCriticality.nonCritical,
      );
    });
  });

  group('BleSecurityPolicy', () {
    test('default policy allows legacy critical commands with diagnostics', () {
      final decision = BleSecurityPolicy.defaultPolicy.evaluate(
        criticality: EixamDeviceCommand.sosTriggerApp().criticality,
        capability: BleSecurityCapability.legacyUnknown,
      );

      expect(decision.allowed, isTrue);
      expect(decision.warningCode,
          BleSecurityDiagnostics.criticalCommandAllowedLegacy);
      expect(
        decision.diagnostics,
        containsAll(<String>[
          BleSecurityDiagnostics.policyEvaluated,
          BleSecurityDiagnostics.capabilityUnknown,
          BleSecurityDiagnostics.criticalCommandAllowedLegacy,
        ]),
      );
    });

    test('strict policy blocks critical command for legacy capabilities', () {
      for (final capability in <BleSecurityCapability>[
        BleSecurityCapability.legacyUnknown,
        BleSecurityCapability.insecureLegacy,
      ]) {
        final decision = BleSecurityPolicy.strictPolicy.evaluate(
          criticality: EixamDeviceCommand.sosCancel().criticality,
          capability: capability,
        );

        expect(decision.allowed, isFalse);
        expect(decision.errorCode, DeviceException.bleLinkNotSecureCode);
        expect(
          decision.diagnostics,
          contains(BleSecurityDiagnostics.criticalCommandBlockedInsecureLink),
        );
        expect(
          decision.diagnostics,
          contains(BleSecurityDiagnostics.strictModeRequired),
        );
      }
    });

    test('strict policy allows critical command for secureReady capability',
        () {
      final decision = BleSecurityPolicy.strictPolicy.evaluate(
        criticality: EixamDeviceCommand.reboot().criticality,
        capability: BleSecurityCapability.secureReady,
      );

      expect(decision.allowed, isTrue);
      expect(decision.errorCode, isNull);
      expect(
        decision.diagnostics,
        contains(BleSecurityDiagnostics.policyEvaluated),
      );
    });

    test('error codes are stable', () {
      expect(DeviceException.bleLinkNotSecureCode, 'E_BLE_LINK_NOT_SECURE');
      expect(DeviceException.blePairingRequiredCode, 'E_BLE_PAIRING_REQUIRED');
      expect(
        DeviceException.bleCommandAuthFailedCode,
        'E_BLE_COMMAND_AUTH_FAILED',
      );
      expect(DeviceException.bleReplayRejectedCode, 'E_BLE_REPLAY_REJECTED');
      expect(
        DeviceException.bleDeviceIdUnverifiedCode,
        'E_BLE_DEVICE_ID_UNVERIFIED',
      );
    });
  });
}
