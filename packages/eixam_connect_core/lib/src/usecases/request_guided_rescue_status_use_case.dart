import '../interfaces/guided_rescue_repository.dart';

class RequestGuidedRescueStatusUseCase {
  const RequestGuidedRescueStatusUseCase(this.repository);

  final GuidedRescueRepository repository;

  Future<void> call() => repository.requestGuidedRescueStatus();
}
