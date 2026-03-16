abstract class NotificationsRepository {
  Future<void> initialize();
  Future<void> requestPermission();
  Future<void> showLocalNotification({required String title, required String body});
}
