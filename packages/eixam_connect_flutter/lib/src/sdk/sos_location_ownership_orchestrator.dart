import 'package:eixam_connect_core/eixam_connect_core.dart';

/// The desired change to the SDK-owned SOS background-location context.
///
/// This is intentionally independent from any platform location adapter.
enum SosLocationOwnershipDirective {
  activate,
  deactivate,
  retain,
}

/// A state change emitted by [SosLocationOwnershipOrchestrator].
enum SosLocationOwnershipTransition {
  activate,
  deactivate,
  none,
}

/// Reduces one authoritative SOS lifecycle snapshot to an ownership directive.
///
/// Ambiguous and externally owned snapshots retain the existing ownership.
/// This function is the canonical location-ownership decision point and has no
/// side effects.
SosLocationOwnershipDirective resolveSosLocationOwnershipDirective(
  SosLifecycleSnapshot snapshot,
) {
  if (snapshot.externalOnly) {
    return SosLocationOwnershipDirective.retain;
  }

  if (snapshot.stage == SosLifecycleStage.idle) {
    return SosLocationOwnershipDirective.deactivate;
  }

  if (!_isApprovedLocalOrigin(snapshot.origin)) {
    return SosLocationOwnershipDirective.retain;
  }

  return switch (snapshot.stage) {
    SosLifecycleStage.active ||
    SosLifecycleStage.cancelling ||
    SosLifecycleStage.cancellationFailed ||
    SosLifecycleStage.recoveryRequired =>
      snapshot.localActionable
          ? SosLocationOwnershipDirective.activate
          : SosLocationOwnershipDirective.retain,
    SosLifecycleStage.cancelled ||
    SosLifecycleStage.resolved =>
      SosLocationOwnershipDirective.deactivate,
    SosLifecycleStage.activationFailed when snapshot.localIncidentId == null =>
      SosLocationOwnershipDirective.deactivate,
    SosLifecycleStage.idle ||
    SosLifecycleStage.arming ||
    SosLifecycleStage.activating ||
    SosLifecycleStage.activationFailed =>
      SosLocationOwnershipDirective.retain,
  };
}

bool _isApprovedLocalOrigin(SosLifecycleOrigin origin) {
  return switch (origin) {
    SosLifecycleOrigin.localApp ||
    SosLifecycleOrigin.connectedLocalDevice ||
    SosLifecycleOrigin.registeredLocalDevice =>
      true,
    SosLifecycleOrigin.remoteRelay ||
    SosLifecycleOrigin.externalBackend ||
    SosLifecycleOrigin.unknown =>
      false,
  };
}

/// Stateful, platform-independent SOS location-ownership reducer.
///
/// It does not subscribe to lifecycle streams and never invokes location,
/// telemetry, platform, persistence, or network APIs.
final class SosLocationOwnershipOrchestrator {
  int? _lastAcceptedLifecycleRevision;
  int? _currentGeneration;
  bool _desiredSosOwnership = false;
  SosLocationOwnershipTransition? _lastEmittedOwnershipTransition;
  bool _disposed = false;

  int? get lastAcceptedLifecycleRevision => _lastAcceptedLifecycleRevision;
  int? get currentGeneration => _currentGeneration;
  bool get desiredSosOwnership => _desiredSosOwnership;
  SosLocationOwnershipTransition? get lastEmittedOwnershipTransition =>
      _lastEmittedOwnershipTransition;
  bool get isDisposed => _disposed;

  /// Accepts a snapshot and returns only a newly required ownership transition.
  SosLocationOwnershipTransition accept(SosLifecycleSnapshot snapshot) {
    _ensureNotDisposed();
    final lastRevision = _lastAcceptedLifecycleRevision;
    if (lastRevision != null && snapshot.revision <= lastRevision) {
      return SosLocationOwnershipTransition.none;
    }
    _lastAcceptedLifecycleRevision = snapshot.revision;

    final directive = resolveSosLocationOwnershipDirective(snapshot);
    return switch (directive) {
      SosLocationOwnershipDirective.activate => _activate(snapshot),
      SosLocationOwnershipDirective.deactivate => _deactivate(snapshot),
      SosLocationOwnershipDirective.retain =>
        SosLocationOwnershipTransition.none,
    };
  }

  /// Clears all accepted lifecycle and desired-ownership state.
  void reset() {
    _ensureNotDisposed();
    _clearState();
  }

  /// Permanently prevents further snapshots from being accepted.
  void dispose() {
    if (_disposed) {
      return;
    }
    _clearState();
    _disposed = true;
  }

  SosLocationOwnershipTransition _activate(SosLifecycleSnapshot snapshot) {
    _currentGeneration = snapshot.generation;
    if (_desiredSosOwnership) {
      return SosLocationOwnershipTransition.none;
    }
    _desiredSosOwnership = true;
    return _emit(SosLocationOwnershipTransition.activate);
  }

  SosLocationOwnershipTransition _deactivate(SosLifecycleSnapshot snapshot) {
    if (!_desiredSosOwnership) {
      return SosLocationOwnershipTransition.none;
    }
    if (snapshot.stage != SosLifecycleStage.idle &&
        snapshot.generation != _currentGeneration) {
      return SosLocationOwnershipTransition.none;
    }
    _desiredSosOwnership = false;
    return _emit(SosLocationOwnershipTransition.deactivate);
  }

  SosLocationOwnershipTransition _emit(
    SosLocationOwnershipTransition transition,
  ) {
    _lastEmittedOwnershipTransition = transition;
    return transition;
  }

  void _clearState() {
    _lastAcceptedLifecycleRevision = null;
    _currentGeneration = null;
    _desiredSosOwnership = false;
    _lastEmittedOwnershipTransition = null;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('SosLocationOwnershipOrchestrator is disposed.');
    }
  }
}
