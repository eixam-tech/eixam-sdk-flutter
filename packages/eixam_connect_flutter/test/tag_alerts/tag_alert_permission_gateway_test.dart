import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/tag_alerts/tag_alert_permission_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  test('iOS permission statuses map to explicit TAG alert states', () {
    TagAlertPermissionState map(PermissionStatus s) =>
        PlatformTagAlertPermissionGateway.statusToState(s);
    expect(map(PermissionStatus.granted), TagAlertPermissionState.granted);
    expect(map(PermissionStatus.limited), TagAlertPermissionState.granted);
    expect(map(PermissionStatus.provisional), TagAlertPermissionState.granted);
    // permission_handler on iOS: `denied` means "not asked yet".
    expect(map(PermissionStatus.denied), TagAlertPermissionState.notDetermined);
    expect(
      map(PermissionStatus.permanentlyDenied),
      TagAlertPermissionState.permanentlyDenied,
    );
    expect(
      map(PermissionStatus.restricted),
      TagAlertPermissionState.permanentlyDenied,
    );
  });

  test(
    'the unsupported gateway never prompts and reports unsupported',
    () async {
      const gateway = UnsupportedTagAlertPermissionGateway();
      expect(await gateway.state(), TagAlertPermissionState.unsupported);
      expect(await gateway.request(), TagAlertPermissionState.unsupported);
    },
  );
}
