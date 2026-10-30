part of 'activity_recording_controller.dart';

/// An episode owns only its own coordinator lease. It never occupies the
/// recorder actor while waiting for BLE, a retry timer or a command deadline.
final class _RecordingRecoveryEpisode {
  _RecordingRecoveryEpisode(
    this.record,
    this.identityGeneration,
    this.generation,
    this.since,
    this.until,
  );
  final ActivityRecordingRecord record;
  final int identityGeneration;
  final int generation;
  final DateTime since;
  DateTime until;
  bool finalizing = false;
  Duration budget = const Duration(seconds: 60);
  DateTime? deadlineAt;
  final Completer<SdkActivityRecording> result = Completer();
  final Completer<void> stopped = Completer();
  bool cancelled = false;
  bool returnDeferred = false;
  bool expired = false;
  bool accepting = true;
  DateTime? first;
  DateTime? last;
  bool rejected = false;
  Timer? deadline;
  Timer? retry;

  void stop() {
    if (!stopped.isCompleted) stopped.complete();
  }
}

// Wrapping the future lets the actor return immediately instead of flattening
// it and deadlocking the D1 commits queued behind that same actor turn.
final class _RecordingRecoveryRequest {
  const _RecordingRecoveryRequest(this.result);
  final Future<SdkActivityRecording> result;
}

extension _ActivityRecordingRecovery on ActivityRecordingController {
  void _fenceRecovery({bool defer = false}) {
    _recoveryGeneration++;
    final episode = _recoveryEpisode;
    _recoveryEpisode = null;
    if (episode == null) return;
    episode.cancelled = true;
    episode.returnDeferred = defer;
    episode.accepting = false;
    episode.deadline?.cancel();
    episode.retry?.cancel();
    episode.stop();
    unawaited(_backlog?.cancelRecording(episode));
    if (defer) {
      unawaited(
        _command((generation) async {
          final record = await _required(
            episode.record.value.recordingId,
            generation,
          );
          if (record.value.phase == ActivityRecordingPhase.finished) {
            throw _unavailable;
          }
          if (_recoveryEpisode != null) return record.value;
          final updated = record.transition(
            recoveryState: ActivityRecordingRecoveryState.deferred,
          );
          await _transaction(generation, (tx) => tx.update(updated));
          _publish(updated, generation);
          return updated.value;
        }).then(
          (value) {
            if (!episode.result.isCompleted) episode.result.complete(value);
          },
          onError: (Object error, StackTrace stack) {
            if (!episode.result.isCompleted) {
              episode.result.completeError(error, stack);
            }
          },
        ),
      );
    }
  }

  bool _currentEpisode(_RecordingRecoveryEpisode e) =>
      !_disposed &&
      !e.cancelled &&
      e.identityGeneration == _generation &&
      e.generation == _recoveryGeneration &&
      identical(e, _recoveryEpisode);

  void _triggerHistory() {
    if (!_used || _identity == null || _disposed || _backlog == null) return;
    final generation = _generation;
    unawaited(
      _command((g) async {
            final record = await _activeForObservation(g);
            if (record == null ||
                record.value.phase != ActivityRecordingPhase.active) {
              return null;
            }
            final window = await _transaction(
              g,
              (tx) => tx.recoveryWindow(record),
            );
            return window.needed ? record.value.recordingId : null;
          })
          .then((id) async {
            if (id != null && generation == _generation) await _recover(id);
          })
          .catchError((Object error, StackTrace stack) {
            if (error is ActivityRecordingException &&
                error.code != 'E_RECORDING_UNAVAILABLE') {
              _publishError(error, stack, generation);
            }
          }),
    );
  }

  void _reconcileHistoryReadiness() {
    if (!_used || _disposed || _identity == null) return;
    final device = _lastPathDevice;
    final node = ActivityRecordingSourceIdentity.forNode(
      _lastPathNodeId,
    )?.value;
    final eligible =
        _lastPathConnected == true &&
        ((device != null && _historyEligible(device)) ||
            (node != null && _historyEligible(node)));
    final becameReady = eligible && !_lastHistoryEligible;
    _lastHistoryEligible = eligible;
    if (becameReady) _triggerHistory();
    if (!eligible && _recoveryEpisode != null) {
      _fenceRecovery(defer: true);
    }
  }

  Future<SdkActivityRecording> _recover(String id) async {
    final request = await _command((generation) async {
      final record = await _required(id, generation);
      final r = record.value;
      if (r.phase != ActivityRecordingPhase.active) throw _conflict;
      await _withSession(
        (session) async =>
            _matchSession(session, ActivityRecordingController._sessionOf(r)),
      );
      final running = _recoveryEpisode;
      if (running != null &&
          _currentEpisode(running) &&
          running.record.value.recordingId == id) {
        return _RecordingRecoveryRequest(running.result.future);
      }
      final window = await _transaction(generation, (tx) async {
        await tx.needRecovery(record);
        return tx.recoveryWindow(record);
      });
      final until = _clock().toUtc();
      if (r.deviceIdentity == null ||
          _backlog == null ||
          _backlog.isActive ||
          !_historyEligible(r.deviceIdentity!) ||
          until.isBefore(window.since)) {
        final deferred = record.transition(
          recoveryState: ActivityRecordingRecoveryState.deferred,
          issues: {
            ...r.issues,
            if (r.deviceIdentity == null)
              ActivityRecordingIssue.deviceIdentityUnavailable
            else
              ActivityRecordingIssue.commandOwnerUnavailable,
          },
        );
        await _transaction(generation, (tx) => tx.update(deferred));
        _publish(deferred, generation);
        return _RecordingRecoveryRequest(Future.value(deferred.value));
      }
      final episode = _RecordingRecoveryEpisode(
        record,
        generation,
        ++_recoveryGeneration,
        window.since,
        until,
      );
      // Attach an error handler before scheduling: automatic and manual callers
      // can be fenced by an identity transition before receiving their future.
      episode.result.future.ignore();
      final recovering = record.transition(
        recoveryState: ActivityRecordingRecoveryState.recovering,
        issues: {...r.issues}
          ..remove(ActivityRecordingIssue.commandOwnerUnavailable)
          ..remove(ActivityRecordingIssue.recoveryFailed)
          ..remove(ActivityRecordingIssue.recoveryTimedOut),
      );
      await _transaction(generation, (tx) => tx.update(recovering));
      _recoveryEpisode = episode;
      _publish(recovering, generation);
      scheduleMicrotask(() => unawaited(_runHistoryEpisode(episode)));
      return _RecordingRecoveryRequest(episode.result.future);
    });
    return request.result;
  }

  void _expireHistory(_RecordingRecoveryEpisode e) {
    e.expired = true;
    e.accepting = false;
    e.stop();
    unawaited(_backlog?.cancelRecording(e));
  }

  Future<void> _runHistoryEpisode(_RecordingRecoveryEpisode e) async {
    final source = ActivityRecordingSourceIdentity.parse(
      e.record.value.deviceIdentity,
    )!;
    var completed = false;
    var timedOut = false;
    e.deadlineAt ??= _clock().toUtc().add(e.budget);
    e.deadline ??= _recoveryTimer(e.budget, () => _expireHistory(e));
    try {
      for (
        var attempt = 0;
        attempt < (e.finalizing ? 1 : 3) && _currentEpisode(e) && !e.expired;
        attempt++
      ) {
        if (!_historyEligible(e.record.value.deviceIdentity!)) break;
        if (attempt > 0) {
          final ready = Completer<void>();
          e.retry = _recoveryTimer(
            Duration(seconds: attempt == 1 ? 1 : 5),
            ready.complete,
          );
          await Future.any<void>([ready.future, e.stopped.future]);
          e.retry?.cancel();
        }
        if (!_currentEpisode(e) ||
            e.expired ||
            !_historyEligible(e.record.value.deviceIdentity!)) {
          break;
        }
        final remaining = e.deadlineAt!.difference(_clock().toUtc());
        if (remaining <= Duration.zero) {
          e.expired = true;
          break;
        }
        e.first = null;
        e.last = null;
        e.rejected = false;
        try {
          final result = await Future.any<DevicePositionBacklogSyncResult?>([
            _backlog!.syncRecording(
              owner: e,
              since: e.since,
              until: e.until,
              budget: remaining,
              timer: _recoveryTimer,
              acceptsEvent: (event) =>
                  _currentEpisode(e) &&
                  e.accepting &&
                  !e.expired &&
                  _historyEligible(e.record.value.deviceIdentity!) &&
                  _historyEventEligible(
                    event,
                    e.record.value.deviceIdentity!,
                  ) &&
                  _historySourceMatches(source, event),
              commit: (batch) => _commitHistory(
                e,
                source.nodeId != null ? source.stamp(batch) : batch,
              ),
            ),
            e.stopped.future.then((_) => null),
          ]);
          timedOut |= result?.timedOut ?? false;
          if (result?.completed == true) {
            completed = !e.rejected;
            break;
          }
        } on DeviceException catch (error) {
          if (error.code == 'E_DEVICE_BACKLOG_SYNC_OWNER_UNAVAILABLE' ||
              error.code == 'E_DEVICE_BACKLOG_SYNC_IN_PROGRESS') {
            break;
          }
        } catch (_) {
          // A transport failure consumes this attempt; committed chunks survive.
        }
      }
      e.accepting = false;
      if (!_currentEpisode(e)) throw _unavailable;
      final settled = await _command((generation) async {
        if (!_currentEpisode(e)) throw _unavailable;
        final result = await _transaction(generation, (tx) async {
          var record = await tx.byId(_owner!.scope, e.record.value.recordingId);
          if (record == null ||
              record.value.phase == ActivityRecordingPhase.finished) {
            throw _unavailable;
          }
          record = record.transition(
            issues: {
              ...record.value.issues,
              if (e.expired || timedOut)
                ActivityRecordingIssue.recoveryTimedOut,
              if (!completed) ActivityRecordingIssue.recoveryFailed,
            },
          );
          final updated = await tx.settleRecovery(
            record,
            completed: completed,
            first: e.first,
            last: e.last,
          );
          if (!_currentEpisode(e)) throw _unavailable;
          return updated;
        });
        if (!_currentEpisode(e)) throw _unavailable;
        _publish(result, generation);
        return result.value;
      });
      e.result.complete(settled);
    } catch (error, stack) {
      if (!e.result.isCompleted && !(e.cancelled && e.returnDeferred)) {
        e.result.completeError(error, stack);
      }
    } finally {
      e.deadline?.cancel();
      e.retry?.cancel();
      e.accepting = false;
      if (identical(_recoveryEpisode, e)) _recoveryEpisode = null;
    }
  }

  Future<void> _commitHistory(
    _RecordingRecoveryEpisode e,
    EixamDevicePositionBatch batch,
  ) async {
    if (!_currentEpisode(e) || !e.accepting || e.expired) throw _unavailable;
    await _command((generation) async {
      if (!_currentEpisode(e)) throw _unavailable;
      final record = await _transaction(generation, (tx) async {
        final record = await tx.byId(_owner!.scope, e.record.value.recordingId);
        if (record == null ||
            record.value.phase == ActivityRecordingPhase.finished ||
            record.value.deviceIdentity != batch.deviceIdentity ||
            batch.delivery != EixamDevicePositionDelivery.recovered ||
            batch.source != SdkLocationSource.connectedDevice) {
          throw _unavailable;
        }
        if (record.value.phase == ActivityRecordingPhase.active) {
          await _withSession(
            (session) async => _matchSession(
              session,
              ActivityRecordingController._sessionOf(record.value),
            ),
          );
        }
        for (final s in batch.samples) {
          final at = s.sampledAt?.toUtc();
          if (at == null ||
              at.isBefore(e.since) ||
              at.isAfter(e.until) ||
              (record.value.endedAt != null &&
                  at.isAfter(record.value.endedAt!)) ||
              s.stableSampleKey.isEmpty ||
              s.source != SdkLocationSource.connectedDevice ||
              !EixamGeoCoordinates.isValidFix(s.latitude, s.longitude) ||
              (s.altitudeMeters != null && !s.altitudeMeters!.isFinite)) {
            e.rejected = true;
          }
        }
        final updated = await const ActivityRecordingIngestor().ingest(
          tx,
          record,
          batch,
          e.until,
          recovered: true,
        );
        if (updated.value.unresolvedGapCount >
            record.value.unresolvedGapCount) {
          e.rejected = true;
        }
        if (!_currentEpisode(e)) throw _unavailable;
        return updated;
      });
      // Coverage is remembered only AFTER the transaction acknowledgement.
      for (final sample in batch.samples) {
        final at = sample.sampledAt;
        if (at == null ||
            at.isBefore(e.since) ||
            at.isAfter(e.until) ||
            (record.value.endedAt != null &&
                at.isAfter(record.value.endedAt!))) {
          continue;
        }
        if (e.first == null || at.isBefore(e.first!)) e.first = at;
        if (e.last == null || at.isAfter(e.last!)) e.last = at;
      }
      _publish(record, generation);
    });
  }

  bool _historySourceMatches(
    ActivityRecordingSourceIdentity source,
    BleIncomingEvent event,
  ) {
    if (source.nodeId == null) {
      return ActivityRecordingSourceIdentity.normalize(
            event.canonicalHardwareId,
          ) ==
          source.value;
    }
    final packet = event.positionBacklogPacket;
    return packet is! EixamPositionBacklogChunk ||
        packet.telPacket.nodeId == source.nodeId;
  }
}
