import '../enums/device_battery_level.dart';
import 'tag_alert.dart';

/// Battery band of a TAG, from the TAG's own 2-bit battery level (or an exact
/// `0x23` percentage mapped to the same bands). Never an exact percentage.
enum TagBatteryBand {
  /// 60 % or more.
  ok,

  /// 30-59 %.
  medium,

  /// 10-29 %.
  below30,

  /// Under 10 %.
  below10;

  static TagBatteryBand? fromLevel(DeviceBatteryLevel? level) {
    switch (level) {
      case DeviceBatteryLevel.ok:
        return TagBatteryBand.ok;
      case DeviceBatteryLevel.medium:
        return TagBatteryBand.medium;
      case DeviceBatteryLevel.low:
        return TagBatteryBand.below30;
      case DeviceBatteryLevel.critical:
        return TagBatteryBand.below10;
      case null:
        return null;
    }
  }

  static TagBatteryBand? fromPercent(int? percent) =>
      fromLevel(DeviceBatteryLevel.fromPercentage(percent));
}

/// Persisted per-TAG alert cycle: which thresholds have already alerted since
/// the battery was last confirmed above them.
final class TagBatteryCycle {
  const TagBatteryCycle({this.firedBelow30 = false, this.firedBelow10 = false});

  /// Strict decoder: throws [FormatException] for anything unsupported.
  factory TagBatteryCycle.fromJson(Object? json) {
    if (json is! Map<String, Object?> ||
        json['v'] != schemaVersion ||
        json['firedBelow30'] is! bool ||
        json['firedBelow10'] is! bool) {
      throw const FormatException('Unsupported TAG battery cycle.');
    }
    return TagBatteryCycle(
      firedBelow30: json['firedBelow30']! as bool,
      firedBelow10: json['firedBelow10']! as bool,
    );
  }

  static const int schemaVersion = 1;
  static const TagBatteryCycle none = TagBatteryCycle();

  final bool firedBelow30;
  final bool firedBelow10;

  bool get isNone => !firedBelow30 && !firedBelow10;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': schemaVersion,
    'firedBelow30': firedBelow30,
    'firedBelow10': firedBelow10,
  };

  @override
  bool operator ==(Object other) =>
      other is TagBatteryCycle &&
      other.firedBelow30 == firedBelow30 &&
      other.firedBelow10 == firedBelow10;

  @override
  int get hashCode => Object.hash(firedBelow30, firedBelow10);

  @override
  String toString() =>
      'TagBatteryCycle(firedBelow30: $firedBelow30, firedBelow10: $firedBelow10)';
}

/// Transient confirmation state. Never persisted: a new connection epoch
/// always restarts it.
final class TagBatteryStreak {
  const TagBatteryStreak({
    required this.epoch,
    required this.band,
    required this.count,
    required this.lastSourceKey,
  });

  final int epoch;
  final TagBatteryBand band;
  final int count;
  final String lastSourceKey;
}

final class TagBatteryAlertDecision {
  const TagBatteryAlertDecision({
    required this.cycle,
    required this.streak,
    this.threshold,
    this.clearDeliveredAlert = false,
  });

  /// The alert to show now, if any.
  final TagAlertBatteryThreshold? threshold;

  /// The battery is confirmed healthy again: remove the delivered alert.
  final bool clearDeliveredAlert;

  final TagBatteryCycle cycle;
  final TagBatteryStreak streak;
}

/// Pure low-battery policy ("like a phone").
///
/// - A band is confirmed after [confirmationReadings] consecutive live
///   readings from distinct samples within one connection epoch. The same
///   confirmation applies to firing and to rearming, so a single stray
///   reading changes nothing.
/// - Confirmed `below30` alerts unless `firedBelow30`; confirmed `below10`
///   alerts unless `firedBelow10` and also marks `firedBelow30`, so a direct
///   jump from `>= 30 %` to `< 10 %` produces one alert.
/// - `firedBelow10` is cleared by a confirmed `below30`, `medium` or `ok`;
///   `firedBelow30` by a confirmed `medium` or `ok`. The alert therefore fires
///   again each time a threshold is crossed downwards after having been above.
/// - The delivered alert is removed only on a confirmed `ok`.
/// - With alerts disabled the cycle is still tracked (rearming) but nothing is
///   fired or marked, so re-enabling while low alerts after confirmation.
abstract final class TagBatteryAlertPolicy {
  static const int confirmationReadings = 2;

  static TagBatteryAlertDecision evaluate({
    required TagBatteryBand band,
    required String sourceKey,
    required int epoch,
    required TagBatteryCycle cycle,
    required TagBatteryStreak? streak,
    required bool alertsEnabled,
  }) {
    final sameStreak =
        streak != null && streak.epoch == epoch && streak.band == band;
    if (streak != null &&
        streak.epoch == epoch &&
        streak.lastSourceKey == sourceKey) {
      // The same sample delivered again is not a second reading.
      return TagBatteryAlertDecision(cycle: cycle, streak: streak);
    }
    final count = sameStreak ? streak.count + 1 : 1;
    final next = TagBatteryStreak(
      epoch: epoch,
      band: band,
      count: count,
      lastSourceKey: sourceKey,
    );
    if (count < confirmationReadings) {
      return TagBatteryAlertDecision(cycle: cycle, streak: next);
    }

    var fired30 = cycle.firedBelow30;
    var fired10 = cycle.firedBelow10;
    TagAlertBatteryThreshold? threshold;
    var clear = false;
    switch (band) {
      case TagBatteryBand.ok:
        fired30 = false;
        fired10 = false;
        clear = count == confirmationReadings;
      case TagBatteryBand.medium:
        fired30 = false;
        fired10 = false;
      case TagBatteryBand.below30:
        fired10 = false;
        if (!fired30 && alertsEnabled) {
          threshold = TagAlertBatteryThreshold.below30;
          fired30 = true;
        }
      case TagBatteryBand.below10:
        if (!fired10 && alertsEnabled) {
          threshold = TagAlertBatteryThreshold.below10;
          fired10 = true;
          fired30 = true;
        }
    }
    return TagBatteryAlertDecision(
      cycle: TagBatteryCycle(firedBelow30: fired30, firedBelow10: fired10),
      streak: next,
      threshold: threshold,
      clearDeliveredAlert: clear,
    );
  }
}
