import '../interfaces/guided_rescue_repository.dart';

class RequestGuidedRescuePositionUseCase {
  const RequestGuidedRescuePositionUseCase(this.repository);

  final GuidedRescueRepository repository;

  Future<void> call() => repository.requestGuidedRescuePosition();
}
