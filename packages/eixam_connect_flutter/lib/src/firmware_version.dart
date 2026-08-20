String normalizeEixamFirmwareVersion(String? version) {
  if (version == null) return '';
  var normalized =
      version.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim().toLowerCase();
  if (normalized.startsWith('v')) {
    normalized = normalized.substring(1);
  }
  return normalized;
}

List<int>? parseEixamFirmwareSemanticCore(String? version) {
  final normalized = normalizeEixamFirmwareVersion(version);
  final match = RegExp(
    r'^(\d+)\.(\d+)\.(\d+)'
    r'(?:\.[0-9a-f]+'
    r'|-[0-9a-z-]+(?:\.[0-9a-z-]+)*(?:\+[0-9a-z-]+(?:\.[0-9a-z-]+)*)?'
    r'|\+[0-9a-z-]+(?:\.[0-9a-z-]+)*)?$',
  ).firstMatch(normalized);
  if (match == null) return null;
  final major = int.tryParse(match.group(1)!);
  final minor = int.tryParse(match.group(2)!);
  final patch = int.tryParse(match.group(3)!);
  if (major == null || minor == null || patch == null) return null;
  return <int>[major, minor, patch];
}
