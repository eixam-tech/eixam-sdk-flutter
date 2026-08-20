import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_remote/sdk_network_psk_remote_data_source.dart';
import '../device/eixam_ble_command.dart';
import '../firmware_version.dart';
import 'provisioning_command_result.dart';
import 'softsim_provisioning.dart';
import 'softsim_transport.dart';
import 'strict_device_provisioning_config.dart';

final class ProvisioningFirmwarePolicy {
  const ProvisioningFirmwarePolicy.current();

  static const String certifiedBaselineVersion = '2.7.37';

  bool supports(String? version) {
    if (version == null) return false;
    final actualParts = _parts(version);
    final baselineParts = _parts(certifiedBaselineVersion);
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
/// The 900 ms lower bound rejects transport loss far earlier than reboot; the
/// 5 second upper bound leaves ample Android/iOS callback scheduling margin.
final class ProvisioningRebootDisconnectPolicy {
  const ProvisioningRebootDisconnectPolicy({
    this.minimumDelay = const Duration(milliseconds: 900),
    this.maximumDelay = const Duration(seconds: 5),
    this.clock = DateTime.now,
  });

  final Duration minimumDelay;
  final Duration maximumDelay;
  final DateTime Function() clock;

  Future<void> writeAndAwait({
    required Future<void> Function() writeReboot,
    required Stream<DeviceStatus> statuses,
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
      await writeReboot();
      diagnosticLog?.call(
        'PROVISIONING_REBOOT command_write_completed=true',
      );
      final writeCompletedAt = clock();
      final disconnectedAt = await disconnect.future.timeout(
        maximumDelay,
        onTimeout: () {
          diagnosticLog?.call(
            'PROVISIONING_REBOOT disconnect_timing_bucket=timeout',
          );
          throw const ProvisioningRebootException();
        },
      );
      final elapsed = disconnectedAt.difference(writeCompletedAt);
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
  }) : _packets = incomingPackets.asBroadcastStream() {
    _ackCoordinator = ProvisioningAckCoordinator(packets: _packets);
    _deviceStatusSubscription = deviceStatusChanges.listen(_onDeviceStatus);
  }

  final Future<DeviceStatus> Function() statusProvider;
  final Future<DeviceStatus> Function() liveStatusProvider;
  final Future<DeviceRuntimeStatus> Function() runtimeStatusProvider;
  final Future<String> Function() countryIsoProvider;
  final SdkNetworkPskRemoteDataSource pskSource;
  final StrictDeviceProvisioningConfigSource configSource;
  final String backendUrl;
  final Future<void> Function(EixamDeviceCommand command) writeCommand;
  final Future<void> Function() reboot;
  final Future<bool> Function(String platformDeviceId) reconnectSameDevice;
  final Future<void> Function() acquireReconnectOwnership;
  final void Function() releaseReconnectOwnership;
  final void Function(String event)? diagnosticLog;
  final ProvisioningFirmwarePolicy firmwarePolicy;
  final Duration softSimRejectionObservationInterval;
  final Stream<List<int>> _packets;
  late final ProvisioningAckCoordinator _ackCoordinator;
  late final StreamSubscription<DeviceStatus> _deviceStatusSubscription;
  final StreamController<DeviceProvisioningState> _stateController =
      StreamController<DeviceProvisioningState>.broadcast();
  DeviceProvisioningState _state = const DeviceProvisioningState.idle();
  Future<DeviceReadyResult>? _inFlight;
  _ProvisioningOperation? _operation;
  String? _activeDeviceId;
  bool _expectingRebootDisconnect = false;
  bool _disposed = false;

  Stream<DeviceProvisioningState> watchState() async* {
    yield _state;
    yield* _stateController.stream;
  }

  Future<DeviceReadyResult> ensureReady() {
    if (_disposed) {
      return Future<DeviceReadyResult>.value(_cancelledResult());
    }
    return _inFlight ??= _startOperation();
  }

  Future<DeviceReadyResult> _startOperation() {
    final operation = _ProvisioningOperation();
    _operation = operation;
    return _run(operation).whenComplete(() {
      if (identical(_operation, operation)) _operation = null;
      _inFlight = null;
    });
  }

  Future<DeviceReadyResult> _run(_ProvisioningOperation operation) async {
    try {
      _emit(DeviceProvisioningPhase.checkingDevice);
      final initialStatus = await statusProvider();
      _check(operation);
      if (!initialStatus.connected || initialStatus.nodeId == null) {
        return _fail(DeviceReadyFailureCode.notConnected, retryable: true);
      }
      _activeDeviceId = initialStatus.deviceId;
      final initialRuntime = await runtimeStatusProvider();
      _check(operation);
      if (initialRuntime.nodeId != initialStatus.nodeId) {
        return _fail(DeviceReadyFailureCode.identityMismatch, retryable: false);
      }
      if (initialRuntime.isProvisioned) {
        // 0x23 proves only structural config.bin validity. It cannot prove
        // current-app PSK ownership or authoritative backend assignment.
        _emit(DeviceProvisioningPhase.provisionedAssignmentUnverified);
        return DeviceReadyResult.provisionedAssignmentUnverified(initialStatus);
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
            _expectingRebootDisconnect = true;
            try {
              await reboot();
            } finally {
              _expectingRebootDisconnect = false;
            }
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
            _check(operation);
            _emit(DeviceProvisioningPhase.verifying, progress: 0.9);
            diagnosticLog?.call(
              'PROVISIONING_REBOOT verification_started=true',
            );
            final finalStatus = await statusProvider();
            _check(operation);
            if (!finalStatus.connected ||
                finalStatus.deviceId != initialStatus.deviceId) {
              return _fail(DeviceReadyFailureCode.identityMismatch,
                  retryable: false);
            }
            final finalRuntime = await runtimeStatusProvider();
            _check(operation);
            final verified = finalRuntime.nodeId == initialRuntime.nodeId &&
                finalRuntime.isProvisioned &&
                finalRuntime.region == config.regionCode &&
                !finalRuntime.usePreset &&
                finalRuntime.txEnabled &&
                finalRuntime.meshSpreadingFactor == config.tel.spreadingFactor;
            if (!verified) {
              final identityChanged =
                  finalRuntime.nodeId != initialRuntime.nodeId;
              return _fail(
                  identityChanged
                      ? DeviceReadyFailureCode.identityMismatch
                      : DeviceReadyFailureCode.verificationFailed,
                  retryable: !identityChanged);
            }
            _emit(DeviceProvisioningPhase.ready, progress: 1);
            return DeviceReadyResult.ready(finalStatus);
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

  DeviceReadyResult _fail(DeviceReadyFailureCode code,
      {required bool retryable}) {
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
