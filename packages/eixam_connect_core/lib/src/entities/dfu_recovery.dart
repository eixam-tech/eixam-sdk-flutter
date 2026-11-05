/// What the SDK offers when an interrupted legacy DFU leaves the TAG visible as
/// the bootloader (AdaDFU, "E1").
///
/// With bootloader 0.4.3 a BLE update cannot be resumed or restarted: the
/// bootloader answers every new Start with INVALID_STATE and the Nordic library
/// then resets it into USB/UF2-only mode (verified on hardware). The strategy
/// is therefore chosen per device from its bootloader version
/// ([resolveE1RecoveryStrategy]); 0.4.3 and unknown versions get
/// [cableRecovery]. The final E1 product behaviour remains an open decision.
enum E1RecoveryStrategy {
  /// Offer [DfuRecoveryAction.prepareCableRecovery]: one tap deliberately
  /// resets the TAG into its USB/UF2 bootloader so the user can finish with a
  /// cable.
  cableRecovery,

  /// Offer [DfuRecoveryAction.restartDfuFromScratch]: one tap starts a fresh
  /// DFU session. On bootloader 0.4.3 this is verified to end in USB/UF2-only
  /// mode; it exists for a future bootloader that stays in OTA mode.
  restartFromScratch,
}

/// Coarse state of an interrupted-DFU recovery. No UI wording lives here.
enum DfuRecoveryState {
  /// Interrupted update, the TAG is visible as the DFU bootloader (E1). The
  /// name is historical: BLE can NOT resume the update on bootloader 0.4.3. The
  /// only action is the one selected by [E1RecoveryStrategy].
  resumable,

  /// iOS only: the TAG advertises but the connection fails with the stale
  /// bond / GATT cache signature (CBError 14). Action: forget the device.
  /// UNVERIFIED ON HARDWARE.
  iosStaleLink,

  /// Interrupted update and the TAG is silent on BLE (USB/UF2 bootloader, E2).
  /// The phone cannot observe the UF2 drive: this is derived from a persisted
  /// interrupted session plus silence, or from a deliberate cable preparation.
  silentNeedsCable,

  /// The TAG reconnected and the installed firmware version was verified.
  recovered,

  /// No interrupted update, an operation is running, or evidence is not yet
  /// sufficient to classify the situation.
  unknown,
}

/// Machine-readable explanation for [DfuRecoveryStatus.state].
enum DfuRecoveryReason {
  noInterruptedUpdate,
  updateInProgress,
  awaitingEvidence,
  bootloaderVisible,
  cableRecoveryPrepared,
  deviceSilent,
  iosStaleBondSuspected,
  versionVerified,

  /// The TAG came back as stock Meshtastic after a physical (cable) recovery;
  /// the stale interrupted record was superseded. Continue the normal
  /// stock -> EIXAM migration.
  physicalRecoveryCompleted,
}

/// The single action a host may offer for the current status.
enum DfuRecoveryAction {
  none,

  /// [DfuRecoveryControl.restartDfuFromScratch] (E1, strategy restartFromScratch).
  restartDfuFromScratch,

  /// [DfuRecoveryControl.prepareCableRecovery] (E1, strategy cableRecovery).
  prepareCableRecovery,

  /// iOS: the user removes the TAG in the system Bluetooth settings, then the
  /// host calls [DfuRecoveryControl.confirmDeviceForgotten].
  forgetDevice,
}

class DfuRecoveryStatus {
  const DfuRecoveryStatus({
    required this.state,
    required this.reason,
    this.availableAction = DfuRecoveryAction.none,
    this.needsCable = false,
    this.progressFraction,
    this.deviceId,
    this.updatedAt,
    this.warnings = const <DfuPreflightWarning>[],
  });

  const DfuRecoveryStatus.unknown({
    DfuRecoveryReason reason = DfuRecoveryReason.noInterruptedUpdate,
  }) : this(state: DfuRecoveryState.unknown, reason: reason);

  final DfuRecoveryState state;
  final DfuRecoveryReason reason;

  /// The one action currently allowed; everything else is rejected with a
  /// [DfuPreflightFailure.actionNotAvailable].
  final DfuRecoveryAction availableAction;

  /// The recovery ends with the user copying a file to the TAG over a cable.
  final bool needsCable;

  /// 0..1 while a recovery DFU runs, otherwise null.
  final double? progressFraction;

  /// Platform id of the affected TAG when known.
  final String? deviceId;
  final DateTime? updatedAt;

  /// Pre-flight checks of the last action whose value could not be read.
  final List<DfuPreflightWarning> warnings;

  DfuRecoveryStatus copyWith({
    DfuRecoveryState? state,
    DfuRecoveryReason? reason,
    DfuRecoveryAction? availableAction,
    bool? needsCable,
    double? progressFraction,
    bool clearProgress = false,
    String? deviceId,
    DateTime? updatedAt,
    List<DfuPreflightWarning>? warnings,
  }) {
    return DfuRecoveryStatus(
      warnings: warnings ?? this.warnings,
      state: state ?? this.state,
      reason: reason ?? this.reason,
      availableAction: availableAction ?? this.availableAction,
      needsCable: needsCable ?? this.needsCable,
      progressFraction: clearProgress
          ? null
          : (progressFraction ?? this.progressFraction),
      deviceId: deviceId ?? this.deviceId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Equality ignores [updatedAt] so streams can de-duplicate.
  @override
  bool operator ==(Object other) =>
      other is DfuRecoveryStatus &&
      other.state == state &&
      other.reason == reason &&
      other.availableAction == availableAction &&
      other.needsCable == needsCable &&
      other.progressFraction == progressFraction &&
      other.deviceId == deviceId &&
      _sameWarnings(other.warnings, warnings);

  static bool _sameWarnings(
    List<DfuPreflightWarning> a,
    List<DfuPreflightWarning> b,
  ) => a.length == b.length && a.every(b.contains);

  @override
  int get hashCode => Object.hash(
    state,
    reason,
    availableAction,
    needsCable,
    progressFraction,
    deviceId,
    warnings.length,
  );

  @override
  String toString() =>
      'DfuRecoveryStatus($state, $reason, action=$availableAction, '
      'needsCable=$needsCable)';
}

/// A pre-flight check whose value could not be read. Unknown is never a
/// failure: the start proceeds and the host may show the warning. Only a value
/// that was read and fails its threshold, or a precondition known to be false
/// (Bluetooth off), blocks. Which checks can be unknown depends on the
/// platform and firmware (see the API docs).
enum DfuPreflightWarning {
  /// TAG battery unreadable (for example stock firmware, or the bootloader).
  deviceBatteryUnknown,
  phoneBatteryUnknown,
  phoneChargingUnknown,
  screenStateUnknown,
  appForegroundUnknown,
  bluetoothStateUnknown,
}

/// Why a DFU (ordinary update, migration or recovery) was refused before
/// anything was sent. Each pre-flight check has its own reason; a failing check
/// blocks the start, never a silent start.
enum DfuPreflightFailure {
  bluetoothOff,
  appNotForeground,
  screenNotAwake,
  phoneBatteryLow,
  deviceBatteryLow,
  deviceNotVisible,
  operationInProgress,

  /// The host did not confirm it showed the "if interrupted, a computer will
  /// be needed" warning (`FirmwareUpdatePolicy.interruptionWarningAcknowledged`).
  interruptionWarningNotAcknowledged,
  noInterruptedUpdate,
  actionNotAvailable,
  artifactUnavailable,
  failed,
}

/// Bootloader versions proven (on hardware) to stay in OTA mode after an
/// interrupted update, so that a fresh BLE DFU session can succeed. EMPTY on
/// purpose: bootloader 0.4.3 is verified NOT to, and an unknown version is
/// treated like 0.4.3. A version is added here only with hardware evidence.
const Set<String> kBleRestartCapableBootloaderVersions = <String>{};

/// Picks the single E1 action for a TAG from its bootloader version.
///
/// [bootloaderVersion] is the leading version token of the bootloader's Device
/// Information firmware revision (for example `0.4.3` from `0.4.3 s140 6.1.1`).
/// Null/unparseable/unlisted -> [E1RecoveryStrategy.cableRecovery].
E1RecoveryStrategy resolveE1RecoveryStrategy(
  String? bootloaderVersion, {
  Set<String> restartCapable = kBleRestartCapableBootloaderVersions,
}) {
  final token = bootloaderVersion?.trim().split(RegExp(r'\s+')).first;
  if (token == null || token.isEmpty) return E1RecoveryStrategy.cableRecovery;
  return restartCapable.contains(token)
      ? E1RecoveryStrategy.restartFromScratch
      : E1RecoveryStrategy.cableRecovery;
}
