import '../entities/background_location.dart';

/// Optional capability for native background-location implementations.
///
/// SDK implementations expose this interface explicitly when supported.
/// [EixamConnectSdk] does not require this capability.
abstract class BackgroundLocationControl {
  Future<LocationPermissionSnapshot> getLocationPermissionSnapshot();

  Future<LocationPermissionSnapshot> requestLocationWhenInUsePermission();

  Future<LocationPermissionSnapshot> requestLocationAlwaysPermission();

  Future<BackgroundLocationRuntimeStatus> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  });

  Future<BackgroundLocationRuntimeStatus> getBackgroundLocationStatus();

  Stream<BackgroundLocationRuntimeStatus> watchBackgroundLocationStatus();
}
