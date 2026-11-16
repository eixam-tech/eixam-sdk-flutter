import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_client.dart';
import '../device/ble_debug_registry.dart';
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
  StreamSubscription<FirmwareUpdateSession>? _completionSub;
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
    _completionSub ??= firmware.watchFirmwareUpdate().listen(
      (session) => unawaited(_noteFirmwareSession(session)),
      onError: (Object _, StackTrace _) {},
    );
  }

  void _stopWatching() {
    _timer?.cancel();
    _timer = null;
    unawaited(_completionSub?.cancel());
    _completionSub = null;
  }

  /// A session reached a terminal state: re-derive the status at once
  /// instead of on the next tick, so a finished update never keeps a stale
  /// status and a failed one is classified right away.
  ///
  /// A verified install (state completed = reconnect + installed version
  /// verified) on the TAG whose update was interrupted turns into the
  /// `recovered` ("Ready") state: after a cable recovery the interrupted
  /// session is superseded and the stock -> EIXAM migration installs and
  /// verifies the firmware in a new session. A verified install on a TAG
  /// with no recorded interruption clears that TAG's recovery bookkeeping.
  Future<void> _noteFirmwareSession(FirmwareUpdateSession session) async {
    if (session.completedAt == null && !session.isCompleted) return;
    try {
      if (session.isCompleted) await _noteVerifiedInstall(session);
    } catch (_) {
      // Best-effort: the TAG works; only the success card is missed.
    }
    // A recovery action publishes its own final status; refreshing between
    // its DFU and its confirmation would flash an intermediate state.
    if (_actionLock) return;
    // No forced scan: the scan cache ages out within one observe interval,
    // and a completed update needs none (it no longer has a session).
    await _refreshAndEmit();
  }

  Future<void> _noteVerifiedInstall(FirmwareUpdateSession session) async {
    final record = await recordStore.load();
    final deviceId = record.deviceId;
    final sameTag =
        deviceId == null ||
        _sameIdentity(
          session.deviceId,
          session.hardwareId,
          deviceId,
          record.hardwareId,
        );
    if (!sameTag || record.recoveredAt != null) return;
    if (record.interruptedAt != null && deviceId != null) {
      await recordStore.save(
        DfuRecoveryRecord(
          recoveredAt: _clock(),
          deviceId: deviceId,
          hardwareId: record.hardwareId,
        ),
      );
      return;
    }
    if (record.sessionId != null ||
        record.deviceId != null ||
        record.firstMissAt != null ||
        record.cablePreparedAt != null) {
      await recordStore.save(
        DfuRecoveryRecord(
          staleLinkDeviceId: record.staleLinkDeviceId,
          staleLinkAt: record.staleLinkAt,
        ),
      );
    }
  }

  bool _refreshQueued = false;

  Future<void> _refreshAndEmit() async {
    if (_refreshing) {
      // The running refresh may have read the state before this change.
      _refreshQueued = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshQueued = false;
        try {
          await getDfuRecoveryStatus();
        } catch (_) {
          // Observation is best-effort; the next tick retries.
        }
      } while (_refreshQueued);
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
    // No identifiers: state, reason and offered actions only (F19 forensics).
    safeSdkDebugPrint(
      'DFU_RECOVERY_STATUS state=${status.state.name} '
      'reason=${status.reason.name} '
      'action=${status.availableAction.name} '
      'forward=${status.forwardActions.map((a) => a.name).join(',')} '
      'progress=${status.progressFraction != null} '
      'device=${status.deviceId != null}',
    );
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

  /// "Not now" hides the recovery card for this app run only. A persisted
  /// dismissal hid every later interruption of the same session id (a retry
  /// reuses it), even with the TAG waiting as AdaDFU and SOS unavailable: the
  /// 2026-11-06 iPhone dead end (F19). After a relaunch the card is back.
  String? _dismissedSessionThisRun;

  @override
  Future<DfuRecoveryStatus> dismissDfuRecovery() async {
    if (_actionLock || _running) {
      throw DfuRecoveryException(DfuPreflightFailure.operationInProgress);
    }
    _warnings = const <DfuPreflightWarning>[];
    final observation = await _observe();
    final record = await recordStore.load();
    _dismissedSessionThisRun = observation.session?.sessionId;
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
      // F7 still holds: the action needs the TAG observed as AdaDFU. Any
      // scan's sighting within one observe interval counts (the card's offer
      // has the same freshness); a fresh scan is only the fallback, retried
      // within that same horizon before refusing (F13).
      var observation = await _observe(sightingsOnly: true);
      final scans = scanTimeout <= Duration.zero
          ? 1
          : (config.observeInterval.inMicroseconds / scanTimeout.inMicroseconds)
                .ceil();
      for (
        var attempt = 0;
        attempt < scans &&
            observation.session != null &&
            observation.status.availableAction != action &&
            (observation.status.reason == DfuRecoveryReason.awaitingEvidence ||
                observation.status.reason == DfuRecoveryReason.deviceSilent);
        attempt++
      ) {
        observation = await _observe(force: true);
      }
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
      _sightingFloor = _clock();
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
    final scans = await _scan(force: true, sightingWindow: Duration.zero);
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
    List<BleScanResult> bootloaderMatches(List<BleScanResult>? scans) =>
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
    var scans = await _scan(sightingsOnly: true);
    if (bootloaderMatches(scans).length != 1) {
      scans = await _scan(force: true);
    }
    final matches = bootloaderMatches(scans);
    final bootloaders =
        scans?.where((scan) => scan.toPublic().isDfuBootloader).length ?? 0;
    if (matches.length != 1 || bootloaders != 1) {
      throw DfuRecoveryException(DfuPreflightFailure.deviceNotVisible);
    }
    return (bootloader: matches.single, warnings: warnings);
  }

  /// Adverts received before this instant never count (set when a recovery
  /// DFU starts: the TAG may have left the bootloader since).
  DateTime? _sightingFloor;

  /// Latest advert per device that ANY scan of the client received (watcher,
  /// discovery, our own) within one observe interval, the same freshness the
  /// card's offer has (F13). Empty when the client cannot tell.
  List<BleScanResult> _sightings(DateTime since) {
    final client = bleClient;
    if (client is! BleAdvertisementSightingSource) {
      return const <BleScanResult>[];
    }
    final floor = _sightingFloor;
    final from = floor != null && floor.isAfter(since) ? floor : since;
    return (client as BleAdvertisementSightingSource).advertisementsSince(from);
  }

  /// [sightingsOnly]: no native scan; recent bootloader sightings, or null
  /// (no evidence) so the caller falls back to a fresh scan.
  /// [sightingWindow]: how far before our scan a sighting may be.
  Future<List<BleScanResult>?> _scan({
    bool force = false,
    bool sightingsOnly = false,
    Duration? sightingWindow,
  }) async {
    final now = _clock();
    if (sightingsOnly) {
      final recent = _sightings(now.subtract(config.observeInterval));
      return recent.any((scan) => scan.toPublic().isDfuBootloader)
          ? recent
          : null;
    }
    final at = _scanCacheAt;
    if (!force &&
        _scanCache != null &&
        at != null &&
        now.difference(at) < config.observeInterval) {
      return _scanCache;
    }
    try {
      // A newer scan by another subsystem supersedes ours and makes it return
      // nothing, although the phone kept receiving adverts (F13).
      final own = await bleClient.scan(timeout: scanTimeout);
      final ids = own.map((scan) => scan.deviceId).toSet();
      final scans = <BleScanResult>[
        ...own,
        ..._sightings(
          now.subtract(sightingWindow ?? config.observeInterval),
        ).where((scan) => !ids.contains(scan.deviceId)),
      ];
      _scanCache = scans;
      _scanCacheAt = _clock();
      return scans;
    } catch (_) {
      return null;
    }
  }

  List<DfuPreflightWarning> _warnings = const <DfuPreflightWarning>[];

  Future<_Observation> _observe({
    bool force = false,
    bool sightingsOnly = false,
  }) async {
    final raw = await _observeRaw(force: force, sightingsOnly: sightingsOnly);
    if (_warnings.isEmpty) return raw;
    return _Observation(raw.status.copyWith(warnings: _warnings), raw.session);
  }

  Future<_Observation> _observeRaw({
    bool force = false,
    bool sightingsOnly = false,
  }) async {
    final active = await firmware.getActiveFirmwareUpdate();
    // A verified version mismatch is a running TAG, not an interrupted update:
    // the firmware card owns it (retry / contact support), no recovery card.
    // The session an update in this process is transferring right now is
    // live, not interrupted, even while the TAG sits in its bootloader (F1).
    final session =
        active != null &&
            !active.isCompleted &&
            active.nativeTransferEngaged &&
            !active.isInstalledVersionMismatch &&
            active.sessionId != firmware.liveUpdateSessionId
        ? active
        : null;
    var record = await recordStore.load();
    final now = _clock();

    if (session != null && record.sessionId != session.sessionId) {
      // A new session on the same TAG (for example the migration after a
      // cable recovery) keeps the interruption marker.
      final previousDeviceId = record.deviceId;
      final sameTag =
          record.interruptedAt != null &&
          previousDeviceId != null &&
          _sameIdentity(
            session.deviceId,
            session.hardwareId,
            previousDeviceId,
            record.hardwareId,
          );
      record = DfuRecoveryRecord(
        sessionId: session.sessionId,
        staleLinkDeviceId: record.staleLinkDeviceId,
        staleLinkAt: record.staleLinkAt,
        deviceId: session.deviceId,
        hardwareId: session.hardwareId,
        interruptedAt: sameTag ? record.interruptedAt : null,
      );
      await recordStore.save(record);
    } else if (session != null && record.deviceId == null) {
      record = record.copyWith(
        deviceId: session.deviceId,
        hardwareId: session.hardwareId,
      );
      await recordStore.save(record);
    }
    final dismissed =
        session != null && _dismissedSessionThisRun == session.sessionId;
    final latched = record.recoveredAt != null && session == null;
    // An update that already ended only holds the lock to persist its result.
    final inProgress =
        _running ||
        (firmware.operationInProgress && !firmware.liveUpdateEnded) ||
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
      if (session != null && inProgress) {
        safeSdkDebugPrint(
          'DFU_RECOVERY_IN_PROGRESS own=$_running '
          'firmware=${firmware.operationInProgress} '
          'other=${isOtherOperationInProgress?.call() ?? false}',
        );
      }
      return _Observation(derive(evidence()), session);
    }

    // The TAG runs its EIXAM application again and the connected TAG reported
    // its old version (for example the cut came before the erase, or the
    // deliberate reset booted the intact old application). Nothing to
    // recover: no recovery card, ever. An older version shows the normal
    // update card. A connected TAG stops advertising, so this must not wait
    // for an advert: silence never counts for it (no E2, F15/M2).
    Future<_Observation> clearHealthyTag() async {
      try {
        await firmware.supersedeInterruptedFirmwareUpdate(session.sessionId);
      } on FirmwareUpdateException {
        // Another owner holds the record; it is not interrupted anyway.
      }
      await recordStore.save(const DfuRecoveryRecord());
      _strategyBySession.remove(session.sessionId);
      return _Observation(
        derive(
          const DfuRecoveryEvidence(),
        ).copyWith(deviceId: session.deviceId),
        null,
      );
    }

    if (_oldApplicationRead(session)) return clearHealthyTag();

    // The user finished (or is finishing) a cable recovery: the EIXAM firmware
    // UF2 puts a complete EIXAM application on the TAG, so a TAG that comes
    // back running EIXAM firmware ENDS the interruption. Whatever application
    // version it reports is the recovered one: it is never a "version
    // mismatch" and never an offer to update (an older version only shows the
    // normal, non-blocking update card later).
    final physicalRecovery =
        record.cablePreparedAt != null ||
        session.state == FirmwareUpdateState.physicalRecoveryRequired ||
        session.manualRecoveryRequired;

    Future<bool> supersedeAfterCable() async {
      try {
        await firmware.supersedeInterruptedFirmwareUpdate(session.sessionId);
        _strategyBySession.remove(session.sessionId);
        return true;
      } on FirmwareUpdateException {
        // Another owner holds the record; the next observation retries.
        return false;
      }
    }

    if (physicalRecovery) {
      // A connected TAG stops advertising, so read it instead of waiting for an
      // advert. Reading never starts a transfer.
      final read = await firmware.readConnectedApplicationVersion();
      if (read != null) {
        if (read.isOldApplication) return clearHealthyTag();
        if (await supersedeAfterCable()) {
          await recordStore.save(
            DfuRecoveryRecord(
              recoveredAt: now,
              deviceId: session.deviceId,
              hardwareId: session.hardwareId,
            ),
          );
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
    }

    final scans = await _scan(force: force, sightingsOnly: sightingsOnly);
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
          // Keep who was recovered: the migration's verified install on this
          // TAG is reported as `recovered` (see _noteFirmwareSession).
          await recordStore.save(
            DfuRecoveryRecord(
              deviceId: session.deviceId,
              hardwareId: session.hardwareId,
              interruptedAt: record.interruptedAt ?? now,
            ),
          );
        } on FirmwareUpdateException {
          // Another owner holds the record; the migration will supersede it.
        }
      }
    }

    // EIXAM application advertising again after a cable recovery: the physical
    // part is over. Clear the interruption (no verification is claimed: the TAG
    // is not connected yet); pairing / provisioning / the normal version check
    // continue in the regular device flows, and a recovered-but-older version
    // only ever shows the normal update card.
    var appObservedAfterCable = false;
    if (physicalRecovery &&
        !stockObserved &&
        appVisible.isNotEmpty &&
        bootloaderCount == 0 &&
        await supersedeAfterCable()) {
      appObservedAfterCable = true;
      await recordStore.save(const DfuRecoveryRecord());
    }

    // App-mode TAG back: success only through the existing reconnect + version
    // verification.
    if (!stockObserved &&
        !appObservedAfterCable &&
        appVisible.isNotEmpty &&
        bootloaderCount == 0) {
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
      if (settled != null && settled.sessionId == session.sessionId) {
        if (_oldApplicationRead(settled)) return clearHealthyTag();
        if (settled.isInstalledVersionMismatch) {
          // A verified app-version mismatch stays with the firmware card
          // (terminal, retry / contact support); no recovery card.
          await recordStore.save(const DfuRecoveryRecord());
          _strategyBySession.remove(session.sessionId);
          return _Observation(
            derive(
              const DfuRecoveryEvidence(),
            ).copyWith(deviceId: session.deviceId),
            null,
          );
        }
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
      stockObserved: stockObserved || appObservedAfterCable,
      staleSuspected: staleSuspected,
      silentFor: silentFor,
    );
    final status = derive(built);
    if (record.interruptedAt == null &&
        (status.state == DfuRecoveryState.resumable ||
            status.state == DfuRecoveryState.silentNeedsCable ||
            status.state == DfuRecoveryState.iosStaleLink)) {
      await recordStore.save(record.copyWith(interruptedAt: now));
    }
    if (status.state == DfuRecoveryState.silentNeedsCable) {
      await firmware.requirePhysicalRecovery();
    }
    return _Observation(
      status,
      stockObserved || appObservedAfterCable ? null : session,
    );
  }

  /// The last reconciliation read the OLD application version from the
  /// connected TAG (the SDK sets these states only for that read; a restore
  /// rewrites nextAction to waitForDevice, so this is fresh evidence). A
  /// bootloader or unread version is `failed/waitForDevice`, never this.
  static bool _oldApplicationRead(FirmwareUpdateSession session) =>
      session.reconciliationOutcome ==
          FirmwareUpdateReconciliationOutcome.installedVersionMismatch &&
      !session.requiresRecovery &&
      (session.state == FirmwareUpdateState.readyToTransfer ||
          session.state == FirmwareUpdateState.checking) &&
      (session.nextAction == FirmwareUpdateNextAction.retryTransfer ||
          session.nextAction == FirmwareUpdateNextAction.retryDownload);

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
