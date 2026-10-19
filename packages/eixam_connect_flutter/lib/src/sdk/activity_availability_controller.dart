import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/activity_availability_store.dart';
import '../data/datasources_remote/sdk_activity_availability_remote_data_source.dart';

/// Owns app assignment snapshots only. Network waits never hold the storage or
/// identity queue, so logout can detach a hung request immediately.
final class ActivityAvailabilityController
    implements ActivityAvailabilityControl {
  ActivityAvailabilityController({
    required this.store,
    this.remote,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ActivityAvailabilityStore store;
  final SdkActivityAvailabilityRemoteDataSource? remote;
  final DateTime Function() _clock;
  static final Map<Object, ActivityAvailabilityController> _writers = {};
  final Set<StreamController<_Observation>> _observers = {};
  Future<void> _tail = Future<void>.value();
  Future<SdkActivityAvailability>? _refresh;
  EixamSession? _identity;
  String? _scope;
  String _backend = '';
  SdkActivityAvailability? _snapshot;
  bool _loaded = false;
  bool _pendingClear = false;
  bool _used = false;
  bool _disposed = false;
  int _generation = 0;
  int _observationGeneration = 0;

  /// Composes existing SDK identity actions without implementing authentication.
  /// The synchronous fence also drops buffered events for paused subscribers.
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
      _observationGeneration++;
      _refresh = null;
      _loaded = false;
      _snapshot = null;
      _publish(null);
    }
    return _serialize(() async {
      _checkAlive();
      final previous = _identity;
      final previousScope = _scope;
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
      final nextBackend = backend();
      final scope = next == null ? null : _scopeFor(nextBackend, next);
      final oldId = _sdkUserId(previous);
      final newId = _sdkUserId(next);
      final canonicalChanged = oldId != null && newId != null && oldId != newId;
      _pendingClear |=
          clearData ||
          canonicalChanged ||
          (previousScope != scope && !(restoreExisting && previous == null)) ||
          next == null;
      _identity = next;
      _scope = scope;
      _backend = nextBackend;
      Object? cleanupError;
      StackTrace? cleanupStack;
      if (_pendingClear && _tryAcquire()) {
        try {
          await _clear();
        } catch (error, stack) {
          cleanupError = error;
          cleanupStack = stack;
          if (generation == _generation && !_disposed) {
            _publishError(error, stack);
          }
        } finally {
          if (!_used) _release();
        }
      }
      // Preserve the original SDK identity error when both actions fail.
      if (actionError != null) {
        Error.throwWithStackTrace(actionError, actionStack!);
      }
      if (cleanupError != null) {
        Error.throwWithStackTrace(cleanupError, cleanupStack!);
      }
      _checkGeneration(generation);
      if (_observers.isNotEmpty) {
        try {
          await _prepare(generation);
          await _load(generation);
        } catch (error, stack) {
          if (generation == _generation && !_disposed) {
            _publishError(error, stack);
          }
        }
      }
      _checkGeneration(generation);
      return result;
    });
  }

  /// Reject authorization on the captured identity only. A later identity
  /// fence makes this queued invalidation a no-op before it touches storage.
  Future<void> invalidateAuthorization(void Function() checkIdentity) {
    final generation = _generation;
    return _serialize(() async {
      _checkGeneration(generation);
      checkIdentity();
      final invalidatedGeneration = ++_generation;
      _observationGeneration++;
      _refresh = null;
      _snapshot = null;
      _loaded = false;
      _pendingClear = true;
      _publish(null);
      await _prepare(invalidatedGeneration);
    });
  }

  @override
  Future<SdkActivityAvailability?> getCachedActivityAvailability() {
    final generation = _generation;
    return _serialize(() async {
      await _prepare(generation);
      await _load(generation);
      return _cached(_snapshot);
    });
  }

  @override
  Future<SdkActivityAvailability> refreshActivityAvailability() {
    final existing = _refresh;
    if (existing != null) return existing;
    final result = _refreshFor(_generation);
    _refresh = result;
    // Clear on both outcomes without creating an unhandled rejected Future.
    unawaited(
      result.then<void>(
        (_) {
          if (identical(_refresh, result)) _refresh = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_refresh, result)) _refresh = null;
        },
      ),
    );
    return result;
  }

  Future<SdkActivityAvailability> _refreshFor(int generation) async {
    try {
      final session = await _serialize(() async {
        await _prepare(generation);
        final identity = _identity;
        if (identity == null) {
          throw const AuthException(
            'E_SDK_SESSION_REQUIRED',
            'An authenticated SDK session is required for availability.',
          );
        }
        try {
          await _load(generation);
        } on ActivityAvailabilityException catch (error, stack) {
          if (error.code != 'E_ACTIVITY_AVAILABILITY_RESTORE_FAILED') rethrow;
          // A corrupt cache must not prevent an authoritative replacement.
          _publishError(error, stack);
        }
        _checkGeneration(generation);
        return (session: identity, backend: _backend);
      });
      final source = remote;
      if (source == null) throw _unavailable;
      final activities = await source.fetch(
        session.session,
        backend: session.backend,
      );
      final snapshot = SdkActivityAvailability(
        activities: activities,
        fetchedAt: _clock(),
        fromCache: false,
      );
      return await _serialize(() async {
        await _prepare(generation);
        final record = ActivityAvailabilityRecord(
          ownerScope: _scope!,
          sdkUserId: _sdkUserId(_identity),
          snapshot: snapshot,
        );
        try {
          await _persist(record.encode());
          _checkGeneration(generation);
        } catch (_) {
          if (_disposed || generation != _generation) {
            // An IO write already in progress cannot be cancelled. Reconcile
            // it away before any later identity/reader can use this store.
            _pendingClear = true;
            await _clear();
            throw _unavailable;
          }
          rethrow;
        }
        _snapshot = snapshot;
        _loaded = true;
        _publish(snapshot);
        return snapshot;
      });
    } catch (error, stack) {
      return _serialize(() async {
        _checkGeneration(generation);
        if (error is AuthException && _identity != null) {
          _observationGeneration++;
          _snapshot = null;
          _loaded = false;
          _pendingClear = true;
          _publish(null);
          try {
            await _clear();
            _checkGeneration(generation);
          } catch (cleanupError, cleanupStack) {
            _checkGeneration(generation);
            _publishError(cleanupError, cleanupStack);
            rethrow;
          }
        }
        _publishError(error, stack);
        Error.throwWithStackTrace(error, stack);
      });
    }
  }

  @override
  Stream<SdkActivityAvailability?> watchActivityAvailability() {
    late final StreamController<_Observation> observer;
    var cancelled = false;
    observer = StreamController<_Observation>(
      onListen: () {
        final generation = _generation;
        final observationGeneration = _observationGeneration;
        unawaited(
          _serialize(() async {
            try {
              await _prepare(generation);
              // Load before registration; the seed and registration occupy one
              // storage queue slot, with no seed/live race or duplicate seed.
              await _load(generation);
              if (cancelled) return;
              _observers.add(observer);
              observer.add(
                _Observation.data(_observationGeneration, _cached(_snapshot)),
              );
            } catch (error, stack) {
              if (cancelled) return;
              if (_disposed) {
                unawaited(observer.close());
                return;
              }
              _observers.add(observer);
              observer.add(
                _Observation.error(
                  generation == _generation
                      ? _observationGeneration
                      : observationGeneration,
                  error,
                  stack,
                ),
              );
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
              if (event.error != null) {
                sink.addError(event.error!, event.stack);
              } else {
                sink.add(event.snapshot);
              }
            },
          ),
        );
  }

  Future<void> _prepare(int generation) async {
    _checkGeneration(generation);
    _used = true;
    if (!_tryAcquire()) throw _unavailable;
    if (_pendingClear) {
      await _clear();
      _checkGeneration(generation);
    }
  }

  Future<void> _load(int generation) async {
    if (_loaded) return;
    if (_identity == null) {
      _loaded = true;
      return;
    }
    ActivityAvailabilityRecord? record;
    try {
      final raw = await store.read();
      if (raw != null) record = ActivityAvailabilityRecord.decode(raw);
    } catch (_) {
      _checkGeneration(generation);
      throw const ActivityAvailabilityException(
        'E_ACTIVITY_AVAILABILITY_RESTORE_FAILED',
        'Availability cache is unreadable, corrupt, or unsupported.',
      );
    }
    _checkGeneration(generation);
    if (record != null &&
        (record.ownerScope != _scope ||
            (_sdkUserId(_identity) != null &&
                record.sdkUserId != null &&
                record.sdkUserId != _sdkUserId(_identity)))) {
      _pendingClear = true;
      await _clear();
      _checkGeneration(generation);
      record = null;
    }
    _snapshot = record?.snapshot;
    _loaded = true;
    _publish(_snapshot);
  }

  Future<void> _clear() async {
    await _persist(null);
    _pendingClear = false;
    _snapshot = null;
    _loaded = false;
  }

  Future<void> _persist(String? intended) async {
    try {
      if (intended == null) {
        await store.remove();
      } else {
        await store.write(intended);
      }
    } catch (_) {
      // Reconcile even lost/false acknowledgements against authoritative IO.
    }
    try {
      if (await store.read() == intended) return;
    } catch (_) {
      // No publication until the write can be verified.
    }
    throw const ActivityAvailabilityException(
      'E_ACTIVITY_AVAILABILITY_PERSISTENCE_FAILED',
      'Availability persistence could not be confirmed. Retry reconciliation.',
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

  void _publish(SdkActivityAvailability? snapshot) {
    for (final observer in _observers.toList()) {
      observer.add(_Observation.data(_observationGeneration, snapshot));
    }
  }

  void _publishError(Object error, StackTrace stack) {
    for (final observer in _observers.toList()) {
      observer.add(_Observation.error(_observationGeneration, error, stack));
    }
  }

  void _checkAlive() {
    if (_disposed) throw _unavailable;
  }

  void _checkGeneration(int generation) {
    _checkAlive();
    if (generation != _generation) throw _unavailable;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _observationGeneration++;
    try {
      await _tail;
      if (_pendingClear && identical(_writers[store.writerNamespace], this)) {
        await _clear();
      }
    } finally {
      _release();
      for (final observer in _observers.toList()) {
        unawaited(observer.close());
      }
      _observers.clear();
    }
  }

  static SdkActivityAvailability? _cached(SdkActivityAvailability? snapshot) =>
      snapshot == null
      ? null
      : SdkActivityAvailability(
          activities: snapshot.activities,
          fetchedAt: snapshot.fetchedAt,
          fromCache: true,
        );

  // Matches logical ActivitySession identity semantics, excluding signing hash.
  static String _scopeFor(String backend, EixamSession session) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
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

  static const _unavailable = ActivityAvailabilityException(
    'E_ACTIVITY_AVAILABILITY_UNAVAILABLE',
    'Availability was disposed, changed identity, or has another writer.',
  );
}

/// Tagged errors share the same paused-subscriber identity fence as values.
final class _Observation {
  const _Observation.data(this.generation, this.snapshot)
    : error = null,
      stack = null;
  const _Observation.error(this.generation, this.error, this.stack)
    : snapshot = null;
  final int generation;
  final SdkActivityAvailability? snapshot;
  final Object? error;
  final StackTrace? stack;
}
