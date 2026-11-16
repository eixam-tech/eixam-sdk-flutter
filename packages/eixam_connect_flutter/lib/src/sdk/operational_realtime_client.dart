import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';

import 'sdk_mqtt_contract.dart';

abstract class OperationalRealtimeClient implements RealtimeClient {
  Future<void> publishOperationalSos(MqttOperationalSosRequest request);

  /// Publishes `cancel: true` on the user's SOS alerts topic. Completes only
  /// on the broker PUBACK; backend confirmation arrives as a `cancelled`
  /// event or is read from the active-SOS endpoint.
  Future<void> publishOperationalSosCancel({required DateTime timestamp});
  Future<void> publishTelemetry(SdkTelemetryPayload payload);
  Future<void> reconnectIfSessionChanged(EixamSession session);
}
