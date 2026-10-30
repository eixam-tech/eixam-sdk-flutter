/// Actionable failures of the optional activity-session capability.
///
/// Kept outside the sealed EixamSdkException hierarchy so existing exhaustive
/// switches over that hierarchy remain source compatible.
final class ActivitySessionException implements Exception {
  const ActivitySessionException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() =>
      'ActivitySessionException(code: $code, message: $message)';
}
