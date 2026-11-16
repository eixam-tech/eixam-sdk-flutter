import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

const _eixamUuid = '6ba1b218-15a8-461f-9fa8-5dcae273ea00';
const _stockUuid = '6ba1b218-15a8-461f-9fa8-5dcae273eafd';

EixamPairingDisplayCategory _classify(
  String? name, {
  List<String> uuids = const <String>[],
  bool dfu = false,
}) => classifyEixamPairingDisplay(
  name: name,
  advertisedServiceUuids: uuids,
  dfuServiceAdvertised: dfu,
);

void main() {
  group('classifyEixamPairingDisplay', () {
    test('historical Eixam names are eixam', () {
      for (final name in <String>[
        'EIXAM_a1b2', // <= 2.7.35, lowercase 4 hex
        'EIXAM_594B1AA8', // 2.7.36 - 2.7.62
        'N6BF425B', // 2.7.63
        'EIXAM_A68E6171', // >= 2.7.65
        'eixam_a68e6171',
        '  EIXAM_A68E6171  ',
        'n6bf425b',
        'N6A26F74',
      ]) {
        expect(
          _classify(name),
          EixamPairingDisplayCategory.eixam,
          reason: name,
        );
      }
    });

    test('Eixam service UUID is eixam even without a name', () {
      expect(
        _classify(null, uuids: [_eixamUuid]),
        EixamPairingDisplayCategory.eixam,
      );
      expect(
        _classify('', uuids: [_eixamUuid.toUpperCase()]),
        EixamPairingDisplayCategory.eixam,
      );
      expect(
        _classify('Unknown', uuids: [' $_eixamUuid ']),
        EixamPairingDisplayCategory.eixam,
      );
    });

    test('stock Meshtastic name or UUID is legacyOrStock', () {
      expect(
        _classify('Meshtastic_a148'),
        EixamPairingDisplayCategory.legacyOrStock,
      );
      expect(
        _classify('MESHTASTIC_A148'),
        EixamPairingDisplayCategory.legacyOrStock,
      );
      // Unprovisioned Eixam TAG <= 2.7.53 only advertised the stock UUID.
      expect(
        _classify('', uuids: [_stockUuid]),
        EixamPairingDisplayCategory.legacyOrStock,
      );
      expect(
        _classify('ABCD_a148', uuids: [_stockUuid]),
        EixamPairingDisplayCategory.legacyOrStock,
      );
    });

    test('Eixam service wins over stock service', () {
      expect(
        _classify('EIXAM_A68E6171', uuids: [_stockUuid, _eixamUuid]),
        EixamPairingDisplayCategory.eixam,
      );
    });

    test('DFU bootloader by name or DFU service is dfuRecovery', () {
      expect(_classify('AdaDFU'), EixamPairingDisplayCategory.dfuRecovery);
      expect(_classify('adadfu'), EixamPairingDisplayCategory.dfuRecovery);
      expect(
        _classify('DfuTarg', dfu: true),
        EixamPairingDisplayCategory.dfuRecovery,
      );
      expect(
        _classify(null, dfu: true),
        EixamPairingDisplayCategory.dfuRecovery,
      );
    });

    test('gateways are hidden regardless of UUIDs or DFU', () {
      expect(
        _classify('EIXAM_GW_0011AABB'),
        EixamPairingDisplayCategory.hidden,
      );
      expect(
        _classify('eixam_gw_0011aabb', uuids: [_stockUuid]),
        EixamPairingDisplayCategory.hidden,
      );
      expect(
        _classify('EIXAM_GW_0011AABB', uuids: [_eixamUuid]),
        EixamPairingDisplayCategory.hidden,
      );
      expect(
        _classify('EIXAM_GW_0011AABB', dfu: true),
        EixamPairingDisplayCategory.hidden,
      );
      expect(isEixamGatewayName(' EIXAM_GW_1 '), isTrue);
      expect(isEixamGatewayName('EIXAM_A68E6171'), isFalse);
      expect(isEixamGatewayName(null), isFalse);
    });

    test('unknown devices are hidden', () {
      for (final name in <String?>[
        null,
        '',
        'Unknown',
        'Galaxy Buds',
        'Manual EIXAM',
        'My EIXAM_TAG',
        'N64xyz',
        'N6A26F7', // 5 hex
        'N6A26F741', // 7 hex
        'N6A26F7G', // non-hex
        'AdaDFU2',
        'Meshtastic',
      ]) {
        expect(
          _classify(name),
          EixamPairingDisplayCategory.hidden,
          reason: '$name',
        );
      }
      expect(
        _classify(
          'Galaxy Buds',
          uuids: ['0000180f-0000-1000-8000-00805f9b34fb'],
        ),
        EixamPairingDisplayCategory.hidden,
      );
    });
  });

  test('N6 names with a known UUID still match by UUID', () {
    expect(
      _classify('N64xyz', uuids: [_eixamUuid]),
      EixamPairingDisplayCategory.eixam,
    );
    expect(
      _classify('N6A26F7', uuids: [_stockUuid]),
      EixamPairingDisplayCategory.legacyOrStock,
    );
  });

  group('EixamPairingDisplayFilter', () {
    test('keeps a device shown by UUID when a later poll lacks the name', () {
      final filter = EixamPairingDisplayFilter();
      expect(
        filter.resolve(deviceId: 'a', fresh: EixamPairingDisplayCategory.eixam),
        EixamPairingDisplayCategory.eixam,
      );
      expect(
        filter.resolve(
          deviceId: 'a',
          fresh: EixamPairingDisplayCategory.hidden,
          name: 'Unknown',
        ),
        EixamPairingDisplayCategory.eixam,
      );
    });

    test('a fresh visible category replaces the remembered one', () {
      final filter = EixamPairingDisplayFilter();
      filter.resolve(
        deviceId: 'a',
        fresh: EixamPairingDisplayCategory.legacyOrStock,
      );
      expect(
        filter.resolve(deviceId: 'a', fresh: EixamPairingDisplayCategory.eixam),
        EixamPairingDisplayCategory.eixam,
      );
      expect(
        filter.resolve(
          deviceId: 'a',
          fresh: EixamPairingDisplayCategory.hidden,
        ),
        EixamPairingDisplayCategory.eixam,
      );
    });

    test('a later gateway name hides and forgets the device', () {
      final filter = EixamPairingDisplayFilter();
      filter.resolve(
        deviceId: 'gw',
        fresh: EixamPairingDisplayCategory.legacyOrStock,
      );
      expect(
        filter.resolve(
          deviceId: 'gw',
          fresh: EixamPairingDisplayCategory.hidden,
          name: 'EIXAM_GW_0011AABB',
        ),
        EixamPairingDisplayCategory.hidden,
      );
      expect(
        filter.resolve(
          deviceId: 'gw',
          fresh: EixamPairingDisplayCategory.hidden,
        ),
        EixamPairingDisplayCategory.hidden,
      );
    });

    test('never-shown hidden devices stay hidden; ids are independent', () {
      final filter = EixamPairingDisplayFilter();
      filter.resolve(deviceId: 'a', fresh: EixamPairingDisplayCategory.eixam);
      expect(
        filter.resolve(
          deviceId: 'b',
          fresh: EixamPairingDisplayCategory.hidden,
        ),
        EixamPairingDisplayCategory.hidden,
      );
    });

    test('reset forgets shown devices', () {
      final filter = EixamPairingDisplayFilter();
      filter.resolve(
        deviceId: 'a',
        fresh: EixamPairingDisplayCategory.dfuRecovery,
      );
      filter.reset();
      expect(
        filter.resolve(
          deviceId: 'a',
          fresh: EixamPairingDisplayCategory.hidden,
        ),
        EixamPairingDisplayCategory.hidden,
      );
    });
  });
}
