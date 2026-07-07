/// Result of resolving the device's physical location to a country, returned by
/// the backend geo endpoint (`GET /v1/sdk/geo/country?lat=&lon=`).
class ResolvedCountry {
  const ResolvedCountry({
    required this.countryIso,
    this.latitude,
    this.longitude,
  });

  /// ISO 3166-1 alpha-2 country code (e.g. `ES`, `US`).
  final String countryIso;

  /// Coordinates the country was resolved from, when echoed back by the
  /// backend (diagnostics only).
  final double? latitude;
  final double? longitude;
}
