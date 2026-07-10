import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';

import '../data/datasources_remote/sdk_firmware_remote_data_source.dart';
import 'firmware_dfu_transport.dart';

typedef ProtectionStatusProvider = Future<ProtectionStatus> Function();
typedef DeviceSosStatusProvider = Future<DeviceSosStatus> Function();
typedef PreSosStatusProvider = Future<PublicPreSosStatus?> Function();
typedef AppLifecycleStateProvider = AppLifecycleState? Function();
typedef FirmwareDfuPreparationHook = Future<DeviceStatus> Function({
  required String deviceId,
});
typedef FirmwareDfuConnectionHook = Future<void> Function({
  required String deviceId,
});
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
  });

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

  static const Duration _postDfuVerificationTimeout = Duration(seconds: 180);
  static const Duration _postDfuVerificationPollInterval = Duration(seconds: 5);

  final StreamController<FirmwareUpdateProgress> _progressController =
      StreamController<FirmwareUpdateProgress>.broadcast();
  final Map<String, FirmwareUpdateSession> _sessions =
      <String, FirmwareUpdateSession>{};
  FirmwareUpdateCheck? _lastCheck;

  Future<DeviceFirmwareInfo> getFirmwareInfo({String? deviceId}) async {
    final status = await deviceRepository.refreshDeviceStatus();
    return _firmwareInfoFromStatus(status);
  }

  Future<FirmwareUpdateCheck> checkFirmwareUpdate({
    String? deviceId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) async {
    final status = await deviceRepository.refreshDeviceStatus();
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
      currentVersion: device.currentVersion!,
    );
    final release = response.firmware?.toDomain();
    final releaseEligibility = await evaluateEligibility(
      status: status,
      release: release,
      policy: policy,
    );
    return _rememberCheck(
      FirmwareUpdateCheck(
        device: device,
        updateAvailable: response.updateAvailable && release != null,
        release: release,
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
      _debugLog(
        'OTA_COORDINATOR pre_transfer_prepare_requested '
        'deviceId=${check.device.deviceId} '
        'blockers=${check.eligibility.blockers.map((b) => b.name).join(",")} '
        'battery=${check.device.batteryPercentage?.toString() ?? "unknown"} '
        'threshold=${policy.minDeviceBatteryPercentage}',
      );
      final preparedStatus = await prepareForDfuTransfer!(
        deviceId: check.device.deviceId,
      );
      _debugLog(
        'OTA_COORDINATOR status_refresh_result '
        'deviceId=${preparedStatus.deviceId} '
        'connected=${preparedStatus.connected} '
        'battery=${preparedStatus.approximateBatteryPercentage?.toString() ?? "unknown"} '
        'firmware=${preparedStatus.firmwareVersion ?? "unknown"} '
        'model=${preparedStatus.model ?? "unknown"}',
      );
      check = await _resolveUsableCheck(
        deviceId: preparedStatus.deviceId,
        releaseId: releaseId,
        policy: policy,
        forceRefresh: true,
      );
      release = check.release;
    }
    if (check.eligibility.eligible && release != null) {
      _debugLog(
        'OTA_COORDINATOR pre_transfer_eligibility_passed '
        'deviceId=${check.device.deviceId} '
        'firmware=${check.device.currentVersion ?? "unknown"} '
        'battery=${check.device.batteryPercentage?.toString() ?? "unknown"} '
        'model=${check.device.hardwareModel ?? "unknown"} '
        'release=$releaseId target=${release.version}',
      );
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

    try {
      _emit(session, FirmwareUpdateState.downloading);
      _debugLog(
        'OTA_COORDINATOR artifact_download_start '
        'sessionId=${session.sessionId} release=$releaseId',
      );
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
      _debugLog(
        'OTA_COORDINATOR artifact_hash_verified '
        'sessionId=${session.sessionId} release=$releaseId '
        'bytes=${artifactBytes.length}',
      );

      _emit(session, FirmwareUpdateState.readyToTransfer);
      _emit(session, FirmwareUpdateState.transferring);
      final dfuSub = dfuTransport.watchProgress(session.sessionId).listen(
            (progress) => _emit(
              session,
              progress.state,
              progressPercentage: progress.progressPercentage,
              bytesTransferred: progress.bytesTransferred,
              totalBytes: progress.totalBytes,
            ),
          );
      try {
        await releaseBleForDfuTransfer?.call(deviceId: session.deviceId);
        _debugLog(
          'OTA_COORDINATOR native_dfu_start '
          'sessionId=${session.sessionId} deviceId=${session.deviceId} '
          'release=$releaseId target=${release.version}',
        );
        await dfuTransport.start(
          FirmwareDfuTransferRequest(
            sessionId: session.sessionId,
            deviceId: session.deviceId,
            release: release,
            artifactBytes: artifactBytes,
          ),
        );
        _debugLog(
          'OTA_COORDINATOR native_dfu_completed '
          'sessionId=${session.sessionId} deviceId=${session.deviceId} '
          'target=${release.version}',
        );
      } finally {
        await dfuSub.cancel();
        await restoreBleAfterDfuTransfer?.call(deviceId: session.deviceId);
      }

      _emit(session, FirmwareUpdateState.reconnecting);
      _debugLog(
        'OTA_COORDINATOR post_dfu_reconnect_wait_start '
        'sessionId=${session.sessionId} deviceId=${session.deviceId} '
        'target=${release.version} timeoutSeconds='
        '${_postDfuVerificationTimeout.inSeconds}',
      );
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
      if (error.code == 'cancelled') {
        return _completeSession(
          session,
          state: FirmwareUpdateState.cancelled,
          failureCode: error.code,
          failureMessage: error.message,
        );
      }
      if (error.code == 'recoveryRequired') {
        return _completeSession(
          session,
          state: FirmwareUpdateState.recoveryRequired,
          failureCode: error.code,
          failureMessage: error.message,
        );
      }
      return _completeSession(
        session,
        state: FirmwareUpdateState.failed,
        failureCode: error.code,
        failureMessage: error.message,
      );
    } catch (error) {
      return _completeSession(
        session,
        state: FirmwareUpdateState.failed,
        failureCode: 'firmwareUpdateFailed',
        failureMessage: error.toString(),
      );
    }
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
    await dfuTransport.cancel(sessionId);
    final session = _sessions[sessionId];
    if (session != null) {
      _completeSession(session, state: FirmwareUpdateState.cancelled);
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

    _debugLog(
      'OTA_COORDINATOR eligibility_inputs '
      'deviceId=${status.deviceId} connected=${status.connected} '
      'firmware=${firmwareVersion ?? "unknown"} '
      'battery=${battery?.toString() ?? "unknown"} '
      'threshold=${policy.minDeviceBatteryPercentage} '
      'model=${model ?? "unknown"} '
      'protection=${protection == null ? "unavailable" : "${protection.modeState.name}/${protection.runtimeState.name}/${protection.bleOwner.name}"} '
      'pendingSos=${protection?.pendingSosCount.toString() ?? "unknown"} '
      'pendingTelemetry=${protection?.pendingTelemetryCount.toString() ?? "unknown"} '
      'blockers=${blockers.map((b) => b.name).join(",")}',
    );

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
      messages: List<String>.unmodifiable(
        <String>[...eligibility.messages, message],
      ),
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
      _debugLog(
        'OTA_COORDINATOR post_dfu_verification_attempt '
        'sessionId=${session.sessionId} attempt=$attempt '
        'source=${postDfuStatusRefresh == null ? "repository_refresh" : "forced_firmware_read"} '
        'connected=${status.connected} ready=${status.isReadyForSafety} '
        'firmware=${installed ?? "unknown"} target=$targetVersion',
      );
      if (status.connected && installed == targetVersion) {
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
  debugPrint(message);
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
