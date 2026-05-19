import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/ble_debug_registry.dart';
import '../../sdk/operational_realtime_client.dart';
import '../../sdk/sos_backend_identity_normalizer.dart';
import 'telemetry_repository.dart';

class MqttTelemetryRepository implements TelemetryRepository {
  MqttTelemetryRepository({
    required this.realtimeClient,
  });

  final OperationalRealtimeClient realtimeClient;

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) {
    final identity = normalizeTelemetryBackendIdentity(payload: payload);
    if (identity.normalized) {
      BleDebugRegistry.instance.recordEvent(
        'BACKEND_DEVICE_ID_NORMALIZED '
        'previousDeviceId=${identity.previousDeviceId} '
        'normalizedDeviceId=${identity.payload.deviceId} source=telemetry',
      );
    }
    if (identity.invalidDeviceId) {
      BleDebugRegistry.instance.recordEvent(
        'BACKEND_DEVICE_ID_INVALID '
        'invalidBackendDeviceId=${identity.previousDeviceId} source=telemetry',
      );
    }
    BleDebugRegistry.instance.recordEvent(
      'TELEMETRY_BACKEND_PAYLOAD_FINAL source=mqtt '
      'deviceId=${identity.payload.deviceId ?? "none"} '
      'nodeId=${identity.nodeId?.toString() ?? "none"} '
      'hardwareId=${identity.payload.hardwareId ?? "none"} '
      'identitySource=${identity.identitySource} '
      'lat=${identity.payload.latitude} lon=${identity.payload.longitude} '
      'timestamp=${identity.payload.timestamp.toUtc().toIso8601String()}',
    );
    _validate(identity.payload);
    return realtimeClient.publishTelemetry(identity.payload);
  }

  @override
  Future<void> publishTelemetryBatch(
    Iterable<SdkTelemetryPayload> payloads,
  ) async {
    for (final payload in payloads) {
      await publishTelemetry(payload);
    }
  }

  void _validate(SdkTelemetryPayload payload) {
    final source = payload.identitySource?.trim().toLowerCase();
    if (source == 'cached_fallback' ||
        source == 'backend_snapshot' ||
        source == 'remote_relay') {
      throw TrackingException(
        'E_TELEMETRY_SOURCE_NOT_PUBLISHABLE',
        'Telemetry source ${payload.identitySource} is not valid for live telemetry publish.',
      );
    }
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
    if (payload.latitude == 0 && payload.longitude == 0) {
      throw const TrackingException(
        'E_TELEMETRY_COORDINATES_INVALID',
        'Telemetry coordinates must not be 0,0.',
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
