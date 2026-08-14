import 'dart:typed_data';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/provisioning/strict_device_provisioning_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  Map<String, dynamic> fixture() => <String, dynamic>{
        'lora_region_code': 3,
        'plan_verified': true,
        'region': 'EU868',
        'tel': <String, dynamic>{
          'freq_mhz': 866.5,
          'bw_khz': 250,
          'sf_default': 9,
          'cr': '4/5',
          'tx_power_uplink_dbm': 14,
        },
        'sos': <String, dynamic>{
          'freq_mhz': 869.4625,
          'bw_khz': 62.5,
          'sf': 12,
          'cr': '4/8',
          'tx_power_dbm': 22,
          'preamble_symbols': 8,
        },
      };

  test('strict EU868 fixture converts without rounding', () {
    final config = StrictDeviceProvisioningConfig.parse(fixture());

    expect(config.regionCode, 3);
    expect(config.tel.frequencyKhz, 866500);
    expect(config.tel.bandwidthKhz, 250);
    expect(config.tel.codingRateDenominator, 5);
    expect(config.sos.frequencyHz, 869462500);
    expect(config.sos.bandwidthHz, 62500);
    expect(config.sos.codingRateDenominator, 8);
  });

  test('decimal scaling is rational and supports exponent notation', () {
    expect(scaleProvisioningDecimalExact(128.002, 1000), 128002);
    expect(scaleProvisioningDecimalExact(1.28002e2, 1000), 128002);
    expect(scaleProvisioningDecimalExact(869.4625, 1000000), 869462500);
    expect(() => scaleProvisioningDecimalExact(128.0025, 1000),
        throwsA(isA<ProvisioningContractException>()));
  });

  test('fails closed outside the source-certified EU868 plan', () {
    final wrongRegion = fixture()..['lora_region_code'] = 4;
    final wrongName = fixture()..['region'] = 'US915';
    final wrongTelCr = fixture();
    (wrongTelCr['tel'] as Map<String, dynamic>)['cr'] = '4/6';
    final outOfBand = fixture();
    (outOfBand['tel'] as Map<String, dynamic>)['freq_mhz'] = 868.0;
    for (final invalid in <Map<String, dynamic>>[
      wrongRegion,
      wrongName,
      wrongTelCr,
      outOfBand,
    ]) {
      expect(() => StrictDeviceProvisioningConfig.parse(invalid),
          throwsA(isA<ProvisioningContractException>()));
    }
  });

  test('requires every field, exact type, and verified plan', () {
    final missing = fixture()..remove('sos');
    final wrongType = fixture()..['lora_region_code'] = 3.0;
    final unverified = fixture()..['plan_verified'] = false;

    expect(() => StrictDeviceProvisioningConfig.parse(missing),
        throwsA(isA<ProvisioningContractException>()));
    expect(() => StrictDeviceProvisioningConfig.parse(wrongType),
        throwsA(isA<ProvisioningContractException>()));
    expect(() => StrictDeviceProvisioningConfig.parse(unverified),
        throwsA(isA<ProvisioningContractException>()));
  });

  test('rejects nonfinite, fractional wire values, overflow and malformed CR',
      () {
    final nonfinite = fixture();
    (nonfinite['tel'] as Map<String, dynamic>)['freq_mhz'] = double.infinity;
    final fractional = fixture();
    (fractional['tel'] as Map<String, dynamic>)['freq_mhz'] = 866.5001;
    final overflow = fixture();
    (overflow['sos'] as Map<String, dynamic>)['freq_mhz'] = 5000;
    final malformedCr = fixture();
    (malformedCr['tel'] as Map<String, dynamic>)['cr'] = '5/8';

    for (final invalid in <Map<String, dynamic>>[
      nonfinite,
      fractional,
      overflow,
      malformedCr,
    ]) {
      expect(() => StrictDeviceProvisioningConfig.parse(invalid),
          throwsA(isA<ProvisioningContractException>()));
    }
  });

  test('rejects invalid SF, power, bandwidth, region and preamble ranges', () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (json) => (json['tel'] as Map<String, dynamic>)['sf_default'] = 13,
      (json) =>
          (json['tel'] as Map<String, dynamic>)['tx_power_uplink_dbm'] = 128,
      (json) => (json['sos'] as Map<String, dynamic>)['bw_khz'] = 0,
      (json) => json['lora_region_code'] = 256,
      (json) => (json['sos'] as Map<String, dynamic>)['preamble_symbols'] = 0,
    ];
    for (final mutate in mutations) {
      final json = fixture();
      mutate(json);
      expect(() => StrictDeviceProvisioningConfig.parse(json),
          throwsA(isA<ProvisioningContractException>()));
    }
  });

  test('0x20 full encoder is exact little-endian', () {
    final config = StrictDeviceProvisioningConfig.parse(fixture());
    final encoded = encodeFullRadioConfig(config);
    final data = ByteData.sublistView(encoded);

    expect(encoded, hasLength(12));
    expect(encoded.sublist(0, 3), <int>[0x20, 3, 1]);
    expect(data.getUint32(3, Endian.little), 866500);
    expect(data.getUint16(7, Endian.little), 250);
    expect(encoded.sublist(9), <int>[9, 5, 14]);
  });

  test('0x21 encoder is exact 14-byte little-endian form', () {
    final encoded = encodeSosRadioConfig(
      StrictDeviceProvisioningConfig.parse(fixture()),
    );
    final data = ByteData.sublistView(encoded);

    expect(encoded, hasLength(14));
    expect(encoded.sublist(0, 2), <int>[0x21, 1]);
    expect(data.getUint32(2, Endian.little), 869462500);
    expect(data.getUint32(6, Endian.little), 62500);
    expect(encoded.sublist(10), <int>[12, 8, 22, 8]);
  });

  test('strict HTTP source uses signed country endpoint and never defaults',
      () async {
    final client = _RecordingClient(
      response: http.Response(_fixtureJson, 200),
    );
    final session = SdkSessionContext()
      ..currentSession = const EixamSession.signed(
        appId: 'app-test',
        externalUserId: 'user-test',
        userHash: 'hash-test',
      );
    final source = HttpStrictDeviceProvisioningConfigSource(
      transport: SdkHttpTransport(
        client: client,
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://api.staging.eixam.io',
          websocketUrl: 'wss://mqtt.staging.eixam.io',
        ),
        sessionContext: session,
      ),
    );

    final config = await source.fetch(countryIso: 'ES');
    final request = client.requests.single;
    expect(config.regionCode, 3);
    expect(request.url.path, '/v1/sdk/device-configs');
    expect(request.url.queryParameters, <String, String>{'country_iso': 'ES'});
    expect(request.headers['X-App-ID'], 'app-test');
    expect(request.headers['Authorization'], 'Bearer hash-test');
    await expectLater(
      source.fetch(countryIso: ''),
      throwsA(isA<ProvisioningContractException>()),
    );
  });
}

const String _fixtureJson = '''
{
  "lora_region_code": 3,
  "plan_verified": true,
  "region": "EU868",
  "tel": {
    "freq_mhz": 866.5,
    "bw_khz": 250,
    "sf_default": 9,
    "cr": "4/5",
    "tx_power_uplink_dbm": 14
  },
  "sos": {
    "freq_mhz": 869.4625,
    "bw_khz": 62.5,
    "sf": 12,
    "cr": "4/8",
    "tx_power_dbm": 22,
    "preamble_symbols": 8
  }
}
''';

final class _RecordingClient extends http.BaseClient {
  _RecordingClient({required this.response});

  final http.Response response;
  final List<http.BaseRequest> requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream<List<int>>.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  }
}
