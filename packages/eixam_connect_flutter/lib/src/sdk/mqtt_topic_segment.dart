import 'package:eixam_connect_core/eixam_connect_core.dart';

class MqttTopicSegment {
  static String encode(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const AuthException(
        'E_SDK_CANONICAL_EXTERNAL_USER_ID_REQUIRED',
        'A canonical external user id is required before building MQTT topics.',
      );
    }
    return Uri.encodeComponent(trimmed);
  }

  static String canonicalExternalUserIdFrom(EixamSession session) {
    final value = session.canonicalExternalUserId;
    if (value == null || value.trim().isEmpty) {
      throw const AuthException(
        'E_SDK_CANONICAL_EXTERNAL_USER_ID_REQUIRED',
        'Call GET /v1/sdk/me and persist user.external_user_id before using MQTT user-scoped topics.',
      );
    }
    return value.trim();
  }
}
