enum FirmwareUpdateState {
  idle,
  checking,
  available,
  notAvailable,
  blocked,
  downloading,
  verifying,
  readyToTransfer,
  transferring,
  reconnecting,
  verifyingInstalledVersion,
  completed,
  failed,
  cancelled,
  recoveryRequired,
  physicalRecoveryRequired,
}

/// Positive device evidence from an SDK platform inspection. Silence or a
/// transport timeout cannot establish this condition.
class FirmwarePhysicalRecoveryEvidence {
  const FirmwarePhysicalRecoveryEvidence({
    required this.deviceId,
    required this.hardwareId,
    required this.applicationInvalid,
    required this.remoteRecoveryUnsupported,
  });

  final String deviceId;
  final String hardwareId;
  final bool applicationInvalid;
  final bool remoteRecoveryUnsupported;
}

enum FirmwareUpdateNextAction {
  none,
  retry,
  waitForDevice,
  recover,
  completed,
  retryDownload,
  startTransfer,
  retryTransfer,
  verifyInstalledVersion,
  physicalRecovery,
  retryRemoteRecovery,
}

enum FirmwareUpdateReconciliationOutcome {
  deviceFound,
  recoveryDeviceFound,
  deviceMissing,
  wrongDevice,
  ambiguousCandidates,
  installedVersionMismatch,
  completed,
}

enum FirmwareUpdateBlocker {
  noConnectedDevice,
  unknownFirmwareVersion,
  unsupportedHardware,
  lowDeviceBattery,
  unstableBleConnection,
  sosActive,
  preSosCountdownActive,
  dmpActiveOrOverdue,
  protectionRuntimeBusy,
  appBackgrounded,
  artifactMissing,
  hashMissing,
  incompatibleRelease,
}

class FirmwareUpdatePolicy {
  const FirmwareUpdatePolicy({
    this.minDeviceBatteryPercentage = 20,
    this.requireKnownDeviceBattery = true,
    this.requireForeground = true,
    this.supportedHardwareModels = const <String>[],
    this.allowDowngrade = false,
    this.targetReleaseId,
  });

  final int minDeviceBatteryPercentage;
  final bool requireKnownDeviceBattery;
  final bool requireForeground;

  /// Optional allow-list. Empty means the backend release metadata is trusted.
  final List<String> supportedHardwareModels;

  /// Selects the highest stored firmware semver below the installed version,
  /// including inactive historical releases exposed by the backend.
  /// Defaults to false so production update checks can never downgrade a
  /// device accidentally. Intended for controlled development/testing flows.
  final bool allowDowngrade;

  /// Explicit backend release to validate and install. This bypasses automatic
  /// latest/previous selection but still enforces device, model, safety,
  /// artifact and scope checks. Intended for controlled development tooling.
  final String? targetReleaseId;
}

class DeviceFirmwareInfo {
  const DeviceFirmwareInfo({
    required this.deviceId,
    required this.connected,
    required this.readyForSafety,
    this.hardwareId,
    this.nodeId,
    this.hardwareModel,
    this.currentVersion,
    this.batteryPercentage,
  });

  final String deviceId;
  final String? hardwareId;
  final int? nodeId;
  final String? hardwareModel;
  final String? currentVersion;
  final int? batteryPercentage;
  final bool connected;
  final bool readyForSafety;
}

class FirmwareRelease {
  const FirmwareRelease({
    required this.releaseId,
    required this.version,
    this.hardwareModel,
    this.sha256Hash,
    this.fileSizeBytes,
    this.releaseNotes,
    this.bootloaderType,
    this.artifactKind,
    this.mandatory = false,
  });

  final String releaseId;
  final String version;
  final String? hardwareModel;
  final String? sha256Hash;
  final int? fileSizeBytes;
  final String? releaseNotes;
  final String? bootloaderType;
  final String? artifactKind;
  final bool mandatory;
}

class FirmwareUpdateEligibility {
  const FirmwareUpdateEligibility({
    required this.eligible,
    this.blockers = const <FirmwareUpdateBlocker>[],
    this.messages = const <String>[],
  });

  final bool eligible;
  final List<FirmwareUpdateBlocker> blockers;
  final List<String> messages;

  static const eligibleResult = FirmwareUpdateEligibility(eligible: true);
}

class FirmwareUpdateCheck {
  const FirmwareUpdateCheck({
    required this.device,
    required this.updateAvailable,
    required this.eligibility,
    required this.checkedAt,
    this.release,
  });

  final DeviceFirmwareInfo device;
  final bool updateAvailable;
  final FirmwareRelease? release;
  final FirmwareUpdateEligibility eligibility;
  final DateTime checkedAt;
}

class FirmwareUpdateSession {
  const FirmwareUpdateSession({
    required this.sessionId,
    required this.deviceId,
    required this.releaseId,
    required this.fromVersion,
    required this.targetVersion,
    required this.state,
    required this.startedAt,
    this.completedAt,
    this.failureCode,
    this.failureMessage,
    this.nativeTransferEngaged = false,
    this.requiresRecovery = false,
    this.schemaVersion = currentSchemaVersion,
    this.hardwareId,
    this.updatedAt,
    this.nextAction = FirmwareUpdateNextAction.none,
    this.reconciliationOutcome,
    this.artifactReference,
    this.artifactSha256,
    this.artifactSizeBytes,
    this.artifactDownloaded = false,
    this.artifactVerified = false,
    this.migrationOwned = false,
    this.recoveryDeviceMatched = false,
    this.remoteRecoveryAttempts = 0,
    this.remoteRecoveryFailed = false,
    this.recoveryReconciliationAttempts = 0,
    this.remoteRecoveryExhausted = false,
  });

  static const int currentSchemaVersion = 1;

  final String sessionId;
  final String deviceId;
  final String releaseId;
  final String fromVersion;
  final String targetVersion;
  final FirmwareUpdateState state;
  final DateTime startedAt;
  final DateTime? completedAt;
  final String? failureCode;
  final String? failureMessage;
  final bool migrationOwned;
  final String? artifactReference;
  final String? artifactSha256;
  final int? artifactSizeBytes;
  final bool artifactDownloaded;
  final bool artifactVerified;
  final bool nativeTransferEngaged;
  final bool requiresRecovery;
  final int schemaVersion;
  final String? hardwareId;
  final DateTime? updatedAt;
  final FirmwareUpdateNextAction nextAction;
  final FirmwareUpdateReconciliationOutcome? reconciliationOutcome;

  /// SDK evidence of a strongly matched, supported recovery advertisement.
  final bool recoveryDeviceMatched;
  final int remoteRecoveryAttempts;

  /// A native recovery invocation returned a terminal transport/recovery error.
  /// This is not a claim about the validity of the installed application.
  final bool remoteRecoveryFailed;
  final int recoveryReconciliationAttempts;
  final bool remoteRecoveryExhausted;

  bool get manualRecoveryRequired =>
      !isCompleted &&
      requiresRecovery &&
      nativeTransferEngaged &&
      recoveryDeviceMatched &&
      remoteRecoveryAttempts > 0 &&
      remoteRecoveryFailed &&
      remoteRecoveryExhausted;

  bool get isCompleted => state == FirmwareUpdateState.completed;

  bool get canCancel =>
      !nativeTransferEngaged && _firmwarePreparationCanCancel(state);

  FirmwareUpdateSession copyWith({
    bool? recoveryDeviceMatched,
    int? remoteRecoveryAttempts,
    bool? remoteRecoveryFailed,
    int? recoveryReconciliationAttempts,
    bool? remoteRecoveryExhausted,
    String? artifactReference,
    String? artifactSha256,
    int? artifactSizeBytes,
    bool? artifactDownloaded,
    bool? artifactVerified,
    FirmwareUpdateState? state,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? failureCode,
    String? failureMessage,
    bool? nativeTransferEngaged,
    bool? requiresRecovery,
    String? hardwareId,
    DateTime? updatedAt,
    FirmwareUpdateNextAction? nextAction,
    FirmwareUpdateReconciliationOutcome? reconciliationOutcome,
  }) {
    return FirmwareUpdateSession(
      recoveryDeviceMatched:
          recoveryDeviceMatched ?? this.recoveryDeviceMatched,
      remoteRecoveryAttempts:
          remoteRecoveryAttempts ?? this.remoteRecoveryAttempts,
      remoteRecoveryFailed: remoteRecoveryFailed ?? this.remoteRecoveryFailed,
      recoveryReconciliationAttempts:
          recoveryReconciliationAttempts ?? this.recoveryReconciliationAttempts,
      remoteRecoveryExhausted:
          remoteRecoveryExhausted ?? this.remoteRecoveryExhausted,
      migrationOwned: migrationOwned,
      artifactReference: artifactReference ?? this.artifactReference,
      artifactSha256: artifactSha256 ?? this.artifactSha256,
      artifactSizeBytes: artifactSizeBytes ?? this.artifactSizeBytes,
      artifactDownloaded: artifactDownloaded ?? this.artifactDownloaded,
      artifactVerified: artifactVerified ?? this.artifactVerified,
      sessionId: sessionId,
      deviceId: deviceId,
      releaseId: releaseId,
      fromVersion: fromVersion,
      targetVersion: targetVersion,
      state: state ?? this.state,
      startedAt: startedAt,
      completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
      failureCode: failureCode ?? this.failureCode,
      failureMessage: failureMessage ?? this.failureMessage,
      nativeTransferEngaged:
          nativeTransferEngaged ?? this.nativeTransferEngaged,
      requiresRecovery: requiresRecovery ?? this.requiresRecovery,
      schemaVersion: schemaVersion,
      hardwareId: hardwareId ?? this.hardwareId,
      updatedAt: updatedAt ?? this.updatedAt,
      nextAction: nextAction ?? this.nextAction,
      reconciliationOutcome:
          reconciliationOutcome ?? this.reconciliationOutcome,
    );
  }
}

class FirmwareUpdateProgress {
  const FirmwareUpdateProgress({
    required this.sessionId,
    required this.deviceId,
    required this.state,
    required this.updatedAt,
    this.progressPercentage,
    this.bytesTransferred,
    this.totalBytes,
    this.failureCode,
    this.failureMessage,
    this.nativeTransferEngaged = false,
    this.requiresRecovery = false,
  });

  final String sessionId;
  final String deviceId;
  final FirmwareUpdateState state;
  final int? progressPercentage;
  final int? bytesTransferred;
  final int? totalBytes;
  final String? failureCode;
  final String? failureMessage;
  final bool nativeTransferEngaged;
  final bool requiresRecovery;
  final DateTime updatedAt;

  bool get canCancel =>
      !nativeTransferEngaged && _firmwarePreparationCanCancel(state);

  /// The completion percentage (0–100) to display, preferring the native
  /// [progressPercentage] and falling back to one derived from
  /// [bytesTransferred] / [totalBytes] when the native layer reports only byte
  /// counts. `null` when neither is available (an indeterminate phase). Callers
  /// should use this instead of re-deriving the byte math so every progress UI
  /// presents the same value.
  int? get effectivePercentage {
    final percent = progressPercentage;
    if (percent != null) {
      return percent.clamp(0, 100);
    }
    final transferred = bytesTransferred;
    final total = totalBytes;
    if (transferred != null && total != null && total > 0) {
      return ((transferred * 100) ~/ total).clamp(0, 100);
    }
    return null;
  }
}

// The SDK owns cancellation safety; hosts only render this verdict.
bool _firmwarePreparationCanCancel(FirmwareUpdateState state) =>
    switch (state) {
      FirmwareUpdateState.downloading ||
      FirmwareUpdateState.verifying ||
      FirmwareUpdateState.readyToTransfer => true,
      _ => false,
    };
