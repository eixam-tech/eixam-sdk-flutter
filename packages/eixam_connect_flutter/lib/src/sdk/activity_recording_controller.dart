import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/activity_recording_record.dart';
import '../data/datasources_local/activity_recording_store.dart';
import '../data/datasources_local/activity_recording_route_data.dart';
import 'activity_recording_ingestor.dart';
import '../device/canonical_hardware_id.dart';
import '../device/ble_incoming_event.dart';
import 'device_position_backlog_coordinator.dart';

part 'activity_recording_recovery.dart';

typedef ActivityRecordingSessionGuard =
    Future<T> Function<T>(
      Future<T> Function(SdkActivitySession? session) action,
    );

/// Verified same-principal evidence supplied by the existing SDK runtime only.
final class ActivityRecordingDeviceEvidence {
  const ActivityRecordingDeviceEvidence(
    this.identity, {
    required this.connected,
  });
  final String identity;
  final bool connected;
}

/// Serialized durable recorder; retained history reuses the SDK coordinator.
/// No phone GPS, safety ownership or periodic polling is a dependency.
final class ActivityRecordingController implements ActivityRecordingControl {
  ActivityRecordingController({
    required this.store,
    required this.sessionGuard,
    required this.verifyDevice,
    DateTime Function()? clock,
    DevicePositionBacklogCoordinator? backlog,
    bool Function(String device)? historyEligible,
    Timer Function(Duration, void Function())? recoveryTimer,
    bool Function(BleIncomingEvent event, String device)? historyEventEligible,
  }) : _clock = clock ?? DateTime.now,
       _backlog = backlog,
       _historyEligible = historyEligible ?? ((_) => false),
       _recoveryTimer = recoveryTimer ?? Timer.new,
       _historyEventEligible = historyEventEligible ?? ((_, _) => true);

  final DevicePositionBacklogCoordinator? _backlog;
  final bool Function(String device) _historyEligible;
  final bool Function(BleIncomingEvent event, String device)
  _historyEventEligible;
  final Timer Function(Duration, void Function()) _recoveryTimer;
  _RecordingRecoveryEpisode? _recoveryEpisode;
  int _recoveryGeneration = 0;
  bool _lastHistoryEligible = false;
  String? _lastPathDevice;
  bool? _lastPathConnected;
  final ActivityRecordingStore store;
  final ActivityRecordingSessionGuard sessionGuard;
  final Future<ActivityRecordingDeviceEvidence?> Function(String identity)
  verifyDevice;
  final DateTime Function() _clock;
  static final Map<Object, ActivityRecordingController> _writers = {};
  final Set<StreamController<_Observation>> _observers = {};
  final Set<void Function()> _cancelRouteReads = {};
  Future<void> _tail = Future<void>.value();
  EixamSession? _identity;
  ActivityRecordingOwner? _owner;
  bool _pendingClear = false;
  bool _restored = false;
  bool _used = false;
  bool _disposed = false;
  bool _identityReady = false;
  int _generation = 0;
  int _observationGeneration = 0;
  String? _lastPublished;

  /// Fences immediately, then drains old IO before identity cleanup/adoption.
  /// No remote readiness request is made by the recorder.
  Future<T> withIdentityChange<T>(
    Future<T> Function() action, {
    required EixamSession? Function() currentSession,
    required String Function() backend,
    bool restoreExisting = false,
    bool clearData = false,
    bool preserveLocalState = false,
  }) {
    final generation = preserveLocalState ? _generation : ++_generation;
    if (!preserveLocalState) {
      _fenceRecovery();
      _lastHistoryEligible = false;
      _identityReady = false;
      for (final cancel in _cancelRouteReads.toList()) {
        cancel();
      }
      _observationGeneration++;
      _lastPublished = null;
    }
    return _serialize(() async {
      _checkAlive();
      final previous = _identity;
      final priorOwner = _owner;
      Object? actionError;
      StackTrace? actionStack;
      late T result;
      try {
        result = await action();
      } catch (error, stack) {
        actionError = error;
        actionStack = stack;
      }
      final conflict =
          actionError is AuthException &&
          actionError.code == 'E_SDK_IDENTITY_CONFLICT';
      final next = conflict ? null : currentSession();
      final owner = next == null
          ? null
          : ActivityRecordingOwner.forIdentity(backend(), next);
      final changed =
          priorOwner?.scope != owner?.scope ||
          (priorOwner != null && owner != null && priorOwner.conflicts(owner));
      _pendingClear |=
          clearData ||
          conflict ||
          next == null ||
          (changed && !(restoreExisting && previous == null));
      _identity = next;
      _owner = owner;
      _restored = false;
      Object? cleanupError;
      StackTrace? cleanupStack;
      try {
        if (_pendingClear) {
          _acquire();
          await store.clear();
          _pendingClear = false;
        }
      } catch (error, stack) {
        cleanupError = error;
        cleanupStack = stack;
      } finally {
        if (!_used) _release();
      }
      if (generation == _generation && !_disposed) {
        _identityReady = cleanupError == null;
        if (cleanupError != null) {
          _publishError(cleanupError, cleanupStack!, generation);
        } else if (_observers.isNotEmpty) {
          try {
            if (_identity != null) await _prepare(generation);
            final active = await _activeForObservation(generation);
            _publish(active, generation, force: true);
          } catch (error, stack) {
            _publishError(error, stack, generation);
          }
        }
      }
      if (actionError != null) {
        Error.throwWithStackTrace(actionError, actionStack!);
      }
      if (cleanupError != null) {
        Error.throwWithStackTrace(cleanupError, cleanupStack!);
      }
      _checkGeneration(generation);
      return result;
    });
  }

  /// Explicit canonical contradiction outside an SDK identity mutation.
  Future<void> rejectIdentity() => withIdentityChange<void>(
    () async {},
    currentSession: () => null,
    backend: () => '',
    clearData: true,
  );

  @override
  Future<SdkActivityRecording?> getActiveActivityRecording() => _command(
    (generation) => _activeForObservation(generation),
    requireIdentity: false,
  ).then((record) => record?.value);

  @override
  Stream<SdkActivityRecording?> watchActiveActivityRecording() {
    late final StreamController<_Observation> observer;
    var cancelled = false;
    observer = StreamController<_Observation>(
      onListen: () {
        final observationGeneration = _observationGeneration;
        unawaited(
          _command((generation) async {
            final active = await _activeForObservation(generation);
            _checkGeneration(generation);
            if (!cancelled) {
              _observers.add(observer);
              observer.add(_Observation(_observationGeneration, active?.value));
            }
          }, requireIdentity: false).catchError((
            Object error,
            StackTrace stack,
          ) {
            if (!cancelled && !_disposed) {
              observer.add(
                _Observation(observationGeneration, null, error, stack),
              );
              unawaited(observer.close());
            }
          }),
        );
      },
      onCancel: () {
        cancelled = true;
        _observers.remove(observer);
      },
    );
    return observer.stream
        .where(
          (event) => !_disposed && event.generation == _observationGeneration,
        )
        .transform(
          StreamTransformer.fromHandlers(
            handleData: (event, sink) {
              if (event.error case final error?) {
                sink.addError(error, event.stack);
              } else {
                sink.add(event.value);
              }
            },
          ),
        );
  }

  @override
  Future<SdkActivityRecording> startActivityRecording({
    required SdkActivitySession activitySession,
    String? deviceIdentity,
  }) => _command(
    (generation) => _withSession((session) async {
      _matchSession(session, activitySession);
      final existing = await _transaction(
        generation,
        (tx) => tx.active(_owner!.scope),
      );
      if (existing != null) {
        if (existing.value.activitySessionId != activitySession.sessionId ||
            existing.value.activityKey != activitySession.activityKey ||
            existing.value.activitySessionStartedAt !=
                activitySession.startedAt.toUtc()) {
          throw _conflict;
        }
        if (deviceIdentity != null &&
            normalizeCanonicalHardwareId(deviceIdentity) !=
                existing.value.deviceIdentity) {
          throw _deviceMismatch;
        }
        if (existing.value.phase != ActivityRecordingPhase.active) {
          throw _conflict;
        }
        _publish(existing, generation);
        return existing.value;
      }
      final evidence = deviceIdentity == null
          ? null
          : await _verifiedDevice(deviceIdentity, generation);
      final now = _clock().toUtc();
      if (now.isBefore(activitySession.startedAt.toUtc())) throw _invalidTime;
      final record = ActivityRecordingRecord(
        _owner!,
        SdkActivityRecording(
          recordingId: _newId(),
          activitySessionId: activitySession.sessionId,
          activityKey: activitySession.activityKey,
          activitySessionStartedAt: activitySession.startedAt,
          recordingStartedAt: now,
          deviceIdentity: evidence?.identity,
          phase: ActivityRecordingPhase.active,
          inputState: _input(evidence),
          recoveryState: ActivityRecordingRecoveryState.idle,
          routeQuality: ActivityRecordingRouteQuality.unknown,
        ),
      );
      await _transaction(generation, (tx) async {
        if (await tx.active(_owner!.scope) != null) throw _conflict;
        if (await tx.forSession(_owner!.scope, activitySession.sessionId) !=
            null) {
          throw const ActivityRecordingException(
            'E_RECORDING_ALREADY_FINISHED',
            'This activity session already has a retained finished recording.',
          );
        }
        await tx.insert(record);
      });
      _publish(record, generation);
      return record.value;
    }),
  );

  @override
  Future<SdkActivityRecording> bindActivityRecordingDevice({
    required String recordingId,
    required String deviceIdentity,
  }) => _command(
    (generation) => _withSession((session) async {
      final record = await _required(recordingId, generation);
      if (record.value.phase != ActivityRecordingPhase.active) throw _conflict;
      _matchSession(session, _sessionOf(record.value));
      final canonical = normalizeCanonicalHardwareId(deviceIdentity);
      if (canonical == null) throw _deviceMismatch;
      if (record.value.deviceIdentity case final existing?) {
        if (existing != canonical) throw _deviceMismatch;
        _publish(record, generation);
        return record.value;
      }
      final evidence = await _verifiedDevice(canonical, generation);
      final bound = record.transition(
        deviceIdentity: evidence.identity,
        inputState: _input(evidence),
        issues: {...record.value.issues}
          ..remove(ActivityRecordingIssue.deviceIdentityUnavailable),
      );
      await _transaction(generation, (tx) => tx.update(bound));
      _publish(bound, generation);
      return bound.value;
    }),
  );

  @override
  Future<SdkActivityRecording?> getActivityRecording({
    required String recordingId,
  }) => _command(
    (generation) async => (await _transaction(
      generation,
      (tx) => tx.byId(_owner!.scope, recordingId),
    ))?.value,
  );

  @override
  Future<SdkActivityRecording> recoverActivityRecordingHistory({
    required String recordingId,
  }) => _recover(recordingId);

  @override
  Future<SdkActivityRecording> finishActivityRecording({
    required String recordingId,
    DateTime? endedAt,
  }) => _command((generation) async {
    var record = await _required(recordingId, generation);
    if (record.value.phase == ActivityRecordingPhase.finished) {
      // A prior commit may have succeeded without an acknowledgement. Reconcile
      // observers without hiding a different recording that is active now.
      try {
        _publish(await _activeForObservation(generation), generation);
      } on ActivityRecordingException catch (error, stack) {
        if (error.code != 'E_RECORDING_SESSION_MISMATCH') rethrow;
        _publishError(error, stack, generation);
      }
      return record.value;
    }
    final priorCutoff = record.value.endedAt;
    if (priorCutoff != null &&
        endedAt != null &&
        priorCutoff != endedAt.toUtc()) {
      throw _invalidTime;
    }
    final now = _clock().toUtc();
    final cutoff = priorCutoff ?? endedAt?.toUtc() ?? now;
    if (cutoff.isBefore(record.value.recordingStartedAt) ||
        (priorCutoff == null && cutoff.isAfter(now))) {
      throw _invalidTime;
    }
    if (record.value.phase == ActivityRecordingPhase.active) {
      _fenceRecovery();
      if (record.value.recoveryState ==
          ActivityRecordingRecoveryState.recovering) {
        record = record.transition(
          recoveryState: ActivityRecordingRecoveryState.deferred,
        );
      }
      record = await _transaction(
        generation,
        (tx) => tx.finishRoute(record, cutoff),
      );
      _publish(record, generation);
    }
    final finished = record.transition(phase: ActivityRecordingPhase.finished);
    await _transaction(generation, (tx) => tx.update(finished));
    _publish(null, generation);
    return finished.value;
  });

  /// Called synchronously at the private decoded-D3 tap, before public dedupe.
  /// Captures the identity generation before queueing any asynchronous work.
  Future<void> ingestLive(EixamDevicePositionBatch batch) {
    if (!_used || _identity == null || _disposed) return Future.value();
    final generationAtReceipt = _generation;
    return _command(
      (generation) => _withSession((session) async {
        final record = await _transaction(generation, (tx) async {
          final current = await tx.active(_owner!.scope);
          if (current == null ||
              current.value.phase != ActivityRecordingPhase.active ||
              current.value.deviceIdentity == null ||
              normalizeCanonicalHardwareId(batch.deviceIdentity) !=
                  current.value.deviceIdentity ||
              batch.source != SdkLocationSource.connectedDevice ||
              batch.delivery != EixamDevicePositionDelivery.live) {
            return null;
          }
          _matchSession(session, _sessionOf(current.value));
          final updated = await const ActivityRecordingIngestor().ingest(
            tx,
            current,
            batch,
            _clock(),
          );
          final observing = updated.transition(
            inputState: ActivityRecordingInputState.observing,
          );
          if (updated.value.inputState !=
              ActivityRecordingInputState.observing) {
            await tx.update(observing);
          }
          return observing;
        });
        if (record != null) _publish(record, generation);
      }),
    ).catchError((Object error, StackTrace stack) {
      final safe = error is ActivityRecordingException
          ? error
          : const ActivityRecordingException(
              'E_RECORDING_PERSISTENCE_FAILED',
              'Recording input could not be committed.',
            );
      _publishError(safe, stack, generationAtReceipt);
      Error.throwWithStackTrace(safe, stack);
    });
  }

  /// Authoritative current TAG path fact, never inferred from GPS cadence.
  Future<void> inputDisconnected(String? currentDevice, bool connected) {
    final device = normalizeCanonicalHardwareId(currentDevice);
    final observedAt = _clock().toUtc();
    if (_lastPathDevice != device || _lastPathConnected != connected) {
      _fenceRecovery(defer: true);
      _lastPathDevice = device;
      _lastPathConnected = connected;
      _lastHistoryEligible = false;
    }
    if (!_used || _identity == null || _disposed) return Future.value();
    return _command((generation) async {
      final updated = await _transaction(generation, (tx) async {
        final current = await tx.active(_owner!.scope);
        if (current == null ||
            current.value.deviceIdentity == null ||
            current.value.phase != ActivityRecordingPhase.active) {
          return null;
        }
        final matching = device == current.value.deviceIdentity;
        if (!matching &&
            device != null &&
            (!connected ||
                current.value.inputState !=
                    ActivityRecordingInputState.observing)) {
          return null;
        }
        final attached = matching && connected;
        final input = attached
            ? ActivityRecordingInputState.observing
            : ActivityRecordingInputState.disconnected;
        if (current.value.inputState == input && attached) return null;
        return tx.inputPath(current, attached, observedAt);
      });
      if (updated != null) _publish(updated, generation);
    }).whenComplete(() {
      if (connected) reconcileHistoryReadiness();
    });
  }

  /// Event-driven readiness edge; repeated diagnostics never restart an exhausted episode.
  void reconcileHistoryReadiness({bool runtimeResumed = false}) {
    _reconcileHistoryReadiness();
    if (runtimeResumed) _triggerHistory();
  }

  @override
  Stream<SdkActivityRoutePage> readActivityRecordingRoute({
    required String recordingId,
    DateTime? fromInclusive,
    int? expectedRouteRevision,
    int pageSize = 512,
  }) {
    late final StreamController<_RouteObservation> output;
    var cancelled = false;
    Completer<void>? paused;
    void cancel() {
      cancelled = true;
      paused?.complete();
      paused = null;
    }

    output = StreamController<_RouteObservation>(
      onListen: () {
        _cancelRouteReads.add(cancel);
        final observationGeneration = _observationGeneration;
        unawaited(
          _command((generation) async {
                if (pageSize <= 0) {
                  throw ArgumentError.value(
                    pageSize,
                    'pageSize',
                    'Must be positive.',
                  );
                }
                // One transaction and actor turn define the finite route revision.
                // Keyset pages keep memory bounded; pause/cancel owns the transaction.
                await _transaction(generation, (tx) async {
                  final record = await tx.byId(_owner!.scope, recordingId);
                  if (record == null) throw _notFound;
                  if (expectedRouteRevision != null &&
                      expectedRouteRevision != record.value.routeRevision) {
                    throw const ActivityRecordingException(
                      'E_RECORDING_ROUTE_REVISION_CHANGED',
                      'Read fresh recording state before retrying the route read.',
                    );
                  }
                  ActivityRecordingRouteCursor? cursor;
                  do {
                    if (cancelled) break;
                    _checkGeneration(generation);
                    final slice = await tx.routePage(
                      record,
                      fromInclusive: fromInclusive,
                      after: cursor,
                      pageSize: pageSize,
                    );
                    if (cancelled) break;
                    output.add(
                      _RouteObservation(
                        observationGeneration,
                        SdkActivityRoutePage(
                          recordingId: recordingId,
                          routeRevision: record.value.routeRevision,
                          segments: slice.segments,
                          gaps: slice.gaps,
                          isLast: slice.last,
                        ),
                      ),
                    );
                    if (slice.last) break;
                    cursor = slice.next;
                    await Future<void>.delayed(Duration.zero);
                    if (paused != null) await paused!.future;
                  } while (!cancelled);
                });
              })
              .catchError((Object error, StackTrace stack) {
                if (!cancelled) {
                  output.add(
                    _RouteObservation(
                      observationGeneration,
                      null,
                      error,
                      stack,
                    ),
                  );
                }
              })
              .whenComplete(() {
                _cancelRouteReads.remove(cancel);
                unawaited(output.close());
              }),
        );
      },
      onPause: () {
        paused ??= Completer<void>();
      },
      onResume: () {
        paused?.complete();
        paused = null;
      },
      onCancel: cancel,
    );
    return output.stream
        .where(
          (event) => !_disposed && event.generation == _observationGeneration,
        )
        .transform(
          StreamTransformer.fromHandlers(
            handleData: (event, sink) {
              if (event.error case final error?) {
                sink.addError(error, event.stack);
              } else {
                sink.add(event.page!);
              }
            },
          ),
        );
  }

  Future<T> _command<T>(
    Future<T> Function(int generation) action, {
    bool requireIdentity = true,
  }) {
    final generation = _generation;
    return _serialize(() async {
      _checkGeneration(generation);
      _used = true;
      _acquire();
      if (_pendingClear) {
        await store.clear();
        _checkGeneration(generation);
        _pendingClear = false;
        _identityReady = true;
      }
      if (!_identityReady) throw _unavailable;
      if (_identity == null) {
        if (requireIdentity) throw _identityRequired;
      } else {
        await _prepare(generation);
      }
      final result = await action(generation);
      _checkGeneration(generation);
      return result;
    });
  }

  Future<void> _prepare(int generation) async {
    if (_restored) return;
    final conflict = await _transaction(
      generation,
      (tx) => tx.reconcileOwner(_owner!),
    );
    if (conflict) {
      _identityReady = false;
      throw _identityRequired;
    }
    if (!_restored) {
      // Only an already committed user finish intent is completed on restart.
      final restored = await _transaction(generation, (tx) async {
        final record = await tx.active(_owner!.scope);
        if (record?.value.phase == ActivityRecordingPhase.finalizing) {
          await tx.update(
            record!.transition(phase: ActivityRecordingPhase.finished),
          );
          return true;
        }
        if (record?.value.phase == ActivityRecordingPhase.active) {
          var current = record!;
          if (current.value.inputState ==
              ActivityRecordingInputState.observing) {
            current = current.transition(
              inputState: ActivityRecordingInputState.disconnected,
            );
            await tx.update(current);
          }
          if (current.value.recoveryState ==
              ActivityRecordingRecoveryState.recovering) {
            current = current.transition(
              recoveryState: ActivityRecordingRecoveryState.deferred,
            );
            await tx.update(current);
            await tx.needRecovery(current);
          }
          final window = await tx.recoveryWindow(current);
          if (window.needed) scheduleMicrotask(_triggerHistory);
        }
        return false;
      });
      _restored = true;
      if (restored) _publish(null, generation);
    }
  }

  Future<ActivityRecordingRecord?> _activeForObservation(int generation) async {
    if (_identity == null) return null;
    final record = await _transaction(
      generation,
      (tx) => tx.active(_owner!.scope),
    );
    if (record?.value.phase == ActivityRecordingPhase.active) {
      await _withSession(
        (session) async => _matchSession(session, _sessionOf(record!.value)),
      );
      _checkGeneration(generation);
    }
    return record;
  }

  Future<T> _transaction<T>(
    int generation,
    Future<T> Function(ActivityRecordingTransaction tx) action,
  ) async {
    _checkGeneration(generation);
    final result = await store.transaction((tx) async {
      _checkGeneration(generation);
      final result = await action(tx);
      _checkGeneration(generation);
      return result;
    });
    _checkGeneration(generation);
    return result;
  }

  Future<ActivityRecordingRecord> _required(String id, int generation) async =>
      await _transaction<ActivityRecordingRecord?>(
        generation,
        (tx) => tx.byId(_owner!.scope, id),
      ) ??
      (throw _notFound);

  Future<ActivityRecordingDeviceEvidence> _verifiedDevice(
    String requested,
    int generation,
  ) async {
    final normalized = normalizeCanonicalHardwareId(requested);
    if (normalized == null) throw _deviceMismatch;
    final evidence = await verifyDevice(normalized);
    _checkGeneration(generation);
    if (evidence == null ||
        normalizeCanonicalHardwareId(evidence.identity) != normalized) {
      throw _deviceMismatch;
    }
    return ActivityRecordingDeviceEvidence(
      normalized,
      connected: evidence.connected,
    );
  }

  Future<T> _withSession<T>(
    Future<T> Function(SdkActivitySession?) action,
  ) async {
    try {
      return await sessionGuard(action);
    } on ActivityRecordingException {
      rethrow;
    } on ActivitySessionException {
      throw const ActivityRecordingException(
        'E_RECORDING_SESSION_MISMATCH',
        'The logical activity session cannot be read or validated.',
      );
    }
  }

  void _matchSession(SdkActivitySession? actual, SdkActivitySession expected) {
    if (actual == null ||
        actual.sessionId != expected.sessionId ||
        actual.activityKey != expected.activityKey ||
        actual.startedAt != expected.startedAt.toUtc()) {
      throw const ActivityRecordingException(
        'E_RECORDING_SESSION_MISMATCH',
        'Recording association does not match the current readable activity session.',
      );
    }
  }

  static SdkActivitySession _sessionOf(SdkActivityRecording r) =>
      SdkActivitySession(
        sessionId: r.activitySessionId,
        activityKey: r.activityKey,
        startedAt: r.activitySessionStartedAt,
      );

  static ActivityRecordingInputState _input(
    ActivityRecordingDeviceEvidence? evidence,
  ) => evidence == null
      ? ActivityRecordingInputState.unbound
      : evidence.connected
      ? ActivityRecordingInputState.unavailable
      : ActivityRecordingInputState.disconnected;

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _acquire() {
    final writer = _writers[store.writerNamespace];
    if (writer != null && !identical(writer, this)) throw _unavailable;
    _writers[store.writerNamespace] = this;
  }

  void _release() {
    if (identical(_writers[store.writerNamespace], this)) {
      _writers.remove(store.writerNamespace);
    }
  }

  void _checkAlive() {
    if (_disposed) throw _unavailable;
  }

  void _checkGeneration(int generation) {
    _checkAlive();
    if (generation != _generation) throw _unavailable;
  }

  void _publish(
    ActivityRecordingRecord? record,
    int generation, {
    bool force = false,
  }) {
    if (_disposed || generation != _generation) return;
    final signature = jsonEncode(record?.encode());
    if (!force && signature == _lastPublished) return;
    _lastPublished = signature;
    for (final observer in _observers.toList()) {
      observer.add(_Observation(_observationGeneration, record?.value));
    }
  }

  void _publishError(Object error, StackTrace stack, int generation) {
    if (_disposed || generation != _generation) return;
    for (final observer in _observers.toList()) {
      observer.add(_Observation(_observationGeneration, null, error, stack));
    }
  }

  /// Fences new work, drains existing transactions, closes readers and releases
  /// the lease. Never deletes committed recording data.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _fenceRecovery();
    for (final cancel in _cancelRouteReads.toList()) {
      cancel();
    }
    _generation++;
    _observationGeneration++;
    await _tail;
    for (final observer in _observers.toList()) {
      unawaited(observer.close());
    }
    _observers.clear();
    try {
      await store.dispose();
    } finally {
      _release();
    }
  }

  static String _newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

final class _Observation {
  const _Observation(this.generation, this.value, [this.error, this.stack]);
  final int generation;
  final SdkActivityRecording? value;
  final Object? error;
  final StackTrace? stack;
}

final class _RouteObservation {
  const _RouteObservation(this.generation, this.page, [this.error, this.stack]);
  final int generation;
  final SdkActivityRoutePage? page;
  final Object? error;
  final StackTrace? stack;
}

const _unavailable = ActivityRecordingException(
  'E_RECORDING_UNAVAILABLE',
  'Recording was disposed, changed identity, has another writer, or awaits cleanup.',
);
const _identityRequired = ActivityRecordingException(
  'E_RECORDING_IDENTITY_REQUIRED',
  'A trusted current SDK identity is required for recording.',
);
const _conflict = ActivityRecordingException(
  'E_RECORDING_CONFLICT',
  'A conflicting recording lifecycle occupies this identity.',
);
const _deviceMismatch = ActivityRecordingException(
  'E_RECORDING_DEVICE_MISMATCH',
  'The requested TAG does not match immutable, verified identity evidence.',
);
const _notFound = ActivityRecordingException(
  'E_RECORDING_NOT_FOUND',
  'No recording with this ID exists in the current identity.',
);
const _invalidTime = ActivityRecordingException(
  'E_RECORDING_INVALID_TIME',
  'The recording time is outside its permitted window or changes a fixed cutoff.',
);
