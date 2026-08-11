/// Authoritative firmware provisioning state reported by BLE command `0x23`.
///
/// This is deliberately independent from product activation and LoRa transmit
/// enablement. Until a valid `0x23` response is observed, the state is
/// [unknown].
enum DeviceProvisioningStatus {
  unknown,
  unprovisioned,
  provisioned,
}
