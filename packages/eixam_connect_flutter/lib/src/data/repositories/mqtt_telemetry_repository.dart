import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../../device/ble_debug_registry.dart';
import '../../sdk/location_debug_log.dart';
import '../../sdk/operational_realtime_client.dart';
import '../../sdk/sos_backend_identity_normalizer.dart';
import 'telemetry_repository.dart';

class MqttTelemetryRepository implements TelemetryRepository {
  MqttTelemetryRepository({
    required this.realtimeClient,
  });

  final OperationalRealtimeClient realtimeClient;
  final Set<String> _inFlightTelemetryKeys = <String>{};
  final Map<String, DateTime> _recentTelemetryPublishes = <String, DateTime>{};

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    final identity = normalizeTelemetryBackendIdentity(payload: payload);
    final telemetryKey = _telemetryDedupeKey(identity.payload);
    final now = DateTime.now().toUtc();
    _recentTelemetryPublishes.removeWhere(
      (_, seenAt) => now.difference(seenAt) > _recentTelemetryDedupeWindow,
    );
    if (_inFlightTelemetryKeys.contains(telemetryKey) ||
        _recentTelemetryPublishes.containsKey(telemetryKey)) {
      BleDebugRegistry.instance.recordEvent(
        'TELEMETRY_NATIVE_DUPLICATE_SUPPRESSED handoffId=$telemetryKey',
      );
      return;
    }
    _inFlightTelemetryKeys.add(telemetryKey);
    final source = identity.payload.identitySource?.trim().isNotEmpty == true
        ? identity.payload.identitySource!.trim()
        : 'sdk_telemetry';
    try {
      BleDebugRegistry.instance.recordEvent(
        'TELEMETRY_TRANSPORT_DECISION transport=mqtt source=$source '
        'reason=telemetry_must_use_mqtt',
      );
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
      final rejectionReason = _telemetryRejectionReason(identity.payload);
      LocationDebugLog.telemetryPayload(
        flow: 'mqtt_outbound',
        payload: identity.payload,
        accepted: rejectionReason == null,
        rejectionReason: rejectionReason,
        sentToBackend: false,
      );
      _validate(identity.payload);
      LocationDebugLog.telemetryPayload(
        flow: 'mqtt_outbound',
        payload: identity.payload,
        accepted: true,
        sentToBackend: true,
      );
      BleDebugRegistry.instance.recordEvent(
        'TELEMETRY_MQTT_PUBLISH_START source=$source '
        'handoffId=${identity.payload.eventId ?? telemetryKey} incidentId=none',
      );
      await realtimeClient.publishTelemetry(identity.payload);
      _recentTelemetryPublishes[telemetryKey] = DateTime.now().toUtc();
      BleDebugRegistry.instance.recordEvent(
        'TELEMETRY_MQTT_PUBLISH_RESULT source=$source success=true',
      );
    } catch (_) {
      BleDebugRegistry.instance.recordEvent(
        'TELEMETRY_MQTT_PUBLISH_RESULT source=$source success=false',
      );
      rethrow;
    } finally {
      _inFlightTelemetryKeys.remove(telemetryKey);
    }
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
    final rejectionReason = _telemetryRejectionReason(payload);
    if (rejectionReason != null) {
      if (rejectionReason == 'source_not_publishable') {
        throw TrackingException(
          'E_TELEMETRY_SOURCE_NOT_PUBLISHABLE',
          'Telemetry source ${payload.identitySource} is not valid for live telemetry publish.',
        );
      }
      if (rejectionReason == 'invalid_latitude') {
        throw const TrackingException(
          'E_TELEMETRY_LATITUDE_INVALID',
          'Telemetry latitude must be a finite value between -90 and 90.',
        );
      }
      if (rejectionReason == 'invalid_longitude') {
        throw const TrackingException(
          'E_TELEMETRY_LONGITUDE_INVALID',
          'Telemetry longitude must be a finite value between -180 and 180.',
        );
      }
      if (rejectionReason == 'zero_coordinates') {
        throw const TrackingException(
          'E_TELEMETRY_COORDINATES_INVALID',
          'Telemetry coordinates must not be 0,0.',
        );
      }
      if (rejectionReason == 'invalid_altitude') {
        throw const TrackingException(
          'E_TELEMETRY_ALTITUDE_INVALID',
          'Telemetry altitude must be a finite value.',
        );
      }
    }
  }

  String? _telemetryRejectionReason(SdkTelemetryPayload payload) {
    final source = payload.identitySource?.trim().toLowerCase();
    if (source == 'cached_fallback' ||
        source == 'backend_snapshot' ||
        source == 'remote_relay') {
      return 'source_not_publishable';
    }
    if (!_isFinite(payload.latitude) ||
        payload.latitude < -90 ||
        payload.latitude > 90) {
      return 'invalid_latitude';
    }
    if (!_isFinite(payload.longitude) ||
        payload.longitude < -180 ||
        payload.longitude > 180) {
      return 'invalid_longitude';
    }
    if (payload.latitude == 0 && payload.longitude == 0) {
      return 'zero_coordinates';
    }
    if (!_isFinite(payload.altitude)) {
      return 'invalid_altitude';
    }
    return null;
  }

  bool _isFinite(double value) => value.isFinite && !value.isNaN;

  String _telemetryDedupeKey(SdkTelemetryPayload payload) {
    final eventId = payload.eventId?.trim();
    if (eventId != null && eventId.isNotEmpty) {
      return eventId;
    }
    return <String>[
      payload.timestamp.toUtc().toIso8601String(),
      payload.deviceId?.trim().isNotEmpty == true
          ? payload.deviceId!.trim()
          : 'none',
      payload.hardwareId?.trim().isNotEmpty == true
          ? payload.hardwareId!.trim()
          : 'none',
      payload.latitude.toStringAsFixed(6),
      payload.longitude.toStringAsFixed(6),
    ].join(':');
  }

  static const Duration _recentTelemetryDedupeWindow = Duration(minutes: 5);
}
