import 'package:eixam_connect_flutter/src/tag_alerts/tag_alert_notification_ids.dart';
import 'package:flutter/services.dart';

/// Stateful stand-in for the OS notification center, behind the real plugin.
final class FakeNotificationCenter {
  final Map<int, Map<String, Object?>> pending = {};
  final Map<int, Map<String, Object?>> delivered = {};
  final List<String> log = [];

  /// When set, `show` and `zonedSchedule` fail like a plugin that was never
  /// initialized (host-managed notifications before the host's own init).
  bool rejectUntilInitialized = false;

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'initialize':
        return true;
      case 'getNotificationAppLaunchDetails':
        return <String, Object?>{'notificationLaunchedApp': false};
      case 'show':
        if (rejectUntilInitialized) {
          throw PlatformException(code: 'not_initialized');
        }
        final map = Map<String, Object?>.from(args as Map);
        log.add('show:${map['id']}');
        delivered[map['id']! as int] = map;
        return null;
      case 'zonedSchedule':
        if (rejectUntilInitialized) {
          throw PlatformException(code: 'not_initialized');
        }
        final map = Map<String, Object?>.from(args as Map);
        log.add('schedule:${map['id']}');
        pending[map['id']! as int] = map;
        return null;
      case 'cancel':
        final id = args is int ? args : (args as Map)['id'] as int;
        log.add('cancel:$id');
        pending.remove(id);
        delivered.remove(id);
        return null;
      case 'pendingNotificationRequests':
        return [
          for (final e in pending.entries)
            {
              'id': e.key,
              'title': e.value['title'],
              'body': e.value['body'],
              'payload': e.value['payload'],
            },
        ];
      case 'getActiveNotifications':
        return [
          for (final e in delivered.entries)
            {
              'id': e.key,
              'title': e.value['title'],
              'body': e.value['body'],
              'payload': e.value['payload'],
            },
        ];
    }
    return null;
  }

  void seedSos() {
    pending[42001] = {'id': 42001, 'payload': 'sos:incident-1'};
    delivered[42002] = {'id': 42002, 'payload': 'sos:incident-1'};
    delivered[6023] = {'id': 6023, 'payload': null};
    pending[43000] = {'id': 43000, 'payload': 'nearby#x'};
    delivered[41001] = {'id': 41001, 'payload': 'death_man:plan'};
  }

  Set<int> get sosIds => {42001, 42002, 6023, 43000, 41001};

  bool sosIntact() =>
      pending.containsKey(42001) &&
      delivered.containsKey(42002) &&
      delivered.containsKey(6023) &&
      pending.containsKey(43000) &&
      delivered.containsKey(41001);

  Iterable<int> get tagIds => [
    ...pending.keys,
    ...delivered.keys,
  ].where(TagAlertNotificationIds.contains);
}
