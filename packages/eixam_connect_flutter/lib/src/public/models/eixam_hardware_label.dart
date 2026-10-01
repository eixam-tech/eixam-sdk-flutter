/// Formatting and recognition rules for labels printed on Eixam hardware.
abstract final class EixamHardwareLabel {
  static final RegExp _housingSerialPattern = RegExp(r'^N6[0-9A-F]{6}$');
  static final RegExp _legacyAdvertisedNamePattern = RegExp(
    r'^EIXAM_[0-9A-F]{8}$',
  );

  /// Converts a 32-bit node identifier to the serial printed on the housing.
  static String housingSerial(int nodeId) {
    final suffix = (nodeId & 0x00FFFFFF)
        .toRadixString(16)
        .toUpperCase()
        .padLeft(6, '0');
    return 'N6$suffix';
  }

  /// Whether [value] is a current housing serial or legacy BLE device name.
  static bool looksLikeAdvertisedName(String value) {
    final normalized = value.trim().toUpperCase();
    return _housingSerialPattern.hasMatch(normalized) ||
        _legacyAdvertisedNamePattern.hasMatch(normalized);
  }
}
