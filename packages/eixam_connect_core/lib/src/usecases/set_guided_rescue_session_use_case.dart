import '../entities/guided_rescue_state.dart';
import '../interfaces/guided_rescue_repository.dart';

class SetGuidedRescueSessionUseCase {
  const SetGuidedRescueSessionUseCase(this.repository);

  final GuidedRescueRepository repository;

  Future<GuidedRescueState> call({
    required int targetNodeId,
    required int rescueNodeId,
  }) {
    return repository.setGuidedRescueSession(
      targetNodeId: targetNodeId,
      rescueNodeId: rescueNodeId,
    );
  }
}
