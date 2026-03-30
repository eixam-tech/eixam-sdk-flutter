import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

class SdkMqttConnectRequest {
  const SdkMqttConnectRequest({
    required this.brokerUri,
    required this.clientIdentifier,
    required this.userProperties,
  });

  final Uri brokerUri;
  final String clientIdentifier;
  final Map<String, String> userProperties;
}

class SdkMqttEnvelope {
  const SdkMqttEnvelope({
    required this.topic,
    required this.payload,
  });

  final String topic;
  final String payload;
}

class MqttOperationalSosRequest {
  const MqttOperationalSosRequest({
    required this.timestamp,
    required this.positionSnapshot,
    this.sdkUserId,
  });

  final DateTime timestamp;
  final TrackingPosition positionSnapshot;
  final String? sdkUserId;

  MqttOperationalSosRequest copyWith({
    DateTime? timestamp,
    TrackingPosition? positionSnapshot,
    Object? sdkUserId = _unset,
  }) {
    return MqttOperationalSosRequest(
      timestamp: timestamp ?? this.timestamp,
      positionSnapshot: positionSnapshot ?? this.positionSnapshot,
      sdkUserId:
          identical(sdkUserId, _unset) ? this.sdkUserId : sdkUserId as String?,
    );
  }

  static const Object _unset = Object();
}

class SdkMqttTopics {
  static const String sosAlerts = 'sos/alerts';

  static Set<String> eventTopicsFor(EixamSession session) {
    final topics = <String>{};
    if (session.sdkUserId != null && session.sdkUserId!.trim().isNotEmpty) {
      topics.add('sos/events/${session.sdkUserId!.trim()}');
    }

    // Backend docs still reference sdkUserId here, but the signed-session
    // contract now allows MQTT bootstrap without /v1/sdk/me. Keep the fallback
    // isolated until backend confirms the final event-topic identifier.
    topics.add('sos/events/${session.externalUserId}');
    return topics;
  }
}

class SdkMqttContract {
  static SdkMqttConnectRequest connectRequest({
    required EixamSdkConfig config,
    required EixamSession session,
  }) {
    final brokerUri = Uri.parse(config.websocketUrl ?? config.apiBaseUrl);
    return SdkMqttConnectRequest(
      brokerUri: brokerUri,
      clientIdentifier: _clientIdentifierFor(session),
      userProperties: <String, String>{
        'x_app_id': session.appId,
        'x_user_id': session.externalUserId,
        'authorization': 'Bearer ${session.userHash}',
      },
    );
  }

  static SdkMqttEnvelope buildOperationalSosEnvelope(
    MqttOperationalSosRequest request,
  ) {
    final payload = <String, dynamic>{
      'timestamp': request.timestamp.toUtc().toIso8601String(),
      'latitude': request.positionSnapshot.latitude,
      'longitude': request.positionSnapshot.longitude,
      'altitude': request.positionSnapshot.altitude ?? 0.0,
      if (request.sdkUserId != null && request.sdkUserId!.trim().isNotEmpty)
        'userId': request.sdkUserId!.trim(),
    };

    return SdkMqttEnvelope(
      topic: SdkMqttTopics.sosAlerts,
      payload: jsonEncode(payload),
    );
  }

  static RealtimeEvent parseRealtimeEvent({
    required String topic,
    required String payload,
  }) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final type = decoded['type'] as String? ??
            decoded['status'] as String? ??
            'mqtt.message';
        final occurredAtRaw =
            decoded['updatedAt'] ?? decoded['occurredAt'] ?? decoded['openedAt'];
        final occurredAt = occurredAtRaw is String
            ? DateTime.tryParse(occurredAtRaw)?.toUtc()
            : null;
        return RealtimeEvent(
          type: type,
          timestamp: occurredAt ?? DateTime.now().toUtc(),
          payload: <String, dynamic>{
            ...decoded,
            'topic': topic,
          },
        );
      }
    } catch (_) {
      // Preserve the raw message as an opaque realtime event.
    }

    return RealtimeEvent(
      type: 'mqtt.message',
      timestamp: DateTime.now().toUtc(),
      payload: <String, dynamic>{
        'topic': topic,
        'rawPayload': payload,
      },
    );
  }

  static String _clientIdentifierFor(EixamSession session) {
    final appPart = _sanitizeIdentifier(session.appId);
    final userPart = _sanitizeIdentifier(session.externalUserId);
    final raw = 'eixam_$appPart\_$userPart';
    return raw.length <= 64 ? raw : raw.substring(0, 64);
  }

  static String _sanitizeIdentifier(String input) {
    return input.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }
}
