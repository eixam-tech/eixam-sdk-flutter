import 'dart:collection';

import 'package:eixam_connect_core/eixam_connect_core.dart';

enum AndroidTrackingOwner {
  legacyPublicTracking,
  sos,
}

enum AndroidTrackingOwnerErrorCategory {
  permission,
  tracking,
  disposed,
  unknown,
}

final class AndroidTrackingOwnerDiagnostics {
  AndroidTrackingOwnerDiagnostics({
    required Iterable<AndroidTrackingOwner> requestedOwners,
    required this.appliedRunning,
    required this.actualState,
    required this.startAttemptCount,
    required this.stopAttemptCount,
    required this.reconciliationCount,
    required this.lastErrorCategory,
    required this.disposed,
  }) : requestedOwners = UnmodifiableSetView<AndroidTrackingOwner>(
          Set<AndroidTrackingOwner>.of(requestedOwners),
        );

  final Set<AndroidTrackingOwner> requestedOwners;
  final bool appliedRunning;
  final TrackingState? actualState;
  final int startAttemptCount;
  final int stopAttemptCount;
  final int reconciliationCount;
  final AndroidTrackingOwnerErrorCategory? lastErrorCategory;
  final bool disposed;
}

/// Arbitrates all Dart owners of the SDK's single Android tracking repository.
final class AndroidTrackingOwnerArbiter {
  AndroidTrackingOwnerArbiter({
    required TrackingRepository trackingRepository,
  }) : _trackingRepository = trackingRepository;

  final TrackingRepository _trackingRepository;
  final Set<AndroidTrackingOwner> _requestedOwners = <AndroidTrackingOwner>{};
  Future<void> _operation = Future<void>.value();
  bool _appliedRunning = false;
  TrackingState? _actualState;
  int _startAttemptCount = 0;
  int _stopAttemptCount = 0;
  int _reconciliationCount = 0;
  AndroidTrackingOwnerErrorCategory? _lastErrorCategory;
  bool _disposed = false;

  bool hasOwner(AndroidTrackingOwner owner) => _requestedOwners.contains(owner);

  AndroidTrackingOwnerDiagnostics get diagnostics =>
      AndroidTrackingOwnerDiagnostics(
        requestedOwners: _requestedOwners,
        appliedRunning: _appliedRunning,
        actualState: _actualState,
        startAttemptCount: _startAttemptCount,
        stopAttemptCount: _stopAttemptCount,
        reconciliationCount: _reconciliationCount,
        lastErrorCategory: _lastErrorCategory,
        disposed: _disposed,
      );

  Future<void> addOwner(AndroidTrackingOwner owner) {
    _ensureNotDisposed();
    if (!_requestedOwners.add(owner)) {
      return _operation;
    }
    return _serialize(_reconcileAppliedState);
  }

  Future<void> removeOwner(AndroidTrackingOwner owner) {
    _ensureNotDisposed();
    if (!_requestedOwners.remove(owner)) {
      return _operation;
    }
    return _serialize(_reconcileAppliedState);
  }

  /// Performs at most one start or stop attempt.
  Future<void> reconcile() {
    _ensureNotDisposed();
    _reconciliationCount += 1;
    return _serialize(() async {
      try {
        _actualState = await _trackingRepository.getTrackingState();
        _appliedRunning = _isRunning(_actualState!);
      } catch (error) {
        _lastErrorCategory = _categorize(error);
      }
      await _reconcileAppliedState();
    });
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _operation;
    _requestedOwners.clear();
  }

  Future<void> _reconcileAppliedState() async {
    final shouldRun = _requestedOwners.isNotEmpty;
    if (shouldRun == _appliedRunning) {
      return;
    }
    if (shouldRun) {
      _startAttemptCount += 1;
      try {
        await _trackingRepository.startTracking();
        _appliedRunning = true;
        _actualState = TrackingState.starting;
        _lastErrorCategory = null;
      } catch (error) {
        _appliedRunning = false;
        _lastErrorCategory = _categorize(error);
        rethrow;
      }
      return;
    }
    _stopAttemptCount += 1;
    try {
      await _trackingRepository.stopTracking();
      _appliedRunning = false;
      _actualState = TrackingState.idle;
      _lastErrorCategory = null;
    } catch (error) {
      _appliedRunning = true;
      _lastErrorCategory = _categorize(error);
      rethrow;
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _operation.then((_) => operation());
    _operation = result.catchError((Object _) {});
    return result;
  }

  bool _isRunning(TrackingState state) => switch (state) {
        TrackingState.starting ||
        TrackingState.tracking ||
        TrackingState.paused ||
        TrackingState.stale =>
          true,
        TrackingState.idle || TrackingState.error => false,
      };

  AndroidTrackingOwnerErrorCategory _categorize(Object error) {
    if (error is TrackingException &&
        error.code == 'E_LOCATION_PERMISSION_REQUIRED') {
      return AndroidTrackingOwnerErrorCategory.permission;
    }
    if (error is TrackingException) {
      return AndroidTrackingOwnerErrorCategory.tracking;
    }
    if (error is StateError) {
      return AndroidTrackingOwnerErrorCategory.disposed;
    }
    return AndroidTrackingOwnerErrorCategory.unknown;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('AndroidTrackingOwnerArbiter is disposed.');
    }
  }
}
