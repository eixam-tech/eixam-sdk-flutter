import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/android_protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/ios_protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// F17b (2026-11-15): the SDK closed an SOS whose TAG stop never reached the
/// TAG; native must know whether it was a cancel or a resolve so it can
/// write the matching command itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const iosChannel = MethodChannel(
    'dev.eixam.connect_flutter/protection_runtime/methods',
  );
  const androidChannel = MethodChannel('f17b-android-test');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    for (final channel in <MethodChannel>[iosChannel, androidChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    }
  });

  tearDown(() {
    for (final channel in <MethodChannel>[iosChannel, androidChannel]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  test('iOS close carries the terminal kind', () async {
    await IosProtectionPlatformAdapter().closeNativeSosCycle(
      nodeId: 0x1234,
      terminal: 'cancel',
    );
    expect(calls.single.method, 'closeNativeSosCycle');
    expect(calls.single.arguments, <String, dynamic>{
      'nodeId': 0x1234,
      'terminal': 'cancel',
    });
  });

  test('Android close reaches native with the terminal kind', () async {
    await AndroidProtectionPlatformAdapter(
      methodChannel: androidChannel,
    ).closeNativeSosCycle(terminal: 'resolve');
    expect(calls.single.method, 'closeNativeSosCycle');
    expect(calls.single.arguments, <String, dynamic>{'terminal': 'resolve'});
  });

  test('lifecycle terminal maps to the TAG command kind', () {
    expect(nativeSosCycleTerminalFor(SosLifecycleStage.cancelled), 'cancel');
    expect(nativeSosCycleTerminalFor(SosLifecycleStage.resolved), 'resolve');
    expect(
      nativeSosCycleTerminalFor(SosLifecycleStage.activationFailed),
      isNull,
    );
  });

  test('stale-stop notice texts reach native (defaults and app texts)', () async {
    const texts = EixamNotificationTexts(
      protectionActiveTitle: 'a',
      protectionActiveBody: 'a',
      protectionModeTitle: 'a',
      protectionModeBody: 'a',
      protectionModeChannelName: 'a',
      protectionModeChannelDescription: 'a',
      protectionSosChannelName: 'a',
      protectionSosChannelDescription: 'a',
      protectionPreSosTitle: 'a',
      protectionPreSosBody: 'a',
      protectionSosActiveTitle: 'a',
      protectionSosActiveBody: 'a',
      protectionSosResolvedTitle: 'a',
      protectionSosResolvedBody: 'a',
      protectionSosStaleStoppedBody: 'Hemos parado en tu TAG el SOS cancelado.',
    );
    for (final adapter in <dynamic>[
      IosProtectionPlatformAdapter(),
      AndroidProtectionPlatformAdapter(methodChannel: androidChannel),
    ]) {
      calls.clear();
      try {
        await adapter.startProtectionRuntime(
          request: const ProtectionPlatformStartRequest(
            modeOptions: ProtectionModeOptions(),
            notificationTexts: texts,
          ),
        );
      } catch (_) {
        // The mock returns no start map; only the arguments matter here.
      }
      final sent = (calls.first.arguments as Map)['notificationTexts'] as Map;
      expect(sent['protectionSosStaleStoppedTitle'], 'SOS stopped on your TAG');
      expect(
        sent['protectionSosStaleStoppedBody'],
        'Hemos parado en tu TAG el SOS cancelado.',
      );
    }
  });
}
