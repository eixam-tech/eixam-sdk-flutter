import '../entities/permission_state.dart';

/// Contract responsible for reading and requesting runtime permissions.
abstract class PermissionsRepository {
  Future<PermissionState> getPermissionState();
  Future<PermissionState> requestLocationPermission();
  Future<PermissionState> requestNotificationPermission();
  Future<PermissionState> requestBluetoothPermission();
}
