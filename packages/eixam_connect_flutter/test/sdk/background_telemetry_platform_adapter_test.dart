import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'dev.eixam.connect_flutter/background_telemetry/methods',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('start background telemetry sends signed session once', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });

    final adapter = AndroidBackgroundTelemetryPlatformAdapter(
      methodChannel: channel,
    );

    await adapter.startBackgroundTelemetry(
      const BackgroundTelemetryStartRequest(
        apiBaseUrl: 'https://api.example.test',
        session: EixamSession.signed(
          appId: 'partner-app',
          externalUserId: 'user-1',
          userHash: 'signed-hash',
          canonicalExternalUserId: 'canonical-user-1',
        ),
        sosOpen: false,
        deviceId: 'device-1',
      ),
    );

    expect(calls, hasLength(1));
    expect(calls.single.method, 'startBackgroundTelemetry');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['apiBaseUrl'], 'https://api.example.test');
    expect(args['deviceId'], 'device-1');
    expect(args['sosOpen'], isFalse);
    expect(args['session'], isA<Map<Object?, Object?>>());
  });

  test('stop background telemetry calls native stop', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });

    final adapter = AndroidBackgroundTelemetryPlatformAdapter(
      methodChannel: channel,
    );
    await adapter.stopBackgroundTelemetry();

    expect(calls.map((call) => call.method), <String>[
      'stopBackgroundTelemetry',
    ]);
  });

  test('missing permission diagnostic maps without crashing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <String, Object?>{
            'backgroundTelemetryEnabled': true,
            'androidForegroundServiceRunning': false,
            'backgroundPermissionStatus': 'location_missing',
            'lastBackgroundTelemetryAt': null,
            'lastBackgroundTelemetryError': 'location_permission_missing',
            'lastBackgroundLocationMode': 'timeout',
            'activeLocationRequest': true,
          };
        });

    final adapter = AndroidBackgroundTelemetryPlatformAdapter(
      methodChannel: channel,
    );
    final diagnostics = await adapter.getBackgroundTelemetryDiagnostics();

    expect(diagnostics.enabled, isTrue);
    expect(diagnostics.serviceRunning, isFalse);
    expect(diagnostics.permissionStatus, 'location_missing');
    expect(diagnostics.lastTelemetryError, 'location_permission_missing');
    expect(diagnostics.lastLocationMode, 'timeout');
    expect(diagnostics.activeLocationRequest, isTrue);
  });

  test('queued phone radio snapshot becomes radio on the payload', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <Map<String, Object?>>[
            <String, Object?>{
              'signature': 'native-1',
              'enqueuedAt': 0,
              'payload': <String, Object?>{
                'timestamp': '2026-03-31T10:15:00.000Z',
                'latitude': 41.38,
                'longitude': 2.17,
                'altitude': 8,
                'identitySource': 'native_background',
                'horizontalAccuracyMeters': 18.5,
                'phoneRadio': <String, Object?>{
                  'networkType': AndroidNetworkType.lte,
                  'overrideNetworkType': AndroidOverrideNetworkType.nrNsa,
                  'cellularDataConnected': false,
                },
              },
            },
          ];
        });

    final adapter = AndroidBackgroundTelemetryPlatformAdapter(
      methodChannel: channel,
    );
    final items = await adapter.peekQueuedBackgroundTelemetry();
    final json = items.single.payload.toJson();

    expect(items.single.payload.phoneRadioSampled, isTrue);
    expect(json['horizontalAccuracyMeters'], 18.5);
    expect(json['radio'], <String, dynamic>{
      'generation': '5g',
      'fiveGMode': 'nsa',
      'connected': false,
    });
    expect(json.containsKey('phoneRadio'), isFalse);
  });

  test('queued wifi snapshot stays sampled and omits radio', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <Map<String, Object?>>[
            <String, Object?>{
              'signature': 'native-wifi',
              'payload': <String, Object?>{
                'timestamp': '2026-03-31T10:15:00.000Z',
                'latitude': 41.38,
                'longitude': 2.17,
                'altitude': 8,
                'identitySource': 'native_background',
                'phoneRadio': <String, Object?>{
                  'networkType': AndroidNetworkType.iwlan,
                  'cellularDataConnected': false,
                },
              },
            },
          ];
        });

    final adapter = AndroidBackgroundTelemetryPlatformAdapter(
      methodChannel: channel,
    );
    final items = await adapter.peekQueuedBackgroundTelemetry();

    expect(items.single.payload.phoneRadioSampled, isTrue);
    expect(items.single.payload.radio, isNull);
    expect(items.single.payload.toJson().containsKey('radio'), isFalse);
  });

  test('malformed radio snapshot keeps the queued fix', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <Map<String, Object?>>[
            <String, Object?>{
              'signature': 'native-bad',
              'payload': <String, Object?>{
                'timestamp': '2026-03-31T10:15:00.000Z',
                'latitude': 41.38,
                'longitude': 2.17,
                'altitude': 8,
                'identitySource': 'native_background',
                'horizontalAccuracyMeters': 'coarse',
                'phoneRadio': <String, Object?>{
                  'networkType': 'lte',
                  'overrideNetworkType': true,
                  'cellularDataConnected': 1,
                  'radioAccessTechnology': 4,
                },
              },
            },
          ];
        });

    final adapter = AndroidBackgroundTelemetryPlatformAdapter(
      methodChannel: channel,
    );
    final items = await adapter.peekQueuedBackgroundTelemetry();

    expect(items, hasLength(1));
    expect(items.single.payload.latitude, 41.38);
    expect(items.single.payload.phoneRadioSampled, isTrue);
    expect(items.single.payload.radio, isNull);
    expect(items.single.payload.horizontalAccuracyMeters, isNull);
  });

  test('a bad field on one queued fix does not drop the next fix', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return <Map<String, Object?>>[
            <String, Object?>{
              'signature': 'native-bad-type',
              'payload': <String, Object?>{
                'timestamp': '2026-03-31T10:15:00.000Z',
                'latitude': 41.38,
                'longitude': 2.17,
                'altitude': 8,
                'identitySource': 4,
                'kind': true,
              },
            },
            <String, Object?>{
              'signature': 'native-next',
              'payload': <String, Object?>{
                'timestamp': '2026-03-31T10:16:00.000Z',
                'latitude': 41.39,
                'longitude': 2.18,
                'altitude': 9,
                'identitySource': 'native_background',
                'phoneRadio': <String, Object?>{
                  'networkType': AndroidNetworkType.lte,
                  'cellularDataConnected': true,
                },
              },
            },
          ];
        });

    final adapter = AndroidBackgroundTelemetryPlatformAdapter(
      methodChannel: channel,
    );
    final items = await adapter.peekQueuedBackgroundTelemetry();

    expect(items, hasLength(2));
    expect(items.first.payload.identitySource, isNull);
    expect(items.first.payload.kind, isNull);
    expect(items.last.payload.radio?.toJson(), <String, dynamic>{
      'generation': '4g',
      'connected': true,
    });
  });
}
