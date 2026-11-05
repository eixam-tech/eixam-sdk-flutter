import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_client.dart';
import '../device/ble_scan_result.dart';
import '../device/canonical_hardware_id.dart';
import '../device/meshtastic_ble_protocol.dart';
import 'device_migration_coordinator.dart';
import 'dfu_preflight.dart';
import 'dfu_recovery_record_store.dart';
import 'dfu_recovery_state.dart';
import 'firmware_update_coordinator.dart';

typedef DfuStockInspector =
    Future<DeviceMigrationCandidate> Function(String deviceId, String? name);

/// Recovery of a TAG whose BLE firmware update was interrupted.
///
/// Honest limits (bootloader 0.4.3, verified on hardware): a BLE update cannot
/// be resumed, and a fresh DFU session against the interrupted bootloader ends
/// with the library resetting it into USB/UF2-only mode. This controller never
/// starts a DFU by itself; each DFU-starting method is one explicit user action
/// behind the pre-flight checks. Success is reported only after the existing
/// reconnect + installed-version verification.
final class DfuRecoveryController implements DfuRecoveryControl {
  DfuRecoveryController({
    required this.firmware,
    required this.bleClient,
    required this.recordStore,
    required this.inspectStock,
    this.config = const EixamDfuRecoveryConfig(),
    this.isOtherOperationInProgress,
    bool Function()? isIosPlatform,
    this.reconnectAfterForget,
    this.knownDeviceBatteryPercent,
    this.phoneBattery,
    this.screenAwake,
    this.appForeground,
    this.bootloaderVersionReader,
    this.restartCapableBootloaders = kBleRestartCapableBootloaderVersions,
    this.minDeviceBatteryPercent = 20,
    DateTime Function()? clock,
    this.scanTimeout = const Duration(seconds: 8),
    this.postResetSettle = const Duration(seconds: 6),
    this.verificationTimeout = const Duration(minutes: 3),
    this.verificationPollInterval = const Duration(seconds: 5),
    Future<void> Function(Duration)? delay,
  }) : _isIosPlatform = isIosPlatform ?? (() => false),
       _clock = clock ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed;

  final FirmwareUpdateCoordinator firmware;
  final BleClient bleClient;
  final DfuRecoveryRecordStore recordStore;
  final DfuStockInspector inspectStock;
  final EixamDfuRecoveryConfig config;

  /// Another subsystem (stock migration, provisioning) owns the device.
  final bool Function()? isOtherOperationInProgress;

  /// iOS only: re-establishes the connection after the user forgot the TAG.
  final Future<bool> Function(BleScanResult scan)? reconnectAfterForget;

  /// Last known TAG battery (the bootloader exposes none). Null = unknown.
  final Future<int?> Function()? knownDeviceBatteryPercent;
  final PhoneBatteryProvider? phoneBattery;
  final ScreenAwakeProvider? screenAwake;
  final AppForegroundProvider? appForeground;

  /// Reads the bootloader version of the TAG currently advertising as the DFU
  /// bootloader (Device Information firmware revision, `2A26`, for example
  /// `0.4.3 s140 6.1.1`). Only consulted when [restartCapableBootloaders] is not
  /// empty; otherwise every device resolves to cable recovery without touching
  /// the TAG. Null or a failing reader means "unknown" -> cable recovery.
  final Future<String?> Function(String bootloaderDeviceId)?
  bootloaderVersionReader;

  /// Bootloader versions proven to allow a BLE restart (empty today).
  final Set<String> restartCapableBootloaders;
  final Map<String, E1RecoveryStrategy> _strategyBySession =
      <String, E1RecoveryStrategy>{};
  final int minDeviceBatteryPercent;
  final Duration scanTimeout;
  final Duration postResetSettle;
  final Duration verificationTimeout;
  final Duration verificationPollInterval;
  final bool Function() _isIosPlatform;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;

  // _actionLock rejects a second tap synchronously; _running means a recovery
  // DFU is actually executing.
  bool _actionLock = false;
  bool _running = false;
  double? _progress;
  DfuRecoveryStatus? _last;
  List<BleScanResult>? _scanCache;
  DateTime? _scanCacheAt;
  Timer? _timer;
  bool _refreshing = false;
  bool _forceNextEmit = false;
  StreamController<DfuRecoveryStatus>? _streamController;

  @override
  Stream<DfuRecoveryStatus> watchDfuRecovery() {
    // Closed by dispose().
    // ignore: close_sinks
    final controller = _streamController ??=
        StreamController<DfuRecoveryStatus>.broadcast(
          onListen: _startWatching,
          onCancel: _stopWatching,
        );
    return controller.stream;
  }

  void _startWatching() {
    _forceNextEmit = true;
    unawaited(_refreshAndEmit());
    _timer?.cancel();
    _timer = Timer.periodic(config.observeInterval, (_) {
      unawaited(_refreshAndEmit());
    });
  }

  void _stopWatching() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _refreshAndEmit() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await getDfuRecoveryStatus();
    } catch (_) {
      // Observation is best-effort; the next tick retries.
    } finally {
      _refreshing = false;
    }
  }

  Future<void> dispose() async {
    _stopWatching();
    await _streamController?.close();
  }

  void _publish(DfuRecoveryStatus status) {
    final stamped = status.copyWith(updatedAt: _clock());
    final unchanged = _last == status && !_forceNextEmit;
    _last = stamped;
    if (unchanged) return;
    _forceNextEmit = false;
    final stream = _streamController;
    if (stream != null && !stream.isClosed && stream.hasListener) {
      stream.add(stamped);
    }
  }

  /// iOS connect failed with CBError 14 (stale bond / GATT cache). Called by the
  /// reconnect coordinator; ignored off iOS. UNVERIFIED ON HARDWARE.
  Future<void> noteIosStaleBond(String deviceId) async {
    if (!_isIosPlatform()) return;
    final record = await recordStore.load();
    await recordStore.save(
      record.copyWith(staleLinkDeviceId: deviceId, staleLinkAt: _clock()),
    );
    _scanCacheAt = null;
  }

  @override
  Future<DfuRecoveryStatus> getDfuRecoveryStatus() async {
    final observation = await _observe();
    _publish(observation.status);
    return observation.status;
  }

  @override
  Future<DfuRecoveryStatus> restartDfuFromScratch() =>
      _runBootloaderAction(DfuRecoveryAction.restartDfuFromScratch);

  @override
  Future<DfuRecoveryStatus> prepareCableRecovery() =>
      _runBootloaderAction(DfuRecoveryAction.prepareCableRecovery);

  @override
  Future<DfuRecoveryStatus> dismissDfuRecovery() async {
    if (_actionLock || _running) {
      throw DfuRecoveryException(DfuPreflightFailure.operationInProgress);
    }
    _warnings = const <DfuPreflightWarning>[];
    final observation = await _observe();
    final record = await recordStore.load();
    await recordStore.save(
      DfuRecoveryRecord(
        sessionId: observation.session?.sessionId ?? record.sessionId,
        dismissedSessionId: observation.session?.sessionId,
      ),
    );
    final status = (await _observe()).status;
    _publish(status);
    return status;
  }

  @override
  Future<DfuRecoveryStatus> confirmDeviceForgotten() async {
    if (_actionLock || _running) {
      throw DfuRecoveryException(DfuPreflightFailure.operationInProgress);
    }
    final observation = await _observe(force: true);
    if (observation.status.availableAction != DfuRecoveryAction.forgetDevice) {
      throw DfuRecoveryException(DfuPreflightFailure.actionNotAvailable);
    }
    _actionLock = true;
    try {
      final record = await recordStore.load();
      final staleId = record.staleLinkDeviceId;
      await recordStore.save(record.copyWith(clearStaleLink: true));
      // Re-scan, then reconnect to the single matching advertisement.
      final session = observation.session!;
      final scans = await _scan(force: true) ?? const <BleScanResult>[];
      final matches = scans
          .where(
            (scan) =>
                scan.connectable &&
                !scan.toPublic().isDfuBootloader &&
                _sameIdentity(
                  scan.deviceId,
                  scan.canonicalHardwareId,
                  staleId ?? session.deviceId,
                  session.hardwareId,
                ),
          )
          .toList(growable: false);
      final reconnect = reconnectAfterForget;
      if (matches.length == 1 && reconnect != null) {
        try {
          await reconnect(matches.single);
        } catch (_) {
          // A failed reconnect leaves the status to fresh evidence.
        }
      }
    } finally {
      _actionLock = false;
    }
    final status = (await _observe(force: true)).status;
    _publish(status);
    return status;
  }

  Future<DfuRecoveryStatus> _runBootloaderAction(
    DfuRecoveryAction action,
  ) async {
    if (_actionLock || _running) {
      throw DfuRecoveryException(DfuPreflightFailure.operationInProgress);
    }
    _actionLock = true;
    try {
      final observation = await _observe(force: true);
      if (observation.status.reason == DfuRecoveryReason.updateInProgress) {
        throw DfuRecoveryException(DfuPreflightFailure.operationInProgress);
      }
      if (observation.session == null) {
        throw DfuRecoveryException(DfuPreflightFailure.noInterruptedUpdate);
      }
      if (observation.status.availableAction != action) {
        throw DfuRecoveryException(DfuPreflightFailure.actionNotAvailable);
      }
      final session = observation.session!;
      final preflight = await _preflight(
        session,
        checkDeviceBattery: action == DfuRecoveryAction.restartDfuFromScratch,
      );

      final attemptsBefore = session.remoteRecoveryAttempts;
      _running = true;
      _progress = 0;
      _publish(
        observation.status.copyWith(
          state: DfuRecoveryState.unknown,
          reason: DfuRecoveryReason.updateInProgress,
          availableAction: DfuRecoveryAction.none,
          progressFraction: 0,
        ),
      );
      final progressSub = firmware.watchProgress().listen((progress) {
        final percent = progress.progressPercentage;
        if (progress.sessionId != session.sessionId || percent == null) return;
        _progress = (percent.clamp(0, 100)) / 100;
        _publish(
          observation.status.copyWith(
            state: DfuRecoveryState.unknown,
            reason: DfuRecoveryReason.updateInProgress,
            availableAction: DfuRecoveryAction.none,
            progressFraction: _progress,
          ),
        );
      });
      FirmwareUpdateSession result;
      try {
        result = await firmware.startBootloaderRecoveryDfu(
          bootloaderDeviceId: preflight.bootloader.deviceId,
          interrupted: session,
        );
      } on FirmwareUpdateException catch (error) {
        throw _mapFirmwareFailure(error.code, error.message);
      } finally {
        await progressSub.cancel();
        _running = false;
        _progress = null;
      }

      if (result.remoteRecoveryAttempts <= attemptsBefore) {
        // Nothing reached the device: a refused start, never a silent one.
        throw _mapFirmwareFailure(result.failureCode, result.failureMessage);
      }
      final transferCompleted =
          result.state == FirmwareUpdateState.reconnecting &&
          !result.remoteRecoveryFailed;
      if (transferCompleted && await _verifyInstalledVersion()) {
        final record = await recordStore.load();
        await recordStore.save(
          record.copyWith(recoveredAt: _clock(), clearCablePrepared: true),
        );
      } else if (!transferCompleted &&
          action == DfuRecoveryAction.prepareCableRecovery) {
        await _confirmCablePreparation();
      }
      _scanCacheAt = null;
      _warnings = preflight.warnings;
      final status = (await _observe(force: true)).status;
      _publish(status);
      return status;
    } finally {
      _actionLock = false;
    }
  }

  /// After the deliberate reset the TAG must be gone from the air (USB/UF2
  /// bootloader); the phone cannot see the UF2 drive itself.
  Future<void> _confirmCablePreparation() async {
    await _delay(postResetSettle);
    final scans = await _scan(force: true);
    if (scans == null) return;
    final session = await firmware.getActiveFirmwareUpdate();
    if (session == null) return;
    final stillVisible = scans.any(
      (scan) => _sameIdentity(
        scan.deviceId,
        scan.canonicalHardwareId,
        session.deviceId,
        session.hardwareId,
      ),
    );
    if (stillVisible) return;
    final record = await recordStore.load();
    await recordStore.save(
      record.copyWith(
        sessionId: session.sessionId,
        cablePreparedAt: _clock(),
        clearFirstMiss: true,
      ),
    );
    await firmware.requirePhysicalRecovery();
  }

  Future<bool> _verifyInstalledVersion() async {
    final attempts =
        (verificationTimeout.inMilliseconds /
                verificationPollInterval.inMilliseconds)
            .ceil()
            .clamp(1, 1000);
    for (var attempt = 0; attempt < attempts; attempt++) {
      final session = await firmware.reconcileFirmwareUpdate();
      if (session != null && session.state == FirmwareUpdateState.completed) {
        return true;
      }
      if (attempt < attempts - 1) await _delay(verificationPollInterval);
    }
    return false;
  }

  DfuRecoveryException _mapFirmwareFailure(String? code, String? message) {
    for (final failure in DfuPreflightFailure.values) {
      if (failure.name == code) return DfuRecoveryException(failure, message);
    }
    if (code == 'firmwareUpdateAlreadyRunning') {
      return DfuRecoveryException(
        DfuPreflightFailure.operationInProgress,
        message,
      );
    }
    const artifact = <String>{
      'artifactMissing',
      'hashMissing',
      'hashMismatch',
      'artifactDownloadFailed',
      'artifactTooLarge',
    };
    if (artifact.contains(code)) {
      return DfuRecoveryException(
        DfuPreflightFailure.artifactUnavailable,
        message,
      );
    }
    return DfuRecoveryException(DfuPreflightFailure.failed, message ?? code);
  }

  /// Every check that must pass before a DFU is started. Returns the single
  /// matching bootloader advertisement.
  Future<({BleScanResult bootloader, List<DfuPreflightWarning> warnings})>
  _preflight(
    FirmwareUpdateSession session, {
    required bool checkDeviceBattery,
  }) async {
    if (firmware.operationInProgress ||
        (isOtherOperationInProgress?.call() ?? false)) {
      throw DfuRecoveryException(DfuPreflightFailure.operationInProgress);
    }
    final warnings = <DfuPreflightWarning>[];
    try {
      warnings.addAll(
        await runDfuPreflight(
          adapterState: bleClient.getAdapterState,
          appForeground: appForeground,
          screenAwake: screenAwake,
          phoneBattery: phoneBattery,
        ),
      );
    } on FirmwareUpdateException catch (error) {
      throw _mapFirmwareFailure(error.code, error.message);
    }
    if (checkDeviceBattery) {
      final battery = await knownDeviceBatteryPercent?.call();
      if (battery == null) {
        // Unreadable (the bootloader exposes no battery): warning, not failure.
        warnings.add(DfuPreflightWarning.deviceBatteryUnknown);
      } else if (battery < minDeviceBatteryPercent) {
        throw DfuRecoveryException(DfuPreflightFailure.deviceBatteryLow);
      }
    }
    final scans = await _scan(force: true);
    final matches =
        scans
            ?.where(
              (scan) =>
                  scan.toPublic().isDfuBootloader &&
                  _sameIdentity(
                    scan.deviceId,
                    scan.canonicalHardwareId,
                    session.deviceId,
                    session.hardwareId,
                  ),
            )
            .toList(growable: false) ??
        const <BleScanResult>[];
    final bootloaders =
        scans?.where((scan) => scan.toPublic().isDfuBootloader).length ?? 0;
    if (matches.length != 1 || bootloaders != 1) {
      throw DfuRecoveryException(DfuPreflightFailure.deviceNotVisible);
    }
    return (bootloader: matches.single, warnings: warnings);
  }

  Future<List<BleScanResult>?> _scan({bool force = false}) async {
    final now = _clock();
    final at = _scanCacheAt;
    if (!force &&
        _scanCache != null &&
        at != null &&
        now.difference(at) < config.observeInterval) {
      return _scanCache;
    }
    try {
      final scans = await bleClient.scan(timeout: scanTimeout);
      _scanCache = scans;
      _scanCacheAt = _clock();
      return scans;
    } catch (_) {
      return null;
    }
  }

  List<DfuPreflightWarning> _warnings = const <DfuPreflightWarning>[];

  Future<_Observation> _observe({bool force = false}) async {
    final raw = await _observeRaw(force: force);
    if (_warnings.isEmpty) return raw;
    return _Observation(raw.status.copyWith(warnings: _warnings), raw.session);
  }

  Future<_Observation> _observeRaw({bool force = false}) async {
    final active = await firmware.getActiveFirmwareUpdate();
    final session =
        active != null && !active.isCompleted && active.nativeTransferEngaged
        ? active
        : null;
    var record = await recordStore.load();
    final now = _clock();

    if (session != null && record.sessionId != session.sessionId) {
      record = DfuRecoveryRecord(
        sessionId: session.sessionId,
        staleLinkDeviceId: record.staleLinkDeviceId,
        staleLinkAt: record.staleLinkAt,
      );
      await recordStore.save(record);
    }
    final dismissed =
        session != null && record.dismissedSessionId == session.sessionId;
    final latched = record.recoveredAt != null && session == null;
    final inProgress =
        _running ||
        firmware.operationInProgress ||
        (isOtherOperationInProgress?.call() ?? false);

    DfuRecoveryEvidence evidence({
      int bootloaderMatches = 0,
      bool stockObserved = false,
      bool staleSuspected = false,
      Duration? silentFor,
    }) => DfuRecoveryEvidence(
      hasInterruptedUpdate: session != null,
      dismissed: dismissed,
      recoveredLatched: latched,
      operationInProgress: inProgress,
      bootloaderMatches: bootloaderMatches,
      stockObserved: stockObserved,
      iosStaleLinkSuspected: staleSuspected,
      cablePrepared: record.cablePreparedAt != null,
      silentFor: silentFor,
      progressFraction: _progress,
      deviceId: session?.deviceId,
    );

    var strategy = E1RecoveryStrategy.cableRecovery;
    DfuRecoveryStatus derive(DfuRecoveryEvidence e) => deriveDfuRecoveryStatus(
      e,
      strategy: strategy,
      silenceWindow: config.silenceWindow,
    );

    if (session == null || dismissed || inProgress) {
      return _Observation(derive(evidence()), session);
    }

    final scans = await _scan(force: force);
    if (scans == null) {
      final silentFor = record.firstMissAt == null
          ? null
          : now.difference(record.firstMissAt!);
      return _Observation(derive(evidence(silentFor: silentFor)), session);
    }

    final matching = scans
        .where(
          (scan) => _sameIdentity(
            scan.deviceId,
            scan.canonicalHardwareId,
            session.deviceId,
            session.hardwareId,
          ),
        )
        .toList(growable: false);
    final bootloaders = scans
        .where((scan) => scan.toPublic().isDfuBootloader)
        .toList(growable: false);
    final matchingBootloaders = matching
        .where((scan) => scan.toPublic().isDfuBootloader)
        .length;
    final bootloaderCount = bootloaders.length > 1
        ? 2
        : (matchingBootloaders == 1 ? 1 : 0);
    final appVisible = matching
        .where(
          (scan) =>
              !scan.toPublic().isDfuBootloader && scan.toPublic().isEixamDevice,
        )
        .toList(growable: false);
    final stockCandidates = matching
        .where(
          (scan) =>
              !scan.toPublic().isDfuBootloader &&
              !scan.toPublic().isEixamDevice &&
              scan.advertisedServiceUuids.any(
                (uuid) =>
                    uuid.trim().toLowerCase() ==
                    MeshtasticBleProtocol.serviceUuid,
              ),
        )
        .toList(growable: false);

    // Silence bookkeeping: the first scan that sees the TAG in no mode starts
    // the window; any sighting clears it (and a cable preparation that did not
    // take).
    if (matching.isEmpty) {
      if (record.firstMissAt == null) {
        record = record.copyWith(firstMissAt: now);
        await recordStore.save(record);
      }
    } else if (record.firstMissAt != null ||
        (record.cablePreparedAt != null && bootloaderCount > 0)) {
      record = record.copyWith(
        clearFirstMiss: true,
        clearCablePrepared: bootloaderCount > 0,
      );
      await recordStore.save(record);
    }

    // Stock firmware again: independent fresh revalidation (hardware model 105,
    // same identity) proves the physical recovery; supersede the stale record.
    var stockObserved = false;
    if (stockCandidates.length == 1 && bootloaderCount == 0) {
      stockObserved = await _verifyStock(stockCandidates.single, session);
      if (stockObserved) {
        try {
          await firmware.supersedeInterruptedFirmwareUpdate(session.sessionId);
          await recordStore.save(const DfuRecoveryRecord());
        } on FirmwareUpdateException {
          // Another owner holds the record; the migration will supersede it.
        }
      }
    }

    // App-mode TAG back: success only through the existing reconnect + version
    // verification.
    if (!stockObserved && appVisible.isNotEmpty && bootloaderCount == 0) {
      final settled = await firmware.reconcileFirmwareUpdate();
      if (settled != null && settled.state == FirmwareUpdateState.completed) {
        await recordStore.save(DfuRecoveryRecord(recoveredAt: now));
        return _Observation(
          deriveDfuRecoveryStatus(
            const DfuRecoveryEvidence(recoveredLatched: true),
            strategy: strategy,
            silenceWindow: config.silenceWindow,
          ).copyWith(deviceId: session.deviceId),
          null,
        );
      }
    }

    final staleSuspected =
        _isIosPlatform() &&
        record.staleLinkDeviceId != null &&
        appVisible.isNotEmpty;
    final silentFor = record.firstMissAt == null
        ? null
        : now.difference(record.firstMissAt!);
    if (bootloaderCount == 1) {
      strategy = await _strategyFor(
        session,
        matching.firstWhere((scan) => scan.toPublic().isDfuBootloader),
      );
    }
    final built = evidence(
      bootloaderMatches: bootloaderCount,
      stockObserved: stockObserved,
      staleSuspected: staleSuspected,
      silentFor: silentFor,
    );
    final status = derive(built);
    if (status.state == DfuRecoveryState.silentNeedsCable) {
      await firmware.requirePhysicalRecovery();
    }
    return _Observation(status, stockObserved ? null : session);
  }

  Future<E1RecoveryStrategy> _strategyFor(
    FirmwareUpdateSession session,
    BleScanResult bootloader,
  ) async {
    final cached = _strategyBySession[session.sessionId];
    if (cached != null) return cached;
    var strategy = E1RecoveryStrategy.cableRecovery;
    final reader = bootloaderVersionReader;
    if (restartCapableBootloaders.isNotEmpty && reader != null) {
      try {
        strategy = resolveE1RecoveryStrategy(
          await reader(bootloader.deviceId),
          restartCapable: restartCapableBootloaders,
        );
      } catch (_) {
        // Unknown bootloader: same as 0.4.3.
      }
    }
    return _strategyBySession[session.sessionId] = strategy;
  }

  Future<bool> _verifyStock(
    BleScanResult scan,
    FirmwareUpdateSession session,
  ) async {
    try {
      final candidate = await inspectStock(scan.deviceId, scan.name);
      if (!candidate.isCompatible ||
          candidate.sourceHardwareModel !=
              DeviceMigrationCoordinator.wisMeshTagHardwareModel) {
        return false;
      }
      return _sameIdentity(
        candidate.deviceId,
        candidate.stableIdentity,
        session.deviceId,
        session.hardwareId,
      );
    } catch (_) {
      return false;
    }
  }

  bool _sameIdentity(
    String firstDeviceId,
    String? firstHardwareId,
    String secondDeviceId,
    String? secondHardwareId,
  ) {
    final first = normalizeCanonicalHardwareId(firstHardwareId);
    final second = normalizeCanonicalHardwareId(secondHardwareId);
    if (first != null && second != null) return first == second;
    return firstDeviceId == secondDeviceId;
  }
}

class _Observation {
  const _Observation(this.status, this.session);

  final DfuRecoveryStatus status;
  final FirmwareUpdateSession? session;
}
