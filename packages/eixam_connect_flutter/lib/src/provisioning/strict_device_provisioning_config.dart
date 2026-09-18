import 'dart:convert';
import 'dart:typed_data';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../data/datasources_remote/sdk_http_transport.dart';

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
      min: 3,
      max: 3,
      detail: DeviceReadyFailureDetail.loraRegionCodeInvalid,
    );
    if (json['plan_verified'] != true) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.planNotVerified,
      );
    }
    final region = json['region'];
    if (region is! String || region.trim().toUpperCase() != 'EU868') {
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
      region: region,
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
          min: 7,
          max: 9,
          detail: DeviceReadyFailureDetail.telSpreadingFactorInvalid,
        ),
        codingRateDenominator: _codingRate(
          tel,
          'cr',
          detail: DeviceReadyFailureDetail.telCodingRateInvalid,
        ),
        txPowerDbm: _requiredInt(
          tel,
          'tx_power_uplink_dbm',
          min: 0,
          max: 14,
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
          min: 7,
          max: 7,
          detail: DeviceReadyFailureDetail.sosSpreadingFactorInvalid,
          missingDetail: DeviceReadyFailureDetail.sosSpreadingFactorMissing,
          typeDetail: DeviceReadyFailureDetail.sosSpreadingFactorTypeInvalid,
          rangeDetail: DeviceReadyFailureDetail.sosSpreadingFactorNotCertified,
        ),
        codingRateDenominator: _codingRate(
          sos,
          'cr',
          detail: DeviceReadyFailureDetail.sosCodingRateInvalid,
        ),
        txPowerDbm: _requiredInt(
          sos,
          'tx_power_dbm',
          min: 0,
          max: 22,
          detail: DeviceReadyFailureDetail.sosPowerInvalid,
        ),
        preambleSymbols: _requiredInt(
          sos,
          'preamble_symbols',
          min: 16,
          max: 16,
          detail: DeviceReadyFailureDetail.sosPreambleInvalid,
        ),
      ),
    );
    _validateCertifiedEu868(config);
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
  }) {
    final value = map[key];
    if (value is! String) {
      throw ProvisioningContractException(detail);
    }
    final match = RegExp(r'^4/([0-9]+)$').firstMatch(value);
    final denominator = match == null ? null : int.tryParse(match.group(1)!);
    if (denominator == null || denominator < 5 || denominator > 8) {
      throw ProvisioningContractException(detail);
    }
    return denominator;
  }

  static void _validateCertifiedEu868(StrictDeviceProvisioningConfig config) {
    // Mirrors firmware EixamRegionPlanTable's sole source-certified plan.
    const telBandLowHz = 865000000;
    const telBandHighHz = 868000000;
    const sosBandLowHz = 869400000;
    const sosBandHighHz = 869650000;
    final telCenterHz = config.tel.frequencyKhz * 1000;
    final telBandwidthHz = config.tel.bandwidthKhz * 1000;
    final telFits =
        telCenterHz - telBandwidthHz ~/ 2 >= telBandLowHz &&
        telCenterHz + telBandwidthHz ~/ 2 <= telBandHighHz;
    final sosFits =
        config.sos.frequencyHz - config.sos.bandwidthHz ~/ 2 >= sosBandLowHz &&
        config.sos.frequencyHz + config.sos.bandwidthHz ~/ 2 <= sosBandHighHz;
    if (!telFits ||
        !sosFits ||
        config.tel.bandwidthKhz != 250 ||
        config.tel.codingRateDenominator != 5 ||
        config.sos.bandwidthHz != 62500 ||
        config.sos.codingRateDenominator != 5) {
      throw const ProvisioningContractException(
        DeviceReadyFailureDetail.certifiedPlanMismatch,
      );
    }
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
