import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

/// Drives the policy with a sequence of readings, like a TAG discharging.
final class _Sim {
  _Sim({this.enabled = true});

  bool enabled;
  TagBatteryCycle cycle = TagBatteryCycle.none;
  TagBatteryStreak? streak;
  int epoch = 1;
  int _n = 0;
  final List<TagAlertBatteryThreshold> alerts = [];
  int clears = 0;

  TagBatteryAlertDecision read(TagBatteryBand band, {String? key}) {
    final decision = TagBatteryAlertPolicy.evaluate(
      band: band,
      sourceKey: key ?? 's${_n++}',
      epoch: epoch,
      cycle: cycle,
      streak: streak,
      alertsEnabled: enabled,
    );
    cycle = decision.cycle;
    streak = decision.streak;
    if (decision.threshold != null) alerts.add(decision.threshold!);
    if (decision.clearDeliveredAlert) clears++;
    return decision;
  }

  void twice(TagBatteryBand band) {
    read(band);
    read(band);
  }

  void reconnect() => epoch++;
}

const ok = TagBatteryBand.ok;
const medium = TagBatteryBand.medium;
const b30 = TagBatteryBand.below30;
const b10 = TagBatteryBand.below10;
const t30 = TagAlertBatteryThreshold.below30;
const t10 = TagAlertBatteryThreshold.below10;

void main() {
  group('bands', () {
    test('map the four 2-bit levels and exact percentages', () {
      expect(TagBatteryBand.fromLevel(DeviceBatteryLevel.ok), ok);
      expect(TagBatteryBand.fromLevel(DeviceBatteryLevel.medium), medium);
      expect(TagBatteryBand.fromLevel(DeviceBatteryLevel.low), b30);
      expect(TagBatteryBand.fromLevel(DeviceBatteryLevel.critical), b10);
      expect(TagBatteryBand.fromLevel(null), isNull);
      expect(TagBatteryBand.fromPercent(100), ok);
      expect(TagBatteryBand.fromPercent(60), ok);
      expect(TagBatteryBand.fromPercent(59), medium);
      expect(TagBatteryBand.fromPercent(30), medium);
      expect(TagBatteryBand.fromPercent(29), b30);
      expect(TagBatteryBand.fromPercent(10), b30);
      expect(TagBatteryBand.fromPercent(9), b10);
      expect(TagBatteryBand.fromPercent(1), b10);
      expect(TagBatteryBand.fromPercent(null), isNull);
      expect(TagBatteryBand.fromPercent(101), isNull);
    });
  });

  group('confirmation', () {
    test('a single reading never fires', () {
      final sim = _Sim()..read(b30);
      expect(sim.alerts, isEmpty);
      expect(sim.cycle, TagBatteryCycle.none);
    });

    test('two consecutive distinct readings fire once', () {
      final sim = _Sim()..twice(b30);
      expect(sim.alerts, [t30]);
      sim.read(b30);
      sim.read(b30);
      expect(sim.alerts, [t30]);
    });

    test('the same sample delivered twice is one reading', () {
      final sim = _Sim()
        ..read(b30, key: 'same')
        ..read(b30, key: 'same');
      expect(sim.alerts, isEmpty);
      sim.read(b30, key: 'other');
      expect(sim.alerts, [t30]);
    });

    test('a stray reading in another band resets the streak', () {
      final sim = _Sim()
        ..read(b30)
        ..read(medium)
        ..read(b30);
      expect(sim.alerts, isEmpty);
      sim.read(b30);
      expect(sim.alerts, [t30]);
    });

    test('a new connection epoch restarts the streak', () {
      final sim = _Sim()..read(b30);
      sim.reconnect();
      sim.read(b30);
      expect(sim.alerts, isEmpty);
      sim.read(b30);
      expect(sim.alerts, [t30]);
    });
  });

  group('firing', () {
    test('30 then 10 produce one alert each', () {
      final sim = _Sim()
        ..twice(ok)
        ..twice(medium)
        ..twice(b30)
        ..twice(b10);
      expect(sim.alerts, [t30, t10]);
    });

    test('a direct jump from >=30 to <10 gives one alert (10 %)', () {
      for (final start in [ok, medium]) {
        final sim = _Sim()
          ..twice(start)
          ..twice(b10);
        expect(sim.alerts, [t10], reason: '$start');
        expect(
          sim.cycle,
          const TagBatteryCycle(firedBelow30: true, firedBelow10: true),
        );
        // And it does not add a 30 % alert on the way back up to 10-29.
        sim.twice(b30);
        expect(sim.alerts, [t10]);
      }
    });
  });

  group('rearm like a phone', () {
    test('confirmed 9 -> 11 -> 9 fires the 10 % alert twice', () {
      final sim = _Sim()
        ..twice(ok)
        ..twice(b10);
      expect(sim.alerts, [t10]);
      sim.twice(b30); // 11 %
      expect(sim.cycle.firedBelow10, isFalse);
      sim.twice(b10); // 9 %
      expect(sim.alerts, [t10, t10]);
    });

    test('confirmed 29 -> 31 -> 29 fires the 30 % alert twice', () {
      final sim = _Sim()
        ..twice(ok)
        ..twice(b30);
      expect(sim.alerts, [t30]);
      sim.twice(medium); // 31 %
      expect(sim.cycle, TagBatteryCycle.none);
      sim.twice(b30); // 29 %
      expect(sim.alerts, [t30, t30]);
    });

    test('rising from <10 to 10-29 rearms 10 % but not 30 %', () {
      final sim = _Sim()
        ..twice(b30)
        ..twice(b10)
        ..twice(b30);
      expect(sim.alerts, [t30, t10]);
      expect(sim.cycle, const TagBatteryCycle(firedBelow30: true));
      sim.twice(b10);
      expect(sim.alerts, [t30, t10, t10]);
    });

    test(
      'a single stray reading across a boundary fires or rearms nothing',
      () {
        final sim = _Sim()
          ..twice(b30)
          ..read(medium) // stray: must NOT rearm
          ..twice(b30);
        expect(sim.alerts, [t30]);
        final sim2 = _Sim()
          ..twice(medium)
          ..read(b30) // stray: must NOT fire
          ..twice(medium);
        expect(sim2.alerts, isEmpty);
        final sim3 = _Sim()
          ..twice(b10)
          ..read(b30) // stray: must NOT rearm
          ..twice(b10);
        expect(sim3.alerts, [t10]);
      },
    );

    test('a streak longer than two does not re-fire', () {
      final sim = _Sim()..twice(b30);
      for (var i = 0; i < 10; i++) {
        sim.read(b30);
      }
      expect(sim.alerts, [t30]);
    });
  });

  group('baseline after reconnect', () {
    test(
      'reconnecting already low and never alerted fires after 2 readings',
      () {
        for (final band in [b30, b10]) {
          final sim = _Sim()..reconnect();
          sim.read(band);
          expect(sim.alerts, isEmpty);
          sim.read(band);
          expect(sim.alerts, [band == b30 ? t30 : t10]);
        }
      },
    );

    test('reconnecting already low but already alerted stays silent', () {
      final sim = _Sim()..twice(b30);
      sim.reconnect();
      sim.twice(b30);
      sim.reconnect();
      sim.twice(b30);
      expect(sim.alerts, [t30]);
    });

    test('a persisted cycle prevents a re-fire after restart', () {
      final first = _Sim()..twice(b10);
      expect(first.alerts, [t10]);
      final restored = TagBatteryCycle.fromJson(first.cycle.toJson());
      final after = _Sim()
        ..cycle = restored
        ..reconnect();
      after.twice(b10);
      after.twice(b30);
      expect(after.alerts, isEmpty);
    });
  });

  group('delivered alert removal', () {
    test('only a confirmed ok clears it, once per streak', () {
      final sim = _Sim()
        ..twice(b30)
        ..twice(medium);
      expect(sim.clears, 0);
      sim.read(ok);
      expect(sim.clears, 0);
      sim.read(ok);
      expect(sim.clears, 1);
      sim.read(ok);
      sim.read(ok);
      expect(sim.clears, 1);
    });
  });

  group('alerts disabled', () {
    test('tracks the cycle but never fires or marks', () {
      final sim = _Sim(enabled: false)
        ..twice(b30)
        ..twice(b10);
      expect(sim.alerts, isEmpty);
      expect(sim.cycle, TagBatteryCycle.none);
    });

    test('re-enabling while still low fires after two live readings', () {
      final sim = _Sim(enabled: false)..twice(b30);
      sim.enabled = true;
      sim.read(b30);
      expect(sim.alerts, [t30]);
    });

    test('rearming still works while disabled', () {
      final sim = _Sim()..twice(b30);
      sim.enabled = false;
      sim.twice(medium);
      expect(sim.cycle, TagBatteryCycle.none);
      sim.enabled = true;
      sim.twice(b30);
      expect(sim.alerts, [t30, t30]);
    });
  });

  group('cycle persistence format', () {
    test('round-trips and rejects unsupported data', () {
      for (final cycle in const [
        TagBatteryCycle.none,
        TagBatteryCycle(firedBelow30: true),
        TagBatteryCycle(firedBelow30: true, firedBelow10: true),
      ]) {
        expect(TagBatteryCycle.fromJson(cycle.toJson()), cycle);
      }
      for (final bad in <Object?>[
        null,
        'x',
        {'v': 2, 'firedBelow30': true, 'firedBelow10': true},
        {'v': 1, 'firedBelow30': 'yes', 'firedBelow10': true},
        {'v': 1, 'firedBelow30': true},
      ]) {
        expect(() => TagBatteryCycle.fromJson(bad), throwsFormatException);
      }
    });
  });
}
