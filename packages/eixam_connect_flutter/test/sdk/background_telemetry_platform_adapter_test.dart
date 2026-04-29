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
  });
}
