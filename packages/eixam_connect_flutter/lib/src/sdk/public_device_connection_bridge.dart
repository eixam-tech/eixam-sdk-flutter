import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Host-facing `connected` may follow native Protection GATT when Flutter
/// does not own the radio. Flutter-owned GATT is authoritative: stale native
/// `deviceConnected` flags must not hide a real drop (provisioning `0x22`
/// reboot, LINK_SUPERVISION_TIMEOUT).
bool shouldBridgeProtectionBleConnection({
  required bool rawConnected,
  required ProtectionBleOwner bleOwner,
  required bool protectionReportsLiveConnection,
  required bool belongsToKnownDevice,
}) {
  if (rawConnected ||
      !protectionReportsLiveConnection ||
      !belongsToKnownDevice) {
    return false;
  }
  return bleOwner != ProtectionBleOwner.flutter;
}
