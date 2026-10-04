import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';

import '../data/datasources_remote/sdk_firmware_remote_data_source.dart';
import '../device/ble_client.dart';
import '../device/ble_debug_registry.dart';
import '../device/canonical_hardware_id.dart';
import '../firmware_version.dart';
import 'firmware_dfu_transport.dart';
import 'firmware_update_session_store.dart';
import 'firmware_artifact_cache.dart';
import 'firmware_update_retry_policy.dart';
import 'device_migration_firmware_service.dart';
export 'device_migration_firmware_service.dart'
    show FirmwareDfuStatusRefreshHook;

typedef ProtectionStatusProvider = Future<ProtectionStatus> Function();
typedef DeviceSosStatusProvider = Future<DeviceSosStatus> Function();
typedef PreSosStatusProvider = Future<PublicPreSosStatus?> Function();
typedef AppLifecycleStateProvider = AppLifecycleState? Function();
typedef FirmwareDfuPreparationHook =
    Future<DeviceStatus> Function({required String deviceId});
typedef FirmwareDfuConnectionHook =
    Future<void> Function({required String deviceId});

class FirmwareUpdateCoordinator implements DeviceMigrationFirmwareService {
  FirmwareUpdateCoordinator({
    required this.deviceRepository,
    required this.sosRepository,
    required this.deathManRepository,
    required this.remoteDataSource,
    required this.dfuTransport,
    this.bleClient,
    this.firmwareStatusRefresh,
    FirmwareUpdateSessionStore? sessionStore,
    FirmwareArtifactCache? artifactCache,
    this.protectionStatusProvider,
    this.deviceSosStatusProvider,
    this.preSosStatusProvider,
    this.appLifecycleStateProvider,
    this.prepareForDfuTransfer,
    this.releaseBleForDfuTransfer,
    this.restoreBleAfterDfuTransfer,
    this.postDfuStatusRefresh,
    this.physicalRecoveryEvidenceProvider,
    Duration dfuStallTimeout = _defaultDfuStallTimeout,
    Duration dfuFirstUploadDeadline = _defaultDfuFirstUploadDeadline,
    Duration postDfuVerificationTimeout = _defaultPostDfuVerificationTimeout,
    Duration postDfuVerificationPollInterval =
        _defaultPostDfuVerificationPollInterval,
  }) : artifactCache = artifactCache ?? FileFirmwareArtifactCache(),
       sessionStore = sessionStore ?? SharedPrefsFirmwareUpdateSessionStore(),
       _dfuStallTimeout = dfuStallTimeout,
       _dfuFirstUploadDeadline = dfuFirstUploadDeadline,
       _postDfuVerificationTimeout = postDfuVerificationTimeout,
       _postDfuVerificationPollInterval = postDfuVerificationPollInterval;

  final DeviceRepository deviceRepository;
  final SosRepository sosRepository;
  final DeathManRepository deathManRepository;
  final SdkFirmwareRemoteDataSource remoteDataSource;
  final FirmwareDfuTransport dfuTransport;
  final BleClient? bleClient;
  final Future<DeviceStatus> Function()? firmwareStatusRefresh;

  Future<DeviceStatus> _refreshFirmwareStatus() =>
      firmwareStatusRefresh?.call() ?? deviceRepository.refreshDeviceStatus();
  final FirmwareUpdateSessionStore sessionStore;
  final FirmwareArtifactCache artifactCache;
  bool _operationInProgress = false;
  bool _disposed = false;
  Future<FirmwareUpdateSession?>? _reconciliationFuture;
  final Set<String> _restoredSessions = {};
  final ProtectionStatusProvider? protectionStatusProvider;
  final DeviceSosStatusProvider? deviceSosStatusProvider;
  final PreSosStatusProvider? preSosStatusProvider;
  final AppLifecycleStateProvider? appLifecycleStateProvider;
  final FirmwareDfuPreparationHook? prepareForDfuTransfer;
  final FirmwareDfuConnectionHook? releaseBleForDfuTransfer;
  final FirmwareDfuConnectionHook? restoreBleAfterDfuTransfer;
  final FirmwareDfuStatusRefreshHook? postDfuStatusRefresh;

  /// SDK platform evidence only; never a host timeout or user-facing retry
  /// policy. Mobile BLE implementations may have no evidence while absent.
  final Future<FirmwarePhysicalRecoveryEvidence?> Function()?
  physicalRecoveryEvidenceProvider;

  static const Duration _defaultPostDfuVerificationTimeout = Duration(
    seconds: 180,
  );
  static const Duration _defaultPostDfuVerificationPollInterval = Duration(
    seconds: 5,
  );

  // Each native operation also has the platform's finite reconnect policy.
  // Limits survive process death; a scan alone never establishes failure.
  static const int maxRemoteRecoveryAttempts = 3;
  static const int maxRecoveryReconciliations = 3;

  static const Duration _defaultDfuStallTimeout = Duration(seconds: 90);
  static const Duration _defaultDfuFirstUploadDeadline = Duration(seconds: 180);

  /// Max time to wait for the device to reboot into the new image and report a
  /// matching firmware version after the transfer completes.
  final Duration _postDfuVerificationTimeout;

  /// Delay between post-DFU version-verification polls.
  final Duration _postDfuVerificationPollInterval;

  /// Max time the DFU may run without any *upload* progress once the upload
  /// has started. Re-armed only by events that carry a progress percentage —
  /// the native reconnect-retry loop emits a steady stream of connecting /
  /// disconnected state events that must NOT keep the watchdog alive, or a
  /// device stranded in the bootloader pins the UI at 0% until the native
  /// terminal timeout.
  final Duration _dfuStallTimeout;

  /// Max time between starting the native DFU and the first upload-progress
  /// event (enter-DFU write, device reboot into the bootloader, bootloader
  /// reconnect, init packet — plus a possible first-time bonding dialog). If no
  /// byte is uploaded within this window the device likely entered the
  /// bootloader but could not be reconnected → fail fast into recovery.
  final Duration _dfuFirstUploadDeadline;

  final StreamController<FirmwareUpdateProgress> _progressController =
      StreamController<FirmwareUpdateProgress>.broadcast();
  final Map<String, FirmwareUpdateSession> _sessions =
      <String, FirmwareUpdateSession>{};
  final StreamController<FirmwareUpdateSession> _sessionController =
      StreamController<FirmwareUpdateSession>.broadcast();
  Future<void>? _restoreFuture;
  Future<void> _persistTail = Future<void>.value();
  FirmwareUpdateSession? _activeSession;
  FirmwareUpdateCheck? _lastCheck;

  /// Whether an update or recovery session is still running (not terminal).
  /// Other reboot-causing flows (e.g. the LoRa region provisioning) must hold
  /// off while this is true — a reboot during transfer or post-DFU
  /// verification breaks the update.
  bool get hasActiveSession =>
      _sessions.values.any((session) => session.completedAt == null);

  Future<FirmwareUpdateSession?> getActiveFirmwareUpdate() async {
    await _restore();
    return _activeSession?.isCompleted == true ? null : _activeSession;
  }

  @override
  Future<FirmwareUpdateSession?> getActiveMigrationFirmwareUpdate() {
    return getActiveFirmwareUpdate();
  }

  Stream<FirmwareUpdateSession> watchFirmwareUpdate() async* {
    await _restore();
    final current = _activeSession;
    if (current != null && !current.isCompleted) yield current;
    yield* _sessionController.stream;
  }

  Future<DeviceFirmwareInfo> getFirmwareInfo({String? deviceId}) async {
    final status = await _refreshFirmwareStatus();
    return _firmwareInfoFromStatus(status);
  }

  Future<List<FirmwareRelease>> listFirmwareReleases({String? deviceId}) async {
    final status = await _refreshFirmwareStatus();
    if (!_matchesRequestedDevice(status, deviceId)) {
      return const <FirmwareRelease>[];
    }
    final response = await remoteDataSource.listReleases(
      hardwareModel: status.model,
    );
    return <FirmwareRelease>[
      for (final release in response.firmwareVersions)
        if (release.id.isNotEmpty && release.version.isNotEmpty)
          release.toDomain(),
    ];
  }

  Future<FirmwareUpdateCheck> checkFirmwareUpdate({
    String? deviceId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) async {
    // A BLE status read can hang if the device is unreachable or stuck in the
    // bootloader; bound it and fall back to the last known status so the check
    // never blocks the UI on "checking firmware" forever.
    DeviceStatus status;
    try {
      status = await _refreshFirmwareStatus().timeout(
        const Duration(seconds: 12),
      );
    } on TimeoutException {
      if (firmwareStatusRefresh != null) {
        throw const FirmwareUpdateException(
          'firmwareStatusUnavailable',
          'The installed firmware could not be inspected.',
        );
      }
      _debugLog(
        'OTA_COORDINATOR check_refresh_timeout '
        'deviceId=${deviceId ?? "unknown"} fallback=cached_status',
      );
      status = await deviceRepository.getDeviceStatus();
    }
    final device = _firmwareInfoFromStatus(status);
    final eligibility = await evaluateEligibility(
      status: status,
      release: null,
      policy: policy,
    );
    if (!_matchesRequestedDevice(status, deviceId)) {
      return _rememberCheck(
        FirmwareUpdateCheck(
          device: device,
          updateAvailable: false,
          eligibility: _withBlocker(
            eligibility,
            FirmwareUpdateBlocker.noConnectedDevice,
            'Requested device is not the connected BLE device.',
          ),
          checkedAt: DateTime.now(),
        ),
      );
    }
    if (eligibility.blockers.contains(
      FirmwareUpdateBlocker.unknownFirmwareVersion,
    )) {
      return _rememberCheck(
        FirmwareUpdateCheck(
          device: device,
          updateAvailable: false,
          eligibility: eligibility,
          checkedAt: DateTime.now(),
        ),
      );
    }

    final response = await remoteDataSource.checkUpdate(
      hardwareModel: device.hardwareModel,
      currentVersion: _backendComparableFirmwareVersion(device.currentVersion!),
      allowDowngrade: policy.allowDowngrade,
      targetReleaseId: policy.targetReleaseId,
    );
    final release = response.firmware?.toDomain();
    var actionableRelease =
        response.updateAvailable &&
            release != null &&
            _firmwareReleaseIsActionable(
              currentVersion: device.currentVersion!,
              targetVersion: release.version,
              allowDowngrade: policy.allowDowngrade,
              explicitTarget: policy.targetReleaseId != null,
            )
        ? release
        : null;
    if (actionableRelease == null && policy.targetReleaseId == null) {
      actionableRelease = await _newestActionableCatalogRelease(
        currentVersion: device.currentVersion!,
        policy: policy,
        hardwareModel: device.hardwareModel,
      );
    }
    final releaseEligibility = await evaluateEligibility(
      status: status,
      release: actionableRelease,
      policy: policy,
    );
    return _rememberCheck(
      FirmwareUpdateCheck(
        device: device,
        updateAvailable: actionableRelease != null,
        release: actionableRelease,
        eligibility: releaseEligibility,
        checkedAt: DateTime.now(),
      ),
    );
  }

  Future<FirmwareUpdateSession> startFirmwareUpdate({
    required String deviceId,
    required String releaseId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) => _exclusive(
    () => _startFirmwareUpdate(
      deviceId: deviceId,
      releaseId: releaseId,
      policy: policy,
    ),
  );

  Future<FirmwareUpdateSession> _startFirmwareUpdate({
    required String deviceId,
    required String releaseId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) async {
    await _restore();
    final initialStatus = await deviceRepository.getDeviceStatus();
    final intentTime = DateTime.now();
    var intent = FirmwareUpdateSession(
      sessionId: _newSessionId(intentTime),
      deviceId: deviceId,
      hardwareId: initialStatus.deviceId == deviceId
          ? initialStatus.canonicalHardwareId
          : null,
      releaseId: releaseId,
      fromVersion: initialStatus.firmwareVersion ?? '',
      targetVersion: '',
      state: FirmwareUpdateState.checking,
      startedAt: intentTime,
      nextAction: FirmwareUpdateNextAction.retryDownload,
    );
    _ensureMayStart(intent);
    final priorIntent = _activeSession;
    if (priorIntent != null && priorIntent.releaseId == releaseId) {
      intent = priorIntent.copyWith(
        state: FirmwareUpdateState.checking,
        clearCompletedAt: true,
        nativeTransferEngaged: false,
        requiresRecovery: false,
        nextAction: FirmwareUpdateNextAction.retryDownload,
      );
    }
    _sessions[intent.sessionId] = intent;
    await _persist(intent);
    var check = await _resolveUsableCheck(
      deviceId: deviceId,
      releaseId: releaseId,
      policy: policy,
    );
    var release = check.release;
    if ((!check.eligibility.eligible || release == null) &&
        release != null &&
        _canAttemptDfuPreparation(check)) {
      final preparedStatus = await prepareForDfuTransfer!(
        deviceId: check.device.deviceId,
      );
      check = await _resolveUsableCheck(
        deviceId: preparedStatus.deviceId,
        releaseId: releaseId,
        policy: policy,
        forceRefresh: true,
      );
      release = check.release;
    }
    final now = DateTime.now();
    var session = FirmwareUpdateSession(
      sessionId: intent.sessionId,
      deviceId: check.device.deviceId,
      releaseId: releaseId,
      fromVersion: check.device.currentVersion ?? '',
      targetVersion: release?.version ?? '',
      state: FirmwareUpdateState.idle,
      startedAt: now,
      hardwareId: check.device.hardwareId,
      updatedAt: now,
      nextAction: FirmwareUpdateNextAction.retry,
    );
    _ensureMayStart(session);
    final previous = _activeSession;
    if (previous != null &&
        previous.releaseId == session.releaseId &&
        previous.targetVersion == session.targetVersion &&
        _sameIdentity(
          previous.deviceId,
          previous.hardwareId,
          session.deviceId,
          session.hardwareId,
        )) {
      session = previous.copyWith(
        state: FirmwareUpdateState.idle,
        clearCompletedAt: true,
        nativeTransferEngaged: false,
        requiresRecovery: false,
        recoveryDeviceMatched: false,
        remoteRecoveryAttempts: 0,
        remoteRecoveryFailed: false,
        recoveryReconciliationAttempts: 0,
        remoteRecoveryExhausted: false,
      );
    }
    _restoredSessions.remove(session.sessionId);
    _sessions[session.sessionId] = session;
    await _persist(session);

    if (!check.eligibility.eligible || release == null) {
      final blocked = _completeSession(
        session,
        state: FirmwareUpdateState.blocked,
        failureCode: 'firmwareUpdateBlocked',
        failureMessage: check.eligibility.blockers
            .map((blocker) => blocker.name)
            .join(','),
      );
      await _persistTail;
      return blocked;
    }

    final result = await _startVerifiedReleaseTransfer(
      session: session,
      release: release,
    );
    await _persistTail;
    return result;
  }

  /// Resolves an active, model-specific catalog artifact for a stock-firmware
  /// migration. Universal artifacts are deliberately excluded: migration is
  /// allowed only when the backend explicitly publishes this hardware model.
  @override
  Future<FirmwareRelease?> resolveMigrationRelease({
    required String hardwareModel,
  }) async {
    final expected = hardwareModel.trim();
    if (expected.isEmpty) return null;
    final response = await remoteDataSource.listReleases(
      hardwareModel: expected,
    );
    FirmwareRelease? newest;
    for (final dto in response.firmwareVersions) {
      if (dto.id.isEmpty || dto.version.isEmpty || dto.isActive == false) {
        continue;
      }
      if (dto.hardwareModel?.trim().toLowerCase() != expected.toLowerCase()) {
        continue;
      }
      final release = dto.toDomain();
      if (release.sha256Hash == null || release.sha256Hash!.isEmpty) continue;
      try {
        validateFirmwareArtifactMetadataSize(release.fileSizeBytes);
      } on FirmwareUpdateException {
        continue;
      }
      if (newest == null) {
        newest = release;
        continue;
      }
      final comparison = compareEixamFirmwareVersions(
        newest.version,
        release.version,
      );
      if (comparison != null && comparison < 0) newest = release;
    }
    return newest;
  }

  /// Runs a stock-firmware migration through the same artifact validation,
  /// native DFU, watchdog, recovery and installed-version state machine used
  /// by ordinary Eixam OTA.
  @override
  Future<FirmwareUpdateSession> startMigrationFirmwareUpdate({
    required DeviceStatus sourceStatus,
    required FirmwareRelease release,
    required FirmwareDfuStatusRefreshHook postMigrationStatusRefresh,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) => _exclusive(
    () => _startMigrationFirmwareUpdate(
      sourceStatus: sourceStatus,
      release: release,
      postMigrationStatusRefresh: postMigrationStatusRefresh,
      policy: policy,
    ),
  );

  Future<FirmwareUpdateSession> _startMigrationFirmwareUpdate({
    required DeviceStatus sourceStatus,
    required FirmwareRelease release,
    required FirmwareDfuStatusRefreshHook postMigrationStatusRefresh,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) async {
    await _restore();
    final eligibility = await evaluateEligibility(
      status: sourceStatus,
      release: release,
      policy: policy,
    );
    final now = DateTime.now();
    var session = FirmwareUpdateSession(
      sessionId: _newSessionId(now),
      deviceId: sourceStatus.deviceId,
      releaseId: release.releaseId,
      fromVersion: sourceStatus.firmwareVersion ?? '',
      targetVersion: release.version,
      migrationOwned: true,
      state: FirmwareUpdateState.idle,
      startedAt: now,
      hardwareId: sourceStatus.canonicalHardwareId,
      updatedAt: now,
      nextAction: FirmwareUpdateNextAction.retry,
    );
    _ensureMayStart(session, verifiedMigrationSource: true);
    final previous = _activeSession;
    if (previous != null &&
        previous.releaseId == session.releaseId &&
        previous.targetVersion == session.targetVersion &&
        _sameIdentity(
          previous.deviceId,
          previous.hardwareId,
          session.deviceId,
          session.hardwareId,
        )) {
      session = previous.copyWith(
        state: FirmwareUpdateState.idle,
        clearCompletedAt: true,
        nativeTransferEngaged: false,
        requiresRecovery: false,
        recoveryDeviceMatched: false,
        remoteRecoveryAttempts: 0,
        remoteRecoveryFailed: false,
        recoveryReconciliationAttempts: 0,
        remoteRecoveryExhausted: false,
      );
    }
    _restoredSessions.remove(session.sessionId);
    _sessions[session.sessionId] = session;
    await _persist(session);
    if (!eligibility.eligible) {
      final blocked = _completeSession(
        session,
        state: FirmwareUpdateState.blocked,
        failureCode: 'firmwareUpdateBlocked',
        failureMessage: eligibility.blockers
            .map((blocker) => blocker.name)
            .join(','),
      );
      await _persistTail;
      return blocked;
    }
    final result = await _startVerifiedReleaseTransfer(
      session: session,
      release: release,
      statusRefresh: postMigrationStatusRefresh,
    );
    await _persistTail;
    return result;
  }

  Future<FirmwareUpdateSession> _startVerifiedReleaseTransfer({
    required FirmwareUpdateSession session,
    required FirmwareRelease release,
    FirmwareDfuStatusRefreshHook? statusRefresh,
  }) async {
    final releaseId = release.releaseId;

    // Set as soon as the native DFU emits any event; a failure before that
    // cannot have stranded the device in the bootloader, so it must NOT be
    // routed to recovery. Read by _completeTransferFailure on the error paths.
    var nativeDfuEngaged = false;
    try {
      final artifactBytes = await _prepareArtifact(session, release);

      _emit(session, FirmwareUpdateState.readyToTransfer);
      _emit(session, FirmwareUpdateState.transferring);
      _debugLog(
        'OTA_COORDINATOR native_dfu_start '
        'sessionId=${session.sessionId} deviceId=${session.deviceId} '
        'release=$releaseId target=${release.version}',
      );
      await _runNativeDfuWithWatchdog(
        session: session,
        request: FirmwareDfuTransferRequest(
          sessionId: session.sessionId,
          deviceId: session.deviceId,
          release: release,
          artifactBytes: artifactBytes,
        ),
        stallMessage:
            'The firmware transfer made no upload progress for '
            '${_dfuStallTimeout.inSeconds}s.',
        firstUploadMessage:
            'The firmware upload never started (the device may have entered '
            'the bootloader but could not be reconnected).',
        onEngaged: () {
          nativeDfuEngaged = true;
          _markNativeTransferEngaged(session);
        },
      );

      _emit(session, FirmwareUpdateState.reconnecting);
      final verification = await _waitForInstalledVersion(
        session: session,
        targetVersion: release.version,
        statusRefresh: statusRefresh,
      );
      if (!verification.matchesTarget) {
        final requiresRecovery = verification.requiresRecovery;
        return _completeSession(
          session,
          state: requiresRecovery
              ? FirmwareUpdateState.recoveryRequired
              : FirmwareUpdateState.failed,
          failureCode: requiresRecovery
              ? 'deviceNotReconnected'
              : 'installedVersionMismatch',
          failureMessage: requiresRecovery
              ? 'Device did not reconnect after DFU completion.'
              : 'Expected ${release.version}, found '
                    '${verification.installedVersion ?? 'unknown'}.',
        );
      }
      return _completeSession(session, state: FirmwareUpdateState.completed);
    } on FirmwareUpdateException catch (error) {
      return _completeTransferFailure(
        session,
        code: error.code,
        message: error.message,
        nativeDfuEngaged: nativeDfuEngaged,
        requiresRecovery: error.requiresRecovery,
      );
    } catch (error) {
      return _completeTransferFailure(
        session,
        code: 'firmwareUpdateFailed',
        message: error.toString(),
        nativeDfuEngaged: nativeDfuEngaged,
      );
    }
  }

  /// Runs [request] through the native DFU transport under two watchdogs,
  /// forwarding progress to [_emit], and returns only when the native transfer
  /// resolves or a watchdog fires (throwing `dfuStalled`). Shared by the normal
  /// update and recovery flows so their stall/first-upload semantics can never
  /// drift apart.
  ///
  /// - The **first-upload deadline** is armed *after* [releaseBleForDfuTransfer]
  ///   so the BLE handoff is not charged against it; it bounds enter-DFU +
  ///   bootloader reconnect + init packet.
  /// - The **stall watchdog** re-arms on any real upload progress and, once the
  ///   upload has started, on every subsequent event — including the
  ///   null-percentage validating/disconnecting tail after 100% — so a slow but
  ///   live finalization is not mistaken for a stall, while the bare
  ///   reconnect-retry churn before the first byte still cannot keep it alive.
  /// - On a watchdog fire the still-pending native transfer is cancelled so it
  ///   does not keep flashing unawaited (and a later recovery is not rejected
  ///   with `alreadyRunning`).
  ///
  /// [onEngaged] fires the first time the native side emits any event, i.e. the
  /// device actually engaged — used to decide recovery-vs-failed routing.
  Future<void> _runNativeDfuWithWatchdog({
    required FirmwareUpdateSession session,
    required FirmwareDfuTransferRequest request,
    required String stallMessage,
    required String firstUploadMessage,
    void Function()? onEngaged,
    Future<void> Function()? beforeNativeStart,
  }) async {
    if (_disposed ||
        _sessions[session.sessionId]?.state == FirmwareUpdateState.cancelled) {
      throw const FirmwareUpdateException(
        'cancelled',
        'Firmware preparation is no longer active.',
      );
    }
    if (dfuTransport is UnsupportedFirmwareDfuTransport) {
      throw const FirmwareUpdateException(
        UnsupportedFirmwareDfuTransport.failureCode,
        'Native firmware transfer is unavailable.',
      );
    }
    final stall = Completer<void>();
    Timer? stallTimer;
    Timer? firstUploadTimer;
    var uploadStarted = false;
    var nativeInvocationStarted = false;
    var nativeCompleted = false;
    void failStalled(String message) {
      if (!stall.isCompleted) {
        stall.completeError(FirmwareUpdateException('dfuStalled', message));
      }
    }

    void armStallWatchdog() {
      stallTimer?.cancel();
      stallTimer = Timer(_dfuStallTimeout, () => failStalled(stallMessage));
    }

    final dfuSub = dfuTransport.watchProgress(request.sessionId).listen((
      progress,
    ) {
      if (_disposed || !nativeInvocationStarted) return;
      onEngaged?.call();
      final isUploadProgress =
          progress.progressPercentage != null ||
          (progress.bytesTransferred ?? 0) > 0;
      if (isUploadProgress) {
        uploadStarted = true;
        firstUploadTimer?.cancel();
        firstUploadTimer = null;
      }
      // Before the first byte, only real upload evidence re-arms the stall
      // watchdog — the bare reconnect-retry churn must not (the first-upload
      // deadline guards that window). After the upload has started, every
      // event (including the null-percentage finalization tail) proves the
      // transfer is still alive and re-arms it.
      if (uploadStarted) {
        armStallWatchdog();
      }
      _emit(
        session,
        progress.state == FirmwareUpdateState.completed
            ? FirmwareUpdateState.reconnecting
            : progress.state,
        progressPercentage: progress.progressPercentage,
        bytesTransferred: progress.bytesTransferred,
        totalBytes: progress.totalBytes,
      );
    });
    try {
      await releaseBleForDfuTransfer?.call(deviceId: request.deviceId);
      if (_disposed ||
          _sessions[session.sessionId]?.state ==
              FirmwareUpdateState.cancelled) {
        throw const FirmwareUpdateException(
          'cancelled',
          'Firmware preparation is no longer active.',
        );
      }
      // Only arm the deadline if the upload hasn't already begun — defensive
      // against any future transport that could emit progress before start().
      if (!uploadStarted) {
        firstUploadTimer = Timer(
          _dfuFirstUploadDeadline,
          () => failStalled(firstUploadMessage),
        );
      }
      // Persist conservative native ownership BEFORE the platform call. A
      // process may die before the first callback reaches Dart.
      onEngaged?.call();
      _markNativeTransferEngaged(session);
      await _persistTail;
      if (_disposed) {
        throw const FirmwareUpdateException(
          'cancelled',
          'Firmware preparation is no longer active.',
        );
      }
      await beforeNativeStart?.call();
      nativeInvocationStarted = true;
      await Future.any(<Future<void>>[
        dfuTransport.start(request),
        stall.future,
      ]);
      nativeCompleted = true;
    } finally {
      stallTimer?.cancel();
      firstUploadTimer?.cancel();
      await dfuSub.cancel();
      // A watchdog fired but the native transfer future is still pending: cancel
      // it so it does not keep flashing behind our back and a subsequent
      // recovery is not rejected with 'alreadyRunning'.
      if (nativeInvocationStarted && !nativeCompleted) {
        // The transport's cancellation future acknowledges native cleanup.
        // Failure to acknowledge must stop recovery, never trigger a retry.
        await dfuTransport.cancel(request.sessionId);
      }
      // Restore is best-effort cleanup: a failure here (e.g. the BLE ownership
      // reclaim throwing) must NOT override the transfer's real outcome — a
      // throw out of this finally would mask a SUCCESSFUL transfer as a failure
      // and route it to recovery. Suppression is already lifted inside the
      // restore hook's own finally, so swallowing here is safe.
      try {
        await restoreBleAfterDfuTransfer?.call(deviceId: request.deviceId);
      } catch (error) {
        _debugLog(
          'OTA_COORDINATOR restore_hook_failed '
          'sessionId=${session.sessionId} error=$error',
        );
      }
    }
  }

  /// Completes a failed transfer, routing to
  /// [FirmwareUpdateState.recoveryRequired] whenever the failure happened after
  /// the transfer began. Past that point the bootloader has already erased the
  /// running app, so the device is stranded in DFU mode and must be re-flashed
  /// regardless of *why* the transfer failed (abort, stall/timeout, or a native
  /// DFU error) — never report a clean "cancelled"/"failed" that hides the fact
  /// the device now needs recovery.
  FirmwareUpdateSession _completeTransferFailure(
    FirmwareUpdateSession session, {
    required String code,
    required String message,
    required bool nativeDfuEngaged,
    bool? requiresRecovery,
  }) {
    final phase = _sessions[session.sessionId]?.state;
    // Prefer the native transport's explicit verdict when it has one. If the
    // device actively responded with an error (`requiresRecovery == false`) it
    // is still alive and NOT stranded — e.g. the bootloader rejected the image
    // at validation ("OPERATION FAILED") and rebooted — so a re-flash would
    // only fail to reconnect; report a plain failure the user can retry. Fall
    // back to the phase heuristic only when the native side gave no verdict
    // (`requiresRecovery == null`), such as a `dfuStalled` first-upload timeout
    // where nothing was ever emitted. Route to recovery only when the device
    // actually entered the bootloader and the running app was erased.
    final stranded =
        requiresRecovery ?? (nativeDfuEngaged && _isPastPointOfNoReturn(phase));
    if (code == 'recoveryRequired' || stranded) {
      return _completeSession(
        session,
        state: FirmwareUpdateState.recoveryRequired,
        failureCode: code == 'cancelled' ? 'dfuAbortedInTransfer' : code,
        failureMessage:
            'The firmware transfer did not finish. Reconnect the same device for '
            'SDK reconciliation before another transfer.',
      );
    }
    return _completeSession(
      session,
      state: code == 'cancelled'
          ? FirmwareUpdateState.cancelled
          : FirmwareUpdateState.failed,
      failureCode: code,
      failureMessage: message,
    );
  }

  Stream<FirmwareUpdateProgress> watchProgress({String? deviceId}) {
    if (deviceId == null || deviceId.trim().isEmpty) {
      return _progressController.stream;
    }
    return _progressController.stream.where(
      (progress) => progress.deviceId == deviceId,
    );
  }

  Future<FirmwareUpdateSession?> reconcileFirmwareUpdate({
    bool attemptRecovery = false,
  }) {
    if (_operationInProgress) return Future.value(_activeSession);
    final pending = _reconciliationFuture;
    if (pending != null) return pending;
    return _reconciliationFuture = _reconcileFirmwareUpdate(
      attemptRecovery: attemptRecovery,
    ).whenComplete(() => _reconciliationFuture = null);
  }

  Future<FirmwareUpdateSession?> _reconcileFirmwareUpdate({
    bool attemptRecovery = false,
  }) async {
    await _restore();
    final current = _activeSession;
    if (current == null || current.isCompleted) return current;

    DeviceStatus status;
    try {
      status = await _refreshFirmwareStatus();
    } catch (_) {
      // Cached metadata cannot prove what booted after a physical recovery.
      status = (await deviceRepository.getDeviceStatus()).copyWith(
        connected: false,
      );
    }
    if (status.connected && _statusMatchesSession(status, current)) {
      if (eixamFirmwareVersionsMatch(
        status.firmwareVersion,
        current.targetVersion,
      )) {
        return _settleReconciliation(
          current,
          state: FirmwareUpdateState.completed,
          outcome: FirmwareUpdateReconciliationOutcome.completed,
          nextAction: FirmwareUpdateNextAction.completed,
          clearPersisted: true,
        );
      }
      final oldApplicationValid = eixamFirmwareVersionsMatch(
        status.firmwareVersion,
        current.fromVersion,
      );
      return _settleReconciliation(
        current,
        state: oldApplicationValid
            ? (current.targetVersion.isEmpty
                  ? FirmwareUpdateState.checking
                  : FirmwareUpdateState.readyToTransfer)
            : FirmwareUpdateState.failed,
        outcome: FirmwareUpdateReconciliationOutcome.installedVersionMismatch,
        nextAction: oldApplicationValid
            ? (current.artifactVerified
                  ? FirmwareUpdateNextAction.retryTransfer
                  : FirmwareUpdateNextAction.retryDownload)
            : FirmwareUpdateNextAction.waitForDevice,
        requiresRecovery: false,
        failureCode: 'installedVersionMismatch',
      );
    }
    if (status.connected && !_statusMatchesSession(status, current)) {
      return _settleReconciliation(
        current,
        state: current.state,
        outcome: FirmwareUpdateReconciliationOutcome.wrongDevice,
        nextAction:
            current.state == FirmwareUpdateState.physicalRecoveryRequired
            ? FirmwareUpdateNextAction.physicalRecovery
            : FirmwareUpdateNextAction.waitForDevice,
        failureCode: 'firmwareUpdateDeviceMismatch',
      );
    }

    final client = bleClient;
    if (client != null) {
      final scans = await client.scan(timeout: const Duration(seconds: 8));
      final bootloaders = scans
          .where((scan) => scan.toPublic().isDfuBootloader)
          .toList(growable: false);
      final matching = bootloaders
          .where(
            (scan) => _scanMatchesSession(
              scan.deviceId,
              scan.canonicalHardwareId,
              current,
            ),
          )
          .toList(growable: false);
      if (matching.length == 1) {
        final matched = current.copyWith(
          recoveryDeviceMatched:
              dfuTransport is! UnsupportedFirmwareDfuTransport,
        );
        await _persistRecoveryEvidence(matched);
        if (matched.state == FirmwareUpdateState.physicalRecoveryRequired ||
            matched.manualRecoveryRequired ||
            (matched.nativeTransferEngaged &&
                matched.remoteRecoveryFailed &&
                matched.remoteRecoveryAttempts >= maxRemoteRecoveryAttempts)) {
          return _requireManualRecovery(matched);
        }
        if (attemptRecovery) {
          final recovered = await recoverFirmwareUpdate(
            bootloaderDeviceId: matching.single.deviceId,
            releaseId: current.releaseId,
            targetVersion: current.targetVersion,
            hardwareId: current.hardwareId,
            replacingSession: matched,
          );
          await _persistTail;
          if (recovered.state == FirmwareUpdateState.completed) {
            return _settleReconciliation(
              recovered,
              state: FirmwareUpdateState.reconnecting,
              outcome: FirmwareUpdateReconciliationOutcome.recoveryDeviceFound,
              nextAction: FirmwareUpdateNextAction.waitForDevice,
            );
          }
          return recovered;
        }
        return _settleReconciliation(
          matched,
          state: FirmwareUpdateState.recoveryRequired,
          outcome: FirmwareUpdateReconciliationOutcome.recoveryDeviceFound,
          nextAction: matched.remoteRecoveryFailed
              ? FirmwareUpdateNextAction.retryRemoteRecovery
              : FirmwareUpdateNextAction.recover,
          requiresRecovery: true,
        );
      }
      if (matching.length > 1 || bootloaders.length > 1) {
        return _settleReconciliation(
          current,
          state: current.state,
          outcome: FirmwareUpdateReconciliationOutcome.ambiguousCandidates,
          nextAction: FirmwareUpdateNextAction.waitForDevice,
          failureCode: 'ambiguousFirmwareRecoveryDevice',
        );
      }
    }
    final physical = await _inspectPhysicalRecovery(
      current,
      matchingDeviceAbsent: bleClient != null,
    );
    if (physical != null) return physical;
    return _settleReconciliation(
      _activeSession ?? current,
      state: current.requiresRecovery
          ? FirmwareUpdateState.recoveryRequired
          : current.state,
      outcome: FirmwareUpdateReconciliationOutcome.deviceMissing,
      nextAction: FirmwareUpdateNextAction.waitForDevice,
    );
  }

  @override
  Future<FirmwareUpdateSession?> verifyRecoveredMigrationFirmware({
    required DeviceStatus verifiedStatus,
  }) async {
    await _restore();
    final current = _activeSession;
    if (current == null || current.isCompleted) return current;
    if (!verifiedStatus.connected ||
        !_statusMatchesSession(verifiedStatus, current)) {
      return current;
    }
    await _persistTail;
    if (eixamFirmwareVersionsMatch(
      verifiedStatus.firmwareVersion,
      current.targetVersion,
    )) {
      return _settleReconciliation(
        current,
        state: FirmwareUpdateState.completed,
        outcome: FirmwareUpdateReconciliationOutcome.completed,
        nextAction: FirmwareUpdateNextAction.completed,
        requiresRecovery: false,
        clearPersisted: true,
      );
    }
    if (eixamFirmwareVersionsMatch(
      verifiedStatus.firmwareVersion,
      current.fromVersion,
    )) {
      return _settleReconciliation(
        current,
        state: FirmwareUpdateState.readyToTransfer,
        outcome: FirmwareUpdateReconciliationOutcome.installedVersionMismatch,
        nextAction: current.artifactVerified
            ? FirmwareUpdateNextAction.retryTransfer
            : FirmwareUpdateNextAction.retryDownload,
        requiresRecovery: false,
      );
    }
    return current;
  }

  @override
  Future<FirmwareUpdateSession?> inspectMigrationPhysicalRecovery() async {
    await _restore();
    final current = _activeSession;
    if (current == null || current.isCompleted || _operationInProgress) {
      return null;
    }
    final physical = await _inspectPhysicalRecovery(
      current,
      matchingDeviceAbsent: true,
    );
    if (physical != null) return physical;
    if (!current.nativeTransferEngaged) return null;
    // The owning migration has just inspected a fresh scan and found no
    // matching device. Keep the canonical firmware action consistent with it.
    return _settleReconciliation(
      _activeSession ?? current,
      state: FirmwareUpdateState.reconnecting,
      outcome: FirmwareUpdateReconciliationOutcome.deviceMissing,
      nextAction: FirmwareUpdateNextAction.waitForDevice,
    );
  }

  Future<FirmwareUpdateSession> _requireManualRecovery(
    FirmwareUpdateSession current,
  ) async {
    final exhausted = current.copyWith(remoteRecoveryExhausted: true);
    await _persistTail;
    _sessions[current.sessionId] = exhausted;
    return _settleReconciliation(
      exhausted,
      state: FirmwareUpdateState.physicalRecoveryRequired,
      outcome: FirmwareUpdateReconciliationOutcome.recoveryDeviceFound,
      nextAction: FirmwareUpdateNextAction.physicalRecovery,
      requiresRecovery: true,
    );
  }

  Future<FirmwareUpdateSession?> _inspectPhysicalRecovery(
    FirmwareUpdateSession current, {
    bool matchingDeviceAbsent = false,
  }) async {
    if (current.manualRecoveryRequired ||
        current.state == FirmwareUpdateState.physicalRecoveryRequired) {
      return _requireManualRecovery(current);
    }
    if (matchingDeviceAbsent &&
        current.nativeTransferEngaged &&
        current.recoveryDeviceMatched &&
        current.remoteRecoveryFailed &&
        current.remoteRecoveryAttempts > 0) {
      final next = current.copyWith(
        recoveryReconciliationAttempts:
            current.recoveryReconciliationAttempts + 1,
      );
      await _persistRecoveryEvidence(next);
      if (next.recoveryReconciliationAttempts >= maxRecoveryReconciliations) {
        return _requireManualRecovery(next);
      }
    }
    final evidence = await physicalRecoveryEvidenceProvider?.call();
    if (current.nativeTransferEngaged &&
        evidence != null &&
        evidence.applicationInvalid &&
        evidence.remoteRecoveryUnsupported &&
        _sameIdentity(
          current.deviceId,
          current.hardwareId,
          evidence.deviceId,
          evidence.hardwareId,
        )) {
      return _settleReconciliation(
        current,
        state: FirmwareUpdateState.physicalRecoveryRequired,
        outcome: FirmwareUpdateReconciliationOutcome.deviceMissing,
        nextAction: FirmwareUpdateNextAction.physicalRecovery,
        requiresRecovery: true,
      );
    }
    return null;
  }

  @override
  Stream<FirmwareUpdateProgress> watchMigrationFirmwareProgress({
    required String deviceId,
  }) => watchProgress(deviceId: deviceId);

  @override
  Future<FirmwareUpdateSession> recoverMigrationFirmwareUpdate({
    required String bootloaderDeviceId,
    required String releaseId,
    required String targetVersion,
  }) async {
    await _restore();
    final active = _activeSession;
    final matchingInterrupted =
        active != null &&
        !active.isCompleted &&
        (active.nativeTransferEngaged || active.requiresRecovery) &&
        active.releaseId == releaseId &&
        eixamFirmwareVersionsMatch(active.targetVersion, targetVersion) &&
        _sameIdentity(
          active.deviceId,
          active.hardwareId,
          bootloaderDeviceId,
          null,
        );
    return recoverFirmwareUpdate(
      bootloaderDeviceId: bootloaderDeviceId,
      releaseId: releaseId,
      targetVersion: targetVersion,
      replacingSession: matchingInterrupted ? active : null,
    );
  }

  Future<void> cancelFirmwareUpdate(String sessionId) async {
    // Once flashing has begun the bootloader has already erased the running
    // app, so aborting cannot restore the previous firmware — it only strands
    // the device in DFU mode. Refuse; the transfer must be allowed to finish.
    if (_sessions[sessionId]?.nativeTransferEngaged == true) {
      throw const FirmwareUpdateException(
        'dfuCancelBlockedInTransfer',
        'The firmware transfer is already in progress and can no longer be '
            'cancelled safely. Let it finish — interrupting it leaves the device '
            'in recovery mode until it is re-flashed.',
      );
    }
    await dfuTransport.cancel(sessionId);
    final session = _sessions[sessionId];
    if (session != null) {
      _completeSession(session, state: FirmwareUpdateState.cancelled);
    }
  }

  /// Whether [state] is at or past the point where the bootloader has erased
  /// the running app, so an abort would strand the device in DFU mode.
  static bool _isPastPointOfNoReturn(FirmwareUpdateState? state) {
    return state == FirmwareUpdateState.transferring ||
        state == FirmwareUpdateState.reconnecting ||
        state == FirmwareUpdateState.verifyingInstalledVersion;
  }

  void _markNativeTransferEngaged(FirmwareUpdateSession session) {
    if (_disposed) return;
    final tracked = _sessions[session.sessionId];
    if (tracked != null && !tracked.nativeTransferEngaged) {
      _sessions[session.sessionId] = tracked.copyWith(
        nativeTransferEngaged: true,
        updatedAt: DateTime.now(),
      );
      _queuePersist(_sessions[session.sessionId]!);
    }
  }

  /// Re-flashes a device stranded in the DFU bootloader (e.g. after an
  /// interrupted transfer, which erased the previous application).
  ///
  /// [bootloaderDeviceId] is the address the device advertises while in
  /// bootloader mode. The flash is forced because the device no longer exposes
  /// the buttonless entry service. On a successful transfer the device reboots
  /// into the freshly installed application and leaves DFU mode on its own;
  /// eligibility and app-mode version verification are intentionally skipped.
  Future<FirmwareUpdateSession> recoverFirmwareUpdate({
    required String bootloaderDeviceId,
    required String releaseId,
    String targetVersion = '',
    String? hardwareId,
    FirmwareUpdateSession? replacingSession,
  }) => _exclusive(
    () => _recoverFirmwareUpdate(
      bootloaderDeviceId: bootloaderDeviceId,
      releaseId: releaseId,
      targetVersion: targetVersion,
      hardwareId: hardwareId,
      replacingSession: replacingSession,
    ),
  );

  Future<FirmwareUpdateSession> _recoverFirmwareUpdate({
    required String bootloaderDeviceId,
    required String releaseId,
    String targetVersion = '',
    String? hardwareId,
    FirmwareUpdateSession? replacingSession,
  }) async {
    await _restore();
    var current = replacingSession;
    // Migration already matched its candidate; independently establish native
    // recovery capability against the canonical firmware identity here.
    if (current != null &&
        bleClient != null &&
        !current.recoveryDeviceMatched) {
      final scans = await bleClient!.scan(timeout: const Duration(seconds: 8));
      final matches = scans.where(
        (scan) =>
            scan.toPublic().isDfuBootloader &&
            _scanMatchesSession(
              scan.deviceId,
              scan.canonicalHardwareId,
              current!,
            ),
      );
      if (matches.length == 1 &&
          dfuTransport is! UnsupportedFirmwareDfuTransport) {
        current = current.copyWith(recoveryDeviceMatched: true);
        await _persistRecoveryEvidence(current);
        bootloaderDeviceId = matches.single.deviceId;
      } else {
        return _settleReconciliation(
          current,
          state: current.state,
          outcome: FirmwareUpdateReconciliationOutcome.deviceMissing,
          nextAction: FirmwareUpdateNextAction.waitForDevice,
        );
      }
    }
    if (current?.manualRecoveryRequired == true) {
      return _requireManualRecovery(current!);
    }
    if (current != null &&
        current.nativeTransferEngaged &&
        current.recoveryDeviceMatched &&
        current.remoteRecoveryFailed &&
        current.remoteRecoveryAttempts >= maxRemoteRecoveryAttempts) {
      return _requireManualRecovery(current);
    }
    var address = bootloaderDeviceId;
    var active = await _recoverFirmwareUpdateOnce(
      bootloaderDeviceId: address,
      releaseId: releaseId,
      targetVersion: targetVersion,
      hardwareId: hardwareId,
      replacingSession: current,
    );
    for (
      var opportunity = 0;
      opportunity < maxRecoveryReconciliations;
      opportunity++
    ) {
      await _persistTail;
      if (!active.remoteRecoveryFailed ||
          !active.recoveryDeviceMatched ||
          active.nextAction == FirmwareUpdateNextAction.waitForDevice) {
        return active;
      }
      // Each terminal native operation has fully released ownership before
      // inspecting the returned application or a fresh recovery advertisement.
      for (var scan = 0; scan < maxRecoveryReconciliations; scan++) {
        final reconciled = await _reconcileFirmwareUpdate();
        if (reconciled == null) return active;
        active = reconciled;
        if (active.nextAction != FirmwareUpdateNextAction.waitForDevice) {
          break;
        }
      }
      if (active.nextAction != FirmwareUpdateNextAction.retryRemoteRecovery &&
          active.nextAction != FirmwareUpdateNextAction.recover) {
        return active;
      }
      final scans = await bleClient!.scan(timeout: const Duration(seconds: 8));
      final identity = active;
      final matches = scans.where(
        (scan) =>
            scan.toPublic().isDfuBootloader &&
            _scanMatchesSession(
              scan.deviceId,
              scan.canonicalHardwareId,
              identity,
            ),
      );
      if (matches.length != 1) {
        return _settleReconciliation(
          active,
          state: active.state,
          outcome: FirmwareUpdateReconciliationOutcome.deviceMissing,
          nextAction: FirmwareUpdateNextAction.waitForDevice,
        );
      }
      address = matches.single.deviceId;
      active = await _recoverFirmwareUpdateOnce(
        bootloaderDeviceId: address,
        releaseId: releaseId,
        targetVersion: targetVersion,
        hardwareId: hardwareId,
        replacingSession: active,
      );
    }
    return active;
  }

  Future<FirmwareUpdateSession> _recoverFirmwareUpdateOnce({
    required String bootloaderDeviceId,
    required String releaseId,
    String targetVersion = '',
    String? hardwareId,
    FirmwareUpdateSession? replacingSession,
  }) async {
    await _restore();
    final now = DateTime.now();
    final session = FirmwareUpdateSession(
      sessionId: replacingSession?.sessionId ?? _newSessionId(now),
      deviceId: replacingSession?.deviceId ?? bootloaderDeviceId,
      releaseId: releaseId,
      fromVersion: replacingSession?.fromVersion ?? '',
      targetVersion: targetVersion,
      state: FirmwareUpdateState.idle,
      startedAt: replacingSession?.startedAt ?? now,
      hardwareId: hardwareId ?? replacingSession?.hardwareId,
      updatedAt: now,
      nativeTransferEngaged: replacingSession?.nativeTransferEngaged ?? false,
      requiresRecovery: true,
      migrationOwned: replacingSession?.migrationOwned ?? false,
      nextAction: FirmwareUpdateNextAction.recover,
      recoveryDeviceMatched: replacingSession?.recoveryDeviceMatched ?? false,
      remoteRecoveryAttempts: replacingSession?.remoteRecoveryAttempts ?? 0,
      remoteRecoveryFailed: replacingSession?.remoteRecoveryFailed ?? false,
      recoveryReconciliationAttempts:
          replacingSession?.recoveryReconciliationAttempts ?? 0,
      remoteRecoveryExhausted:
          replacingSession?.remoteRecoveryExhausted ?? false,
    );
    if (replacingSession == null) _ensureMayStart(session);
    _sessions[session.sessionId] = session;
    await _persist(session);
    var remoteInvocationStarted = false;
    try {
      final release = FirmwareRelease(
        releaseId: releaseId,
        version: targetVersion,
        sha256Hash: replacingSession?.artifactSha256,
        fileSizeBytes: replacingSession?.artifactSizeBytes,
      );
      final artifactBytes = await _prepareArtifact(session, release);
      _emit(session, FirmwareUpdateState.readyToTransfer);
      _emit(session, FirmwareUpdateState.transferring);
      _debugLog(
        'OTA_COORDINATOR recovery_dfu_start '
        'sessionId=${session.sessionId} bootloader=$bootloaderDeviceId '
        'release=$releaseId',
      );
      // Same reconnect suppression as a normal update: an auto-reconnect
      // grabbing the bootloader's address mid-flash breaks the recovery too.
      await _runNativeDfuWithWatchdog(
        session: session,
        beforeNativeStart: () async {
          await _persistRecoveryEvidence(
            _sessions[session.sessionId]!.copyWith(
              remoteRecoveryAttempts: session.remoteRecoveryAttempts + 1,
              remoteRecoveryFailed: false,
              clearCompletedAt: true,
            ),
          );
          remoteInvocationStarted = true;
        },
        request: FirmwareDfuTransferRequest(
          sessionId:
              '${session.sessionId}-recovery-${session.remoteRecoveryAttempts + 1}-${DateTime.now().microsecondsSinceEpoch}',
          deviceId: bootloaderDeviceId,
          release: release,
          artifactBytes: artifactBytes,
          forceDfu: true,
        ),
        stallMessage:
            'The recovery transfer made no upload progress for '
            '${_dfuStallTimeout.inSeconds}s.',
        firstUploadMessage:
            'The recovery upload never started (the bootloader could not be '
            'reconnected).',
      );
      return _settleReconciliation(
        _sessions[session.sessionId]!.copyWith(
          remoteRecoveryFailed: false,
          remoteRecoveryExhausted: false,
          recoveryReconciliationAttempts: 0,
        ),
        state: FirmwareUpdateState.reconnecting,
        outcome: FirmwareUpdateReconciliationOutcome.recoveryDeviceFound,
        nextAction: FirmwareUpdateNextAction.waitForDevice,
      );
    } on FirmwareUpdateException catch (error) {
      final tracked = _sessions[session.sessionId]!;
      final terminalTransportFailure = const {
        'dfuFailed',
        'dfuTransportFailed',
        'recoveryRequired',
        'deviceDisconnected',
        'dfuStalled',
        'dfuTerminalTimeout',
      }.contains(error.code);
      await _persistRecoveryEvidence(
        tracked.copyWith(
          remoteRecoveryFailed:
              terminalTransportFailure && remoteInvocationStarted,
        ),
      );
      return _completeSession(
        session,
        state: FirmwareUpdateState.recoveryRequired,
        failureCode: error.code,
        failureMessage: error.message,
      );
    } catch (error) {
      return _completeSession(
        session,
        state: FirmwareUpdateState.recoveryRequired,
        failureCode: 'firmwareRecoveryFailed',
        failureMessage: error.toString(),
      );
    }
  }

  Future<FirmwareUpdateEligibility> evaluateEligibility({
    required DeviceStatus status,
    required FirmwareRelease? release,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) async {
    final blockers = <FirmwareUpdateBlocker>[];
    final messages = <String>[];

    void add(FirmwareUpdateBlocker blocker, String message) {
      if (!blockers.contains(blocker)) {
        blockers.add(blocker);
        messages.add(message);
      }
    }

    final firmwareVersion = status.firmwareVersion?.trim();
    if (!status.connected) {
      add(FirmwareUpdateBlocker.noConnectedDevice, 'No BLE device connected.');
    }
    if (firmwareVersion == null || firmwareVersion.isEmpty) {
      add(
        FirmwareUpdateBlocker.unknownFirmwareVersion,
        'Current firmware version is unknown.',
      );
    }
    final battery = status.approximateBatteryPercentage;
    if ((battery == null && policy.requireKnownDeviceBattery) ||
        (battery != null && battery < policy.minDeviceBatteryPercentage)) {
      add(
        FirmwareUpdateBlocker.lowDeviceBattery,
        'Device battery is below the OTA threshold.',
      );
    }
    // TODO: add an RSSI/connection-stability signal when the BLE runtime
    // exposes one. DeviceStatus.signalQuality is not currently a BLE RSSI.

    final model = status.model?.trim();
    if (model == null || model.isEmpty) {
      add(
        FirmwareUpdateBlocker.unsupportedHardware,
        'Device hardware model is unknown.',
      );
    } else if (policy.supportedHardwareModels.isNotEmpty &&
        !policy.supportedHardwareModels
            .map((item) => item.toLowerCase())
            .contains(model.toLowerCase())) {
      add(
        FirmwareUpdateBlocker.unsupportedHardware,
        'Device hardware model is not supported by this policy.',
      );
    }
    if (release != null) {
      final releaseModel = release.hardwareModel?.trim();
      if (releaseModel != null &&
          releaseModel.isNotEmpty &&
          model != null &&
          model.isNotEmpty &&
          releaseModel.toLowerCase() != model.toLowerCase()) {
        add(
          FirmwareUpdateBlocker.incompatibleRelease,
          'Firmware release does not match this hardware model.',
        );
      }
      if (release.sha256Hash == null || release.sha256Hash!.isEmpty) {
        add(
          FirmwareUpdateBlocker.hashMissing,
          'Firmware release SHA-256 is missing.',
        );
      }
    }

    final sosState = await sosRepository.getSosState();
    if (_isActiveSosState(sosState)) {
      add(FirmwareUpdateBlocker.sosActive, 'SOS flow is active.');
    }
    final incident = await sosRepository.getCurrentIncident();
    if (incident != null && _isActiveSosState(incident.state)) {
      add(FirmwareUpdateBlocker.sosActive, 'Local SOS incident is active.');
    }
    final preSos = await preSosStatusProvider?.call();
    if (preSos?.active == true) {
      add(
        FirmwareUpdateBlocker.preSosCountdownActive,
        'PRE-SOS countdown is active.',
      );
    }
    final deviceSos = await deviceSosStatusProvider?.call();
    if (deviceSos?.state == DeviceSosState.preConfirm) {
      add(
        FirmwareUpdateBlocker.preSosCountdownActive,
        'Device PRE-SOS countdown is active.',
      );
    } else if (deviceSos != null &&
        deviceSos.state != DeviceSosState.inactive &&
        deviceSos.state != DeviceSosState.resolved &&
        deviceSos.state != DeviceSosState.unknown) {
      add(FirmwareUpdateBlocker.sosActive, 'Device SOS runtime is active.');
    }

    final deathManPlan = await deathManRepository.getActiveDeathManPlan();
    if (deathManPlan != null &&
        _isBlockingDeathManStatus(deathManPlan.status)) {
      add(
        FirmwareUpdateBlocker.dmpActiveOrOverdue,
        'Death Man Protocol is active or overdue.',
      );
    }

    final protection = await protectionStatusProvider?.call();
    if (protection != null && _isProtectionBusy(protection)) {
      add(
        FirmwareUpdateBlocker.protectionRuntimeBusy,
        'Protection runtime is using BLE or has pending work.',
      );
    }

    final lifecycleState = appLifecycleStateProvider?.call();
    if (policy.requireForeground &&
        lifecycleState != null &&
        lifecycleState != AppLifecycleState.resumed) {
      add(
        FirmwareUpdateBlocker.appBackgrounded,
        'The app must stay in the foreground for OTA.',
      );
    }

    return FirmwareUpdateEligibility(
      eligible: blockers.isEmpty,
      blockers: List<FirmwareUpdateBlocker>.unmodifiable(blockers),
      messages: List<String>.unmodifiable(messages),
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    await _persistTail;
    await _sessionController.close();
    await _progressController.close();
  }

  Future<FirmwareUpdateSession> _exclusive(
    Future<FirmwareUpdateSession> Function() action,
  ) async {
    if (_disposed) {
      throw const FirmwareUpdateException(
        'firmwareCoordinatorDisposed',
        'Firmware coordinator is closed.',
      );
    }
    if (_operationInProgress) {
      throw const FirmwareUpdateException(
        'firmwareUpdateAlreadyRunning',
        'A firmware operation is running.',
      );
    }
    _operationInProgress = true;
    try {
      return await action();
    } finally {
      _operationInProgress = false;
    }
  }

  Future<List<int>> _prepareArtifact(
    FirmwareUpdateSession session,
    FirmwareRelease release,
  ) async {
    _emit(session, FirmwareUpdateState.downloading);
    await _persistTail;
    final download = await remoteDataSource.prepareDownload(release.releaseId);
    final expectedHash =
        (download.sha256Hash.isNotEmpty
                ? download.sha256Hash
                : release.sha256Hash)
            ?.trim()
            .toLowerCase();
    if (expectedHash == null || expectedHash.isEmpty) {
      throw const FirmwareUpdateException(
        'hashMissing',
        'Firmware artifact SHA-256 is missing.',
      );
    }
    if (release.sha256Hash != null &&
        release.sha256Hash!.trim().isNotEmpty &&
        expectedHash != release.sha256Hash!.trim().toLowerCase()) {
      throw const FirmwareUpdateException(
        'hashMismatch',
        'Firmware release integrity metadata changed.',
      );
    }
    validateFirmwareArtifactMetadataSize(release.fileSizeBytes);
    final reference = firmwareArtifactReference(
      release.releaseId,
      release.version,
      expectedHash,
    );
    var tracked = _sessions[session.sessionId] ?? session;
    final metadata = tracked.copyWith(
      artifactReference: reference,
      artifactSha256: expectedHash,
      artifactSizeBytes: release.fileSizeBytes,
      artifactDownloaded: false,
      artifactVerified: false,
    );
    _sessions[session.sessionId] = metadata;
    _queuePersist(metadata);
    await _persistTail;
    var bytes = await artifactCache.readVerified(
      reference,
      expectedHash,
      release.fileSizeBytes,
    );
    if (bytes == null) {
      if (download.downloadUrl.isEmpty) {
        throw const FirmwareUpdateException(
          'artifactMissing',
          'Firmware artifact URL is missing.',
        );
      }
      bytes = await remoteDataSource.downloadArtifact(
        download.downloadUrl,
        expectedSizeBytes: release.fileSizeBytes,
      );
      if (_disposed) {
        throw const FirmwareUpdateException(
          'cancelled',
          'Firmware preparation is closed.',
        );
      }
      validateFirmwareArtifactDownloadedSize(
        bytes.length,
        expectedSizeBytes: release.fileSizeBytes,
      );
      _emit(session, FirmwareUpdateState.verifying);
      _verifySha256(bytes, expectedHash);
      await artifactCache.writeVerified(reference, bytes);
    } else {
      _emit(session, FirmwareUpdateState.verifying);
      _verifySha256(bytes, expectedHash);
    }
    tracked = _sessions[session.sessionId]!.copyWith(
      artifactDownloaded: true,
      artifactVerified: true,
      artifactSizeBytes: release.fileSizeBytes ?? bytes.length,
    );
    _sessions[session.sessionId] = tracked;
    _queuePersist(tracked);
    await _persistTail;
    if (_sessions[session.sessionId]?.state == FirmwareUpdateState.cancelled) {
      throw const FirmwareUpdateException(
        'cancelled',
        'Firmware preparation was cancelled.',
      );
    }
    _emit(session, FirmwareUpdateState.readyToTransfer);
    await _persistTail;
    return bytes;
  }

  Future<void> _restore() {
    return _restoreFuture ??= () async {
      var restored = await sessionStore.load();
      if (restored != null) {
        if (!restored.nativeTransferEngaged && !restored.isCompleted) {
          restored = restored.copyWith(
            requiresRecovery: false,
            nextAction: restored.artifactVerified
                ? FirmwareUpdateNextAction.startTransfer
                : FirmwareUpdateNextAction.retryDownload,
          );
        }
        if (restored.nativeTransferEngaged &&
            restored.state != FirmwareUpdateState.physicalRecoveryRequired) {
          restored = restored.copyWith(
            nextAction: FirmwareUpdateNextAction.waitForDevice,
          );
        }
        if (restored.manualRecoveryRequired) {
          restored = restored.copyWith(
            state: FirmwareUpdateState.physicalRecoveryRequired,
            nextAction: FirmwareUpdateNextAction.physicalRecovery,
          );
        }
        _activeSession = restored;
        _sessions[restored.sessionId] = restored;
        _restoredSessions.add(restored.sessionId);
      }
    }();
  }

  void _ensureMayStart(
    FirmwareUpdateSession requested, {
    bool verifiedMigrationSource = false,
  }) {
    final active = _activeSession;
    if (active == null || active.isCompleted) return;
    final sameDevice = _sameIdentity(
      active.deviceId,
      active.hardwareId,
      requested.deviceId,
      requested.hardwareId,
    );
    // Only migration supplies source status from a fresh owned protocol
    // inspection. A persisted terminal failure must not deadlock that retry.
    if (sameDevice &&
        ((verifiedMigrationSource &&
                (canRetryFirmwareAfterSourceVerification(active) ||
                    (active.nextAction ==
                            FirmwareUpdateNextAction.physicalRecovery &&
                        requested.fromVersion.isNotEmpty) ||
                    (_restoredSessions.contains(active.sessionId) &&
                        eixamFirmwareVersionsMatch(
                          active.fromVersion,
                          requested.fromVersion,
                        )))) ||
            (_restoredSessions.contains(active.sessionId) &&
                !active.nativeTransferEngaged) ||
            active.nextAction == FirmwareUpdateNextAction.retryTransfer ||
            active.nextAction == FirmwareUpdateNextAction.retryDownload ||
            active.nextAction == FirmwareUpdateNextAction.startTransfer)) {
      return;
    }
    throw FirmwareUpdateException(
      sameDevice
          ? 'firmwareUpdateResumeRequired'
          : 'firmwareUpdateActiveForAnotherDevice',
      sameDevice
          ? 'An interrupted firmware update must be reconciled before retrying.'
          : 'A firmware update for another physical device is active.',
      requiresRecovery: active.requiresRecovery,
    );
  }

  bool _statusMatchesSession(
    DeviceStatus status,
    FirmwareUpdateSession session,
  ) {
    return _sameIdentity(
      status.deviceId,
      status.canonicalHardwareId,
      session.deviceId,
      session.hardwareId,
    );
  }

  bool _scanMatchesSession(
    String deviceId,
    String? hardwareId,
    FirmwareUpdateSession session,
  ) {
    return _sameIdentity(
      deviceId,
      hardwareId,
      session.deviceId,
      session.hardwareId,
    );
  }

  bool _sameIdentity(
    String firstDeviceId,
    String? firstHardwareId,
    String secondDeviceId,
    String? secondHardwareId,
  ) {
    final firstStable = normalizeCanonicalHardwareId(firstHardwareId);
    final secondStable = normalizeCanonicalHardwareId(secondHardwareId);
    if (firstStable != null && secondStable != null) {
      return firstStable == secondStable;
    }
    return firstDeviceId == secondDeviceId;
  }

  Future<FirmwareUpdateSession> _settleReconciliation(
    FirmwareUpdateSession session, {
    required FirmwareUpdateState state,
    required FirmwareUpdateReconciliationOutcome outcome,
    required FirmwareUpdateNextAction nextAction,
    bool? requiresRecovery,
    String? failureCode,
    bool clearPersisted = false,
  }) async {
    final now = DateTime.now();
    final next = session.copyWith(
      state: state,
      completedAt: state == FirmwareUpdateState.completed ? now : null,
      clearCompletedAt: state != FirmwareUpdateState.completed,
      updatedAt: now,
      reconciliationOutcome: outcome,
      nextAction: nextAction,
      requiresRecovery: requiresRecovery,
      failureCode: failureCode,
    );
    _sessions[next.sessionId] = next;
    _activeSession = next;
    if (clearPersisted) {
      await sessionStore.clear();
    } else {
      await sessionStore.save(next);
    }
    if (!_sessionController.isClosed) _sessionController.add(next);
    return next;
  }

  Future<void> _persistRecoveryEvidence(FirmwareUpdateSession session) async {
    await _persistTail;
    _sessions[session.sessionId] = session;
    await _persist(session);
  }

  Future<void> _persist(FirmwareUpdateSession session) async {
    _activeSession = session;
    if (session.isCompleted) {
      await sessionStore.clear();
    } else {
      await sessionStore.save(session);
    }
    if (!_sessionController.isClosed) _sessionController.add(session);
  }

  void _queuePersist(FirmwareUpdateSession session) {
    if (_disposed) return;
    _persistTail = _persistTail.then((_) => _persist(session));
  }

  FirmwareUpdateCheck _rememberCheck(FirmwareUpdateCheck check) {
    _lastCheck = check;
    return check;
  }

  Future<FirmwareUpdateCheck> _resolveUsableCheck({
    required String deviceId,
    required String releaseId,
    required FirmwareUpdatePolicy policy,
    bool forceRefresh = false,
  }) async {
    final current = _lastCheck;
    if (!forceRefresh &&
        current != null &&
        current.device.deviceId == deviceId &&
        current.release?.releaseId == releaseId) {
      return current;
    }
    final check = await checkFirmwareUpdate(deviceId: deviceId, policy: policy);
    if (check.release?.releaseId == releaseId) {
      return check;
    }
    final blockers = <FirmwareUpdateBlocker>[
      ...check.eligibility.blockers,
      FirmwareUpdateBlocker.incompatibleRelease,
    ];
    return FirmwareUpdateCheck(
      device: check.device,
      updateAvailable: check.updateAvailable,
      release: check.release,
      eligibility: FirmwareUpdateEligibility(
        eligible: false,
        blockers: List<FirmwareUpdateBlocker>.unmodifiable(blockers),
        messages: <String>[
          ...check.eligibility.messages,
          'Requested firmware release is not the backend-selected update.',
        ],
      ),
      checkedAt: check.checkedAt,
    );
  }

  DeviceFirmwareInfo _firmwareInfoFromStatus(DeviceStatus status) {
    return DeviceFirmwareInfo(
      deviceId: status.deviceId,
      hardwareId: status.canonicalHardwareId ?? status.deviceId,
      nodeId: status.nodeId,
      hardwareModel: status.model,
      currentVersion: status.firmwareVersion,
      batteryPercentage: status.approximateBatteryPercentage,
      connected: status.connected,
      readyForSafety: status.isReadyForSafety,
    );
  }

  bool _matchesRequestedDevice(DeviceStatus status, String? requestedDeviceId) {
    final requested = requestedDeviceId?.trim();
    if (requested == null || requested.isEmpty) {
      return true;
    }
    return status.deviceId == requested ||
        status.canonicalHardwareId == requested ||
        status.nodeId?.toString() == requested;
  }

  FirmwareUpdateEligibility _withBlocker(
    FirmwareUpdateEligibility eligibility,
    FirmwareUpdateBlocker blocker,
    String message,
  ) {
    if (eligibility.blockers.contains(blocker)) {
      return eligibility;
    }
    return FirmwareUpdateEligibility(
      eligible: false,
      blockers: List<FirmwareUpdateBlocker>.unmodifiable(
        <FirmwareUpdateBlocker>[...eligibility.blockers, blocker],
      ),
      messages: List<String>.unmodifiable(<String>[
        ...eligibility.messages,
        message,
      ]),
    );
  }

  void _verifySha256(List<int> bytes, String expectedHash) {
    final actual = sha256.convert(bytes).toString().toLowerCase();
    if (actual != expectedHash.toLowerCase()) {
      throw FirmwareUpdateException(
        'hashMismatch',
        'Firmware artifact SHA-256 mismatch.',
      );
    }
  }

  Future<_InstalledVersionVerification> _waitForInstalledVersion({
    required FirmwareUpdateSession session,
    required String targetVersion,
    FirmwareDfuStatusRefreshHook? statusRefresh,
  }) async {
    final deadline = DateTime.now().add(_postDfuVerificationTimeout);
    var attempt = 0;
    DeviceStatus? latest;
    while (true) {
      if (_disposed) {
        throw const FirmwareUpdateException(
          'cancelled',
          'Firmware verification is closed.',
        );
      }
      attempt += 1;
      final now = DateTime.now();
      _emit(
        session,
        latest?.connected == true
            ? FirmwareUpdateState.verifyingInstalledVersion
            : FirmwareUpdateState.reconnecting,
      );
      final refresh = statusRefresh ?? postDfuStatusRefresh;
      DeviceStatus status;
      try {
        status = refresh == null
            ? await _refreshFirmwareStatus()
            : await refresh(
                deviceId: session.deviceId,
                attempt: attempt,
                targetVersion: targetVersion,
              );
      } catch (error) {
        if (error is FirmwareUpdateException &&
            !const {
              'bluetoothDisabled',
              'bluetoothUnavailable',
              'deviceNotFound',
              'deviceDisconnected',
            }.contains(error.code)) {
          rethrow;
        }
        // Native transfer already completed. A temporarily unavailable adapter
        // during rediscovery is waiting evidence, not a failed native transfer.
        _debugLog(
          'OTA_COORDINATOR verification_wait attempt=$attempt error=$error',
        );
        status = DeviceStatus(
          deviceId: session.deviceId,
          canonicalHardwareId: session.hardwareId,
          model: latest?.model ?? '',
          paired: false,
          activated: false,
          connected: false,
        );
      }
      latest = status;
      final installed = status.firmwareVersion?.trim();
      final matches = eixamFirmwareVersionsMatch(installed, targetVersion);
      if (status.connected &&
          matches &&
          _statusMatchesSession(status, session)) {
        return _InstalledVersionVerification(
          matchesTarget: true,
          installedVersion: installed,
          latestStatus: status,
        );
      }
      if (!now.isBefore(deadline)) {
        return _InstalledVersionVerification(
          matchesTarget: false,
          installedVersion: installed,
          latestStatus: status,
          requiresRecovery: !status.connected,
        );
      }
      await Future<void>.delayed(_postDfuVerificationPollInterval);
    }
  }

  String _backendComparableFirmwareVersion(String version) {
    final normalized = normalizeEixamFirmwareVersion(version);
    final semver = RegExp(r'^(\d+\.\d+\.\d+)(?:\.|$)').firstMatch(normalized);
    return semver?.group(1) ?? normalized;
  }

  bool _firmwareReleaseIsActionable({
    required String currentVersion,
    required String targetVersion,
    required bool allowDowngrade,
    required bool explicitTarget,
  }) {
    if (eixamFirmwareVersionsMatch(currentVersion, targetVersion)) {
      return false;
    }
    if (explicitTarget) {
      return true;
    }
    final comparison = compareEixamFirmwareVersions(
      currentVersion,
      targetVersion,
    );
    if (comparison == null) {
      return !allowDowngrade;
    }
    return allowDowngrade ? comparison > 0 : comparison < 0;
  }

  Future<FirmwareRelease?> _newestActionableCatalogRelease({
    required String currentVersion,
    required FirmwareUpdatePolicy policy,
    required String? hardwareModel,
  }) async {
    try {
      final response = await remoteDataSource.listReleases(
        hardwareModel: hardwareModel,
      );
      FirmwareRelease? newest;
      for (final dto in response.firmwareVersions) {
        if (dto.id.isEmpty || dto.version.isEmpty) continue;
        if (dto.isActive == false && !policy.allowDowngrade) continue;
        if (!_firmwareReleaseIsActionable(
          currentVersion: currentVersion,
          targetVersion: dto.version,
          allowDowngrade: policy.allowDowngrade,
          explicitTarget: false,
        )) {
          continue;
        }
        if (newest == null) {
          newest = dto.toDomain();
          continue;
        }
        final comparison = compareEixamFirmwareVersions(
          newest.version,
          dto.version,
        );
        if (comparison != null && comparison < 0) {
          newest = dto.toDomain();
        }
      }
      return newest;
    } catch (error) {
      _debugLog('OTA_COORDINATOR catalog_fallback_failed error=$error');
      return null;
    }
  }

  FirmwareUpdateSession _completeSession(
    FirmwareUpdateSession session, {
    required FirmwareUpdateState state,
    String? failureCode,
    String? failureMessage,
  }) {
    final tracked = _sessions[session.sessionId] ?? session;
    if (_disposed) return tracked;
    final next = tracked.copyWith(
      state: state,
      completedAt: DateTime.now(),
      failureCode: failureCode,
      failureMessage: failureMessage,
      requiresRecovery: state == FirmwareUpdateState.recoveryRequired,
      updatedAt: DateTime.now(),
      nextAction: switch (state) {
        FirmwareUpdateState.completed => FirmwareUpdateNextAction.completed,
        FirmwareUpdateState.recoveryRequired =>
          FirmwareUpdateNextAction.recover,
        FirmwareUpdateState.reconnecting ||
        FirmwareUpdateState.verifyingInstalledVersion =>
          FirmwareUpdateNextAction.waitForDevice,
        _ => FirmwareUpdateNextAction.retry,
      },
    );
    _sessions[session.sessionId] = next;
    _queuePersist(next);
    _emit(
      next,
      state,
      failureCode: failureCode,
      failureMessage: failureMessage,
    );
    return next;
  }

  void _emit(
    FirmwareUpdateSession session,
    FirmwareUpdateState state, {
    int? progressPercentage,
    int? bytesTransferred,
    int? totalBytes,
    String? failureCode,
    String? failureMessage,
  }) {
    if (_disposed) return;
    // Track the live phase in the session map: the point-of-no-return guards
    // (_completeTransferFailure, cancelFirmwareUpdate) read it to decide
    // whether the bootloader has already erased the running app. Without this
    // the tracked state stays `idle` for the whole transfer and a mid-flash
    // abort/stall is misreported as a clean cancel/failure.
    final tracked = _sessions[session.sessionId];
    if (tracked != null &&
        tracked.completedAt == null &&
        tracked.state != state) {
      // Do NOT let a native terminal-ish progress event (dfuError → failed,
      // dfuAborted → cancelled, delivered through watchProgress) regress the
      // tracked phase out of the point-of-no-return band. The failure routing
      // reads this phase right after start() throws; if it were clobbered to
      // failed/cancelled, a device genuinely mid-flash would be reported as a
      // clean failure instead of routed to recovery. Terminal state is applied
      // authoritatively by _completeSession, not by a transient progress event.
      final regressesOutOfPointOfNoReturn =
          _isPastPointOfNoReturn(tracked.state) &&
          !_isPastPointOfNoReturn(state);
      if (!regressesOutOfPointOfNoReturn) {
        _sessions[session.sessionId] = tracked.copyWith(
          state: state,
          updatedAt: DateTime.now(),
          nextAction: switch (state) {
            FirmwareUpdateState.downloading || FirmwareUpdateState.verifying =>
              FirmwareUpdateNextAction.retryDownload,
            FirmwareUpdateState.readyToTransfer =>
              FirmwareUpdateNextAction.startTransfer,
            FirmwareUpdateState.reconnecting ||
            FirmwareUpdateState.verifyingInstalledVersion =>
              FirmwareUpdateNextAction.waitForDevice,
            FirmwareUpdateState.recoveryRequired =>
              FirmwareUpdateNextAction.recover,
            _ => FirmwareUpdateNextAction.none,
          },
        );
        _queuePersist(_sessions[session.sessionId]!);
      }
    }
    if (_progressController.isClosed) {
      return;
    }
    _progressController.add(
      FirmwareUpdateProgress(
        sessionId: session.sessionId,
        deviceId: session.deviceId,
        state: state,
        progressPercentage: progressPercentage,
        bytesTransferred: bytesTransferred,
        totalBytes: totalBytes,
        failureCode: failureCode,
        failureMessage: failureMessage,
        nativeTransferEngaged:
            _sessions[session.sessionId]?.nativeTransferEngaged ?? false,
        requiresRecovery: state == FirmwareUpdateState.recoveryRequired,
        updatedAt: DateTime.now(),
      ),
    );
  }

  String _newSessionId(DateTime now) {
    return 'fw-${now.toUtc().microsecondsSinceEpoch}';
  }

  bool _isActiveSosState(SosState state) {
    return switch (state) {
      SosState.idle ||
      SosState.cancelled ||
      SosState.cancelRequested ||
      SosState.resolved ||
      SosState.failed => false,
      _ => true,
    };
  }

  bool _isBlockingDeathManStatus(DeathManStatus status) {
    return switch (status) {
      DeathManStatus.confirmedSafe ||
      DeathManStatus.cancelled ||
      DeathManStatus.expired => false,
      _ => true,
    };
  }

  bool _isProtectionBusy(ProtectionStatus status) {
    return status.modeState != ProtectionModeState.off ||
        status.runtimeState == ProtectionRuntimeState.starting ||
        status.runtimeState == ProtectionRuntimeState.active ||
        status.runtimeState == ProtectionRuntimeState.recovering ||
        status.bleOwner != ProtectionBleOwner.flutter ||
        status.pendingSosCount > 0 ||
        status.pendingTelemetryCount > 0 ||
        status.pendingNativeSosCreateCount > 0 ||
        status.pendingNativeSosCancelCount > 0;
  }

  bool _canAttemptDfuPreparation(FirmwareUpdateCheck check) {
    final hook = prepareForDfuTransfer;
    if (hook == null) {
      return false;
    }
    final blockers = check.eligibility.blockers;
    if (blockers.isEmpty) {
      return false;
    }
    for (final blocker in blockers) {
      if (blocker == FirmwareUpdateBlocker.lowDeviceBattery &&
          check.device.batteryPercentage == null) {
        continue;
      }
      if (blocker == FirmwareUpdateBlocker.noConnectedDevice ||
          blocker == FirmwareUpdateBlocker.protectionRuntimeBusy) {
        continue;
      }
      return false;
    }
    return true;
  }
}

void _debugLog(String message) {
  if (!kDebugMode) {
    return;
  }
  safeSdkDebugPrint(message);
}

class _InstalledVersionVerification {
  const _InstalledVersionVerification({
    required this.matchesTarget,
    required this.latestStatus,
    this.installedVersion,
    this.requiresRecovery = false,
  });

  final bool matchesTarget;
  final String? installedVersion;
  final DeviceStatus latestStatus;
  final bool requiresRecovery;
}
