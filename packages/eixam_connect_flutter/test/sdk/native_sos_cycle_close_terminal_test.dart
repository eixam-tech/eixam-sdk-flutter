import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/android_protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/ios_protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_channel_mapper.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_stop_guard.dart';
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

  // F17c Phase 2 (decided 16/11/2026) + item 1 (Roger 17/11/2026): Dart's side
  // of the shared fixture. Every `terminal` step goes through the central
  // guard (kind nativeCycleClose) as the SDK decides it: an automated stop
  // names its native cycle (target=NAME, default the current one) and reaches
  // both platforms with that id and its issue time; target=none (no id) is
  // refused by the guard and never sent; target=user (the user's own action)
  // reaches native as "the current cycle".
  test('shared fixture: every SDK stop is decided by the guard and reaches '
      'iOS and Android native with its cycle target and issue time', () async {
    final base = DateTime.utc(2026, 11, 16).millisecondsSinceEpoch;
    var withIssue = 0;
    var without = 0;
    var exact = 0;
    var current = 0;
    var refused = 0;
    for (final raw in File(
      'test/fixtures/stale_sos_guard_scenarios.txt',
    ).readAsLinesSync()) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('scenario')) {
        continue;
      }
      final event = line.split(' => ').first.split(' ');
      if (event[1] != 'terminal') {
        continue;
      }
      final args = <String, String>{
        for (final token in event.skip(2))
          if (token.contains('='))
            token.split('=').first: token.split('=').last,
      };
      final issued = args['issued'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              base + int.parse(args['issued']!),
              isUtc: true,
            );
      final node = int.parse(args['node'] ?? '7');
      final target = args['target'];
      final user = target == 'user';
      // The id the SDK bound to the SOS it stops (native's cycle id).
      final cycleId = switch (target) {
        'user' || 'none' => null,
        null => 'native-cycle-current',
        final name => 'native-cycle-$name',
      };
      final decision = SosStopGuard().authorize(
        SosStopRequest(
          kind: SosStopKind.nativeCycleClose,
          basis: user
              ? SosStopBasis.userAction
              : SosStopBasis.authorizedUpstream,
          source: 'fixture',
          nativeCycleId: cycleId,
        ),
      );
      if (target == 'none') {
        expect(decision.allowed, isFalse, reason: line);
        expect(decision.reason, 'unknown_native_cycle', reason: line);
        refused++;
        continue;
      }
      expect(decision.allowed, isTrue, reason: line);
      for (final adapter in <ProtectionPlatformAdapter>[
        IosProtectionPlatformAdapter(),
        AndroidProtectionPlatformAdapter(methodChannel: androidChannel),
      ]) {
        calls.clear();
        await adapter.closeNativeSosCycle(
          nodeId: node,
          terminal: args['kind'],
          issuedAt: issued,
          targetCycleId: cycleId,
          targetCurrentCycle: user,
        );
        final sent = Map<String, dynamic>.from(
          calls.single.arguments as Map<Object?, Object?>,
        );
        expect(sent['terminal'], args['kind'], reason: line);
        expect(sent['nodeId'], node, reason: line);
        if (user) {
          expect(sent['targetCurrentCycle'], isTrue, reason: line);
          expect(sent.containsKey('targetCycleId'), isFalse, reason: line);
          current++;
        } else {
          expect(sent.containsKey('targetCurrentCycle'), isFalse, reason: line);
          expect(sent['targetCycleId'], cycleId, reason: line);
          exact++;
        }
        if (issued == null) {
          expect(sent.containsKey('issuedAtMs'), isFalse, reason: line);
          without++;
        } else {
          expect(
            sent['issuedAtMs'],
            issued.millisecondsSinceEpoch,
            reason: line,
          );
          withIssue++;
        }
      }
    }
    expect(withIssue, greaterThanOrEqualTo(8), reason: '>= 4 steps x 2');
    expect(without, greaterThan(20));
    expect(exact, greaterThan(20));
    expect(current, greaterThanOrEqualTo(4), reason: '>= 2 user steps x 2');
    expect(refused, greaterThanOrEqualTo(1));
  });

  test('F17c item 1: both platforms report the native SOS cycle id in the '
      'snapshot', () {
    final raw = <String, dynamic>{
      'nativeSosCycleId': 'native-cycle-1',
      'nativeSosCycleOpen': true,
    };
    for (final snapshot in <ProtectionPlatformSnapshot>[
      mapIosProtectionPlatformSnapshot(raw),
      mapAndroidProtectionPlatformSnapshot(raw),
    ]) {
      expect(snapshot.nativeSosCycleId, 'native-cycle-1');
      expect(snapshot.nativeSosCycleOpen, isTrue);
    }
    final none = mapAndroidProtectionPlatformSnapshot(<String, dynamic>{});
    expect(none.nativeSosCycleId, isNull);
    expect(none.nativeSosCycleOpen, isFalse);
  });

  test('lifecycle terminal maps to the TAG command kind', () {
    expect(nativeSosCycleTerminalFor(SosLifecycleStage.cancelled), 'cancel');
    expect(nativeSosCycleTerminalFor(SosLifecycleStage.resolved), 'resolve');
    expect(
      nativeSosCycleTerminalFor(SosLifecycleStage.activationFailed),
      isNull,
    );
  });

  test(
    'stale-stop notice texts reach native (defaults and app texts)',
    () async {
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
        protectionSosStaleStoppedBody:
            'Hemos parado en tu TAG el SOS cancelado.',
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
        expect(
          sent['protectionSosStaleStoppedTitle'],
          'SOS stopped on your TAG',
        );
        expect(
          sent['protectionSosStaleStoppedBody'],
          'Hemos parado en tu TAG el SOS cancelado.',
        );
      }
    },
  );
}
