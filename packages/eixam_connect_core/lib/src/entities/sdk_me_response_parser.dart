import 'dart:convert';

import 'sdk_user_profile.dart';

/// Shared parsing for `GET /v1/sdk/me` JSON (identity bootstrap + profile reads).
abstract final class SdkMeResponseParser {
  static Map<String, dynamic> decodePayload(String responseBody) {
    if (responseBody.isEmpty) {
      throw const FormatException('Empty SDK /me response body');
    }
    final decoded = jsonDecode(responseBody);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('SDK /me response must be a JSON object');
    }
    return decoded;
  }

  /// Values needed to enrich [EixamSession] during bootstrap.
  static ({
    String sdkUserId,
    String canonicalExternalUserId,
  }) readIdentityIds(Map<String, dynamic> payload) {
    final user = payload['user'];
    if (user is! Map<String, dynamic>) {
      throw const FormatException('E_SDK_ME_MISSING_USER_OBJECT');
    }
    final sdkUserId = user['id'];
    final canonicalExternalUserId = user['external_user_id'];
    if (sdkUserId is! String ||
        sdkUserId.trim().isEmpty ||
        canonicalExternalUserId is! String ||
        canonicalExternalUserId.trim().isEmpty) {
      throw const FormatException(
        'E_SDK_ME_MISSING_REQUIRED_IDS',
      );
    }
    return (
      sdkUserId: sdkUserId.trim(),
      canonicalExternalUserId: canonicalExternalUserId.trim(),
    );
  }

  static SdkUserProfile readProfile(Map<String, dynamic> payload) {
    return SdkUserProfile.fromMeResponseJson(payload);
  }
}
