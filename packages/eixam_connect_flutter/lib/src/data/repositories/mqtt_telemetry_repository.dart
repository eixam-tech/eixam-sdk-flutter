import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../sdk/operational_realtime_client.dart';
import 'telemetry_repository.dart';

class MqttTelemetryRepository implements TelemetryRepository {
  MqttTelemetryRepository({
    required this.realtimeClient,
  });

  final OperationalRealtimeClient realtimeClient;

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) {
    _validate(payload);
    return realtimeClient.publishTelemetry(payload);
  }

  void _validate(SdkTelemetryPayload payload) {
    if (!_isFinite(payload.latitude) ||
        payload.latitude < -90 ||
        payload.latitude > 90) {
      throw const TrackingException(
        'E_TELEMETRY_LATITUDE_INVALID',
        'Telemetry latitude must be a finite value between -90 and 90.',
      );
    }
    if (!_isFinite(payload.longitude) ||
        payload.longitude < -180 ||
        payload.longitude > 180) {
      throw const TrackingException(
        'E_TELEMETRY_LONGITUDE_INVALID',
        'Telemetry longitude must be a finite value between -180 and 180.',
      );
    }
    if (!_isFinite(payload.altitude)) {
      throw const TrackingException(
        'E_TELEMETRY_ALTITUDE_INVALID',
        'Telemetry altitude must be a finite value.',
      );
    }
  }

  bool _isFinite(double value) => value.isFinite && !value.isNaN;
}
