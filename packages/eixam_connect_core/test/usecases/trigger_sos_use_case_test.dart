import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

import '../support/builders/sos_incident_builder.dart';
import '../support/builders/tracking_position_builder.dart';
import '../support/fakes/fake_sos_repository.dart';

void main() {
  group('TriggerSosUseCase', () {
    test('forwards the request to the repository and returns the incident',
        () async {
      final position = buildTrackingPosition();
      final incident = buildSosIncident(positionSnapshot: position);
      final repository = FakeSosRepository(triggerResult: incident);
      final useCase = TriggerSosUseCase(repository);

      final result = await useCase(
        message: 'Help needed',
        triggerSource: 'device_button',
        positionSnapshot: position,
      );

      expect(result, same(incident));
      expect(repository.lastTriggerMessage, 'Help needed');
      expect(repository.lastTriggerSource, 'device_button');
      expect(repository.lastTriggerPositionSnapshot, same(position));
    });
  });
}
