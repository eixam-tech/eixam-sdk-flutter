import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'mqtt_topic_segment.dart';
import 'sos_backend_identity_normalizer.dart';

class SdkMqttConnectRequest {
  const SdkMqttConnectRequest({
    required this.brokerUri,
    required this.clientIdentifier,
    required this.username,
    required this.password,
    required this.cleanSession,
  });

  final Uri brokerUri;
  final String clientIdentifier;
  final String username;
  final String password;
  final bool cleanSession;
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
    this.positionSnapshot,
    this.deviceId,
    this.appDeviceId,
    this.hardwareId,
    this.identitySource,
    this.originatorNodeId,
    this.relayNodeId,
    this.relayDeviceId,
    this.relayHardwareId,
    this.source,
    this.incidentId,
    this.cycleKey,
    this.deviceBattery,
    this.deviceCoverage,
    this.mobileBattery,
    this.mobileCoverage,
  });

  final DateTime timestamp;
  final TrackingPosition? positionSnapshot;
  final String? deviceId;
  final String? appDeviceId;
  final String? hardwareId;
  final String? identitySource;
  final int? originatorNodeId;
  final int? relayNodeId;
  final String? relayDeviceId;
  final String? relayHardwareId;
  final String? source;
  final String? incidentId;
  final String? cycleKey;
  final SdkDeviceBatterySnapshot? deviceBattery;
  final SdkCoverageSnapshot? deviceCoverage;
  final int? mobileBattery;
  final SdkCoverageSnapshot? mobileCoverage;

  MqttOperationalSosRequest copyWith({
    DateTime? timestamp,
    TrackingPosition? positionSnapshot,
    Object? deviceId = _unset,
    Object? appDeviceId = _unset,
    Object? hardwareId = _unset,
    Object? identitySource = _unset,
    Object? originatorNodeId = _unset,
    Object? relayNodeId = _unset,
    Object? relayDeviceId = _unset,
    Object? relayHardwareId = _unset,
    Object? source = _unset,
    Object? incidentId = _unset,
    Object? cycleKey = _unset,
    Object? deviceBattery = _unset,
    Object? deviceCoverage = _unset,
    Object? mobileBattery = _unset,
    Object? mobileCoverage = _unset,
  }) {
    return MqttOperationalSosRequest(
      timestamp: timestamp ?? this.timestamp,
      positionSnapshot: positionSnapshot ?? this.positionSnapshot,
      deviceId:
          identical(deviceId, _unset) ? this.deviceId : deviceId as String?,
      appDeviceId: identical(appDeviceId, _unset)
          ? this.appDeviceId
          : appDeviceId as String?,
      hardwareId: identical(hardwareId, _unset)
          ? this.hardwareId
          : hardwareId as String?,
      identitySource: identical(identitySource, _unset)
          ? this.identitySource
          : identitySource as String?,
      originatorNodeId: identical(originatorNodeId, _unset)
          ? this.originatorNodeId
          : originatorNodeId as int?,
      relayNodeId: identical(relayNodeId, _unset)
          ? this.relayNodeId
          : relayNodeId as int?,
      relayDeviceId: identical(relayDeviceId, _unset)
          ? this.relayDeviceId
          : relayDeviceId as String?,
      relayHardwareId: identical(relayHardwareId, _unset)
          ? this.relayHardwareId
          : relayHardwareId as String?,
      source: identical(source, _unset) ? this.source : source as String?,
      incidentId: identical(incidentId, _unset)
          ? this.incidentId
          : incidentId as String?,
      cycleKey:
          identical(cycleKey, _unset) ? this.cycleKey : cycleKey as String?,
      deviceBattery: identical(deviceBattery, _unset)
          ? this.deviceBattery
          : deviceBattery as SdkDeviceBatterySnapshot?,
      deviceCoverage: identical(deviceCoverage, _unset)
          ? this.deviceCoverage
          : deviceCoverage as SdkCoverageSnapshot?,
      mobileBattery: identical(mobileBattery, _unset)
          ? this.mobileBattery
          : mobileBattery as int?,
      mobileCoverage: identical(mobileCoverage, _unset)
          ? this.mobileCoverage
          : mobileCoverage as SdkCoverageSnapshot?,
    );
  }

  static const Object _unset = Object();
}

class SdkMqttTopics {
  static const String legacySosAlerts = 'sos/alerts';
  static const String sosAlerts = legacySosAlerts;

  static String sosAlertsFor(String sdkUserId) {
    return 'sos/alerts/${MqttTopicSegment.encode(sdkUserId)}';
  }

  static String sosAlertsForSession(EixamSession session) {
    if (MqttTopicSegment.usesLegacyUserTopics(session)) {
      return legacySosAlerts;
    }
    return sosAlertsFor(MqttTopicSegment.sdkUserIdFrom(session));
  }

  static String telemetryDataFor(EixamSession session) {
    final userId = MqttTopicSegment.userTopicSegmentFrom(session);
    return 'tel/${MqttTopicSegment.encode(userId)}/data';
  }

  static Set<String> eventTopicsFor(EixamSession session) {
    final topics = <String>{
      'sos/events/${MqttTopicSegment.encode(MqttTopicSegment.userTopicSegmentFrom(session))}',
    };
    final legacyUserId = MqttTopicSegment.legacyUserIdFrom(session);
    if (!MqttTopicSegment.usesLegacyUserTopics(session) &&
        legacyUserId != MqttTopicSegment.sdkUserIdFrom(session)) {
      topics.add('sos/events/${MqttTopicSegment.encode(legacyUserId)}');
    }
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
      username: 'sdk:${session.appId}:${session.externalUserId}',
      password: session.userHash,
      cleanSession: true,
    );
  }

  static SdkMqttEnvelope buildOperationalSosEnvelope({
    required String sdkUserId,
    String? legacyUserId,
    required MqttOperationalSosRequest request,
  }) {
    final topicSDKUserId = sdkUserId.trim();
    final payloadUserId = legacyUserId?.trim();
    final identity = normalizeSosBackendIdentity(
      deviceId: request.deviceId,
      appDeviceId: request.appDeviceId,
      hardwareId: request.hardwareId,
      originatorNodeId: request.originatorNodeId,
      relayNodeId: request.relayNodeId,
      relayDeviceId: request.relayDeviceId,
      incidentId: request.incidentId,
      cycleKey: request.cycleKey,
    );
    final payload = <String, dynamic>{
      'timestamp': request.timestamp.toUtc().toIso8601String(),
      if (request.positionSnapshot != null) ...{
        'latitude': request.positionSnapshot!.latitude,
        'longitude': request.positionSnapshot!.longitude,
        'altitude': request.positionSnapshot!.altitude ?? 0.0,
      },
      if (payloadUserId != null && payloadUserId.isNotEmpty)
        'userId': payloadUserId,
      if (identity.deviceId != null && identity.deviceId!.isNotEmpty)
        'deviceId': identity.deviceId,
      if (identity.appDeviceId != null && identity.appDeviceId!.isNotEmpty)
        'appDeviceId': identity.appDeviceId,
      if (identity.hardwareId != null && identity.hardwareId!.trim().isNotEmpty)
        'hardwareId': identity.hardwareId!.trim(),
      'identitySource': identity.identitySource,
      if (identity.originatorNodeId != null) ...{
        'nodeId': identity.originatorNodeId,
        'originatorNodeId': identity.originatorNodeId,
      },
      if (request.relayNodeId != null) 'relayNodeId': request.relayNodeId,
      if (identity.relayDeviceId != null && identity.relayDeviceId!.isNotEmpty)
        'relayDeviceId': identity.relayDeviceId,
      if (request.relayHardwareId != null &&
          request.relayHardwareId!.trim().isNotEmpty)
        'relayHardwareId': request.relayHardwareId!.trim(),
      if (request.source != null && request.source!.trim().isNotEmpty)
        'source': request.source!.trim(),
      if (request.deviceBattery != null)
        'deviceBattery': request.deviceBattery!.toJson(),
      if (request.deviceCoverage != null)
        'deviceCoverage': request.deviceCoverage!.toJson(),
      if (request.mobileBattery != null)
        'mobileBattery': request.mobileBattery!.clamp(0, 100),
      if (request.mobileCoverage != null)
        'mobileCoverage': request.mobileCoverage!.toJson(),
    };

    return SdkMqttEnvelope(
      topic: topicSDKUserId.isEmpty
          ? SdkMqttTopics.legacySosAlerts
          : SdkMqttTopics.sosAlertsFor(topicSDKUserId),
      payload: jsonEncode(payload),
    );
  }

  static SdkMqttEnvelope buildTelemetryEnvelope({
    required EixamSession session,
    required SdkTelemetryPayload payload,
  }) {
    final identity = normalizeTelemetryBackendIdentity(payload: payload);
    final legacyUserId = MqttTopicSegment.usesLegacyUserTopics(session)
        ? MqttTopicSegment.legacyUserIdFrom(session)
        : null;
    return SdkMqttEnvelope(
      topic: SdkMqttTopics.telemetryDataFor(session),
      payload: jsonEncode(
        identity.payload.copyWith(userId: legacyUserId).toJson(),
      ),
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
        final occurredAtRaw = decoded['updatedAt'] ??
            decoded['occurredAt'] ??
            decoded['openedAt'];
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
    final raw = 'eixam_${appPart}_$userPart';
    return raw.length <= 64 ? raw : raw.substring(0, 64);
  }

  static String _sanitizeIdentifier(String input) {
    return input.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }
}
