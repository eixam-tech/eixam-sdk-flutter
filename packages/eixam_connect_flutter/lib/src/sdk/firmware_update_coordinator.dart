import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';

import '../data/datasources_remote/sdk_firmware_remote_data_source.dart';
import '../device/ble_debug_registry.dart';
import '../firmware_version.dart';
import 'firmware_dfu_transport.dart';

typedef ProtectionStatusProvider = Future<ProtectionStatus> Function();
typedef DeviceSosStatusProvider = Future<DeviceSosStatus> Function();
typedef PreSosStatusProvider = Future<PublicPreSosStatus?> Function();
typedef AppLifecycleStateProvider = AppLifecycleState? Function();
typedef FirmwareDfuPreparationHook = Future<DeviceStatus> Function(
    {required String deviceId});
typedef FirmwareDfuConnectionHook = Future<void> Function(
    {required String deviceId});
typedef FirmwareDfuStatusRefreshHook = Future<DeviceStatus> Function({
  required String deviceId,
  required int attempt,
  required String targetVersion,
});

class FirmwareUpdateCoordinator {
  FirmwareUpdateCoordinator({
    required this.deviceRepository,
    required this.sosRepository,
    required this.deathManRepository,
    required this.remoteDataSource,
    required this.dfuTransport,
    this.protectionStatusProvider,
    this.deviceSosStatusProvider,
    this.preSosStatusProvider,
    this.appLifecycleStateProvider,
    this.prepareForDfuTransfer,
    this.releaseBleForDfuTransfer,
    this.restoreBleAfterDfuTransfer,
    this.postDfuStatusRefresh,
    Duration dfuStallTimeout = _defaultDfuStallTimeout,
    Duration dfuFirstUploadDeadline = _defaultDfuFirstUploadDeadline,
    Duration postDfuVerificationTimeout = _defaultPostDfuVerificationTimeout,
    Duration postDfuVerificationPollInterval =
        _defaultPostDfuVerificationPollInterval,
  })  : _dfuStallTimeout = dfuStallTimeout,
        _dfuFirstUploadDeadline = dfuFirstUploadDeadline,
        _postDfuVerificationTimeout = postDfuVerificationTimeout,
        _postDfuVerificationPollInterval = postDfuVerificationPollInterval;

  final DeviceRepository deviceRepository;
  final SosRepository sosRepository;
  final DeathManRepository deathManRepository;
  final SdkFirmwareRemoteDataSource remoteDataSource;
  final FirmwareDfuTransport dfuTransport;
  final ProtectionStatusProvider? protectionStatusProvider;
  final DeviceSosStatusProvider? deviceSosStatusProvider;
  final PreSosStatusProvider? preSosStatusProvider;
  final AppLifecycleStateProvider? appLifecycleStateProvider;
  final FirmwareDfuPreparationHook? prepareForDfuTransfer;
  final FirmwareDfuConnectionHook? releaseBleForDfuTransfer;
  final FirmwareDfuConnectionHook? restoreBleAfterDfuTransfer;
  final FirmwareDfuStatusRefreshHook? postDfuStatusRefresh;

  static const Duration _defaultPostDfuVerificationTimeout = Duration(
    seconds: 180,
  );
  static const Duration _defaultPostDfuVerificationPollInterval = Duration(
    seconds: 5,
  );

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
  FirmwareUpdateCheck? _lastCheck;

  /// Whether an update or recovery session is still running (not terminal).
  /// Other reboot-causing flows (e.g. the LoRa region provisioning) must hold
  /// off while this is true — a reboot during transfer or post-DFU
  /// verification breaks the update.
  bool get hasActiveSession =>
      _sessions.values.any((session) => session.completedAt == null);

  Future<DeviceFirmwareInfo> getFirmwareInfo({String? deviceId}) async {
    final status = await deviceRepository.refreshDeviceStatus();
    return _firmwareInfoFromStatus(status);
  }

  Future<List<FirmwareRelease>> listFirmwareReleases({String? deviceId}) async {
    final status = await deviceRepository.refreshDeviceStatus();
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
      status = await deviceRepository.refreshDeviceStatus().timeout(
            const Duration(seconds: 12),
          );
    } on TimeoutException {
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
    final actionableRelease = response.updateAvailable &&
            release != null &&
            _firmwareReleaseIsActionable(
              currentVersion: device.currentVersion!,
              targetVersion: release.version,
              allowDowngrade: policy.allowDowngrade,
              explicitTarget: policy.targetReleaseId != null,
            )
        ? release
        : null;
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
  }) async {
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
    final session = FirmwareUpdateSession(
      sessionId: _newSessionId(now),
      deviceId: check.device.deviceId,
      releaseId: releaseId,
      fromVersion: check.device.currentVersion ?? '',
      targetVersion: release?.version ?? '',
      state: FirmwareUpdateState.idle,
      startedAt: now,
    );
    _sessions[session.sessionId] = session;

    if (!check.eligibility.eligible || release == null) {
      return _completeSession(
        session,
        state: FirmwareUpdateState.blocked,
        failureCode: 'firmwareUpdateBlocked',
        failureMessage:
            check.eligibility.blockers.map((blocker) => blocker.name).join(','),
      );
    }

    // Set as soon as the native DFU emits any event; a failure before that
    // cannot have stranded the device in the bootloader, so it must NOT be
    // routed to recovery. Read by _completeTransferFailure on the error paths.
    var nativeDfuEngaged = false;
    try {
      _emit(session, FirmwareUpdateState.downloading);
      final download = await remoteDataSource.prepareDownload(releaseId);
      if (download.downloadUrl.isEmpty) {
        throw const FirmwareUpdateException(
          'artifactMissing',
          'Firmware artifact URL is missing.',
        );
      }
      final expectedHash = download.sha256Hash.isNotEmpty
          ? download.sha256Hash
          : release.sha256Hash;
      if (expectedHash == null || expectedHash.isEmpty) {
        throw const FirmwareUpdateException(
          'hashMissing',
          'Firmware artifact SHA-256 is missing.',
        );
      }
      validateFirmwareArtifactMetadataSize(release.fileSizeBytes);
      final artifactBytes = await remoteDataSource.downloadArtifact(
        download.downloadUrl,
        expectedSizeBytes: release.fileSizeBytes,
      );
      validateFirmwareArtifactDownloadedSize(
        artifactBytes.length,
        expectedSizeBytes: release.fileSizeBytes,
      );

      _emit(session, FirmwareUpdateState.verifying);
      _verifySha256(artifactBytes, expectedHash);

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
        stallMessage: 'The firmware transfer made no upload progress for '
            '${_dfuStallTimeout.inSeconds}s.',
        firstUploadMessage:
            'The firmware upload never started (the device may have entered '
            'the bootloader but could not be reconnected).',
        onEngaged: () => nativeDfuEngaged = true,
      );

      _emit(session, FirmwareUpdateState.reconnecting);
      final verification = await _waitForInstalledVersion(
        session: session,
        targetVersion: release.version,
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
  }) async {
    final stall = Completer<void>();
    Timer? stallTimer;
    Timer? firstUploadTimer;
    var uploadStarted = false;
    void failStalled(String message) {
      if (!stall.isCompleted) {
        stall.completeError(FirmwareUpdateException('dfuStalled', message));
      }
    }

    void armStallWatchdog() {
      stallTimer?.cancel();
      stallTimer = Timer(_dfuStallTimeout, () => failStalled(stallMessage));
    }

    final dfuSub = dfuTransport.watchProgress(session.sessionId).listen((
      progress,
    ) {
      onEngaged?.call();
      final isUploadProgress = progress.progressPercentage != null ||
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
        progress.state,
        progressPercentage: progress.progressPercentage,
        bytesTransferred: progress.bytesTransferred,
        totalBytes: progress.totalBytes,
      );
    });
    try {
      await releaseBleForDfuTransfer?.call(deviceId: request.deviceId);
      // Only arm the deadline if the upload hasn't already begun — defensive
      // against any future transport that could emit progress before start().
      if (!uploadStarted) {
        firstUploadTimer = Timer(
          _dfuFirstUploadDeadline,
          () => failStalled(firstUploadMessage),
        );
      }
      await Future.any(<Future<void>>[
        dfuTransport.start(request),
        stall.future,
      ]);
    } finally {
      stallTimer?.cancel();
      firstUploadTimer?.cancel();
      await dfuSub.cancel();
      // A watchdog fired but the native transfer future is still pending: cancel
      // it so it does not keep flashing behind our back and a subsequent
      // recovery is not rejected with 'alreadyRunning'.
      if (stall.isCompleted) {
        try {
          await dfuTransport.cancel(session.sessionId);
        } catch (_) {}
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
            'The firmware transfer did not finish and the device is now in DFU '
            'recovery mode. Re-flash it to complete the update.',
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

  Future<void> cancelFirmwareUpdate(String sessionId) async {
    // Once flashing has begun the bootloader has already erased the running
    // app, so aborting cannot restore the previous firmware — it only strands
    // the device in DFU mode. Refuse; the transfer must be allowed to finish.
    if (_isPastPointOfNoReturn(_sessions[sessionId]?.state)) {
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
  }) async {
    final now = DateTime.now();
    final session = FirmwareUpdateSession(
      sessionId: _newSessionId(now),
      deviceId: bootloaderDeviceId,
      releaseId: releaseId,
      fromVersion: '',
      targetVersion: targetVersion,
      state: FirmwareUpdateState.idle,
      startedAt: now,
    );
    _sessions[session.sessionId] = session;
    try {
      _emit(session, FirmwareUpdateState.downloading);
      final download = await remoteDataSource.prepareDownload(releaseId);
      if (download.downloadUrl.isEmpty) {
        throw const FirmwareUpdateException(
          'artifactMissing',
          'Firmware artifact URL is missing.',
        );
      }
      final artifactBytes = await remoteDataSource.downloadArtifact(
        download.downloadUrl,
      );
      if (download.sha256Hash.isNotEmpty) {
        _emit(session, FirmwareUpdateState.verifying);
        _verifySha256(artifactBytes, download.sha256Hash);
      }
      final release = FirmwareRelease(
        releaseId: releaseId,
        version: targetVersion,
        sha256Hash: download.sha256Hash.isEmpty ? null : download.sha256Hash,
      );
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
        request: FirmwareDfuTransferRequest(
          sessionId: session.sessionId,
          deviceId: bootloaderDeviceId,
          release: release,
          artifactBytes: artifactBytes,
          forceDfu: true,
        ),
        stallMessage: 'The recovery transfer made no upload progress for '
            '${_dfuStallTimeout.inSeconds}s.',
        firstUploadMessage:
            'The recovery upload never started (the bootloader could not be '
            'reconnected).',
      );
      return _completeSession(session, state: FirmwareUpdateState.completed);
    } on FirmwareUpdateException catch (error) {
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
    if (battery == null || battery < policy.minDeviceBatteryPercentage) {
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
    await _progressController.close();
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
  }) async {
    final deadline = DateTime.now().add(_postDfuVerificationTimeout);
    var attempt = 0;
    DeviceStatus? latest;
    while (true) {
      attempt += 1;
      final now = DateTime.now();
      _emit(
        session,
        latest?.connected == true
            ? FirmwareUpdateState.verifyingInstalledVersion
            : FirmwareUpdateState.reconnecting,
      );
      final status = postDfuStatusRefresh == null
          ? await deviceRepository.refreshDeviceStatus()
          : await postDfuStatusRefresh!(
              deviceId: session.deviceId,
              attempt: attempt,
              targetVersion: targetVersion,
            );
      latest = status;
      final installed = status.firmwareVersion?.trim();
      final matches = _firmwareVersionMatches(installed, targetVersion);
      if (status.connected && matches) {
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

  /// Whether the device's [installed] firmware string represents [target].
  ///
  /// The GATT firmware-revision string can carry build metadata (a git hash
  /// appended on a dot boundary, e.g. `2.7.25.942a98e`), NUL/whitespace padding,
  /// a `v` prefix, or differ in case from the backend release version. A strict
  /// `==` check reports a false "still on the previous version" even when the
  /// DFU succeeded. This tolerates those formatting differences while never
  /// treating a genuinely different version — including the same semver with a
  /// different build hash — as a match, so a failed DFU is still reported failed.
  bool _firmwareVersionMatches(String? installed, String target) {
    final a = _normalizeFirmwareVersion(installed);
    final b = _normalizeFirmwareVersion(target);
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    // One side may omit build metadata that the other carries as a dot-suffix
    // (e.g. release `2.7.25` vs device `2.7.25.942a98e`). Only match across a
    // dot boundary so `2.7.25` never matches `2.7.26` and same-semver builds
    // with a different hash stay distinct.
    return a.startsWith('$b.') || b.startsWith('$a.');
  }

  String _normalizeFirmwareVersion(String? version) {
    return normalizeEixamFirmwareVersion(version);
  }

  String _backendComparableFirmwareVersion(String version) {
    final normalized = _normalizeFirmwareVersion(version);
    final semver = RegExp(r'^(\d+\.\d+\.\d+)(?:\.|$)').firstMatch(normalized);
    return semver?.group(1) ?? normalized;
  }

  bool _firmwareReleaseIsActionable({
    required String currentVersion,
    required String targetVersion,
    required bool allowDowngrade,
    required bool explicitTarget,
  }) {
    if (_firmwareVersionMatches(currentVersion, targetVersion)) {
      return false;
    }
    if (explicitTarget) {
      return true;
    }
    final current = _parseComparableSemver(currentVersion);
    final target = _parseComparableSemver(targetVersion);
    if (current == null || target == null) {
      return !allowDowngrade;
    }
    final comparison = _compareSemver(target, current);
    return allowDowngrade ? comparison < 0 : comparison > 0;
  }

  List<int>? _parseComparableSemver(String version) {
    final comparable = _backendComparableFirmwareVersion(version);
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(comparable);
    if (match == null) {
      return null;
    }
    return <int>[
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ];
  }

  int _compareSemver(List<int> candidate, List<int> base) {
    for (var index = 0; index < 3; index++) {
      if (candidate[index] != base[index]) {
        return candidate[index].compareTo(base[index]);
      }
    }
    return 0;
  }

  FirmwareUpdateSession _completeSession(
    FirmwareUpdateSession session, {
    required FirmwareUpdateState state,
    String? failureCode,
    String? failureMessage,
  }) {
    final next = session.copyWith(
      state: state,
      completedAt: DateTime.now(),
      failureCode: failureCode,
      failureMessage: failureMessage,
    );
    _sessions[session.sessionId] = next;
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
        _sessions[session.sessionId] = tracked.copyWith(state: state);
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
      SosState.failed =>
        false,
      _ => true,
    };
  }

  bool _isBlockingDeathManStatus(DeathManStatus status) {
    return switch (status) {
      DeathManStatus.confirmedSafe ||
      DeathManStatus.cancelled ||
      DeathManStatus.expired =>
        false,
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
