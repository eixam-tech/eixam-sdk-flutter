import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_remote/sdk_network_psk_remote_data_source.dart';
import '../device/eixam_ble_command.dart';
import '../firmware_version.dart';
import 'device_assignment_verifier.dart';
import 'provisioning_command_result.dart';
import 'softsim_provisioning.dart';
import 'softsim_transport.dart';
import 'strict_device_provisioning_config.dart';

final class ProvisioningFirmwarePolicy {
  const ProvisioningFirmwarePolicy.current();

  static const String certifiedBaselineVersion = '2.7.37';
  static const String unprovisionBaselineVersion = '2.7.53';

  bool supports(String? version) => _atLeast(version, certifiedBaselineVersion);

  bool supportsUnprovision(String? version) =>
      _atLeast(version, unprovisionBaselineVersion);

  static bool _atLeast(String? version, String baseline) {
    if (version == null) return false;
    final actualParts = _parts(version);
    final baselineParts = _parts(baseline);
    if (actualParts == null || baselineParts == null) return false;
    for (var index = 0; index < 3; index++) {
      if (actualParts[index] != baselineParts[index]) {
        return actualParts[index] > baselineParts[index];
      }
    }
    return true;
  }

  static List<int>? _parts(String value) {
    return parseEixamFirmwareSemanticCore(value);
  }
}

final class ProvisioningRebootException implements Exception {
  const ProvisioningRebootException();
}

/// Validates the disconnect caused by firmware's 1.5 second reboot schedule.
/// Timing starts at the 0x22 write, not write completion: CMD is
/// write-with-response, so the TAG can drop BLE before the ATT ACK settles.
/// A thrown write is still success when the disconnect window is valid.
/// The 900 ms lower bound still rejects an immediate transport loss; the
/// 12 second upper bound covers Android LINK_SUPERVISION_TIMEOUT after the
/// scheduled reboot (often 5–8 s after the radio dies).
final class ProvisioningRebootDisconnectPolicy {
  const ProvisioningRebootDisconnectPolicy({
    this.minimumDelay = const Duration(milliseconds: 900),
    this.maximumDelay = const Duration(seconds: 12),
    this.clock = DateTime.now,
  });

  final Duration minimumDelay;
  final Duration maximumDelay;
  final DateTime Function() clock;

  Future<void> writeAndAwait({
    required Future<void> Function() writeReboot,
    required Stream<DeviceStatus> statuses,
    bool Function()? alreadyDisconnected,
    void Function(String event)? diagnosticLog,
  }) async {
    final disconnect = Completer<DateTime>();
    final subscription = statuses.listen((status) {
      if (!status.connected && !disconnect.isCompleted) {
        diagnosticLog?.call(
          'PROVISIONING_REBOOT disconnect_observed=true',
        );
        disconnect.complete(clock());
      }
    });
    try {
      diagnosticLog?.call(
        'PROVISIONING_REBOOT command_write_started=true',
      );
      final writeStartedAt = clock();
      unawaited(
        writeReboot().then(
          (_) {
            diagnosticLog?.call(
              'PROVISIONING_REBOOT command_write_completed=true',
            );
          },
          onError: (Object error) {
            diagnosticLog?.call(
              'PROVISIONING_REBOOT command_write_failed=true',
            );
          },
        ),
      );
      DateTime disconnectedAt;
      try {
        disconnectedAt = await disconnect.future.timeout(maximumDelay);
      } on TimeoutException {
        if (alreadyDisconnected?.call() == true) {
          diagnosticLog?.call(
            'PROVISIONING_REBOOT disconnect_timing_bucket=valid_unobserved',
          );
          return;
        }
        diagnosticLog?.call(
          'PROVISIONING_REBOOT disconnect_timing_bucket=timeout',
        );
        throw const ProvisioningRebootException();
      }
      final elapsed = disconnectedAt.difference(writeStartedAt);
      if (elapsed < minimumDelay) {
        diagnosticLog?.call(
          'PROVISIONING_REBOOT disconnect_timing_bucket=too_early',
        );
        throw const ProvisioningRebootException();
      }
      if (elapsed > maximumDelay) {
        diagnosticLog?.call(
          'PROVISIONING_REBOOT disconnect_timing_bucket=timeout',
        );
        throw const ProvisioningRebootException();
      }
      diagnosticLog?.call(
        'PROVISIONING_REBOOT disconnect_timing_bucket=valid',
      );
    } finally {
      await subscription.cancel();
    }
  }
}

final class DeviceProvisioningCoordinator {
  DeviceProvisioningCoordinator({
    required this.statusProvider,
    required this.liveStatusProvider,
    required this.runtimeStatusProvider,
    required this.countryIsoProvider,
    required this.pskSource,
    required this.configSource,
    required this.assignmentVerifier,
    required this.assignmentCreator,
    required this.backendUrl,
    required this.writeCommand,
    required Stream<List<int>> incomingPackets,
    required Stream<DeviceStatus> deviceStatusChanges,
    required this.reboot,
    required this.reconnectSameDevice,
    required this.acquireReconnectOwnership,
    required this.releaseReconnectOwnership,
    this.diagnosticLog,
    this.firmwarePolicy = const ProvisioningFirmwarePolicy.current(),
    this.softSimRejectionObservationInterval =
        const Duration(milliseconds: 250),
    this.unprovisionVerifyAttempts = 5,
    this.unprovisionVerifyRetryDelay = const Duration(milliseconds: 400),
    this.postRebootVerifyAttempts = 15,
    this.postRebootVerifyRetryDelay = const Duration(seconds: 1),
    Future<void> Function(Duration duration)? delay,
  })  : _packets = incomingPackets.asBroadcastStream(),
        _delay = delay ?? _defaultDelay {
    _ackCoordinator = ProvisioningAckCoordinator(packets: _packets);
    _deviceStatusSubscription = deviceStatusChanges.listen(_onDeviceStatus);
  }

  final Future<DeviceStatus> Function() statusProvider;
  final Future<DeviceStatus> Function() liveStatusProvider;
  final Future<DeviceRuntimeStatus> Function() runtimeStatusProvider;
  final Future<String> Function() countryIsoProvider;
  final SdkNetworkPskRemoteDataSource pskSource;
  final StrictDeviceProvisioningConfigSource configSource;
  final DeviceAssignmentVerifier assignmentVerifier;
  final DeviceAssignmentCreator assignmentCreator;
  final String backendUrl;
  final Future<void> Function(EixamDeviceCommand command) writeCommand;
  final Future<void> Function() reboot;
  final Future<bool> Function(String platformDeviceId) reconnectSameDevice;
  final Future<void> Function() acquireReconnectOwnership;
  final void Function() releaseReconnectOwnership;
  final void Function(String event)? diagnosticLog;
  final ProvisioningFirmwarePolicy firmwarePolicy;
  final Duration softSimRejectionObservationInterval;
  final int unprovisionVerifyAttempts;
  final Duration unprovisionVerifyRetryDelay;
  final int postRebootVerifyAttempts;
  final Duration postRebootVerifyRetryDelay;
  final Future<void> Function(Duration duration) _delay;
  final Stream<List<int>> _packets;
  late final ProvisioningAckCoordinator _ackCoordinator;
  late final StreamSubscription<DeviceStatus> _deviceStatusSubscription;
  final StreamController<DeviceProvisioningState> _stateController =
      StreamController<DeviceProvisioningState>.broadcast();
  DeviceProvisioningState _state = const DeviceProvisioningState.idle();
  Future<DeviceReadyResult>? _inFlight;
  Future<DeviceUnprovisionResult>? _unprovisionInFlight;
  _ProvisioningOperation? _operation;
  String? _activeDeviceId;
  bool _expectingRebootDisconnect = false;
  bool _disposed = false;

  bool get isBusy => _inFlight != null || _unprovisionInFlight != null;

  Stream<DeviceProvisioningState> watchState() async* {
    yield _state;
    yield* _stateController.stream;
  }

  Future<DeviceReadyResult> ensureReady() {
    if (_disposed) {
      return Future<DeviceReadyResult>.value(_cancelledResult());
    }
    if (_unprovisionInFlight != null) {
      return Future<DeviceReadyResult>.value(
        const DeviceReadyResult.failed(
          DeviceReadyFailure(
            code: DeviceReadyFailureCode.deviceCommunicationInterrupted,
            retryable: true,
          ),
        ),
      );
    }
    return _inFlight ??= _startOperation();
  }

  Future<DeviceUnprovisionResult> unprovision() {
    if (_disposed) {
      return Future<DeviceUnprovisionResult>.value(
        const DeviceUnprovisionResult.failed(
          DeviceUnprovisionFailure(
            code: DeviceUnprovisionFailureCode.deviceCommunicationInterrupted,
            retryable: true,
          ),
        ),
      );
    }
    if (_inFlight != null || _unprovisionInFlight != null) {
      return Future<DeviceUnprovisionResult>.value(
        const DeviceUnprovisionResult.failed(
          DeviceUnprovisionFailure(
            code: DeviceUnprovisionFailureCode.busy,
            retryable: true,
          ),
        ),
      );
    }
    return _unprovisionInFlight ??= _startUnprovision();
  }

  Future<DeviceUnprovisionResult> _startUnprovision() {
    final operation = _ProvisioningOperation();
    _operation = operation;
    return _runUnprovision(operation).whenComplete(() {
      if (identical(_operation, operation)) _operation = null;
      _unprovisionInFlight = null;
    });
  }

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

  Future<DeviceReadyResult> _startOperation() {
    final operation = _ProvisioningOperation();
    _operation = operation;
    return _run(operation).whenComplete(() {
      if (identical(_operation, operation)) _operation = null;
      _inFlight = null;
    });
  }

  Future<DeviceUnprovisionResult> _runUnprovision(
    _ProvisioningOperation operation,
  ) async {
    try {
      final initialStatus = await statusProvider();
      _check(operation);
      if (!initialStatus.connected || initialStatus.nodeId == null) {
        return _unprovisionFail(
          DeviceUnprovisionFailureCode.notConnected,
          retryable: true,
        );
      }
      _activeDeviceId = initialStatus.deviceId;
      final initialRuntime = await runtimeStatusProvider();
      _check(operation);
      if (initialRuntime.nodeId != initialStatus.nodeId) {
        return _unprovisionFail(
          DeviceUnprovisionFailureCode.identityMismatch,
          retryable: false,
        );
      }

      final liveStatus = await liveStatusProvider();
      _check(operation);
      if (!liveStatus.connected ||
          liveStatus.deviceId != initialStatus.deviceId) {
        return _unprovisionFail(
          DeviceUnprovisionFailureCode.deviceCommunicationInterrupted,
          retryable: true,
        );
      }
      if (!firmwarePolicy.supportsUnprovision(liveStatus.firmwareVersion)) {
        return _unprovisionFail(
          DeviceUnprovisionFailureCode.firmwareUpdateRequired,
          retryable: false,
        );
      }

      final ack = await _ackCoordinator.run(
        expectedOpcode: 0x25,
        allowNoChange: true,
        isCancelled: () => operation.cancelled,
        write: () => _write(operation, EixamDeviceCommand.unprovision()),
      );
      _check(operation);
      final alreadyVirgin =
          ack.outcome == ProvisioningCommandOutcome.okNoChange;

      // 0x23 can already report PROVISIONED=0 from disk while the Eixam
      // stack is still in RAM. Always reboot after OK / OK_NOCHANGE, even
      // when the TAG looked unprovisioned before the write.
      operation.rebootBoundaryStarted = true;
      try {
        await acquireReconnectOwnership();
        _check(operation);
        _expectingRebootDisconnect = true;
        try {
          diagnosticLog?.call('UNPROVISION reboot_started=true');
          await reboot();
          _check(operation);
          diagnosticLog?.call('UNPROVISION explicit_reconnect_started=true');
          if (!await reconnectSameDevice(initialStatus.deviceId)) {
            diagnosticLog?.call('UNPROVISION explicit_reconnect_result=failed');
            return _unprovisionFail(
              DeviceUnprovisionFailureCode.reconnectFailed,
              retryable: true,
            );
          }
          diagnosticLog?.call(
            'UNPROVISION explicit_reconnect_result=connected',
          );
        } finally {
          _expectingRebootDisconnect = false;
        }
        return await _verifyAfterUnprovisionReconnect(
          operation: operation,
          initialStatus: initialStatus,
          initialRuntime: initialRuntime,
          alreadyVirgin: alreadyVirgin,
        );
      } finally {
        releaseReconnectOwnership();
      }
    } on ProvisioningOperationCancelledException {
      return _unprovisionFail(
        DeviceUnprovisionFailureCode.deviceCommunicationInterrupted,
        retryable: true,
      );
    } on ProvisioningCommandRejectedException {
      return _unprovisionFail(
        DeviceUnprovisionFailureCode.deviceConfigurationRejected,
        retryable: true,
      );
    } on ProvisioningCommandTimeoutException {
      return _unprovisionFail(
        DeviceUnprovisionFailureCode.deviceCommunicationTimeout,
        retryable: true,
      );
    } on ProvisioningCommunicationInterruptedException {
      return _unprovisionFail(
        DeviceUnprovisionFailureCode.deviceCommunicationInterrupted,
        retryable: true,
      );
    } on ProvisioningConnectionEpochInvalidException {
      return _unprovisionFail(
        DeviceUnprovisionFailureCode.deviceCommunicationInterrupted,
        retryable: true,
      );
    } on ProvisioningRebootException {
      return _unprovisionFail(
        DeviceUnprovisionFailureCode.rebootFailed,
        retryable: true,
      );
    } on DeviceException {
      return _unprovisionFail(
        DeviceUnprovisionFailureCode.deviceCommunicationInterrupted,
        retryable: true,
      );
    } catch (_) {
      return _unprovisionFail(
        DeviceUnprovisionFailureCode.internal,
        retryable: true,
      );
    }
  }

  DeviceUnprovisionResult _unprovisionFail(
    DeviceUnprovisionFailureCode code, {
    required bool retryable,
  }) {
    diagnosticLog?.call('UNPROVISION failure_code=${code.name}');
    return DeviceUnprovisionResult.failed(
      DeviceUnprovisionFailure(code: code, retryable: retryable),
    );
  }

  Future<DeviceUnprovisionResult> _verifyAfterUnprovisionReconnect({
    required _ProvisioningOperation operation,
    required DeviceStatus initialStatus,
    required DeviceRuntimeStatus initialRuntime,
    required bool alreadyVirgin,
  }) async {
    DeviceUnprovisionFailureCode? lastCode;
    for (var attempt = 1; attempt <= unprovisionVerifyAttempts; attempt++) {
      _check(operation);
      try {
        final finalStatus = await statusProvider();
        _check(operation);
        if (!finalStatus.connected) {
          lastCode = DeviceUnprovisionFailureCode.reconnectFailed;
          diagnosticLog?.call(
            'UNPROVISION verify_retry attempt=$attempt reason=not_connected',
          );
          await _delayBeforeUnprovisionVerifyRetry(attempt);
          continue;
        }
        if (finalStatus.deviceId != initialStatus.deviceId) {
          return _unprovisionFail(
            DeviceUnprovisionFailureCode.identityMismatch,
            retryable: false,
          );
        }
        final finalRuntime = await runtimeStatusProvider();
        _check(operation);
        if (finalRuntime.nodeId == 0) {
          lastCode =
              DeviceUnprovisionFailureCode.deviceCommunicationInterrupted;
          diagnosticLog?.call(
            'UNPROVISION verify_retry attempt=$attempt reason=node_id_unready',
          );
          await _delayBeforeUnprovisionVerifyRetry(attempt);
          continue;
        }
        if (finalRuntime.nodeId != initialRuntime.nodeId) {
          return _unprovisionFail(
            DeviceUnprovisionFailureCode.identityMismatch,
            retryable: false,
          );
        }
        if (finalRuntime.isProvisioned) {
          lastCode = DeviceUnprovisionFailureCode.verificationFailed;
          diagnosticLog?.call(
            'UNPROVISION verify_retry attempt=$attempt '
            'reason=still_provisioned',
          );
          await _delayBeforeUnprovisionVerifyRetry(attempt);
          continue;
        }
        diagnosticLog?.call(
          alreadyVirgin
              ? 'UNPROVISION verified_already_unprovisioned=true'
              : 'UNPROVISION verified_unprovisioned=true',
        );
        return alreadyVirgin
            ? DeviceUnprovisionResult.alreadyUnprovisioned(finalStatus)
            : DeviceUnprovisionResult.unprovisioned(finalStatus);
      } on ProvisioningOperationCancelledException {
        rethrow;
      } on DeviceException {
        lastCode = DeviceUnprovisionFailureCode.deviceCommunicationInterrupted;
        diagnosticLog?.call(
          'UNPROVISION verify_retry attempt=$attempt reason=device_exception',
        );
        await _delayBeforeUnprovisionVerifyRetry(attempt);
      }
    }
    return _unprovisionFail(
      lastCode ?? DeviceUnprovisionFailureCode.deviceCommunicationInterrupted,
      retryable: true,
    );
  }

  Future<void> _delayBeforeUnprovisionVerifyRetry(int attempt) async {
    if (attempt >= unprovisionVerifyAttempts) {
      return;
    }
    await _delay(unprovisionVerifyRetryDelay);
  }

  /// GATT/0x23 is often unread after the 1.5 s scheduled reboot plus boot.
  /// Stay on [DeviceProvisioningPhase.verifying] until the TAG is actually
  /// readable. A single-shot "not connected" is not identity mismatch.
  Future<DeviceReadyResult> _verifyAfterProvisioningReconnect({
    required _ProvisioningOperation operation,
    required DeviceStatus initialStatus,
    required DeviceRuntimeStatus initialRuntime,
    required StrictDeviceProvisioningConfig config,
  }) async {
    _emit(DeviceProvisioningPhase.verifying, progress: 0.9);
    diagnosticLog?.call('PROVISIONING_REBOOT verification_started=true');
    DeviceReadyFailureCode? lastCode;
    var lastRetryable = true;
    for (var attempt = 1; attempt <= postRebootVerifyAttempts; attempt++) {
      _check(operation);
      try {
        final finalStatus = await statusProvider();
        _check(operation);
        if (!finalStatus.connected) {
          lastCode = DeviceReadyFailureCode.reconnectFailed;
          lastRetryable = true;
          diagnosticLog?.call(
            'PROVISIONING_REBOOT verify_retry attempt=$attempt '
            'reason=not_connected',
          );
          await _delayBeforePostRebootVerifyRetry(attempt);
          continue;
        }
        if (finalStatus.deviceId != initialStatus.deviceId) {
          return _fail(DeviceReadyFailureCode.identityMismatch,
              retryable: false);
        }
        final finalRuntime = await runtimeStatusProvider();
        _check(operation);
        if (finalRuntime.nodeId == 0) {
          lastCode = DeviceReadyFailureCode.deviceCommunicationInterrupted;
          lastRetryable = true;
          diagnosticLog?.call(
            'PROVISIONING_REBOOT verify_retry attempt=$attempt '
            'reason=node_id_unready',
          );
          await _delayBeforePostRebootVerifyRetry(attempt);
          continue;
        }
        if (finalRuntime.nodeId != initialRuntime.nodeId) {
          return _fail(DeviceReadyFailureCode.identityMismatch,
              retryable: false);
        }
        final verified = finalRuntime.isProvisioned &&
            finalRuntime.region == config.regionCode &&
            !finalRuntime.usePreset &&
            finalRuntime.txEnabled &&
            finalRuntime.meshSpreadingFactor == config.tel.spreadingFactor;
        if (!verified) {
          lastCode = DeviceReadyFailureCode.verificationFailed;
          lastRetryable = true;
          diagnosticLog?.call(
            'PROVISIONING_REBOOT verify_retry attempt=$attempt '
            'reason=runtime_not_ready',
          );
          await _delayBeforePostRebootVerifyRetry(attempt);
          continue;
        }
        final assigned = await _createAssignment(
          operation,
          nodeId: finalRuntime.nodeId,
          status: finalStatus,
          reason: 'successful_initial_provisioning',
        );
        if (assigned) {
          final readback =
              await _lookupAssignment(operation, finalRuntime.nodeId);
          diagnosticLog?.call(
            'ASSIGNMENT_READBACK result=${switch (readback) {
              _AssignmentLookup.matched => 'matched',
              _AssignmentLookup.missing => 'not_found',
              _AssignmentLookup.unavailable => 'backend_unavailable',
            }}',
          );
          return _readyProvisioned(
            finalStatus,
            assignmentVerified: readback == _AssignmentLookup.matched,
          );
        }
        return _readyProvisioned(
          finalStatus,
          assignmentVerified: false,
        );
      } on ProvisioningOperationCancelledException {
        rethrow;
      } on DeviceException {
        lastCode = DeviceReadyFailureCode.deviceCommunicationTimeout;
        lastRetryable = true;
        diagnosticLog?.call(
          'PROVISIONING_REBOOT verify_retry attempt=$attempt '
          'reason=device_exception',
        );
        await _delayBeforePostRebootVerifyRetry(attempt);
      }
    }
    return _fail(
      lastCode ?? DeviceReadyFailureCode.deviceCommunicationInterrupted,
      retryable: lastRetryable,
    );
  }

  Future<void> _delayBeforePostRebootVerifyRetry(int attempt) async {
    if (attempt >= postRebootVerifyAttempts) {
      return;
    }
    await _delay(postRebootVerifyRetryDelay);
  }

  Future<DeviceReadyResult> _run(_ProvisioningOperation operation) async {
    try {
      _emit(DeviceProvisioningPhase.checkingDevice);
      final initialStatus = await statusProvider();
      _check(operation);
      if (!initialStatus.connected) {
        return _fail(DeviceReadyFailureCode.notConnected, retryable: true);
      }
      if (initialStatus.nodeId == null) {
        return _fail(DeviceReadyFailureCode.missingNodeIdentity,
            retryable: true);
      }
      _activeDeviceId = initialStatus.deviceId;
      final initialRuntime = await runtimeStatusProvider();
      _check(operation);
      if (initialRuntime.nodeId != initialStatus.nodeId) {
        return _fail(DeviceReadyFailureCode.identityMismatch, retryable: false);
      }
      if (initialRuntime.isProvisioned) {
        // 0x23 proves structural config.bin validity. Current-app assignment
        // is claimed when missing, but a connected provisioned TAG stays
        // usable even if the registry is down or the row cannot be proven.
        final assigned = await _ensureCurrentAssignment(
          operation,
          nodeId: initialRuntime.nodeId,
          status: initialStatus,
        );
        return _readyProvisioned(
          initialStatus,
          assignmentVerified: assigned,
        );
      }

      _emit(DeviceProvisioningPhase.fetchingConfiguration);
      final countryIso = await countryIsoProvider();
      _check(operation);
      final config = await configSource.fetch(countryIso: countryIso);
      _check(operation);

      // Force a live Device Information read immediately before obtaining the
      // PSK and issuing the first mutating provisioning frame.
      final liveStatus = await liveStatusProvider();
      _check(operation);
      if (!liveStatus.connected ||
          liveStatus.deviceId != initialStatus.deviceId) {
        return _fail(DeviceReadyFailureCode.deviceCommunicationInterrupted,
            retryable: true);
      }
      if (!firmwarePolicy.supports(liveStatus.firmwareVersion)) {
        _emit(DeviceProvisioningPhase.firmwareUpdateRequired);
        return const DeviceReadyResult.failed(DeviceReadyFailure(
          code: DeviceReadyFailureCode.firmwareUpdateRequired,
          retryable: false,
        ));
      }

      final psk = await pskSource.fetchEffectivePsk();
      _check(operation);
      try {
        // PSK acquisition is deliberately after the first live gate. Repeat
        // the live read after that network await so mutation is guarded by
        // firmware metadata obtained immediately before frame construction.
        final mutationStatus = await liveStatusProvider();
        _check(operation);
        if (!mutationStatus.connected ||
            mutationStatus.deviceId != initialStatus.deviceId) {
          return _fail(DeviceReadyFailureCode.deviceCommunicationInterrupted,
              retryable: true);
        }
        if (!firmwarePolicy.supports(mutationStatus.firmwareVersion)) {
          _emit(DeviceProvisioningPhase.firmwareUpdateRequired);
          return const DeviceReadyResult.failed(DeviceReadyFailure(
            code: DeviceReadyFailureCode.firmwareUpdateRequired,
            retryable: false,
          ));
        }
        final softSim = buildSoftSim(
          psk: psk.bytes,
          nodeId: initialRuntime.nodeId,
          backendUrl: backendUrl,
          telSpreadingFactor: config.tel.spreadingFactor,
          sosPowerDbm: config.sos.txPowerDbm,
        );
        try {
          _emit(DeviceProvisioningPhase.provisioning, progress: 0);
          await SoftSimProvisioningTransport(
            write: (command) => _write(operation, command),
            packets: _packets,
            ackCoordinator: _ackCoordinator,
            rejectionObservationInterval: softSimRejectionObservationInterval,
            isCancelled: () => operation.cancelled,
            cancelled: operation.whenCancelled,
          ).transfer(softSim);
          _check(operation);

          _emit(DeviceProvisioningPhase.applyingRadioConfiguration,
              progress: 0.5);
          await _runAckCommand(operation,
              expectedOpcode: 0x20,
              allowNoChange: true,
              label: 'APPLY RADIO CONFIG',
              bytes: encodeFullRadioConfig(config));
          await _runAckCommand(operation,
              expectedOpcode: 0x21,
              label: 'APPLY SOS RADIO CONFIG',
              bytes: encodeSosRadioConfig(config));
          _check(operation);

          operation.rebootBoundaryStarted = true;
          try {
            await acquireReconnectOwnership();
            _check(operation);
            _emit(DeviceProvisioningPhase.rebooting, progress: 0.7);
            // Stay armed through verify. GATT often drops again while the
            // TAG is still booting; that must not cancel the operation.
            _expectingRebootDisconnect = true;
            try {
              await reboot();
              _check(operation);
              _emit(DeviceProvisioningPhase.reconnecting, progress: 0.8);
              diagnosticLog?.call(
                'PROVISIONING_REBOOT explicit_reconnect_started=true',
              );
              if (!await reconnectSameDevice(initialStatus.deviceId)) {
                diagnosticLog?.call(
                  'PROVISIONING_REBOOT explicit_reconnect_result=failed',
                );
                return _fail(DeviceReadyFailureCode.reconnectFailed,
                    retryable: true);
              }
              diagnosticLog?.call(
                'PROVISIONING_REBOOT explicit_reconnect_result=connected',
              );
              return await _verifyAfterProvisioningReconnect(
                operation: operation,
                initialStatus: initialStatus,
                initialRuntime: initialRuntime,
                config: config,
              );
            } finally {
              _expectingRebootDisconnect = false;
            }
          } finally {
            releaseReconnectOwnership();
          }
        } finally {
          softSim.dispose();
        }
      } finally {
        psk.dispose();
      }
    } on ProvisioningOperationCancelledException {
      return _cancelledResult();
    } on ProvisioningMaterialException catch (error) {
      return _fail(
        error.code == ProvisioningMaterialFailureCode.timeout
            ? DeviceReadyFailureCode.backendTimeout
            : error.code == ProvisioningMaterialFailureCode.malformedResponse
                ? DeviceReadyFailureCode.configurationInvalid
                : DeviceReadyFailureCode.configurationUnavailable,
        retryable: error.code == ProvisioningMaterialFailureCode.timeout,
      );
    } on ProvisioningContractException {
      return _fail(DeviceReadyFailureCode.configurationInvalid,
          retryable: false);
    } on NetworkException catch (error) {
      final timeout = error.code == 'E_SDK_HTTP_TIMEOUT';
      return _fail(
          timeout
              ? DeviceReadyFailureCode.backendTimeout
              : DeviceReadyFailureCode.configurationUnavailable,
          retryable: timeout);
    } on ProvisioningCommandRejectedException {
      return _fail(DeviceReadyFailureCode.deviceConfigurationRejected,
          retryable: false);
    } on ProvisioningCommandTimeoutException {
      return _fail(DeviceReadyFailureCode.deviceCommunicationTimeout,
          retryable: true);
    } on ProvisioningCommunicationInterruptedException catch (_) {
      return _fail(DeviceReadyFailureCode.deviceCommunicationInterrupted,
          retryable: true);
    } on ProvisioningConnectionEpochInvalidException catch (_) {
      return _fail(DeviceReadyFailureCode.deviceCommunicationInterrupted,
          retryable: true);
    } on SoftSimTransportUncertainException {
      return _fail(DeviceReadyFailureCode.deviceCommunicationInterrupted,
          retryable: true);
    } on ProvisioningRebootException {
      return _fail(DeviceReadyFailureCode.rebootFailed, retryable: true);
    } on DeviceException catch (error) {
      return _fail(
        error.code == 'E_DEVICE_STATUS_TIMEOUT'
            ? DeviceReadyFailureCode.deviceCommunicationTimeout
            : DeviceReadyFailureCode.deviceCommunicationInterrupted,
        retryable: true,
      );
    } on TimeoutException {
      return _fail(DeviceReadyFailureCode.deviceCommunicationTimeout,
          retryable: true);
    } catch (_) {
      return _fail(DeviceReadyFailureCode.internal, retryable: true);
    }
  }

  Future<void> _runAckCommand(
    _ProvisioningOperation operation, {
    required int expectedOpcode,
    required String label,
    required List<int> bytes,
    bool allowNoChange = false,
  }) async {
    await _ackCoordinator.run(
      expectedOpcode: expectedOpcode,
      allowNoChange: allowNoChange,
      isCancelled: () => operation.cancelled,
      write: () => _write(
        operation,
        EixamDeviceCommand.provisioningFrame(
          label: label,
          bytes: bytes,
          secret: false,
        ),
      ),
    );
  }

  Future<bool> _ensureCurrentAssignment(
    _ProvisioningOperation operation, {
    required int nodeId,
    required DeviceStatus status,
  }) async {
    switch (await _lookupAssignment(operation, nodeId)) {
      case _AssignmentLookup.matched:
        return true;
      case _AssignmentLookup.unavailable:
      case _AssignmentLookup.missing:
        break;
    }
    if (!await _createAssignment(
      operation,
      nodeId: nodeId,
      status: status,
      reason: 'provisioned_assignment_missing',
    )) {
      return false;
    }
    switch (await _lookupAssignment(operation, nodeId)) {
      case _AssignmentLookup.matched:
        diagnosticLog?.call('ASSIGNMENT_READBACK result=matched');
        return true;
      case _AssignmentLookup.missing:
        diagnosticLog?.call('ASSIGNMENT_READBACK result=not_found');
        return false;
      case _AssignmentLookup.unavailable:
        diagnosticLog?.call('ASSIGNMENT_READBACK result=backend_unavailable');
        return false;
    }
  }

  Future<_AssignmentLookup> _lookupAssignment(
    _ProvisioningOperation operation,
    int nodeId,
  ) async {
    diagnosticLog?.call('ASSIGNMENT_VERIFY started');
    try {
      final matched = await assignmentVerifier.verifyAssignment(nodeId: nodeId);
      _check(operation);
      diagnosticLog?.call(
        'ASSIGNMENT_VERIFY result=${matched ? "matched" : "not_found"}',
      );
      return matched ? _AssignmentLookup.matched : _AssignmentLookup.missing;
    } on ProvisioningOperationCancelledException {
      rethrow;
    } catch (_) {
      _check(operation);
      diagnosticLog?.call(
        'ASSIGNMENT_VERIFY result=backend_unavailable',
      );
      return _AssignmentLookup.unavailable;
    }
  }

  Future<bool> _createAssignment(
    _ProvisioningOperation operation, {
    required int nodeId,
    required DeviceStatus status,
    required String reason,
  }) async {
    diagnosticLog?.call(
      'ASSIGNMENT_CREATE reason=$reason',
    );
    try {
      final firmwareVersion = status.firmwareVersion?.trim();
      final hardwareModel = (status.model ?? status.deviceAlias)?.trim();
      final created = await assignmentCreator.createAssignment(
        nodeId: nodeId,
        firmwareVersion: firmwareVersion == null || firmwareVersion.isEmpty
            ? 'unknown'
            : firmwareVersion,
        hardwareModel: hardwareModel == null || hardwareModel.isEmpty
            ? 'EIXAM R1'
            : hardwareModel,
        pairedAt: (status.lastSeen ?? DateTime.now()).toUtc(),
      );
      _check(operation);
      diagnosticLog?.call(
        'ASSIGNMENT_CREATE result=${created ? "success" : "failed"}',
      );
      return created;
    } on ProvisioningOperationCancelledException {
      rethrow;
    } catch (_) {
      _check(operation);
      diagnosticLog?.call('ASSIGNMENT_CREATE result=failed');
      return false;
    }
  }

  Future<void> _write(
      _ProvisioningOperation operation, EixamDeviceCommand command) async {
    _check(operation);
    await writeCommand(command);
  }

  void _check(_ProvisioningOperation operation) {
    if (_disposed || operation.cancelled || !identical(_operation, operation)) {
      throw const ProvisioningOperationCancelledException();
    }
  }

  void _onDeviceStatus(DeviceStatus status) {
    if (_disposed) return;
    final previousDevice = _activeDeviceId;
    if (!status.connected) {
      _ackCoordinator.markDisconnected();
      if (!_expectingRebootDisconnect) {
        _cancelOperation();
        _resetDeviceScopedState();
      }
      return;
    }
    _ackCoordinator.markConnected();
    if (previousDevice != null && status.deviceId != previousDevice) {
      _cancelOperation();
      _resetDeviceScopedState();
    }
    _activeDeviceId = status.deviceId;
  }

  void _resetDeviceScopedState() {
    if (_state.phase != DeviceProvisioningPhase.idle) {
      _emit(DeviceProvisioningPhase.idle);
    }
  }

  void _cancelOperation() {
    _operation?.cancel();
    _ackCoordinator.cancelPending();
  }

  DeviceReadyResult _cancelledResult() {
    if (_operation?.rebootBoundaryStarted == true) {
      diagnosticLog?.call(
        'PROVISIONING_REBOOT '
        'failure_code=${DeviceReadyFailureCode.deviceCommunicationInterrupted.name}',
      );
    }
    return const DeviceReadyResult.failed(
      DeviceReadyFailure(
        code: DeviceReadyFailureCode.deviceCommunicationInterrupted,
        retryable: true,
      ),
    );
  }

  DeviceReadyResult _readyProvisioned(
    DeviceStatus status, {
    required bool assignmentVerified,
  }) {
    if (!assignmentVerified) {
      diagnosticLog?.call(
        'ASSIGNMENT remaining=unverified action=ready_provisioned',
      );
    }
    _emit(DeviceProvisioningPhase.ready, progress: 1);
    return DeviceReadyResult.ready(status);
  }

  DeviceReadyResult _fail(DeviceReadyFailureCode code,
      {required bool retryable}) {
    final failedPhase = _state.phase;
    diagnosticLog?.call(
      'PROVISIONING_FAILURE reason=${code.name} phase=${failedPhase.name}',
    );
    if (_operation?.rebootBoundaryStarted == true) {
      diagnosticLog?.call(
        'PROVISIONING_REBOOT failure_code=${code.name}',
      );
    }
    final failure = DeviceReadyFailure(code: code, retryable: retryable);
    _emit(DeviceProvisioningPhase.failed, failure: failure);
    return DeviceReadyResult.failed(failure);
  }

  void _emit(DeviceProvisioningPhase phase,
      {double? progress, DeviceReadyFailure? failure}) {
    if (_disposed) return;
    _state = DeviceProvisioningState(
        phase: phase, progress: progress, failure: failure);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _cancelOperation();
    await _deviceStatusSubscription.cancel();
    await _ackCoordinator.dispose();
    await _stateController.close();
  }
}

final class _ProvisioningOperation {
  final Completer<void> _cancelled = Completer<void>();
  bool rebootBoundaryStarted = false;
  bool get cancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

enum _AssignmentLookup { matched, missing, unavailable }
