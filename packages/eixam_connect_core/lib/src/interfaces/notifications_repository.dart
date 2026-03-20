typedef NotificationActionHandler =
    Future<void> Function(NotificationActionInvocation invocation);

class NotificationActionInvocation {
  const NotificationActionInvocation({
    required this.actionId,
    this.payload,
    this.launchedApp = false,
  });

  final String actionId;
  final String? payload;
  final bool launchedApp;
}

class LocalNotificationAction {
  const LocalNotificationAction({
    required this.id,
    required this.title,
    this.foreground = false,
    this.destructive = false,
  });

  final String id;
  final String title;
  final bool foreground;
  final bool destructive;
}

abstract class NotificationsRepository {
  Future<void> initialize({NotificationActionHandler? onAction});
  Future<void> requestPermission();
  Future<void> showLocalNotification({
    int? notificationId,
    required String title,
    required String body,
    String? payload,
    List<LocalNotificationAction> actions = const <LocalNotificationAction>[],
  });
}
