import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Extension point for Guided Rescue Phase 1 orchestration.
///
/// TODO: wire this to the BLE/runtime/backend rescue flow once the
/// command/status pipeline is implemented beyond the current contract layer.
abstract class GuidedRescueRuntime {
  Future<GuidedRescueState> getCurrentState();
  Stream<GuidedRescueState> watchState();
  Future<GuidedRescueState> setSession({
    required int targetNodeId,
    required int rescueNodeId,
  });
  Future<void> clearSession();
  Future<void> requestPosition();
  Future<void> acknowledgeSos();
  Future<void> enableBuzzer();
  Future<void> disableBuzzer();
  Future<void> requestStatus();
}
