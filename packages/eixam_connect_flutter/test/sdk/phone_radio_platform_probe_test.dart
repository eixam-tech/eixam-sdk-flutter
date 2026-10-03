import 'dart:async';

import 'package:eixam_connect_flutter/src/sdk/phone_radio_platform_probe.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'dev.eixam.connect_flutter/phone_radio/methods',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('read maps an iOS RAT to radio generation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'readPhoneRadio');
          return <String, Object?>{
            'radioAccessTechnology': 'CTRadioAccessTechnologyNRNSA',
            'cellularDataConnected': true,
          };
        });

    final reading = await const PhoneRadioPlatformProbe(
      methodChannel: channel,
    ).read();

    expect(reading?.radioAccessTechnology, 'CTRadioAccessTechnologyNRNSA');
    expect(reading?.cellularDataConnected, isTrue);
  });

  test('a stuck platform read returns null', () async {
    final pending = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) => pending.future);

    final reading = await const PhoneRadioPlatformProbe(
      methodChannel: channel,
      timeout: Duration(milliseconds: 30),
    ).read();

    expect(reading, isNull);
    pending.complete(<String, Object?>{});
  });
}
