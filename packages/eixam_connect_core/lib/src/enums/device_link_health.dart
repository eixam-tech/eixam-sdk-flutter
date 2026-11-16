/// Health of the connected TAG's notification link, as verified by the SDK.
///
/// The SDK periodically asks the TAG for a reply that only arrives as a BLE
/// notification. When the TAG stays connected and accepts writes but its
/// notifications stopped (so a TAG SOS would reach neither the app nor the
/// backend), the SDK reconnects the TAG once. If replies are still missing
/// after that, it reports [restartRequired]: hosts ask the user to restart the
/// app to finish connecting the TAG. A later successful check returns to [ok].
///
/// [restartRequiredAfterRepair]: a TAG pairing completed in an app session
/// in which a TAG had already been unpaired through the SDK. TAG SOS
/// notifications may then not reach the app or the backend until the app
/// restarts. It wins over [ok] and [restartRequired], is reported while a TAG
/// is paired (connected or not) and never clears until the process restarts:
/// hosts ask the user to restart the app to finish pairing the TAG. The app
/// SOS keeps working. Consumers that only check for [restartRequired] treat it
/// as not requiring a restart.
enum DeviceLinkHealth { ok, restartRequired, restartRequiredAfterRepair }
