import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_activity_availability_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'availability_test_support.dart';

void main() {
  Future<List<SdkAvailableActivity>> fetch(
    Object? payload, {
    int status = 200,
  }) {
    final source = HttpSdkActivityAvailabilityRemoteDataSource(
      transport: SdkHttpTransport(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.toString(), 'https://sdk.test/v1/sdk/activities');
          expect(request.body, isEmpty);
          expect(request.headers['X-App-ID'], a.appId);
          expect(request.headers['X-User-ID'], a.externalUserId);
          expect(request.headers['Authorization'], 'Bearer ${a.userHash}');
          return http.Response(jsonEncode(payload), status);
        }),
        config: const EixamSdkConfig(apiBaseUrl: 'https://sdk.test'),
        sessionContext: SdkSessionContext()..currentSession = b,
      ),
    );
    return source.fetch(a, backend: 'https://sdk.test');
  }

  Map<String, Object> row(SdkAvailableActivity activity) => {
    'id': activity.id,
    'key': activity.key,
  };

  test('one exact documented row uses captured signed identity', () async {
    final values = await fetch({
      'activities': [row(mountain)],
    });
    expect(values.single.id, mountain.id);
    expect(values.single.key, 'mountain');
  });
  test('multiple ordered rows, duplicates and additive properties', () async {
    final values = await fetch({
      'activities': [
        {
          ...row(ski),
          'unknown': {'nested': true},
        },
        row(mountain),
        row(ski),
      ],
      'future': true,
    });
    expect(values.map((v) => v.key), [ski.key, mountain.key, ski.key]);
  });
  test('confirmed empty is accepted', () async {
    expect(await fetch({'activities': []}), isEmpty);
  });
  for (final key in ['1ski', '_ski', '-ski', 'ski__tour', 'ski-', 'a' * 50]) {
    test('backend key preserved exactly: $key', () async {
      final values = await fetch({
        'activities': [
          {'id': ski.id, 'key': key},
        ],
      });
      expect(values.single.key, key);
      expect(
        () => SdkActivitySession.validateActivityKey(key),
        key == 'a' * 50
            ? returnsNormally
            : throwsA(isA<ActivitySessionException>()),
      );
    });
  }
  final malformed = <Object?>[
    null,
    [],
    'root',
    1,
    {},
    {'activities': null},
    {'activities': {}},
    {'activities': 'array'},
    {
      'activities': [null],
    },
    {
      'activities': [[]],
    },
    {
      'activities': ['item'],
    },
    {
      'activities': [{}],
    },
    {
      'activities': [
        {'id': ski.id},
      ],
    },
    {
      'activities': [
        {'key': 'ski'},
      ],
    },
    for (final id in [null, 1, {}, [], '', 'not-uuid', '${ski.id}\n'])
      {
        'activities': [
          {'id': id, 'key': 'ski'},
        ],
      },
    for (final key in [
      null,
      1,
      {},
      [],
      '',
      'A',
      ' ski',
      'ski ',
      'ski\n',
      'ski/tour',
      'é',
      'a' * 51,
    ])
      {
        'activities': [
          {'id': ski.id, 'key': key},
        ],
      },
    {
      'activities': [
        row(mountain),
        {'id': ski.id},
      ],
    },
  ];
  for (var i = 0; i < malformed.length; i++) {
    test('reject whole malformed response $i', () async {
      await expectLater(
        fetch(malformed[i]),
        throwsA(availabilityError('INVALID_RESPONSE')),
      );
    });
  }
  for (final status in [201, 204, 400, 403, 404, 429, 500, 503]) {
    test('HTTP $status uses typed network failure without raw body', () async {
      await expectLater(
        fetch({'secret': 'backend detail'}, status: status),
        throwsA(
          isA<NetworkException>()
              .having(
                (e) => e.code,
                'code',
                status == 429
                    ? 'E_ACTIVITY_AVAILABILITY_RATE_LIMITED'
                    : 'E_ACTIVITY_AVAILABILITY_HTTP_FAILED',
              )
              .having(
                (e) => e.message,
                'message',
                isNot(contains('backend detail')),
              ),
        ),
      );
    });
  }
  test('HTTP 401 uses existing AuthException', () async {
    await expectLater(fetch({}, status: 401), throwsA(isA<AuthException>()));
  });
  for (final error in [
    TimeoutException('timeout'),
    const SocketException('offline'),
    http.ClientException('connection failed'),
  ]) {
    test('transport maps ${error.runtimeType} to NetworkException', () async {
      final source = HttpSdkActivityAvailabilityRemoteDataSource(
        transport: SdkHttpTransport(
          client: MockClient((_) async => throw error),
          config: const EixamSdkConfig(apiBaseUrl: 'https://sdk.test'),
          sessionContext: SdkSessionContext(),
        ),
      );
      await expectLater(
        source.fetch(a, backend: 'https://sdk.test'),
        throwsA(isA<NetworkException>()),
      );
    });
  }
  test(
    'invalid JSON has availability-specific invalid-response error',
    () async {
      final source = HttpSdkActivityAvailabilityRemoteDataSource(
        transport: SdkHttpTransport(
          client: MockClient((_) async => http.Response('{broken', 200)),
          config: const EixamSdkConfig(apiBaseUrl: 'https://sdk.test'),
          sessionContext: SdkSessionContext(),
        ),
      );
      await expectLater(
        source.fetch(a, backend: 'https://sdk.test'),
        throwsA(availabilityError('INVALID_RESPONSE')),
      );
    },
  );

  test('hung GET obeys the existing twenty-second transport timeout', () {
    fakeAsync((async) {
      final pending = Completer<http.Response>();
      final source = HttpSdkActivityAvailabilityRemoteDataSource(
        transport: SdkHttpTransport(
          client: MockClient((_) => pending.future),
          config: const EixamSdkConfig(apiBaseUrl: 'https://sdk.test'),
          sessionContext: SdkSessionContext(),
        ),
      );
      Object? error;
      source
          .fetch(a, backend: 'https://sdk.test')
          .then<void>(
            (_) => fail('Hung request unexpectedly succeeded.'),
            onError: (Object failure) {
              error = failure;
            },
          );
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 19));
      expect(error, isNull);
      async.elapse(const Duration(seconds: 1));
      expect(
        error,
        isA<NetworkException>().having(
          (e) => e.code,
          'code',
          'E_SDK_HTTP_TIMEOUT',
        ),
      );
      pending.complete(http.Response('{"activities":[]}', 200));
      async.flushMicrotasks();
    });
  });

  test(
    'backend reinitialization cannot fetch from a transport bound elsewhere',
    () async {
      var calls = 0;
      final source = HttpSdkActivityAvailabilityRemoteDataSource(
        transport: SdkHttpTransport(
          client: MockClient((_) async {
            calls++;
            return http.Response('{"activities":[]}', 200);
          }),
          config: const EixamSdkConfig(apiBaseUrl: 'https://sdk.test'),
          sessionContext: SdkSessionContext(),
        ),
      );
      await expectLater(
        source.fetch(a, backend: 'https://other.test'),
        throwsA(availabilityError('UNAVAILABLE')),
      );
      expect(calls, 0);
      expect(await source.fetch(a, backend: 'https://sdk.test///'), isEmpty);
      expect(calls, 1);
    },
  );
}
