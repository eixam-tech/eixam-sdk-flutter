import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/repositories/telemetry_repository.dart';
import '../device/ble_incoming_event.dart';
import '../device/eixam_backlog_sync_frame.dart';
import '../device/eixam_ble_command.dart';

class BacklogSyncController {
  BacklogSyncController({
    required Stream<BleIncomingEvent> bleIncomingEvents,
    required this.telemetryRepository,
    required Future<void> Function(EixamDeviceCommand command) commandSender,
    required Future<String?> Function() backendHardwareIdResolver,
    Duration sessionTimeout = const Duration(seconds: 30),
  })  : _commandSender = commandSender,
        _backendHardwareIdResolver = backendHardwareIdResolver,
        _sessionTimeout = sessionTimeout {
    _bleSub = bleIncomingEvents.listen(
      handleBleIncomingEvent,
      onError: (Object error) {
        _emitState(
          _state.copyWith(
            phase: BacklogSyncPhase.failed,
            lastError: 'Backlog sync BLE stream failed: $error',
            lastUpdatedAt: DateTime.now(),
          ),
        );
      },
    );
  }

  final TelemetryRepository telemetryRepository;
  final Future<void> Function(EixamDeviceCommand command) _commandSender;
  final Future<String?> Function() _backendHardwareIdResolver;
  final Duration _sessionTimeout;
  final StreamController<BacklogSyncState> _controller =
      StreamController<BacklogSyncState>.broadcast();

  StreamSubscription<BleIncomingEvent>? _bleSub;
  Future<void> _serial = Future<void>.value();
  Timer? _timeoutTimer;
  BacklogSyncState _state = const BacklogSyncState.idle();
  _BacklogSyncRequest? _request;

  BacklogSyncState get currentState => _state;

  Stream<BacklogSyncState> watchState() => _controller.stream;

  Future<BacklogSyncState> start({
    DateTime? since,
    int maxEvents = 100,
  }) async {
    if (maxEvents <= 0 || maxEvents > 0xFFFF) {
      throw ArgumentError.value(
        maxEvents,
        'maxEvents',
        'Backlog sync maxEvents must be between 1 and 65535.',
      );
    }
    if (_state.isActive) {
      await cancel(reason: _BacklogSyncAbortReason.restarted);
    }

    final request = _BacklogSyncRequest(
      since: since?.toUtc(),
      maxEvents: maxEvents,
    );
    _request = request;
    _emitState(
      BacklogSyncState(
        phase: BacklogSyncPhase.starting,
        confirmedEvents: 0,
        nextOffset: 0,
        lastUpdatedAt: DateTime.now(),
      ),
    );
    await _sendStart(request);
    return _state;
  }

  Future<void> cancel({
    int reason = _BacklogSyncAbortReason.cancelled,
  }) async {
    _timeoutTimer?.cancel();
    final sessionId = _state.sessionId;
    _request = null;
    if (sessionId != null) {
      try {
        await _commandSender(
          EixamDeviceCommand.backlogSyncAbort(
            sessionId: sessionId,
            reason: reason,
          ),
        );
      } catch (_) {}
    }
    _emitState(
      _state.copyWith(
        phase: BacklogSyncPhase.cancelled,
        lastUpdatedAt: DateTime.now(),
      ),
    );
  }

  void handleBleIncomingEvent(BleIncomingEvent event) {
    final frame = event.backlogSyncFrame;
    if (frame == null) {
      return;
    }
    _serial =
        _serial.then((_) => _handleFrame(frame)).catchError((Object error) {
      _timeoutTimer?.cancel();
      _request = null;
      _emitState(
        _state.copyWith(
          phase: BacklogSyncPhase.failed,
          lastError: 'Backlog sync failed: $error',
          lastUpdatedAt: DateTime.now(),
        ),
      );
    });
  }

  Future<void> onDeviceStatusChanged({
    required DeviceStatus? previous,
    required DeviceStatus current,
  }) async {
    if (!_state.isActive) {
      return;
    }
    if (current.connected) {
      _restartTimeout();
    } else {
      _timeoutTimer?.cancel();
    }
    if ((previous?.connected ?? false) || !current.connected) {
      return;
    }
    final request = _request;
    if (request == null) {
      return;
    }
    _emitState(
      _state.copyWith(
        phase: BacklogSyncPhase.starting,
        sessionId: null,
        lastUpdatedAt: DateTime.now(),
      ),
    );
    await _sendStart(request);
  }

  Future<void> dispose() async {
    _timeoutTimer?.cancel();
    await _bleSub?.cancel();
    await _controller.close();
  }

  Future<void> _handleFrame(EixamBacklogSyncFrame frame) async {
    if (!_state.isActive &&
        frame.messageType != EixamBacklogSyncMessageType.error) {
      return;
    }
    _restartTimeout();
    switch (frame.messageType) {
      case EixamBacklogSyncMessageType.meta:
        final meta = frame as EixamBacklogSyncMetaFrame;
        _emitState(
          _state.copyWith(
            phase: BacklogSyncPhase.syncing,
            sessionId: meta.sessionId,
            totalEvents: meta.totalEvents,
            nextOffset: meta.startOffset,
            confirmedEvents: 0,
            lastError: null,
            lastUpdatedAt: DateTime.now(),
          ),
        );
        return;
      case EixamBacklogSyncMessageType.chunk:
        final chunk = frame as EixamBacklogSyncChunkFrame;
        if (!_matchesActiveSession(chunk.sessionId)) {
          return;
        }
        final backendHardwareId = await _backendHardwareIdResolver();
        final payloads = chunk.records
            .map(
              (record) => SdkTelemetryPayload(
                timestamp: DateTime.fromMillisecondsSinceEpoch(
                  record.timeUnix * 1000,
                  isUtc: true,
                ),
                latitude: record.telPacket.position.latitude,
                longitude: record.telPacket.position.longitude,
                altitude: record.telPacket.position.altitudeMeters.toDouble(),
                nodeId: record.telPacket.nodeId,
                deviceId: record.telPacket.nodeId.toString(),
                hardwareId: backendHardwareId,
                eventId:
                    '${record.telPacket.nodeId}:${record.timeUnix}:${record.telPacket.packetId}',
              ),
            )
            .toList(growable: false);
        await telemetryRepository.publishTelemetryBatch(payloads);
        final nextOffset = chunk.chunkOffset + chunk.records.length;
        await _commandSender(
          EixamDeviceCommand.backlogSyncAck(
            sessionId: chunk.sessionId,
            nextOffset: nextOffset,
          ),
        );
        _emitState(
          _state.copyWith(
            phase: BacklogSyncPhase.syncing,
            confirmedEvents: _state.confirmedEvents + chunk.records.length,
            nextOffset: nextOffset,
            lastUpdatedAt: DateTime.now(),
          ),
        );
        return;
      case EixamBacklogSyncMessageType.end:
        final end = frame as EixamBacklogSyncEndFrame;
        if (!_matchesActiveSession(end.sessionId)) {
          return;
        }
        _timeoutTimer?.cancel();
        _request = null;
        _emitState(
          _state.copyWith(
            phase: end.status == 0
                ? BacklogSyncPhase.completed
                : BacklogSyncPhase.failed,
            confirmedEvents: _state.confirmedEvents > end.sentEvents
                ? _state.confirmedEvents
                : end.sentEvents,
            nextOffset: end.lastOffset,
            lastError: end.status == 0
                ? null
                : 'Device ended backlog sync with status=${end.status}',
            lastUpdatedAt: DateTime.now(),
          ),
        );
        return;
      case EixamBacklogSyncMessageType.error:
        final error = frame as EixamBacklogSyncErrorFrame;
        if (_state.sessionId != null &&
            !_matchesActiveSession(error.sessionId)) {
          return;
        }
        _timeoutTimer?.cancel();
        _request = null;
        _emitState(
          _state.copyWith(
            phase: BacklogSyncPhase.failed,
            sessionId: error.sessionId,
            lastError:
                'Device backlog sync error code=${error.code} detail=${error.detail}',
            lastUpdatedAt: DateTime.now(),
          ),
        );
        return;
    }
  }

  bool _matchesActiveSession(int sessionId) {
    final currentSessionId = _state.sessionId;
    return currentSessionId == null || currentSessionId == sessionId;
  }

  Future<void> _sendStart(_BacklogSyncRequest request) async {
    _restartTimeout();
    await _commandSender(
      EixamDeviceCommand.backlogSyncStart(
        sinceUnix: request.sinceUnix,
        maxEvents: request.maxEvents,
      ),
    );
  }

  void _restartTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_sessionTimeout, () {
      unawaited(_handleTimeout());
    });
  }

  Future<void> _handleTimeout() async {
    if (!_state.isActive) {
      return;
    }
    final sessionId = _state.sessionId;
    if (sessionId != null) {
      try {
        await _commandSender(
          EixamDeviceCommand.backlogSyncAbort(
            sessionId: sessionId,
            reason: _BacklogSyncAbortReason.timeout,
          ),
        );
      } catch (_) {}
    }
    _request = null;
    _emitState(
      _state.copyWith(
        phase: BacklogSyncPhase.failed,
        lastError: 'Backlog sync timed out after ${_sessionTimeout.inSeconds}s',
        lastUpdatedAt: DateTime.now(),
      ),
    );
  }

  void _emitState(BacklogSyncState nextState) {
    _state = nextState;
    if (!_controller.isClosed) {
      _controller.add(nextState);
    }
  }
}

class _BacklogSyncRequest {
  const _BacklogSyncRequest({
    required this.since,
    required this.maxEvents,
  });

  final DateTime? since;
  final int maxEvents;

  int get sinceUnix =>
      since == null ? 0 : since!.millisecondsSinceEpoch ~/ 1000;
}

abstract final class _BacklogSyncAbortReason {
  static const int cancelled = 0x01;
  static const int timeout = 0x02;
  static const int restarted = 0x03;
}
