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

  static const String _bleSosCategoryId = 'eixam_ble_sos_actions';
  static const String _defaultTapActionId = 'open_app';

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
    final darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          _bleSosCategoryId,
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(
              _defaultTapActionId,
              'Open app',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.foreground,
              },
            ),
            DarwinNotificationAction.plain(
              'cancel_sos',
              'Cancel SOS',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.foreground,
                DarwinNotificationActionOption.destructive,
              },
            ),
            DarwinNotificationAction.plain(
              'confirm_sos',
              'Confirm SOS',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.foreground,
              },
            ),
            DarwinNotificationAction.plain(
              'resolve_sos',
              'Resolve SOS',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.foreground,
                DarwinNotificationActionOption.destructive,
              },
            ),
            DarwinNotificationAction.plain(
              'confirm_dead_man_safe',
              'I\'m OK',
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.foreground,
              },
            ),
          ],
        ),
      ],
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
    if (ok != true) {
      throw const DeviceException(
        'E_NOTIFICATIONS_INIT_FAILED',
        'Unable to initialize local notifications',
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

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'eixam_local_alerts',
        'EIXAM Local Alerts',
        channelDescription:
            'Local alerts for SOS, tracking and Death Man checks',
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
        categoryIdentifier: actions.isEmpty ? null : _bleSosCategoryId,
      ),
      macOS: DarwinNotificationDetails(
        categoryIdentifier: actions.isEmpty ? null : _bleSosCategoryId,
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

  int _nextNotificationId() {
    return DateTime.now().microsecondsSinceEpoch % 2147483647;
  }
}
