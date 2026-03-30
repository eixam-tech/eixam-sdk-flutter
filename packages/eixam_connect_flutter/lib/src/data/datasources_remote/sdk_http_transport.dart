import 'dart:convert';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:http/http.dart' as http;

import 'sdk_session_context.dart';

/// Shared authenticated HTTP transport for production SDK requests.
class SdkHttpTransport {
  SdkHttpTransport({
    required this.client,
    required this.config,
    required this.sessionContext,
  });

  final http.Client client;
  final EixamSdkConfig config;
  final SdkSessionContext sessionContext;

  Future<Map<String, dynamic>> getJson(
    String path, {
    EixamSession? sessionOverride,
  }) async {
    final response = await get(
      path,
      sessionOverride: sessionOverride,
      headers: const <String, String>{'Accept': 'application/json'},
    );
    return _decodeJson(response);
  }

  Future<Map<String, dynamic>> postJson(
    String path, {
    Map<String, dynamic>? body,
    EixamSession? sessionOverride,
  }) async {
    final response = await post(
      path,
      sessionOverride: sessionOverride,
      headers: const <String, String>{'Accept': 'application/json'},
      body: body == null ? null : jsonEncode(body),
    );
    return _decodeJson(response);
  }

  Future<http.Response> get(
    String path, {
    Map<String, String>? headers,
    EixamSession? sessionOverride,
  }) async {
    final session = _resolveSession(sessionOverride);
    try {
      return await client.get(
        _resolveUri(path),
        headers: _headersFor(session, extra: headers),
      );
    } on SocketException catch (error) {
      throw NetworkException('E_SDK_HTTP_GET_FAILED', error.message);
    } on http.ClientException catch (error) {
      throw NetworkException('E_SDK_HTTP_GET_FAILED', error.message);
    }
  }

  Future<http.Response> post(
    String path, {
    Map<String, String>? headers,
    Object? body,
    EixamSession? sessionOverride,
  }) async {
    final session = _resolveSession(sessionOverride);
    try {
      return await client.post(
        _resolveUri(path),
        headers: _headersFor(session, extra: headers),
        body: body,
      );
    } on SocketException catch (error) {
      throw NetworkException('E_SDK_HTTP_POST_FAILED', error.message);
    } on http.ClientException catch (error) {
      throw NetworkException('E_SDK_HTTP_POST_FAILED', error.message);
    }
  }

  Uri _resolveUri(String path) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('${config.apiBaseUrl}$normalizedPath');
  }

  EixamSession _resolveSession(EixamSession? sessionOverride) {
    final session = sessionOverride ?? sessionContext.currentSession;
    if (session == null) {
      throw const AuthException(
        'E_SDK_SESSION_REQUIRED',
        'An SDK session must be configured before calling authenticated routes.',
      );
    }
    return session;
  }

  Map<String, String> _headersFor(
    EixamSession session, {
    Map<String, String>? extra,
  }) {
    return <String, String>{
      'Content-Type': 'application/json',
      'X-App-ID': session.appId,
      'X-User-ID': session.externalUserId,
      'Authorization': 'Bearer ${session.userHash}',
      if (extra != null) ...extra,
    };
  }

  Map<String, dynamic> _decodeJson(http.Response response) {
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    final Object decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const NetworkException(
        'E_SDK_HTTP_INVALID_JSON',
        'The backend returned invalid JSON.',
      );
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    throw const NetworkException(
      'E_SDK_HTTP_INVALID_JSON',
      'The backend returned an unexpected JSON payload.',
    );
  }
}
