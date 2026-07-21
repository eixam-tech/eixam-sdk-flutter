import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('umbrella entrypoint exports documented public models', () {
    const publicTypes = <Type>[
      PreferredDeviceReconnectResult,
      PreferredDeviceReconnectResultStatus,
      SosHistoryItem,
      SosHistoryPage,
      SosHistoryTelemetry,
      SosIncidentProgress,
      SosProgressState,
      SosProgressStep,
      SosProgressStepType,
    ];

    expect(publicTypes, hasLength(9));
    expect(publicTypes.toSet(), hasLength(publicTypes.length));
  });
}
