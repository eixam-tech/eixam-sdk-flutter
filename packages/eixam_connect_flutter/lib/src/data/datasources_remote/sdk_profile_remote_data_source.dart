import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import 'sdk_http_transport.dart';

abstract class SdkProfileRemoteDataSource {
  Future<SdkUserProfile> fetchProfile({EixamSession? sessionOverride});

  Future<SdkUserProfile> updateProfile(
    SdkUserProfileUpdate update, {
    EixamSession? sessionOverride,
  });

  Future<void> deleteUserData({required EixamSession sessionOverride});
}

/// HTTP implementation for `GET`/`PUT /v1/sdk/me`.
final class HttpSdkProfileRemoteDataSource
    implements SdkProfileRemoteDataSource {
  HttpSdkProfileRemoteDataSource({required this.transport});

  static const _mePath = '/v1/sdk/me';
  static const _jsonHeaders = <String, String>{'Accept': 'application/json'};

  final SdkHttpTransport transport;

  @override
  Future<SdkUserProfile> fetchProfile({EixamSession? sessionOverride}) async {
    final response = await transport.get(
      _mePath,
      sessionOverride: sessionOverride,
      headers: _jsonHeaders,
    );
    return _readProfileResponse(response);
  }

  @override
  Future<SdkUserProfile> updateProfile(
    SdkUserProfileUpdate update, {
    EixamSession? sessionOverride,
  }) async {
    final response = await transport.put(
      _mePath,
      sessionOverride: sessionOverride,
      headers: _jsonHeaders,
      body: jsonEncode(update.toRequestJson()),
    );
    return _readProfileResponse(response);
  }

  @override
  Future<void> deleteUserData({required EixamSession sessionOverride}) async {
    final response = await transport.delete(
      _mePath,
      sessionOverride: sessionOverride,
    );
    final statusCode = response.statusCode;
    if (statusCode == 404 || (statusCode >= 200 && statusCode < 300)) {
      return;
    }
    final error = SdkProfileHttpSupport.tryMapHttpFailure(response);
    if (error != null) {
      throw error;
    }
  }

  SdkUserProfile _readProfileResponse(http.Response response) {
    final error = SdkProfileHttpSupport.tryMapHttpFailure(response);
    if (error != null) {
      throw error;
    }
    try {
      final payload = SdkMeResponseParser.decodePayload(response.body);
      return SdkMeResponseParser.readProfile(payload);
    } on FormatException catch (e) {
      throw AuthException('E_SDK_ME_INVALID_RESPONSE', e.message);
    }
  }
}

final class SdkProfileErrorEnvelope {
  const SdkProfileErrorEnvelope({this.code, this.message});

  final String? code;
  final String? message;
}

abstract final class SdkProfileHttpSupport {
  static ProfileHttpException? tryMapHttpFailure(http.Response response) {
    final statusCode = response.statusCode;
    if (statusCode >= 200 && statusCode < 300) {
      return null;
    }

    final bodyStr = response.body;
    final envelope = tryParseErrorEnvelope(bodyStr);
    return ProfileHttpException(
      _errorCodeForStatus(statusCode),
      envelope?.message ?? bodyStr,
      statusCode: statusCode,
      rawBody: bodyStr,
      apiErrorCode: envelope?.code,
      apiErrorMessage: envelope?.message,
      fieldHints: fieldHintsFromEnvelope(envelope, bodyStr),
    );
  }

  static SdkProfileErrorEnvelope? tryParseErrorEnvelope(String body) {
    if (body.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final err = decoded['error'];
      if (err is! Map<String, dynamic>) {
        return null;
      }
      final code = err['code'];
      final message = err['message'];
      return SdkProfileErrorEnvelope(
        code: code is String ? code : null,
        message: message is String ? message : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// OpenAPI does not define field paths on [ErrorEnvelope]; only explicit
  /// backend error codes may become field hints.
  static List<SdkProfileApiFieldHint> fieldHintsFromEnvelope(
    SdkProfileErrorEnvelope? envelope,
    String rawFallback,
  ) {
    final code = envelope?.code;
    if (code == null || code.isEmpty) {
      return const [];
    }
    final field = switch (code) {
      'bad_phone' ||
      'invalid_phone' ||
      'phone_invalid' ||
      'phone_invalid_e164' =>
        SdkProfileFieldKey.phone,
      'bad_email' ||
      'invalid_email' ||
      'email_invalid' =>
        SdkProfileFieldKey.email,
      'bad_address' ||
      'invalid_address' ||
      'address_invalid' =>
        SdkProfileFieldKey.address,
      'bad_name' || 'invalid_name' || 'name_invalid' => SdkProfileFieldKey.name,
      _ => null,
    };
    if (field == null) {
      return const [];
    }
    return [SdkProfileApiFieldHint(field: field, message: code)];
  }

  static String _errorCodeForStatus(int statusCode) {
    return switch (statusCode) {
      400 => 'E_SDK_ME_VALIDATION',
      401 => 'E_SDK_ME_UNAUTHORIZED',
      429 => 'E_SDK_ME_RATE_LIMITED',
      _ => 'E_SDK_ME_FAILED',
    };
  }
}
