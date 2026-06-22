import '../enums/sos_state.dart';
import '../interfaces/sos_repository.dart';

class GetSosStateUseCase {

  const GetSosStateUseCase(this.repository);
  final SosRepository repository;

  Future<SosState> call() => repository.getSosState();
}
