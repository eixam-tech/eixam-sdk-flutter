import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import 'android_tracking_owner_arbiter.dart';
import 'background_location_platform_adapter.dart';
import 'sos_location_ownership_effect.dart';
import 'sos_location_trace.dart';

final class ObservingSosLocationOwnershipEffectSink
    implements
        SosLocationOwnershipEffectSink,
        SosLocationOwnershipReconciler,
        SosLocationOwnershipPlatformStateProvider {
  bool? _requestedOwnership;

  @override
  SosLocationOwnershipPlatformState get platformState =>
      SosLocationOwnershipPlatformState(
        requestedOwnership: _requestedOwnership,
        appliedOwnership: false,
        running: false,
      );

  @override
  Future<void> apply(SosLocationOwnershipEffect effect) async {
    _requestedOwnership =
        effect == SosLocationOwnershipEffect.activateSosLocation;
  }

  @override
  Future<void> reconcile(
    bool desiredOwnership,
    SosLocationOwnershipReconciliationReason reason,
  ) async {
    _requestedOwnership = desiredOwnership;
  }
}

final class AndroidSosLocationOwnershipEffectSink
    implements
        SosLocationOwnershipEffectSink,
        SosLocationOwnershipReconciler,
        SosLocationOwnershipPlatformStateProvider {
  AndroidSosLocationOwnershipEffectSink({
    required AndroidTrackingOwnerArbiter trackingOwnerArbiter,
  }) : _trackingOwnerArbiter = trackingOwnerArbiter;

  final AndroidTrackingOwnerArbiter _trackingOwnerArbiter;

  @override
  SosLocationOwnershipPlatformState get platformState {
    final diagnostics = _trackingOwnerArbiter.diagnostics;
    return SosLocationOwnershipPlatformState(
      requestedOwnership:
          diagnostics.requestedOwners.contains(AndroidTrackingOwner.sos),
      appliedOwnership:
          diagnostics.requestedOwners.contains(AndroidTrackingOwner.sos) &&
              diagnostics.appliedRunning,
      running: diagnostics.appliedRunning,
    );
  }

  @override
  Future<void> apply(SosLocationOwnershipEffect effect) => switch (effect) {
        SosLocationOwnershipEffect.activateSosLocation =>
          _trackingOwnerArbiter.addOwner(AndroidTrackingOwner.sos),
        SosLocationOwnershipEffect.deactivateSosLocation =>
          _trackingOwnerArbiter.removeOwner(AndroidTrackingOwner.sos),
      };

  @override
  Future<void> reconcile(
    bool desiredOwnership,
    SosLocationOwnershipReconciliationReason reason,
  ) async {
    final hasSosOwner =
        _trackingOwnerArbiter.hasOwner(AndroidTrackingOwner.sos);
    if (desiredOwnership && !hasSosOwner) {
      await _trackingOwnerArbiter.addOwner(AndroidTrackingOwner.sos);
      return;
    }
    if (!desiredOwnership && hasSosOwner) {
      await _trackingOwnerArbiter.removeOwner(AndroidTrackingOwner.sos);
      return;
    }
    if (desiredOwnership) {
      await _trackingOwnerArbiter.reconcile();
    }
  }
}

final class IosSosLocationOwnershipEffectSink
    implements
        SosLocationOwnershipEffectSink,
        SosLocationOwnershipReconciler,
        SosLocationOwnershipPlatformStateProvider {
  IosSosLocationOwnershipEffectSink({
    required BackgroundLocationPlatformAdapter platformAdapter,
  }) : _platformAdapter = platformAdapter;

  final BackgroundLocationPlatformAdapter _platformAdapter;
  bool? _requestedOwnership;
  BackgroundLocationRuntimeStatus? _lastStatus;

  @override
  SosLocationOwnershipPlatformState get platformState {
    final status = _lastStatus;
    return SosLocationOwnershipPlatformState(
      requestedOwnership: _requestedOwnership,
      appliedOwnership:
          status?.activeContexts.contains(BackgroundLocationContext.sos),
      running: status?.isNativeServiceRunning,
    );
  }

  @override
  Future<void> apply(SosLocationOwnershipEffect effect) async {
    final active = effect == SosLocationOwnershipEffect.activateSosLocation;
    _requestedOwnership = active;
    _lastStatus = await _platformAdapter.setBackgroundLocationContext(
      BackgroundLocationContext.sos,
      active: active,
    );
    _traceIosContexts('effect', desiredOwnership: active);
  }

  @override
  Future<void> reconcile(
    bool desiredOwnership,
    SosLocationOwnershipReconciliationReason reason,
  ) async {
    _requestedOwnership = desiredOwnership;
    final status = await _platformAdapter.getBackgroundLocationStatus();
    _lastStatus = status;
    final hasSos =
        status.activeContexts.contains(BackgroundLocationContext.sos);
    if (hasSos == desiredOwnership) {
      _traceIosContexts('reconcile_unchanged',
          desiredOwnership: desiredOwnership);
      return;
    }
    _lastStatus = await _platformAdapter.setBackgroundLocationContext(
      BackgroundLocationContext.sos,
      active: desiredOwnership,
    );
    _traceIosContexts('reconcile_applied', desiredOwnership: desiredOwnership);
  }

  void _traceIosContexts(
    String action, {
    required bool desiredOwnership,
  }) {
    final status = _lastStatus;
    final contexts =
        status?.activeContexts.map((context) => context.name).toList() ?? [];
    contexts.sort();
    SosLocationTrace.emit('ios_context', {
      'action': action,
      'requested_context': BackgroundLocationContext.sos.name,
      'desired': desiredOwnership,
      'active_contexts': contexts.isEmpty ? 'none' : contexts.join(','),
      'sos_active':
          status?.activeContexts.contains(BackgroundLocationContext.sos),
      'sharing_active':
          status?.activeContexts.contains(BackgroundLocationContext.sharing),
      'running': status?.isNativeServiceRunning,
    });
  }
}

SosLocationOwnershipEffectSink createSosLocationOwnershipEffectSink({
  TargetPlatform? platform,
  bool? isWeb,
  required SosLocationOwnershipEffectMode effectMode,
  required AndroidTrackingOwnerArbiter trackingOwnerArbiter,
  required BackgroundLocationPlatformAdapter backgroundLocationPlatformAdapter,
}) {
  if (effectMode == SosLocationOwnershipEffectMode.disabled) {
    return const NoopSosLocationOwnershipEffectSink();
  }
  if (effectMode == SosLocationOwnershipEffectMode.observe) {
    return ObservingSosLocationOwnershipEffectSink();
  }
  if (isWeb ?? kIsWeb) {
    return const NoopSosLocationOwnershipEffectSink();
  }
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => AndroidSosLocationOwnershipEffectSink(
        trackingOwnerArbiter: trackingOwnerArbiter,
      ),
    TargetPlatform.iOS => IosSosLocationOwnershipEffectSink(
        platformAdapter: backgroundLocationPlatformAdapter,
      ),
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows =>
      const NoopSosLocationOwnershipEffectSink(),
  };
}
