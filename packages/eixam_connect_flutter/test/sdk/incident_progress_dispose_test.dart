import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart' as public;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _watchdog = Duration(seconds: 2);
const _secureChannel = MethodChannel(
  'dev.eixam.connect.flutter/secure_storage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureValues = <String, String>{};

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secureValues.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, (call) async {
          final args = Map<String, Object?>.from(call.arguments as Map);
          final key = args['key'] as String?;
          switch (call.method) {
            case 'read':
              return secureValues[key];
            case 'write':
              secureValues[key!] = args['value'] as String;
              return null;
            case 'delete':
              secureValues.remove(key);
              return null;
            case 'deleteAll':
              secureValues.clear();
              return null;
          }
          throw StateError('Unexpected secure storage operation');
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_secureChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'real API SDK idle progress cancellation completes before disposal',
    () async {
      final sdk = await _bootstrap();
      final values = <SosIncidentProgress?>[];
      final subscription = (sdk as SosIncidentProgressProvider)
          .currentSosIncidentProgressStream
          .listen(values.add);
      try {
        await pumpEventQueue();
        expect(values, [null]);
        await subscription.cancel().timeout(_watchdog);
        expect(await sdk.getTrackingState(), TrackingState.idle);
      } finally {
        // This must not unblock cancellation until its assertion has resolved.
        await (sdk as dynamic).dispose();
        await subscription.cancel();
      }
    },
  );

  test(
    'real API SDK closes idle progress and initializes a fresh runtime',
    () async {
      for (var run = 0; run < 2; run++) {
        final sdk = await _bootstrap();
        final done = Completer<void>();
        final values = <SosIncidentProgress?>[];
        (sdk as SosIncidentProgressProvider).currentSosIncidentProgressStream
            .listen(values.add, onDone: done.complete);
        await pumpEventQueue();
        expect(values, [null]);
        expect(await sdk.getTrackingState(), TrackingState.idle);
        await ((sdk as dynamic).dispose() as Future<void>).timeout(_watchdog);
        await done.future.timeout(_watchdog);
      }
    },
  );
}

Future<EixamConnectSdk> _bootstrap() => public.ApiSdkFactory.bootstrap(
  const EixamBootstrapConfig(
    appId: 'cancellation-test',
    environment: EixamEnvironment.sandbox,
    notificationPolicy: EixamNotificationPolicy.hostAppManaged,
    featureFlags: {'defer_runtime_startup': true},
    notificationTexts: EixamNotificationTexts(
      protectionActiveTitle: 'Test',
      protectionActiveBody: 'Test',
      protectionModeTitle: 'Test',
      protectionModeBody: 'Test',
      protectionModeChannelName: 'Test',
      protectionModeChannelDescription: 'Test',
      protectionSosChannelName: 'Test',
      protectionSosChannelDescription: 'Test',
      protectionPreSosTitle: 'Test',
      protectionPreSosBody: 'Test',
      protectionSosActiveTitle: 'Test',
      protectionSosActiveBody: 'Test',
      protectionSosResolvedTitle: 'Test',
      protectionSosResolvedBody: 'Test',
    ),
  ),
);
