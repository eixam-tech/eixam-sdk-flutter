import '../enums/lora_region_code.dart';

/// Per-country device radio config returned by `GET /v1/sdk/device-configs`.
///
/// The backend response is free-form: the full payload is preserved in [raw]
/// and only the keys the SDK understands are promoted to typed fields. The
/// region byte the device must adopt is taken verbatim from the backend
/// (`lora_region_code`) — the SDK does NOT translate spec strings to bytes.
/// When the backend omits/zeroes the byte the config falls back to
/// [fallbackRegion] (EU868), so a device is never left without a legal region.
class DeviceCountryConfig {
  const DeviceCountryConfig({
    this.deviceConfig,
    this.loraRegionByte,
    this.country,
    this.sub,
    this.raw = const <String, dynamic>{},
  });

  factory DeviceCountryConfig.fromJson(Map<String, dynamic> json) {
    String? readString(String key) {
      final value = json[key];
      return value is String ? value : null;
    }

    int? readInt(String key) {
      final value = json[key];
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value.trim());
      return null;
    }

    return DeviceCountryConfig(
      // Region byte comes straight from the backend config (source of truth).
      loraRegionByte: readInt('lora_region_code'),
      // Human-readable region label (e.g. "EU868"); diagnostics only.
      deviceConfig: readString('region') ?? readString('device_config'),
      country: readString('country'),
      sub: readString('sub'),
      raw: Map<String, dynamic>.unmodifiable(json),
    );
  }

  /// Safe fallback applied when the backend omits a usable region byte.
  static const LoraRegionCode fallbackRegion = LoraRegionCode.eu868;

  /// Region label string (e.g. `EU868`), from the backend `region` field
  /// (falling back to `device_config`). Diagnostics only — not the apply source.
  final String? deviceConfig;

  /// Meshtastic region byte the device should adopt, taken verbatim from the
  /// backend `lora_region_code`. `null` when the backend omitted it.
  final int? loraRegionByte;

  /// ISO country code the backend associated with this config.
  final String? country;

  /// Optional sub-region disambiguator (e.g. AS923 sub-band country).
  final String? sub;

  /// Full backend payload, preserved for forward-compatibility.
  final Map<String, dynamic> raw;

  /// Region byte to write to the device: the backend `lora_region_code`, or the
  /// [fallbackRegion] (EU868) byte when the backend omits/zeroes it. Always a
  /// legal region — the SDK never skips a device for a "missing" region.
  int get regionByte {
    final byte = loraRegionByte;
    return (byte != null && byte > 0) ? byte : fallbackRegion.wireValue;
  }

  /// Typed label for [regionByte] (diagnostics/public status). Unmodeled bytes
  /// resolve to [LoraRegionCode.unset].
  LoraRegionCode get regionCode => LoraRegionCode.fromWireValue(regionByte);

  /// Always true: [regionByte] falls back to EU868 when the backend is unmapped.
  bool get hasApplicableRegion => regionByte != LoraRegionCode.unset.wireValue;
}
