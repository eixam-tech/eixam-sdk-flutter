import 'package:eixam_connect_core/eixam_connect_core.dart';

enum DeviceConnectionProjectionReason {
  flutterRepositoryConnected,
  authoritativeNativeConnection,
  sameNativeSessionContinuity,
  nativeOwnerNotReady,
  nativeGattDisconnected,
  nativeIdentityMismatch,
  disconnected,
}

final class DeviceConnectionProjection {
  const DeviceConnectionProjection({
    required this.visibleConnected,
    required this.falseDisconnectBlocked,
    required this.reason,
  });

  final bool visibleConnected;
  final bool falseDisconnectBlocked;
  final DeviceConnectionProjectionReason reason;
}

/// Produces the one SDK-owned device connection truth consumed by hosts and
/// reconnect orchestration.
///
/// Flutter repository state is authoritative while Flutter owns GATT. Once a
/// native Protection runtime is the ready owner, its live GATT plus exact
/// connected-device identity is authoritative instead. A repository refresh
/// is still retained as diagnostics, but cannot publish a false disconnect or
/// start a second BLE owner.
DeviceConnectionProjection projectDeviceConnection({
  required bool flutterRepositoryConnected,
  required bool nativeOwnerDeclared,
  required bool nativeOwnerReady,
  required bool nativeGattConnected,
  required bool sameDeviceIdentity,
  bool nativeConnectionContinuityProven = false,
}) {
  if (flutterRepositoryConnected) {
    return const DeviceConnectionProjection(
      visibleConnected: true,
      falseDisconnectBlocked: false,
      reason: DeviceConnectionProjectionReason.flutterRepositoryConnected,
    );
  }
  if (nativeOwnerReady && nativeGattConnected && sameDeviceIdentity) {
    return const DeviceConnectionProjection(
      visibleConnected: true,
      falseDisconnectBlocked: true,
      reason: DeviceConnectionProjectionReason.authoritativeNativeConnection,
    );
  }
  if (nativeOwnerDeclared &&
      nativeConnectionContinuityProven &&
      nativeGattConnected &&
      sameDeviceIdentity) {
    return const DeviceConnectionProjection(
      visibleConnected: true,
      falseDisconnectBlocked: true,
      reason: DeviceConnectionProjectionReason.sameNativeSessionContinuity,
    );
  }
  final reason = !nativeOwnerDeclared
      ? DeviceConnectionProjectionReason.disconnected
      : !nativeGattConnected
      ? DeviceConnectionProjectionReason.nativeGattDisconnected
      : !sameDeviceIdentity
      ? DeviceConnectionProjectionReason.nativeIdentityMismatch
      : DeviceConnectionProjectionReason.nativeOwnerNotReady;
  return DeviceConnectionProjection(
    visibleConnected: false,
    falseDisconnectBlocked: false,
    reason: reason,
  );
}

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
  return projectDeviceConnection(
    flutterRepositoryConnected: rawConnected,
    nativeOwnerDeclared: bleOwner != ProtectionBleOwner.flutter,
    nativeOwnerReady: bleOwner != ProtectionBleOwner.flutter,
    nativeGattConnected: protectionReportsLiveConnection,
    sameDeviceIdentity: belongsToKnownDevice,
  ).falseDisconnectBlocked;
}
