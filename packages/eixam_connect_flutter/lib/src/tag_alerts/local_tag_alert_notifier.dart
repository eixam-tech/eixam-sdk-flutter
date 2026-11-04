import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'tag_alert_notification_ids.dart';

/// Default [TagAlertNotifier] over `flutter_local_notifications`.
///
/// - Uses [TagAlertNotificationIds] ids and `tag_alert:` payloads only, so it
///   can neither replace nor cancel an SOS, DMP or any other notification.
/// - Never calls `initialize` on the shared plugin itself: that would replace
///   the process-wide response callback. [ensureInitialized] delegates to the
///   component that already owns it. It is awaited only before showing or
///   scheduling, never on cancel paths.
/// - Scheduling relies on the plugin's native persistence and boot receiver
///   (Android) / `UNUserNotificationCenter` (iOS); nothing is stored here.
/// - Operations are serialized, so rapid reschedules cannot interleave.
final class LocalTagAlertNotifier implements TagAlertNotifier {
  LocalTagAlertNotifier({
    required FlutterLocalNotificationsPlugin plugin,
    required Future<void> Function() ensureInitialized,
    TagAlertTextResolver? textResolver,
    DateTime Function()? clock,
  }) : _plugin = plugin,
       _ensureInitialized = ensureInitialized,
       _resolver = textResolver ?? defaultTagAlertText,
       _clock = clock ?? DateTime.now;

  final FlutterLocalNotificationsPlugin _plugin;
  final Future<void> Function() _ensureInitialized;
  final TagAlertTextResolver _resolver;
  final DateTime Function() _clock;
  Future<void> _tail = Future<void>.value();

  /// Ids this instance already resolved for a slot. A push for a cached slot
  /// costs one platform call (`zonedSchedule`, which replaces the pending alert
  /// with the same id) instead of three. Other slots avoid cached ids when they
  /// allocate, so a cached id cannot be taken from under its slot.
  final Map<TagAlertSlot, int> _slotIds = <TagAlertSlot, int>{};

  static const String channelName = 'TAG alerts';
  static const String channelDescription =
      'Battery and connection notices for your TAG';

  @override
  Future<void> show(TagAlert alert) => _serialize(() async {
    await _ensureInitialized();
    final slot = TagAlertSlot(alert.deviceId, alert.kind);
    final id = await _idFor(slot);
    // A pending alarm with the same id would otherwise still fire later.
    await _plugin.cancel(id: id);
    await _plugin.show(
      id: id,
      title: _text(alert).title,
      body: _text(alert).body,
      notificationDetails: _details,
      payload: TagAlertPayload.encode(alert.deviceId, alert.kind),
    );
  });

  @override
  Future<void> schedule(TagAlert alert, DateTime at) => _serialize(() async {
    await _ensureInitialized();
    final slot = TagAlertSlot(alert.deviceId, alert.kind);
    final id = await _idFor(slot);
    if (!at.isAfter(_clock().add(const Duration(seconds: 1)))) {
      // The moment already passed (for example the app was suspended): the
      // condition holds, so tell the user now instead of dropping the alert.
      await _plugin.cancel(id: id);
      await _plugin.show(
        id: id,
        title: _text(alert).title,
        body: _text(alert).body,
        notificationDetails: _details,
        payload: TagAlertPayload.encode(alert.deviceId, alert.kind),
      );
      return;
    }
    // Same id replaces the pending alarm atomically in the plugin.
    await _plugin.zonedSchedule(
      id: id,
      title: _text(alert).title,
      body: _text(alert).body,
      scheduledDate: tz.TZDateTime.from(at, tz.UTC),
      notificationDetails: _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: TagAlertPayload.encode(alert.deviceId, alert.kind),
    );
  });

  @override
  Future<void> cancel(String deviceId, TagAlertKind kind) =>
      _cancelWhere((slot) => slot.deviceKey == deviceId && slot.kind == kind);

  @override
  Future<void> cancelAllForDevice(String deviceId) =>
      _cancelWhere((slot) => slot.deviceKey == deviceId);

  @override
  Future<void> cancelAll() => _cancelWhere((_) => true);

  Future<void> _cancelWhere(bool Function(TagAlertSlot slot) test) =>
      _serialize(() async {
        _slotIds.removeWhere((slot, _) => test(slot));
        final inventory = await _inventory();
        for (final entry in inventory.owners.entries) {
          if (test(entry.value)) {
            await _plugin.cancel(id: entry.key);
          }
        }
      });

  TagAlertText _text(TagAlert alert) {
    try {
      final text = _resolver(alert);
      if (text.title.trim().isNotEmpty && text.body.trim().isNotEmpty) {
        return text;
      }
    } catch (_) {
      // A faulty host resolver must not drop the alert.
    }
    return defaultTagAlertText(alert);
  }

  NotificationDetails get _details => const NotificationDetails(
    android: AndroidNotificationDetails(
      TagAlertPayload.channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
      interruptionLevel: InterruptionLevel.active,
    ),
  );

  /// Pending and delivered notifications that matter for id allocation:
  /// TAG alert owners by id, and ids inside the reserved range that somebody
  /// else holds (which must be probed around, never reused).
  Future<_Inventory> _inventory() async {
    final owners = <int, TagAlertSlot>{};
    final foreign = <int>{};
    void note(int? id, String? payload) {
      if (id == null) return;
      final slot = TagAlertPayload.decode(payload);
      if (slot != null) {
        owners[id] = slot;
      } else if (TagAlertNotificationIds.contains(id)) {
        foreign.add(id);
      }
    }

    try {
      for (final request in await _plugin.pendingNotificationRequests()) {
        note(request.id, request.payload);
      }
    } on UnimplementedError {
      // Platform without pending listing: nothing to enumerate.
    }
    try {
      for (final active in await _plugin.getActiveNotifications()) {
        note(active.id, active.payload);
      }
    } on UnimplementedError {
      // Platform without active listing.
    }
    return _Inventory(owners, foreign);
  }

  Future<int> _idFor(TagAlertSlot slot) async {
    final cached = _slotIds[slot];
    if (cached != null) return cached;
    final id = _resolveId(slot, await _inventory());
    _slotIds[slot] = id;
    return id;
  }

  int _resolveId(TagAlertSlot slot, _Inventory inventory) {
    // Reuse the slot's existing id so a reschedule replaces in place.
    for (final entry in inventory.owners.entries) {
      if (entry.value == slot) return entry.key;
    }
    final reservedByOthers = <int>{
      for (final entry in _slotIds.entries)
        if (entry.key != slot) entry.value,
    };
    var id = TagAlertNotificationIds.candidate(slot.deviceKey, slot.kind);
    for (var i = 0; i < TagAlertNotificationIds.rangeSize; i++) {
      if (!inventory.owners.containsKey(id) &&
          !inventory.foreign.contains(id) &&
          !reservedByOthers.contains(id)) {
        return id;
      }
      id = TagAlertNotificationIds.next(id);
    }
    throw StateError('TAG alert notification id range exhausted');
  }

  Future<void> _serialize(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @visibleForTesting
  Future<void> flush() => _tail;
}

final class _Inventory {
  _Inventory(this.owners, this.foreign);

  final Map<int, TagAlertSlot> owners;
  final Set<int> foreign;
}
