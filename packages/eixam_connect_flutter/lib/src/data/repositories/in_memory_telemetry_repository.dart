import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'telemetry_repository.dart';

class InMemoryTelemetryRepository implements TelemetryRepository {
  final List<SdkTelemetryPayload> publishedPayloads = <SdkTelemetryPayload>[];

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    publishedPayloads.add(payload);
  }
}
