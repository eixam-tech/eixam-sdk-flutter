/// Structural recognition only: a box code is not authentication or a checksum.
enum TagPairingCodeFormat { structurallyValid, invalid, unsupported }

final class TagPairingCodeInspection {
  const TagPairingCodeInspection._(this.format, this.code);

  final TagPairingCodeFormat format;
  final TagPairingCode? code;
}

/// Documented N6 labels and current A6 labels carry the last three MAC bytes.
/// Prefixes are retained, never silently rewritten or treated as node-ID bytes.
final class TagPairingCode {
  const TagPairingCode._(this.normalized);

  final String normalized;
  String get hardwareSuffix => normalized.substring(2);
  String get legacyAdvertisingSuffix => normalized.substring(4);

  static TagPairingCodeInspection inspect(String payload) {
    final normalized = payload.trim().toUpperCase();
    if (normalized.isEmpty || RegExp(r'[\x00-\x20\x7f]').hasMatch(normalized)) {
      return const TagPairingCodeInspection._(
        TagPairingCodeFormat.invalid,
        null,
      );
    }
    if (!normalized.startsWith('N6') && !normalized.startsWith('A6')) {
      return const TagPairingCodeInspection._(
        TagPairingCodeFormat.unsupported,
        null,
      );
    }
    if (!RegExp(r'^(N6|A6)[0-9A-F]{6}$').hasMatch(normalized)) {
      return const TagPairingCodeInspection._(
        TagPairingCodeFormat.invalid,
        null,
      );
    }
    return TagPairingCodeInspection._(
      TagPairingCodeFormat.structurallyValid,
      TagPairingCode._(normalized),
    );
  }
}
