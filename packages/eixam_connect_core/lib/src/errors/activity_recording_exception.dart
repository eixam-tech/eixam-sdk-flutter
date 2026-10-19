/// Actionable failures of the optional activity-recording capability.
///
/// Independent of the sealed EixamSdkException hierarchy so existing exhaustive
/// switches remain source compatible. AR1 defines this type, not a runtime.
///
/// Contract codes are E_RECORDING_CONFLICT, E_RECORDING_SESSION_MISMATCH,
/// E_RECORDING_IDENTITY_REQUIRED, E_RECORDING_DEVICE_MISMATCH,
/// E_RECORDING_INVALID_TIME, E_RECORDING_NOT_FOUND, E_RECORDING_ALREADY_FINISHED,
/// E_RECORDING_ROUTE_REVISION_CHANGED and E_RECORDING_UNAVAILABLE.
/// Persistence/recovery implementation failures will be specified with AR2.
final class ActivityRecordingException implements Exception {
  const ActivityRecordingException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() =>
      'ActivityRecordingException(code: $code, message: $message)';
}
