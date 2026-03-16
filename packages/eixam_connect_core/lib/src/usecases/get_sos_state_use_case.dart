import '../enums/sos_state.dart';
import '../interfaces/sos_repository.dart';

class GetSosStateUseCase {
  final SosRepository repository;

  const GetSosStateUseCase(this.repository);

  Future<SosState> call() => repository.getSosState();
}
