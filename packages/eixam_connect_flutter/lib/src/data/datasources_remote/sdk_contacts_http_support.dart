import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

/// Maps HTTP failures for `/v1/sdk/contacts` to [ContactsHttpException].
abstract final class SdkContactsHttpSupport {
  static ContactsHttpException? tryMapHttpFailure(
    http.Response response, {
    required String defaultCode,
  }) {
    final statusCode = response.statusCode;
    if (statusCode >= 200 && statusCode < 300) {
      return null;
    }
    final bodyStr = response.body;
    final envelope = _tryParseErrorEnvelope(bodyStr);
    final code = _errorCodeForStatus(statusCode, defaultCode: defaultCode);
    return ContactsHttpException(
      code,
      envelope?.message ?? bodyStr,
      statusCode: statusCode,
      rawBody: bodyStr,
      apiErrorCode: envelope?.code,
      apiErrorMessage: envelope?.message,
    );
  }

  static _ContactErrorEnvelope? _tryParseErrorEnvelope(String body) {
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
      return _ContactErrorEnvelope(
        code: code is String ? code : null,
        message: message is String ? message : null,
      );
    } on FormatException {
      return null;
    }
  }

  static String _errorCodeForStatus(
    int statusCode, {
    required String defaultCode,
  }) {
    return switch (statusCode) {
      400 => 'E_SDK_CONTACTS_VALIDATION',
      401 => 'E_SDK_CONTACTS_UNAUTHORIZED',
      404 => 'E_SDK_CONTACTS_NOT_FOUND',
      _ => defaultCode,
    };
  }
}

class _ContactErrorEnvelope {
  const _ContactErrorEnvelope({this.code, this.message});

  final String? code;
  final String? message;
}
