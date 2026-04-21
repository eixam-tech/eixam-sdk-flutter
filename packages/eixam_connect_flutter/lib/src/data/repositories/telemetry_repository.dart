import 'package:eixam_connect_core/eixam_connect_core.dart';

abstract class TelemetryRepository {
  Future<void> publishTelemetry(SdkTelemetryPayload payload);

  Future<void> publishTelemetryBatch(
      Iterable<SdkTelemetryPayload> payloads) async {
    for (final payload in payloads) {
      await publishTelemetry(payload);
    }
  }
}
