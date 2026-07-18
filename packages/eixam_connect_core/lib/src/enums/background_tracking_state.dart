/// Authoritative runtime state of user-controlled background location tracking.
enum BackgroundTrackingState {
  stopped,
  starting,
  activeForeground,
  activeBackground,
  stopping,
  permissionBlocked,
  serviceUnavailable,
  error,
}
