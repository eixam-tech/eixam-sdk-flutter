import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Timing and gating of the foreground battery probe (`0x23`).
///
/// - waits for SOS rehydration first, so a pre-SOS/SOS that started while the
///   app was backgrounded is known; if that cannot be confirmed in time the
///   probe stays silent instead of guessing;
/// - evaluates [isBlocked] only after that wait and again immediately before
///   [start], with no `await` in between;
/// - runs at most once per [minInterval] per device, counted from the moment a
///   request is actually made (a failed request also waits out the interval,
///   a skipped one does not);
/// - [start] returns null when the command path is not **already** ready; the
///   probe then does nothing. Nothing here can reconnect, rebind or retry.
final class TagBatteryProbe {
  TagBatteryProbe({
    required DateTime Function() clock,
    required bool Function() isBlocked,
    required Future<DeviceRuntimeStatus>? Function() start,
    this.minInterval = const Duration(minutes: 10),
    this.sosRehydrationWait = const Duration(seconds: 10),
    void Function(String outcome)? onOutcome,
  }) : _onOutcome = onOutcome,
       _clock = clock,
       _isBlocked = isBlocked,
       _start = start;

  final DateTime Function() _clock;
  final bool Function() _isBlocked;
  final Future<DeviceRuntimeStatus>? Function() _start;
  final void Function(String outcome)? _onOutcome;
  final Duration minInterval;
  final Duration sosRehydrationWait;
  final Map<String, DateTime> _lastRequestAt = <String, DateTime>{};

  /// Returns the reply, or null when the probe was skipped or the request
  /// failed.
  Future<DeviceRuntimeStatus?> run({
    required String deviceKey,
    Future<void>? afterSosRehydration,
  }) async {
    if (afterSosRehydration != null) {
      try {
        await afterSosRehydration.timeout(sosRehydrationWait);
      } catch (_) {
        _onOutcome?.call('skipped_sos_rehydration_unconfirmed');
        return null;
      }
    }
    if (_isBlocked()) {
      _onOutcome?.call('skipped_blocked');
      return null;
    }
    final now = _clock();
    final last = _lastRequestAt[deviceKey];
    if (last != null && now.difference(last) < minInterval) {
      _onOutcome?.call('skipped_interval');
      return null;
    }
    // Synchronous from the last gate check to the send: it cannot go stale.
    if (_isBlocked()) {
      _onOutcome?.call('skipped_blocked_before_send');
      return null;
    }
    final request = _start();
    if (request == null) {
      _onOutcome?.call('skipped_path_not_ready');
      return null;
    }
    _lastRequestAt[deviceKey] = now;
    try {
      final reply = await request;
      _onOutcome?.call('replied');
      return reply;
    } catch (_) {
      _onOutcome?.call('request_failed');
      return null;
    }
  }
}
