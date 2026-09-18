import 'eixam_ble_scan_result.dart';
import 'firmware_update.dart';

/// Result of a read-only inspection of stock firmware before migration.
enum DeviceMigrationCompatibility {
  compatible,
  unsupportedHardware,
  unableToVerify,
}

/// Strongest identity evidence captured before firmware replacement.
enum DeviceMigrationIdentityKind {
  hardwareMac,
  platformIdentifier,
  meshtasticNodeNumber,
  none,
}

class DeviceMigrationCandidate {
  const DeviceMigrationCandidate({
    required this.deviceId,
    required this.compatibility,
    required this.identityKind,
    required this.inspectedAt,
    this.advertisedName,
    this.sourceHardwareModel,
    this.sourceFirmwareVersion,
    this.stableIdentity,
    this.sourceNodeNumber,
    this.batteryPercentage,
    this.detailCode,
  });

  final String deviceId;
  final String? advertisedName;
  final DeviceMigrationCompatibility compatibility;
  final int? sourceHardwareModel;
  final String? sourceFirmwareVersion;
  final String? stableIdentity;
  final DeviceMigrationIdentityKind identityKind;
  final int? sourceNodeNumber;
  final int? batteryPercentage;
  final String? detailCode;
  final DateTime inspectedAt;

  bool get isCompatible =>
      compatibility == DeviceMigrationCompatibility.compatible;
}

enum DeviceMigrationOutcome {
  completed,
  blocked,
  failed,
  recoveryRequired,
  ambiguousPostMigrationDevice,
}

class DeviceMigrationResult {
  const DeviceMigrationResult({
    required this.outcome,
    required this.candidate,
    this.firmwareSession,
    this.migratedDevice,
    this.failureCode,
    this.failureMessage,
  });

  final DeviceMigrationOutcome outcome;
  final DeviceMigrationCandidate candidate;
  final FirmwareUpdateSession? firmwareSession;
  final EixamBleScanResult? migratedDevice;
  final String? failureCode;
  final String? failureMessage;

  bool get succeeded => outcome == DeviceMigrationOutcome.completed;
}
