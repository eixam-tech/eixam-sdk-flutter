import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'ble_debug_registry.dart';
import 'eixam_ble_command.dart';
import 'eixam_sos_event_packet.dart';
import 'eixam_sos_packet.dart';

typedef DeviceCommandWriter = Future<void> Function(EixamDeviceCommand command);

class DeviceSosController {
  DeviceSosController({
    Duration countdownDuration = const Duration(seconds: 20),
    Duration countdownTick = const Duration(seconds: 1),
    Duration appActivationObservationTimeout = const Duration(seconds: 3),
    DateTime Function()? now,
  })  : _countdownDuration = countdownDuration,
        _countdownTick = countdownTick,
        _appActivationObservationTimeout = appActivationObservationTimeout,
        _now = now ?? DateTime.now {
    _controller.add(_status);
  }

  final StreamController<DeviceSosStatus> _controller =
      StreamController<DeviceSosStatus>.broadcast();
  final StreamController<bool> _commandPathController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _controlCommandPathController =
      StreamController<bool>.broadcast();

  DeviceCommandWriter? _commandWriter;
  bool _shortCommandAvailable = false;
  bool _longCommandAvailable = false;
  DeviceSosStatus _status = DeviceSosStatus.initial();
  final Duration _countdownDuration;
  final Duration _countdownTick;
  final Duration _appActivationObservationTimeout;
  final DateTime Function() _now;
  Timer? _countdownTimer;
  bool _awaitingObservedAppActivation = false;
  _PendingTerminalDeviceCommand? _pendingTerminalCommand;
  String? _lastPromotedPreConfirmCycleKey;
  DateTime? _lastPromotedPreConfirmAt;

  static const Duration _terminalCycleSuppressionWindow = Duration(seconds: 5);
  static const Duration _promotedPreConfirmSuppressionWindow = Duration(
    minutes: 2,
  );
  static const Duration _observedDevicePreSosSkew = Duration(seconds: 2);

  DeviceSosStatus get currentStatus => _status;
  bool get shortCommandAvailable =>
      _commandWriter != null && _shortCommandAvailable;
  bool get longCommandAvailable =>
      _commandWriter != null && _longCommandAvailable;
  bool get hasSosCommandPath => shortCommandAvailable;
  bool get hasCommandChannel => longCommandAvailable;
  Stream<bool> watchCommandPathAvailability() async* {
    yield hasSosCommandPath;
    yield* _commandPathController.stream;
  }

  /// Availability of the CMD characteristic used by control operations such
  /// as runtime status, region provisioning and reboot. This is intentionally
  /// separate from the short INET path used by most SOS commands.
  Stream<bool> watchControlCommandPathAvailability() async* {
    yield hasCommandChannel;
    yield* _controlCommandPathController.stream;
  }

  Future<void> attach({
    required DeviceCommandWriter commandWriter,
    bool shortCommandAvailable = true,
    bool longCommandAvailable = true,
  }) async {
    final previousAvailability = hasSosCommandPath;
    final previousControlAvailability = hasCommandChannel;
    _commandWriter = commandWriter;
    _shortCommandAvailable = shortCommandAvailable;
    _longCommandAvailable = longCommandAvailable;
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_SOS_COMMAND_PATH_ATTACHED available=$hasSosCommandPath previous=$previousAvailability shortCommandAvailable=${this.shortCommandAvailable} longCommandAvailable=${this.longCommandAvailable}',
    );
    _emitCommandPathAvailabilityIfChanged(previousAvailability);
    _emitControlCommandPathAvailabilityIfChanged(previousControlAvailability);
    _emit(
      _status.copyWith(
        lastEvent: 'DEVICE_SOS_COMMAND_CHANNEL_ATTACHED',
        updatedAt: _now(),
      ),
    );
    unawaited(_flushPendingTerminalCommand(reason: 'command_path_attached'));
  }

  Future<void> detach() async {
    final previousAvailability = hasSosCommandPath;
    final previousControlAvailability = hasCommandChannel;
    _commandWriter = null;
    _shortCommandAvailable = false;
    _longCommandAvailable = false;
    _awaitingObservedAppActivation = false;
    _pendingTerminalCommand = null;
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_SOS_COMMAND_PATH_DETACHED available=$hasSosCommandPath previous=$previousAvailability',
    );
    _emitCommandPathAvailabilityIfChanged(previousAvailability);
    _emitControlCommandPathAvailabilityIfChanged(previousControlAvailability);
    _cancelCountdownTimer();
    _emit(
      DeviceSosStatus(
        state: DeviceSosState.inactive,
        previousState: _status.state,
        transitionSource: DeviceSosTransitionSource.unknown,
        triggerOrigin: DeviceSosTransitionSource.unknown,
        lastEvent: 'DEVICE_SOS_CONTROLLER_DETACHED',
        updatedAt: _now(),
      ),
    );
  }

  Future<DeviceSosStatus> getStatus() async => _status;

  Stream<DeviceSosStatus> watchStatus() => _controller.stream;

  DeviceSosStatus settleExpiredPreConfirmCountdown({required String reason}) {
    if (_status.state != DeviceSosState.preConfirm ||
        _status.expectedActivationAt == null ||
        _now().isBefore(_status.expectedActivationAt!)) {
      return _status;
    }
    return _promoteExpiredPreConfirmCountdown(
      event: 'SOS countdown elapsed: $reason',
    );
  }

  Future<DeviceSosStatus> triggerSos({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) {
    return _sendCommand(
      command: EixamDeviceCommand.sosTriggerApp(),
      optimisticState: DeviceSosState.preConfirm,
      optimisticEvent: 'DEVICE_SOS_TRIGGERED_BY_APP',
      failureEvent: 'DEVICE_SOS_TRIGGER_WRITE_FAILED',
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
  }

  Future<DeviceSosStatus> activateSosFromApp({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) async {
    try {
      _awaitingObservedAppActivation = false;
      await triggerSos(
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );
      await _waitForStatus(
        description: 'DEVICE_SOS_PRE_CONFIRM_OBSERVED',
        predicate: _isObservedPreConfirmForAppActivation,
      );
      await _sendAppConfirmCommand(
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );
      final active = await _waitForStatus(
        description: 'DEVICE_SOS_ACTIVE_OBSERVED_AFTER_CONFIRM',
        predicate: _isObservedActiveForAppActivation,
      );
      BleDebugRegistry.instance.recordEvent(
        'APP_SOS_DEVICE_ACTIVATION_COMPLETED route=$commandRouteLabel state=${active.state.name}',
      );
      return active;
    } catch (error) {
      _awaitingObservedAppActivation = false;
      BleDebugRegistry.instance.recordEvent(
        'APP_SOS_DEVICE_ACTIVATION_INCOMPLETE route=$commandRouteLabel state=${_status.state.name} error=$error note=device_stayed_in_pre_sos',
      );
      rethrow;
    }
  }

  Future<DeviceSosStatus> confirmSos({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) {
    if (_status.state != DeviceSosState.preConfirm) {
      return Future<DeviceSosStatus>.value(
        _status.copyWith(
          lastEvent: 'DEVICE_SOS_CONFIRM_IGNORED_STATE_NOT_PRE_CONFIRM',
          updatedAt: _now(),
        ),
      );
    }
    return _sendCommand(
      command: EixamDeviceCommand.sosConfirm(),
      optimisticState: DeviceSosState.active,
      optimisticEvent: 'DEVICE_SOS_CONFIRMED_BY_APP',
      failureEvent: 'DEVICE_SOS_CONFIRM_WRITE_FAILED',
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
  }

  Future<DeviceSosStatus> cancelSos({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
    String terminalAction = 'cancel',
    bool? terminalCmdAvailable,
    bool? waitForCloseAcknowledgement,
  }) async {
    final writer = commandWriterOverride ?? _commandWriter;
    if (writer == null) {
      return _queueTerminalCommand(
        action: terminalAction,
        reason: 'no_command_characteristic_ready',
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );
    }
    final previous = _status;
    final sent = await _dispatchTerminalCommand(
      writer: writer,
      previous: previous,
      commandRouteLabel: commandRouteLabel,
      allowCmd: terminalCmdAvailable ?? longCommandAvailable,
      allowInet: commandWriterOverride != null || shortCommandAvailable,
      action: terminalAction,
      commandWriterOverride: commandWriterOverride,
    );
    if (!sent) {
      return _queueTerminalCommand(
        action: terminalAction,
        reason: 'no_command_characteristic_ready',
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );
    }
    if (_isClosedState(previous.state)) {
      return _status;
    }
    final shouldWaitForCloseAcknowledgement =
        waitForCloseAcknowledgement ?? _isOpenSosState(previous.state);
    if (!shouldWaitForCloseAcknowledgement) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_CLOSE_COMMAND_DISPATCHED_WITHOUT_ACK_WAIT route=$commandRouteLabel previousState=${previous.state.name}',
      );
      final now = _now();
      final nextState = terminalAction == 'resolve'
          ? DeviceSosState.resolved
          : DeviceSosState.inactive;
      _cancelCountdownTimer();
      _awaitingObservedAppActivation = false;
      _emit(
        _status.copyWith(
          state: nextState,
          previousState: previous.state,
          transitionSource: DeviceSosTransitionSource.app,
          triggerOrigin: previous.triggerOrigin,
          lastEvent:
              'DEVICE_SOS_CLOSE_COMMAND_APPLIED_LOCALLY action=$terminalAction',
          updatedAt: now,
          optimistic: false,
          derivedFromBlePacket: false,
          countdownStartedAt: null,
          expectedActivationAt: null,
          countdownRemainingSeconds: null,
        ),
      );
      return _status;
    }
    try {
      final closed = await _waitForStatus(
        description: 'DEVICE_SOS_CLOSE_ACK_OBSERVED_AFTER_CANCEL',
        predicate: _isObservedClosedAfterCancel,
      );
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_CLOSE_COMMAND_ACKNOWLEDGED route=$commandRouteLabel state=${closed.state.name} previousState=${previous.state.name}',
      );
      return closed;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_CLOSE_COMMAND_ACK_TIMEOUT_OR_FAILED route=$commandRouteLabel lastState=${_status.state.name} previousState=${previous.state.name} error=$error',
      );
      return _forceTerminalStateAfterMissingCloseAcknowledgement(
        previous: previous,
        terminalAction: terminalAction,
        commandRouteLabel: commandRouteLabel,
        error: error,
      );
    }
  }

  DeviceSosStatus clearPreSosLocally({required String reason}) {
    if (_status.state != DeviceSosState.preConfirm) {
      return _status;
    }
    final previous = _status;
    _awaitingObservedAppActivation = false;
    _cancelCountdownTimer();
    BleDebugRegistry.instance.recordEvent(
      '[APP_PRE_SOS_CANCEL] action=device_state_cleared reason=$reason '
      'previousState=${previous.state.name}',
    );
    _emit(
      DeviceSosStatus(
        state: DeviceSosState.inactive,
        previousState: previous.state,
        transitionSource: DeviceSosTransitionSource.app,
        triggerOrigin: previous.triggerOrigin,
        lastEvent: 'DEVICE_PRE_SOS_COUNTDOWN_CLEARED reason=$reason',
        updatedAt: _now(),
      ),
    );
    return _status;
  }

  Future<DeviceSosStatus> acknowledgeSos({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) {
    if (_status.state != DeviceSosState.active) {
      return Future<DeviceSosStatus>.value(
        _status.copyWith(
          lastEvent: 'DEVICE_SOS_ACK_IGNORED_STATE_NOT_ACTIVE',
          updatedAt: _now(),
        ),
      );
    }
    return _sendCommand(
      command: EixamDeviceCommand.sosAck(),
      optimisticState: DeviceSosState.acknowledged,
      optimisticEvent: 'DEVICE_SOS_BACKEND_ACK_SENT_BY_APP',
      failureEvent: 'DEVICE_SOS_BACKEND_ACK_WRITE_FAILED',
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
  }

  Future<void> sendInetOk({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) => _sendNonSosCommand(
        EixamDeviceCommand.inetOk(),
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );

  Future<void> sendInetLost({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) => _sendNonSosCommand(
        EixamDeviceCommand.inetLost(),
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );

  Future<void> sendPositionConfirmed({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) => _sendNonSosCommand(
        EixamDeviceCommand.positionConfirmed(),
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );

  Future<void> sendAckRelay({
    required int nodeId,
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) {
    return _sendNonSosCommand(
      EixamDeviceCommand.sosAckRelay(nodeId: nodeId),
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
  }

  Future<void> sendShutdown({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) => _sendNonSosCommand(
        EixamDeviceCommand.shutdown(),
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );

  Future<void> sendAttachedCommand(EixamDeviceCommand command) {
    return _sendNonSosCommand(command);
  }

  Future<DeviceSosStatus> _sendCommand({
    required EixamDeviceCommand command,
    required DeviceSosState optimisticState,
    required String optimisticEvent,
    required String failureEvent,
    DeviceCommandWriter? commandWriterOverride,
    required String commandRouteLabel,
  }) async {
    final writer = commandWriterOverride ?? _commandWriter;
    if (writer == null) {
      throw const DeviceException(
        'E_DEVICE_SOS_COMMAND_CHANNEL_NOT_READY',
        'E_DEVICE_SOS_COMMAND_CHANNEL_NOT_READY',
      );
    }
    if (commandWriterOverride == null) {
      _ensureCommandAvailable(command: command);
    }

    final previous = _status;
    final now = _now();
    if (optimisticState == DeviceSosState.preConfirm) {
      _enterPreConfirm(
        source: DeviceSosTransitionSource.app,
        event: optimisticEvent,
        at: now,
        optimistic: true,
        derivedFromBlePacket: false,
        lastOpcode: command.opcode,
        decoderNote:
            'DEVICE_SOS_OPTIMISTIC_LOCAL_TRANSITION_PENDING_CONFIRMATION',
      );
    } else {
      _cancelCountdownTimer();
      _emit(
        _status.copyWith(
          state: optimisticState,
          previousState: previous.state,
          transitionSource: DeviceSosTransitionSource.app,
          triggerOrigin:
              previous.triggerOrigin == DeviceSosTransitionSource.unknown
                  ? DeviceSosTransitionSource.app
                  : previous.triggerOrigin,
          lastEvent: optimisticEvent,
          updatedAt: now,
          optimistic: true,
          derivedFromBlePacket: false,
          lastOpcode: command.opcode,
          decoderNote:
              'DEVICE_SOS_OPTIMISTIC_LOCAL_TRANSITION_PENDING_CONFIRMATION',
          countdownStartedAt: null,
          expectedActivationAt: null,
          countdownRemainingSeconds: null,
        ),
      );
    }

    await _dispatchCommand(
      writer: writer,
      command: command,
      previous: previous,
      failureEvent: failureEvent,
      commandRouteLabel: commandRouteLabel,
    );
    return _status;
  }

  Future<void> _dispatchCommand({
    required DeviceCommandWriter writer,
    required EixamDeviceCommand command,
    required DeviceSosStatus previous,
    required String failureEvent,
    required String commandRouteLabel,
  }) async {
    try {
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_COMMAND_DISPATCH route=$commandRouteLabel command=${command.label} previousState=${previous.state.name}',
      );
      await writer(command);
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_COMMAND_SENT route=$commandRouteLabel command=${command.label} previousState=${previous.state.name}',
      );
      return;
    } catch (error) {
      _emit(
        previous.copyWith(
          lastEvent: '$failureEvent: $error',
          updatedAt: _now(),
          optimistic: false,
          previousState: previous.state,
          transitionSource: DeviceSosTransitionSource.app,
          lastOpcode: command.opcode,
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'DEVICE_SOS_COMMAND_FAILED route=$commandRouteLabel command=${command.label} error=$error',
      );

      rethrow;
    }
  }

  Future<bool> _dispatchTerminalCommand({
    required DeviceCommandWriter writer,
    required DeviceSosStatus previous,
    required String commandRouteLabel,
    required bool allowCmd,
    required bool allowInet,
    required String action,
    DeviceCommandWriter? commandWriterOverride,
  }) async {
    Object? cmdError;
    if (allowCmd) {
      final command = EixamDeviceCommand.sosCancel(
        forceCmdCharacteristic: true,
      );
      try {
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_SOS_COMMAND_DISPATCH route=$commandRouteLabel command=${command.label} previousState=${previous.state.name}',
        );
        await writer(command);
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_SOS_COMMAND_SENT route=$commandRouteLabel command=${command.label} previousState=${previous.state.name}',
        );
        _recordTerminalCommandSent(
          channel: 'cmd',
          action: action,
          commandWriterOverride: commandWriterOverride,
          commandRouteLabel: commandRouteLabel,
        );
        return true;
      } catch (error) {
        cmdError = error;
      }
    }

    if (allowInet) {
      if (cmdError != null || !allowCmd) {
        BleDebugRegistry.instance.recordEvent(
          'SOS_TRACE device_terminal_command_fallback channel=inet reason=cmd_not_ready',
        );
      }
      final command = EixamDeviceCommand.sosCancel();
      try {
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_SOS_COMMAND_DISPATCH route=$commandRouteLabel command=${command.label} previousState=${previous.state.name}',
        );
        await writer(command);
        BleDebugRegistry.instance.recordEvent(
          'DEVICE_SOS_COMMAND_SENT route=$commandRouteLabel command=${command.label} previousState=${previous.state.name}',
        );
        _recordTerminalCommandSent(
          channel: 'inet',
          action: action,
          commandWriterOverride: commandWriterOverride,
          commandRouteLabel: commandRouteLabel,
        );
        return true;
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  DeviceSosStatus _queueTerminalCommand({
    required String action,
    required String reason,
    DeviceCommandWriter? commandWriterOverride,
    String? commandRouteLabel,
  }) {
    final now = _now();
    _pendingTerminalCommand = _PendingTerminalDeviceCommand(
      action: action,
      nodeId: _status.nodeId,
      requestedAt: now,
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
    _cancelCountdownTimer();
    BleDebugRegistry.instance.recordEvent(
      'SOS_TRACE device_terminal_command_queued reason=$reason',
    );
    _emit(
      _status.copyWith(
        lastEvent: 'DEVICE_TERMINAL_CLEAR_COMMAND_QUEUED',
        updatedAt: now,
        transitionSource: DeviceSosTransitionSource.app,
        optimistic: false,
        countdownStartedAt: null,
        expectedActivationAt: null,
        countdownRemainingSeconds: null,
      ),
    );
    return _status;
  }

  Future<void> _flushPendingTerminalCommand({required String reason}) async {
    final pending = _pendingTerminalCommand;
    final writer = pending?.commandWriterOverride ?? _commandWriter;
    if (pending == null || writer == null) {
      return;
    }
    final usesOverride = pending.commandWriterOverride != null;
    if (!usesOverride && !longCommandAvailable && !shortCommandAvailable) {
      return;
    }
    if (reason != 'sos_still_observed_after_terminal') {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRACE device_terminal_command_retry reason=$reason',
      );
    }
    final sent = await _dispatchTerminalCommand(
      writer: writer,
      previous: _status,
      commandRouteLabel: pending.commandRouteLabel ?? 'attached_writer',
      allowCmd: !usesOverride && longCommandAvailable,
      allowInet: usesOverride || shortCommandAvailable,
      action: pending.action,
      commandWriterOverride: pending.commandWriterOverride,
    );
    if (sent) {
      _pendingTerminalCommand = pending.copyWith(sentAt: _now());
    }
  }

  void _recordTerminalCommandSent({
    required String channel,
    required String action,
    DeviceCommandWriter? commandWriterOverride,
    String? commandRouteLabel,
  }) {
    final pending = _pendingTerminalCommand;
    _pendingTerminalCommand =
        (pending ??
            _PendingTerminalDeviceCommand(
              action: action,
              nodeId: _status.nodeId,
              requestedAt: _now(),
              commandWriterOverride: commandWriterOverride,
              commandRouteLabel: commandRouteLabel,
            ))
        .copyWith(sentAt: _now());
    BleDebugRegistry.instance.recordEvent(
      'SOS_TRACE device_terminal_command_sent opcode=0x04 channel=$channel',
    );
  }

  Future<void> _sendAppConfirmCommand({
    DeviceCommandWriter? commandWriterOverride,
    required String commandRouteLabel,
  }) async {
    if (_status.state != DeviceSosState.preConfirm) {
      throw const DeviceException(
        'E_DEVICE_SOS_CONFIRM_STATE_REQUIRED',
        'E_DEVICE_SOS_CONFIRM_STATE_REQUIRED',
      );
    }
    final writer = commandWriterOverride ?? _commandWriter;
    if (writer == null) {
      throw const DeviceException(
        'E_DEVICE_SOS_COMMAND_CHANNEL_NOT_READY',
        'E_DEVICE_SOS_COMMAND_CHANNEL_NOT_READY',
      );
    }
    final command = EixamDeviceCommand.sosConfirm();
    if (commandWriterOverride == null) {
      _ensureCommandAvailable(command: command);
    }
    final previous = _status;
    _awaitingObservedAppActivation = true;
    await _dispatchCommand(
      writer: writer,
      command: command,
      previous: previous,
      failureEvent: 'DEVICE_SOS_CONFIRM_WRITE_FAILED',
      commandRouteLabel: commandRouteLabel,
    );
  }

  Future<void> _sendNonSosCommand(
    EixamDeviceCommand command, {
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) async {
    final writer = commandWriterOverride ?? _commandWriter;
    if (writer == null) {
      throw const DeviceException(
        'E_BLE_COMMAND_CHANNEL_NOT_READY',
        'E_BLE_COMMAND_CHANNEL_NOT_READY',
      );
    }
    if (commandWriterOverride == null) {
      _ensureCommandAvailable(command: command);
    }
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_COMMAND_DISPATCH route=$commandRouteLabel command=${command.label}',
    );
    await writer(command);
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_COMMAND_SENT route=$commandRouteLabel command=${command.label}',
    );
  }

  void _ensureCommandAvailable({required EixamDeviceCommand command}) {
    final available = command.usesCmdCharacteristic
        ? longCommandAvailable
        : shortCommandAvailable;
    if (available) {
      return;
    }
    final readiness = command.usesCmdCharacteristic
        ? 'longCommandAvailable=$longCommandAvailable'
        : 'shortCommandAvailable=$shortCommandAvailable';
    throw DeviceException(
      'E_BLE_COMMAND_PATH_NOT_READY',
      'E_BLE_COMMAND_PATH_NOT_READY ($readiness)',
    );
  }

  void handleIncomingSosPacket(
    EixamSosPacket packet, {
    required DeviceSosTransitionSource source,
  }) {
    final previousStatus = _status;
    final previous = previousStatus.state;
    final now = _now();
    final resolution = _resolveMeshPacketState(
      packet,
      currentStatus: previousStatus,
      source: source,
    );
    final nextState = resolution.resolvedState;
    final event =
        'SOS notify decoded -> nodeId=${_formatNodeId(packet.nodeId)} '
        'sosType=${packet.sosType} '
        'packetId=${packet.packetId} '
        'relayCount=${packet.relayCount} '
        'hasPosition=${packet.hasPosition}';

    BleDebugRegistry.instance.recordEvent(event);
    BleDebugRegistry.instance.recordEvent(
      'SOS transition -> ${previous.name} -> ${nextState.name}',
    );
    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_SOS_STATE_DECISION] '
      'rawHex=${packet.rawHex} '
      'nodeId=${_formatNodeId(packet.nodeId)} '
      'packetId=${packet.packetId} '
      'sosType=${packet.sosType} '
      'retryCount=${packet.retryCount} '
      'flagsWord=0x${packet.flagsWord.toRadixString(16).padLeft(4, '0')} '
      'previousState=${previous.name} '
      'protocolResolvedState=${resolution.protocolState.name} '
      'finalResolvedState=${nextState.name} '
      'reason=${resolution.reason} '
      'cycleKey=${resolution.cycleKey ?? "-"}',
    );
    BleDebugRegistry.instance.recordEvent(
      '[SDK_SOS_CLASSIFY] '
      'packet=${packet.rawHex} '
      'decision=${resolution.classificationDecision} '
      'reason=${resolution.classificationReason}',
    );

    if (_shouldSuppressForPendingTerminalCommand(
      packet.nodeId,
      source: source,
      currentStatus: previousStatus,
      resolution: resolution,
    )) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRACE device_rearm_suppressed reason=pending_terminal_command',
      );
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRACE device_terminal_command_retry reason=sos_still_observed_after_terminal',
      );
      unawaited(
        _flushPendingTerminalCommand(
        reason: 'sos_still_observed_after_terminal',
        ),
      );
      return;
    }

    if (nextState == DeviceSosState.preConfirm) {
      _enterPreConfirm(
        source: source,
        event: event,
        at: now,
        optimistic: false,
        derivedFromBlePacket: true,
        triggerOriginOverride: _resolveObservedTriggerOrigin(
          source,
          nodeId: packet.nodeId,
        ),
        lastPacketHex: packet.rawHex,
        lastPacketLength: packet.rawBytes.length,
        lastPacketAt: now,
        lastPacketSignature:
            '${packet.nodeId}:${packet.packetId}:${packet.rawHex}',
        nodeId: packet.nodeId,
        flags: packet.flagsWord,
        sosType: packet.sosType,
        retryCount: packet.retryCount,
        relayCount: packet.relayCount,
        batteryLevel: packet.batteryLevel,
        batteryState: DeviceBatteryLevel.fromProtocolValue(packet.batteryLevel),
        gpsQuality: packet.gpsQuality,
        packetId: packet.packetId,
        hasLocation: packet.hasPosition,
        decoderNote: resolution.decoderNote,
      );
      return;
    }

    final keepCountdownMetadata =
        nextState == DeviceSosState.active &&
        _status.state == DeviceSosState.preConfirm;
    if (nextState != DeviceSosState.preConfirm) {
      _cancelCountdownTimer();
    }
    if (nextState == DeviceSosState.active) {
      _awaitingObservedAppActivation = false;
    }
    final preserveCurrentPacketMetadata =
        resolution.downgradeSuppressed && nextState == _status.state;
    _emit(
      _status.copyWith(
        state: nextState,
        previousState: previous,
        transitionSource: source,
        triggerOrigin: _resolveObservedTriggerOrigin(
          source,
          nodeId: packet.nodeId,
        ),
        lastEvent: event,
        updatedAt: now,
        optimistic: false,
        derivedFromBlePacket: true,
        lastPacketHex: packet.rawHex,
        lastPacketLength: packet.rawBytes.length,
        lastPacketAt: now,
        lastPacketSignature:
            '${packet.nodeId}:${packet.packetId}:${packet.rawHex}',
        nodeId: preserveCurrentPacketMetadata ? _status.nodeId : packet.nodeId,
        flags: preserveCurrentPacketMetadata ? _status.flags : packet.flagsWord,
        sosType: preserveCurrentPacketMetadata
            ? _status.sosType
            : packet.sosType,
        retryCount: preserveCurrentPacketMetadata
            ? _status.retryCount
            : packet.retryCount,
        relayCount: preserveCurrentPacketMetadata
            ? _status.relayCount
            : packet.relayCount,
        batteryLevel: preserveCurrentPacketMetadata
            ? _status.batteryLevel
            : packet.batteryLevel,
        batteryState: preserveCurrentPacketMetadata
            ? _status.batteryState
            : DeviceBatteryLevel.fromProtocolValue(packet.batteryLevel),
        gpsQuality: preserveCurrentPacketMetadata
            ? _status.gpsQuality
            : packet.gpsQuality,
        packetId: preserveCurrentPacketMetadata
            ? _status.packetId
            : packet.packetId,
        hasLocation: preserveCurrentPacketMetadata
            ? _status.hasLocation
            : packet.hasPosition,
        decoderNote: resolution.decoderNote,
        countdownStartedAt: keepCountdownMetadata
            ? _status.countdownStartedAt
            : null,
        expectedActivationAt: keepCountdownMetadata
            ? _status.expectedActivationAt
            : null,
        countdownRemainingSeconds: keepCountdownMetadata ? 0 : null,
      ),
    );
  }

  void handleIncomingSosEventPacket(
    EixamSosEventPacket packet, {
    required DeviceSosTransitionSource source,
  }) {
    final now = _now();
    final previous = _status.state;
    final nextState = _resolveEventState(packet, previous);
    final classification = _classifyEventPacket(packet, nextState);
    final controlEventLabel = _describeEventPacket(packet);
    final event =
        'SOS device event decoded -> $controlEventLabel '
        'nodeId=${_formatNodeId(packet.nodeId)} '
        'subcode=0x${packet.subcode.toRadixString(16).padLeft(2, '0')}';

    BleDebugRegistry.instance.recordEvent(event);
    BleDebugRegistry.instance.recordEvent(
      'SOS transition -> ${previous.name} -> ${nextState.name}',
    );
    BleDebugRegistry.instance.recordEvent(
      '[SDK_SOS_CLASSIFY] '
      'packet=${packet.rawHex} '
      'decision=${classification.decision} '
      'reason=${classification.reason}',
    );
    if (packet.opcode == 0xE2) {
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRACE device_terminal_command_ack_ignored event=0xE2 subcode=0x${packet.subcode.toRadixString(16).padLeft(2, '0')}',
      );
      return;
    }

    if (nextState == DeviceSosState.inactive ||
        nextState == DeviceSosState.resolved) {
      _cancelCountdownTimer();
      _awaitingObservedAppActivation = false;
      _pendingTerminalCommand = null;
    }
    _emit(
      _status.copyWith(
        state: nextState,
        previousState: previous,
        transitionSource: source,
        triggerOrigin:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.triggerOrigin
            : _resolveObservedTriggerOrigin(source, nodeId: packet.nodeId),
        lastEvent: event,
        updatedAt: now,
        optimistic: false,
        derivedFromBlePacket: true,
        lastOpcode: packet.opcode,
        lastPacketHex: packet.rawHex,
        lastPacketLength: packet.rawBytes.length,
        lastPacketAt: now,
        lastPacketSignature:
            '${packet.nodeId}:${packet.opcode}:${packet.subcode}:${packet.rawHex}',
        nodeId: packet.nodeId,
        packetId:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.packetId
            : null,
        hasLocation:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.hasLocation
            : false,
        flags:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.flags
            : null,
        sosType:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.sosType
            : null,
        retryCount:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.retryCount
            : null,
        relayCount:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.relayCount
            : null,
        batteryLevel:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.batteryLevel
            : null,
        batteryState:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.batteryState
            : null,
        gpsQuality:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.gpsQuality
            : null,
        decoderNote:
            'DEVICE_SOS_CONTROL_EVENT_DECODED event=$controlEventLabel',
        countdownStartedAt:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? null
            : _status.countdownStartedAt,
        expectedActivationAt:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? null
            : _status.expectedActivationAt,
        countdownRemainingSeconds:
            nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? null
            : _status.countdownRemainingSeconds,
      ),
    );
  }

  _MeshPacketResolution _resolveMeshPacketState(
    EixamSosPacket packet, {
    required DeviceSosStatus currentStatus,
    required DeviceSosTransitionSource source,
  }) {
    final protocolState = _resolveProtocolSosPacketState(packet);
    final cycleKey = _deriveDeviceSosCycleKey(
      nodeId: packet.nodeId,
      packetId: packet.packetId,
    );
    final currentCycleKey = _deriveDeviceSosCycleKey(
      nodeId: currentStatus.nodeId,
      packetId: currentStatus.packetId,
    );
    final sameCycle =
        cycleKey != null &&
        currentCycleKey != null &&
        cycleKey == currentCycleKey;
    final sameOriginNode =
        packet.nodeId != 0 &&
        currentStatus.nodeId != null &&
        packet.nodeId == currentStatus.nodeId;

    if (protocolState == DeviceSosState.inactive) {
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: currentStatus.state,
        cycleKey: cycleKey,
        downgradeSuppressed: false,
        classificationDecision: 'ignored_inactive',
        classificationReason: 'protocol_inactive_without_explicit_close',
        reason: 'DEVICE_SOS_INACTIVE_PACKET_IGNORED_NO_EXPLICIT_CLOSE',
        decoderNote: 'DEVICE_SOS_INACTIVE_PACKET_IGNORED_NO_EXPLICIT_CLOSE',
      );
    }

    final recentlyClosedSameCycle =
        sameCycle &&
        _isClosedState(currentStatus.state) &&
        _now().difference(currentStatus.updatedAt) <=
            _terminalCycleSuppressionWindow;
    final recentlyClosedSameOrigin =
        sameOriginNode &&
        _isClosedState(currentStatus.state) &&
        _now().difference(currentStatus.updatedAt) <=
            _terminalCycleSuppressionWindow;
    if (recentlyClosedSameCycle || recentlyClosedSameOrigin) {
      final closedDecision = currentStatus.state == DeviceSosState.inactive
          ? 'terminal_cancelled'
          : 'terminal_resolved';
      final closedReason = currentStatus.state == DeviceSosState.inactive
          ? 'device_cancel'
          : 'device_resolve';
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: currentStatus.state,
        cycleKey: cycleKey,
        downgradeSuppressed: true,
        classificationDecision: closedDecision,
        classificationReason: recentlyClosedSameCycle
            ? closedReason
            : '${closedReason}_same_node',
        reason: recentlyClosedSameCycle
            ? 'DEVICE_SOS_SAME_CYCLE_REOPEN_SUPPRESSED_AFTER_TERMINAL'
            : 'DEVICE_SOS_SAME_NODE_REOPEN_SUPPRESSED_AFTER_TERMINAL',
        decoderNote: recentlyClosedSameCycle
            ? 'DEVICE_SOS_SAME_CYCLE_REOPEN_SUPPRESSED_AFTER_TERMINAL'
            : 'DEVICE_SOS_SAME_NODE_REOPEN_SUPPRESSED_AFTER_TERMINAL',
      );
    }

    if (protocolState == DeviceSosState.preConfirm &&
        _shouldSuppressPromotedPreConfirmCycle(
          cycleKey: cycleKey,
          currentStatus: currentStatus,
        )) {
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: DeviceSosState.active,
        cycleKey: cycleKey,
        downgradeSuppressed: true,
        classificationDecision: 'active_sos',
        classificationReason: 'same_promoted_cycle_packet_preserved',
        reason: 'DEVICE_SOS_PRE_CONFIRM_RESTART_SUPPRESSED_AFTER_PROMOTION',
        decoderNote:
            'DEVICE_SOS_PRE_CONFIRM_RESTART_SUPPRESSED_AFTER_PROMOTION',
      );
    }

    if (currentStatus.state == DeviceSosState.active ||
        currentStatus.state == DeviceSosState.acknowledged) {
      final preserveAcknowledged =
          currentStatus.state == DeviceSosState.acknowledged;
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: preserveAcknowledged
            ? DeviceSosState.acknowledged
            : DeviceSosState.active,
        cycleKey: cycleKey,
        downgradeSuppressed: protocolState == DeviceSosState.preConfirm,
        classificationDecision: preserveAcknowledged
            ? 'acknowledged_sos'
            : 'active_sos',
        classificationReason: preserveAcknowledged
            ? 'acknowledged_cycle_authoritative'
            : (protocolState == DeviceSosState.preConfirm
                ? (sameCycle || sameOriginNode
                    ? 'same_open_cycle_packet_preserved'
                    : 'open_cycle_packet_preserved')
                : 'explicit_active_packet'),
        reason: preserveAcknowledged
            ? 'DEVICE_SOS_ACKNOWLEDGED_CYCLE_AUTHORITATIVE'
            : (protocolState == DeviceSosState.preConfirm
                ? 'DEVICE_SOS_NONZERO_PACKET_PRESERVED_OPEN_CYCLE'
                : 'DEVICE_SOS_PACKET_EXPLICIT_ACTIVE'),
        decoderNote: preserveAcknowledged
            ? 'DEVICE_SOS_ACKNOWLEDGED_CYCLE_AUTHORITATIVE'
            : (protocolState == DeviceSosState.preConfirm
                ? 'DEVICE_SOS_NONZERO_PACKET_PRESERVED_OPEN_CYCLE'
                : 'DEVICE_SOS_PACKET_EXPLICIT_ACTIVE'),
      );
    }

    if (_awaitingObservedAppActivation &&
        currentStatus.state == DeviceSosState.preConfirm &&
        protocolState == DeviceSosState.active) {
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: DeviceSosState.active,
        cycleKey: cycleKey,
        downgradeSuppressed: false,
        classificationDecision: 'active_sos',
        classificationReason: 'app_activation_confirmed',
        reason: 'DEVICE_SOS_APP_ACTIVATION_CONFIRMED_BY_PACKET',
        decoderNote: 'DEVICE_SOS_APP_ACTIVATION_CONFIRMED_BY_PACKET',
      );
    }

    if (source == DeviceSosTransitionSource.device &&
        protocolState == DeviceSosState.active &&
        currentStatus.state != DeviceSosState.preConfirm &&
        !_isOpenSosState(currentStatus.state)) {
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: DeviceSosState.preConfirm,
        cycleKey: cycleKey,
        downgradeSuppressed: true,
        classificationDecision: 'pre_sos',
        classificationReason: 'device_active_packet_held_for_countdown',
        reason: 'DEVICE_SOS_ACTIVE_PACKET_STARTED_PRE_CONFIRM_COUNTDOWN',
        decoderNote: 'DEVICE_SOS_ACTIVE_PACKET_STARTED_PRE_CONFIRM_COUNTDOWN',
      );
    }

    if (currentStatus.state == DeviceSosState.preConfirm &&
        currentStatus.expectedActivationAt != null &&
        _now().isBefore(currentStatus.expectedActivationAt!)) {
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: DeviceSosState.preConfirm,
        cycleKey: cycleKey,
        downgradeSuppressed: protocolState == DeviceSosState.active,
        classificationDecision: 'pre_sos',
        classificationReason: protocolState == DeviceSosState.active
            ? 'active_packet_held_until_countdown'
            : 'remote_emergency_trigger',
        reason: protocolState == DeviceSosState.active
            ? 'DEVICE_SOS_ACTIVE_PACKET_HELD_UNTIL_COUNTDOWN'
            : 'DEVICE_SOS_PACKET_PRE_CONFIRM_KEEP_COUNTDOWN',
        decoderNote: protocolState == DeviceSosState.active
            ? 'DEVICE_SOS_ACTIVE_PACKET_HELD_UNTIL_COUNTDOWN'
            : 'DEVICE_SOS_PACKET_PRE_CONFIRM_KEEP_COUNTDOWN',
      );
    }

    if (currentStatus.state == DeviceSosState.preConfirm &&
        currentStatus.expectedActivationAt != null &&
        !_now().isBefore(currentStatus.expectedActivationAt!)) {
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: DeviceSosState.active,
        cycleKey: cycleKey,
        downgradeSuppressed: protocolState == DeviceSosState.preConfirm,
        classificationDecision: 'active_sos',
        classificationReason: protocolState == DeviceSosState.active
            ? 'explicit_active_packet_after_countdown'
            : 'countdown_elapsed_nonzero_sos_packet',
        reason: protocolState == DeviceSosState.active
            ? 'DEVICE_SOS_PACKET_EXPLICIT_ACTIVE_AFTER_COUNTDOWN'
            : 'DEVICE_SOS_NONZERO_PACKET_AFTER_COUNTDOWN',
        decoderNote: protocolState == DeviceSosState.active
            ? 'DEVICE_SOS_PACKET_EXPLICIT_ACTIVE_AFTER_COUNTDOWN'
            : 'DEVICE_SOS_NONZERO_PACKET_AFTER_COUNTDOWN',
      );
    }

    if (currentStatus.state == DeviceSosState.preConfirm && sameCycle) {
      return _MeshPacketResolution(
        protocolState: protocolState,
        resolvedState: DeviceSosState.active,
        cycleKey: cycleKey,
        downgradeSuppressed: protocolState == DeviceSosState.preConfirm,
        classificationDecision: 'active_sos',
        classificationReason: protocolState == DeviceSosState.active
            ? 'explicit_active_packet'
            : 'same_cycle_pre_sos_ignored',
        reason: protocolState == DeviceSosState.active
            ? 'DEVICE_SOS_PACKET_EXPLICIT_ACTIVE'
            : 'DEVICE_SOS_PRE_CONFIRM_RESTART_SUPPRESSED_AFTER_COUNTDOWN',
        decoderNote: protocolState == DeviceSosState.active
            ? 'DEVICE_SOS_PACKET_EXPLICIT_ACTIVE'
            : 'DEVICE_SOS_PRE_CONFIRM_RESTART_SUPPRESSED_AFTER_COUNTDOWN',
      );
    }

    return _MeshPacketResolution(
      protocolState: protocolState,
      resolvedState: protocolState,
      cycleKey: cycleKey,
      downgradeSuppressed: false,
      classificationDecision: protocolState == DeviceSosState.active
          ? 'active_sos'
          : 'pre_sos',
      classificationReason: protocolState == DeviceSosState.active
          ? 'explicit_active_packet'
          : 'remote_emergency_trigger',
      reason: protocolState == DeviceSosState.active
          ? 'DEVICE_SOS_PACKET_EXPLICIT_ACTIVE'
          : 'DEVICE_SOS_PACKET_PRE_CONFIRM_STARTED_COUNTDOWN',
      decoderNote: protocolState == DeviceSosState.active
          ? 'DEVICE_SOS_PACKET_EXPLICIT_ACTIVE'
          : 'DEVICE_SOS_PACKET_PRE_CONFIRM_STARTED_COUNTDOWN',
    );
  }

  DeviceSosState _resolveProtocolSosPacketState(EixamSosPacket packet) {
    switch (packet.sosType) {
      case 0:
        return DeviceSosState.inactive;
      case 2:
      case 3:
        return DeviceSosState.active;
      case 1:
        return DeviceSosState.preConfirm;
      default:
        return DeviceSosState.preConfirm;
    }
  }

  bool _isOpenSosState(DeviceSosState state) {
    return state == DeviceSosState.active ||
        state == DeviceSosState.acknowledged;
  }

  String? _deriveDeviceSosCycleKey({
    required int? nodeId,
    required int? packetId,
  }) {
    if (nodeId == null || packetId == null) {
      return null;
    }
    return '$nodeId:$packetId';
  }

  DeviceSosState _resolveEventState(
    EixamSosEventPacket packet,
    DeviceSosState current,
  ) {
    switch (packet.opcode) {
      case 0xE1:
        return DeviceSosState.inactive;
      case 0xE2:
        return current;
      default:
        return current;
    }
  }

  _EventPacketClassification _classifyEventPacket(
    EixamSosEventPacket packet,
    DeviceSosState nextState,
  ) {
    switch (packet.opcode) {
      case 0xE1:
        return const _EventPacketClassification(
          decision: 'terminal_cancelled',
          reason: 'device_cancel',
        );
      case 0xE2:
        return const _EventPacketClassification(
          decision: 'ignored_event',
          reason: 'app_terminal_ack_ignored',
        );
      default:
        return const _EventPacketClassification(
          decision: 'ignored_event',
          reason: 'unknown_event_packet',
        );
    }
  }

  String _describeEventPacket(EixamSosEventPacket packet) {
    if (packet.isUserDeactivated) {
      return 'user deactivated to cancelled';
    }
    if (packet.isAppCancelAck) {
      return 'app cancel acknowledgment ignored';
    }
    return 'unknown control event';
  }

  String _formatNodeId(int nodeId) {
    final normalized = nodeId & 0xFFFFFFFF;
    return '0x${normalized.toRadixString(16).padLeft(8, '0')} ($nodeId)';
  }

  bool _isClosedState(DeviceSosState state) {
    return state == DeviceSosState.inactive || state == DeviceSosState.resolved;
  }

  DeviceSosStatus _forceTerminalStateAfterMissingCloseAcknowledgement({
    required DeviceSosStatus previous,
    required String terminalAction,
    required String commandRouteLabel,
    required Object error,
  }) {
    final now = _now();
    final nextState = terminalAction == 'resolve'
        ? DeviceSosState.resolved
        : DeviceSosState.inactive;
    _pendingTerminalCommand = null;
    _cancelCountdownTimer();
    _awaitingObservedAppActivation = false;
    BleDebugRegistry.instance.recordEvent(
      'DEVICE_SOS_CLOSE_COMMAND_ACK_TIMEOUT_FORCED_TERMINAL route=$commandRouteLabel action=$terminalAction previousState=${previous.state.name} forcedState=${nextState.name} error=$error',
    );
    _emit(
      _status.copyWith(
        state: nextState,
        previousState: previous.state,
        transitionSource: DeviceSosTransitionSource.app,
        triggerOrigin: previous.triggerOrigin,
        lastEvent:
            'DEVICE_SOS_CLOSE_COMMAND_FORCED_TERMINAL_AFTER_MISSING_ACK action=$terminalAction',
        updatedAt: now,
        optimistic: false,
        derivedFromBlePacket: false,
        countdownStartedAt: null,
        expectedActivationAt: null,
        countdownRemainingSeconds: null,
      ),
    );
    return _status;
  }

  bool _shouldSuppressForPendingTerminalCommand(
    int nodeId, {
    required DeviceSosTransitionSource source,
    required DeviceSosStatus currentStatus,
    required _MeshPacketResolution resolution,
  }) {
    final pending = _pendingTerminalCommand;
    if (pending == null) {
      return false;
    }
    final anchor = pending.sentAt ?? pending.requestedAt;
    if (_now().difference(anchor) > _terminalCycleSuppressionWindow) {
      _pendingTerminalCommand = null;
      return false;
    }
    if (source == DeviceSosTransitionSource.device &&
        currentStatus.state == DeviceSosState.inactive &&
        resolution.protocolState == DeviceSosState.preConfirm &&
        resolution.resolvedState == DeviceSosState.preConfirm) {
      _pendingTerminalCommand = null;
      BleDebugRegistry.instance.recordEvent(
        'SOS_TRACE device_rearm_allowed reason=pending_terminal_command_pre_sos',
      );
      return false;
    }
    return pending.nodeId == null || pending.nodeId == nodeId;
  }

  void _enterPreConfirm({
    required DeviceSosTransitionSource source,
    required String event,
    required DateTime at,
    required bool optimistic,
    required bool derivedFromBlePacket,
    DeviceSosTransitionSource? triggerOriginOverride,
    int? lastOpcode,
    String? lastPacketHex,
    int? lastPacketLength,
    DateTime? lastPacketAt,
    String? lastPacketSignature,
    int? nodeId,
    int? flags,
    int? sosType,
    int? retryCount,
    int? relayCount,
    int? batteryLevel,
    DeviceBatteryLevel? batteryState,
    int? gpsQuality,
    int? packetId,
    bool? hasLocation,
    String? decoderNote,
  }) {
    final isExistingCountdown =
        _status.state == DeviceSosState.preConfirm &&
        _status.countdownStartedAt != null &&
        _status.expectedActivationAt != null;
    final triggerOrigin =
        triggerOriginOverride ?? _resolveTriggerOrigin(source);
    final countdownStartAdjustment = _observedDevicePreSosStartAdjustment(
      derivedFromBlePacket: derivedFromBlePacket,
      triggerOrigin: triggerOrigin,
    );
    final countdownStartedAt = isExistingCountdown
        ? _status.countdownStartedAt!
        : at.subtract(countdownStartAdjustment);
    final expectedActivationAt = isExistingCountdown
        ? _status.expectedActivationAt!
        : countdownStartedAt.add(_countdownDuration);
    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_PRE_SOS_COUNTDOWN] '
      'action=${isExistingCountdown ? "preserve" : "start"} '
      'source=${source.name} origin=${triggerOrigin.name} '
      'previousState=${_status.state.name} '
      'nodeId=${nodeId == null ? "-" : _formatNodeId(nodeId)} '
      'packetId=${packetId?.toString() ?? "-"} '
      'previousPacketId=${_status.packetId?.toString() ?? "-"} '
      'startedAt=${countdownStartedAt.toUtc().toIso8601String()} '
      'deadline=${expectedActivationAt.toUtc().toIso8601String()} '
      'remaining=${_countdownRemainingSeconds(now: at, expectedActivationAt: expectedActivationAt)}',
    );
    if (!isExistingCountdown) {
      _cancelCountdownTimer();
    }
    _emit(
      _status.copyWith(
        state: DeviceSosState.preConfirm,
        previousState: _status.state,
        transitionSource: source,
        triggerOrigin: triggerOrigin,
        lastEvent: event,
        updatedAt: at,
        optimistic: optimistic,
        derivedFromBlePacket: derivedFromBlePacket,
        lastOpcode: lastOpcode,
        lastPacketHex: lastPacketHex,
        lastPacketLength: lastPacketLength,
        lastPacketAt: lastPacketAt,
        lastPacketSignature: lastPacketSignature,
        nodeId: nodeId,
        flags: flags,
        sosType: sosType,
        retryCount: retryCount,
        relayCount: relayCount,
        batteryLevel: batteryLevel,
        batteryState: batteryState,
        gpsQuality: gpsQuality,
        packetId: packetId,
        hasLocation: hasLocation,
        decoderNote: decoderNote,
        countdownStartedAt: countdownStartedAt,
        expectedActivationAt: expectedActivationAt,
        countdownRemainingSeconds: _countdownRemainingSeconds(
          now: at,
          expectedActivationAt: expectedActivationAt,
        ),
      ),
    );
    if (!isExistingCountdown) {
      _startCountdownTimer(expectedActivationAt);
    }
  }

  void _startCountdownTimer(DateTime expectedActivationAt) {
    _countdownTimer = Timer.periodic(_countdownTick, (timer) {
      if (_status.state != DeviceSosState.preConfirm) {
        timer.cancel();
        return;
      }

      final now = _now();
      final remainingSeconds = _countdownRemainingSeconds(
        now: now,
        expectedActivationAt: expectedActivationAt,
      );

      if (remainingSeconds <= 0) {
        timer.cancel();
        _promoteExpiredPreConfirmCountdown(
          event:
              'SOS countdown elapsed after ${_countdownDuration.inSeconds}s.',
          now: now,
        );
        return;
      }

      _emit(
        _status.copyWith(
          updatedAt: now,
          countdownRemainingSeconds: remainingSeconds,
        ),
      );
    });
  }

  int _countdownRemainingSeconds({
    required DateTime now,
    required DateTime expectedActivationAt,
  }) {
    final remaining = expectedActivationAt.difference(now);
    if (remaining <= Duration.zero) {
      return 0;
    }
    return remaining.inSeconds + (remaining.inMilliseconds % 1000 == 0 ? 0 : 1);
  }

  Duration _observedDevicePreSosStartAdjustment({
    required bool derivedFromBlePacket,
    required DeviceSosTransitionSource triggerOrigin,
  }) {
    if (!derivedFromBlePacket ||
        triggerOrigin != DeviceSosTransitionSource.device ||
        _countdownDuration <= _observedDevicePreSosSkew) {
      return Duration.zero;
    }
    return _observedDevicePreSosSkew;
  }

  DeviceSosStatus _promoteExpiredPreConfirmCountdown({
    required String event,
    DateTime? now,
  }) {
    final resolvedNow = now ?? _now();
    _rememberPromotedPreConfirmCycle(_status);
    _cancelCountdownTimer();
    BleDebugRegistry.instance.recordEvent(
      '[DEVICE_PRE_SOS_COUNTDOWN] action=promote_to_active '
      'origin=${_status.triggerOrigin.name} '
      'nodeId=${_status.nodeId == null ? "-" : _formatNodeId(_status.nodeId!)} '
      'packetId=${_status.packetId?.toString() ?? "-"} '
      'startedAt=${_status.countdownStartedAt?.toUtc().toIso8601String() ?? "-"} '
      'deadline=${_status.expectedActivationAt?.toUtc().toIso8601String() ?? "-"} '
      'now=${resolvedNow.toUtc().toIso8601String()}',
    );
    _emit(
      _status.copyWith(
        state: DeviceSosState.active,
        previousState: DeviceSosState.preConfirm,
        transitionSource: _status.triggerOrigin,
        triggerOrigin: _status.triggerOrigin,
        lastEvent: event,
        updatedAt: resolvedNow,
        optimistic: false,
        derivedFromBlePacket: false,
        decoderNote: 'DEVICE_SOS_PRE_CONFIRM_PROMOTED_AFTER_COUNTDOWN',
        countdownRemainingSeconds: 0,
      ),
    );
    return _status;
  }

  void _rememberPromotedPreConfirmCycle(DeviceSosStatus status) {
    final cycleKey = _deriveDeviceSosCycleKey(
      nodeId: status.nodeId,
      packetId: status.packetId,
    );
    if (cycleKey == null) {
      return;
    }
    _lastPromotedPreConfirmCycleKey = cycleKey;
    _lastPromotedPreConfirmAt = _now();
  }

  bool _shouldSuppressPromotedPreConfirmCycle({
    required String? cycleKey,
    required DeviceSosStatus currentStatus,
  }) {
    final promotedCycleKey = _lastPromotedPreConfirmCycleKey;
    final promotedAt = _lastPromotedPreConfirmAt;
    if (cycleKey == null || promotedCycleKey == null || promotedAt == null) {
      return false;
    }
    if (!_isOpenSosState(currentStatus.state)) {
      return false;
    }
    if (cycleKey != promotedCycleKey) {
      return false;
    }
    if (_now().difference(promotedAt) > _promotedPreConfirmSuppressionWindow) {
      _lastPromotedPreConfirmCycleKey = null;
      _lastPromotedPreConfirmAt = null;
      return false;
    }
    return true;
  }

  DeviceSosTransitionSource _resolveTriggerOrigin(
    DeviceSosTransitionSource source,
  ) {
    if (source == DeviceSosTransitionSource.app ||
        source == DeviceSosTransitionSource.device) {
      return source;
    }
    return _status.triggerOrigin;
  }

  DeviceSosTransitionSource _resolveObservedTriggerOrigin(
    DeviceSosTransitionSource source, {
    int? nodeId,
  }) {
    final currentOrigin = _status.triggerOrigin;
    final currentNodeId = _status.nodeId;
    final keepsExistingAppCycle =
        currentOrigin == DeviceSosTransitionSource.app &&
        _status.state != DeviceSosState.inactive &&
        _status.state != DeviceSosState.resolved &&
        (currentNodeId == null || nodeId == null || currentNodeId == nodeId);
    if (keepsExistingAppCycle) {
      return DeviceSosTransitionSource.app;
    }
    return _resolveTriggerOrigin(source);
  }

  void _cancelCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  bool _isObservedPreConfirmForAppActivation(DeviceSosStatus status) {
    return status.state == DeviceSosState.preConfirm &&
        !status.optimistic &&
        status.derivedFromBlePacket;
  }

  bool _isObservedActiveForAppActivation(DeviceSosStatus status) {
    return status.state == DeviceSosState.active &&
        !status.optimistic &&
        status.derivedFromBlePacket;
  }

  bool _isObservedClosedAfterCancel(DeviceSosStatus status) {
    return (status.state == DeviceSosState.inactive ||
            status.state == DeviceSosState.resolved) &&
        !status.optimistic &&
        status.derivedFromBlePacket;
  }

  Future<DeviceSosStatus> _waitForStatus({
    required String description,
    required bool Function(DeviceSosStatus status) predicate,
  }) async {
    if (predicate(_status)) {
      return _status;
    }
    final completer = Completer<DeviceSosStatus>();
    late final StreamSubscription<DeviceSosStatus> subscription;
    subscription = _controller.stream.listen((status) {
      if (predicate(status) && !completer.isCompleted) {
        completer.complete(status);
      }
    });
    try {
      return await completer.future.timeout(
        _appActivationObservationTimeout,
        onTimeout: () => throw DeviceException(
          'E_DEVICE_SOS_STATUS_WAIT_TIMEOUT',
          'E_DEVICE_SOS_STATUS_WAIT_TIMEOUT description=$description last_state=${_status.state.name} optimistic=${_status.optimistic} derivedFromBle=${_status.derivedFromBlePacket}',
        ),
      );
    } finally {
      await subscription.cancel();
    }
  }

  void _emit(DeviceSosStatus next) {
    _status = next;
    _controller.add(next);
  }

  void _emitCommandPathAvailabilityIfChanged(bool previousAvailability) {
    if (previousAvailability == hasSosCommandPath ||
        _commandPathController.isClosed) {
      return;
    }
    _commandPathController.add(hasSosCommandPath);
  }

  void _emitControlCommandPathAvailabilityIfChanged(bool previousAvailability) {
    if (previousAvailability == hasCommandChannel ||
        _controlCommandPathController.isClosed) {
      return;
    }
    _controlCommandPathController.add(hasCommandChannel);
  }

  Future<void> dispose() async {
    _awaitingObservedAppActivation = false;
    _pendingTerminalCommand = null;
    _cancelCountdownTimer();
    await _controlCommandPathController.close();
    await _commandPathController.close();
    await _controller.close();
  }
}

class _PendingTerminalDeviceCommand {
  const _PendingTerminalDeviceCommand({
    required this.action,
    required this.nodeId,
    required this.requestedAt,
    this.commandWriterOverride,
    this.commandRouteLabel,
    this.sentAt,
  });

  final String action;
  final int? nodeId;
  final DateTime requestedAt;
  final DeviceCommandWriter? commandWriterOverride;
  final String? commandRouteLabel;
  final DateTime? sentAt;

  _PendingTerminalDeviceCommand copyWith({DateTime? sentAt}) {
    return _PendingTerminalDeviceCommand(
      action: action,
      nodeId: nodeId,
      requestedAt: requestedAt,
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
      sentAt: sentAt ?? this.sentAt,
    );
  }
}

class _MeshPacketResolution {
  const _MeshPacketResolution({
    required this.protocolState,
    required this.resolvedState,
    required this.cycleKey,
    required this.downgradeSuppressed,
    required this.classificationDecision,
    required this.classificationReason,
    required this.reason,
    required this.decoderNote,
  });

  final DeviceSosState protocolState;
  final DeviceSosState resolvedState;
  final String? cycleKey;
  final bool downgradeSuppressed;
  final String classificationDecision;
  final String classificationReason;
  final String reason;
  final String decoderNote;
}

class _EventPacketClassification {
  const _EventPacketClassification({
    required this.decision,
    required this.reason,
  });

  final String decision;
  final String reason;
}
