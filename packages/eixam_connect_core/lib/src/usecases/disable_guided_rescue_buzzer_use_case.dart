import '../interfaces/guided_rescue_repository.dart';

class DisableGuidedRescueBuzzerUseCase {
  const DisableGuidedRescueBuzzerUseCase(this.repository);

  final GuidedRescueRepository repository;

  Future<void> call() => repository.disableGuidedRescueBuzzer();
}
