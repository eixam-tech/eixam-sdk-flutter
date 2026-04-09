import 'dart:convert';
import 'dart:io';

import 'package:eixam_control_app/src/features/operational_demo/validation_session_signer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generateUserHash posts app_id and user_id to sign endpoint', () async {
    late Map<String, dynamic> payload;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    server.listen((request) async {
      expect(request.uri.path, '/v1/auth/sign');
      expect(request.method, 'POST');
      final body = await utf8.decodeStream(request);
      payload = body.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(body) as Map);
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"user_hash":"signed-staging-user-hash"}');
      await request.response.close();
    });

    final signer = ValidationSessionSigner();
    final userHash = await signer.generateUserHash(
      apiBaseUrl: 'http://${server.address.host}:${server.port}',
      appId: 'app_u8eetxk3kqgf',
      externalUserId: 'eixam-staging-20260409-134512-034',
    );

    expect(userHash, 'signed-staging-user-hash');
    expect(payload, <String, dynamic>{
      'app_id': 'app_u8eetxk3kqgf',
      'user_id': 'eixam-staging-20260409-134512-034',
    });
  });

  test('generateUserHash accepts nested user_hash payloads', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);

    server.listen((request) async {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"data":{"user_hash":"nested-value"}}');
      await request.response.close();
    });

    final signer = ValidationSessionSigner();
    final userHash = await signer.generateUserHash(
      apiBaseUrl: 'http://${server.address.host}:${server.port}',
      appId: 'app_u8eetxk3kqgf',
      externalUserId: 'user',
    );

    expect(userHash, 'nested-value');
  });
}
