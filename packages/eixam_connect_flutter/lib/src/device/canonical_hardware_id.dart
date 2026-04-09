String? normalizeCanonicalHardwareId(String? rawValue) {
  final value = rawValue?.trim();
  if (value == null || value.isEmpty) {
    return null;
  }

  final normalized = value.toUpperCase();
  final macPattern = RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$');
  if (!macPattern.hasMatch(normalized)) {
    return null;
  }
  return normalized;
}
