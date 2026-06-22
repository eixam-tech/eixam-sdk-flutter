import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'ble_command_criticality.dart';

export 'ble_command_criticality.dart';

enum BleSecurityCapability {
  legacyUnknown,
  insecureLegacy,
  secureLinkRequired,
  secureCommandAuthRequired,
  secureReady,
}

final class BleSecurityDiagnostics {
  const BleSecurityDiagnostics._();

  static const String policyEvaluated = 'BLE_SECURITY_POLICY_EVALUATED';
  static const String criticalCommandAllowedLegacy =
      'BLE_SECURITY_CRITICAL_COMMAND_ALLOWED_LEGACY';
  static const String criticalCommandBlockedInsecureLink =
      'BLE_SECURITY_CRITICAL_COMMAND_BLOCKED_INSECURE_LINK';
  static const String capabilityUnknown = 'BLE_SECURITY_CAPABILITY_UNKNOWN';
  static const String strictModeRequired = 'BLE_SECURITY_STRICT_MODE_REQUIRED';
}

final class BleCommandSecurityDecision {
  const BleCommandSecurityDecision({
    required this.allowed,
    required this.capability,
    required this.criticality,
    required this.diagnostics,
    this.warningCode,
    this.errorCode,
  });

  final bool allowed;
  final BleSecurityCapability capability;
  final BleCommandCriticality criticality;
  final List<String> diagnostics;
  final String? warningCode;
  final String? errorCode;

  bool get hasWarning => warningCode != null;
}

final class BleSecurityPolicy {
  const BleSecurityPolicy._({
    required this.strict,
  });

  const BleSecurityPolicy.legacyCompatible() : this._(strict: false);

  const BleSecurityPolicy.strict() : this._(strict: true);

  static const BleSecurityPolicy defaultPolicy =
      BleSecurityPolicy.legacyCompatible();
  static const BleSecurityPolicy strictPolicy = BleSecurityPolicy.strict();

  final bool strict;

  BleCommandSecurityDecision evaluate({
    required BleCommandCriticality criticality,
    required BleSecurityCapability capability,
  }) {
    final diagnostics = <String>[
      BleSecurityDiagnostics.policyEvaluated,
      if (capability == BleSecurityCapability.legacyUnknown)
        BleSecurityDiagnostics.capabilityUnknown,
    ];
    if (criticality == BleCommandCriticality.nonCritical) {
      return BleCommandSecurityDecision(
        allowed: true,
        capability: capability,
        criticality: criticality,
        diagnostics: List<String>.unmodifiable(diagnostics),
      );
    }

    if (!strict) {
      final warningCode = _legacyWarningCode(capability);
      if (warningCode != null) {
        diagnostics.add(warningCode);
      }
      return BleCommandSecurityDecision(
        allowed: true,
        capability: capability,
        criticality: criticality,
        diagnostics: List<String>.unmodifiable(diagnostics),
        warningCode: warningCode,
      );
    }

    if (capability == BleSecurityCapability.secureReady) {
      return BleCommandSecurityDecision(
        allowed: true,
        capability: capability,
        criticality: criticality,
        diagnostics: List<String>.unmodifiable(diagnostics),
      );
    }

    diagnostics
      ..add(BleSecurityDiagnostics.criticalCommandBlockedInsecureLink)
      ..add(BleSecurityDiagnostics.strictModeRequired);
    return BleCommandSecurityDecision(
      allowed: false,
      capability: capability,
      criticality: criticality,
      diagnostics: List<String>.unmodifiable(diagnostics),
      errorCode: DeviceException.bleLinkNotSecureCode,
    );
  }

  String? _legacyWarningCode(BleSecurityCapability capability) {
    return switch (capability) {
      BleSecurityCapability.legacyUnknown ||
      BleSecurityCapability.insecureLegacy =>
        BleSecurityDiagnostics.criticalCommandAllowedLegacy,
      BleSecurityCapability.secureLinkRequired ||
      BleSecurityCapability.secureCommandAuthRequired ||
      BleSecurityCapability.secureReady =>
        null,
    };
  }
}
