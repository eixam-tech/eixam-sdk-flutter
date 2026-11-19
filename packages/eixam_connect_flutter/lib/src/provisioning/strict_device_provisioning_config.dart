import 'dart:convert';
import 'dart:typed_data';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_remote/sdk_http_transport.dart';

const Set<int> _sx1262TelBandwidthsKhz = <int>{125, 250, 500};
const Set<int> _sx1262SosBandwidthsHz = <int>{
  7800,
  10400,
  15600,
  20800,
  31250,
  41700,
  62500,
  125000,
  250000,
  500000,
};
const int _sx1262MaxPowerDbm = 22;

final class _RegulatoryRegion {
  const _RegulatoryRegion({
    required this.code,
    required this.name,
    required this.telBandLowHz,
    required this.telBandHighHz,
    required this.telMinSpreadingFactor,
    required this.telMaxSpreadingFactor,
    required this.telMaxPowerDbm,
    required this.sosBandLowHz,
    required this.sosBandHighHz,
    required this.sosMaxPowerDbm,
  });

  final int code;
  final String name;
  final int telBandLowHz;
  final int telBandHighHz;
  final int telMinSpreadingFactor;
  final int telMaxSpreadingFactor;
  final int telMaxPowerDbm;
  final int sosBandLowHz;
  final int sosBandHighHz;
  final int sosMaxPowerDbm;
}

// This mirrors the verified regulatory envelope in firmware's generated
// EixamRegionPlanTable, not the backend-owned operational profile within it.
const _RegulatoryRegion _eu868 = _RegulatoryRegion(
  code: 3,
  name: 'EU868',
  telBandLowHz: 865000000,
  telBandHighHz: 868000000,
  telMinSpreadingFactor: 7,
  telMaxSpreadingFactor: 9,
  telMaxPowerDbm: 14,
  sosBandLowHz: 869400000,
  sosBandHighHz: 869650000,
  sosMaxPowerDbm: 27,
);

const List<_RegulatoryRegion> _supportedRegions = <_RegulatoryRegion>[_eu868];

final class ProvisioningContractException implements Exception {
  const ProvisioningContractException(this.detail, {this.observedInteger});

  final DeviceReadyFailureDetail detail;
  final int? observedInteger;

  @override
  String toString() =>
      'ProvisioningContractException(detail: ${detail.name}'
      '${observedInteger == null ? '' : ', observedInteger: $observedInteger'})';
}

final class ProvisioningTelConfig {
  const ProvisioningTelConfig({
    required this.frequencyKhz,
    required this.bandwidthKhz,
    required this.spreadingFactor,
    required this.codingRateDenominator,
    required this.txPowerDbm,
  });

  final int frequencyKhz;
  final int bandwidthKhz;
  final int spreadingFactor;
  final int codingRateDenominator;
  final int txPowerDbm;
}

final class ProvisioningSosConfig {
  const ProvisioningSosConfig({
    required this.frequencyHz,
    required this.bandwidthHz,
    required this.spreadingFactor,
    required this.codingRateDenominator,
    required this.txPowerDbm,
    required this.preambleSymbols,
  });

  final int frequencyHz;
  final int bandwidthHz;
  final int spreadingFactor;
  final int codingRateDenominator;
  final int txPowerDbm;
  final int preambleSymbols;
}

final class StrictDeviceProvisioningConfig {
  const StrictDeviceProvisioningConfig({
    required this.regionCode,
    required this.region,
    required this.tel,
    required this.sos,
  });

  final int regionCode;
  final String region;
  final ProvisioningTelConfig tel;
  final ProvisioningSosConfig sos;

  static StrictDeviceProvisioningConfig parse(Map<String, dynamic> json) {
    final regionCode = _requiredInt(
      json,
      'lora_region_code',
      min: 0,
      max: 0xff,
      detail: DeviceReadyFailureDetail.loraRegionCodeInvalid,
    );
    if (json['plan_verified'] != true) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.planNotVerified,
      );
    }
    final regionValue = json['region'];
    if (regionValue is! String) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.regionUnsupported,
      );
    }
    final regionName = regionValue.trim().toUpperCase();
    final regulatoryRegion = _regionFor(regionCode, regionName);
    if (regulatoryRegion == null) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.regionUnsupported,
      );
    }
    final tel = _requiredMap(
      json,
      'tel',
      detail: DeviceReadyFailureDetail.telConfigurationMissing,
    );
    final sos = _requiredMap(
      json,
      'sos',
      detail: DeviceReadyFailureDetail.sosConfigurationMissing,
    );
    final config = StrictDeviceProvisioningConfig(
      regionCode: regionCode,
      region: regionValue,
      tel: ProvisioningTelConfig(
        frequencyKhz: _scaledExact(
          tel,
          'freq_mhz',
          1000,
          min: 100000,
          max: 1000000,
          wireMax: 0xffffffff,
          detail: DeviceReadyFailureDetail.telFrequencyInvalid,
        ),
        bandwidthKhz: _scaledExact(
          tel,
          'bw_khz',
          1,
          min: 1,
          max: 1000,
          wireMax: 0xffff,
          detail: DeviceReadyFailureDetail.telBandwidthInvalid,
        ),
        spreadingFactor: _requiredInt(
          tel,
          'sf_default',
          min: 0,
          max: 0xff,
          detail: DeviceReadyFailureDetail.telSpreadingFactorInvalid,
        ),
        codingRateDenominator: _codingRate(
          tel,
          'cr',
          detail: DeviceReadyFailureDetail.telCodingRateInvalid,
          rangeDetail: DeviceReadyFailureDetail.invalidCodingRate,
        ),
        txPowerDbm: _requiredInt(
          tel,
          'tx_power_uplink_dbm',
          min: -0x80,
          max: 0x7f,
          detail: DeviceReadyFailureDetail.telPowerInvalid,
        ),
      ),
      sos: ProvisioningSosConfig(
        frequencyHz: _scaledExact(
          sos,
          'freq_mhz',
          1000000,
          min: 100000000,
          max: 1000000000,
          wireMax: 0xffffffff,
          detail: DeviceReadyFailureDetail.sosFrequencyInvalid,
        ),
        bandwidthHz: _scaledExact(
          sos,
          'bw_khz',
          1000,
          min: 1000,
          max: 1000000,
          wireMax: 0xffffffff,
          detail: DeviceReadyFailureDetail.sosBandwidthInvalid,
        ),
        spreadingFactor: _requiredInt(
          sos,
          'sf',
          min: 0,
          max: 0xff,
          detail: DeviceReadyFailureDetail.sosSpreadingFactorInvalid,
          missingDetail: DeviceReadyFailureDetail.sosSpreadingFactorMissing,
          typeDetail: DeviceReadyFailureDetail.sosSpreadingFactorTypeInvalid,
        ),
        codingRateDenominator: _codingRate(
          sos,
          'cr',
          detail: DeviceReadyFailureDetail.sosCodingRateInvalid,
          rangeDetail: DeviceReadyFailureDetail.invalidCodingRate,
        ),
        txPowerDbm: _requiredInt(
          sos,
          'tx_power_dbm',
          min: -0x80,
          max: 0x7f,
          detail: DeviceReadyFailureDetail.sosPowerInvalid,
        ),
        preambleSymbols: _requiredInt(
          sos,
          'preamble_symbols',
          min: 0,
          max: 0xff,
          detail: DeviceReadyFailureDetail.sosPreambleInvalid,
        ),
      ),
    );
    _validateCapabilitiesAndRegion(config, regulatoryRegion);
    return config;
  }

  static Map<String, dynamic> _requiredMap(
    Map<String, dynamic> map,
    String key, {
    required DeviceReadyFailureDetail detail,
  }) {
    final value = map[key];
    if (value is! Map<String, dynamic>) {
      throw ProvisioningContractException(detail);
    }
    return value;
  }

  static int _requiredInt(
    Map<String, dynamic> map,
    String key, {
    required int min,
    required int max,
    required DeviceReadyFailureDetail detail,
    DeviceReadyFailureDetail? missingDetail,
    DeviceReadyFailureDetail? typeDetail,
    DeviceReadyFailureDetail? rangeDetail,
  }) {
    final value = map[key];
    if (value == null) {
      throw ProvisioningContractException(missingDetail ?? detail);
    }
    if (value is! int) {
      throw ProvisioningContractException(typeDetail ?? detail);
    }
    if (value < min || value > max) {
      throw ProvisioningContractException(
        rangeDetail ?? detail,
        observedInteger: value,
      );
    }
    return value;
  }

  static int _scaledExact(
    Map<String, dynamic> map,
    String key,
    int scale, {
    required int min,
    required int max,
    required int wireMax,
    required DeviceReadyFailureDetail detail,
  }) {
    final value = map[key];
    if (value is! num) {
      throw ProvisioningContractException(detail);
    }
    final result = scaleProvisioningDecimalExact(value, scale, detail: detail);
    if (result < min || result > max || result < 0 || result > wireMax) {
      throw ProvisioningContractException(detail);
    }
    return result;
  }

  static int _codingRate(
    Map<String, dynamic> map,
    String key, {
    required DeviceReadyFailureDetail detail,
    required DeviceReadyFailureDetail rangeDetail,
  }) {
    final value = map[key];
    if (value is! String) {
      throw ProvisioningContractException(detail);
    }
    final match = RegExp(r'^4/([0-9]+)$').firstMatch(value);
    final denominator = match == null ? null : int.tryParse(match.group(1)!);
    if (denominator == null) {
      throw ProvisioningContractException(detail);
    }
    if (denominator < 5 || denominator > 8) {
      throw ProvisioningContractException(
        rangeDetail,
        observedInteger: denominator,
      );
    }
    return denominator;
  }

  static void _validateCapabilitiesAndRegion(
    StrictDeviceProvisioningConfig config,
    _RegulatoryRegion region,
  ) {
    final telCenterHz = config.tel.frequencyKhz * 1000;
    final telBandwidthHz = config.tel.bandwidthKhz * 1000;
    if (!_channelFitsBand(
      centerHz: telCenterHz,
      bandwidthHz: telBandwidthHz,
      bandLowHz: region.telBandLowHz,
      bandHighHz: region.telBandHighHz,
    )) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.frequencyOutOfRegion,
      );
    }
    if (!_channelFitsBand(
      centerHz: config.sos.frequencyHz,
      bandwidthHz: config.sos.bandwidthHz,
      bandLowHz: region.sosBandLowHz,
      bandHighHz: region.sosBandHighHz,
    )) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.frequencyOutOfRegion,
      );
    }
    if (!_sx1262TelBandwidthsKhz.contains(config.tel.bandwidthKhz)) {
      throw ProvisioningContractException(
        DeviceReadyFailureDetail.unsupportedBandwidth,
        observedInteger: config.tel.bandwidthKhz,
      );
    }
    if (!_sx1262SosBandwidthsHz.contains(config.sos.bandwidthHz)) {
      throw ProvisioningContractException(
        DeviceReadyFailureDetail.unsupportedBandwidth,
        observedInteger: config.sos.bandwidthHz,
      );
    }
    if (config.tel.spreadingFactor < region.telMinSpreadingFactor ||
        config.tel.spreadingFactor > region.telMaxSpreadingFactor) {
      throw ProvisioningContractException(
        DeviceReadyFailureDetail.unsupportedSpreadingFactor,
        observedInteger: config.tel.spreadingFactor,
      );
    }
    if (config.sos.spreadingFactor < 7 || config.sos.spreadingFactor > 12) {
      throw ProvisioningContractException(
        DeviceReadyFailureDetail.unsupportedSpreadingFactor,
        observedInteger: config.sos.spreadingFactor,
      );
    }
    if (config.tel.txPowerDbm < 0 ||
        config.tel.txPowerDbm > region.telMaxPowerDbm ||
        config.tel.txPowerDbm > _sx1262MaxPowerDbm) {
      throw ProvisioningContractException(
        DeviceReadyFailureDetail.txPowerOutOfRange,
        observedInteger: config.tel.txPowerDbm,
      );
    }
    if (config.sos.txPowerDbm < 0 ||
        config.sos.txPowerDbm > region.sosMaxPowerDbm ||
        config.sos.txPowerDbm > _sx1262MaxPowerDbm) {
      throw ProvisioningContractException(
        DeviceReadyFailureDetail.txPowerOutOfRange,
        observedInteger: config.sos.txPowerDbm,
      );
    }
    // Firmware rejects fewer than six symbols. The one-byte 0x21 field is the
    // upper bound; 16 remains the current ES backend policy, not an SDK rule.
    if (config.sos.preambleSymbols < 6) {
      throw ProvisioningContractException(
        DeviceReadyFailureDetail.invalidPreamble,
        observedInteger: config.sos.preambleSymbols,
      );
    }
  }

  static _RegulatoryRegion? _regionFor(int code, String name) {
    for (final region in _supportedRegions) {
      if (region.code == code && region.name == name) return region;
    }
    return null;
  }

  static bool _channelFitsBand({
    required int centerHz,
    required int bandwidthHz,
    required int bandLowHz,
    required int bandHighHz,
  }) {
    final halfBandwidthHz = bandwidthHz ~/ 2;
    return centerHz - halfBandwidthHz >= bandLowHz &&
        centerHz + halfBandwidthHz <= bandHighHz;
  }
}

int scaleProvisioningDecimalExact(
  num value,
  int scale, {
  DeviceReadyFailureDetail detail =
      DeviceReadyFailureDetail.configurationNumericValueInvalid,
}) {
  if (!value.isFinite) throw ProvisioningContractException(detail);
  final match = RegExp(
    r'^([+-]?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$',
  ).firstMatch(value.toString());
  if (match == null) throw ProvisioningContractException(detail);
  final negative = match.group(1) == '-';
  final fraction = match.group(3) ?? '';
  final exponent = int.tryParse(match.group(4) ?? '0');
  if (exponent == null) throw ProvisioningContractException(detail);
  var numerator =
      BigInt.parse('${match.group(2)}$fraction') * BigInt.from(scale);
  var denominator = BigInt.one;
  final decimalPower = exponent - fraction.length;
  if (decimalPower >= 0) {
    numerator *= BigInt.from(10).pow(decimalPower);
  } else {
    denominator = BigInt.from(10).pow(-decimalPower);
  }
  if (numerator.remainder(denominator) != BigInt.zero) {
    throw ProvisioningContractException(detail);
  }
  final scaled = numerator ~/ denominator;
  final signed = negative ? -scaled : scaled;
  if (!signed.isValidInt) throw ProvisioningContractException(detail);
  return signed.toInt();
}

abstract interface class StrictDeviceProvisioningConfigSource {
  Future<StrictDeviceProvisioningConfig> fetch({required String countryIso});
}

final class HttpStrictDeviceProvisioningConfigSource
    implements StrictDeviceProvisioningConfigSource {
  HttpStrictDeviceProvisioningConfigSource({required this.transport});

  final SdkHttpTransport transport;

  @override
  Future<StrictDeviceProvisioningConfig> fetch({
    required String countryIso,
  }) async {
    final iso = countryIso.trim();
    if (iso.isEmpty) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.countryIsoMissing,
      );
    }
    final path = Uri(
      path: '/v1/sdk/device-configs',
      queryParameters: <String, String>{'country_iso': iso},
    ).toString();
    final response = await transport.get(
      path,
      headers: const <String, String>{'Accept': 'application/json'},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NetworkException(
        response.statusCode == 401
            ? 'E_PROVISIONING_AUTH_FAILED'
            : 'E_PROVISIONING_RF_FAILED',
        response.statusCode == 401
            ? 'E_PROVISIONING_AUTH_FAILED'
            : 'E_PROVISIONING_RF_FAILED',
      );
    }
    final Object decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.configurationResponseInvalidJson,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.configurationResponseNotObject,
      );
    }
    return StrictDeviceProvisioningConfig.parse(decoded);
  }
}

Uint8List encodeFullRadioConfig(StrictDeviceProvisioningConfig config) {
  final bytes = Uint8List(12);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 0x20;
  bytes[1] = config.regionCode;
  bytes[2] = 0x01;
  data.setUint32(3, config.tel.frequencyKhz, Endian.little);
  data.setUint16(7, config.tel.bandwidthKhz, Endian.little);
  bytes[9] = config.tel.spreadingFactor;
  bytes[10] = config.tel.codingRateDenominator;
  data.setInt8(11, config.tel.txPowerDbm);
  return bytes;
}

Uint8List encodeSosRadioConfig(StrictDeviceProvisioningConfig config) {
  final bytes = Uint8List(14);
  final data = ByteData.sublistView(bytes);
  bytes[0] = 0x21;
  bytes[1] = 0x01;
  data.setUint32(2, config.sos.frequencyHz, Endian.little);
  data.setUint32(6, config.sos.bandwidthHz, Endian.little);
  bytes[10] = config.sos.spreadingFactor;
  bytes[11] = config.sos.codingRateDenominator;
  data.setInt8(12, config.sos.txPowerDbm);
  bytes[13] = config.sos.preambleSymbols;
  return bytes;
}
