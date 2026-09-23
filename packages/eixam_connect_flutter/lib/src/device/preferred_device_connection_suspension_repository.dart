import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Internal non-destructive device detach used by intentional suspension.
abstract interface class PreferredDeviceConnectionSuspensionRepository {
  Future<DeviceStatus> suspendPreferredDeviceConnection();
}
