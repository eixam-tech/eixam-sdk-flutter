import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

enum ProtectionPlatformEventType {
  woke,
  runtimeStarted,
  runtimeStopped,
  runtimeRecovered,
  runtimeFailed,
}

class ProtectionPlatformSnapshot {
  const ProtectionPlatformSnapshot({
    required this.backgroundCapabilityReady,
    this.lastWakeAt,
    this.lastWakeReason,
  });

  final bool backgroundCapabilityReady;
  final DateTime? lastWakeAt;
  final String? lastWakeReason;
}

class ProtectionPlatformStartResult {
  const ProtectionPlatformStartResult({
    required this.success,
    this.runtimeState = ProtectionRuntimeState.active,
    this.coverageLevel = ProtectionCoverageLevel.full,
    this.failureReason,
  });

  final bool success;
  final ProtectionRuntimeState runtimeState;
  final ProtectionCoverageLevel coverageLevel;
  final String? failureReason;
}

class ProtectionPermissionResult {
  const ProtectionPermissionResult({
    required this.locationGranted,
    required this.notificationsGranted,
    required this.bluetoothGranted,
  });

  final bool locationGranted;
  final bool notificationsGranted;
  final bool bluetoothGranted;
}

class ProtectionPlatformEvent {
  const ProtectionPlatformEvent({
    required this.type,
    required this.timestamp,
    this.reason,
  });

  final ProtectionPlatformEventType type;
  final DateTime timestamp;
  final String? reason;
}

abstract class ProtectionPlatformAdapter {
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot();
  Future<ProtectionPlatformStartResult> startProtectionRuntime();
  Future<void> stopProtectionRuntime();
  Future<ProtectionPermissionResult> requestProtectionPermissions();
  Future<void> openProtectionSettings();
  Stream<ProtectionPlatformEvent> watchPlatformEvents();
}

class NoopProtectionPlatformAdapter implements ProtectionPlatformAdapter {
  const NoopProtectionPlatformAdapter();

  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async {
    return const ProtectionPlatformSnapshot(
      backgroundCapabilityReady: false,
    );
  }

  @override
  Future<ProtectionPlatformStartResult> startProtectionRuntime() async {
    return const ProtectionPlatformStartResult(
      success: false,
      runtimeState: ProtectionRuntimeState.failed,
      coverageLevel: ProtectionCoverageLevel.none,
      failureReason:
          'Protection Mode platform runtime is not configured in this host app yet.',
    );
  }

  @override
  Future<void> stopProtectionRuntime() async {}

  @override
  Future<ProtectionPermissionResult> requestProtectionPermissions() async {
    return const ProtectionPermissionResult(
      locationGranted: false,
      notificationsGranted: false,
      bluetoothGranted: false,
    );
  }

  @override
  Future<void> openProtectionSettings() async {}

  @override
  Stream<ProtectionPlatformEvent> watchPlatformEvents() =>
      const Stream<ProtectionPlatformEvent>.empty();
}
