import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import 'ble_debug_registry.dart';
import 'device_sos_packet.dart';

typedef DeviceCommandWriter = Future<void> Function(List<int> data);

class DeviceSosController {
  DeviceSosController() {
    _controller.add(_status);
  }

  static const int _sosCancel = 0x04;
  static const int _sosConfirm = 0x05;
  static const int _sosTriggerApp = 0x06;
  static const int _sosAck = 0x07;
  static const int _sosAckRelay = 0x08;

  final StreamController<DeviceSosStatus> _controller =
      StreamController<DeviceSosStatus>.broadcast();

  StreamSubscription<List<int>>? _notificationSubscription;
  DeviceCommandWriter? _commandWriter;
  DeviceSosStatus _status = DeviceSosStatus.initial();

  DeviceSosStatus get currentStatus => _status;

  Future<void> attach({
    required Stream<List<int>> notifications,
    required DeviceCommandWriter commandWriter,
  }) async {
    await _notificationSubscription?.cancel();
    _commandWriter = commandWriter;
    _notificationSubscription = notifications.listen(
      _handlePacket,
      onError: (Object error) {
        BleDebugRegistry.instance.recordEvent(
          'Device SOS notification error: $error',
        );
      },
    );
  }

  Future<void> detach() async {
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _commandWriter = null;
    _emit(
      DeviceSosStatus(
        state: DeviceSosState.inactive,
        lastEvent: 'Device SOS controller detached',
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<DeviceSosStatus> getStatus() async => _status;

  Stream<DeviceSosStatus> watchStatus() => _controller.stream;

  Future<DeviceSosStatus> triggerSos() {
    return _sendCommand(
      opcode: _sosTriggerApp,
      optimisticState: DeviceSosState.preConfirm,
      optimisticEvent: 'App triggered SOS on device',
      failureEvent: 'SOS trigger write failed',
    );
  }

  Future<DeviceSosStatus> confirmSos() {
    return _sendCommand(
      opcode: _sosConfirm,
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
      opcode: _sosCancel,
      optimisticState: nextState,
      optimisticEvent: 'App cancelled SOS on device',
      failureEvent: 'SOS cancel write failed',
    );
  }

  Future<DeviceSosStatus> acknowledgeSos() {
    return _sendCommand(
      opcode: _sosAck,
      optimisticState: DeviceSosState.acknowledged,
      optimisticEvent: 'App acknowledged SOS on device',
      failureEvent: 'SOS acknowledge write failed',
    );
  }

  Future<DeviceSosStatus> _sendCommand({
    required int opcode,
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
        lastEvent: optimisticEvent,
        updatedAt: DateTime.now(),
        optimistic: true,
        derivedFromBlePacket: false,
        lastOpcode: opcode,
        decoderNote: 'Optimistic local transition pending BLE/device confirmation.',
      ),
    );

    try {
      await writer(<int>[opcode]);
      BleDebugRegistry.instance.recordEvent(
        'Device SOS command sent: ${_opcodeLabel(opcode)}',
      );
      return _status;
    } catch (error, stackTrace) {
      _emit(
        previous.copyWith(
          lastEvent: '$failureEvent: $error',
          updatedAt: DateTime.now(),
          optimistic: false,
          lastOpcode: opcode,
        ),
      );
      BleDebugRegistry.instance.recordEvent(
        'Device SOS command failed: ${_opcodeLabel(opcode)} error=$error',
      );
      debugPrint('Device SOS command failed -> opcode=$opcode error=$error');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  void _handlePacket(List<int> packet) {
    if (packet.isEmpty) {
      return;
    }

    final parsed = DeviceSosPacket.tryParse(
      packet,
      previousState: _status.state,
    );
    if (parsed == null) {
      BleDebugRegistry.instance.recordEvent(
        'Ignored SOS notify packet with unexpected length ${packet.length}: ${_hex(packet)}',
      );
      return;
    }

    final previous = _status.state;
    final event =
        'SOS notify decoded -> nodeId=${parsed.nodeId} '
        'flags=0x${parsed.flags.toRadixString(16).padLeft(2, '0')} '
        'counter=${parsed.counter} '
        'marker=0x${parsed.marker.toRadixString(16).padLeft(2, '0')} '
        'statusByte=0x${parsed.statusByte.toRadixString(16).padLeft(2, '0')} '
        'derived=${parsed.derivedState.name}';
    BleDebugRegistry.instance.recordEvent(event);
    BleDebugRegistry.instance.recordEvent(
      'SOS transition -> ${previous.name} -> ${parsed.derivedState.name}',
    );
    if (parsed.decoderNote.isNotEmpty) {
      BleDebugRegistry.instance.recordEvent(
        'SOS decoder note -> ${parsed.decoderNote}',
      );
    }

    _emit(
      _status.copyWith(
        state: parsed.derivedState,
        lastEvent: event,
        updatedAt: DateTime.now(),
        optimistic: false,
        derivedFromBlePacket: true,
        lastPacketHex: parsed.rawHex,
        lastPacketLength: parsed.rawBytes.length,
        lastPacketAt: DateTime.now(),
        nodeId: parsed.nodeId,
        flags: parsed.flags,
        marker: parsed.marker,
        statusByte: parsed.statusByte,
        decoderNote: parsed.decoderNote,
      ),
    );
  }

  String _opcodeLabel(int opcode) {
    switch (opcode) {
      case 0x00:
        return 'SOS_INACTIVE';
      case 0x01:
        return 'SOS_PRE_CONFIRM';
      case 0x02:
        return 'SOS_ACTIVE';
      case 0x03:
        return 'SOS_ACKNOWLEDGED';
      case 0x09:
        return 'SOS_RESOLVED';
      case _sosCancel:
        return 'SOS_CANCEL';
      case _sosConfirm:
        return 'SOS_CONFIRM';
      case _sosTriggerApp:
        return 'SOS_TRIGGER_APP';
      case _sosAck:
        return 'SOS_ACK';
      case _sosAckRelay:
        return 'SOS_ACK_RELAY';
      default:
        return '0x${opcode.toRadixString(16).padLeft(2, '0')}';
    }
  }

  void _emit(DeviceSosStatus next) {
    _status = next;
    _controller.add(next);
  }

  String _hex(List<int> data) {
    return data
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(' ');
  }

  Future<void> dispose() async {
    await _notificationSubscription?.cancel();
    await _controller.close();
  }
}
