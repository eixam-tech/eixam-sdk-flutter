import 'dart:async';

import 'sos_location_ownership_orchestrator.dart';

/// A platform-independent ownership intent emitted for SOS location.
///
/// This internal SDK type deliberately carries no location, permission,
/// telemetry, cadence, sharing, DMP, or platform-specific data.
enum SosLocationOwnershipEffect {
  activateSosLocation,
  deactivateSosLocation,
}

/// Internal boundary for applying SOS location-ownership intent.
abstract interface class SosLocationOwnershipEffectSink {
  Future<void> apply(SosLocationOwnershipEffect effect);
}

/// Production implementation for phase 4B3.
///
/// It intentionally performs no work and retains no data.
final class NoopSosLocationOwnershipEffectSink
    implements SosLocationOwnershipEffectSink {
  const NoopSosLocationOwnershipEffectSink();

  @override
  Future<void> apply(SosLocationOwnershipEffect effect) async {}
}

/// Sanitized, in-memory diagnostics for the serialized effect boundary.
final class SosLocationOwnershipEffectDiagnostics {
  const SosLocationOwnershipEffectDiagnostics({
    required this.emittedCommandCount,
    required this.completedCommandCount,
    required this.failureCount,
    required this.lastEffect,
    required this.lastSequenceNumber,
    required this.disposed,
  });

  final int emittedCommandCount;
  final int completedCommandCount;
  final int failureCount;
  final SosLocationOwnershipEffect? lastEffect;
  final int lastSequenceNumber;
  final bool disposed;
}

/// Serializes effect delivery without allowing failures to affect lifecycle.
final class SosLocationOwnershipEffectDispatcher {
  SosLocationOwnershipEffectDispatcher({
    SosLocationOwnershipEffectSink sink =
        const NoopSosLocationOwnershipEffectSink(),
  }) : _sink = sink;

  final SosLocationOwnershipEffectSink _sink;
  Future<void> _tail = Future<void>.value();
  int _emittedCommandCount = 0;
  int _completedCommandCount = 0;
  int _failureCount = 0;
  SosLocationOwnershipEffect? _lastEffect;
  int _lastSequenceNumber = 0;
  bool _disposed = false;

  SosLocationOwnershipEffectDiagnostics get diagnostics =>
      SosLocationOwnershipEffectDiagnostics(
        emittedCommandCount: _emittedCommandCount,
        completedCommandCount: _completedCommandCount,
        failureCount: _failureCount,
        lastEffect: _lastEffect,
        lastSequenceNumber: _lastSequenceNumber,
        disposed: _disposed,
      );

  /// Offers one command for serialized delivery.
  ///
  /// Errors are reduced to a count and never escape this boundary.
  void offer(SosLocationOwnershipEffect effect) {
    if (_disposed) {
      return;
    }
    _emittedCommandCount += 1;
    _lastSequenceNumber += 1;
    _lastEffect = effect;
    _tail = _tail.then((_) async {
      if (_disposed) {
        return;
      }
      try {
        await _sink.apply(effect);
        _completedCommandCount += 1;
      } catch (_) {
        _failureCount += 1;
      }
    });
  }

  /// Test synchronization point for all currently queued commands.
  Future<void> get whenIdle => _tail;

  void dispose() {
    _disposed = true;
  }
}

SosLocationOwnershipEffect? sosLocationOwnershipEffectFor(
  SosLocationOwnershipTransition transition,
) =>
    switch (transition) {
      SosLocationOwnershipTransition.activate =>
        SosLocationOwnershipEffect.activateSosLocation,
      SosLocationOwnershipTransition.deactivate =>
        SosLocationOwnershipEffect.deactivateSosLocation,
      SosLocationOwnershipTransition.none => null,
    };
