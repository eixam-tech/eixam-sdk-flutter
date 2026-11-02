import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_local/tag_alert_store.dart';
import '../tag_alerts/tag_alert_permission_gateway.dart';

/// Owns per-TAG alert settings and the cleanup of scheduled/delivered alerts.
///
/// Mirrors `ActivityAvailabilityController`: serialized storage, a writer
/// lease per physical store, and a synchronous identity fence so logout can
/// never be observed half-applied. It carries no battery or connection policy.
final class TagAlertsController implements TagAlertsControl {
  TagAlertsController({
    required this.store,
    required this.notifier,
    this.permissions = const UnsupportedTagAlertPermissionGateway(),
    this.notifierTimeout = defaultNotifierTimeout,
  });

  /// Bound for every notifier call made inside the serialized tail, so a hung
  /// platform call can never hold logout, unpair or settings changes.
  static const Duration defaultNotifierTimeout = Duration(seconds: 5);
  final Duration notifierTimeout;

  final TagAlertStore store;
  final TagAlertNotifier notifier;
  final TagAlertPermissionGateway permissions;
  static final Map<Object, TagAlertsController> _writers = {};
  final Set<_Watcher> _watchers = {};
  Future<void> _tail = Future<void>.value();
  EixamSession? _identity;
  String? _scope;
  Map<String, TagAlertSettings> _devices = {};
  Map<String, TagBatteryCycle> _cycles = {};
  // Confirmation streaks are transient and per identity; never persisted.
  final Map<String, TagBatteryStreak> _streaks = {};
  // Sticky until the next successful write or clear, so late watchers learn
  // that the stored data was unreadable and defaults are in effect.
  _Failure? _restoreFailure;
  bool _loaded = false;
  bool _pendingClear = false;
  // Cleanup the notifier could not complete (error or timeout). The data is
  // already gone, but delivered/scheduled alerts show the TAG alias, so they
  // are retried before every controller operation until they are removed.
  bool _cancelAllPending = false;
  final Set<String> _cancelDevicesPending = <String>{};
  // The last cold-start restore failed, so the signed-in identity is unknown.
  bool _restoreUnresolved = false;
  bool _used = false;
  bool _disposed = false;
  int _generation = 0;
  int _observationGeneration = 0;

  /// Composes existing SDK identity actions. Clearing (logout, local wipe, a
  /// different app/user/backend) removes the stored settings and every
  /// scheduled or delivered TAG alert.
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
      // Drop buffered events of the previous identity. Nothing is published
      // here: watchers get the reloaded value after the action, so a same-user
      // session refresh never flashes defaults.
      _observationGeneration++;
      _loaded = false;
      _devices = {};
      _cycles = {};
      _streaks.clear();
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
      // A restore that threw (keychain locked, transient storage error) tells
      // us nothing about who is signed in. It must not look like "signed out":
      // keep the data and let the owner-scope check in `_load` decide once an
      // identity is known. Only a restore that completed with no session, or
      // an explicit logout, clears.
      final restoreFailed =
          actionError != null &&
          restoreExisting &&
          previous == null &&
          next == null;
      final adoptsExisting =
          previous == null && (restoreExisting || _restoreUnresolved);
      _pendingClear |=
          clearData ||
          canonicalChanged ||
          (previousScope != scope && !adoptsExisting) ||
          (next == null && !restoreFailed);
      _restoreUnresolved = restoreFailed;
      _identity = next;
      _scope = scope;
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
      if (_watchers.isNotEmpty) {
        try {
          await _prepare(generation);
          await _load(generation);
          _publishAll();
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

  /// Unpair cleanup: cancels the device's scheduled and delivered alerts and
  /// forgets its settings.
  Future<void> onDeviceUnpaired(String deviceKey) {
    final generation = _generation;
    return _serialize(() async {
      _checkGeneration(generation);
      Object? cancelError;
      StackTrace? cancelStack;
      try {
        await _notify(() => notifier.cancelAllForDevice(deviceKey));
        _cancelDevicesPending.remove(deviceKey);
      } catch (error, stack) {
        _cancelDevicesPending.add(deviceKey);
        cancelError = error;
        cancelStack = stack;
      }
      try {
        await _prepare(generation, retryCleanup: false);
        await _load(generation);
        _streaks.remove(deviceKey);
        if (_devices.containsKey(deviceKey) || _cycles.containsKey(deviceKey)) {
          final nextDevices = Map<String, TagAlertSettings>.of(_devices)
            ..remove(deviceKey);
          final nextCycles = Map<String, TagBatteryCycle>.of(_cycles)
            ..remove(deviceKey);
          await _write(nextDevices, nextCycles);
          _checkGeneration(generation);
          _devices = nextDevices;
          _cycles = nextCycles;
          _publishAll();
        }
      } finally {
        if (cancelError != null) {
          _publishError(cancelError, cancelStack!);
        }
      }
    });
  }

  /// Moves a device's state to its new key after a device migration changed
  /// the TAG's identity. Settings move unless the new key already has its own
  /// (those win). Alerts of the old key are removed; the policies re-create
  /// whatever applies under the new key.
  Future<void> rekeyDevice(String fromKey, String toKey) {
    if (fromKey.trim().isEmpty || toKey.trim().isEmpty || fromKey == toKey) {
      return Future<void>.value();
    }
    final generation = _generation;
    return _serialize(() async {
      _checkGeneration(generation);
      Object? cancelError;
      StackTrace? cancelStack;
      try {
        await _notify(() => notifier.cancelAllForDevice(fromKey));
        _cancelDevicesPending.remove(fromKey);
      } catch (error, stack) {
        _cancelDevicesPending.add(fromKey);
        cancelError = error;
        cancelStack = stack;
      }
      try {
        await _prepare(generation, retryCleanup: false);
        if (_identity == null) return;
        await _load(generation);
        _streaks.remove(fromKey);
        final moved = _devices[fromKey];
        final movedCycle = _cycles[fromKey];
        if (moved == null && movedCycle == null) return;
        final nextDevices = Map<String, TagAlertSettings>.of(_devices)
          ..remove(fromKey);
        if (moved != null) {
          nextDevices.putIfAbsent(
            toKey,
            () => TagAlertSettings(
              deviceId: toKey,
              batteryAlerts: moved.batteryAlerts,
              disconnectAfter: moved.disconnectAfter,
            ),
          );
        }
        final nextCycles = Map<String, TagBatteryCycle>.of(_cycles)
          ..remove(fromKey);
        if (movedCycle != null) {
          // Union of both: a threshold that already alerted for either
          // identity must not alert again for the same physical TAG.
          final existing = nextCycles[toKey];
          nextCycles[toKey] = TagBatteryCycle(
            firedBelow30:
                movedCycle.firedBelow30 || (existing?.firedBelow30 ?? false),
            firedBelow10:
                movedCycle.firedBelow10 || (existing?.firedBelow10 ?? false),
          );
        }
        await _write(nextDevices, nextCycles);
        _checkGeneration(generation);
        _devices = nextDevices;
        _cycles = nextCycles;
        _publishAll();
      } finally {
        if (cancelError != null) {
          _publishError(cancelError, cancelStack!);
        }
      }
    });
  }

  @override
  Future<TagAlertSettings> getTagAlertSettings(String deviceId) {
    _validateKey(deviceId);
    final generation = _generation;
    return _serialize(() async {
      await _prepare(generation);
      await _load(generation);
      return _settingsFor(deviceId);
    });
  }

  @override
  Stream<TagAlertSettings> watchTagAlertSettings(String deviceId) {
    _validateKey(deviceId);
    late final _Watcher watcher;
    var cancelled = false;
    final controller = StreamController<_Observation>(
      onCancel: () {
        cancelled = true;
        _watchers.remove(watcher);
      },
    );
    watcher = _Watcher(deviceId, controller);
    controller.onListen = () {
      final generation = _generation;
      final observationGeneration = _observationGeneration;
      unawaited(
        _serialize(() async {
          try {
            await _prepare(generation);
            await _load(generation);
            if (cancelled) return;
            _watchers.add(watcher);
            final failure = _restoreFailure;
            if (failure != null) {
              controller.add(
                _Observation.error(
                  _observationGeneration,
                  failure.error,
                  failure.stack,
                ),
              );
            }
            controller.add(
              _Observation.data(_observationGeneration, _settingsFor(deviceId)),
            );
          } catch (error, stack) {
            if (cancelled) return;
            if (_disposed) {
              unawaited(controller.close());
              return;
            }
            _watchers.add(watcher);
            controller.add(
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
    };
    return controller.stream
        .where(
          (event) => !_disposed && event.generation == _observationGeneration,
        )
        .transform(
          StreamTransformer<_Observation, TagAlertSettings>.fromHandlers(
            handleData: (event, sink) {
              if (event.error != null) {
                sink.addError(event.error!, event.stack);
              } else {
                sink.add(event.settings!);
              }
            },
          ),
        );
  }

  @override
  Future<void> updateTagAlertSettings(TagAlertSettings settings) {
    final generation = _generation;
    return _serialize(() async {
      await _prepare(generation);
      if (_identity == null) {
        throw const TagAlertsException(
          'E_TAG_ALERTS_SESSION_REQUIRED',
          'An SDK session is required to store TAG alert settings.',
        );
      }
      await _load(generation);
      final next = Map<String, TagAlertSettings>.of(_devices)
        ..[settings.deviceId] = settings;
      await _write(next, _cycles);
      _checkGeneration(generation);
      _devices = next;
      _publishAll();
      // Hygiene only: a disabled feature must not leave an alert behind. The
      // policies (future blocks) own every other scheduling decision.
      await _cancelDisabled(settings);
    });
  }

  /// Feeds one live battery reading of [deviceKey] to the low-battery policy.
  ///
  /// [epoch] identifies the connection the reading arrived on; confirmation
  /// never spans epochs. Readings are ignored without a session. The cycle is
  /// persisted only when it changes. A notifier failure is reported to the
  /// settings streams and never thrown, so BLE handling is never affected.
  Future<void> onBatteryReading({
    required String deviceKey,
    required TagBatteryBand band,
    required String sourceKey,
    required int epoch,
    String? deviceAlias,
  }) {
    final generation = _generation;
    return _serialize(() async {
      await _prepare(generation);
      if (_identity == null) return;
      await _load(generation);
      final cycle = _cycles[deviceKey] ?? TagBatteryCycle.none;
      final decision = TagBatteryAlertPolicy.evaluate(
        band: band,
        sourceKey: sourceKey,
        epoch: epoch,
        cycle: cycle,
        streak: _streaks[deviceKey],
        alertsEnabled: _settingsFor(deviceKey).batteryAlerts,
      );
      _streaks[deviceKey] = decision.streak;
      if (decision.cycle != cycle) {
        final nextCycles = Map<String, TagBatteryCycle>.of(_cycles);
        if (decision.cycle.isNone) {
          nextCycles.remove(deviceKey);
        } else {
          nextCycles[deviceKey] = decision.cycle;
        }
        // Persist before notifying: if this fails nothing was shown and the
        // next confirmed reading decides again.
        await _write(_devices, nextCycles);
        _checkGeneration(generation);
        _cycles = nextCycles;
      }
      final threshold = decision.threshold;
      try {
        if (threshold != null) {
          await notifier.show(
            TagAlert(
              kind: TagAlertKind.batteryLow,
              deviceId: deviceKey,
              deviceAlias: deviceAlias,
              batteryThreshold: threshold,
            ),
          );
        } else if (decision.clearDeliveredAlert) {
          await notifier.cancel(deviceKey, TagAlertKind.batteryLow);
        }
      } catch (error, stack) {
        _publishError(error, stack);
      }
    });
  }

  @override
  Future<TagAlertPermissionState> getTagAlertPermissionState() =>
      permissions.state();

  @override
  Future<TagAlertPermissionState> requestTagAlertPermission() =>
      permissions.request();

  Future<void> _cancelDisabled(TagAlertSettings settings) async {
    try {
      if (!settings.batteryAlerts) {
        await _notify(
          () => notifier.cancel(settings.deviceId, TagAlertKind.batteryLow),
        );
      }
      if (settings.disconnectAfter == null) {
        await _notify(
          () =>
              notifier.cancel(settings.deviceId, TagAlertKind.tagDisconnected),
        );
      }
    } catch (error, stack) {
      _publishError(error, stack);
    }
  }

  TagAlertSettings _settingsFor(String deviceId) =>
      _devices[deviceId] ?? TagAlertSettings(deviceId: deviceId);

  Future<void> _prepare(int generation, {bool retryCleanup = true}) async {
    _checkGeneration(generation);
    _used = true;
    if (!_tryAcquire()) throw _unavailable;
    if (retryCleanup) {
      await _retryCleanup();
      _checkGeneration(generation);
    }
    if (_pendingClear) {
      await _clear();
      _checkGeneration(generation);
    }
  }

  Future<T> _bounded<T>(Future<T> operation) =>
      operation.timeout(notifierTimeout);

  Future<void> _notify(Future<void> Function() operation) =>
      _bounded(operation());

  /// Retries notifier cleanup that previously failed. Failures are surfaced to
  /// watchers and the cleanup stays pending.
  Future<void> _retryCleanup() async {
    if (_cancelAllPending) {
      try {
        await _notify(notifier.cancelAll);
        _cancelAllPending = false;
        _cancelDevicesPending.clear();
      } catch (error, stack) {
        _publishError(error, stack);
        return;
      }
    }
    for (final key in _cancelDevicesPending.toList()) {
      try {
        await _notify(() => notifier.cancelAllForDevice(key));
        _cancelDevicesPending.remove(key);
      } catch (error, stack) {
        _publishError(error, stack);
      }
    }
  }

  /// A corrupt or unsupported store yields defaults and one explicit error on
  /// the watch streams; it never throws into callers.
  Future<void> _load(int generation) async {
    if (_loaded) return;
    if (_identity == null) {
      _devices = {};
      _cycles = {};
      _loaded = true;
      return;
    }
    TagAlertRecord? record;
    Object? restoreError;
    StackTrace? restoreStack;
    try {
      final raw = await store.read();
      if (raw != null) record = TagAlertRecord.decode(raw);
    } catch (error, stack) {
      restoreError = error;
      restoreStack = stack;
    }
    _checkGeneration(generation);
    if (restoreError != null) {
      _devices = {};
      _cycles = {};
      _loaded = true;
      const failure = TagAlertsException(
        'E_TAG_ALERTS_RESTORE_FAILED',
        'TAG alert settings are unreadable or unsupported; defaults apply.',
      );
      _restoreFailure = _Failure(failure, restoreStack!);
      _publishError(failure, restoreStack);
      return;
    }
    if (record != null && record.ownerScope != _scope) {
      _pendingClear = true;
      await _clear();
      _checkGeneration(generation);
      record = null;
    }
    _restoreFailure = null;
    _devices = record == null ? {} : Map.of(record.devices);
    _cycles = record == null ? {} : Map.of(record.cycles);
    _loaded = true;
  }

  Future<void> _write(
    Map<String, TagAlertSettings> devices,
    Map<String, TagBatteryCycle> cycles,
  ) async {
    final record = TagAlertRecord(
      ownerScope: _scope!,
      devices: Map<String, TagAlertSettings>.unmodifiable(devices),
      cycles: Map<String, TagBatteryCycle>.unmodifiable(cycles),
    );
    await _persist(record.encode());
    _restoreFailure = null;
  }

  Future<void> _clear() async {
    // Privacy first: alerts show the TAG alias, so drop them before the data.
    Object? cancelError;
    StackTrace? cancelStack;
    try {
      await _notify(notifier.cancelAll);
      _cancelAllPending = false;
      _cancelDevicesPending.clear();
    } catch (error, stack) {
      _cancelAllPending = true;
      cancelError = error;
      cancelStack = stack;
    }
    await _persist(null);
    _pendingClear = false;
    _devices = {};
    _cycles = {};
    _streaks.clear();
    _loaded = false;
    _restoreFailure = null;
    if (cancelError != null) {
      _publishError(cancelError, cancelStack!);
    }
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
    throw const TagAlertsException(
      'E_TAG_ALERTS_PERSISTENCE_FAILED',
      'TAG alert persistence could not be confirmed. Retry.',
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

  void _publishAll() {
    for (final watcher in _watchers.toList()) {
      watcher.controller.add(
        _Observation.data(
          _observationGeneration,
          _settingsFor(watcher.deviceId),
        ),
      );
    }
  }

  void _publishError(Object error, StackTrace stack) {
    for (final watcher in _watchers.toList()) {
      watcher.controller.add(
        _Observation.error(_observationGeneration, error, stack),
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

  static void _validateKey(String deviceId) {
    if (deviceId.trim().isEmpty) {
      throw ArgumentError.value(deviceId, 'deviceId', 'must not be empty');
    }
  }

  /// Releases the writer lease and observers. It does not wipe persisted
  /// settings or cancel scheduled alerts: those are user preferences and OS
  /// state that must outlive an SDK instance. A clear already owed (logout in
  /// flight) is still completed.
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
      for (final watcher in _watchers.toList()) {
        unawaited(watcher.controller.close());
      }
      _watchers.clear();
    }
  }

  // Matches logical identity semantics of the other optional capabilities.
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

  static const _unavailable = TagAlertsException(
    'E_TAG_ALERTS_UNAVAILABLE',
    'TAG alerts were disposed, changed identity, or have another writer.',
  );
}

final class _Failure {
  const _Failure(this.error, this.stack);

  final Object error;
  final StackTrace stack;
}

final class _Watcher {
  _Watcher(this.deviceId, this.controller);

  final String deviceId;
  final StreamController<_Observation> controller;
}

/// Tagged errors share the same paused-subscriber identity fence as values.
final class _Observation {
  const _Observation.data(this.generation, this.settings)
    : error = null,
      stack = null;
  const _Observation.error(this.generation, this.error, this.stack)
    : settings = null;
  final int generation;
  final TagAlertSettings? settings;
  final Object? error;
  final StackTrace? stack;
}
