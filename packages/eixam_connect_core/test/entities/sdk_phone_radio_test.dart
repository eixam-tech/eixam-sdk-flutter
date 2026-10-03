import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('mapPhoneRadio', () {
    test('NSA override is 5g nsa even when the data tech is LTE', () {
      final radio = mapPhoneRadio(
        const SdkPhoneRadioReading(
          networkType: AndroidNetworkType.lte,
          overrideNetworkType: AndroidOverrideNetworkType.nrNsa,
          cellularDataConnected: true,
        ),
      );

      expect(radio?.toJson(), <String, dynamic>{
        'generation': '5g',
        'fiveGMode': 'nsa',
        'connected': true,
      });
    });

    test('NR without NSA is 5g sa', () {
      final radio = mapPhoneRadio(
        const SdkPhoneRadioReading(
          networkType: AndroidNetworkType.nr,
          cellularDataConnected: false,
        ),
      );

      expect(radio?.toJson(), <String, dynamic>{
        'generation': '5g',
        'fiveGMode': 'sa',
        'connected': false,
      });
    });

    test('NR advanced on LTE omits fiveGMode', () {
      final radio = mapPhoneRadio(
        const SdkPhoneRadioReading(
          networkType: AndroidNetworkType.lte,
          overrideNetworkType: AndroidOverrideNetworkType.nrAdvanced,
        ),
      );

      expect(radio?.toJson(), <String, dynamic>{'generation': '5g'});
    });

    test('NR advanced on NR is standalone', () {
      final radio = mapPhoneRadio(
        const SdkPhoneRadioReading(
          networkType: AndroidNetworkType.nr,
          overrideNetworkType: AndroidOverrideNetworkType.nrAdvanced,
          cellularDataConnected: true,
        ),
      );

      expect(radio?.fiveGMode, 'sa');
    });

    test('mmWave NSA override is 5g nsa', () {
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(
            networkType: AndroidNetworkType.lte,
            overrideNetworkType: AndroidOverrideNetworkType.nrNsaMmwave,
          ),
        )?.toJson(),
        <String, dynamic>{'generation': '5g', 'fiveGMode': 'nsa'},
      );
    });

    test('LTE and LTE-CA are 4g', () {
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(networkType: AndroidNetworkType.lte),
        )?.generation,
        '4g',
      );
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(
            overrideNetworkType: AndroidOverrideNetworkType.lteCa,
          ),
        )?.generation,
        '4g',
      );
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(networkType: AndroidNetworkType.lteCa),
        )?.generation,
        '4g',
      );
    });

    test('UMTS WCDMA and HSPA are 3g', () {
      for (final network in <int>[
        AndroidNetworkType.umts,
        AndroidNetworkType.hspa,
        AndroidNetworkType.hsdpa,
        AndroidNetworkType.hsupa,
        AndroidNetworkType.hspap,
      ]) {
        expect(
          mapPhoneRadio(SdkPhoneRadioReading(networkType: network))?.generation,
          '3g',
        );
      }
    });

    test('GSM EDGE and GPRS are 2g', () {
      for (final network in <int>[
        AndroidNetworkType.gsm,
        AndroidNetworkType.edge,
        AndroidNetworkType.gprs,
      ]) {
        expect(
          mapPhoneRadio(SdkPhoneRadioReading(networkType: network))?.generation,
          '2g',
        );
      }
    });

    test('iOS NR and NRNSA map to sa and nsa', () {
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(
            radioAccessTechnology: 'CTRadioAccessTechnologyNR',
            cellularDataConnected: true,
          ),
        )?.toJson(),
        <String, dynamic>{
          'generation': '5g',
          'fiveGMode': 'sa',
          'connected': true,
        },
      );
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(
            radioAccessTechnology: 'CTRadioAccessTechnologyNRNSA',
          ),
        )?.toJson(),
        <String, dynamic>{'generation': '5g', 'fiveGMode': 'nsa'},
      );
    });

    test('iOS LTE WCDMA and EDGE map to 4g 3g and 2g', () {
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(
            radioAccessTechnology: 'CTRadioAccessTechnologyLTE',
          ),
        )?.generation,
        '4g',
      );
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(
            radioAccessTechnology: 'CTRadioAccessTechnologyWCDMA',
          ),
        )?.generation,
        '3g',
      );
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(
            radioAccessTechnology: 'CTRadioAccessTechnologyEdge',
          ),
        )?.generation,
        '2g',
      );
    });

    test('wifi IWLAN empty and unknown produce no radio', () {
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(networkType: AndroidNetworkType.iwlan),
        ),
        isNull,
      );
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(
            networkType: AndroidNetworkType.iwlan,
            overrideNetworkType: AndroidOverrideNetworkType.nrNsa,
            cellularDataConnected: false,
          ),
        )?.toJson(),
        <String, dynamic>{
          'generation': '5g',
          'fiveGMode': 'nsa',
          'connected': false,
        },
      );
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(radioAccessTechnology: 'wifi'),
        ),
        isNull,
      );
      expect(
        mapPhoneRadio(const SdkPhoneRadioReading(radioAccessTechnology: '')),
        isNull,
      );
      expect(
        mapPhoneRadio(
          const SdkPhoneRadioReading(networkType: AndroidNetworkType.unknown),
        ),
        isNull,
      );
      expect(mapPhoneRadio(const SdkPhoneRadioReading()), isNull);
      expect(
        () => SdkPhoneRadioReading.fromJson(const <String, Object?>{
          'networkType': 'lte',
          'cellularDataConnected': 1,
          'radioAccessTechnology': 4,
        }),
        returnsNormally,
      );
      expect(
        SdkPhoneRadioReading.fromJson(const <String, Object?>{
          'networkType': 'lte',
          'cellularDataConnected': 1,
        }).cellularDataConnected,
        isNull,
      );
    });
  });

  group('resolvePhoneRadio', () {
    test('app and native_background keep or fill radio', () {
      final existing = _payload(identitySource: 'app').copyWith(
        radio: const SdkRadioSnapshot(generation: '4g', connected: true),
      );
      expect(
        resolvePhoneRadio(payload: existing, fixIdentitySource: 'app').radio,
        existing.radio,
      );

      final filled = resolvePhoneRadio(
        payload: _payload(identitySource: 'native_background'),
        fixIdentitySource: 'native_background',
        probed: const SdkPhoneRadioReading(
          networkType: AndroidNetworkType.lte,
          cellularDataConnected: true,
        ),
      );
      expect(filled.radio?.generation, '4g');
    });

    test('a sampled wifi fix is not replaced by a later probe', () {
      final sampled = _payload(
        identitySource: 'native_background',
      ).copyWith(phoneRadioSampled: true);
      final resolved = resolvePhoneRadio(
        payload: sampled,
        fixIdentitySource: 'native_background',
        probed: const SdkPhoneRadioReading(
          networkType: AndroidNetworkType.nr,
          cellularDataConnected: true,
        ),
      );

      expect(resolved.radio, isNull);
      expect(
        shouldProbePhoneRadio(
          fixIdentitySource: 'native_background',
          payload: sampled,
        ),
        isFalse,
      );
    });

    test('tag relay and other identities drop radio', () {
      for (final identity in <String?>[
        'ble_node',
        'remote_relay',
        'backend_snapshot',
        'cached_fallback',
        'device_hardware',
        null,
      ]) {
        final payload = _payload(identitySource: identity).copyWith(
          radio: const SdkRadioSnapshot(generation: '5g', fiveGMode: 'sa'),
        );
        expect(
          resolvePhoneRadio(
            payload: payload,
            fixIdentitySource: identity,
          ).radio,
          isNull,
          reason: identity,
        );
        expect(
          shouldProbePhoneRadio(fixIdentitySource: identity, payload: payload),
          isFalse,
          reason: identity,
        );
      }
    });
  });
}

SdkTelemetryPayload _payload({String? identitySource}) {
  return SdkTelemetryPayload(
    timestamp: DateTime.utc(2026, 3, 31, 10, 15),
    latitude: 41.38,
    longitude: 2.17,
    altitude: 8,
    identitySource: identitySource,
  );
}
