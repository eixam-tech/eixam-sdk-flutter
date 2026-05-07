import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Internal Flutter-SDK capability for restoring a known BLE device without
/// expanding the public core DeviceRepository contract.
abstract class KnownDeviceReconnectRepository {
  Future<DeviceStatus> reconnectDevice({required PreferredDevice device});
}
