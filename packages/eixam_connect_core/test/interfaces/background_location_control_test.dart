import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test('BackgroundLocationControl is an explicit optional capability', () {
    final control = _FakeBackgroundLocationControl();

    expect(control, isA<BackgroundLocationControl>());
    expect(control, isNot(isA<EixamConnectSdk>()));
  });

  test('legacy background telemetry APIs remain on EixamConnectSdk', () {
    Future<void> enable(
      EixamConnectSdk sdk, {
      String? notificationTitle,
      String? notificationBody,
    }) {
      return sdk.enableBackgroundTelemetry(
        notificationTitle: notificationTitle,
        notificationBody: notificationBody,
      );
    }

    Future<void> disable(EixamConnectSdk sdk) {
      return sdk.disableBackgroundTelemetry();
    }

    expect(enable, isA<Function>());
    expect(disable, isA<Function>());
  });
}

class _FakeBackgroundLocationControl implements BackgroundLocationControl {
  static const permission = LocationPermissionSnapshot(
    locationServicesEnabled: true,
    authorizationStatus: LocationAuthorizationStatus.whenInUse,
    accuracyAuthorization: LocationAccuracyAuthorization.full,
  );

  BackgroundLocationRuntimeStatus get _status =>
      BackgroundLocationRuntimeStatus(
        activeContexts: const <BackgroundLocationContext>[],
        isNativePlatformSupported: true,
        isNativeServiceRunning: false,
        permission: permission,
      );

  @override
  Future<BackgroundLocationRuntimeStatus> getBackgroundLocationStatus() async {
    return _status;
  }

  @override
  Future<LocationPermissionSnapshot> getLocationPermissionSnapshot() async {
    return permission;
  }

  @override
  Future<LocationPermissionSnapshot> requestLocationAlwaysPermission() async {
    return permission;
  }

  @override
  Future<LocationPermissionSnapshot>
      requestLocationWhenInUsePermission() async {
    return permission;
  }

  @override
  Future<BackgroundLocationRuntimeStatus> setBackgroundLocationContext(
    BackgroundLocationContext context, {
    required bool active,
  }) async {
    return _status;
  }

  @override
  Stream<BackgroundLocationRuntimeStatus> watchBackgroundLocationStatus() {
    return Stream<BackgroundLocationRuntimeStatus>.value(_status);
  }
}
