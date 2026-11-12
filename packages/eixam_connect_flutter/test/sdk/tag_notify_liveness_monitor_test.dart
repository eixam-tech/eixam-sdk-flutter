import 'package:eixam_connect_flutter/src/sdk/tag_notify_liveness_monitor.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> log;
  late List<TagNotifyProbeResult> replies;
  late String? skip;
  late int probes;
  late int recoveries;
  late List<bool> restart;
  late TagNotifyLivenessMonitor monitor;
  late bool proven;

  void build() {
    monitor = TagNotifyLivenessMonitor(
      skipReason: () => skip,
      probe: (timeout) async {
        probes++;
        await Future<void>.delayed(timeout);
        return replies.isEmpty
            ? TagNotifyProbeResult.replied
            : replies.removeAt(0);
      },
      recover: () async {
        recoveries++;
        return true;
      },
      onRestartRequiredChanged: restart.add,
      log: log.add,
      isStatusSupportProven: () => proven,
    );
  }

  setUp(() {
    log = <String>[];
    replies = <TagNotifyProbeResult>[];
    skip = null;
    probes = 0;
    recoveries = 0;
    restart = <bool>[];
    proven = true;
    build();
  });

  String line(String result, String reason, String trigger) =>
      'TAG_NOTIFY_LIVENESS result=$result reason=$reason trigger=$trigger';

  test('checks at +5 s, +60 s, +3 min after connect, then every 10 min', () {
    fakeAsync((async) {
      monitor.onLink(connected: true, deviceKey: 'tag', trigger: 'pair');
      async.elapse(const Duration(seconds: 4));
      expect(probes, 0);
      async.elapse(const Duration(seconds: 10));
      expect(probes, 1);
      async.elapse(const Duration(seconds: 60));
      expect(probes, 2);
      async.elapse(const Duration(minutes: 3));
      expect(probes, 3);
      async.elapse(const Duration(minutes: 7));
      expect(probes, 4, reason: 'periodic at 10 min');
      expect(log.first, line('ok', 'reply_received', 'pair'));
    });
  });

  test('an SOS that starts after two misses defers the reconnect until it '
      'is over; the whole check runs again', () {
    fakeAsync((async) {
      monitor.onLink(connected: true, deviceKey: 'tag');
      replies.addAll([
        TagNotifyProbeResult.noReply,
        TagNotifyProbeResult.noReply,
      ]);
      // SOS starts while the second probe is waiting for its reply.
      async.elapse(const Duration(seconds: 5) + const Duration(seconds: 9));
      skip = 'sos_active';
      async.elapse(const Duration(seconds: 8));
      expect(recoveries, 0, reason: 'never reconnect during an SOS');
      expect(log, contains(line('skipped', 'sos_active', 'reconnect')));
      final probesDuringSos = probes;
      async.elapse(const Duration(minutes: 2));
      expect(probes, probesDuringSos, reason: 'no probe during an SOS');
      expect(recoveries, 0);

      skip = null;
      replies.addAll([
        TagNotifyProbeResult.noReply,
        TagNotifyProbeResult.noReply,
      ]);
      async.elapse(const Duration(seconds: 40));
      expect(recoveries, 1);
    });
  });

  test('a failed write never counts as missed and never recovers', () {
    fakeAsync((async) {
      monitor.onLink(connected: true, deviceKey: 'tag');
      replies.addAll([
        TagNotifyProbeResult.noReply,
        TagNotifyProbeResult.writeFailed,
        TagNotifyProbeResult.noReply,
        TagNotifyProbeResult.writeFailed,
      ]);
      async.elapse(const Duration(minutes: 4));
      expect(recoveries, 0);
      expect(restart, isEmpty);
      expect(log, contains(line('skipped', 'write_failed', 'reconnect')));
    });
  });

  test('M1: an SOS that starts during probe #2 after a recovery never raises '
      'restartRequired; it is raised once the SOS is over', () {
    fakeAsync((async) {
      monitor.onLink(connected: true, deviceKey: 'tag');
      replies.addAll(List.filled(2, TagNotifyProbeResult.noReply));
      async.elapse(const Duration(seconds: 30));
      expect(recoveries, 1);
      monitor.onLink(connected: false, deviceKey: 'tag');
      monitor.onLink(connected: true, deviceKey: 'tag');
      replies.addAll(List.filled(2, TagNotifyProbeResult.noReply));
      // +5 s check: probe #1 misses (8 s), SOS starts during probe #2.
      async.elapse(const Duration(seconds: 5 + 9));
      skip = 'sos_active';
      async.elapse(const Duration(minutes: 2));
      expect(restart, isEmpty, reason: 'never raised during an SOS');
      expect(monitor.restartRequired, isFalse);

      skip = null;
      replies.addAll(List.filled(2, TagNotifyProbeResult.noReply));
      async.elapse(const Duration(seconds: 40));
      expect(restart, [true]);
      expect(recoveries, 1, reason: 'no second reconnect');
    });
  });

  test('a TAG that never answered a 0x23 this session is never dropped and '
      'never asks for a restart', () {
    fakeAsync((async) {
      proven = false;
      monitor.onLink(connected: true, deviceKey: 'tag');
      replies.addAll(List.filled(6, TagNotifyProbeResult.noReply));
      async.elapse(const Duration(minutes: 4));
      expect(recoveries, 0);
      expect(restart, isEmpty);
      expect(
        log,
        contains(line('skipped', 'unproven_status_support', 'reconnect')),
      );
    });
  });

  test('native owner: no probe, no polling', () {
    fakeAsync((async) {
      skip = 'native_owner';
      monitor.onLink(connected: true, deviceKey: 'tag');
      monitor.onResume();
      async.elapse(const Duration(minutes: 30));
      expect(probes, 0);
      expect(recoveries, 0);
    });
  });

  test('disconnect, unpair and dispose cancel everything; unpair clears '
      'restartRequired', () {
    fakeAsync((async) {
      monitor.onLink(connected: true, deviceKey: 'tag');
      replies.addAll(List.filled(4, TagNotifyProbeResult.noReply));
      async.elapse(const Duration(seconds: 30));
      expect(recoveries, 1);
      // The recovery reconnect: drop + reconnect, still no reply.
      monitor.onLink(connected: false, deviceKey: 'tag');
      monitor.onLink(connected: true, deviceKey: 'tag');
      async.elapse(const Duration(seconds: 30));
      expect(restart, [true]);
      expect(monitor.restartRequired, isTrue);
      expect(
        log,
        contains(line('failed', 'no_reply_after_recovery', 'recovery')),
      );

      monitor.onLink(connected: false, deviceKey: null);
      expect(restart, [true, false]);
      final before = probes;
      async.elapse(const Duration(hours: 1));
      expect(probes, before);

      monitor.onLink(connected: true, deviceKey: 'tag');
      monitor.dispose();
      async.elapse(const Duration(hours: 1));
      expect(probes, before);
    });
  });
}
