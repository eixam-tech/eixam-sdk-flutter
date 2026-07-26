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

/// Immutable diagnostics for the in-memory SOS ownership shadow.
///
/// This type is internal to the Flutter SDK package and is not barrel-exported.
final class SosLocationOwnershipShadowState {
  const SosLocationOwnershipShadowState({
    required this.lastAcceptedLifecycleRevision,
    required this.currentGeneration,
    required this.desiredSosOwnership,
    required this.lastDirective,
    required this.lastEmittedOwnershipTransition,
    required this.acceptedSnapshotCount,
    required this.activateTransitionCount,
    required this.deactivateTransitionCount,
    required this.disposed,
  });

  final int? lastAcceptedLifecycleRevision;
  final int? currentGeneration;
  final bool desiredSosOwnership;
  final SosLocationOwnershipDirective? lastDirective;
  final SosLocationOwnershipTransition? lastEmittedOwnershipTransition;
  final int acceptedSnapshotCount;
  final int activateTransitionCount;
  final int deactivateTransitionCount;
  final bool disposed;
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
  SosLocationOwnershipDirective? _lastDirective;
  SosLocationOwnershipTransition? _lastEmittedOwnershipTransition;
  int _acceptedSnapshotCount = 0;
  int _activateTransitionCount = 0;
  int _deactivateTransitionCount = 0;
  bool _disposed = false;

  int? get lastAcceptedLifecycleRevision => _lastAcceptedLifecycleRevision;
  int? get currentGeneration => _currentGeneration;
  bool get desiredSosOwnership => _desiredSosOwnership;
  SosLocationOwnershipTransition? get lastEmittedOwnershipTransition =>
      _lastEmittedOwnershipTransition;
  bool get isDisposed => _disposed;
  SosLocationOwnershipShadowState get shadowState =>
      SosLocationOwnershipShadowState(
        lastAcceptedLifecycleRevision: _lastAcceptedLifecycleRevision,
        currentGeneration: _currentGeneration,
        desiredSosOwnership: _desiredSosOwnership,
        lastDirective: _lastDirective,
        lastEmittedOwnershipTransition: _lastEmittedOwnershipTransition,
        acceptedSnapshotCount: _acceptedSnapshotCount,
        activateTransitionCount: _activateTransitionCount,
        deactivateTransitionCount: _deactivateTransitionCount,
        disposed: _disposed,
      );

  /// Accepts a snapshot and returns only a newly required ownership transition.
  SosLocationOwnershipTransition accept(SosLifecycleSnapshot snapshot) {
    _ensureNotDisposed();
    final lastRevision = _lastAcceptedLifecycleRevision;
    if (lastRevision != null && snapshot.revision <= lastRevision) {
      return SosLocationOwnershipTransition.none;
    }
    _lastAcceptedLifecycleRevision = snapshot.revision;
    _acceptedSnapshotCount += 1;

    final directive = resolveSosLocationOwnershipDirective(snapshot);
    _lastDirective = directive;
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
    switch (transition) {
      case SosLocationOwnershipTransition.activate:
        _activateTransitionCount += 1;
      case SosLocationOwnershipTransition.deactivate:
        _deactivateTransitionCount += 1;
      case SosLocationOwnershipTransition.none:
        break;
    }
    return transition;
  }

  void _clearState() {
    _lastAcceptedLifecycleRevision = null;
    _currentGeneration = null;
    _desiredSosOwnership = false;
    _lastDirective = null;
    _lastEmittedOwnershipTransition = null;
    _acceptedSnapshotCount = 0;
    _activateTransitionCount = 0;
    _deactivateTransitionCount = 0;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('SosLocationOwnershipOrchestrator is disposed.');
    }
  }
}
