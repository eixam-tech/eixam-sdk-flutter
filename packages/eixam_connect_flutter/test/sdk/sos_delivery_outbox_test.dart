import 'dart:async';

import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/sdk/sos_delivery_outbox.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes/memory_shared_prefs_sdk_store.dart';

/// Rules of the durable SOS outbox (F4/F5): MQTT-only delivery, retried with
/// bounded backoff until the backend confirms, ordered, persisted, no
/// duplicates, a cancel supersedes queued triggers.
void main() {
  late List<String> releaseLines;

  setUp(() {
    releaseLines = <String>[];
    sdkReleaseLogSinkForTesting = releaseLines.add;
  });

  tearDown(() {
    sdkReleaseLogSinkForTesting = null;
  });

  group('SosDeliveryOutbox', () {
    test('MQTT down at SOS time: retried until published and confirmed, '
        'same payload every attempt', () async {
      final harness = _Harness(failFirstPublishes: 3);
      final outbox = harness.build();
      addTearDown(outbox.dispose);

      final action = await outbox.enqueueTrigger(
        cycleKey: 'sos:7:2',
        payload: const <String, dynamic>{'incidentId': 'native-sos-7-2'},
      );
      // Backend shows the incident once a publish got through.
      harness.backendAfterPublish = SosOutboxBackendCheck.confirmed;

      expect(
        await outbox.waitForConfirmation(
          action,
          timeout: const Duration(seconds: 2),
        ),
        isTrue,
      );
      expect(harness.publishAttempts, 4);
      expect(harness.published.map((a) => a.payload['incidentId']).toSet(), {
        'native-sos-7-2',
      });
      expect(outbox.pending, isEmpty);
      expect(
        releaseLines.any((l) => l.startsWith('SOS_OUTBOX_CONFIRMED')),
        isTrue,
      );
    });

    test(
      'PUBACK alone is not confirmation: stays pending and retrying',
      () async {
        final harness = _Harness();
        final outbox = harness.build(
          retryingAfter: const Duration(milliseconds: 60),
        );
        addTearDown(outbox.dispose);

        final action = await outbox.enqueueTrigger(
          cycleKey: 'sos:7:3',
          payload: const <String, dynamic>{},
        );
        await Future<void>.delayed(const Duration(milliseconds: 150));

        expect(outbox.isPending(action.id), isTrue);
        expect(outbox.status.pendingTrigger, isTrue);
        expect(
          outbox.status.retrying,
          isTrue,
          reason: 'Not sent yet, retrying',
        );
        expect(harness.publishAttempts, greaterThan(1));
        expect(outbox.pending.single.published, isTrue);
      },
    );

    test('realtime confirmation completes the head immediately', () async {
      final harness = _Harness();
      final outbox = harness.build(
        confirmationWindow: const Duration(seconds: 5),
      );
      addTearDown(outbox.dispose);
      harness.onPublish = (action) {
        scheduleMicrotask(
          () => outbox.confirm(action.kind, source: 'mqtt_processed'),
        );
      };

      final action = await outbox.enqueueTrigger(
        cycleKey: 'sos:7:4',
        payload: const <String, dynamic>{},
      );

      expect(
        await outbox.waitForConfirmation(
          action,
          timeout: const Duration(milliseconds: 500),
        ),
        isTrue,
      );
      expect(harness.publishAttempts, 1);
      expect(harness.backendReads, 0);
    });

    test('a trigger for a queued cycle is not duplicated', () async {
      final harness = _Harness(failFirstPublishes: 1000);
      final outbox = harness.build();
      addTearDown(outbox.dispose);

      final first = await outbox.enqueueTrigger(
        cycleKey: 'sos:7:5',
        payload: const <String, dynamic>{},
      );
      final second = await outbox.enqueueTrigger(
        cycleKey: 'sos:7:5',
        payload: const <String, dynamic>{},
      );

      expect(second.id, first.id);
      expect(outbox.pending, hasLength(1));
    });

    test(
      'a cancel supersedes queued triggers; the trigger is never replayed',
      () async {
        final harness = _Harness(failFirstPublishes: 1000);
        final outbox = harness.build();
        addTearDown(outbox.dispose);

        await outbox.enqueueTrigger(
          cycleKey: 'sos:7:6',
          payload: const <String, dynamic>{},
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        harness.failFirstPublishes = 0;
        harness.backendAfterPublish = SosOutboxBackendCheck.confirmed;
        final cancel = (await outbox.enqueueCancel(cycleKey: 'sos:7:6'))!;
        final triggerAttemptsAtCancel = harness.published
            .where((a) => a.kind == SosOutboxActionKind.trigger)
            .length;

        expect(
          await outbox.waitForConfirmation(
            cancel,
            timeout: const Duration(seconds: 2),
          ),
          isTrue,
        );
        expect(
          harness.published
              .where((a) => a.kind == SosOutboxActionKind.trigger)
              .length,
          triggerAttemptsAtCancel,
          reason: 'no trigger publish after the cancel',
        );
        expect(outbox.pending, isEmpty);
      },
    );

    test('actions are delivered strictly in order', () async {
      final harness = _Harness();
      harness.backendAfterPublish = SosOutboxBackendCheck.confirmed;
      final outbox = harness.build();
      addTearDown(outbox.dispose);

      final cancel = (await outbox.enqueueCancel(cycleKey: 'sos:7:7'))!;
      final trigger = await outbox.enqueueTrigger(
        cycleKey: 'sos:7:8',
        payload: const <String, dynamic>{},
      );
      await outbox.waitForConfirmation(
        trigger,
        timeout: const Duration(seconds: 2),
      );

      expect(harness.published.map((a) => a.id).toList(), [
        cancel.id,
        trigger.id,
      ]);
    });

    test('pending actions survive a process restart', () async {
      final store = MemorySharedPrefsSdkStore();
      final harness = _Harness(failFirstPublishes: 1000);
      final first = harness.build(store: store);
      await first.enqueueTrigger(
        cycleKey: 'sos:7:9',
        payload: const <String, dynamic>{'incidentId': 'native-sos-7-9'},
      );
      await first.enqueueCancel(cycleKey: 'sos:7:9');
      await first.enqueueTrigger(
        cycleKey: 'sos:7:10',
        payload: const <String, dynamic>{'incidentId': 'native-sos-7-10'},
      );
      await first.dispose();

      final restarted = _Harness();
      restarted.backendAfterPublish = SosOutboxBackendCheck.confirmed;
      final second = restarted.build(store: store);
      addTearDown(second.dispose);
      await second.restore();
      expect(second.pending.map((a) => a.kind).toList(), [
        SosOutboxActionKind.cancel,
        SosOutboxActionKind.trigger,
      ]);
      final trigger = second.pending.last;
      expect(
        await second.waitForConfirmation(
          trigger,
          timeout: const Duration(seconds: 2),
        ),
        isTrue,
      );
      expect(restarted.published.map((a) => a.kind).toList(), [
        SosOutboxActionKind.cancel,
        SosOutboxActionKind.trigger,
      ]);
      expect(restarted.published.last.payload['incidentId'], 'native-sos-7-10');
      final persisted = await store.readJson(SosDeliveryOutbox.storeKey);
      expect(persisted?['actions'] ?? const <Object>[], isEmpty);
    });

    test(
      'a failed publish whose backend read confirms is not re-sent',
      () async {
        final harness = _Harness(failFirstPublishes: 1);
        harness.backendOnFailure = SosOutboxBackendCheck.confirmed;
        final outbox = harness.build();
        addTearDown(outbox.dispose);

        final action = await outbox.enqueueTrigger(
          cycleKey: 'sos:7:11',
          payload: const <String, dynamic>{},
        );

        expect(
          await outbox.waitForConfirmation(
            action,
            timeout: const Duration(seconds: 1),
          ),
          isTrue,
        );
        expect(harness.publishAttempts, 1);
      },
    );

    test('session clear drops actions of the previous account', () async {
      final store = MemorySharedPrefsSdkStore();
      final harness = _Harness(failFirstPublishes: 1000);
      final outbox = harness.build(store: store);
      addTearDown(outbox.dispose);
      await outbox.enqueueTrigger(
        cycleKey: 'sos:7:12',
        payload: const <String, dynamic>{},
      );

      await outbox.clear(reason: 'session_cleared');

      expect(outbox.pending, isEmpty);
      expect(await store.readJson(SosDeliveryOutbox.storeKey), isNull);
    });

    test('a stale cancel never supersedes or precedes a newer SOS', () async {
      var now = DateTime.utc(2026, 11, 10, 13, 0, 0);
      final harness = _Harness(failFirstPublishes: 1000);
      final outbox = harness.build(clock: () => now);
      addTearDown(outbox.dispose);
      final cancelObservedAt = now;
      now = now.add(const Duration(seconds: 30));
      final newer = await outbox.enqueueTrigger(
        cycleKey: 'sos:7:20',
        payload: const <String, dynamic>{},
      );

      final cancel = await outbox.enqueueCancel(
        cycleKey: 'sos:7:19',
        observedAt: cancelObservedAt,
      );

      expect(outbox.pending.map((a) => a.id).toList(), [cancel!.id, newer.id]);
    });

    test('a stale cancel is dropped when a newer SOS already reached the '
        'broker', () async {
      var now = DateTime.utc(2026, 11, 10, 13, 0, 0);
      final harness = _Harness();
      final outbox = harness.build(clock: () => now);
      addTearDown(outbox.dispose);
      final cancelObservedAt = now;
      now = now.add(const Duration(seconds: 30));
      await outbox.enqueueTrigger(
        cycleKey: 'sos:7:21',
        payload: const <String, dynamic>{},
      );
      for (var i = 0; i < 50 && harness.published.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final cancel = await outbox.enqueueCancel(
        cycleKey: 'sos:7:20',
        observedAt: cancelObservedAt,
      );

      expect(cancel, isNull);
      expect(
        harness.published.where((a) => a.kind == SosOutboxActionKind.cancel),
        isEmpty,
      );
    });

    test('a cancel already acknowledged by the broker does not block a new '
        'SOS', () async {
      final harness = _Harness();
      final outbox = harness.build();
      addTearDown(outbox.dispose);
      await outbox.enqueueCancel(cycleKey: 'sos:7:22');
      for (var i = 0; i < 50 && harness.published.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      harness.backendAfterPublish = SosOutboxBackendCheck.confirmed;

      final trigger = await outbox.enqueueTrigger(
        cycleKey: 'sos:7:23',
        payload: const <String, dynamic>{},
      );

      expect(
        await outbox.waitForConfirmation(
          trigger,
          timeout: const Duration(seconds: 1),
        ),
        isTrue,
      );
    });

    test('an expired trigger is reported, not left pending', () async {
      var now = DateTime.utc(2026, 11, 10, 13);
      final expired = <SosOutboxAction>[];
      final harness = _Harness(failFirstPublishes: 1000);
      final outbox = harness.build(
        clock: () => now,
        triggerMaxAge: const Duration(minutes: 1),
        onExpired: expired.add,
      );
      addTearDown(outbox.dispose);
      await outbox.enqueueTrigger(
        cycleKey: 'sos:7:24',
        payload: const <String, dynamic>{},
      );
      now = now.add(const Duration(minutes: 2));
      outbox.kick('test');
      for (var i = 0; i < 50 && expired.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(expired.single.cycleKey, 'sos:7:24');
      expect(outbox.pending, isEmpty);
    });

    test(
      'an action the publisher refuses for another account is dropped',
      () async {
        final harness = _Harness();
        harness.dropWith = const SosOutboxDropAction('account_changed');
        final outbox = harness.build();
        addTearDown(outbox.dispose);

        final action = await outbox.enqueueTrigger(
          cycleKey: 'sos:7:25',
          payload: const <String, dynamic>{},
        );

        expect(
          await outbox.waitForConfirmation(
            action,
            timeout: const Duration(seconds: 1),
          ),
          isFalse,
        );
        expect(outbox.pending, isEmpty);
      },
    );
  });
}

class _Harness {
  _Harness({this.failFirstPublishes = 0});

  int failFirstPublishes;
  int publishAttempts = 0;
  int backendReads = 0;
  final List<SosOutboxAction> published = <SosOutboxAction>[];
  SosOutboxBackendCheck backendAfterPublish =
      SosOutboxBackendCheck.notConfirmed;
  SosOutboxBackendCheck backendOnFailure = SosOutboxBackendCheck.unknown;
  void Function(SosOutboxAction action)? onPublish;
  SosOutboxDropAction? dropWith;
  bool _lastPublishFailed = false;

  SosDeliveryOutbox build({
    MemorySharedPrefsSdkStore? store,
    Duration confirmationWindow = const Duration(milliseconds: 15),
    Duration retryingAfter = const Duration(seconds: 10),
    DateTime Function()? clock,
    Duration triggerMaxAge = const Duration(hours: 6),
    void Function(SosOutboxAction action)? onExpired,
  }) {
    return SosDeliveryOutbox(
      store: store,
      clock: clock,
      triggerMaxAge: triggerMaxAge,
      onExpired: onExpired,
      confirmationWindow: confirmationWindow,
      retryingAfter: retryingAfter,
      backoff: const <Duration>[Duration(milliseconds: 5)],
      publish: (action) async {
        publishAttempts++;
        final drop = dropWith;
        if (drop != null) {
          throw drop;
        }
        if (publishAttempts <= failFirstPublishes) {
          _lastPublishFailed = true;
          throw StateError('MQTT not connected');
        }
        _lastPublishFailed = false;
        published.add(action);
        onPublish?.call(action);
      },
      readBackend: (action) async {
        backendReads++;
        return _lastPublishFailed ? backendOnFailure : backendAfterPublish;
      },
    );
  }
}
