import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'background_location_platform_adapter.dart';
import 'sos_location_ownership_orchestrator.dart';

enum SosLocationOwnershipEffectMode {
  disabled,
  observe,
  enabled,
}

enum SosLocationOwnershipReconciliationReason {
  initializationAfterLifecycleRestoration,
  newerAuthoritativeLifecycleRevision,
  explicitInternalTestTrigger,
  permissionOrStatusChange,
  sdkRuntime,
  beforeDisposal,
}

enum SosLocationOwnershipErrorCategory {
  permission,
  platformChannel,
  disposed,
  tracking,
  invalidPlatformState,
  unknown,
}

final class SosLocationOwnershipPlatformState {
  const SosLocationOwnershipPlatformState({
    required this.requestedOwnership,
    required this.appliedOwnership,
    required this.running,
  });

  final bool? requestedOwnership;
  final bool? appliedOwnership;
  final bool? running;
}

abstract interface class SosLocationOwnershipReconciler {
  Future<void> reconcile(
    bool desiredOwnership,
    SosLocationOwnershipReconciliationReason reason,
  );
}

abstract interface class SosLocationOwnershipDisposable {
  Future<void> dispose();
}

abstract interface class SosLocationOwnershipPlatformStateProvider {
  SosLocationOwnershipPlatformState get platformState;
}

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
    required this.authoritativeDesiredOwnership,
    required this.emittedCommandCount,
    required this.effectAttemptCount,
    required this.completedCommandCount,
    required this.failureCount,
    required this.lastEffect,
    required this.lastSequenceNumber,
    required this.lastErrorCategory,
    required this.platformState,
    required this.reconciliationCount,
    required this.lastReconciliationReason,
    required this.effectMode,
    required this.acceptingCommands,
    required this.disposed,
  });

  final bool authoritativeDesiredOwnership;
  final int emittedCommandCount;
  final int effectAttemptCount;
  final int completedCommandCount;
  final int failureCount;
  final SosLocationOwnershipEffect? lastEffect;
  final int lastSequenceNumber;
  final SosLocationOwnershipErrorCategory? lastErrorCategory;
  final SosLocationOwnershipPlatformState platformState;
  final int reconciliationCount;
  final SosLocationOwnershipReconciliationReason? lastReconciliationReason;
  final SosLocationOwnershipEffectMode effectMode;
  final bool acceptingCommands;
  final bool disposed;
}

/// Serializes effect delivery without allowing failures to affect lifecycle.
final class SosLocationOwnershipEffectDispatcher {
  SosLocationOwnershipEffectDispatcher({
    SosLocationOwnershipEffectSink sink =
        const NoopSosLocationOwnershipEffectSink(),
    this.effectMode = SosLocationOwnershipEffectMode.disabled,
  }) : _sink = sink;

  final SosLocationOwnershipEffectSink _sink;
  final SosLocationOwnershipEffectMode effectMode;
  Future<void> _tail = Future<void>.value();
  bool _authoritativeDesiredOwnership = false;
  int _emittedCommandCount = 0;
  int _effectAttemptCount = 0;
  int _completedCommandCount = 0;
  int _failureCount = 0;
  SosLocationOwnershipEffect? _lastEffect;
  int _lastSequenceNumber = 0;
  SosLocationOwnershipErrorCategory? _lastErrorCategory;
  int _reconciliationCount = 0;
  SosLocationOwnershipReconciliationReason? _lastReconciliationReason;
  bool _acceptingCommands = true;
  bool _disposed = false;

  SosLocationOwnershipEffectDiagnostics get diagnostics =>
      SosLocationOwnershipEffectDiagnostics(
        authoritativeDesiredOwnership: _authoritativeDesiredOwnership,
        emittedCommandCount: _emittedCommandCount,
        effectAttemptCount: _effectAttemptCount,
        completedCommandCount: _completedCommandCount,
        failureCount: _failureCount,
        lastEffect: _lastEffect,
        lastSequenceNumber: _lastSequenceNumber,
        lastErrorCategory: _lastErrorCategory,
        platformState: _sink is SosLocationOwnershipPlatformStateProvider
            ? (_sink as SosLocationOwnershipPlatformStateProvider).platformState
            : const SosLocationOwnershipPlatformState(
                requestedOwnership: null,
                appliedOwnership: null,
                running: null,
              ),
        reconciliationCount: _reconciliationCount,
        lastReconciliationReason: _lastReconciliationReason,
        effectMode: effectMode,
        acceptingCommands: _acceptingCommands,
        disposed: _disposed,
      );

  /// Offers one command for serialized delivery.
  ///
  /// Errors are reduced to a count and never escape this boundary.
  void offer(SosLocationOwnershipEffect effect) {
    if (!_acceptingCommands) {
      return;
    }
    _authoritativeDesiredOwnership =
        effect == SosLocationOwnershipEffect.activateSosLocation;
    _emittedCommandCount += 1;
    _lastSequenceNumber += 1;
    _lastEffect = effect;
    _tail = _tail.then((_) async {
      _effectAttemptCount += 1;
      try {
        await _sink.apply(effect);
        _completedCommandCount += 1;
        _lastErrorCategory = null;
      } catch (error) {
        _failureCount += 1;
        _lastErrorCategory = _categorize(error);
      }
    });
  }

  /// Compares desired and platform state independently of transition dedup.
  void reconcile(
    bool desiredOwnership,
    SosLocationOwnershipReconciliationReason reason,
  ) {
    if (!_acceptingCommands) {
      return;
    }
    _authoritativeDesiredOwnership = desiredOwnership;
    _reconciliationCount += 1;
    _lastReconciliationReason = reason;
    _tail = _tail.then((_) async {
      final sink = _sink;
      if (sink is! SosLocationOwnershipReconciler) {
        return;
      }
      try {
        await (sink as SosLocationOwnershipReconciler).reconcile(
          desiredOwnership,
          reason,
        );
        _lastErrorCategory = null;
      } catch (error) {
        _failureCount += 1;
        _lastErrorCategory = _categorize(error);
      }
    });
  }

  /// Test synchronization point for all currently queued commands.
  Future<void> get whenIdle => _tail;

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _acceptingCommands = false;
    await _tail;
    final sink = _sink;
    if (sink is SosLocationOwnershipDisposable) {
      try {
        await (sink as SosLocationOwnershipDisposable).dispose();
      } catch (error) {
        _failureCount += 1;
        _lastErrorCategory = _categorize(error);
      }
    }
    _disposed = true;
  }

  SosLocationOwnershipErrorCategory _categorize(Object error) {
    if (error is BackgroundLocationAdapterException) {
      return SosLocationOwnershipErrorCategory.platformChannel;
    }
    if (error is TrackingException) {
      return error.code == 'E_LOCATION_PERMISSION_REQUIRED'
          ? SosLocationOwnershipErrorCategory.permission
          : SosLocationOwnershipErrorCategory.tracking;
    }
    if (error is StateError) {
      return SosLocationOwnershipErrorCategory.disposed;
    }
    return SosLocationOwnershipErrorCategory.unknown;
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
