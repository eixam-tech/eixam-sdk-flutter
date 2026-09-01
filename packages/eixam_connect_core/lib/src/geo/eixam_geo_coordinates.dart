/// Shared geo gates for TEL and SOS.
///
/// Null Island is never a legitimate fix for this product. Tags 2.7.45–2.7.49
/// emitted 0°,0° with `gpsQuality = 2`; filter by coordinates, not quality.
abstract final class EixamGeoCoordinates {
  static bool isValidFix(double latitude, double longitude) {
    return latitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude.isFinite &&
        longitude >= -180 &&
        longitude <= 180 &&
        !isNullIsland(latitude, longitude);
  }

  static bool isNullIsland(double latitude, double longitude) {
    return latitude == 0 && longitude == 0;
  }
}
