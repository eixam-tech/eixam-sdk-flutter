import 'dart:async';

/// Outcome of one liveness probe: a request whose reply only arrives as a TAG
/// notification (`0x23 GET_DEVICE_STATUS`).
enum TagNotifyProbeResult {
  /// The reply notification arrived within the timeout.
  replied,

  /// The write succeeded but no reply notification arrived in time.
  noReply,

  /// The write itself failed: the link is really down. Never a "missed"
  /// check; the normal disconnect handling owns this case.
  writeFailed,

  /// No Flutter command path right now. Nothing was sent.
  notReady,
}

final class TagNotifyLivenessTiming {
  const TagNotifyLivenessTiming({
    this.replyTimeout = const Duration(seconds: 8),
    this.afterConnect = const <Duration>[
      Duration(seconds: 5),
      Duration(seconds: 60),
      Duration(minutes: 3),
    ],
    this.afterResume = const Duration(seconds: 5),
    this.periodic = const Duration(minutes: 10),
    this.deferredRetry = const Duration(seconds: 15),
  });

  final Duration replyTimeout;
  final List<Duration> afterConnect;
  final Duration afterResume;
  final Duration periodic;

  /// How often a check deferred by an SOS (or DFU, migration, provisioning,
  /// a running reconnect, a command path not ready yet) is re-evaluated. No
  /// BLE traffic happens while it is deferred.
  final Duration deferredRetry;
}

/// Safety net for a TAG that stays connected and accepts writes while its
/// notifications silently stopped (F12: a TAG SOS then reaches neither the app
/// nor the backend).
///
/// While a TAG is connected it checks that a notification-only reply arrives:
/// after every connect (+5 s, +60 s, +3 min), on app resume and every 10 min.
/// Two consecutive missing replies drop the link once through the existing
/// reconnect path ([recover]); if replies are still missing after that
/// reconnect it reports `restartRequired` until a later check succeeds.
///
/// [skipReason] is evaluated right before every probe and before the
/// recovery; any non-null reason means "do nothing now". Reasons in
/// [_deferredReasons] (SOS, firmware, migration, provisioning, reconnect in
/// progress, command path not ready) re-evaluate later; a check is never run
/// and a reconnect is never started while they hold.
final class TagNotifyLivenessMonitor {
  TagNotifyLivenessMonitor({
    required String? Function() skipReason,
    required Future<TagNotifyProbeResult> Function(Duration timeout) probe,
    required Future<bool> Function() recover,
    required void Function(bool restartRequired) onRestartRequiredChanged,
    required void Function(String line) log,
    bool Function()? isStatusSupportProven,
    this.timing = const TagNotifyLivenessTiming(),
  }) : _isStatusSupportProven = isStatusSupportProven ?? (() => true),
       _skipReason = skipReason,
       _probe = probe,
       _recover = recover,
       _onRestartRequiredChanged = onRestartRequiredChanged,
       _log = log;

  static const Set<String> _deferredReasons = <String>{
    'sos_active',
    'firmware_update',
    'migration',
    'provisioning',
    'reconnecting',
    'path_not_ready',
    'status_request_pending',
    'sos_frame_recent',
  };

  final TagNotifyLivenessTiming timing;
  final String? Function() _skipReason;
  final Future<TagNotifyProbeResult> Function(Duration timeout) _probe;
  final Future<bool> Function() _recover;
  final void Function(bool restartRequired) _onRestartRequiredChanged;
  final void Function(String line) _log;

  /// This TAG answered at least one `0x23` in this app session (its firmware
  /// supports the probe). Without it misses never drop the link or raise
  /// `restartRequired`.
  final bool Function() _isStatusSupportProven;

  final List<Timer> _timers = <Timer>[];
  Timer? _periodicTimer;
  Timer? _deferredTimer;
  String? _deferredTrigger;
  String? _lastSkipLogged;
  String? _deviceKey;
  bool _connected = false;
  bool _running = false;
  bool _disposed = false;
  int _epoch = 0;

  /// A forced reconnect was started; the next completed check decides
  /// between `recovered` and `failed`.
  bool _recoveryPending = false;
  bool _restartRequired = false;

  bool get restartRequired => _restartRequired;

  /// Feeds every published TAG link state. [deviceKey] is null when no TAG
  /// is paired (unpair). [trigger] labels the checks a new connection
  /// schedules (`pair`, `reconnect`).
  void onLink({
    required bool connected,
    required String? deviceKey,
    String trigger = 'reconnect',
  }) {
    if (_disposed) return;
    if (deviceKey != _deviceKey) {
      _deviceKey = deviceKey;
      _connected = false;
      _cancelAll();
      _recoveryPending = false;
      _setRestartRequired(false);
    }
    if (deviceKey == null) return;
    if (connected == _connected) return;
    _connected = connected;
    _cancelAll();
    if (!connected) return;
    final label = _recoveryPending ? 'recovery' : trigger;
    for (final delay in timing.afterConnect) {
      _schedule(delay, label);
    }
    _periodicTimer = Timer.periodic(
      timing.periodic,
      (_) => unawaited(_check('periodic')),
    );
  }

  void onResume() {
    if (_disposed || !_connected) return;
    _schedule(timing.afterResume, 'resume');
  }

  void dispose() {
    _disposed = true;
    _cancelAll();
  }

  void _schedule(Duration delay, String trigger) {
    late final Timer timer;
    timer = Timer(delay, () {
      _timers.remove(timer);
      unawaited(_check(trigger));
    });
    _timers.add(timer);
  }

  void _cancelAll() {
    _epoch++;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _deferredTimer?.cancel();
    _deferredTimer = null;
    _deferredTrigger = null;
    _lastSkipLogged = null;
    _running = false;
  }

  /// Returns true when the caller must stop (skipped or deferred).
  bool _skipped(String trigger) {
    final reason = _skipReason();
    if (reason == null) {
      _lastSkipLogged = null;
      return false;
    }
    final signature = '$reason|$trigger';
    if (_lastSkipLogged != signature) {
      _lastSkipLogged = signature;
      _emit('skipped', reason, trigger);
    }
    if (_deferredReasons.contains(reason)) {
      _defer(trigger);
    }
    return true;
  }

  void _defer(String trigger) {
    _deferredTrigger ??= trigger;
    if (_deferredTimer != null) return;
    _deferredTimer = Timer(timing.deferredRetry, () {
      _deferredTimer = null;
      final deferred = _deferredTrigger;
      _deferredTrigger = null;
      if (deferred != null) unawaited(_check(deferred));
    });
  }

  Future<void> _check(String trigger) async {
    if (_disposed || !_connected || _running) return;
    if (_skipped(trigger)) return;
    final epoch = _epoch;
    _running = true;
    try {
      var misses = 0;
      while (misses < 2) {
        if (misses > 0 && _skipped(trigger)) return;
        final result = await _probe(timing.replyTimeout);
        if (_disposed || epoch != _epoch) return;
        switch (result) {
          case TagNotifyProbeResult.replied:
            _onReplied(trigger);
            return;
          case TagNotifyProbeResult.writeFailed:
            _emit('skipped', 'write_failed', trigger);
            return;
          case TagNotifyProbeResult.notReady:
            _emit('skipped', 'path_not_ready', trigger);
            _defer(trigger);
            return;
          case TagNotifyProbeResult.noReply:
            misses++;
            _emit(
              'missed',
              misses == 1 ? 'no_reply_first' : 'no_reply_x2',
              trigger,
            );
        }
      }
      await _onMissedTwice(trigger, epoch);
    } finally {
      if (epoch == _epoch) _running = false;
    }
  }

  void _onReplied(String trigger) {
    if (_recoveryPending || _restartRequired) {
      _recoveryPending = false;
      _setRestartRequired(false);
      _emit('recovered', 'reply_received', trigger);
      return;
    }
    _emit('ok', 'reply_received', trigger);
  }

  Future<void> _onMissedTwice(String trigger, int epoch) async {
    if (!_isStatusSupportProven()) {
      _emit('skipped', 'unproven_status_support', trigger);
      return;
    }
    if (_recoveryPending || _restartRequired) {
      // Never raise (or re-raise) the restart message during an SOS: the
      // check runs again once it is over.
      if (_skipped(trigger)) return;
      _recoveryPending = false;
      _setRestartRequired(true);
      _emit('failed', 'no_reply_after_recovery', trigger);
      return;
    }
    // Never start a reconnect during an SOS (or any other deferred reason):
    // the whole check runs again once it is over.
    if (_skipped(trigger)) return;
    _emit('missed', 'reconnect_started', trigger);
    _recoveryPending = true;
    final started = await _recover();
    if (_disposed || !started) {
      if (!_disposed && epoch == _epoch && !_skipped(trigger)) {
        _recoveryPending = false;
        _setRestartRequired(true);
        _emit('failed', 'recovery_unavailable', trigger);
      }
      return;
    }
  }

  void _setRestartRequired(bool value) {
    if (_restartRequired == value) return;
    _restartRequired = value;
    _onRestartRequiredChanged(value);
  }

  void _emit(String result, String reason, String trigger) {
    _log('TAG_NOTIFY_LIVENESS result=$result reason=$reason trigger=$trigger');
  }
}
