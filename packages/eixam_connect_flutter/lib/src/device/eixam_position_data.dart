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
    final details = EixamPositionDecodeDetails.decode(bytes, offset: offset);
    return EixamPositionData(
      latitude: details.decodedLatitude,
      longitude: details.decodedLongitude,
      altitudeMeters: details.decodedAltitudeMeters,
    );
  }

  /// Packs lat/lon/alt into the 6-byte geo slice shared by TEL and SOS 12 B.
  static List<int> encode({
    required double latitude,
    required double longitude,
    int altitudeMeters = 0,
  }) {
    final latEnc =
        ((latitude + 90.0) * 1048576.0 / 180.0).round().clamp(0, 1048575);
    final lonEnc =
        ((longitude + 180.0) * 2097152.0 / 360.0).round().clamp(0, 2097151);
    final altEnc = (altitudeMeters / 40).round().clamp(0, 127);
    return <int>[
      (latEnc >> 12) & 0xFF,
      (latEnc >> 4) & 0xFF,
      ((latEnc & 0x0F) << 4) | ((lonEnc >> 17) & 0x0F),
      (lonEnc >> 9) & 0xFF,
      (lonEnc >> 1) & 0xFF,
      (lonEnc & 0x01) | ((altEnc & 0x7F) << 1),
    ];
  }
}

class EixamPositionDecodeDetails {
  const EixamPositionDecodeDetails({
    required this.offset,
    required this.positionBytesHex,
    required this.latBytesHex,
    required this.lonBytesHex,
    required this.altBytesHex,
    required this.packed,
    required this.latRawInt,
    required this.lonRawInt,
    required this.lonSigned21RawInt,
    required this.altRawInt,
    required this.legacyLittleEndianPacked,
    required this.legacyLittleEndianLonRawInt,
    required this.legacyLittleEndianDecodedLongitudeOffsetMinus180,
    required this.legacyLittleEndianDecodedLongitudeNoOffset,
    required this.legacyLittleEndianDecodedLongitudeSigned21,
    required this.decodedLatitude,
    required this.decodedLongitude,
    required this.decodedLongitudeOffsetMinus180,
    required this.decodedLongitudeNoOffset,
    required this.decodedLongitudeSigned21,
    required this.decodedAltitudeMeters,
  });

  final int offset;
  final String positionBytesHex;
  final String latBytesHex;
  final String lonBytesHex;
  final String altBytesHex;
  final int packed;
  final int latRawInt;
  final int lonRawInt;
  final int lonSigned21RawInt;
  final int altRawInt;
  final int legacyLittleEndianPacked;
  final int legacyLittleEndianLonRawInt;
  final double legacyLittleEndianDecodedLongitudeOffsetMinus180;
  final double legacyLittleEndianDecodedLongitudeNoOffset;
  final double legacyLittleEndianDecodedLongitudeSigned21;
  final double decodedLatitude;
  final double decodedLongitude;
  final double decodedLongitudeOffsetMinus180;
  final double decodedLongitudeNoOffset;
  final double decodedLongitudeSigned21;
  final int decodedAltitudeMeters;

  static const String parserName = 'EixamPositionData.geoMeta_v2';
  static const String protocolVersion = 'firmware_tel_sos_v2';
  static const String latScale = '(raw*180/1048576)-90';
  static const String selectedLongitudeFormula =
      'firmwareGeoMetaOffsetMinus180';
  static const String lonScale = '(raw*360/2097152)-180';
  static const String lonOffsetMinus180Scale = '(raw*360/2097152)-180';
  static const String lonNoOffsetScale = 'raw*360/2097152';
  static const String lonSigned21Scale = 'signed21(raw)*360/2097152';
  static const String altScale = 'raw*40';

  static EixamPositionDecodeDetails decode(
    List<int> bytes, {
    required int offset,
  }) {
    // Mirrors firmware EixamPositionCodec::encodeGeoMeta/decodeGeoMeta.
    final latEnc = (bytes[offset] << 12) |
        (bytes[offset + 1] << 4) |
        ((bytes[offset + 2] >> 4) & 0x0F);
    final lonEnc = ((bytes[offset + 2] & 0x0F) << 17) |
        (bytes[offset + 3] << 9) |
        (bytes[offset + 4] << 1) |
        (bytes[offset + 5] & 0x01);
    final lonSigned21 = _signExtend(lonEnc, bitWidth: 21);
    final altEnc = (bytes[offset + 5] >> 1) & 0x7F;
    final decodedLonOffsetMinus180 = (lonEnc * 360.0 / 2097152.0) - 180.0;
    final decodedLonNoOffset = lonEnc * 360.0 / 2097152.0;
    final decodedLonSigned21 = lonSigned21 * 360.0 / 2097152.0;

    final legacyLittleEndianPacked = bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24) |
        (bytes[offset + 4] << 32) |
        (bytes[offset + 5] << 40);
    final legacyLittleEndianLonEnc =
        (legacyLittleEndianPacked >> 20) & 0x1FFFFF;
    final legacyLittleEndianLonSigned21 =
        _signExtend(legacyLittleEndianLonEnc, bitWidth: 21);

    return EixamPositionDecodeDetails(
      offset: offset,
      positionBytesHex: _hex(bytes, offset, 6),
      latBytesHex: _hex(bytes, offset, 3),
      lonBytesHex: _hex(bytes, offset + 2, 4),
      altBytesHex: _hex(bytes, offset + 5, 1),
      packed: (latEnc << 28) | (lonEnc << 7) | altEnc,
      latRawInt: latEnc,
      lonRawInt: lonEnc,
      lonSigned21RawInt: lonSigned21,
      altRawInt: altEnc,
      legacyLittleEndianPacked: legacyLittleEndianPacked,
      legacyLittleEndianLonRawInt: legacyLittleEndianLonEnc,
      legacyLittleEndianDecodedLongitudeOffsetMinus180:
          (legacyLittleEndianLonEnc * 360.0 / 2097152.0) - 180.0,
      legacyLittleEndianDecodedLongitudeNoOffset:
          legacyLittleEndianLonEnc * 360.0 / 2097152.0,
      legacyLittleEndianDecodedLongitudeSigned21:
          legacyLittleEndianLonSigned21 * 360.0 / 2097152.0,
      decodedLatitude: (latEnc * 180.0 / 1048576.0) - 90.0,
      decodedLongitude: decodedLonOffsetMinus180,
      decodedLongitudeOffsetMinus180: decodedLonOffsetMinus180,
      decodedLongitudeNoOffset: decodedLonNoOffset,
      decodedLongitudeSigned21: decodedLonSigned21,
      decodedAltitudeMeters: altEnc * 40,
    );
  }

  static int _signExtend(int value, {required int bitWidth}) {
    final signBit = 1 << (bitWidth - 1);
    final mask = 1 << bitWidth;
    return (value & signBit) == 0 ? value : value - mask;
  }

  static String _hex(List<int> bytes, int offset, int length) {
    if (offset < 0 || offset >= bytes.length || length <= 0) {
      return '';
    }
    final end = offset + length > bytes.length ? bytes.length : offset + length;
    return bytes
        .sublist(offset, end)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(' ');
  }
}
