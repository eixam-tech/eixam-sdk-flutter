import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import 'sdk_http_transport.dart';

abstract class SdkFeedbackRemoteDataSource {
  Future<AppFeedbackSubmission> submitFeedback({
    required EixamSession session,
    required String description,
    required String userAccessToken,
  });
}

final class HttpSdkFeedbackRemoteDataSource
    implements SdkFeedbackRemoteDataSource {
  HttpSdkFeedbackRemoteDataSource({required this.transport});

  static const _feedbackPath = '/v1/feedback';
  static const _maxDescriptionLength = 10000;

  final SdkHttpTransport transport;

  @override
  Future<AppFeedbackSubmission> submitFeedback({
    required EixamSession session,
    required String description,
    required String userAccessToken,
  }) async {
    final trimmedDescription = description.trim();
    if (trimmedDescription.isEmpty) {
      throw const FeedbackException(
        'E_SDK_FEEDBACK_VALIDATION',
        'Feedback description must not be empty.',
      );
    }
    if (trimmedDescription.length > _maxDescriptionLength) {
      throw const FeedbackException(
        'E_SDK_FEEDBACK_VALIDATION',
        'Feedback description must be 10000 characters or fewer.',
      );
    }

    final trimmedToken = userAccessToken.trim();
    if (trimmedToken.isEmpty) {
      throw const AuthException(
        'E_SDK_FEEDBACK_USER_TOKEN_REQUIRED',
        'An authenticated Eixam user JWT is required to submit feedback.',
      );
    }

    final response = await transport.post(
      _feedbackPath,
      sessionOverride: session,
      headers: <String, String>{
        'Accept': 'application/json',
        'Authorization': 'Bearer $trimmedToken',
      },
      body: jsonEncode(<String, dynamic>{
        'app_id': session.appId,
        'sdk_user_id': session.externalUserId,
        'description': trimmedDescription,
      }),
    );
    _ensureSuccess(response);
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('E_SDK_FEEDBACK_INVALID_PAYLOAD');
      }
      return AppFeedbackSubmission.fromJson(decoded);
    } on FormatException catch (error) {
      throw NetworkException('E_SDK_FEEDBACK_INVALID_RESPONSE', error.message);
    }
  }

  static void _ensureSuccess(http.Response response) {
    if (response.statusCode == 201) {
      return;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    final body = response.body;
    final envelope = _tryParseErrorEnvelope(body);
    throw FeedbackHttpException(
      _errorCodeForStatus(response.statusCode),
      envelope?.message ?? body,
      statusCode: response.statusCode,
      rawBody: body,
      apiErrorCode: envelope?.code,
      apiErrorMessage: envelope?.message,
    );
  }

  static _FeedbackErrorEnvelope? _tryParseErrorEnvelope(String body) {
    if (body.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }
      final error = decoded['error'];
      if (error is! Map<String, dynamic>) {
        return null;
      }
      final code = error['code'];
      final message = error['message'];
      return _FeedbackErrorEnvelope(
        code: code is String ? code : null,
        message: message is String ? message : null,
      );
    } on FormatException {
      return null;
    }
  }

  static String _errorCodeForStatus(int statusCode) {
    return switch (statusCode) {
      400 => 'E_SDK_FEEDBACK_VALIDATION',
      401 => 'E_SDK_FEEDBACK_UNAUTHORIZED',
      404 => 'E_SDK_FEEDBACK_NOT_FOUND',
      503 => 'E_SDK_FEEDBACK_UNAVAILABLE',
      _ => 'E_SDK_FEEDBACK_FAILED',
    };
  }
}

final class _FeedbackErrorEnvelope {
  const _FeedbackErrorEnvelope({this.code, this.message});

  final String? code;
  final String? message;
}
