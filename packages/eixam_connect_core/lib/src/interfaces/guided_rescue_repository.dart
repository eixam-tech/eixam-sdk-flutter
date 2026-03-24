import '../entities/guided_rescue_state.dart';

/// Contract for Guided Rescue Phase 1 orchestration.
///
/// Implementations should own rescue session context, command dispatch,
/// structured status updates, and action availability. Host apps should only
/// consume the public SDK/state surface built on top of this contract.
abstract class GuidedRescueRepository {
  Future<GuidedRescueState> getGuidedRescueState();
  Stream<GuidedRescueState> watchGuidedRescueState();
  Future<GuidedRescueState> setGuidedRescueSession({
    required int targetNodeId,
    required int rescueNodeId,
  });
  Future<void> clearGuidedRescueSession();
  Future<void> requestGuidedRescuePosition();
  Future<void> acknowledgeGuidedRescueSos();
  Future<void> enableGuidedRescueBuzzer();
  Future<void> disableGuidedRescueBuzzer();
  Future<void> requestGuidedRescueStatus();
}
