import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_debug_registry.dart';
import '../device/ble_incoming_event.dart';
import '../device/eixam_ble_command.dart';
import '../device/eixam_ble_protocol.dart';
import '../device/eixam_nearby_text_packet.dart';
import '../provisioning/provisioning_command_result.dart';

class NearbyTextController {
  NearbyTextController({
    required Stream<BleIncomingEvent> incomingEvents,
    required this.writeCommand,
    this.txTimeout = const Duration(seconds: 8),
    int Function()? packetIdFactory,
  }) : _packetIdFactory = packetIdFactory ?? _nextPacketId {
    _incomingController = StreamController<NearbyIncomingText>.broadcast(
      onListen: _flushBufferedIncoming,
    );
    _txStatusController = StreamController<NearbyTextTxResult>.broadcast(
      onListen: _flushBufferedTxStatus,
    );
    _incomingSub = incomingEvents.listen(_onIncoming);
  }

  final Future<void> Function(EixamDeviceCommand command) writeCommand;
  final Duration txTimeout;
  final int Function() _packetIdFactory;

  late final StreamController<NearbyIncomingText> _incomingController;
  final StreamController<NearbyNodeName> _namesController =
      StreamController<NearbyNodeName>.broadcast();
  late final StreamController<NearbyTextTxResult> _txStatusController;
  final List<NearbyIncomingText> _bufferedIncoming = <NearbyIncomingText>[];
  final List<NearbyTextTxResult> _bufferedTxStatus = <NearbyTextTxResult>[];
  final Map<int, Completer<NearbyTextTxStatus>> _pending =
      <int, Completer<NearbyTextTxStatus>>{};
  Completer<ProvisioningCommandResult>? _groupAck;
  Completer<ProvisioningCommandResult>? _ownerAck;
  StreamSubscription<BleIncomingEvent>? _incomingSub;
  Future<void>? _inflight;
  bool _disposed = false;
  bool _groupEpochValid = true;
  bool _sawDisconnect = false;
  bool _connected = false;
  String? _cachedOwnerName;

  Stream<NearbyIncomingText> get incoming => _incomingController.stream;

  Stream<NearbyNodeName> get nodeNames => _namesController.stream;

  Stream<NearbyTextTxResult> get txStatus => _txStatusController.stream;

  /// E9 7A has no transaction id. After a group timeout, ignore further `0x41`
  /// ACKs for a short drain, then retry while this TAG stays connected.
  void markDisconnected() {
    if (_disposed) {
      return;
    }
    _connected = false;
    _groupEpochValid = false;
    _sawDisconnect = true;
    _failPendingTx(NearbyTextTxStatus.disconnected);
    _failGroupAck();
    _failOwnerAck();
  }

  void markConnected() {
    if (_disposed) {
      return;
    }
    _connected = true;
    if (_sawDisconnect) {
      _sawDisconnect = false;
      _groupEpochValid = true;
    }
    final name = _cachedOwnerName;
    if (name != null && name.isNotEmpty) {
      unawaited(setOwnerDisplayName(name));
    }
  }

  /// Connected status repeats. Restore the group epoch if a disconnect was
  /// missed, without pushing the owner name on every GPS tick.
  void noteStillConnected() {
    if (_disposed) {
      return;
    }
    _connected = true;
    if (_sawDisconnect) {
      _sawDisconnect = false;
      _groupEpochValid = true;
    }
  }

  Future<void> setOwnerDisplayName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return;
    }
    _cachedOwnerName = _clipOwnerName(trimmed);
    if (_disposed || !_connected) {
      return;
    }
    await _enqueue(() => _writeOwnerName(_cachedOwnerName!));
  }

  Future<NearbyTextTxResult> sendBroadcast(String text) {
    return _enqueue(
      () => _sendOnce(
        text,
        destNodeId: EixamBleProtocol.nearbyTextBroadcastDest,
        groupId: 0,
        maxBytes: EixamBleProtocol.nearbyTextPayloadMaxBytes,
      ),
    );
  }

  Future<NearbyTextTxResult> sendDirect(
    String text, {
    required int destNodeId,
  }) {
    final dest = destNodeId.toUnsigned(32);
    if (dest == 0 || dest == EixamBleProtocol.nearbyTextBroadcastDest) {
      return Future<NearbyTextTxResult>.value(
        const NearbyTextTxResult(
          packetId: 0,
          status: NearbyTextTxStatus.badFrame,
        ),
      );
    }
    return _enqueue(
      () => _sendOnce(
        text,
        destNodeId: dest,
        groupId: 0,
        maxBytes: EixamBleProtocol.nearbyTextDirectPayloadMaxBytes,
      ),
    );
  }

  Future<NearbyTextTxResult> sendGroup(String text, {required int groupId}) {
    if (groupId == 0) {
      return Future<NearbyTextTxResult>.value(
        const NearbyTextTxResult(
          packetId: 0,
          status: NearbyTextTxStatus.unknownGroup,
        ),
      );
    }
    return _enqueue(
      () => _sendOnce(
        text,
        destNodeId: EixamBleProtocol.nearbyTextBroadcastDest,
        groupId: groupId,
        maxBytes: EixamBleProtocol.nearbyTextPayloadMaxBytes,
      ),
    );
  }

  Future<NearbyGroupCommandResult> setGroup({
    required int groupId,
    required List<int> psk,
    bool replace = false,
  }) {
    return _enqueue(
      () => _writeGroup(
        action: replace
            ? EixamBleProtocol.nearbyTextGroupSetReplace
            : EixamBleProtocol.nearbyTextGroupSet,
        groupId: groupId,
        psk: psk,
      ),
    );
  }

  Future<NearbyGroupCommandResult> removeGroup(int groupId) {
    return _enqueue(
      () => _writeGroup(action: 0, groupId: groupId, psk: const <int>[]),
    );
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final previous = _inflight;
    final current = () async {
      if (previous != null) {
        await previous;
      }
      return action();
    }();
    _inflight = current.then((_) {}, onError: (Object _) {});
    return current;
  }

  Future<NearbyTextTxResult> _sendOnce(
    String text, {
    required int destNodeId,
    required int groupId,
    required int maxBytes,
  }) async {
    if (_disposed) {
      return const NearbyTextTxResult(
        packetId: 0,
        status: NearbyTextTxStatus.disconnected,
      );
    }
    final utf8Bytes = utf8.encode(text);
    if (utf8Bytes.isEmpty || _whitespaceOnly(utf8Bytes)) {
      return NearbyTextTxResult(packetId: 0, status: NearbyTextTxStatus.empty);
    }
    if (utf8Bytes.length > maxBytes) {
      return NearbyTextTxResult(
        packetId: 0,
        status: NearbyTextTxStatus.tooLong,
      );
    }

    final packetId = _packetIdFactory();
    final completer = Completer<NearbyTextTxStatus>();
    _pending[packetId] = completer;

    try {
      await _writeTxFrames(
        packetId: packetId,
        utf8Bytes: utf8Bytes,
        destNodeId: destNodeId,
        groupId: groupId,
      );
    } on DeviceException {
      // Writer miss is transient while TEL RX still works (CMD bind lag,
      // protection owner claim). One retry, same packet id.
      final drain = txTimeout < const Duration(milliseconds: 400)
          ? txTimeout
          : const Duration(milliseconds: 400);
      await Future<void>.delayed(drain);
      if (_disposed) {
        _pending.remove(packetId);
        return NearbyTextTxResult(
          packetId: packetId,
          status: NearbyTextTxStatus.disconnected,
        );
      }
      try {
        await _writeTxFrames(
          packetId: packetId,
          utf8Bytes: utf8Bytes,
          destNodeId: destNodeId,
          groupId: groupId,
        );
      } catch (_) {
        _pending.remove(packetId);
        return NearbyTextTxResult(
          packetId: packetId,
          status: NearbyTextTxStatus.disconnected,
        );
      }
    } catch (_) {
      _pending.remove(packetId);
      return NearbyTextTxResult(
        packetId: packetId,
        status: NearbyTextTxStatus.disconnected,
      );
    }

    try {
      final status = await completer.future.timeout(txTimeout);
      return NearbyTextTxResult(packetId: packetId, status: status);
    } on TimeoutException {
      _pending.remove(packetId);
      return NearbyTextTxResult(
        packetId: packetId,
        status: NearbyTextTxStatus.timeout,
      );
    }
  }

  Future<void> _writeTxFrames({
    required int packetId,
    required List<int> utf8Bytes,
    required int destNodeId,
    required int groupId,
  }) async {
    final frames = EixamNearbyTextFramer.txFragments(
      packetId: packetId,
      utf8Bytes: utf8Bytes,
      destNodeId: destNodeId,
      groupId: groupId,
    );
    for (final frame in frames) {
      await writeCommand(EixamDeviceCommand.nearbyTextTxFragment(frame));
    }
  }

  Future<NearbyGroupCommandResult> _writeGroup({
    required int action,
    required int groupId,
    required List<int> psk,
  }) async {
    if (_disposed) {
      return const NearbyGroupCommandResult(accepted: false, detail: 0);
    }
    if (groupId == 0) {
      return const NearbyGroupCommandResult(accepted: false, detail: 0);
    }
    if (!_groupEpochValid) {
      if (!_connected) {
        return const NearbyGroupCommandResult(accepted: false, detail: 0);
      }
      final drain = txTimeout < const Duration(milliseconds: 400)
          ? txTimeout
          : const Duration(milliseconds: 400);
      await Future<void>.delayed(drain);
      if (_disposed || !_connected) {
        return const NearbyGroupCommandResult(accepted: false, detail: 0);
      }
      _groupEpochValid = true;
    }
    if ((action == EixamBleProtocol.nearbyTextGroupSet ||
            action == EixamBleProtocol.nearbyTextGroupSetReplace) &&
        _invalidGroupKey(psk)) {
      return const NearbyGroupCommandResult(
        accepted: false,
        detail: NearbyGroupCommandResult.rejectDetailBadKey,
      );
    }
    var retried = false;
    while (true) {
      final ack = Completer<ProvisioningCommandResult>();
      _groupAck = ack;
      try {
        safeSdkDebugPrint(
          'NEARBY_GROUP_WRITE phase=send action=$action retried=$retried '
          'connected=$_connected epoch=$_groupEpochValid',
        );
        final frames = EixamNearbyTextFramer.groupFragments(
          action: action,
          groupId: groupId,
          psk: psk,
        );
        for (final frame in frames) {
          await writeCommand(EixamDeviceCommand.nearbyGroupFragment(frame));
        }
        final result = await ack.future.timeout(txTimeout);
        safeSdkDebugPrint(
          'NEARBY_GROUP_WRITE phase=ack retried=$retried '
          'outcome=${result.outcome.name} detail=${result.detail}',
        );
        return NearbyGroupCommandResult(
          accepted: result.outcome != ProvisioningCommandOutcome.reject,
          detail: result.detail,
        );
      } on TimeoutException {
        _groupEpochValid = false;
        safeSdkDebugPrint(
          'NEARBY_GROUP_WRITE phase=timeout retried=$retried '
          'connected=$_connected',
        );
        if (retried || !_connected) {
          return const NearbyGroupCommandResult(accepted: false, detail: 0);
        }
        retried = true;
        final drain = txTimeout < const Duration(milliseconds: 400)
            ? txTimeout
            : const Duration(milliseconds: 400);
        await Future<void>.delayed(drain);
        if (_disposed || !_connected) {
          return const NearbyGroupCommandResult(accepted: false, detail: 0);
        }
        _groupEpochValid = true;
      } on DeviceException {
        // Writer not ready yet. Do not poison the 0x41 epoch — a retry after
        // the command channel comes up is valid while the tag stays connected.
        safeSdkDebugPrint(
          'NEARBY_GROUP_WRITE phase=writer_miss retried=$retried',
        );
        return const NearbyGroupCommandResult(
          accepted: false,
          detail: NearbyGroupCommandResult.rejectDetailCommandChannel,
        );
      } catch (error) {
        _groupEpochValid = false;
        safeSdkDebugPrint(
          'NEARBY_GROUP_WRITE phase=throw throw_type=${error.runtimeType} '
          'retried=$retried',
        );
        return const NearbyGroupCommandResult(accepted: false, detail: 0);
      } finally {
        if (identical(_groupAck, ack)) {
          _groupAck = null;
        }
      }
    }
  }

  void _onIncoming(BleIncomingEvent event) {
    if (event.type == BleIncomingEventType.provisioningCommandResult) {
      final result = event.provisioningCommandResult;
      if (result != null &&
          result.opcode == EixamBleProtocol.nearbyOwnerNameOpcode) {
        final pending = _ownerAck;
        if (pending != null && !pending.isCompleted) {
          pending.complete(result);
        }
        return;
      }
      if (result != null &&
          result.opcode == EixamBleProtocol.nearbyTextGroupOpcode) {
        if (!_groupEpochValid) {
          return;
        }
        final pending = _groupAck;
        if (pending != null && !pending.isCompleted) {
          pending.complete(result);
        }
      }
      return;
    }
    if (event.type == BleIncomingEventType.nearbyTextTxStatus) {
      final packet = event.nearbyTextTxStatusPacket;
      if (packet == null) {
        return;
      }
      _emitTxStatus(
        NearbyTextTxResult(packetId: packet.packetId, status: packet.status),
      );
      if (packet.status.isDeliveryUpdate) {
        return;
      }
      if (packet.packetId == 0) {
        final pending = Map<int, Completer<NearbyTextTxStatus>>.from(_pending);
        _pending.clear();
        for (final completer in pending.values) {
          if (!completer.isCompleted) {
            completer.complete(packet.status);
          }
        }
        return;
      }
      final pending = _pending.remove(packet.packetId);
      if (pending != null && !pending.isCompleted) {
        pending.complete(packet.status);
      }
      return;
    }
    if (event.type == BleIncomingEventType.nearbyOwnerName) {
      final packet = event.nearbyOwnerNamePacket;
      if (packet == null || _namesController.isClosed) {
        return;
      }
      _namesController.add(
        NearbyNodeName(
          nodeId: packet.nodeId,
          name: packet.name,
          receivedAt: event.receivedAt,
        ),
      );
      return;
    }
    if (event.type != BleIncomingEventType.nearbyTextRx) {
      return;
    }
    final packet = event.nearbyTextPacket;
    if (packet == null || _incomingController.isClosed) {
      return;
    }
    _emitIncoming(
      NearbyIncomingText(
        fromNodeId: packet.fromNodeId,
        destNodeId: packet.destNodeId,
        packetId: packet.packetId,
        groupId: packet.groupId,
        pkiEncrypted: packet.pkiEncrypted,
        text: packet.text,
        receivedAt: event.receivedAt,
      ),
    );
  }

  void _emitIncoming(NearbyIncomingText text) {
    if (_incomingController.isClosed) {
      return;
    }
    if (_incomingController.hasListener) {
      _incomingController.add(text);
      return;
    }
    _bufferedIncoming.add(text);
    if (_bufferedIncoming.length > 64) {
      _bufferedIncoming.removeAt(0);
    }
  }

  void _flushBufferedIncoming() {
    if (_incomingController.isClosed || _bufferedIncoming.isEmpty) {
      return;
    }
    final pending = List<NearbyIncomingText>.from(_bufferedIncoming);
    _bufferedIncoming.clear();
    for (final text in pending) {
      _incomingController.add(text);
    }
  }

  void _emitTxStatus(NearbyTextTxResult status) {
    if (_txStatusController.isClosed) {
      return;
    }
    if (_txStatusController.hasListener) {
      _txStatusController.add(status);
      return;
    }
    _bufferedTxStatus.add(status);
    if (_bufferedTxStatus.length > 32) {
      _bufferedTxStatus.removeAt(0);
    }
  }

  void _flushBufferedTxStatus() {
    if (_txStatusController.isClosed || _bufferedTxStatus.isEmpty) {
      return;
    }
    final pending = List<NearbyTextTxResult>.from(_bufferedTxStatus);
    _bufferedTxStatus.clear();
    for (final status in pending) {
      _txStatusController.add(status);
    }
  }

  void _failPendingTx(NearbyTextTxStatus status) {
    final pending = Map<int, Completer<NearbyTextTxStatus>>.from(_pending);
    _pending.clear();
    for (final completer in pending.values) {
      if (!completer.isCompleted) {
        completer.complete(status);
      }
    }
  }

  void _failGroupAck() {
    final groupAck = _groupAck;
    if (groupAck != null && !groupAck.isCompleted) {
      groupAck.complete(
        const ProvisioningCommandResult(
          opcode: EixamBleProtocol.nearbyTextGroupOpcode,
          outcome: ProvisioningCommandOutcome.reject,
          detail: 0,
        ),
      );
    }
    _groupAck = null;
  }

  void _failOwnerAck() {
    final ownerAck = _ownerAck;
    if (ownerAck != null && !ownerAck.isCompleted) {
      ownerAck.complete(
        const ProvisioningCommandResult(
          opcode: EixamBleProtocol.nearbyOwnerNameOpcode,
          outcome: ProvisioningCommandOutcome.reject,
          detail: 0,
        ),
      );
    }
    _ownerAck = null;
  }

  Future<void> _writeOwnerName(String name) async {
    final utf8Bytes = utf8.encode(name);
    if (utf8Bytes.isEmpty) {
      return;
    }
    final ack = Completer<ProvisioningCommandResult>();
    _ownerAck = ack;
    try {
      final frames = EixamNearbyTextFramer.ownerNameFragments(utf8Bytes);
      for (final frame in frames) {
        await writeCommand(EixamDeviceCommand.nearbyOwnerNameFragment(frame));
      }
    } on DeviceException {
      if (identical(_ownerAck, ack)) {
        _ownerAck = null;
      }
      return;
    } catch (_) {
      if (identical(_ownerAck, ack)) {
        _ownerAck = null;
      }
      return;
    }
    unawaited(() async {
      try {
        await ack.future.timeout(txTimeout);
      } on TimeoutException {
        // Old firmware ignores 0x42. Names still fall back to EIXAM_<nodeId>.
      } catch (_) {
        // Same: never fail the BLE session for a display-name push.
      } finally {
        if (identical(_ownerAck, ack)) {
          _ownerAck = null;
        }
      }
    }());
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _incomingSub?.cancel();
    _incomingSub = null;
    _failPendingTx(NearbyTextTxStatus.disconnected);
    final groupAck = _groupAck;
    if (groupAck != null && !groupAck.isCompleted) {
      groupAck.completeError(StateError('nearby disposed'));
    }
    _groupAck = null;
    _failOwnerAck();
    _bufferedIncoming.clear();
    _bufferedTxStatus.clear();
    await _incomingController.close();
    await _namesController.close();
    await _txStatusController.close();
  }

  static bool _whitespaceOnly(List<int> bytes) {
    for (final byte in bytes) {
      if (byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x20) {
        return false;
      }
    }
    return true;
  }

  static bool _invalidGroupKey(List<int> keyBytes) {
    if (keyBytes.length != 32) {
      return true;
    }
    for (final byte in keyBytes) {
      if (byte != 0) {
        return false;
      }
    }
    return true;
  }

  static String _clipOwnerName(String name) {
    var clipped = name;
    while (utf8.encode(clipped).length >
            EixamBleProtocol.nearbyOwnerNameMaxBytes &&
        clipped.isNotEmpty) {
      clipped = clipped.substring(0, clipped.length - 1);
    }
    return clipped.trim();
  }

  static int _nextPacketId() {
    final random = Random();
    var id = 0;
    while (id == 0) {
      id = (random.nextInt(1 << 30) << 2) ^ random.nextInt(1 << 30);
      id &= 0xFFFFFFFF;
    }
    return id;
  }
}
