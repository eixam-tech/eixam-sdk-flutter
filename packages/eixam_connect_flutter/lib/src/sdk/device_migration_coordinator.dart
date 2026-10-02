import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_client.dart';
import '../device/ble_scan_result.dart';
import '../device/canonical_hardware_id.dart';
import '../device/meshtastic_metadata_probe.dart';
import '../firmware_version.dart';
import 'device_migration_firmware_service.dart';
import 'device_migration_session_store.dart';

final class DeviceMigrationCoordinator {
  DeviceMigrationCoordinator({
    required this.bleClient,
    required this.metadataProbe,
    required this.firmwareUpdates,
    DeviceMigrationSessionStore? sessionStore,
    this.rediscoveryTimeout = const Duration(seconds: 12),
  }) : sessionStore = sessionStore ?? SharedPrefsDeviceMigrationSessionStore();

  static const int wisMeshTagHardwareModel = 105;
  static const String eixamFirmwareCatalogModel = 'EIXAM R1';
  static const String ambiguousDeviceCode = 'ambiguousPostMigrationDevice';

  final BleClient bleClient;
  final MeshtasticMetadataProbe metadataProbe;
  final DeviceMigrationFirmwareService firmwareUpdates;
  final DeviceMigrationSessionStore sessionStore;
  final Duration rediscoveryTimeout;

  BleScanResult? _verifiedMigratedDevice;
  DeviceMigrationSession? _session;
  Future<void>? _restoreFuture;
  Future<void> _writeTail = Future<void>.value();
  final StreamController<DeviceMigrationSession> _sessionController =
      StreamController<DeviceMigrationSession>.broadcast();

  Future<DeviceMigrationSession?> getActiveSession() async {
    await _restore();
    return _session?.state == DeviceMigrationState.completed ? null : _session;
  }

  Stream<DeviceMigrationSession> watchSession() async* {
    await _restore();
    final current = _session;
    if (current != null) yield current;
    yield* _sessionController.stream;
  }

  Future<DeviceMigrationCandidate> inspect({
    required String deviceId,
    String? advertisedName,
  }) async {
    if (deviceId.trim().isEmpty) {
      return _unableCandidate(
        deviceId: deviceId,
        advertisedName: advertisedName,
        code: 'missingDeviceId',
      );
    }
    try {
      final probe = await metadataProbe.inspect(deviceId);
      final model = probe.hardwareModel;
      final identity = _strongestIdentity(
        deviceId: deviceId,
        hardwareMac: probe.hardwareMac,
        nodeNumber: probe.nodeNumber,
      );
      return DeviceMigrationCandidate(
        deviceId: deviceId,
        advertisedName: advertisedName,
        compatibility: model == 0
            ? DeviceMigrationCompatibility.unableToVerify
            : model == wisMeshTagHardwareModel
            ? DeviceMigrationCompatibility.compatible
            : DeviceMigrationCompatibility.unsupportedHardware,
        sourceHardwareModel: model == 0 ? null : model,
        sourceFirmwareVersion: probe.firmwareVersion,
        stableIdentity: identity.$1,
        identityKind: identity.$2,
        sourceNodeNumber: probe.nodeNumber,
        batteryPercentage: probe.batteryPercentage,
        detailCode: model == 0 ? 'hardwareModelUnset' : null,
        inspectedAt: DateTime.now(),
      );
    } on MeshtasticInspectionException catch (error) {
      return _unableCandidate(
        deviceId: deviceId,
        advertisedName: advertisedName,
        code: error.failure.name,
        inspectionFailure: error.failure,
      );
    } on MeshtasticDeviceUnavailableException {
      return _unableCandidate(
        deviceId: deviceId,
        advertisedName: advertisedName,
        code: 'selectedDeviceUnavailable',
      );
    } catch (_) {
      return _unableCandidate(
        deviceId: deviceId,
        advertisedName: advertisedName,
        code: 'hardwareVerificationFailed',
      );
    }
  }

  Future<DeviceMigrationResult> migrate(
    DeviceMigrationCandidate candidate,
  ) async {
    await _restore();
    final activeFirmware = await firmwareUpdates
        .getActiveMigrationFirmwareUpdate();
    if (activeFirmware != null &&
        !_firmwareSessionMatchesCandidate(activeFirmware, candidate)) {
      return _blocked(candidate, 'firmwareUpdateActiveForAnotherDevice');
    }
    if (activeFirmware != null) {
      return _blocked(candidate, 'firmwareUpdateResumeRequired');
    }
    final active = _session;
    if (active != null &&
        active.state != DeviceMigrationState.completed &&
        !_samePhysicalDevice(active.candidate, candidate)) {
      return _blocked(candidate, 'migrationActiveForAnotherDevice');
    }
    if (!candidate.isCompatible ||
        candidate.sourceHardwareModel != wisMeshTagHardwareModel) {
      return _blocked(candidate, 'migrationCandidateNotCompatible');
    }

    // Never trust a caller-constructed or stale candidate. The exact selected
    // platform ID is probed again immediately before artifact selection.
    final revalidated = await inspect(
      deviceId: candidate.deviceId,
      advertisedName: candidate.advertisedName,
    );
    if (!revalidated.isCompatible ||
        revalidated.sourceHardwareModel != wisMeshTagHardwareModel) {
      return _blocked(revalidated, 'migrationRevalidationFailed');
    }
    if (!_samePreMigrationIdentity(candidate, revalidated)) {
      return _blocked(revalidated, 'migrationIdentityChanged');
    }

    FirmwareRelease? release;
    try {
      release = await firmwareUpdates.resolveMigrationRelease(
        hardwareModel: eixamFirmwareCatalogModel,
      );
    } catch (_) {
      return _blocked(revalidated, 'migrationArtifactUnavailable');
    }
    if (release == null) {
      return _blocked(revalidated, 'migrationArtifactUnavailable');
    }

    final now = DateTime.now();
    await _publish(
      DeviceMigrationSession(
        sessionId: 'migration-${now.microsecondsSinceEpoch}',
        schemaVersion: DeviceMigrationSession.currentSchemaVersion,
        candidate: revalidated,
        releaseId: release.releaseId,
        targetVersion: release.version,
        state: DeviceMigrationState.prepared,
        nextAction: DeviceMigrationNextAction.continueMigration,
        canCancel: true,
        createdAt: now,
        updatedAt: now,
      ),
    );

    _verifiedMigratedDevice = null;
    final sourceStatus = DeviceStatus(
      deviceId: revalidated.deviceId,
      nodeId: revalidated.sourceNodeNumber,
      canonicalHardwareId: normalizeCanonicalHardwareId(
        revalidated.stableIdentity,
      ),
      deviceAlias: revalidated.advertisedName,
      model: eixamFirmwareCatalogModel,
      paired: true,
      activated: false,
      connected: true,
      batteryPercent: revalidated.batteryPercentage,
      firmwareVersion: revalidated.sourceFirmwareVersion ?? 'stock-meshtastic',
    );
    final progressSub = firmwareUpdates
        .watchMigrationFirmwareProgress(deviceId: sourceStatus.deviceId)
        .listen(_onFirmwareProgress);
    late final FirmwareUpdateSession session;
    try {
      session = await firmwareUpdates.startMigrationFirmwareUpdate(
        sourceStatus: sourceStatus,
        release: release,
        policy: const FirmwareUpdatePolicy(
          supportedHardwareModels: <String>[eixamFirmwareCatalogModel],
          requireKnownDeviceBattery: false,
        ),
        postMigrationStatusRefresh:
            ({required deviceId, required attempt, required targetVersion}) =>
                _rediscoverAndVerify(
                  candidate: revalidated,
                  targetVersion: targetVersion,
                ),
      );
    } finally {
      await progressSub.cancel();
      await _writeTail;
    }

    if (session.state == FirmwareUpdateState.completed &&
        _verifiedMigratedDevice != null) {
      await _publish(
        _session!.copyWith(
          firmwareSession: session,
          migratedDevice: _verifiedMigratedDevice!.toPublic(),
          state: DeviceMigrationState.completed,
          outcome: DeviceMigrationOutcome.completed,
          reconciliationOutcome: DeviceMigrationReconciliationOutcome.completed,
          nextAction: DeviceMigrationNextAction.completed,
          canCancel: false,
          updatedAt: DateTime.now(),
        ),
        clearPersisted: true,
      );
      return DeviceMigrationResult(
        outcome: DeviceMigrationOutcome.completed,
        candidate: revalidated,
        firmwareSession: session,
        migratedDevice: _verifiedMigratedDevice!.toPublic(),
      );
    }
    final ambiguous = session.failureCode == ambiguousDeviceCode;
    final outcome = ambiguous
        ? DeviceMigrationOutcome.ambiguousPostMigrationDevice
        : session.state == FirmwareUpdateState.recoveryRequired
        ? DeviceMigrationOutcome.recoveryRequired
        : session.state == FirmwareUpdateState.blocked
        ? DeviceMigrationOutcome.blocked
        : DeviceMigrationOutcome.failed;
    await _publish(
      _session!.copyWith(
        firmwareSession: session,
        state: session.state == FirmwareUpdateState.recoveryRequired
            ? DeviceMigrationState.recoveryRequired
            : session.state == FirmwareUpdateState.blocked
            ? DeviceMigrationState.blocked
            : DeviceMigrationState.failed,
        outcome: outcome,
        nextAction: session.state == FirmwareUpdateState.recoveryRequired
            ? DeviceMigrationNextAction.recover
            : ambiguous
            ? DeviceMigrationNextAction.reinspect
            : DeviceMigrationNextAction.retry,
        canCancel: false,
        failureCode: session.failureCode,
        failureMessage: session.failureMessage,
        updatedAt: DateTime.now(),
      ),
    );
    return DeviceMigrationResult(
      outcome: outcome,
      candidate: revalidated,
      firmwareSession: session,
      failureCode: session.failureCode,
      failureMessage: session.failureMessage,
    );
  }

  /// Reconciles a persisted operation using BLE identity and installed-version
  /// evidence. Recovery is attempted only for a bootloader with a strong
  /// identity match and only when [attemptRecovery] is explicitly requested.
  Future<DeviceMigrationSession?> reconcile({
    bool attemptRecovery = false,
  }) async {
    await _restore();
    final current = _session;
    if (current == null || current.state == DeviceMigrationState.completed) {
      return current;
    }
    await _publish(
      current.copyWith(
        state: DeviceMigrationState.reconciling,
        nextAction: DeviceMigrationNextAction.waitForDevice,
        canCancel: false,
        updatedAt: DateTime.now(),
      ),
    );
    final scans = await bleClient.scan(timeout: rediscoveryTimeout);
    final eixam = scans.where(_looksLikeEixam).toList(growable: false);
    final matchingEixam = eixam
        .where((scan) => _stronglyMatches(current.candidate, scan))
        .toList(growable: false);
    if (matchingEixam.length == 1) {
      final match = matchingEixam.single;
      final status = await _verifyMigratedScan(scan: match);
      if (status.connected &&
          eixamFirmwareVersionsMatch(
            status.firmwareVersion,
            current.targetVersion,
          )) {
        final completed = current.copyWith(
          migratedDevice: match.toPublic(),
          state: DeviceMigrationState.completed,
          outcome: DeviceMigrationOutcome.completed,
          reconciliationOutcome: DeviceMigrationReconciliationOutcome.completed,
          nextAction: DeviceMigrationNextAction.completed,
          canCancel: false,
          updatedAt: DateTime.now(),
        );
        await _publish(completed, clearPersisted: true);
        return completed;
      }
      return _reconciled(
        current,
        state: DeviceMigrationState.failed,
        outcome: DeviceMigrationReconciliationOutcome.migratedDeviceVerified,
        nextAction: DeviceMigrationNextAction.retry,
        failureCode: 'installedVersionMismatch',
      );
    }
    if (matchingEixam.length > 1 ||
        (matchingEixam.isEmpty && eixam.length > 1)) {
      return _reconciled(
        current,
        state: DeviceMigrationState.waitingForDevice,
        outcome: DeviceMigrationReconciliationOutcome.ambiguousCandidates,
        nextAction: DeviceMigrationNextAction.reinspect,
        failureCode: ambiguousDeviceCode,
      );
    }

    final bootloaders = scans
        .where((scan) => scan.toPublic().isDfuBootloader)
        .toList(growable: false);
    final matchingBootloaders = bootloaders
        .where((scan) => _stronglyMatches(current.candidate, scan))
        .toList(growable: false);
    if (matchingBootloaders.length == 1) {
      final bootloader = matchingBootloaders.single;
      if (attemptRecovery) {
        final recovered = await firmwareUpdates.recoverMigrationFirmwareUpdate(
          bootloaderDeviceId: bootloader.deviceId,
          releaseId: current.releaseId,
          targetVersion: current.targetVersion,
        );
        if (recovered.state == FirmwareUpdateState.completed) {
          await _publish(
            current.copyWith(
              firmwareSession: recovered,
              state: DeviceMigrationState.waitingForDevice,
              reconciliationOutcome: DeviceMigrationReconciliationOutcome
                  .matchingRecoveryDeviceFound,
              nextAction: DeviceMigrationNextAction.waitForDevice,
              canCancel: false,
              updatedAt: DateTime.now(),
            ),
          );
          return reconcile();
        }
        return _reconciled(
          current.copyWith(firmwareSession: recovered),
          state: DeviceMigrationState.recoveryRequired,
          outcome: DeviceMigrationReconciliationOutcome.recoveryRequired,
          nextAction: DeviceMigrationNextAction.recover,
          failureCode: recovered.failureCode ?? 'firmwareRecoveryFailed',
        );
      }
      return _reconciled(
        current,
        state: DeviceMigrationState.recoveryRequired,
        outcome: DeviceMigrationReconciliationOutcome.recoveryRequired,
        nextAction: DeviceMigrationNextAction.recover,
      );
    }
    if (matchingBootloaders.length > 1 || bootloaders.length > 1) {
      return _reconciled(
        current,
        state: DeviceMigrationState.waitingForDevice,
        outcome: DeviceMigrationReconciliationOutcome.ambiguousCandidates,
        nextAction: DeviceMigrationNextAction.reinspect,
      );
    }

    final sourceFound = scans.any(
      (scan) =>
          !scan.toPublic().isDfuBootloader &&
          !_looksLikeEixam(scan) &&
          _stronglyMatches(current.candidate, scan),
    );
    if (sourceFound) {
      return _reconciled(
        current,
        state: DeviceMigrationState.prepared,
        outcome: DeviceMigrationReconciliationOutcome.originalSourceDeviceFound,
        nextAction: DeviceMigrationNextAction.continueMigration,
        canCancel: true,
      );
    }
    return _reconciled(
      current,
      state: DeviceMigrationState.waitingForDevice,
      outcome: DeviceMigrationReconciliationOutcome.deviceNotFound,
      nextAction: DeviceMigrationNextAction.waitForDevice,
    );
  }

  Future<void> dispose() async {
    await _writeTail;
    await _sessionController.close();
  }

  Future<void> _restore() {
    return _restoreFuture ??= () async {
      _session = await sessionStore.load();
    }();
  }

  void _onFirmwareProgress(FirmwareUpdateProgress progress) {
    final current = _session;
    if (current == null) return;
    final terminal =
        progress.state == FirmwareUpdateState.completed ||
        progress.state == FirmwareUpdateState.failed ||
        progress.state == FirmwareUpdateState.cancelled ||
        progress.state == FirmwareUpdateState.blocked ||
        progress.state == FirmwareUpdateState.recoveryRequired;
    final firmwareSession = FirmwareUpdateSession(
      sessionId: progress.sessionId,
      deviceId: progress.deviceId,
      releaseId: current.releaseId,
      fromVersion: current.candidate.sourceFirmwareVersion ?? '',
      targetVersion: current.targetVersion,
      state: progress.state,
      startedAt: current.createdAt,
      completedAt: terminal ? progress.updatedAt : null,
      failureCode: progress.failureCode,
      failureMessage: progress.failureMessage,
      nativeTransferEngaged: progress.nativeTransferEngaged,
      requiresRecovery: progress.requiresRecovery,
    );
    final migrationState = switch (progress.state) {
      FirmwareUpdateState.transferring => DeviceMigrationState.transferring,
      FirmwareUpdateState.reconnecting ||
      FirmwareUpdateState.verifyingInstalledVersion =>
        DeviceMigrationState.waitingForDevice,
      FirmwareUpdateState.recoveryRequired =>
        DeviceMigrationState.recoveryRequired,
      FirmwareUpdateState.blocked => DeviceMigrationState.blocked,
      FirmwareUpdateState.failed ||
      FirmwareUpdateState.cancelled => DeviceMigrationState.failed,
      _ => DeviceMigrationState.prepared,
    };
    final nextAction = switch (migrationState) {
      DeviceMigrationState.transferring ||
      DeviceMigrationState.waitingForDevice =>
        DeviceMigrationNextAction.waitForDevice,
      DeviceMigrationState.recoveryRequired =>
        DeviceMigrationNextAction.recover,
      DeviceMigrationState.failed ||
      DeviceMigrationState.blocked => DeviceMigrationNextAction.retry,
      _ => DeviceMigrationNextAction.continueMigration,
    };
    _writeTail = _writeTail.then(
      (_) => _publish(
        current.copyWith(
          firmwareSession: firmwareSession,
          state: migrationState,
          nextAction: nextAction,
          canCancel: !progress.nativeTransferEngaged && !terminal,
          failureCode: progress.failureCode,
          failureMessage: progress.failureMessage,
          updatedAt: progress.updatedAt,
        ),
      ),
    );
  }

  Future<DeviceMigrationSession> _reconciled(
    DeviceMigrationSession session, {
    required DeviceMigrationState state,
    required DeviceMigrationReconciliationOutcome outcome,
    required DeviceMigrationNextAction nextAction,
    bool canCancel = false,
    String? failureCode,
  }) async {
    final next = session.copyWith(
      state: state,
      reconciliationOutcome: outcome,
      nextAction: nextAction,
      canCancel: canCancel,
      failureCode: failureCode,
      updatedAt: DateTime.now(),
    );
    await _publish(next);
    return next;
  }

  Future<void> _publish(
    DeviceMigrationSession session, {
    bool clearPersisted = false,
  }) async {
    _session = session;
    if (clearPersisted) {
      await sessionStore.clear();
    } else {
      await sessionStore.save(session);
    }
    if (!_sessionController.isClosed) _sessionController.add(session);
  }

  Future<DeviceStatus> _rediscoverAndVerify({
    required DeviceMigrationCandidate candidate,
    required String targetVersion,
  }) async {
    final scans = await bleClient.scan(timeout: rediscoveryTimeout);
    final eixam = scans.where(_looksLikeEixam).toList(growable: false);
    final matches = eixam
        .where((scan) => _stronglyMatches(candidate, scan))
        .toList(growable: false);
    if (matches.length > 1 || (matches.isEmpty && eixam.length > 1)) {
      throw const FirmwareUpdateException(
        ambiguousDeviceCode,
        'Multiple Eixam devices were visible and identity was ambiguous.',
        requiresRecovery: false,
      );
    }
    if (matches.isEmpty) {
      return _disconnectedStatus(candidate.deviceId);
    }

    final match = matches.single;
    return _verifyMigratedScan(scan: match);
  }

  Future<DeviceStatus> _verifyMigratedScan({
    required BleScanResult scan,
  }) async {
    var connectedForVerification = false;
    try {
      await bleClient.connect(scan.deviceId);
      connectedForVerification = true;
      if (!await bleClient.isEixamCompatible(scan.deviceId)) {
        throw const FirmwareUpdateException(
          'postMigrationGattIncompatible',
          'The migrated device did not expose the required Eixam GATT API.',
          requiresRecovery: false,
        );
      }
      final installed = await bleClient.readFirmwareVersion(scan.deviceId);
      _verifiedMigratedDevice = scan;
      return DeviceStatus(
        deviceId: scan.deviceId,
        canonicalHardwareId: scan.canonicalHardwareId,
        deviceAlias: scan.name,
        model: eixamFirmwareCatalogModel,
        paired: true,
        activated: false,
        connected: true,
        firmwareVersion: installed,
      );
    } on FirmwareUpdateException {
      rethrow;
    } catch (_) {
      return _disconnectedStatus(scan.deviceId);
    } finally {
      // Verification owns only a temporary GATT connection. Normal pairing
      // must rediscover the TAG and bind its runtime notifications itself; a
      // connected TAG no longer advertises and cannot appear in that scan.
      if (connectedForVerification) {
        await bleClient.disconnect(scan.deviceId);
      }
    }
  }

  DeviceStatus _disconnectedStatus(String deviceId) => DeviceStatus(
    deviceId: deviceId,
    model: eixamFirmwareCatalogModel,
    paired: false,
    activated: false,
    connected: false,
  );

  bool _looksLikeEixam(BleScanResult scan) {
    final public = scan.toPublic();
    return public.isEixamDevice && !public.isDfuBootloader;
  }

  bool _stronglyMatches(
    DeviceMigrationCandidate candidate,
    BleScanResult scan,
  ) {
    if (scan.deviceId == candidate.deviceId) return true;
    final candidateMac = normalizeCanonicalHardwareId(candidate.stableIdentity);
    final scanMac = normalizeCanonicalHardwareId(
      scan.canonicalHardwareId ?? scan.deviceId,
    );
    return candidateMac != null && scanMac == candidateMac;
  }

  bool _samePreMigrationIdentity(
    DeviceMigrationCandidate before,
    DeviceMigrationCandidate after,
  ) {
    if (before.deviceId != after.deviceId) return false;
    final beforeIdentity = before.stableIdentity?.trim();
    final afterIdentity = after.stableIdentity?.trim();
    return beforeIdentity == null ||
        beforeIdentity.isEmpty ||
        afterIdentity == null ||
        afterIdentity.isEmpty ||
        beforeIdentity == afterIdentity;
  }

  bool _samePhysicalDevice(
    DeviceMigrationCandidate first,
    DeviceMigrationCandidate second,
  ) {
    final firstStable = normalizeCanonicalHardwareId(first.stableIdentity);
    final secondStable = normalizeCanonicalHardwareId(second.stableIdentity);
    if (firstStable != null && secondStable != null) {
      return firstStable == secondStable;
    }
    return first.deviceId == second.deviceId;
  }

  bool _firmwareSessionMatchesCandidate(
    FirmwareUpdateSession session,
    DeviceMigrationCandidate candidate,
  ) {
    final firmwareStable = normalizeCanonicalHardwareId(session.hardwareId);
    final candidateStable = normalizeCanonicalHardwareId(
      candidate.stableIdentity,
    );
    if (firmwareStable != null && candidateStable != null) {
      return firmwareStable == candidateStable;
    }
    return session.deviceId == candidate.deviceId;
  }

  (String?, DeviceMigrationIdentityKind) _strongestIdentity({
    required String deviceId,
    required String? hardwareMac,
    required int? nodeNumber,
  }) {
    final mac =
        normalizeCanonicalHardwareId(hardwareMac) ??
        normalizeCanonicalHardwareId(deviceId);
    if (mac != null) {
      return (mac, DeviceMigrationIdentityKind.hardwareMac);
    }
    if (nodeNumber != null && nodeNumber != 0) {
      return (
        '!${nodeNumber.toRadixString(16).padLeft(8, '0')}',
        DeviceMigrationIdentityKind.meshtasticNodeNumber,
      );
    }
    if (deviceId.trim().isNotEmpty) {
      return (deviceId.trim(), DeviceMigrationIdentityKind.platformIdentifier);
    }
    return (null, DeviceMigrationIdentityKind.none);
  }

  DeviceMigrationCandidate _unableCandidate({
    required String deviceId,
    required String? advertisedName,
    required String code,
    DeviceMigrationInspectionFailure? inspectionFailure,
  }) => DeviceMigrationCandidate(
    deviceId: deviceId,
    advertisedName: advertisedName,
    compatibility: DeviceMigrationCompatibility.unableToVerify,
    identityKind: DeviceMigrationIdentityKind.none,
    inspectedAt: DateTime.now(),
    detailCode: code,
    inspectionFailure: inspectionFailure,
  );

  DeviceMigrationResult _blocked(
    DeviceMigrationCandidate candidate,
    String code,
  ) => DeviceMigrationResult(
    outcome: DeviceMigrationOutcome.blocked,
    candidate: candidate,
    failureCode: code,
  );
}
