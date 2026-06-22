import '../entities/sos_incident.dart';
import '../interfaces/sos_repository.dart';

class CancelSosUseCase {

  const CancelSosUseCase(this.repository);
  final SosRepository repository;

  Future<SosIncident> call() {
    return repository.cancelSos();
  }
}
