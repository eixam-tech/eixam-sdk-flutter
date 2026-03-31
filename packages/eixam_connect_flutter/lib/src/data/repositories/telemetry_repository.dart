import 'package:eixam_connect_core/eixam_connect_core.dart';

abstract class TelemetryRepository {
  Future<void> publishTelemetry(SdkTelemetryPayload payload);
}
