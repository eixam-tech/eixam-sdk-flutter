import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

final _t0 = DateTime.utc(2026, 11, 2, 12);
const _five = Duration(minutes: 5);

/// Drives the policy like the controller does.
final class _Sim {
  _Sim({this.after = _five, this.permission = true});

  Duration? after;
  bool permission;
  TagLeaseState state = TagLeaseState.none;
  final List<TagDisconnectAction> log = [];

  TagDisconnectDecision feed(TagLinkSnapshot snapshot) {
    final decision = TagDisconnectAlertPolicy.evaluate(
      snapshot: snapshot,
      state: state,
      disconnectAfter: after,
      permissionAllowed: permission,
    );
    state = decision.state;
    log.addAll(decision.actions);
    return decision;
  }
}

TagLinkSnapshot up(
  DateTime at, {
  bool sos = false,
  bool background = false,
  bool paired = true,
}) => TagLinkSnapshot(
  deviceKey: 'tag-1',
  observedAt: at,
  paired: paired,
  connected: true,
  sosActive: sos,
  backgroundDisarm: background,
);

TagLinkSnapshot down(
  DateTime at, {
  required DateTime since,
  TagDisconnectCause cause = TagDisconnectCause.unexpected,
  DateTime? hold,
  bool sos = false,
  bool background = false,
}) => TagLinkSnapshot(
  deviceKey: 'tag-1',
  observedAt: at,
  paired: true,
  connected: false,
  disconnectedSince: since,
  cause: cause,
  holdUntil: hold,
  sosActive: sos,
  backgroundDisarm: background,
);

TagDisconnectSchedule onlySchedule(TagDisconnectDecision d) =>
    d.actions.whereType<TagDisconnectSchedule>().single;

Set<TagAlertKind> cancelled(TagDisconnectDecision d) => {
  for (final a in d.actions.whereType<TagDisconnectCancel>()) ...a.kinds,
};

void main() {
  group('push interval', () {
    test('is clamp(X/4, 60 s, 10 min)', () {
      Duration p(int minutes) =>
          TagDisconnectAlertPolicy.pushIntervalFor(Duration(minutes: minutes));
      expect(p(5), const Duration(seconds: 75));
      expect(p(15), const Duration(seconds: 225));
      expect(p(30), const Duration(seconds: 450));
      expect(p(60), const Duration(minutes: 10));
      expect(
        TagDisconnectAlertPolicy.pushIntervalFor(const Duration(minutes: 1)),
        const Duration(seconds: 60),
      );
    });
  });

  group('lease while connected', () {
    test('arms at now + X + slack', () {
      final sim = _Sim();
      final d = sim.feed(up(_t0));
      final schedule = onlySchedule(d);
      expect(schedule.kind, TagAlertKind.tagDisconnected);
      expect(schedule.at, _t0.add(_five).add(const Duration(seconds: 75)));
      expect(schedule.elapsed, _five);
      // First arming of this run: a stale alert from an earlier run goes away.
      expect(schedule.clearDelivered, isTrue);
      expect(d.state.phase, TagLeasePhase.leased);
    });

    test('is pushed forward at most once per interval', () {
      final sim = _Sim();
      sim.feed(up(_t0));
      for (var s = 15; s < 75; s += 15) {
        expect(
          sim.feed(up(_t0.add(Duration(seconds: s)))).actions,
          isEmpty,
          reason: '$s s',
        );
      }
      final push = sim.feed(up(_t0.add(const Duration(seconds: 75))));
      expect(
        onlySchedule(push).at,
        _t0
            .add(const Duration(seconds: 75))
            .add(_five)
            .add(const Duration(seconds: 75)),
      );
    });

    test(
      'never fires before X, and at most 1.25 X, after the last contact',
      () {
        for (final minutes in [5, 15, 30, 60]) {
          final x = Duration(minutes: minutes);
          final interval = TagDisconnectAlertPolicy.pushIntervalFor(x);
          final sim = _Sim(after: x);
          var lastFire = sim.feed(up(_t0)).state.fireAt!;
          var lastContact = _t0;
          // 15 s ticks for four hours.
          for (var s = 15; s <= 4 * 3600; s += 15) {
            final at = _t0.add(Duration(seconds: s));
            final d = sim.feed(up(at));
            lastContact = at;
            if (d.actions.isNotEmpty) lastFire = d.state.fireAt!;
            final lead = lastFire.difference(lastContact);
            expect(lead >= x, isTrue, reason: 'X=$minutes at $s s: $lead');
            expect(lead <= x + interval, isTrue, reason: 'X=$minutes: $lead');
          }
        }
      },
    );

    test('the rate of platform pushes is bounded by the interval', () {
      final sim = _Sim();
      var pushes = 0;
      for (var s = 0; s <= 3600; s += 15) {
        pushes += sim.feed(up(_t0.add(Duration(seconds: s)))).actions.length;
      }
      expect(pushes, lessThanOrEqualTo(3600 ~/ 75 + 1));
    });
  });

  group('observed unexpected disconnect', () {
    test('reschedules to exactly disconnectedSince + X', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(seconds: 100));
      final d = sim.feed(down(since, since: since));
      expect(onlySchedule(d).at, since.add(_five));
      expect(onlySchedule(d).kind, TagAlertKind.tagDisconnected);
      expect(d.state.phase, TagLeasePhase.pending);
    });

    test('repeated identical snapshots do nothing', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(seconds: 100));
      sim.feed(down(since, since: since));
      for (var s = 15; s <= 600; s += 15) {
        expect(
          sim.feed(down(since.add(Duration(seconds: s)), since: since)).actions,
          isEmpty,
        );
      }
    });

    test('a reconnect removes the alert (also if delivered) and re-arms', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(minutes: 1));
      sim.feed(down(since, since: since));
      final back = sim.feed(up(since.add(const Duration(minutes: 7))));
      expect(onlySchedule(back).clearDelivered, isTrue);
      expect(back.state.phase, TagLeasePhase.leased);
    });

    test('a disconnect observed in the background still arms exactly', () {
      final sim = _Sim()..feed(up(_t0, background: true));
      expect(sim.state.phase, TagLeasePhase.disarmed);
      final since = _t0.add(const Duration(minutes: 2));
      final d = sim.feed(down(since, since: since, background: true));
      expect(onlySchedule(d).at, since.add(_five));
    });
  });

  group('cold start with the TAG away', () {
    test('an unobserved drop neither schedules nor cancels anything', () {
      final sim = _Sim();
      final d = sim.feed(
        TagLinkSnapshot(
          deviceKey: 'tag-1',
          observedAt: _t0,
          paired: true,
          connected: false,
        ),
      );
      expect(d.actions, isEmpty);
      expect(d.state.phase, TagLeasePhase.disarmed);
    });

    test('the first connection removes an alert left by an earlier run', () {
      final sim = _Sim();
      final d = sim.feed(up(_t0));
      expect(onlySchedule(d).clearDelivered, isTrue);
      // Later pushes do not clear again.
      final push = sim.feed(up(_t0.add(const Duration(seconds: 75))));
      expect(onlySchedule(push).clearDelivered, isFalse);
    });
  });

  group('suppression', () {
    test('a manual disconnect cancels and stays quiet until reconnect', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(minutes: 1));
      final d = sim.feed(
        down(since, since: since, cause: TagDisconnectCause.manual),
      );
      expect(cancelled(d), {
        TagAlertKind.tagDisconnected,
        TagAlertKind.bluetoothOff,
      });
      expect(d.state.phase, TagLeasePhase.suppressed);
      expect(
        sim
            .feed(
              down(
                since.add(const Duration(hours: 3)),
                since: since,
                cause: TagDisconnectCause.manual,
              ),
            )
            .actions,
        isEmpty,
      );
    });

    test('an expected drop holds the alert; it moves to hold + X', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(minutes: 1));
      final hold = since.add(const Duration(seconds: 90));
      final during = sim.feed(
        down(
          since.add(const Duration(seconds: 10)),
          since: since,
          cause: TagDisconnectCause.expected,
          hold: hold,
        ),
      );
      expect(during.state.phase, TagLeasePhase.suppressed);
      expect(cancelled(during), isNotEmpty);
      final after = sim.feed(
        down(
          hold.add(const Duration(seconds: 30)),
          since: since,
          cause: TagDisconnectCause.expected,
          hold: hold,
        ),
      );
      expect(onlySchedule(after).at, hold.add(_five));
    });

    test('an expected drop that reconnects in time never alerts', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(minutes: 1));
      sim.feed(
        down(
          since,
          since: since,
          cause: TagDisconnectCause.expected,
          hold: since.add(const Duration(minutes: 2)),
        ),
      );
      final back = sim.feed(up(since.add(const Duration(seconds: 40))));
      expect(onlySchedule(back).clearDelivered, isTrue);
      expect(back.state.phase, TagLeasePhase.leased);
    });

    test('settings "never", no permission and an unpaired TAG disarm', () {
      for (final setup in <void Function(_Sim)>[
        (s) => s.after = null,
        (s) => s.permission = false,
      ]) {
        final sim = _Sim()..feed(up(_t0));
        setup(sim);
        final d = sim.feed(up(_t0.add(const Duration(minutes: 5))));
        expect(d.state.phase, TagLeasePhase.disarmed);
        expect(cancelled(d), isNotEmpty);
        expect(
          sim.feed(up(_t0.add(const Duration(minutes: 6)))).actions,
          isEmpty,
        );
      }
      final sim = _Sim()..feed(up(_t0));
      final d = sim.feed(
        up(_t0.add(const Duration(minutes: 1)), paired: false),
      );
      expect(d.state.phase, TagLeasePhase.disarmed);
    });

    test('never arms while permission is blocked, arms once granted', () {
      final sim = _Sim(permission: false);
      expect(sim.feed(up(_t0)).actions, isEmpty);
      expect(sim.state.phase, TagLeasePhase.disarmed);
      sim.permission = true;
      expect(
        onlySchedule(sim.feed(up(_t0.add(const Duration(seconds: 15))))),
        isNotNull,
      );
    });
  });

  group('SOS', () {
    test('cancels the lease and a pending alert, re-arms when SOS ends', () {
      final sim = _Sim()..feed(up(_t0));
      final d = sim.feed(up(_t0.add(const Duration(seconds: 30)), sos: true));
      expect(d.state.phase, TagLeasePhase.disarmed);
      expect(cancelled(d), isNotEmpty);
      expect(
        sim.feed(up(_t0.add(const Duration(minutes: 2)), sos: true)).actions,
        isEmpty,
      );
      final ended = sim.feed(up(_t0.add(const Duration(minutes: 3))));
      expect(ended.state.phase, TagLeasePhase.leased);
    });

    test(
      'a drop during SOS is not alerted; after SOS it counts from the drop',
      () {
        final sim = _Sim()..feed(up(_t0));
        final since = _t0.add(const Duration(minutes: 1));
        final during = sim.feed(down(since, since: since, sos: true));
        expect(during.state.phase, TagLeasePhase.disarmed);
        final after = sim.feed(
          down(since.add(const Duration(minutes: 10)), since: since),
        );
        expect(onlySchedule(after).at, since.add(_five));
      },
    );
  });

  group('background disarm (iOS paused)', () {
    test('drops the lease while connected and re-arms on resume', () {
      final sim = _Sim()..feed(up(_t0));
      final paused = sim.feed(
        up(_t0.add(const Duration(seconds: 10)), background: true),
      );
      expect(paused.state.phase, TagLeasePhase.disarmed);
      expect(cancelled(paused), isNotEmpty);
      final resumed = sim.feed(up(_t0.add(const Duration(minutes: 30))));
      expect(resumed.state.phase, TagLeasePhase.leased);
    });
  });

  group('background disarms only the lease, never arm-at-disconnect', () {
    TagLinkSnapshot downInBackground(
      DateTime since, {
      TagDisconnectCause cause = TagDisconnectCause.unexpected,
      DateTime? hold,
      bool sos = false,
      bool paired = true,
    }) => TagLinkSnapshot(
      deviceKey: 'tag-1',
      observedAt: since,
      paired: paired,
      connected: false,
      disconnectedSince: since,
      cause: cause,
      holdUntil: hold,
      sosActive: sos,
      backgroundDisarm: true,
    );

    test(
      'backgrounded + observed unexpected drop => scheduled at drop + X',
      () {
        for (final start in [
          TagLeaseState.none,
          const TagLeaseState(phase: TagLeasePhase.leased, fireAt: null),
        ]) {
          final sim = _Sim()..state = start;
          final since = _t0.add(const Duration(minutes: 3));
          final d = sim.feed(downInBackground(since));
          expect(onlySchedule(d).kind, TagAlertKind.tagDisconnected);
          expect(onlySchedule(d).at, since.add(_five));
          expect(d.state.phase, TagLeasePhase.pending);
        }
      },
    );

    test('backgrounded + connected + no events => nothing scheduled', () {
      final sim = _Sim();
      for (var s = 0; s <= 3600; s += 30) {
        final d = sim.feed(up(_t0.add(Duration(seconds: s)), background: true));
        expect(d.actions.whereType<TagDisconnectSchedule>(), isEmpty);
      }
      expect(sim.log, isEmpty, reason: 'not even a cancel from a clean state');
      expect(sim.state.phase, TagLeasePhase.disarmed);
    });

    test('backgrounded + connected after being armed => only cancels', () {
      final sim = _Sim()..feed(up(_t0));
      final d = sim.feed(
        up(_t0.add(const Duration(seconds: 30)), background: true),
      );
      expect(d.actions.whereType<TagDisconnectSchedule>(), isEmpty);
      expect(cancelled(d), isNotEmpty);
    });

    test('backgrounded + SOS active + drop => nothing', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(minutes: 1));
      final d = sim.feed(downInBackground(since, sos: true));
      expect(d.actions.whereType<TagDisconnectSchedule>(), isEmpty);
      expect(d.state.phase, TagLeasePhase.disarmed);
    });

    test('backgrounded + Bluetooth off => bluetoothOff kind at since + X', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(minutes: 1));
      final d = sim.feed(
        downInBackground(since, cause: TagDisconnectCause.bluetoothOff),
      );
      expect(onlySchedule(d).kind, TagAlertKind.bluetoothOff);
      expect(onlySchedule(d).at, since.add(_five));
    });

    test('every usual suppression still applies in the background', () {
      final since = _t0.add(const Duration(minutes: 1));
      final manual = _Sim()..feed(up(_t0));
      expect(
        manual
            .feed(downInBackground(since, cause: TagDisconnectCause.manual))
            .actions
            .whereType<TagDisconnectSchedule>(),
        isEmpty,
      );
      final held = _Sim()..feed(up(_t0));
      expect(
        held
            .feed(
              downInBackground(
                since,
                cause: TagDisconnectCause.expected,
                hold: since.add(const Duration(minutes: 2)),
              ),
            )
            .actions
            .whereType<TagDisconnectSchedule>(),
        isEmpty,
      );
      final never = _Sim()..feed(up(_t0));
      never.after = null;
      expect(
        never
            .feed(downInBackground(since))
            .actions
            .whereType<TagDisconnectSchedule>(),
        isEmpty,
      );
      final noPermission = _Sim()..feed(up(_t0));
      noPermission.permission = false;
      expect(
        noPermission
            .feed(downInBackground(since))
            .actions
            .whereType<TagDisconnectSchedule>(),
        isEmpty,
      );
      final unpaired = _Sim()..feed(up(_t0));
      expect(
        unpaired
            .feed(downInBackground(since, paired: false))
            .actions
            .whereType<TagDisconnectSchedule>(),
        isEmpty,
      );
    });

    test(
      'an expected drop in the background alerts once the hold has ended',
      () {
        final sim = _Sim()..feed(up(_t0));
        final since = _t0.add(const Duration(minutes: 1));
        final hold = since.add(const Duration(seconds: 90));
        sim.feed(
          downInBackground(
            since,
            cause: TagDisconnectCause.expected,
            hold: hold,
          ),
        );
        final d = sim.feed(
          TagLinkSnapshot(
            deviceKey: 'tag-1',
            observedAt: hold.add(const Duration(seconds: 30)),
            paired: true,
            connected: false,
            disconnectedSince: since,
            cause: TagDisconnectCause.expected,
            holdUntil: hold,
            backgroundDisarm: true,
          ),
        );
        expect(onlySchedule(d).at, hold.add(_five));
      },
    );

    test('a reconnect while backgrounded removes the pending alert', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(minutes: 1));
      sim.feed(downInBackground(since));
      final d = sim.feed(
        up(since.add(const Duration(minutes: 2)), background: true),
      );
      expect(cancelled(d), contains(TagAlertKind.tagDisconnected));
      expect(d.actions.whereType<TagDisconnectSchedule>(), isEmpty);
    });
  });

  group('Bluetooth off', () {
    test(
      'raises the bluetoothOff kind at since + X and replaces the lease',
      () {
        final sim = _Sim()..feed(up(_t0));
        final since = _t0.add(const Duration(minutes: 1));
        final d = sim.feed(
          down(since, since: since, cause: TagDisconnectCause.bluetoothOff),
        );
        expect(onlySchedule(d).kind, TagAlertKind.bluetoothOff);
        expect(onlySchedule(d).at, since.add(_five));
        expect(cancelled(d), {TagAlertKind.tagDisconnected});
      },
    );

    test('Bluetooth back on and reconnected removes it and re-arms', () {
      final sim = _Sim()..feed(up(_t0));
      final since = _t0.add(const Duration(minutes: 1));
      sim.feed(
        down(since, since: since, cause: TagDisconnectCause.bluetoothOff),
      );
      final back = sim.feed(up(since.add(const Duration(minutes: 1))));
      expect(onlySchedule(back).kind, TagAlertKind.tagDisconnected);
      expect(cancelled(back), {TagAlertKind.bluetoothOff});
    });
  });
}
