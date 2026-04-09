import 'dart:convert';
import 'dart:io';

typedef ValidationHttpClientFactory = HttpClient Function();

class ValidationSessionSigner {
  ValidationSessionSigner({
    ValidationHttpClientFactory? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final ValidationHttpClientFactory _httpClientFactory;

  Future<String> generateUserHash({
    required String apiBaseUrl,
    required String appId,
    required String externalUserId,
  }) async {
    if (apiBaseUrl.trim().isEmpty) {
      throw StateError(
          'Select a staging backend URL before generating userHash.');
    }
    if (appId.trim().isEmpty || externalUserId.trim().isEmpty) {
      throw StateError(
        'appId and externalUserId are both required before calling /v1/auth/sign.',
      );
    }

    final client = _httpClientFactory();
    try {
      final request = await client.postUrl(
        Uri.parse(apiBaseUrl).resolve('/v1/auth/sign'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, String>{
          'app_id': appId.trim(),
          'user_id': externalUserId.trim(),
        }),
      );

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'Sign request failed with HTTP ${response.statusCode}: $responseBody',
        );
      }

      final payload = _decodePayload(responseBody);
      final userHash = _extractUserHash(payload);
      if (userHash == null || userHash.trim().isEmpty) {
        throw const FormatException(
          'The sign response did not include a user_hash value.',
        );
      }
      return userHash.trim();
    } on SocketException catch (error) {
      throw StateError(
          'Could not reach the staging sign endpoint: ${error.message}');
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _decodePayload(String responseBody) {
    final Object decoded;
    try {
      decoded = jsonDecode(responseBody);
    } catch (_) {
      throw const FormatException(
        'The sign response did not return valid JSON.',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'The sign response did not return a JSON object.',
      );
    }
    return decoded;
  }

  String? _extractUserHash(Map<String, dynamic> payload) {
    final direct =
        payload['user_hash'] ?? payload['userHash'] ?? payload['hash'];
    if (direct is String && direct.trim().isNotEmpty) {
      return direct;
    }

    final data = payload['data'];
    if (data is Map<String, dynamic>) {
      final nested = data['user_hash'] ?? data['userHash'] ?? data['hash'];
      if (nested is String && nested.trim().isNotEmpty) {
        return nested;
      }
    }

    return null;
  }
}
