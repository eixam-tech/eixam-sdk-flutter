import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_battery_probe.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tag_battery_test_support.dart';

void main() {
  late DateTime now;
  late bool blocked;
  late List<String> log;
  late Future<DeviceRuntimeStatus>? Function() start;
  late TagBatteryProbe probe;

  setUp(() {
    now = DateTime.utc(2026, 11, 2, 12);
    blocked = false;
    log = <String>[];
    start = () {
      log.add('start');
      return Future.value(runtimeStatus(receivedAt: now));
    };
    probe = TagBatteryProbe(
      clock: () => now,
      isBlocked: () {
        log.add('blocked?');
        return blocked;
      },
      start: () => start(),
      sosRehydrationWait: const Duration(milliseconds: 50),
    );
  });

  test('sends one request and returns the reply', () async {
    expect(await probe.run(deviceKey: 'tag-1'), isNotNull);
    expect(log, ['blocked?', 'blocked?', 'start']);
  });

  group('M1: SOS rehydration comes first', () {
    test('the gate is evaluated only after rehydration completes', () async {
      final rehydration = Completer<void>();
      final result = probe.run(
        deviceKey: 'tag-1',
        afterSosRehydration: rehydration.future,
      );
      await pumpEventQueue();
      expect(log, isEmpty, reason: 'nothing happens while SOS is unknown');
      rehydration.complete();
      expect(await result, isNotNull);
      expect(log, ['blocked?', 'blocked?', 'start']);
    });

    test('an SOS discovered during rehydration blocks the probe', () async {
      final rehydration = Completer<void>();
      final result = probe.run(
        deviceKey: 'tag-1',
        afterSosRehydration: rehydration.future,
      );
      blocked = true; // rehydration found an active SOS
      rehydration.complete();
      expect(await result, isNull);
      expect(log, isNot(contains('start')));
    });

    test('the gate is re-checked immediately before the send', () async {
      var checks = 0;
      probe = TagBatteryProbe(
        clock: () => now,
        isBlocked: () => ++checks == 2, // first check passes, second blocks
        start: () {
          log.add('start');
          return Future.value(runtimeStatus());
        },
      );
      expect(await probe.run(deviceKey: 'tag-1'), isNull);
      expect(log, isEmpty);
    });

    test(
      'rehydration that fails or does not finish in time stays silent',
      () async {
        expect(
          await probe.run(
            deviceKey: 'tag-1',
            afterSosRehydration: Future<void>.error(StateError('backend')),
          ),
          isNull,
        );
        expect(
          await probe.run(
            deviceKey: 'tag-1',
            afterSosRehydration: Completer<void>().future,
          ),
          isNull,
        );
        expect(log, isEmpty);
        // And a skipped probe does not consume the interval.
        expect(await probe.run(deviceKey: 'tag-1'), isNotNull);
      },
    );
  });

  group('M2: nothing is started unless the path is already ready', () {
    test('a null start means skip: no request, no interval consumed', () async {
      start = () => null;
      expect(await probe.run(deviceKey: 'tag-1'), isNull);
      start = () => Future.value(runtimeStatus());
      expect(await probe.run(deviceKey: 'tag-1'), isNotNull);
    });

    test('a failing request returns null and waits out the interval', () async {
      var calls = 0;
      start = () {
        calls++;
        return Future<DeviceRuntimeStatus>.error(StateError('timeout'));
      };
      expect(await probe.run(deviceKey: 'tag-1'), isNull);
      expect(await probe.run(deviceKey: 'tag-1'), isNull);
      expect(calls, 1);
    });
  });

  group('interval', () {
    test('at most once per 10 minutes per device', () async {
      expect(await probe.run(deviceKey: 'tag-1'), isNotNull);
      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(await probe.run(deviceKey: 'tag-1'), isNull);
      expect(await probe.run(deviceKey: 'tag-2'), isNotNull);
      now = now.add(const Duration(seconds: 2));
      expect(await probe.run(deviceKey: 'tag-1'), isNotNull);
    });
  });
}
