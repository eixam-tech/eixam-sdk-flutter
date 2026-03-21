class EixamPositionData {
  const EixamPositionData({
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
  });

  final double latitude;
  final double longitude;
  final int altitudeMeters;

  static EixamPositionData decode(List<int> bytes, {required int offset}) {
    final packed = bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24) |
        (bytes[offset + 4] << 32) |
        (bytes[offset + 5] << 40);

    final latEnc = packed & 0xFFFFF;
    final lonEnc = (packed >> 20) & 0x1FFFFF;
    final altEnc = (packed >> 41) & 0x7F;

    return EixamPositionData(
      latitude: (latEnc * 180.0 / 1048576.0) - 90.0,
      longitude: (lonEnc * 360.0 / 2097152.0) - 180.0,
      altitudeMeters: altEnc * 40,
    );
  }
}
