import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

import '../support/builders/sos_incident_builder.dart';
import '../support/fakes/fake_sos_repository.dart';

void main() {
  group('CancelSosUseCase', () {
    test('forwards the cancel reason to the repository and returns the incident', () async {
      final incident = buildSosIncident(state: SosState.cancelled);
      final repository = FakeSosRepository(cancelResult: incident);
      final useCase = CancelSosUseCase(repository);

      final result = await useCase(reason: 'User cancelled');

      expect(result, same(incident));
      expect(repository.lastCancelReason, 'User cancelled');
    });
  });
}
