/// Local failures of the optional TAG alerts capability. Kept outside the
/// sealed SDK error family, like `ActivityAvailabilityException`.
final class TagAlertsException implements Exception {
  const TagAlertsException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'TagAlertsException(code: $code, message: $message)';
}
