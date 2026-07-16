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
    this.requireForeground = true,
    this.supportedHardwareModels = const <String>[],
    this.allowDowngrade = false,
    this.targetReleaseId,
  });

  final int minDeviceBatteryPercentage;
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
  });

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

  FirmwareUpdateSession copyWith({
    FirmwareUpdateState? state,
    DateTime? completedAt,
    String? failureCode,
    String? failureMessage,
  }) {
    return FirmwareUpdateSession(
      sessionId: sessionId,
      deviceId: deviceId,
      releaseId: releaseId,
      fromVersion: fromVersion,
      targetVersion: targetVersion,
      state: state ?? this.state,
      startedAt: startedAt,
      completedAt: completedAt ?? this.completedAt,
      failureCode: failureCode ?? this.failureCode,
      failureMessage: failureMessage ?? this.failureMessage,
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
  });

  final String sessionId;
  final String deviceId;
  final FirmwareUpdateState state;
  final int? progressPercentage;
  final int? bytesTransferred;
  final int? totalBytes;
  final String? failureCode;
  final String? failureMessage;
  final DateTime updatedAt;

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
