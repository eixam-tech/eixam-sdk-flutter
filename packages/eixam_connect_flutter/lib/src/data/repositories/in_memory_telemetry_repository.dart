import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'telemetry_repository.dart';

class InMemoryTelemetryRepository implements TelemetryRepository {
  final List<SdkTelemetryPayload> publishedPayloads = <SdkTelemetryPayload>[];

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    publishedPayloads.add(payload);
  }

  @override
  Future<void> publishTelemetryBatch(
    Iterable<SdkTelemetryPayload> payloads,
  ) async {
    for (final payload in payloads) {
      await publishTelemetry(payload);
    }
  }
}
