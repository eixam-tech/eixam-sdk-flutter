import '../interfaces/guided_rescue_repository.dart';

class ClearGuidedRescueSessionUseCase {
  const ClearGuidedRescueSessionUseCase(this.repository);

  final GuidedRescueRepository repository;

  Future<void> call() => repository.clearGuidedRescueSession();
}
