import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import 'ble_debug_registry.dart';
import 'eixam_ble_command.dart';
import 'eixam_sos_packet.dart';

typedef DeviceCommandWriter = Future<void> Function(EixamDeviceCommand command);

class DeviceSosController {
  DeviceSosController() {
    _controller.add(_status);
  }

  final StreamController<DeviceSosStatus> _controller =
      StreamController<DeviceSosStatus>.broadcast();

  DeviceCommandWriter? _commandWriter;
  DeviceSosStatus _status = DeviceSosStatus.initial();

  DeviceSosStatus get currentStatus => _status;

  Future<void> attach({required DeviceCommandWriter commandWriter}) async {
    _commandWriter = commandWriter;
  }

  Future<void> detach() async {
    _commandWriter = null;
    _emit(
      DeviceSosStatus(
        state: DeviceSosState.inactive,
        previousState: _status.state,
        transitionSource: DeviceSosTransitionSource.unknown,
        lastEvent: 'Device SOS controller detached',
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<DeviceSosStatus> getStatus() async => _status;

  Stream<DeviceSosStatus> watchStatus() => _controller.stream;

  Future<DeviceSosStatus> triggerSos() {
    return _sendCommand(
      command: EixamDeviceCommand.sosTriggerApp(),
      optimisticState: DeviceSosState.preConfirm,
      optimisticEvent: 'App triggered SOS on device',
      failureEvent: 'SOS trigger write failed',
    );
  }

  Future<DeviceSosStatus> confirmSos() {
    return _sendCommand(
      command: EixamDeviceCommand.sosConfirm(),
      optimisticState: DeviceSosState.active,
      optimisticEvent: 'App confirmed SOS on device',
      failureEvent: 'SOS confirm write failed',
    );
  }

  Future<DeviceSosStatus> cancelSos() {
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
    );
  }

  Future<DeviceSosStatus> acknowledgeSos() {
    return _sendCommand(
      command: EixamDeviceCommand.sosAck(),
      optimisticState: DeviceSosState.acknowledged,
      optimisticEvent: 'App sent backend acknowledgment to device',
      failureEvent: 'Backend acknowledgment write failed',
    );
  }

  Future<void> sendInetOk() => _sendNonSosCommand(EixamDeviceCommand.inetOk());

  Future<void> sendInetLost() =>
      _sendNonSosCommand(EixamDeviceCommand.inetLost());

  Future<void> sendPositionConfirmed() =>
      _sendNonSosCommand(EixamDeviceCommand.positionConfirmed());

  Future<void> sendAckRelay({required int nodeId}) {
    return _sendNonSosCommand(EixamDeviceCommand.sosAckRelay(nodeId: nodeId));
  }

  Future<void> sendShutdown() =>
      _sendNonSosCommand(EixamDeviceCommand.shutdown());

  Future<DeviceSosStatus> _sendCommand({
    required EixamDeviceCommand command,
    required DeviceSosState optimisticState,
    required String optimisticEvent,
    required String failureEvent,
  }) async {
    final writer = _commandWriter;
    if (writer == null) {
      throw StateError('Device SOS command channel is not ready.');
    }

    final previous = _status;
    _emit(
      DeviceSosStatus(
        state: optimisticState,
        previousState: previous.state,
        transitionSource: DeviceSosTransitionSource.app,
        lastEvent: optimisticEvent,
        updatedAt: DateTime.now(),
        optimistic: true,
        derivedFromBlePacket: false,
        lastOpcode: command.opcode,
        decoderNote:
            'Optimistic local transition pending BLE/device confirmation.',
      ),
    );

    try {
      await writer(command);
      BleDebugRegistry.instance.recordEvent(
        'Device SOS command sent: ${command.label} previousState=${previous.state.name}',
      );
      return _status;
    } catch (error, stackTrace) {
      _emit(
        previous.copyWith(
          lastEvent: '$failureEvent: $error',
          updatedAt: DateTime.now(),
          optimistic: false,
          previousState: previous.state,
          transitionSource: DeviceSosTransitionSource.app,
          lastOpcode: command.opcode,
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'Device SOS command failed: ${command.label} error=$error',
      );
      debugPrint(
        'Device SOS command failed -> opcode=${command.opcode} error=$error',
      );
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _sendNonSosCommand(EixamDeviceCommand command) async {
    final writer = _commandWriter;
    if (writer == null) {
      throw StateError('Device command channel is not ready.');
    }
    await writer(command);
  }

  void handleIncomingSosPacket(
    EixamSosPacket packet, {
    required DeviceSosTransitionSource source,
  }) {
    final previous = _status.state;
    final nextState = packet.sosType == 0 ? previous : DeviceSosState.active;
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

    _emit(
      _status.copyWith(
        state: nextState,
        previousState: previous,
        transitionSource: source,
        lastEvent: event,
        updatedAt: DateTime.now(),
        optimistic: false,
        derivedFromBlePacket: true,
        lastPacketHex: packet.rawHex,
        lastPacketLength: packet.rawBytes.length,
        lastPacketAt: DateTime.now(),
        lastPacketSignature: '${packet.nodeId}:${packet.packetId}:${packet.rawHex}',
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
            'Decoded from the SOS characteristic using the current protocol document. Runtime phase is kept intentionally minimal because the BLE payload no longer relies on the old ad-hoc status-byte mapping.',
      ),
    );
  }

  String _formatNodeId(int nodeId) {
    final normalized = nodeId & 0xFFFF;
    return '0x${normalized.toRadixString(16).padLeft(4, '0')}';
  }

  void _emit(DeviceSosStatus next) {
    _status = next;
    _controller.add(next);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}
