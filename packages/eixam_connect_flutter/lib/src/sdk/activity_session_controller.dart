import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/activity_session_store.dart';

/// Owns logical sessions only. No tracking, native, SOS or DMP dependencies.
final class ActivitySessionController implements ActivitySessionControl {
  ActivitySessionController({required this.store, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final ActivitySessionStore store;
  final DateTime Function() _clock;
  static final Map<Object, ActivitySessionController> _writers = {};
  final Set<StreamController<_ActivityObservation>> _observers = {};
  Future<void> _tail = Future<void>.value();
  EixamSession? _identity;
  String? _scope;
  ActivitySessionRecord? _record;
  SdkActivitySession? _lastPublished;
  bool _hasPublished = false;
  bool _loaded = false;
  bool _pendingClear = false;
  bool _used = false;
  bool _disposed = false;
  int _generation = 0;
  int _observationGeneration = 0;

  /// Fences commands immediately, then orders SDK identity work and activity
  /// cleanup together. Existing SDK identity actions are supplied unchanged.
  Future<T> withIdentityChange<T>(
    Future<T> Function() action, {
    required EixamSession? Function() currentSession,
    required String Function() backend,
    bool restoreExisting = false,
    bool clearData = false,
  }) {
    final generation = ++_generation;
    _loaded = false;
    return _serialize(() async {
      _checkAlive();
      final previous = _identity;
      final priorScope = _scope;
      Object? actionError;
      StackTrace? actionStack;
      late T result;
      try {
        result = await action();
      } catch (error, stack) {
        actionError = error;
        actionStack = stack;
      }
      final next = currentSession();
      final scope = next == null ? null : _scopeFor(backend(), next);
      final previousId = _sdkUserId(previous);
      final nextId = _sdkUserId(next);
      final canonicalChanged =
          previousId != null && nextId != null && previousId != nextId;
      final changed = priorScope != scope || canonicalChanged;
      _pendingClear |=
          clearData ||
          canonicalChanged ||
          (changed && !(restoreExisting && previous == null)) ||
          next == null;
      _identity = next;
      _scope = scope;
      _loaded = false;

      Object? cleanupError;
      StackTrace? cleanupStack;
      // Bootstrap never acquires a lasting lease. Contending runtimes leave the
      // owner's record alone and report contention through capability access.
      if (_pendingClear && _tryAcquire()) {
        try {
          await _persist(null);
          _pendingClear = false;
          _record = null;
        } catch (error, stack) {
          cleanupError = error;
          cleanupStack = stack;
        } finally {
          if (!_used) _release();
        }
      }
      if (changed || clearData) {
        // Drop buffered events from the previous account, even for paused
        // subscribers resuming after the identity transition completed.
        _observationGeneration++;
      }
      if (cleanupError != null) {
        // Identity invalidation must not masquerade as a confirmed end/wipe.
        _hasPublished = false;
        for (final observer in _observers.toList()) {
          observer.add(
            _ActivityObservation.error(
              _observationGeneration,
              cleanupError,
              cleanupStack,
            ),
          );
        }
      } else if (changed || clearData) {
        _publish(null, force: true);
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

  @override
  Future<SdkActivitySession?> getActiveActivitySession() =>
      _command(() async => _record?.active);

  @override
  Stream<SdkActivitySession?> watchActiveActivitySession() {
    late final StreamController<_ActivityObservation> observer;
    var cancelled = false;
    observer = StreamController<_ActivityObservation>(
      onListen: () {
        final commandGeneration = _generation;
        final observationGeneration = _observationGeneration;
        unawaited(
          _command(() async {
            if (!cancelled) {
              // Registration and seed share the same queue slot. No mutation can
              // fall between them, including while restoration is awaiting IO.
              _observers.add(observer);
              observer.add(
                _ActivityObservation.data(
                  _observationGeneration,
                  _record?.active,
                ),
              );
            }
          }).catchError((Object error, StackTrace stack) {
            if (!cancelled) {
              observer.add(
                _ActivityObservation.error(
                  commandGeneration == _generation
                      ? _observationGeneration
                      : observationGeneration,
                  error,
                  stack,
                ),
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
              final error = event.error;
              if (error != null) {
                sink.addError(error, event.stackTrace);
              } else {
                sink.add(event.session);
              }
            },
          ),
        );
  }

  @override
  Future<SdkActivitySession> startActivitySession({
    required String activityKey,
  }) {
    return _command(() async {
      _requireIdentity();
      SdkActivitySession.validateActivityKey(activityKey);
      final current = _record?.active;
      if (current != null) {
        if (current.activityKey == activityKey) return current;
        throw _conflict;
      }
      final session = SdkActivitySession(
        sessionId: _newSessionId(),
        activityKey: activityKey,
        startedAt: _clock().toUtc(),
      );
      await _commit(
        ActivitySessionRecord(
          ownerScope: _scope!,
          sdkUserId: _sdkUserId(_identity),
          session: session,
        ),
      );
      return session;
    });
  }

  @override
  Future<void> endActivitySession({required String sessionId}) {
    return _command(() async {
      _requireIdentity();
      final record = _record;
      if (record == null) return;
      if (record.session.sessionId != sessionId) throw _conflict;
      if (record.endedAt != null) return;
      final now = _clock().toUtc();
      await _commit(
        ActivitySessionRecord(
          ownerScope: _scope!,
          sdkUserId: _sdkUserId(_identity),
          session: record.session,
          endedAt: now.isBefore(record.session.startedAt)
              ? record.session.startedAt
              : now,
        ),
      );
    });
  }

  Future<T> _command<T>(Future<T> Function() action) {
    final generation = _generation;
    return _serialize(() async {
      _checkGeneration(generation);
      _used = true;
      if (!_tryAcquire()) throw _unavailable;
      await _load(generation);
      _checkGeneration(generation);
      return action();
    });
  }

  Future<void> _load(int generation) async {
    if (_loaded) return;
    if (_pendingClear) {
      await _persist(null);
      _checkGeneration(generation);
      _pendingClear = false;
    }
    ActivitySessionRecord? record;
    try {
      final raw = await store.read();
      if (raw != null) record = ActivitySessionRecord.decode(raw);
    } catch (_) {
      throw const ActivitySessionException(
        'E_ACTIVITY_RESTORE_FAILED',
        'Activity storage is unreadable, corrupt, or uses an unsupported schema.',
      );
    }
    _checkGeneration(generation);
    if (record != null &&
        (record.ownerScope != _scope ||
            (_sdkUserId(_identity) != null &&
                record.sdkUserId != null &&
                record.sdkUserId != _sdkUserId(_identity)))) {
      await _persist(null);
      _checkGeneration(generation);
      record = null;
    }
    _record = record;
    _loaded = true;
    _publish(record?.active);
  }

  Future<void> _commit(ActivitySessionRecord record) async {
    final generation = _generation;
    await _persist(record.encode());
    _checkGeneration(generation);
    _record = record;
    _loaded = true;
    _publish(record.active);
  }

  Future<void> _persist(String? intended) async {
    _loaded = false;
    try {
      // A false result or exception may still mean the write was applied.
      // Always reload through the backend, not SharedPreferences' local cache.
      if (intended == null) {
        await store.remove();
      } else {
        await store.write(intended);
      }
    } catch (_) {
      // The authoritative read below resolves an ambiguous acknowledgement.
    }
    try {
      if (await store.read() == intended) return;
    } catch (_) {
      // Keep the cache unready until a later successful reconciliation.
    }
    throw const ActivitySessionException(
      'E_ACTIVITY_PERSISTENCE_FAILED',
      'Activity persistence could not be confirmed. Retry reconciliation.',
    );
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  bool _tryAcquire() {
    final owner = _writers[store.writerNamespace];
    if (owner != null && !identical(owner, this)) return false;
    _writers[store.writerNamespace] = this;
    return true;
  }

  void _release() {
    if (identical(_writers[store.writerNamespace], this)) {
      _writers.remove(store.writerNamespace);
    }
  }

  void _publish(SdkActivitySession? active, {bool force = false}) {
    if (!force &&
        _hasPublished &&
        _lastPublished?.sessionId == active?.sessionId &&
        _lastPublished?.activityKey == active?.activityKey &&
        _lastPublished?.startedAt == active?.startedAt) {
      return;
    }
    _lastPublished = active;
    _hasPublished = true;
    for (final observer in _observers.toList()) {
      observer.add(_ActivityObservation.data(_observationGeneration, active));
    }
  }

  void _requireIdentity() {
    if (_identity == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'An authenticated SDK session is required for activity commands.',
      );
    }
  }

  void _checkAlive() {
    if (_disposed) throw _unavailable;
  }

  void _checkGeneration(int generation) {
    _checkAlive();
    if (generation != _generation) throw _unavailable;
  }

  /// Drains in-flight storage but preserves the logical session on disk.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    await _tail;
    _release();
    for (final observer in _observers.toList()) {
      unawaited(observer.close());
    }
    _observers.clear();
  }

  static String _scopeFor(String backend, EixamSession session) => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String>[
            backend.replaceFirst(RegExp(r'/+$'), ''),
            session.appId,
            session.externalUserId,
          ]),
        ),
      )
      .toString();

  static String? _sdkUserId(EixamSession? identity) {
    final id = identity?.sdkUserId;
    return id == null || id.trim().isEmpty ? null : id;
  }

  static String _newSessionId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  static const _conflict = ActivitySessionException(
    'E_ACTIVITY_CONFLICT',
    'A different activity or session ID already occupies this scope.',
  );
  static const _unavailable = ActivitySessionException(
    'E_ACTIVITY_UNAVAILABLE',
    'Activity capability was disposed, changed identity, or has another writer.',
  );
}

/// Errors travel as tagged data internally so pausing cannot bypass the same
/// principal fence applied to session values. Only the public stream unwraps.
final class _ActivityObservation {
  const _ActivityObservation.data(this.generation, this.session)
    : error = null,
      stackTrace = null;

  const _ActivityObservation.error(this.generation, this.error, this.stackTrace)
    : session = null;

  final int generation;
  final SdkActivitySession? session;
  final Object? error;
  final StackTrace? stackTrace;
}
