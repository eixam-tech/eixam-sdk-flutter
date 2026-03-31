import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';

import 'sdk_mqtt_contract.dart';

abstract class OperationalRealtimeClient implements RealtimeClient {
  Future<void> publishOperationalSos(MqttOperationalSosRequest request);
  Future<void> publishTelemetry(SdkTelemetryPayload payload);
  Future<void> reconnectIfSessionChanged(EixamSession session);
}
