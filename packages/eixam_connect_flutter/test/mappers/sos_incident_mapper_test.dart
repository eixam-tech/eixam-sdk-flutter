import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/mappers/sos_incident_mapper.dart';

void main() {
  group('SosIncidentMapper', () {
    test('maps DTOs into domain incidents', () {
      const dto = SosIncidentDto(
        id: 'remote-1',
        state: 'acknowledged',
        createdAt: '2026-03-24T09:00:00.000Z',
        triggerSource: 'backend',
        message: 'Incident acknowledged',
        positionSnapshot: <String, dynamic>{
          'latitude': 41.38,
          'longitude': 2.17,
          'source': 'mobile',
          'timestamp': '2026-03-24T08:59:00.000Z',
        },
      );

      final incident = const SosIncidentMapper().toDomain(dto);

      expect(incident.id, dto.id);
      expect(incident.state, SosState.acknowledged);
      expect(incident.triggerSource, dto.triggerSource);
      expect(incident.message, dto.message);
      expect(incident.positionSnapshot, isNotNull);
      expect(incident.positionSnapshot?.source, DeliveryMode.mobile);
    });

    test('falls back to failed when dto state is unknown', () {
      const dto = SosIncidentDto(
        id: 'remote-2',
        state: 'mystery_state',
        createdAt: '2026-03-24T09:00:00.000Z',
      );

      final incident = const SosIncidentMapper().toDomain(dto);

      expect(incident.state, SosState.failed);
    });
  });
}
