import 'package:eixam_connect_flutter/src/sdk/ios_protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_channel_mapper.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The iOS adapter speaks the same pending create/cancel channel contract as
/// Android (native keeps a TAG SOS durable, the SDK claims it for the MQTT
/// outbox), plus the background-time hold.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'dev.eixam.connect_flutter/protection_runtime/methods',
  );
  final calls = <MethodCall>[];
  Map<String, dynamic>? pendingCreate;

  setUp(() {
    calls.clear();
    pendingCreate = <String, dynamic>{
      'signature': 'native-sos-sos-7-2:sos:7:2:native-sos-1',
      'incidentId': 'native-sos-sos-7-2',
      'cycleKey': 'sos:7:2',
      'correlationId': 'native-sos-1',
      'source': 'native_protection_sos',
      'triggerSource': 'native_protection_sos',
      'nodeId': 7,
      'deviceId': '7',
      'createdAt': DateTime.utc(2026, 11, 10, 9).millisecondsSinceEpoch,
      'updatedAt': DateTime.utc(2026, 11, 10, 9).millisecondsSinceEpoch,
      'state': 'pending_mqtt',
      'retryCount': 0,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'peekPendingNativeSosCreate':
              return pendingCreate;
            case 'ackPendingNativeSosCreate':
            case 'dropPendingNativeSosCreate':
            case 'ackPendingNativeSosCancel':
              return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('peeks the native pending create with the Android mapping', () async {
    final adapter = IosProtectionPlatformAdapter();

    final pending = await adapter.peekPendingNativeSosCreate();

    expect(pending, isNotNull);
    expect(pending!.signature, 'native-sos-sos-7-2:sos:7:2:native-sos-1');
    expect(pending.incidentId, 'native-sos-sos-7-2');
    expect(pending.cycleKey, 'sos:7:2');
    expect(pending.nodeId, 7);
    expect(pending.deviceId, '7');
    expect(pending.createdAt, DateTime.utc(2026, 11, 10, 9));
    expect(pending.state, 'pending_mqtt');

    pendingCreate = null;
    expect(await adapter.peekPendingNativeSosCreate(), isNull);
  });

  test('claims, retires and holds through the native channel', () async {
    final adapter = IosProtectionPlatformAdapter();
    const signature = 'native-sos-sos-7-2:sos:7:2:native-sos-1';

    await adapter.markPendingNativeSosCreateMqttFlushStarted(signature);
    await adapter.markPendingNativeSosCreateMqttPublished(signature);
    await adapter.retainPendingNativeSosCreate(signature, reason: 'retry');
    expect(
      await adapter.ackPendingNativeSosCreate(
        signature,
        backendIncidentId: 'b-1',
      ),
      isTrue,
    );
    expect(
      await adapter.dropPendingNativeSosCreate(signature, reason: 'x'),
      isTrue,
    );
    expect(await adapter.ackPendingNativeSosCancel(), isTrue);
    await adapter.setSosDeliveryPending(true);

    expect(calls.map((call) => call.method), <String>[
      'markPendingNativeSosCreateMqttFlushStarted',
      'markPendingNativeSosCreateMqttPublished',
      'retainPendingNativeSosCreate',
      'ackPendingNativeSosCreate',
      'dropPendingNativeSosCreate',
      'ackPendingNativeSosCancel',
      'setSosDeliveryPending',
    ]);
    expect(calls.first.arguments, <String, dynamic>{'signature': signature});
    expect(calls[2].arguments, <String, dynamic>{
      'signature': signature,
      'reason': 'retry',
    });
    expect(calls.last.arguments, <String, dynamic>{'pending': true});
  });

  test('maps native pending create/cancel counts from the iOS snapshot', () {
    final cancelledAt = DateTime.utc(2026, 11, 10, 9, 5);
    final snapshot = mapIosProtectionPlatformSnapshot(<String, dynamic>{
      'pendingSosCount': 2,
      'pendingNativeSosCreateCount': 1,
      'pendingNativeSosCancelCount': 1,
      'pendingNativeSosCancelCreatedAt': cancelledAt.millisecondsSinceEpoch,
      'preSosLifecycleState': 'createPending',
      'preSosCycleKey': 'sos:7:2',
    });

    expect(snapshot.pendingNativeSosCreateCount, 1);
    expect(snapshot.pendingNativeSosCancelCount, 1);
    expect(snapshot.pendingNativeSosCancelCreatedAt, cancelledAt);
    expect(snapshot.preSosLifecycleState, 'createPending');
  });
}
