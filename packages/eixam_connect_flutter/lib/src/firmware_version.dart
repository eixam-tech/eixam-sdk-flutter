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

/// Whether [installed] and [target] name the same firmware image.
///
/// GATT strings can be `2.7.50`, `2.7.50.<hash>`, `v50`, or a portal short
/// build `50`. Distinct hashes of the same semver stay distinct.
bool eixamFirmwareVersionsMatch(String? installed, String? target) {
  final a = normalizeEixamFirmwareVersion(installed);
  final b = normalizeEixamFirmwareVersion(target);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (a.startsWith('$b.') || b.startsWith('$a.')) return true;
  final aBuild = _firmwareBuildHash(a);
  final bBuild = _firmwareBuildHash(b);
  if (aBuild != null && bBuild != null && aBuild != bBuild) {
    return false;
  }
  final aParts = _firmwareOrderParts(installed);
  final bParts = _firmwareOrderParts(target);
  if (aParts == null || bParts == null) return false;
  if (aParts.length == 1 && bParts.length == 3) {
    return aParts[0] == bParts[2];
  }
  if (aParts.length == 3 && bParts.length == 1) {
    return aParts[2] == bParts[0];
  }
  return false;
}

/// Negative if [left] is older than [right], positive if newer, zero if the
/// same image. Null when neither side yields a comparable number.
int? compareEixamFirmwareVersions(String? left, String? right) {
  if (eixamFirmwareVersionsMatch(left, right)) return 0;
  final leftParts = _firmwareOrderParts(left);
  final rightParts = _firmwareOrderParts(right);
  if (leftParts == null || rightParts == null) return null;
  if (leftParts.length == 1 && rightParts.length == 3) {
    return leftParts[0].compareTo(rightParts[2]);
  }
  if (leftParts.length == 3 && rightParts.length == 1) {
    return leftParts[2].compareTo(rightParts[0]);
  }
  final length = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var index = 0; index < length; index++) {
    final leftValue = index < leftParts.length ? leftParts[index] : 0;
    final rightValue = index < rightParts.length ? rightParts[index] : 0;
    if (leftValue != rightValue) {
      return leftValue.compareTo(rightValue);
    }
  }
  return 0;
}

List<int>? _firmwareOrderParts(String? version) {
  final normalized = normalizeEixamFirmwareVersion(version);
  if (normalized.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(normalized)) {
    return <int>[int.parse(normalized)];
  }
  return parseEixamFirmwareSemanticCore(version);
}

String? _firmwareBuildHash(String normalized) {
  final match = RegExp(r'^\d+\.\d+\.\d+\.([0-9a-f]+)$').firstMatch(normalized);
  return match?.group(1);
}
