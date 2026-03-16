/// High-level lifecycle of the device inside the host app.
///
/// This value helps the UI understand whether the device still needs pairing,
/// activation or runtime recovery. It is intentionally broader than a pure BLE
/// connection state.
enum DeviceLifecycleState {
  unpaired,
  pairing,
  paired,
  activating,
  activated,
  ready,
  error,
}
