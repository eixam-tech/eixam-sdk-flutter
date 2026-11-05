import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Everything the state derivation looks at. Gathered by the controller; pure
/// input so every state and transition is unit-testable.
class DfuRecoveryEvidence {
  const DfuRecoveryEvidence({
    this.hasInterruptedUpdate = false,
    this.dismissed = false,
    this.recoveredLatched = false,
    this.operationInProgress = false,
    this.bootloaderMatches = 0,
    this.stockObserved = false,
    this.iosStaleLinkSuspected = false,
    this.cablePrepared = false,
    this.silentFor,
    this.progressFraction,
    this.deviceId,
  });

  /// A persisted firmware session whose native transfer started and that never
  /// completed.
  final bool hasInterruptedUpdate;

  /// The user dismissed the recovery for the current interrupted session.
  final bool dismissed;

  /// Reconnect + installed version were verified.
  final bool recoveredLatched;

  /// An update/recovery DFU or a migration currently owns the device.
  final bool operationInProgress;

  /// Number of DFU-bootloader advertisements matching the interrupted device.
  final int bootloaderMatches;

  /// The TAG is back as stock Meshtastic: hardware model re-verified and same
  /// identity as the interrupted session.
  final bool stockObserved;

  /// iOS connect failed with the stale bond signature and the TAG advertises.
  final bool iosStaleLinkSuspected;

  /// A user-started cable preparation left the TAG off the air.
  final bool cablePrepared;

  /// How long the TAG has been unseen in any mode.
  final Duration? silentFor;
  final double? progressFraction;
  final String? deviceId;
}

/// Maps evidence to the public status. First matching rule wins.
DfuRecoveryStatus deriveDfuRecoveryStatus(
  DfuRecoveryEvidence evidence, {
  required E1RecoveryStrategy strategy,
  required Duration silenceWindow,
}) {
  DfuRecoveryStatus status(
    DfuRecoveryState state,
    DfuRecoveryReason reason, {
    DfuRecoveryAction action = DfuRecoveryAction.none,
    bool needsCable = false,
  }) => DfuRecoveryStatus(
    state: state,
    reason: reason,
    availableAction: action,
    needsCable: needsCable,
    progressFraction: evidence.progressFraction,
    deviceId: evidence.deviceId,
  );

  if (evidence.dismissed) {
    return status(
      DfuRecoveryState.unknown,
      DfuRecoveryReason.noInterruptedUpdate,
    );
  }
  if (evidence.recoveredLatched) {
    return status(
      DfuRecoveryState.recovered,
      DfuRecoveryReason.versionVerified,
    );
  }
  if (evidence.operationInProgress) {
    return status(DfuRecoveryState.unknown, DfuRecoveryReason.updateInProgress);
  }
  if (!evidence.hasInterruptedUpdate) {
    return status(
      DfuRecoveryState.unknown,
      DfuRecoveryReason.noInterruptedUpdate,
    );
  }
  if (evidence.stockObserved) {
    return status(
      DfuRecoveryState.unknown,
      DfuRecoveryReason.physicalRecoveryCompleted,
    );
  }
  if (evidence.iosStaleLinkSuspected) {
    return status(
      DfuRecoveryState.iosStaleLink,
      DfuRecoveryReason.iosStaleBondSuspected,
      action: DfuRecoveryAction.forgetDevice,
    );
  }
  if (evidence.bootloaderMatches == 1) {
    return status(
      DfuRecoveryState.resumable,
      DfuRecoveryReason.bootloaderVisible,
      action: strategy == E1RecoveryStrategy.restartFromScratch
          ? DfuRecoveryAction.restartDfuFromScratch
          : DfuRecoveryAction.prepareCableRecovery,
      needsCable: strategy == E1RecoveryStrategy.cableRecovery,
    );
  }
  if (evidence.bootloaderMatches > 1) {
    return status(DfuRecoveryState.unknown, DfuRecoveryReason.awaitingEvidence);
  }
  if (evidence.cablePrepared) {
    return status(
      DfuRecoveryState.silentNeedsCable,
      DfuRecoveryReason.cableRecoveryPrepared,
      needsCable: true,
    );
  }
  final silent = evidence.silentFor;
  if (silent != null && silent >= silenceWindow) {
    return status(
      DfuRecoveryState.silentNeedsCable,
      DfuRecoveryReason.deviceSilent,
      needsCable: true,
    );
  }
  return status(DfuRecoveryState.unknown, DfuRecoveryReason.awaitingEvidence);
}
