import '../entities/guided_rescue_state.dart';
import '../interfaces/guided_rescue_repository.dart';

class GetGuidedRescueStateUseCase {
  const GetGuidedRescueStateUseCase(this.repository);

  final GuidedRescueRepository repository;

  Future<GuidedRescueState> call() => repository.getGuidedRescueState();
}
