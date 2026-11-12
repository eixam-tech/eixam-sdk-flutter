/// Health of the connected TAG's notification link, as verified by the SDK.
///
/// The SDK periodically asks the TAG for a reply that only arrives as a BLE
/// notification. When the TAG stays connected and accepts writes but its
/// notifications stopped (so a TAG SOS would reach neither the app nor the
/// backend), the SDK reconnects the TAG once. If replies are still missing
/// after that, it reports [restartRequired]: hosts ask the user to restart the
/// app to finish connecting the TAG. A later successful check returns to [ok].
enum DeviceLinkHealth { ok, restartRequired }
