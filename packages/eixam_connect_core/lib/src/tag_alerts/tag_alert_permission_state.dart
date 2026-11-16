/// Notification permission as seen by the TAG alert capability.
///
/// On Android the state is best effort until [requestTagAlertPermission]
/// reports `permanentlyDenied`; iOS reports `notDetermined` before the first
/// prompt and `permanentlyDenied` once the user has declined.
enum TagAlertPermissionState {
  granted,
  denied,
  permanentlyDenied,
  notDetermined,
  unsupported,
}
