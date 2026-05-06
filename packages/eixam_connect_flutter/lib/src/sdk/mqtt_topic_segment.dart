import 'package:eixam_connect_core/eixam_connect_core.dart';

class MqttTopicSegment {
  static String encode(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const AuthException(
        'E_SDK_TOPIC_SEGMENT_REQUIRED',
        'A non-empty MQTT topic segment is required.',
      );
    }
    return Uri.encodeComponent(trimmed);
  }

  static String sdkUserIdFrom(EixamSession session) {
    final value = session.sdkUserId;
    if (value == null || value.trim().isEmpty) {
      throw const AuthException(
        'E_SDK_USER_ID_REQUIRED',
        'Call GET /v1/sdk/me and persist user.id before using MQTT user-scoped topics.',
      );
    }
    return value.trim();
  }

  static String legacyUserIdFrom(EixamSession session) {
    final value = session.canonicalExternalUserId?.trim().isNotEmpty == true
        ? session.canonicalExternalUserId
        : session.externalUserId;
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      throw const AuthException(
        'E_SDK_USER_ID_REQUIRED',
        'A non-empty legacy user id is required before using MQTT user-scoped topics.',
      );
    }
    return trimmed;
  }

  static String userTopicSegmentFrom(EixamSession session) {
    final sdkUserId = session.sdkUserId;
    if (sdkUserId != null && sdkUserId.trim().isNotEmpty) {
      return sdkUserId.trim();
    }
    return legacyUserIdFrom(session);
  }

  static bool usesLegacyUserTopics(EixamSession session) {
    final sdkUserId = session.sdkUserId;
    return sdkUserId == null || sdkUserId.trim().isEmpty;
  }
}
