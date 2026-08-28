import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_debug_registry.dart';
import '../device/ble_incoming_event.dart';
import '../device/eixam_ble_command.dart';
import '../device/eixam_position_backlog_packet.dart';
import 'device_position_batch_normalizer.dart';

class DevicePositionBacklogCoordinator {
  DevicePositionBacklogCoordinator({
    required this.writeCommand,
    required this.normalizer,
    required this.emitBatch,
    this.abortTimeout = const Duration(milliseconds: 250),
  });

  final Future<void> Function(EixamDeviceCommand command) writeCommand;
  final DevicePositionBatchNormalizer normalizer;
  final void Function(EixamDevicePositionBatch batch) emitBatch;
  final Duration abortTimeout;

  _BacklogSession? _active;

  bool get isActive => _active != null;

  Future<DevicePositionBacklogSyncResult> sync({
    required DateTime since,
    required DateTime? until,
    required Duration timeout,
  }) async {
    if (_active != null) {
      throw const DeviceException(
        'E_DEVICE_BACKLOG_SYNC_IN_PROGRESS',
        'E_DEVICE_BACKLOG_SYNC_IN_PROGRESS',
      );
    }
    if (timeout <= Duration.zero ||
        (until != null && until.toUtc().isBefore(since.toUtc()))) {
      throw ArgumentError('Invalid position backlog sync window or timeout.');
    }
    final sinceUnix = since.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (sinceUnix <= 0 || sinceUnix > 0xFFFFFFFF) {
      throw ArgumentError.value(since, 'since', 'Must fit firmware UTC u32.');
    }

    final session = _BacklogSession(
      since: since.toUtc(),
      until: until?.toUtc(),
      deadline: DateTime.now().toUtc().add(timeout),
    );
    _active = session;
    session.timer = Timer(timeout, () => _timeoutNow(session));
    final untilUtc = until?.toUtc();
    final untilUnix = untilUtc == null
        ? 'none'
        : '${untilUtc.millisecondsSinceEpoch ~/ 1000}';
    BleDebugRegistry.instance.recordEvent(
      'POSITION_BACKLOG request sinceUnix=$sinceUnix '
      'untilUnix=$untilUnix',
    );
    unawaited(_start(session, sinceUnix));
    return session.completer.future;
  }

  Future<void> _start(_BacklogSession session, int sinceUnix) async {
    try {
      await _writeWithinDeadline(
        session,
        EixamDeviceCommand.positionBacklogStart(sinceUnix: sinceUnix),
      );
    } on TimeoutException {
      _timeoutNow(session);
    } catch (error, stackTrace) {
      BleDebugRegistry.instance.recordEvent(
        'POSITION_BACKLOG failed reason=request_write',
      );
      _completeError(session, error, stackTrace);
    }
  }

  Future<void> handleEvent(BleIncomingEvent event) async {
    if (event.type != BleIncomingEventType.telPositionBacklog) return;
    final session = _active;
    if (session == null) return;
    final packet = event.positionBacklogPacket;
    if (packet == null) {
      _fail(session, 'malformed', abortReason: 1);
      return;
    }

    if (packet is EixamPositionBacklogMeta) {
      if (session.sessionId != null) {
        _fail(session, 'unexpected_meta', abortReason: 2);
        return;
      }
      session
        ..sessionId = packet.sessionId
        ..totalEvents = packet.totalEvents
        ..expectedIndex = packet.startIndex
        ..endIndex = packet.endIndex;
      BleDebugRegistry.instance.recordEvent(
        'POSITION_BACKLOG meta totalEvents=${packet.totalEvents}',
      );
      return;
    }

    if (session.sessionId == null || packet.sessionId != session.sessionId) {
      _fail(session, 'session_mismatch', abortReason: 3);
      return;
    }

    if (packet is EixamPositionBacklogChunk) {
      if (session.totalEvents == 0 ||
          packet.logicalIndex != session.expectedIndex ||
          packet.logicalIndex > session.endIndex!) {
        _fail(session, 'logical_index_mismatch', abortReason: 4);
        return;
      }
      session.receivedEvents++;
      final sampledAt = packet.batch.samples.single.sampledAt!;
      final rejectedUntil =
          session.until != null && sampledAt.isAfter(session.until!);
      final inWindow = !sampledAt.isBefore(session.since) && !rejectedUntil;
      if (!inWindow) {
        if (rejectedUntil) session.rejectedUntilCount++;
      } else {
        final normalized = normalizer.normalizeBacklog(event, packet);
        session.duplicateCount += normalized.duplicateCount;
        final batch = normalized.batch;
        if (batch != null) {
          session.recoveredCount += batch.samples.length;
          emitBatch(batch);
          BleDebugRegistry.instance.recordEvent(
            'POSITION_BACKLOG sample_emitted novelCount=${batch.samples.length}',
          );
        } else {
          BleDebugRegistry.instance.recordEvent(
            'POSITION_BACKLOG sample_deduplicated duplicateCount=${normalized.duplicateCount}',
          );
        }
        if (session.lastProcessedSampleAt == null ||
            sampledAt.isAfter(session.lastProcessedSampleAt!)) {
          session.lastProcessedSampleAt = sampledAt.toUtc();
        }
      }
      session.expectedIndex = packet.logicalIndex + 1;
      BleDebugRegistry.instance.recordEvent(
        'POSITION_BACKLOG chunks received=${session.receivedEvents}',
      );
      try {
        await _writeWithinDeadline(
          session,
          EixamDeviceCommand.positionBacklogAck(
            sessionId: session.sessionId!,
            nextLogicalIndex: session.expectedIndex!,
          ),
        );
      } on TimeoutException {
        _timeoutNow(session);
      } catch (_) {
        _fail(session, 'ack_failed', abortReason: 5);
      }
      return;
    }

    if (packet is EixamPositionBacklogError) {
      BleDebugRegistry.instance.recordEvent(
        'POSITION_BACKLOG failed reason=device_error',
      );
      _complete(session, completed: false);
      return;
    }

    if (packet is EixamPositionBacklogEnd) {
      session.endSentEvents = packet.sentEvents;
      final valid = packet.status == 0 &&
          packet.sentEvents == session.receivedEvents &&
          packet.sentEvents == session.totalEvents &&
          (packet.sentEvents == 0
              ? packet.lastIndex == 0
              : packet.lastIndex == session.expectedIndex! - 1);
      if (!valid) {
        _fail(session, 'malformed_end', abortReason: 6);
        return;
      }
      _complete(session, completed: true);
    }
  }

  Future<void> disconnected() async {
    final session = _active;
    if (session != null) {
      BleDebugRegistry.instance.recordEvent(
        'POSITION_BACKLOG failed reason=disconnected',
      );
      _complete(session, completed: false);
    }
  }

  Future<void> cancel() async {
    final session = _active;
    if (session != null) _fail(session, 'cancelled', abortReason: 7);
  }

  void _timeoutNow(_BacklogSession session) {
    if (!identical(_active, session)) return;
    BleDebugRegistry.instance.recordEvent(
      'POSITION_BACKLOG failed reason=timeout',
    );
    final sessionId = session.sessionId;
    _complete(session, completed: false, timedOut: true);
    if (sessionId != null) _abortBestEffort(sessionId, 8);
  }

  void _fail(
    _BacklogSession session,
    String reason, {
    required int abortReason,
  }) {
    BleDebugRegistry.instance.recordEvent(
      'POSITION_BACKLOG failed reason=$reason',
    );
    final sessionId = session.sessionId;
    _complete(session, completed: false);
    if (sessionId != null) _abortBestEffort(sessionId, abortReason);
  }

  void _abortBestEffort(int sessionId, int reason) {
    unawaited(
      writeCommand(
        EixamDeviceCommand.positionBacklogAbort(
          sessionId: sessionId,
          reason: reason,
        ),
      ).timeout(abortTimeout).catchError((_) {}),
    );
  }

  Future<void> _writeWithinDeadline(
    _BacklogSession session,
    EixamDeviceCommand command,
  ) async {
    if (!identical(_active, session)) return;
    final remaining = session.deadline.difference(DateTime.now().toUtc());
    if (remaining <= Duration.zero) throw TimeoutException('deadline');
    await writeCommand(command).timeout(remaining);
    if (!identical(_active, session)) return;
  }

  void _completeError(
    _BacklogSession session,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!identical(_active, session)) return;
    session.timer?.cancel();
    _active = null;
    if (!session.completer.isCompleted) {
      session.completer.completeError(error, stackTrace);
    }
  }

  void _complete(
    _BacklogSession session, {
    required bool completed,
    bool timedOut = false,
  }) {
    if (!identical(_active, session)) return;
    session.timer?.cancel();
    _active = null;
    final result = DevicePositionBacklogSyncResult(
      completed: completed,
      timedOut: timedOut,
      partial: !completed &&
          (session.recoveredCount > 0 || session.duplicateCount > 0),
      metaTotalEvents: session.totalEvents,
      receivedCount: session.receivedEvents,
      recoveredCount: session.recoveredCount,
      duplicateCount: session.duplicateCount,
      rejectedUntilCount: session.rejectedUntilCount,
      endSentEvents: session.endSentEvents,
      lastProcessedSampleAt: session.lastProcessedSampleAt,
      retentionGapDetected: session.retentionGapDetected,
    );
    if (completed) {
      BleDebugRegistry.instance.recordEvent(
        'POSITION_BACKLOG completed '
        'metaTotalEvents=${result.metaTotalEvents ?? 0} '
        'receivedCount=${result.receivedCount} '
        'recoveredCount=${result.recoveredCount} '
        'duplicateCount=${result.duplicateCount} '
        'rejectedUntilCount=${result.rejectedUntilCount} '
        'endSentEvents=${result.endSentEvents ?? 0} '
        'backlogEmpty=${result.backlogEmpty}',
      );
    }
    if (!session.completer.isCompleted) session.completer.complete(result);
  }
}

class _BacklogSession {
  _BacklogSession({
    required this.since,
    required this.until,
    required this.deadline,
  });

  final DateTime since;
  final DateTime? until;
  final DateTime deadline;
  final Completer<DevicePositionBacklogSyncResult> completer =
      Completer<DevicePositionBacklogSyncResult>();
  Timer? timer;
  int? sessionId;
  int? totalEvents;
  int? expectedIndex;
  int? endIndex;
  int receivedEvents = 0;
  int recoveredCount = 0;
  int duplicateCount = 0;
  int rejectedUntilCount = 0;
  int? endSentEvents;
  DateTime? lastProcessedSampleAt;
  bool retentionGapDetected = false;
}
