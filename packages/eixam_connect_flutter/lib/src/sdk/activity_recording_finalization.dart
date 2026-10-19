part of 'activity_recording_controller.dart';

/// The durable row owns intent and deadline. This future only coalesces callers
/// within one identity generation; it is never required for process restoration.
final class _RecordingFinalization {
  _RecordingFinalization(this.identityGeneration);
  final int identityGeneration;
  final Completer<SdkActivityRecording> result = Completer();
  final Completer<void> stopped = Completer();
  Timer? timer;
  bool expired = false;
}

extension _ActivityRecordingFinalization on ActivityRecordingController {
  static const _finishBudget = Duration(seconds: 5);

  Future<SdkActivityRecording> _finish(String id, DateTime? endedAt) async {
    final request = await _command((generation) async {
      var record = await _required(id, generation);
      final r = record.value;
      if (r.endedAt != null &&
          endedAt != null &&
          r.endedAt != endedAt.toUtc()) {
        throw _invalidTime;
      }
      if (r.phase == ActivityRecordingPhase.finished) {
        // Read authoritative state after a lost commit acknowledgement, without
        // hiding a later recording that is active now.
        try {
          _publish(await _activeForObservation(generation), generation);
        } on ActivityRecordingException catch (error, stack) {
          if (error.code != 'E_RECORDING_SESSION_MISMATCH') rethrow;
          _publishError(error, stack, generation);
        }
        return _RecordingRecoveryRequest(Future.value(r));
      }
      final running = _finalizations[id];
      if (running != null && running.identityGeneration == generation) {
        return _RecordingRecoveryRequest(running.result.future);
      }
      final now = _clock().toUtc();
      final cutoff = r.endedAt ?? endedAt?.toUtc() ?? now;
      if (cutoff.isBefore(r.recordingStartedAt) ||
          (r.endedAt == null && cutoff.isAfter(now))) {
        throw _invalidTime;
      }
      final finish = _RecordingFinalization(generation);
      finish.result.future.ignore();
      if (r.phase == ActivityRecordingPhase.active) {
        // Start the runtime cap before storage IO. Clock rollback cannot extend
        // this timer, and the same deadline survives every restart.
        _armFinalization(finish, _finishBudget);
        try {
          record = await _transaction(generation, (tx) async {
            final clipped = await tx.finishRoute(record, cutoff);
            final durable = clipped.transition(
              finalizationStartedAt: now,
              finalizationDeadlineAt: now.add(_finishBudget),
            );
            await tx.update(durable);
            return durable;
          });
        } catch (error, stack) {
          final authoritative = await _afterUncertainWrite(id, generation);
          if (authoritative?.value.phase != ActivityRecordingPhase.finalizing ||
              authoritative?.value.endedAt != cutoff) {
            finish.timer?.cancel();
            Error.throwWithStackTrace(error, stack);
          }
          record = authoritative!;
        }
        _publish(record, generation);
      } else {
        _armFinalization(finish, _remainingFinalization(record));
        try {
          // A prior process/version's finalizing intent is not proof that its
          // persisted points are valid. Keep its frozen cutoff and deadline.
          record = await _transaction(
            generation,
            (tx) => tx.finishRoute(record, cutoff),
          );
        } catch (_) {
          finish.timer?.cancel();
          rethrow;
        }
      }
      _finalizations[id] = finish;
      scheduleMicrotask(() => unawaited(_runFinalization(record, finish)));
      return _RecordingRecoveryRequest(finish.result.future);
    });
    return request.result;
  }

  Future<ActivityRecordingRecord?> _afterUncertainWrite(
    String id,
    int generation,
  ) async {
    try {
      return await _required(id, generation);
    } on ActivityRecordingException {
      return null;
    }
  }

  Duration _remainingFinalization(ActivityRecordingRecord record) {
    final start = record.finalizationStartedAt;
    final deadline = record.finalizationDeadlineAt;
    final now = _clock().toUtc();
    // Legacy finalizing rows have no timing proof. Missing or inconsistent
    // evidence never earns another fresh five-second window.
    if (start == null || deadline == null || now.isBefore(start)) {
      return Duration.zero;
    }
    final remaining = deadline.difference(now);
    return remaining <= Duration.zero ? Duration.zero : remaining;
  }

  void _armFinalization(_RecordingFinalization finish, Duration remaining) {
    void expire() {
      finish.expired = true;
      if (!finish.stopped.isCompleted) finish.stopped.complete();
    }

    if (remaining <= Duration.zero) {
      expire();
    } else {
      finish.timer = _recoveryTimer(remaining, expire);
    }
  }

  void _resumeFinalization(ActivityRecordingRecord record, int generation) {
    if (_disposed || generation != _generation) return;
    _finish(record.value.recordingId, null).then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _publishError(error, stack, generation);
      },
    );
  }

  void _fenceFinalizations() {
    for (final finish in _finalizations.values) {
      finish.timer?.cancel();
      if (!finish.stopped.isCompleted) finish.stopped.complete();
    }
    _finalizations.clear();
  }

  Future<void> _runFinalization(
    ActivityRecordingRecord record,
    _RecordingFinalization finish,
  ) async {
    final id = record.value.recordingId;
    _RecordingRecoveryEpisode? episode;
    try {
      var recoveryFailed = false;
      _RecordingRecoveryRequest? request;
      try {
        request = await _command((generation) async {
          _checkGeneration(finish.identityGeneration);
          final current = await _required(id, generation);
          if (current.value.phase != ActivityRecordingPhase.finalizing) {
            throw _unavailable;
          }
          final remaining = _remainingFinalization(current);
          final device = current.value.deviceIdentity;
          final running = _recoveryEpisode;
          if (running != null &&
              _currentEpisode(running) &&
              running.record.value.recordingId == id) {
            episode = running;
            // Narrow acceptance even though an older on-wire request cannot be
            // rewritten. The authoritative row also checks the exact cutoff.
            if (running.until.isAfter(current.value.endedAt!)) {
              running.until = current.value.endedAt!;
            }
            // Coverage from a point clipped by this cutoff cannot prove a gap.
            if (running.last?.isAfter(current.value.endedAt!) == true) {
              running.last = null;
              running.rejected = true;
            }
            if (running.first?.isAfter(current.value.endedAt!) == true) {
              running.first = null;
            }
            running.finalizing = true;
            running.deadlineAt = _clock().toUtc().add(remaining);
            running.deadline?.cancel();
            running.deadline = _recoveryTimer(
              remaining,
              () => _expireHistory(running),
            );
          }
          if (finish.expired || remaining <= Duration.zero) return null;
          if (episode != null) {
            return _RecordingRecoveryRequest(episode!.result.future);
          }
          if (device == null ||
              _backlog == null ||
              _backlog.isActive ||
              !_historyEligible(device)) {
            return null;
          }
          final window = await _transaction(
            generation,
            (tx) => tx.recoveryWindow(current),
          );
          if (window.since.isAfter(current.value.endedAt!)) return null;
          final e = _RecordingRecoveryEpisode(
            current,
            generation,
            ++_recoveryGeneration,
            window.since,
            current.value.endedAt!,
          );
          e.finalizing = true;
          e.budget = remaining;
          e.deadlineAt = current.finalizationDeadlineAt;
          e.result.future.ignore();
          _recoveryEpisode = e;
          episode = e;
          final recovering = current.transition(
            recoveryState: ActivityRecordingRecoveryState.recovering,
          );
          await _transaction(generation, (tx) => tx.update(recovering));
          _publish(recovering, generation);
          if (finish.expired ||
              _remainingFinalization(current) <= Duration.zero) {
            _expireHistory(e);
            return null;
          }
          e.budget = _remainingFinalization(current);
          scheduleMicrotask(() => unawaited(_runHistoryEpisode(e)));
          return _RecordingRecoveryRequest(e.result.future);
        });
      } on ActivityRecordingException catch (error) {
        if (error.code != 'E_RECORDING_PERSISTENCE_FAILED') rethrow;
        _checkGeneration(finish.identityGeneration);
        recoveryFailed = true;
      }
      if (request != null) {
        try {
          await Future.any<Object?>([request.result, finish.stopped.future]);
        } on ActivityRecordingException catch (error) {
          if (error.code != 'E_RECORDING_UNAVAILABLE' &&
              error.code != 'E_RECORDING_PERSISTENCE_FAILED') {
            rethrow;
          }
          recoveryFailed = error.code == 'E_RECORDING_PERSISTENCE_FAILED';
          _checkGeneration(finish.identityGeneration);
          // A lost TAG path ends recovery, not durable finish intent.
        }
      }
      // Every accepted point transaction already queued on the recorder actor
      // drains before this turn. Fencing here prevents any later callback from
      // committing behind the final result, without waiting on public consumers.
      final result = await _command((generation) async {
        _checkGeneration(finish.identityGeneration);
        if (identical(_recoveryEpisode, episode) && episode != null) {
          _fenceRecovery();
        }
        late ActivityRecordingRecord committed;
        try {
          committed = await _transaction(generation, (tx) async {
            var current = await tx.byId(_owner!.scope, id);
            if (current == null) throw _notFound;
            if (current.value.phase == ActivityRecordingPhase.finished) {
              return current;
            }
            if (current.value.phase != ActivityRecordingPhase.finalizing) {
              throw _conflict;
            }
            if (finish.expired ||
                request == null ||
                recoveryFailed ||
                current.value.recoveryState ==
                    ActivityRecordingRecoveryState.deferred ||
                current.value.recoveryState ==
                    ActivityRecordingRecoveryState.recovering) {
              final rollback =
                  current.finalizationStartedAt != null &&
                  _clock().toUtc().isBefore(current.finalizationStartedAt!);
              current = current.transition(
                issues: {
                  ...current.value.issues,
                  if (finish.expired && episode != null)
                    ActivityRecordingIssue.recoveryTimedOut,
                  if (rollback) ActivityRecordingIssue.clockUncertain,
                  if (recoveryFailed) ActivityRecordingIssue.recoveryFailed,
                  if (request == null &&
                      !finish.expired &&
                      current.value.deviceIdentity != null)
                    ActivityRecordingIssue.commandOwnerUnavailable,
                },
              );
              current = await tx.settleRecovery(current, completed: false);
            }
            final finished = current.transition(
              phase: ActivityRecordingPhase.finished,
              inputState: current.value.deviceIdentity == null
                  ? ActivityRecordingInputState.unbound
                  : ActivityRecordingInputState.unavailable,
              recoveryState: ActivityRecordingRecoveryState.idle,
            );
            await tx.update(finished);
            return finished;
          });
        } catch (error, stack) {
          final authoritative = await _afterUncertainWrite(id, generation);
          if (authoritative?.value.phase != ActivityRecordingPhase.finished) {
            Error.throwWithStackTrace(error, stack);
          }
          committed = authoritative!;
        }
        _publish(null, generation);
        return committed.value;
      });
      finish.result.complete(result);
    } catch (error, stack) {
      finish.result.completeError(error, stack);
    } finally {
      finish.timer?.cancel();
      if (identical(_finalizations[id], finish)) _finalizations.remove(id);
    }
  }
}
