import '../entities/dfu_recovery.dart';

/// Optional capability: recovery of a TAG whose BLE firmware update was
/// interrupted. Detect with a type check; existing EixamConnectSdk
/// implementations need not implement it.
///
/// Honest statement: with bootloader 0.4.3 a BLE update can NOT be resumed.
/// Nothing here starts a DFU automatically, not even on app relaunch. Every
/// DFU-starting method is one explicit user action, runs the pre-flight checks
/// first and fails with a [DfuRecoveryException] instead of starting silently.
/// Success ([DfuRecoveryState.recovered]) is reported only after the TAG has
/// reconnected and its installed firmware version was verified.
abstract interface class DfuRecoveryControl {
  /// Derives the current status from fresh evidence.
  Future<DfuRecoveryStatus> getDfuRecoveryStatus();

  /// Emits the current status, then every change. Scans are issued only while
  /// listened to and only while an interrupted update is persisted.
  Stream<DfuRecoveryStatus> watchDfuRecovery();

  /// E1 with [E1RecoveryStrategy.restartFromScratch] only. One fresh DFU
  /// session. Verified on bootloader 0.4.3 to end with the TAG in USB/UF2-only
  /// mode (Start, then Reset 108-245 ms later).
  Future<DfuRecoveryStatus> restartDfuFromScratch();

  /// E1 with [E1RecoveryStrategy.cableRecovery] only. One fresh DFU session
  /// whose expected outcome is the bootloader reset into USB/UF2 mode; the
  /// state then becomes [DfuRecoveryState.silentNeedsCable].
  Future<DfuRecoveryStatus> prepareCableRecovery();

  /// iOS stale link: the user forgot the TAG in system settings. Clears the
  /// marker, re-scans and tries to reconnect. UNVERIFIED ON HARDWARE.
  Future<DfuRecoveryStatus> confirmDeviceForgotten();

  /// Archives the recovery record without touching the device.
  Future<DfuRecoveryStatus> dismissDfuRecovery();
}
