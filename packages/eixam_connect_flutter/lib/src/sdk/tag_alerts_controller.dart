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
    DateTime Function()? clock,
    void Function(String message)? log,
  }) : _clock = clock ?? DateTime.now,
       _log = log;

  /// Bound for every notifier call made inside the serialized tail, so a hung
  /// platform call can never hold logout, unpair or settings changes.
  static const Duration defaultNotifierTimeout = Duration(seconds: 5);
  final Duration notifierTimeout;
  final DateTime Function() _clock;
  final void Function(String message)? _log;

  /// How long a notification-permission check is reused by the disconnect
  /// lease, so frequent pushes never poll the OS.
  static const Duration permissionCacheTtl = Duration(seconds: 60);

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
  // Disconnect lease: per-TAG policy state (in memory), the newest link
  // snapshot per TAG (older ones are superseded, never queued), and the keys
  // that already have an evaluation waiting in the serialized tail.
  final Map<String, TagLeaseState> _leases = <String, TagLeaseState>{};
  final Map<String, TagLinkSnapshot> _latestSnapshots =
      <String, TagLinkSnapshot>{};
  final Set<String> _leaseQueued = <String>{};
  final StreamController<TagAlertRekey> _rekeys =
      StreamController<TagAlertRekey>.broadcast();
  bool? _permissionAllowedCache;
  DateTime? _permissionCheckedAt;
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
      _leases.clear();
      _latestSnapshots.clear();
      _leaseQueued.clear();
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
    _leases.remove(deviceKey);
    _latestSnapshots.remove(deviceKey);
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
    _leases.remove(fromKey);
    _latestSnapshots.remove(fromKey);
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
        // The old key's alerts are gone; whoever owns the lease re-arms it
        // under the new key.
        if (!_rekeys.isClosed) {
          _rekeys.add(TagAlertRekey(fromKey, toKey));
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
      final previous = _devices[settings.deviceId];
      final next = Map<String, TagAlertSettings>.of(_devices)
        ..[settings.deviceId] = settings;
      await _write(next, _cycles);
      _checkGeneration(generation);
      _devices = next;
      _publishAll();
      if (previous?.disconnectAfter != settings.disconnectAfter) {
        // A new delay re-arms the lease from scratch under the new value.
        _leases.remove(settings.deviceId);
      }
      // Hygiene only: a disabled feature must not leave an alert behind. The
      // policies (future blocks) own every other scheduling decision.
      await _cancelDisabled(settings);
      _reevaluateLease(settings.deviceId);
    });
  }

  /// Feeds one live battery reading of [deviceKey] to the low-battery policy.
  ///
  /// [epoch] identifies the connection the reading arrived on; confirmation
  /// never spans epochs. Readings are ignored without a session.
  ///
  /// Delivery is at-least-once: the alert is shown first and the "already
  /// alerted" mark is persisted afterwards, so an alert that could not be shown
  /// (notifier error or timeout) is retried by the next confirmed reading, and a
  /// failed write after a successful show may repeat the alert at worst. While
  /// notifications cannot be shown (permission not granted) the threshold is
  /// not marked, so granting permission later while still low alerts on the
  /// next live reading. Notifier failures are reported to the settings streams,
  /// never thrown, so BLE handling is never affected.
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
      final streak = _streaks[deviceKey];
      final enabled = _settingsFor(deviceKey).batteryAlerts;
      var decision = TagBatteryAlertPolicy.evaluate(
        band: band,
        sourceKey: sourceKey,
        epoch: epoch,
        cycle: cycle,
        streak: streak,
        alertsEnabled: enabled,
      );
      if (decision.threshold != null && !await _canDeliverNotifications()) {
        // Track and rearm, but do not consume the alert.
        decision = TagBatteryAlertPolicy.evaluate(
          band: band,
          sourceKey: sourceKey,
          epoch: epoch,
          cycle: cycle,
          streak: streak,
          alertsEnabled: false,
        );
      }
      _streaks[deviceKey] = decision.streak;
      final threshold = decision.threshold;
      if (threshold != null) {
        try {
          await _notify(
            () => notifier.show(
              TagAlert(
                kind: TagAlertKind.batteryLow,
                deviceId: deviceKey,
                deviceAlias: deviceAlias,
                batteryThreshold: threshold,
              ),
            ),
          );
        } catch (error, stack) {
          // Not shown, so not marked: the next confirmed reading retries.
          _publishError(error, stack);
          return;
        }
      }
      _checkGeneration(generation);
      if (decision.cycle != cycle) {
        final nextCycles = Map<String, TagBatteryCycle>.of(_cycles);
        if (decision.cycle.isNone) {
          nextCycles.remove(deviceKey);
        } else {
          nextCycles[deviceKey] = decision.cycle;
        }
        await _write(_devices, nextCycles);
        _checkGeneration(generation);
        _cycles = nextCycles;
      }
      if (threshold == null && decision.clearDeliveredAlert) {
        try {
          await _notify(
            () => notifier.cancel(deviceKey, TagAlertKind.batteryLow),
          );
        } catch (error, stack) {
          _publishError(error, stack);
        }
      }
    });
  }

  /// Whether the OS would show a notification right now. Only a state that
  /// clearly blocks delivery (denied, permanently denied, not asked yet)
  /// counts; granted and unsupported platforms, or a failing check, allow it.
  Future<bool> _canDeliverNotifications() async {
    try {
      final state = await _bounded(permissions.state());
      switch (state) {
        case TagAlertPermissionState.denied:
        case TagAlertPermissionState.permanentlyDenied:
        case TagAlertPermissionState.notDetermined:
          return false;
        case TagAlertPermissionState.granted:
        case TagAlertPermissionState.unsupported:
          return true;
      }
    } catch (_) {
      return true;
    }
  }

  @override
  Future<TagAlertPermissionState> getTagAlertPermissionState() =>
      permissions.state();

  @override
  Future<TagAlertPermissionState> requestTagAlertPermission() async {
    final state = await permissions.request();
    _permissionCheckedAt = null;
    for (final key in _latestSnapshots.keys.toList()) {
      _reevaluateLease(key);
    }
    return state;
  }

  /// Feeds the newest link state of a TAG to the disconnect policy.
  ///
  /// Snapshots are state-based and the newest replaces any older one that has
  /// not run yet, so a burst of ticks costs one evaluation. The policy
  /// throttles platform pushes, and every notifier call runs inside the
  /// serialized tail with the same timeout and cleanup retry as the rest.
  /// Failures are reported to the settings streams, never thrown.
  Future<void> onLinkSnapshot(TagLinkSnapshot snapshot) {
    final key = snapshot.deviceKey;
    _latestSnapshots[key] = snapshot;
    if (!_leaseQueued.add(key)) return Future<void>.value();
    final generation = _generation;
    return _serialize(() async {
      _leaseQueued.remove(key);
      final latest = _latestSnapshots[key];
      if (latest == null) return;
      await _applyLease(generation, latest);
    });
  }

  /// Fires when [rekeyDevice] moved a TAG's state after a device migration.
  Stream<TagAlertRekey> get rekeyEvents => _rekeys.stream;

  void _reevaluateLease(String key) {
    final latest = _latestSnapshots[key];
    if (latest == null) return;
    unawaited(onLinkSnapshot(latest).catchError((Object _) {}));
  }

  Future<void> _applyLease(int generation, TagLinkSnapshot snapshot) async {
    // A drop observed in the background may have only seconds (the iOS wake
    // window) to schedule its alert. That path never waits on the OS for a
    // permission answer or on cleanup retries.
    final backgroundDrop = !snapshot.connected && snapshot.backgrounded;
    await _prepare(generation, retryCleanup: !backgroundDrop);
    if (_identity == null) return;
    await _load(generation);
    final key = snapshot.deviceKey;
    final after = _settingsFor(key).disconnectAfter;
    final bool allowed;
    if (after == null) {
      allowed = true;
    } else if (backgroundDrop) {
      // Last known state, however old; unknown counts as allowed. Scheduling
      // while permission is actually missing is harmless: the OS drops it.
      allowed = _permissionAllowedCache ?? true;
    } else {
      allowed = await _notificationsAllowed();
    }
    final decision = TagDisconnectAlertPolicy.evaluate(
      snapshot: snapshot,
      state: _leases[key] ?? TagLeaseState.none,
      disconnectAfter: after,
      permissionAllowed: allowed,
    );
    _checkGeneration(generation);
    final previous = _leases[key] ?? TagLeaseState.none;
    if (decision.actions.isNotEmpty || decision.state.phase != previous.phase) {
      _leaseLog(
        'snapshot ${_logKey(key)} connected=${snapshot.connected} '
        'cause=${snapshot.cause.name} background=${snapshot.backgroundDisarm} '
        'sos=${snapshot.sosActive} phase=${previous.phase.name}'
        '->${decision.state.phase.name} actions=${decision.actions.length}',
      );
    }
    var applied = true;
    for (final action in decision.actions) {
      try {
        await _runLeaseAction(snapshot, action);
      } catch (error, stack) {
        // Keep the previous state: the next snapshot retries the same step.
        _leaseLog('action_failed ${_logKey(key)} error=${error.runtimeType}');
        _publishError(error, stack);
        applied = false;
        break;
      }
    }
    if (applied) _leases[key] = decision.state;
    if (backgroundDrop && after != null) {
      // Only now, with the alert already scheduled: bring the permission
      // answer up to date without blocking, and re-evaluate if it changed.
      _refreshPermissionInBackground(key);
      await _retryCleanup();
    }
  }

  void _refreshPermissionInBackground(String key) {
    final checkedAt = _permissionCheckedAt;
    if (_permissionAllowedCache != null &&
        checkedAt != null &&
        _clock().difference(checkedAt) < permissionCacheTtl) {
      return;
    }
    unawaited(() async {
      final allowed = await _canDeliverNotifications();
      final changed = allowed != _permissionAllowedCache;
      _permissionAllowedCache = allowed;
      _permissionCheckedAt = _clock();
      if (changed && !_disposed) _reevaluateLease(key);
    }());
  }

  Future<void> _runLeaseAction(
    TagLinkSnapshot snapshot,
    TagDisconnectAction action,
  ) async {
    final key = snapshot.deviceKey;
    switch (action) {
      case TagDisconnectNoAction():
        return;
      case TagDisconnectCancel(:final kinds):
        _leaseLog(
          'cancel ${_logKey(key)} kinds=${kinds.map((k) => k.name).join(',')}',
        );
        for (final kind in kinds) {
          await _notify(() => notifier.cancel(key, kind));
        }
      case TagDisconnectSchedule():
        _leaseLog(
          'schedule ${_logKey(key)} kind=${action.kind.name} '
          // Not named `...At`: the diagnostics redactor hides those values.
          'fire=${action.at.toUtc().toIso8601String()} '
          'in=${action.at.difference(_clock()).inSeconds}s '
          'clearDelivered=${action.clearDelivered}',
        );
        if (action.clearDelivered) {
          _leaseLog(
            'cancel ${_logKey(key)} kinds=${action.kind.name} '
            'reason=clear_delivered',
          );
          await _notify(() => notifier.cancel(key, action.kind));
        }
        final alert = action.kind == TagAlertKind.bluetoothOff
            ? TagAlert(
                kind: TagAlertKind.bluetoothOff,
                deviceId: key,
                deviceAlias: snapshot.deviceAlias,
              )
            : TagAlert(
                kind: TagAlertKind.tagDisconnected,
                deviceId: key,
                deviceAlias: snapshot.deviceAlias,
                elapsed: action.elapsed,
                lastTagPosition: snapshot.lastTagPosition,
              );
        await _notify(() => notifier.schedule(alert, action.at));
        if (!snapshot.connected) {
          _leaseLog(
            'scheduled ${_logKey(key)} kind=${action.kind.name} '
            'dropToScheduleMs='
            '${_clock().difference(snapshot.observedAt).inMilliseconds}',
          );
        }
    }
  }

  void _leaseLog(String message) => _log?.call(message);

  /// A short stable digest instead of the device identifier.
  static String _logKey(String key) =>
      'key#${sha256.convert(utf8.encode(key)).toString().substring(0, 6)}';

  /// Cached for [permissionCacheTtl]. Only an explicit blocking state (denied,
  /// permanently denied, not asked yet) keeps the lease disarmed.
  Future<bool> _notificationsAllowed() async {
    final now = _clock();
    final checkedAt = _permissionCheckedAt;
    final cached = _permissionAllowedCache;
    if (checkedAt != null &&
        cached != null &&
        now.difference(checkedAt) < permissionCacheTtl) {
      return cached;
    }
    final allowed = await _canDeliverNotifications();
    _permissionAllowedCache = allowed;
    _permissionCheckedAt = now;
    return allowed;
  }

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
    _leases.clear();
    _latestSnapshots.clear();
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
      unawaited(_rekeys.close());
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

/// A TAG's alert state moved from [from] to [to] (device migration).
final class TagAlertRekey {
  const TagAlertRekey(this.from, this.to);

  final String from;
  final String to;
}
