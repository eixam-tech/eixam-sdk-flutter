import '../interfaces/guided_rescue_repository.dart';

class AcknowledgeGuidedRescueSosUseCase {
  const AcknowledgeGuidedRescueSosUseCase(this.repository);

  final GuidedRescueRepository repository;

  Future<void> call() => repository.acknowledgeGuidedRescueSos();
}
