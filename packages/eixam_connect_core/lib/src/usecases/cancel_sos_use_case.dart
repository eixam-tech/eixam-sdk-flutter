import '../entities/sos_incident.dart';
import '../interfaces/sos_repository.dart';

class CancelSosUseCase {
  final SosRepository repository;

  const CancelSosUseCase(this.repository);

  Future<SosIncident> call() {
    return repository.cancelSos();
  }
}
