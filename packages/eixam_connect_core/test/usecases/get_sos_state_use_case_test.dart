import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

import '../support/fakes/fake_sos_repository.dart';

void main() {
  group('GetSosStateUseCase', () {
    test('returns the current SOS state from the repository', () async {
      final repository = FakeSosRepository(initialState: SosState.acknowledged);
      final useCase = GetSosStateUseCase(repository);

      final result = await useCase();

      expect(result, SosState.acknowledged);
    });
  });
}
