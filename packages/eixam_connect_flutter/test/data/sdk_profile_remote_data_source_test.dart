import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_profile_remote_data_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('SdkProfileHttpSupport', () {
    test('parses ErrorEnvelope code and message', () {
      final env = SdkProfileHttpSupport.tryParseErrorEnvelope(
        '{"error":{"code":"bad_phone","message":"invalid phone"}}',
      );
      expect(env?.code, 'bad_phone');
      expect(env?.message, 'invalid phone');
    });

    test('infers phone field hint from message', () {
      final hints = SdkProfileHttpSupport.fieldHintsFromEnvelope(
        SdkProfileErrorEnvelope(code: 'validation', message: 'invalid phone'),
        '',
      );
      expect(hints.single.field, SdkProfileFieldKey.phone);
    });

    test('maps 400 responses to profile validation exception', () {
      final error = SdkProfileHttpSupport.tryMapHttpFailure(
        http.Response(
          '{"error":{"code":"bad_phone","message":"invalid phone"}}',
          400,
        ),
      );

      expect(error, isNotNull);
      expect(error!.code, 'E_SDK_ME_VALIDATION');
      expect(error.statusCode, 400);
      expect(error.apiErrorCode, 'bad_phone');
      expect(error.fieldHints.single.field, SdkProfileFieldKey.phone);
    });

    test('maps 429 responses to rate limit exception', () {
      final error = SdkProfileHttpSupport.tryMapHttpFailure(
        http.Response(
          '{"error":{"code":"rate_limited","message":"too many requests"}}',
          429,
        ),
      );

      expect(error, isNotNull);
      expect(error!.code, 'E_SDK_ME_RATE_LIMITED');
      expect(error.statusCode, 429);
      expect(error.apiErrorCode, 'rate_limited');
    });

    test('returns null for success responses', () {
      final error = SdkProfileHttpSupport.tryMapHttpFailure(
        http.Response('{"user":{}}', 200),
      );

      expect(error, isNull);
    });
  });
}
