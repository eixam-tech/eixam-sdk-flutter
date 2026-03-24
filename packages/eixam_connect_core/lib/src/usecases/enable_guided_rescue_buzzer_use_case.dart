import '../interfaces/guided_rescue_repository.dart';

class EnableGuidedRescueBuzzerUseCase {
  const EnableGuidedRescueBuzzerUseCase(this.repository);

  final GuidedRescueRepository repository;

  Future<void> call() => repository.enableGuidedRescueBuzzer();
}
