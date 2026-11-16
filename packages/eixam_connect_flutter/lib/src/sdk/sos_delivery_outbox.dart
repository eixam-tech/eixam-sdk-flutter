import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/datasources_local/shared_prefs_sdk_store.dart';
import '../diagnostics/sdk_release_log.dart';

/// Kind of SOS action delivered to the backend over MQTT.
enum SosOutboxActionKind { trigger, cancel }

/// Result of reading the backend after a publish.
enum SosOutboxBackendCheck {
  /// The backend shows the action took effect.
  confirmed,

  /// The backend does not (yet) show the action.
  notConfirmed,

  /// The backend could not be read (offline, error).
  unknown,
}

/// One persisted SOS action. [payload] is the opaque, already validated
/// request the publisher needs to repeat the exact same message (same
/// incident id / cycle key on every attempt, so the backend upserts the same
/// open incident instead of creating another).
@immutable
class SosOutboxAction {
  const SosOutboxAction({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.cycleKey,
    this.payload = const <String, dynamic>{},
    this.attempts = 0,
    this.published = false,
    this.lastAttemptAt,
    DateTime? observedAt,
    this.scope,
  }) : observedAt = observedAt ?? createdAt;

  final String id;
  final SosOutboxActionKind kind;
  final DateTime createdAt;
  final String? cycleKey;
  final Map<String, dynamic> payload;
  final int attempts;

  /// The broker acknowledged (PUBACK) at least one attempt.
  final bool published;
  final DateTime? lastAttemptAt;

  /// When the user/TAG action happened (a TAG cancel can be handed over
  /// later than it was observed). Orders cancels against triggers.
  final DateTime observedAt;

  /// Account scope the action belongs to; never delivered for another one.
  final String? scope;

  SosOutboxAction copyWith({
    int? attempts,
    bool? published,
    DateTime? lastAttemptAt,
  }) {
    return SosOutboxAction(
      id: id,
      kind: kind,
      createdAt: createdAt,
      cycleKey: cycleKey,
      payload: payload,
      attempts: attempts ?? this.attempts,
      published: published ?? this.published,
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      observedAt: observedAt,
      scope: scope,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (cycleKey != null) 'cycleKey': cycleKey,
    'payload': payload,
    'attempts': attempts,
    'published': published,
    if (lastAttemptAt != null)
      'lastAttemptAt': lastAttemptAt!.toUtc().toIso8601String(),
    'observedAt': observedAt.toUtc().toIso8601String(),
    if (scope != null) 'scope': scope,
  };

  static SosOutboxAction? tryParse(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final id = raw['id'];
    final kind = SosOutboxActionKind.values
        .where((value) => value.name == raw['kind'])
        .firstOrNull;
    final createdAt = DateTime.tryParse('${raw['createdAt']}');
    if (id is! String || id.isEmpty || kind == null || createdAt == null) {
      return null;
    }
    final payload = raw['payload'];
    return SosOutboxAction(
      id: id,
      kind: kind,
      createdAt: createdAt.toUtc(),
      cycleKey: raw['cycleKey'] is String ? raw['cycleKey'] as String : null,
      payload: payload is Map
          ? Map<String, dynamic>.from(payload)
          : const <String, dynamic>{},
      attempts: raw['attempts'] is int ? raw['attempts'] as int : 0,
      published: raw['published'] == true,
      lastAttemptAt: DateTime.tryParse('${raw['lastAttemptAt']}')?.toUtc(),
      observedAt: DateTime.tryParse('${raw['observedAt']}')?.toUtc(),
      scope: raw['scope'] is String ? raw['scope'] as String : null,
    );
  }
}

/// Public-facing delivery status of the head action.
@immutable
class SosOutboxStatus {
  const SosOutboxStatus({
    required this.pendingTrigger,
    required this.pendingCancel,
    required this.retrying,
    this.headAttempts = 0,
  });

  static const SosOutboxStatus empty = SosOutboxStatus(
    pendingTrigger: false,
    pendingCancel: false,
    retrying: false,
  );

  /// A trigger is queued and not yet confirmed by the backend.
  final bool pendingTrigger;

  /// A cancel is queued and not yet confirmed by the backend.
  final bool pendingCancel;

  /// The head action was not confirmed within the confirmation window and is
  /// being retried ("Not sent yet, retrying").
  final bool retrying;
  final int headAttempts;

  bool get isEmpty => !pendingTrigger && !pendingCancel;

  @override
  bool operator ==(Object other) =>
      other is SosOutboxStatus &&
      other.pendingTrigger == pendingTrigger &&
      other.pendingCancel == pendingCancel &&
      other.retrying == retrying &&
      other.headAttempts == headAttempts;

  @override
  int get hashCode =>
      Object.hash(pendingTrigger, pendingCancel, retrying, headAttempts);
}

/// Thrown by a publisher when an action must never be delivered (e.g. it
/// belongs to another account). The outbox drops it instead of retrying.
class SosOutboxDropAction implements Exception {
  const SosOutboxDropAction(this.reason);

  final String reason;

  @override
  String toString() => 'SosOutboxDropAction($reason)';
}

typedef SosOutboxPublisher = Future<void> Function(SosOutboxAction action);
typedef SosOutboxBackendReader =
    Future<SosOutboxBackendCheck> Function(SosOutboxAction action);

/// Durable, ordered delivery queue for SOS trigger and cancel over MQTT.
///
/// Rules:
/// - every action is persisted before its first attempt and survives process
///   restarts;
/// - actions are delivered strictly in order (head of line);
/// - an action is done only when the backend confirms it, either through
///   [confirm] (realtime `processed` / `cancelled` event) or a backend read;
///   PUBACK alone is not confirmation;
/// - failures are retried with bounded backoff, indefinitely until confirmed
///   or expired; [kick] retries immediately (connectivity regained, app
///   resumed, native SOS event);
/// - a cancel supersedes every trigger queued before it: the user cancelled,
///   so a trigger must never be replayed afterwards (the backend would open a
///   new incident);
/// - a duplicate trigger for the same cycle is not queued twice.
class SosDeliveryOutbox {
  SosDeliveryOutbox({
    required SosOutboxPublisher publish,
    required SosOutboxBackendReader readBackend,
    SharedPrefsSdkStore? store,
    DateTime Function()? clock,
    this.confirmationWindow = const Duration(seconds: 6),
    this.retryingAfter = const Duration(seconds: 10),
    List<Duration>? backoff,
    this.triggerMaxAge = const Duration(hours: 6),
    this.cancelMaxAge = const Duration(hours: 24),
    void Function(SosOutboxAction action, String source)? onConfirmed,
    void Function(SosOutboxAction action)? onExpired,
  }) : _onExpired = onExpired,
       backoff = (backoff == null || backoff.isEmpty)
           ? defaultBackoff
           : List<Duration>.unmodifiable(backoff),
       _onConfirmed = onConfirmed,
       _publish = publish,
       _readBackend = readBackend,
       _store = store,
       _clock = clock ?? DateTime.now;

  static const String storeKey = SharedPrefsSdkStore.sosDeliveryOutboxKey;

  /// Bounded backoff: 1, 2, 4, 8, 15, then every 30 s until confirmed.
  static const List<Duration> defaultBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];
  final void Function(SosOutboxAction action, String source)? _onConfirmed;
  final void Function(SosOutboxAction action)? _onExpired;

  /// Newest trigger the broker acknowledged. A cancel observed before it is
  /// stale: delivering it would close that newer SOS (user-scoped cancel).
  DateTime? _lastPublishedTriggerAt;

  final SosOutboxPublisher _publish;
  final SosOutboxBackendReader _readBackend;
  final SharedPrefsSdkStore? _store;
  final DateTime Function() _clock;

  /// After a PUBACK, how long to wait for the realtime confirmation before
  /// reading the backend.
  final Duration confirmationWindow;

  /// Unconfirmed for longer than this → status `retrying`.
  final Duration retryingAfter;
  final List<Duration> backoff;
  final Duration triggerMaxAge;
  final Duration cancelMaxAge;

  final List<SosOutboxAction> _queue = <SosOutboxAction>[];
  final StreamController<SosOutboxStatus> _statusController =
      StreamController<SosOutboxStatus>.broadcast();
  final Map<String, Completer<bool>> _waiters = <String, Completer<bool>>{};
  final Map<String, Completer<void>> _attemptWaiters =
      <String, Completer<void>>{};
  SosOutboxStatus _status = SosOutboxStatus.empty;
  Completer<void>? _wake;
  Completer<void>? _confirmSignal;
  bool _running = false;
  bool _disposed = false;
  bool _paused = false;
  int _sequence = 0;
  Timer? _retryingTimer;

  /// Read from the queue itself (status can lag behind a pending persist).
  bool get hasPendingTrigger =>
      _queue.any((action) => action.kind == SosOutboxActionKind.trigger);

  List<SosOutboxAction> get pending =>
      List<SosOutboxAction>.unmodifiable(_queue);
  SosOutboxStatus get status => _status;
  Stream<SosOutboxStatus> watchStatus() => _statusController.stream;

  /// Loads persisted actions (process restart) and resumes delivery.
  Future<void> restore() async {
    final store = _store;
    if (store == null) {
      return;
    }
    final json = await store.readJson(storeKey);
    final lastPublished = DateTime.tryParse(
      '${json?['lastPublishedTriggerAt']}',
    )?.toUtc();
    if (lastPublished != null &&
        (_lastPublishedTriggerAt == null ||
            lastPublished.isAfter(_lastPublishedTriggerAt!))) {
      _lastPublishedTriggerAt = lastPublished;
    }
    final raw = json?['actions'];
    if (raw is! List) {
      return;
    }
    final restored = raw
        .map(SosOutboxAction.tryParse)
        .whereType<SosOutboxAction>()
        .where((action) => _queue.every((queued) => queued.id != action.id))
        .toList();
    if (restored.isEmpty) {
      return;
    }
    _queue.insertAll(0, restored);
    sdkReleaseLog(
      'SOS_OUTBOX_RESTORED count=${restored.length} '
      'kinds=${restored.map((action) => action.kind.name).join(",")}',
    );
    _publishStatus();
    kick('restored');
  }

  /// Persists a trigger and starts delivery. A trigger for a cycle already
  /// queued is not duplicated.
  Future<SosOutboxAction> enqueueTrigger({
    required String? cycleKey,
    required Map<String, dynamic> payload,
    String? scope,
  }) async {
    // A cancel the broker already acknowledged went on the wire before this
    // trigger can: it must not block a new SOS while awaiting confirmation.
    final retired = _queue
        .where(
          (action) =>
              action.kind == SosOutboxActionKind.cancel && action.published,
        )
        .toList();
    for (final cancel in retired) {
      _queue.remove(cancel);
      _completeWaiter(cancel.id, false);
      sdkReleaseLog(
        'SOS_OUTBOX_CANCEL_RETIRED reason=newer_trigger_after_puback',
      );
    }
    final normalizedKey = cycleKey?.trim();
    if (normalizedKey != null && normalizedKey.isNotEmpty) {
      final existing = _queue.where(
        (action) =>
            action.kind == SosOutboxActionKind.trigger &&
            action.cycleKey == normalizedKey,
      );
      if (existing.isNotEmpty) {
        sdkReleaseLog('SOS_OUTBOX_TRIGGER_DEDUPED reason=same_cycle_queued');
        kick('trigger_deduped');
        return existing.first;
      }
    }
    final action = SosOutboxAction(
      id: _nextId(SosOutboxActionKind.trigger),
      kind: SosOutboxActionKind.trigger,
      createdAt: _clock().toUtc(),
      cycleKey: normalizedKey,
      payload: payload,
      scope: scope,
    );
    _queue.add(action);
    await _persist();
    sdkReleaseLog('SOS_OUTBOX_ENQUEUED kind=trigger queue=${_queue.length}');
    _publishStatus();
    kick('trigger_enqueued');
    return action;
  }

  /// Persists a cancel observed at [observedAt] (default: now).
  ///
  /// - Triggers created up to [observedAt] are superseded: either never
  ///   delivered (nothing to cancel) or delivered (the cancel closes them);
  ///   they must not be re-sent.
  /// - Triggers created after it are newer SOS: they stay, and the cancel is
  ///   placed before them so it can never close them.
  /// - A cancel observed before a newer trigger the broker already
  ///   acknowledged is stale and is dropped (returns null).
  Future<SosOutboxAction?> enqueueCancel({
    String? cycleKey,
    DateTime? observedAt,
    String? scope,
  }) async {
    final observed = (observedAt ?? _clock()).toUtc();
    final newestPublished = _lastPublishedTriggerAt;
    final newerTriggerPublished =
        (newestPublished != null && newestPublished.isAfter(observed)) ||
        _queue.any(
          (action) =>
              action.kind == SosOutboxActionKind.trigger &&
              action.published &&
              action.createdAt.isAfter(observed),
        );
    if (newerTriggerPublished) {
      sdkReleaseLog(
        'SOS_OUTBOX_STALE_CANCEL_DROPPED reason=newer_sos_delivered',
      );
      return null;
    }
    final superseded = _queue
        .where(
          (action) =>
              action.kind == SosOutboxActionKind.trigger &&
              !action.createdAt.isAfter(observed),
        )
        .toList();
    for (final trigger in superseded) {
      _queue.remove(trigger);
      _completeWaiter(trigger.id, false);
    }
    if (superseded.isNotEmpty) {
      sdkReleaseLog(
        'SOS_OUTBOX_TRIGGER_SUPERSEDED_BY_CANCEL count=${superseded.length} '
        'anyPublished=${superseded.any((action) => action.published || action.attempts > 0)}',
      );
    }
    final insertAt = _queue.indexWhere(
      (action) =>
          action.kind == SosOutboxActionKind.trigger &&
          action.createdAt.isAfter(observed),
    );
    final queuedCancel = _queue
        .take(insertAt < 0 ? _queue.length : insertAt)
        .where((action) => action.kind == SosOutboxActionKind.cancel)
        .lastOrNull;
    if (queuedCancel != null) {
      await _persist();
      _publishStatus();
      kick('cancel_deduped');
      return queuedCancel;
    }
    final action = SosOutboxAction(
      id: _nextId(SosOutboxActionKind.cancel),
      kind: SosOutboxActionKind.cancel,
      createdAt: _clock().toUtc(),
      observedAt: observed,
      cycleKey: cycleKey,
      scope: scope,
      payload: <String, dynamic>{
        'timestamp': _clock().toUtc().toIso8601String(),
      },
    );
    if (insertAt < 0) {
      _queue.add(action);
    } else {
      _queue.insert(insertAt, action);
      sdkReleaseLog('SOS_OUTBOX_CANCEL_ORDERED_BEFORE_NEWER_TRIGGER');
    }
    await _persist();
    sdkReleaseLog('SOS_OUTBOX_ENQUEUED kind=cancel queue=${_queue.length}');
    _publishStatus();
    // Interrupt any wait on a superseded trigger.
    _signalConfirm();
    kick('cancel_enqueued');
    return action;
  }

  /// The backend confirmed the oldest pending action of [kind] (realtime
  /// event). Confirms the head when it matches.
  void confirm(
    SosOutboxActionKind kind, {
    required String source,
    bool Function(SosOutboxAction head)? matches,
  }) {
    final head = _queue.firstOrNull;
    if (head == null || head.kind != kind || !_wasAttempted(head)) {
      return;
    }
    if (matches != null && !matches(head)) {
      return;
    }
    unawaited(_markConfirmed(head, source: source));
  }

  /// Wait until [action] is confirmed (true), superseded/expired (false), or
  /// [timeout] elapses (false). Delivery continues after a timeout.
  Future<bool> waitForConfirmation(
    SosOutboxAction action, {
    required Duration timeout,
  }) {
    if (_queue.every((queued) => queued.id != action.id)) {
      return Future<bool>.value(false);
    }
    final completer = _waiters.putIfAbsent(action.id, Completer<bool>.new);
    return completer.future.timeout(timeout, onTimeout: () => false);
  }

  /// Completes when one publish attempt of [action] finished (PUBACK or
  /// failure), when it is confirmed/superseded, or after [timeout].
  Future<void> waitForAttempt(
    SosOutboxAction action, {
    required Duration timeout,
  }) {
    if (!isPending(action.id)) {
      return Future<void>.value();
    }
    final completer = _attemptWaiters.putIfAbsent(
      action.id,
      Completer<void>.new,
    );
    return completer.future.timeout(timeout, onTimeout: () {});
  }

  void _completeAttemptWaiter(String id) {
    final waiter = _attemptWaiters.remove(id);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  bool isPending(String actionId) =>
      _queue.any((action) => action.id == actionId);

  /// Retry now instead of waiting for the backoff.
  void kick(String reason) {
    if (_disposed || _paused) {
      return;
    }
    final wake = _wake;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
    if (!_running && _queue.isNotEmpty) {
      unawaited(_run(reason));
    }
  }

  /// Account change: pending actions belong to the previous user.
  Future<void> clear({required String reason}) async {
    final dropped = _queue.length;
    for (final action in _queue) {
      _completeWaiter(action.id, false);
    }
    _queue.clear();
    _lastPublishedTriggerAt = null;
    _signalConfirm();
    await _store?.remove(storeKey);
    if (dropped > 0) {
      sdkReleaseLog('SOS_OUTBOX_CLEARED count=$dropped reason=$reason');
    }
    _publishStatus();
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryingTimer?.cancel();
    final wake = _wake;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
    _signalConfirm();
    for (final waiter in _waiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete(false);
      }
    }
    _waiters.clear();
    for (final waiter in _attemptWaiters.values) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _attemptWaiters.clear();
    await _statusController.close();
  }

  Future<void> _run(String reason) async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      while (!_disposed && !_paused && _queue.isNotEmpty) {
        final head = _queue.first;
        if (_expired(head)) {
          _queue.removeAt(0);
          await _persist();
          _completeWaiter(head.id, false);
          sdkReleaseLog(
            'SOS_OUTBOX_EXPIRED kind=${head.kind.name} attempts=${head.attempts}',
          );
          _publishStatus();
          _onExpired?.call(head);
          continue;
        }
        final outcome = await _attempt(head);
        if (_disposed) {
          return;
        }
        if (outcome == _AttemptOutcome.done ||
            _queue.firstOrNull?.id != head.id) {
          continue;
        }
        final current = _queue.first;
        final delay =
            backoff[(current.attempts - 1).clamp(0, backoff.length - 1)];
        sdkReleaseLog(
          'SOS_OUTBOX_RETRY_SCHEDULED kind=${current.kind.name} '
          'attempt=${current.attempts} delayMs=${delay.inMilliseconds}',
        );
        await _sleep(delay);
      }
    } finally {
      _running = false;
    }
    if (!_disposed && !_paused && _queue.isNotEmpty) {
      unawaited(_run('requeue'));
    }
  }

  Future<_AttemptOutcome> _attempt(SosOutboxAction head) async {
    final attempted = head.copyWith(
      attempts: head.attempts + 1,
      lastAttemptAt: _clock().toUtc(),
    );
    _replace(attempted);
    await _persist();
    _publishStatus();
    var current = attempted;
    try {
      await _publish(current);
      if (_queue.firstOrNull?.id != current.id) {
        _completeAttemptWaiter(current.id);
        return _AttemptOutcome.superseded;
      }
      current = current.copyWith(published: true);
      _replace(current);
      if (current.kind == SosOutboxActionKind.trigger &&
          (_lastPublishedTriggerAt == null ||
              current.createdAt.isAfter(_lastPublishedTriggerAt!))) {
        _lastPublishedTriggerAt = current.createdAt;
      }
      await _persist();
      sdkReleaseLog(
        'SOS_OUTBOX_PUBLISHED kind=${current.kind.name} '
        'attempt=${current.attempts}',
      );
      _completeAttemptWaiter(current.id);
    } on SosOutboxDropAction catch (drop) {
      _queue.removeWhere((action) => action.id == current.id);
      await _persist();
      sdkReleaseLog(
        'SOS_OUTBOX_DROPPED kind=${current.kind.name} reason=${drop.reason}',
      );
      _completeWaiter(current.id, false);
      _publishStatus();
      return _AttemptOutcome.superseded;
    } catch (error) {
      sdkReleaseLog(
        'SOS_OUTBOX_PUBLISH_FAILED kind=${current.kind.name} '
        'attempt=${current.attempts} errorType=${error.runtimeType}',
      );
      _completeAttemptWaiter(current.id);
      // A timed-out PUBACK may still have reached the backend: check it.
      final check = await _safeRead(current);
      if (check == SosOutboxBackendCheck.confirmed &&
          _queue.firstOrNull?.id == current.id) {
        await _markConfirmed(current, source: 'backend_read_after_failure');
        return _AttemptOutcome.done;
      }
      return _AttemptOutcome.retry;
    }

    // Published: wait briefly for the realtime confirmation, then read.
    if (await _waitConfirmSignal(current)) {
      return _AttemptOutcome.done;
    }
    if (_queue.firstOrNull?.id != current.id) {
      return _AttemptOutcome.superseded;
    }
    final check = await _safeRead(current);
    if (_queue.firstOrNull?.id != current.id) {
      return _AttemptOutcome.superseded;
    }
    if (check == SosOutboxBackendCheck.confirmed) {
      await _markConfirmed(current, source: 'backend_read');
      return _AttemptOutcome.done;
    }
    sdkReleaseLog(
      'SOS_OUTBOX_NOT_CONFIRMED kind=${current.kind.name} '
      'attempt=${current.attempts} backend=${check.name}',
    );
    return _AttemptOutcome.retry;
  }

  Future<bool> _waitConfirmSignal(SosOutboxAction action) async {
    if (!isPending(action.id)) {
      return true;
    }
    final signal = Completer<void>();
    _confirmSignal = signal;
    await Future.any(<Future<void>>[
      signal.future,
      Future<void>.delayed(confirmationWindow),
    ]);
    if (identical(_confirmSignal, signal)) {
      _confirmSignal = null;
    }
    return !isPending(action.id) && _lastConfirmedId == action.id;
  }

  String? _lastConfirmedId;

  Future<void> _markConfirmed(
    SosOutboxAction action, {
    required String source,
  }) async {
    final removed = _queue.indexWhere((queued) => queued.id == action.id);
    if (removed < 0) {
      return;
    }
    final confirmed = _queue.removeAt(removed);
    _lastConfirmedId = confirmed.id;
    await _persist();
    sdkReleaseLog(
      'SOS_OUTBOX_CONFIRMED kind=${confirmed.kind.name} '
      'attempts=${confirmed.attempts} source=$source '
      'latencyMs=${_clock().toUtc().difference(confirmed.createdAt).inMilliseconds}',
    );
    _completeWaiter(confirmed.id, true);
    _signalConfirm();
    _publishStatus();
    _onConfirmed?.call(confirmed, source);
  }

  Future<SosOutboxBackendCheck> _safeRead(SosOutboxAction action) async {
    try {
      return await _readBackend(action);
    } catch (error) {
      sdkReleaseLog(
        'SOS_OUTBOX_BACKEND_READ_FAILED kind=${action.kind.name} '
        'errorType=${error.runtimeType}',
      );
      return SosOutboxBackendCheck.unknown;
    }
  }

  Future<void> _sleep(Duration delay) async {
    final wake = Completer<void>();
    _wake = wake;
    await Future.any(<Future<void>>[wake.future, Future<void>.delayed(delay)]);
    if (identical(_wake, wake)) {
      _wake = null;
    }
  }

  void _signalConfirm() {
    final signal = _confirmSignal;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }
  }

  void _completeWaiter(String id, bool value) {
    _completeAttemptWaiter(id);
    final waiter = _waiters.remove(id);
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(value);
    }
  }

  bool _wasAttempted(SosOutboxAction action) => action.attempts > 0;

  bool _expired(SosOutboxAction action) {
    final maxAge = action.kind == SosOutboxActionKind.trigger
        ? triggerMaxAge
        : cancelMaxAge;
    return _clock().toUtc().difference(action.createdAt) > maxAge;
  }

  void _replace(SosOutboxAction action) {
    final index = _queue.indexWhere((queued) => queued.id == action.id);
    if (index >= 0) {
      _queue[index] = action;
    }
  }

  Future<void> _persist() async {
    final store = _store;
    // A disposed outbox (process shutting down) must not overwrite what a
    // newer runtime restored from the store.
    if (store == null || _disposed) {
      return;
    }
    final lastPublished = _lastPublishedTriggerAt;
    if (_queue.isEmpty && lastPublished == null) {
      await store.remove(storeKey);
      return;
    }
    await store.saveJson(storeKey, <String, dynamic>{
      'actions': _queue.map((action) => action.toJson()).toList(),
      if (lastPublished != null)
        'lastPublishedTriggerAt': lastPublished.toIso8601String(),
    });
  }

  void _publishStatus() {
    final head = _queue.firstOrNull;
    final unconfirmedFor = head == null
        ? Duration.zero
        : _clock().toUtc().difference(head.createdAt);
    final next = SosOutboxStatus(
      pendingTrigger: _queue.any(
        (action) => action.kind == SosOutboxActionKind.trigger,
      ),
      pendingCancel: _queue.any(
        (action) => action.kind == SosOutboxActionKind.cancel,
      ),
      retrying: head != null && unconfirmedFor >= retryingAfter,
      headAttempts: head?.attempts ?? 0,
    );
    _retryingTimer?.cancel();
    if (!_disposed && head != null && !next.retrying) {
      _retryingTimer = Timer(retryingAfter - unconfirmedFor, _publishStatus);
    }
    if (next == _status) {
      return;
    }
    _status = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  String _nextId(SosOutboxActionKind kind) =>
      '${kind.name}-${_clock().toUtc().microsecondsSinceEpoch}-${_sequence++}';

  @visibleForTesting
  void pauseForTesting() => _paused = true;

  @visibleForTesting
  void resumeForTesting() {
    _paused = false;
    kick('test_resume');
  }
}

enum _AttemptOutcome { done, retry, superseded }
