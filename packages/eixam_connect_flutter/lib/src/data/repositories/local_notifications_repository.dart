import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications adapter used by the starter SDK.
class LocalNotificationsRepository implements NotificationsRepository {
  LocalNotificationsRepository({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
      macOS: darwinSettings,
    );

    final ok = await _plugin.initialize(settings);
    if (ok != true) {
      throw const DeviceException('E_NOTIFICATIONS_INIT_FAILED', 'Unable to initialize local notifications');
    }
    _initialized = true;
  }

  @override
  Future<void> requestPermission() async {
    if (!_initialized) {
      await initialize();
    }

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();

    final iosImpl = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    await iosImpl?.requestPermissions(alert: true, badge: true, sound: true);

    final macImpl = _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    await macImpl?.requestPermissions(alert: true, badge: true, sound: true);
  }

  @override
  Future<void> showLocalNotification({required String title, required String body}) async {
    if (!_initialized) {
      await initialize();
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'eixam_local_alerts',
        'EIXAM Local Alerts',
        channelDescription: 'Local alerts for SOS, tracking and Death Man checks',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }
}
