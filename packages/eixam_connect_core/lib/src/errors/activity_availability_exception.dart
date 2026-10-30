/// Local/validation failures of the optional availability capability.
/// Kept outside the sealed SDK error family for exhaustive-switch compatibility.
/// Authentication and transport failures use AuthException/NetworkException.
final class ActivityAvailabilityException implements Exception {
  const ActivityAvailabilityException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() =>
      'ActivityAvailabilityException(code: $code, message: $message)';
}
