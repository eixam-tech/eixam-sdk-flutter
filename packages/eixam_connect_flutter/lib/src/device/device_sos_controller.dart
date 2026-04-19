import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import 'ble_debug_registry.dart';
import 'eixam_ble_command.dart';
import 'eixam_sos_event_packet.dart';
import 'eixam_sos_packet.dart';

typedef DeviceCommandWriter = Future<void> Function(EixamDeviceCommand command);

class DeviceSosController {
  DeviceSosController({
    Duration countdownDuration = const Duration(seconds: 20),
    Duration countdownTick = const Duration(seconds: 1),
    DateTime Function()? now,
  })  : _countdownDuration = countdownDuration,
        _countdownTick = countdownTick,
        _now = now ?? DateTime.now {
    _controller.add(_status);
  }

  final StreamController<DeviceSosStatus> _controller =
      StreamController<DeviceSosStatus>.broadcast();
  final StreamController<bool> _commandPathController =
      StreamController<bool>.broadcast();

  DeviceCommandWriter? _commandWriter;
  DeviceSosStatus _status = DeviceSosStatus.initial();
  final Duration _countdownDuration;
  final Duration _countdownTick;
  final DateTime Function() _now;
  Timer? _countdownTimer;

  DeviceSosStatus get currentStatus => _status;
  bool get hasSosCommandPath => _commandWriter != null;
  bool get hasCommandChannel => hasSosCommandPath;
  Stream<bool> watchCommandPathAvailability() async* {
    yield hasSosCommandPath;
    yield* _commandPathController.stream;
  }

  Future<void> attach({required DeviceCommandWriter commandWriter}) async {
    final previousAvailability = hasSosCommandPath;
    _commandWriter = commandWriter;
    BleDebugRegistry.instance.recordEvent(
      'Device SOS command path attached -> available=$hasSosCommandPath previous=$previousAvailability',
    );
    _emitCommandPathAvailabilityIfChanged(previousAvailability);
    _emit(
      _status.copyWith(
        lastEvent: 'Device SOS command channel attached',
        updatedAt: _now(),
      ),
    );
  }

  Future<void> detach() async {
    final previousAvailability = hasSosCommandPath;
    _commandWriter = null;
    BleDebugRegistry.instance.recordEvent(
      'Device SOS command path detached -> available=$hasSosCommandPath previous=$previousAvailability',
    );
    _emitCommandPathAvailabilityIfChanged(previousAvailability);
    _cancelCountdownTimer();
    _emit(
      DeviceSosStatus(
        state: DeviceSosState.inactive,
        previousState: _status.state,
        transitionSource: DeviceSosTransitionSource.unknown,
        triggerOrigin: DeviceSosTransitionSource.unknown,
        lastEvent: 'Device SOS controller detached',
        updatedAt: _now(),
      ),
    );
  }

  Future<DeviceSosStatus> getStatus() async => _status;

  Stream<DeviceSosStatus> watchStatus() => _controller.stream;

  Future<DeviceSosStatus> triggerSos({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) {
    return _sendCommand(
      command: EixamDeviceCommand.sosTriggerApp(),
      optimisticState: DeviceSosState.preConfirm,
      optimisticEvent: 'App triggered SOS on device',
      failureEvent: 'SOS trigger write failed',
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
  }

  Future<DeviceSosStatus> activateSosFromApp({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) async {
    await triggerSos(
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
    try {
      final active = await confirmSos(
        commandWriterOverride: commandWriterOverride,
        commandRouteLabel: commandRouteLabel,
      );
      BleDebugRegistry.instance.recordEvent(
        'App SOS device activation completed -> route=$commandRouteLabel state=${active.state.name}',
      );
      return active;
    } catch (error) {
      BleDebugRegistry.instance.recordEvent(
        'App SOS device activation incomplete -> route=$commandRouteLabel state=${_status.state.name} error=$error note=device_stayed_in_pre_sos',
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
          lastEvent:
              'SOS confirm ignored because the device is not in pre-confirmation.',
          updatedAt: _now(),
        ),
      );
    }
    return _sendCommand(
      command: EixamDeviceCommand.sosConfirm(),
      optimisticState: DeviceSosState.active,
      optimisticEvent: 'App confirmed SOS on device',
      failureEvent: 'SOS confirm write failed',
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
  }

  Future<DeviceSosStatus> cancelSos({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) {
    final nextState = switch (_status.state) {
      DeviceSosState.preConfirm => DeviceSosState.inactive,
      DeviceSosState.active => DeviceSosState.resolved,
      DeviceSosState.acknowledged => DeviceSosState.resolved,
      DeviceSosState.resolved => DeviceSosState.resolved,
      _ => DeviceSosState.inactive,
    };

    return _sendCommand(
      command: EixamDeviceCommand.sosCancel(),
      optimisticState: nextState,
      optimisticEvent: 'App cancelled SOS on device',
      failureEvent: 'SOS cancel write failed',
      commandWriterOverride: commandWriterOverride,
      commandRouteLabel: commandRouteLabel,
    );
  }

  Future<DeviceSosStatus> acknowledgeSos({
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) {
    if (_status.state != DeviceSosState.active) {
      return Future<DeviceSosStatus>.value(
        _status.copyWith(
          lastEvent:
              'Backend acknowledgment ignored because the SOS is not active.',
          updatedAt: _now(),
        ),
      );
    }
    return _sendCommand(
      command: EixamDeviceCommand.sosAck(),
      optimisticState: DeviceSosState.acknowledged,
      optimisticEvent: 'App sent backend acknowledgment to device',
      failureEvent: 'Backend acknowledgment write failed',
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
      throw StateError('Device SOS command channel is not ready.');
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
            'Optimistic local transition pending BLE/device confirmation.',
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
              'Optimistic local transition pending BLE/device confirmation.',
          countdownStartedAt: null,
          expectedActivationAt: null,
          countdownRemainingSeconds: null,
        ),
      );
    }

    try {
      BleDebugRegistry.instance.recordEvent(
        'Device SOS command dispatch -> route=$commandRouteLabel command=${command.label} previousState=${previous.state.name}',
      );
      await writer(command);
      BleDebugRegistry.instance.recordEvent(
        'Device SOS command sent -> route=$commandRouteLabel command=${command.label} previousState=${previous.state.name}',
      );
      return _status;
    } catch (error, stackTrace) {
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
        'Device SOS command failed -> route=$commandRouteLabel command=${command.label} error=$error',
      );
      debugPrint(
        'Device SOS command failed -> opcode=${command.opcode} error=$error',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _sendNonSosCommand(
    EixamDeviceCommand command, {
    DeviceCommandWriter? commandWriterOverride,
    String commandRouteLabel = 'attached_writer',
  }) async {
    final writer = commandWriterOverride ?? _commandWriter;
    if (writer == null) {
      throw StateError('Device command channel is not ready.');
    }
    BleDebugRegistry.instance.recordEvent(
      'Device command dispatch -> route=$commandRouteLabel command=${command.label}',
    );
    await writer(command);
    BleDebugRegistry.instance.recordEvent(
      'Device command sent -> route=$commandRouteLabel command=${command.label}',
    );
  }

  void handleIncomingSosPacket(
    EixamSosPacket packet, {
    required DeviceSosTransitionSource source,
  }) {
    final previous = _status.state;
    final now = _now();
    final nextState = _resolveMeshPacketState(packet, source: source);
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

    if (nextState == DeviceSosState.preConfirm) {
      _enterPreConfirm(
        source: source,
        event: event,
        at: now,
        optimistic: false,
        derivedFromBlePacket: true,
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
        decoderNote:
            'The BLE SOS notify packet does not expose a distinct countdown-vs-active bit. The SDK treats the first SOS packet in a new cycle as preConfirm and owns the 20-second timeout locally unless a later cancel/confirm/active signal overrides it.',
      );
      return;
    }

    final keepCountdownMetadata = nextState == DeviceSosState.active &&
        _status.state == DeviceSosState.preConfirm;
    if (nextState != DeviceSosState.preConfirm) {
      _cancelCountdownTimer();
    }
    _emit(
      _status.copyWith(
        state: nextState,
        previousState: previous,
        transitionSource: source,
        triggerOrigin: _resolveTriggerOrigin(source),
        lastEvent: event,
        updatedAt: now,
        optimistic: false,
        derivedFromBlePacket: true,
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
        decoderNote: nextState == DeviceSosState.active
            ? 'Decoded SOS mesh packet from the SOS characteristic and kept the SOS active because this cycle had already advanced beyond the local countdown window.'
            : 'Decoded SOS mesh packet from the SOS characteristic and mapped it to preConfirm while the local 20-second countdown is pending.',
        countdownStartedAt:
            keepCountdownMetadata ? _status.countdownStartedAt : null,
        expectedActivationAt:
            keepCountdownMetadata ? _status.expectedActivationAt : null,
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
    final controlEventLabel = _describeEventPacket(packet);
    final event = 'SOS device event decoded -> $controlEventLabel '
        'nodeId=${_formatNodeId(packet.nodeId)} '
        'subcode=0x${packet.subcode.toRadixString(16).padLeft(2, '0')}';

    BleDebugRegistry.instance.recordEvent(event);
    BleDebugRegistry.instance.recordEvent(
      'SOS transition -> ${previous.name} -> ${nextState.name}',
    );

    if (nextState == DeviceSosState.inactive ||
        nextState == DeviceSosState.resolved) {
      _cancelCountdownTimer();
    }
    _emit(
      _status.copyWith(
        state: nextState,
        previousState: previous,
        transitionSource: source,
        triggerOrigin: nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? _status.triggerOrigin
            : _resolveTriggerOrigin(source),
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
        packetId: null,
        hasLocation: false,
        decoderNote:
            'Decoded SOS device control event ($controlEventLabel) from the SOS characteristic.',
        countdownStartedAt: nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? null
            : _status.countdownStartedAt,
        expectedActivationAt: nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? null
            : _status.expectedActivationAt,
        countdownRemainingSeconds: nextState == DeviceSosState.inactive ||
                nextState == DeviceSosState.resolved
            ? null
            : _status.countdownRemainingSeconds,
      ),
    );
  }

  DeviceSosState _resolveMeshPacketState(
    EixamSosPacket packet, {
    required DeviceSosTransitionSource source,
  }) {
    if (packet.sosType == 0) {
      return _status.state;
    }

    if (_status.state == DeviceSosState.acknowledged) {
      return DeviceSosState.acknowledged;
    }

    if (_status.state == DeviceSosState.active) {
      return DeviceSosState.active;
    }

    if (_status.state == DeviceSosState.preConfirm &&
        _status.expectedActivationAt != null &&
        _now().isBefore(_status.expectedActivationAt!)) {
      return DeviceSosState.preConfirm;
    }

    if (_status.state == DeviceSosState.preConfirm) {
      return DeviceSosState.active;
    }

    if (source == DeviceSosTransitionSource.device ||
        source == DeviceSosTransitionSource.app) {
      // The BLE protocol does not emit a dedicated device-countdown packet.
      // For a new SOS cycle, the first mesh packet is therefore treated as a
      // pre-confirm/preventive state and only promoted later by confirm or the
      // local countdown timeout.
      return DeviceSosState.preConfirm;
    }

    return DeviceSosState.active;
  }

  DeviceSosState _resolveEventState(
    EixamSosEventPacket packet,
    DeviceSosState current,
  ) {
    switch (packet.opcode) {
      case 0xE1:
        if (packet.subcode == 0x01) {
          return DeviceSosState.inactive;
        }
        if (packet.subcode == 0x02) {
          return DeviceSosState.resolved;
        }
        return current;
      case 0xE2:
        if (packet.subcode == 0x01) {
          return DeviceSosState.inactive;
        }
        if (packet.subcode == 0x02 || packet.subcode == 0x03) {
          return DeviceSosState.resolved;
        }
        return current;
      default:
        return current;
    }
  }

  String _describeEventPacket(EixamSosEventPacket packet) {
    if (packet.isUserDeactivated) {
      return switch (packet.subcode) {
        0x01 => 'user deactivated to inactive',
        0x02 => 'user deactivated to resolved',
        _ => 'user deactivated event',
      };
    }
    if (packet.isAppCancelAck) {
      return switch (packet.subcode) {
        0x01 => 'app cancel acknowledged as inactive',
        0x02 => 'app cancel acknowledged as resolved',
        0x03 => 'app cancel acknowledged as resolved',
        _ => 'app cancel acknowledgment',
      };
    }
    return 'unknown control event';
  }

  String _formatNodeId(int nodeId) {
    final normalized = nodeId & 0xFFFF;
    return '0x${normalized.toRadixString(16).padLeft(4, '0')}';
  }

  void _enterPreConfirm({
    required DeviceSosTransitionSource source,
    required String event,
    required DateTime at,
    required bool optimistic,
    required bool derivedFromBlePacket,
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
    final isExistingCountdown = _status.state == DeviceSosState.preConfirm &&
        _status.countdownStartedAt != null &&
        _status.expectedActivationAt != null;
    final countdownStartedAt =
        isExistingCountdown ? _status.countdownStartedAt! : at;
    final expectedActivationAt = isExistingCountdown
        ? _status.expectedActivationAt!
        : at.add(_countdownDuration);
    final triggerOrigin = _resolveTriggerOrigin(source);
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
        _emit(
          _status.copyWith(
            state: DeviceSosState.active,
            previousState: DeviceSosState.preConfirm,
            transitionSource: _status.triggerOrigin,
            triggerOrigin: _status.triggerOrigin,
            lastEvent:
                'SOS countdown elapsed after ${_countdownDuration.inSeconds}s.',
            updatedAt: now,
            optimistic: false,
            derivedFromBlePacket: false,
            decoderNote:
                'The SDK promoted preConfirm to active after the protocol-defined 20-second countdown because no distinct countdown-finished BLE packet was observed.',
            countdownRemainingSeconds: 0,
          ),
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

  DeviceSosTransitionSource _resolveTriggerOrigin(
    DeviceSosTransitionSource source,
  ) {
    if (source == DeviceSosTransitionSource.app ||
        source == DeviceSosTransitionSource.device) {
      return source;
    }
    return _status.triggerOrigin;
  }

  void _cancelCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
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

  Future<void> dispose() async {
    _cancelCountdownTimer();
    await _commandPathController.close();
    await _controller.close();
  }
}
