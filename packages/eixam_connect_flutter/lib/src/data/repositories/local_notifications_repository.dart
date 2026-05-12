import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications adapter used by the starter SDK.
class LocalNotificationsRepository implements NotificationsRepository {
  LocalNotificationsRepository({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;
  NotificationActionHandler? _onAction;
  bool _launchActionDispatched = false;

  static const String _defaultTapActionId = 'open_app';
  static const String _defaultChannelId = 'eixam_local_alerts';
  static const String _sosChannelId = 'eixam_sos_alerts';

  @override
  Future<void> initialize({NotificationActionHandler? onAction}) async {
    _onAction = onAction ?? _onAction;
    if (_initialized) {
      await _dispatchLaunchActionIfNeeded();
      return;
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    final settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    final ok = await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );
    // iOS returns `false` when no permission types are requested (all
    // request*Permission flags false). Categories and delegate are still
    // configured; only `null` means the platform plugin is missing.
    if (ok == null) {
      throw const DeviceException(
        'E_NOTIFICATIONS_INIT_FAILED',
        'E_NOTIFICATIONS_INIT_FAILED',
      );
    }
    _initialized = true;
    await _dispatchLaunchActionIfNeeded();
  }

  @override
  Future<void> requestPermission() async {
    if (!_initialized) {
      await initialize();
    }

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();

    final iosImpl = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    await iosImpl?.requestPermissions(alert: true, badge: true, sound: true);

    final macImpl = _plugin.resolvePlatformSpecificImplementation<
        MacOSFlutterLocalNotificationsPlugin>();
    await macImpl?.requestPermissions(alert: true, badge: true, sound: true);
  }

  @override
  Future<void> showLocalNotification({
    int? notificationId,
    required String title,
    required String body,
    String? payload,
    List<LocalNotificationAction> actions = const <LocalNotificationAction>[],
  }) async {
    if (!_initialized) {
      await initialize();
    }

    final isSosNotification = _looksLikeSosNotification(
      payload: payload,
    );
    final channelId = isSosNotification ? _sosChannelId : _defaultChannelId;
    final channelName = channelId;

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        channelId,
        channelName,
        importance: Importance.max,
        priority: Priority.high,
        actions: actions
            .map(
              (action) => AndroidNotificationAction(
                action.id,
                action.title,
                showsUserInterface: action.foreground,
                cancelNotification: true,
              ),
            )
            .toList(growable: false),
      ),
      iOS: DarwinNotificationDetails(
        categoryIdentifier: null,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: null,
      ),
    );

    await _plugin.show(
      notificationId ?? _nextNotificationId(),
      title,
      body,
      details,
      payload: payload,
    );
  }

  @override
  Future<void> clearSosNotifications() async {
    if (!_initialized) {
      try {
        await initialize();
      } catch (_) {
        return;
      }
    }

    final notificationIds = <int>{};

    try {
      final activeNotifications = await _plugin.getActiveNotifications();
      for (final notification in activeNotifications) {
        if (_matchesSosNotification(
          channelId: notification.channelId,
          title: notification.title,
          body: notification.body,
          payload: notification.payload,
        )) {
          final id = notification.id;
          if (id != null) {
            notificationIds.add(id);
          }
        }
      }
    } on UnimplementedError {
      // Best effort: some platforms do not support active notification listing.
    } catch (_) {
      // Keep SOS state transitions resilient if notification cleanup fails.
    }

    try {
      final pendingNotifications = await _plugin.pendingNotificationRequests();
      for (final notification in pendingNotifications) {
        if (_matchesSosNotification(
          title: notification.title,
          body: notification.body,
          payload: notification.payload,
        )) {
          notificationIds.add(notification.id);
        }
      }
    } on UnimplementedError {
      // Best effort: pending notification listing may not be implemented.
    } catch (_) {
      // Keep SOS state transitions resilient if notification cleanup fails.
    }

    for (final id in notificationIds) {
      try {
        await _plugin.cancel(id);
      } catch (_) {
        // Keep cancelling the rest even if one cancellation fails.
      }
    }
  }

  Future<void> _dispatchLaunchActionIfNeeded() async {
    if (_launchActionDispatched) {
      return;
    }
    final details = await _plugin.getNotificationAppLaunchDetails();
    final response = details?.notificationResponse;
    if (details?.didNotificationLaunchApp != true || response == null) {
      return;
    }
    _launchActionDispatched = true;
    await _emitAction(
      actionId: _normalizeActionId(response.actionId),
      payload: response.payload,
      launchedApp: true,
    );
  }

  Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    await _emitAction(
      actionId: _normalizeActionId(response.actionId),
      payload: response.payload,
      launchedApp: false,
    );
  }

  Future<void> _emitAction({
    required String actionId,
    required String? payload,
    required bool launchedApp,
  }) async {
    final handler = _onAction;
    if (handler == null) {
      return;
    }
    await handler(
      NotificationActionInvocation(
        actionId: actionId,
        payload: payload,
        launchedApp: launchedApp,
      ),
    );
  }

  String _normalizeActionId(String? actionId) {
    final normalized = actionId?.trim();
    if (normalized == null || normalized.isEmpty) {
      return _defaultTapActionId;
    }
    return normalized;
  }

  bool _matchesSosNotification({
    String? channelId,
    String? title,
    String? body,
    String? payload,
  }) {
    if (channelId == _sosChannelId) {
      return true;
    }
    return _looksLikeSosNotification(payload: payload);
  }

  bool _looksLikeSosNotification({
    String? payload,
  }) {
    if (payload == null || payload.trim().isEmpty) {
      return false;
    }
    final normalized = payload.trim().toLowerCase();
    if (normalized.startsWith('death_man:')) {
      return false;
    }
    if (normalized.startsWith('sos:') ||
        normalized.startsWith('pre_sos:') ||
        normalized.startsWith('pre-sos:')) {
      return true;
    }
    return normalized.contains('"kind":"sos_received"') ||
        normalized.contains('"kind": "sos_received"');
  }

  int _nextNotificationId() {
    return DateTime.now().microsecondsSinceEpoch % 2147483647;
  }
}
