import 'dart:convert';

import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Notification id range reserved for TAG alerts.
///
/// `flutter_local_notifications` is a process-wide singleton and its ids share
/// one namespace with the Android `NotificationManager`. Ids in use today:
///
/// | Owner | Ids |
/// | --- | --- |
/// | Android protection foreground service | 6021, 6022, 6023, 6024 |
/// | Android telemetry foreground service | 6031 |
/// | Commercial app DMP | 41001, 41002 |
/// | Commercial app SDK-SOS mirror | 42001..42008 |
/// | Nearby text (native and app) | 43000 |
/// | Commercial app activity | 44001 |
/// | SDK `LocalNotificationsRepository` default | pseudo-random in
///   `[0, 2^31-2]`, excluding this range (see `nextSafeNotificationId`) |
/// | **TAG alerts** | [rangeStart]..[rangeEnd] |
abstract final class TagAlertNotificationIds {
  static const int rangeStart = 1000000000;
  static const int rangeSize = 100000;
  static const int rangeEnd = rangeStart + rangeSize - 1;

  static bool contains(int id) => id >= rangeStart && id <= rangeEnd;

  /// Moves [id] out of the reserved range. Used by the SDK's generic
  /// notification id generator so that it can never collide with a TAG alert.
  static int outsideRange(int id) => contains(id) ? id - rangeSize : id;

  /// Stable first-choice id for a slot (FNV-1a 32 bit over key and kind).
  static int candidate(String deviceKey, TagAlertKind kind) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode('$deviceKey\u0000${kind.name}')) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return rangeStart + hash % rangeSize;
  }

  /// Next id in the range, wrapping, for collision probing.
  static int next(int id) => id >= rangeEnd ? rangeStart : id + 1;
}

/// Payload carried by every TAG alert notification:
/// `tag_alert:<kind>:<hex(utf8(deviceKey))>`.
///
/// The device key is hex-encoded on purpose: hosts classify SOS notifications
/// by substring (`sos`) over payload, tag and channel, and arbitrary device
/// ids must never be able to produce that substring. Hex digits cannot.
abstract final class TagAlertPayload {
  static const String prefix = 'tag_alert:';
  static const String channelId = 'eixam_tag_alerts';

  static bool isTagAlert(String? payload) =>
      payload != null && payload.startsWith(prefix);

  static String encode(String deviceKey, TagAlertKind kind) {
    final hex = utf8
        .encode(deviceKey)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '$prefix${_wire(kind)}:$hex';
  }

  static TagAlertSlot? decode(String? payload) {
    if (!isTagAlert(payload)) return null;
    final parts = payload!.substring(prefix.length).split(':');
    if (parts.length != 2) return null;
    final kind = _kindFromWire(parts[0]);
    final hex = parts[1];
    if (kind == null || hex.isEmpty || hex.length.isOdd) return null;
    try {
      final bytes = <int>[
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ];
      return TagAlertSlot(utf8.decode(bytes), kind);
    } on FormatException {
      return null;
    }
  }

  static String _wire(TagAlertKind kind) => switch (kind) {
    TagAlertKind.batteryLow => 'battery_low',
    TagAlertKind.tagDisconnected => 'tag_disconnected',
    TagAlertKind.bluetoothOff => 'bluetooth_off',
  };

  static TagAlertKind? _kindFromWire(String wire) {
    for (final kind in TagAlertKind.values) {
      if (_wire(kind) == wire) return kind;
    }
    return null;
  }
}

/// One (device, kind) notification slot.
final class TagAlertSlot {
  const TagAlertSlot(this.deviceKey, this.kind);

  final String deviceKey;
  final TagAlertKind kind;

  @override
  bool operator ==(Object other) =>
      other is TagAlertSlot &&
      other.deviceKey == deviceKey &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(deviceKey, kind);
}
