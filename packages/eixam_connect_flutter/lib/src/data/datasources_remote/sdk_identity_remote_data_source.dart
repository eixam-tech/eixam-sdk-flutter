import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import 'sdk_http_transport.dart';

abstract class SdkIdentityRemoteDataSource {
  Future<EixamSession> bootstrapSession(EixamSession session);
}

/// Optional enrichment for the authenticated SDK identity.
///
/// This is useful for profile/bootstrap reads such as resolving `sdkUserId`
/// and the canonical `external_user_id` from `/v1/sdk/me`.
class HttpSdkIdentityRemoteDataSource implements SdkIdentityRemoteDataSource {
  HttpSdkIdentityRemoteDataSource({required this.transport});

  final SdkHttpTransport transport;

  @override
  Future<EixamSession> bootstrapSession(EixamSession session) async {
    final response = await transport.get(
      '/v1/sdk/me',
      sessionOverride: session,
      headers: const <String, String>{'Accept': 'application/json'},
    );

    if (response.statusCode == 401) {
      throw AuthException('E_SDK_ME_UNAUTHORIZED', response.body);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NetworkException('E_SDK_ME_FAILED', response.body);
    }

    final Object decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const AuthException(
        'E_SDK_ME_INVALID_RESPONSE',
        'The backend did not return valid JSON for the SDK user payload.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const AuthException(
        'E_SDK_ME_INVALID_RESPONSE',
        'The backend did not return a valid SDK user payload.',
      );
    }
    final payload = decoded;
    final user = payload['user'];
    if (user is! Map<String, dynamic>) {
      throw const AuthException(
        'E_SDK_ME_INVALID_RESPONSE',
        'The backend did not return a valid SDK user payload.',
      );
    }

    final sdkUserId = user['id'];
    if (sdkUserId is! String || sdkUserId.trim().isEmpty) {
      throw const AuthException(
        'E_SDK_ME_INVALID_RESPONSE',
        'The backend did not return a valid SDK user id.',
      );
    }

    final canonicalExternalUserId = user['external_user_id'];
    if (canonicalExternalUserId is! String ||
        canonicalExternalUserId.trim().isEmpty) {
      throw const AuthException(
        'E_SDK_ME_INVALID_RESPONSE',
        'The backend did not return a valid canonical external user id.',
      );
    }

    return session.copyWith(
      sdkUserId: sdkUserId.trim(),
      canonicalExternalUserId: canonicalExternalUserId.trim(),
    );
  }
}
