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
    if (response.statusCode == 429) {
      throw NetworkException('E_SDK_ME_RATE_LIMITED', response.body);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NetworkException('E_SDK_ME_FAILED', response.body);
    }

    try {
      final payload = SdkMeResponseParser.decodePayload(response.body);
      final ids = SdkMeResponseParser.readIdentityIds(payload);
      return session.copyWith(
        sdkUserId: ids.sdkUserId,
        canonicalExternalUserId: ids.canonicalExternalUserId,
      );
    } on FormatException catch (e) {
      throw AuthException(
        'E_SDK_ME_INVALID_RESPONSE',
        e.message,
      );
    }
  }
}
