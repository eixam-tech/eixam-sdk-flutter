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

/// Inspection failures remain distinct from hardware incompatibility.
enum DeviceMigrationInspectionFailure {
  connectionFailed,
  serviceDiscoveryFailed,
  serviceIncomplete,
  batteryReadFailed,
  notificationSetupFailed,
  notificationSetupTimedOut,
  bondingFailed,
  bondingTimedOut,
  metadataRequestFailed,
  metadataReadFailed,
  metadataTimedOut,
  malformedMetadata,
  cancelled,
  connectionAlreadyOwned,
  cleanupFailed,
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
    this.inspectionFailure,
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
  final DeviceMigrationInspectionFailure? inspectionFailure;
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

/// Authoritative state of a device migration operation.
enum DeviceMigrationState {
  prepared,
  transferring,
  waitingForDevice,
  reconciling,
  recoveryRequired,
  completed,
  blocked,
  failed,
}

/// The next operation a host may present without deriving migration state.
enum DeviceMigrationNextAction {
  none,
  waitForDevice,
  reinspect,
  retry,
  recover,
  continueMigration,
  completed,
}

/// Evidence found while reconciling a durable migration after restart.
enum DeviceMigrationReconciliationOutcome {
  originalSourceDeviceFound,
  matchingRecoveryDeviceFound,
  migratedDeviceVerified,
  ambiguousCandidates,
  deviceNotFound,
  recoveryRequired,
  completed,
}

/// Durable SDK-owned state for one physical-device migration operation.
///
/// This deliberately contains no credentials, UI navigation or consumer copy.
class DeviceMigrationSession {
  const DeviceMigrationSession({
    required this.sessionId,
    required this.schemaVersion,
    required this.candidate,
    required this.releaseId,
    required this.targetVersion,
    required this.state,
    required this.nextAction,
    required this.canCancel,
    required this.createdAt,
    required this.updatedAt,
    this.firmwareSession,
    this.migratedDevice,
    this.outcome,
    this.reconciliationOutcome,
    this.failureCode,
    this.failureMessage,
  });

  static const int currentSchemaVersion = 1;

  final String sessionId;
  final int schemaVersion;
  final DeviceMigrationCandidate candidate;
  final String releaseId;
  final String targetVersion;
  final FirmwareUpdateSession? firmwareSession;
  final EixamBleScanResult? migratedDevice;
  final DeviceMigrationState state;
  final DeviceMigrationOutcome? outcome;
  final DeviceMigrationReconciliationOutcome? reconciliationOutcome;
  final DeviceMigrationNextAction nextAction;
  final bool canCancel;
  final String? failureCode;
  final String? failureMessage;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isTerminal =>
      state == DeviceMigrationState.completed ||
      state == DeviceMigrationState.blocked ||
      state == DeviceMigrationState.failed;

  DeviceMigrationSession copyWith({
    FirmwareUpdateSession? firmwareSession,
    EixamBleScanResult? migratedDevice,
    DeviceMigrationState? state,
    DeviceMigrationOutcome? outcome,
    DeviceMigrationReconciliationOutcome? reconciliationOutcome,
    DeviceMigrationNextAction? nextAction,
    bool? canCancel,
    String? failureCode,
    String? failureMessage,
    DateTime? updatedAt,
  }) => DeviceMigrationSession(
    sessionId: sessionId,
    schemaVersion: schemaVersion,
    candidate: candidate,
    releaseId: releaseId,
    targetVersion: targetVersion,
    firmwareSession: firmwareSession ?? this.firmwareSession,
    migratedDevice: migratedDevice ?? this.migratedDevice,
    state: state ?? this.state,
    outcome: outcome ?? this.outcome,
    reconciliationOutcome: reconciliationOutcome ?? this.reconciliationOutcome,
    nextAction: nextAction ?? this.nextAction,
    canCancel: canCancel ?? this.canCancel,
    failureCode: failureCode ?? this.failureCode,
    failureMessage: failureMessage ?? this.failureMessage,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
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
