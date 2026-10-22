import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'read-only lookup validates before scanning and never acquires a current TAG',
    () async {
      final sdk = _ReadOnlySdk([
        scan(
          'target',
          name: 'EIXAM_A693756E',
          brand: BleDiscoveredDeviceBrand.eixam,
          mac: 'E9:B4:55:93:75:6E',
        ),
      ]);
      expect(
        (await TagPairingCodeCorrelator.lookup(
          sdk,
          'https://example.com',
        )).state,
        TagPairingCodeMatchState.unsupportedCode,
      );
      expect(sdk.scans, 0);
      final result = await TagPairingCodeCorrelator.lookup(sdk, 'N693756E');
      expect(result.state, TagPairingCodeMatchState.matched);
      expect(result.candidate!.deviceId, 'target');
      expect(sdk.inspections, 0);
      expect(sdk.scans, 1);
    },
  );

  test('read-only lookup inspects only the unique legacy candidate', () async {
    final sdk = _ReadOnlySdk([scan('selected')]);
    expect(
      (await TagPairingCodeCorrelator.lookup(sdk, 'N693756E')).state,
      TagPairingCodeMatchState.matched,
    );
    expect(sdk.inspections, 1);
    sdk.devices = [scan('selected'), scan('other')];
    expect(
      (await TagPairingCodeCorrelator.lookup(sdk, 'N693756E')).state,
      TagPairingCodeMatchState.ambiguous,
    );
    expect(sdk.inspections, 1);
  });

  test('current discovery rejects missing and contradictory MAC evidence', () {
    for (final mac in [null, 'E1:5F:27:D4:47:DB']) {
      final lookup = TagPairingCodeCorrelator.find('N693756E', [
        scan(
          'target',
          name: 'EIXAM_A693756E',
          brand: BleDiscoveredDeviceBrand.eixam,
          mac: mac,
        ),
      ]);
      expect(
        TagPairingCodeCorrelator.verifyCurrentDiscovery(lookup).state,
        mac == null
            ? TagPairingCodeMatchState.identityUnverified
            : TagPairingCodeMatchState.identityMismatch,
      );
    }
  });

  test('invalid and unsupported QR values never produce candidates', () {
    expect(
      TagPairingCodeCorrelator.find('', []).state,
      TagPairingCodeMatchState.invalidCode,
    );
    expect(
      TagPairingCodeCorrelator.find('ABCDEFGH', []).state,
      TagPairingCodeMatchState.unsupportedCode,
    );
  });

  test(
    'only exact legacy naming and brand semantics shortlist a candidate',
    () {
      for (final device in [
        scan('wrong', name: 'Meshtastic_756F'),
        scan('unrelated', name: 'Headphones_756E'),
        scan('extra', name: 'Meshtastic_1756E'),
        scan('brand', brand: BleDiscoveredDeviceBrand.unknown),
        scan('dfu', dfu: true),
        scan('offline', connectable: false),
      ]) {
        expect(
          TagPairingCodeCorrelator.find('N693756E', [device]).state,
          TagPairingCodeMatchState.notFound,
        );
      }
      final result = TagPairingCodeCorrelator.find('n693756e', [
        scan('selected', name: 'meshtastic_756e'),
      ]);
      expect(result.state, TagPairingCodeMatchState.inspectionRequired);
      expect(result.candidate!.deviceId, 'selected');
    },
  );

  test(
    'zero, one and multiple candidates are independent of RSSI and order',
    () {
      expect(
        TagPairingCodeCorrelator.find('N693756E', []).state,
        TagPairingCodeMatchState.notFound,
      );
      final weak = scan('weak', rssi: -99);
      final strong = scan('strong', rssi: -20);
      for (final devices in [
        [weak, strong],
        [strong, weak],
      ]) {
        final result = TagPairingCodeCorrelator.find('N693756E', devices);
        expect(result.state, TagPairingCodeMatchState.ambiguous);
        expect(result.candidate, isNull);
      }
      expect(
        TagPairingCodeCorrelator.find('N693756E', [weak, weak]).state,
        TagPairingCodeMatchState.inspectionRequired,
      );
    },
  );

  test(
    'legacy verification requires full six-digit hardware evidence on selected TAG',
    () {
      final lookup = TagPairingCodeCorrelator.find('N693756E', [
        scan('selected'),
      ]);
      expect(
        TagPairingCodeCorrelator.verifyLegacy(lookup, inspected()).state,
        TagPairingCodeMatchState.matched,
      );
      expect(
        TagPairingCodeCorrelator.verifyLegacy(
          lookup,
          inspected(mac: 'AA:BB:CC:12:75:6E'),
        ).state,
        TagPairingCodeMatchState.identityMismatch,
      );
      expect(
        TagPairingCodeCorrelator.verifyLegacy(
          lookup,
          inspected(id: 'other'),
        ).state,
        TagPairingCodeMatchState.identityMismatch,
      );
      expect(
        TagPairingCodeCorrelator.verifyLegacy(
          lookup,
          inspected(
            kind: DeviceMigrationIdentityKind.meshtasticNodeNumber,
            mac: '!0093756e',
          ),
        ).state,
        TagPairingCodeMatchState.identityUnverified,
      );
      expect(
        TagPairingCodeCorrelator.verifyLegacy(
          lookup,
          inspected(compatibility: DeviceMigrationCompatibility.unableToVerify),
        ).state,
        TagPairingCodeMatchState.identityUnverified,
      );
      expect(
        TagPairingCodeCorrelator.verifyLegacy(
          lookup,
          inspected(
            compatibility: DeviceMigrationCompatibility.unsupportedHardware,
          ),
        ).state,
        TagPairingCodeMatchState.unsupportedHardware,
      );
    },
  );

  test(
    'confirmed lookup is revalidated rather than accepting another connected TAG',
    () {
      final current = TagPairingCodeCorrelator.find('N693756E', [
        scan(
          'selected',
          name: 'EIXAM_A693756E',
          brand: BleDiscoveredDeviceBrand.eixam,
        ),
      ]);
      final matched = TagPairingCodeCorrelator.verifyCurrent(current, status());
      expect(matched.state, TagPairingCodeMatchState.matched);
      expect(
        TagPairingCodeCorrelator.verifyCurrent(
          matched,
          status(id: 'other'),
        ).state,
        TagPairingCodeMatchState.identityMismatch,
      );
      final legacy = TagPairingCodeCorrelator.verifyLegacy(
        TagPairingCodeCorrelator.find('N693756E', [scan('selected')]),
        inspected(),
      );
      expect(
        TagPairingCodeCorrelator.verifyLegacy(
          legacy,
          inspected(id: 'other'),
        ).state,
        TagPairingCodeMatchState.identityMismatch,
      );
    },
  );

  test(
    'recorded physical target metadata agrees with box while old bench is rejected',
    () {
      // QR-P1 read-only USB metadata and Android discovery, not a simulated flash.
      const targetMac = 'E9:B4:55:93:75:6E';
      final target = scan(
        targetMac,
        name: 'EIXAM_A693756E',
        brand: BleDiscoveredDeviceBrand.eixam,
        mac: targetMac,
      );
      final oldBench = scan(
        'E1:5F:27:D4:47:DB',
        name: 'EIXAM_A6D447DB',
        brand: BleDiscoveredDeviceBrand.eixam,
        mac: 'E1:5F:27:D4:47:DB',
      );
      final lookup = TagPairingCodeCorrelator.find('N693756E', [
        oldBench,
        target,
      ]);
      expect(lookup.candidate!.deviceId, targetMac);
      expect(lookup.state, TagPairingCodeMatchState.inspectionRequired);
      // Discovery remains a candidate; a disconnected runtime is no success.
      expect(
        TagPairingCodeCorrelator.verifyCurrent(
          lookup,
          status(id: targetMac, mac: targetMac, connected: false),
        ).state,
        TagPairingCodeMatchState.identityUnverified,
      );
      expect(
        TagPairingCodeCorrelator.verifyCurrent(
          lookup,
          status(id: oldBench.deviceId, mac: oldBench.canonicalHardwareId),
        ).state,
        TagPairingCodeMatchState.identityMismatch,
      );
    },
  );

  test(
    'current and historical Eixam names shortlist, but names alone never confirm',
    () {
      for (final name in ['EIXAM_A693756E', 'N693756E']) {
        final lookup = TagPairingCodeCorrelator.find('N693756E', [
          scan('selected', name: name, brand: BleDiscoveredDeviceBrand.eixam),
        ]);
        expect(lookup.state, TagPairingCodeMatchState.inspectionRequired);
        expect(
          TagPairingCodeCorrelator.verifyCurrent(
            lookup,
            status(mac: null),
          ).state,
          TagPairingCodeMatchState.identityUnverified,
        );
        expect(
          TagPairingCodeCorrelator.verifyCurrent(lookup, status()).state,
          TagPairingCodeMatchState.matched,
        );
        expect(
          TagPairingCodeCorrelator.verifyCurrent(
            lookup,
            status(id: 'other'),
          ).state,
          TagPairingCodeMatchState.identityMismatch,
        );
        expect(
          TagPairingCodeCorrelator.verifyCurrent(
            lookup,
            status(mac: 'E1:5F:27:D4:47:DB'),
          ).state,
          TagPairingCodeMatchState.identityMismatch,
        );
        expect(
          TagPairingCodeCorrelator.verifyCurrent(
            lookup,
            status(connected: false),
          ).state,
          TagPairingCodeMatchState.identityUnverified,
        );
      }
    },
  );

  test(
    'current canonical MAC supports renamed TAG and catches cross-brand collisions',
    () {
      final current = scan(
        'selected',
        name: 'Custom TAG',
        brand: BleDiscoveredDeviceBrand.eixam,
        mac: 'AA:BB:CC:93:75:6E',
      );
      final lookup = TagPairingCodeCorrelator.find('N693756E', [current]);
      expect(lookup.state, TagPairingCodeMatchState.inspectionRequired);
      expect(
        TagPairingCodeCorrelator.find('N693756E', [
          current,
          scan('legacy'),
        ]).state,
        TagPairingCodeMatchState.ambiguous,
      );
      expect(
        TagPairingCodeCorrelator.verifyLegacy(lookup, inspected()).state,
        TagPairingCodeMatchState.identityMismatch,
      );
    },
  );

  test(
    'ambiguous lookup cannot be promoted using an already-connected TAG',
    () {
      final lookup = TagPairingCodeCorrelator.find('N693756E', [
        scan('one'),
        scan('two'),
      ]);
      expect(
        TagPairingCodeCorrelator.verifyCurrent(lookup, status()).state,
        TagPairingCodeMatchState.ambiguous,
      );
      expect(
        TagPairingCodeCorrelator.verifyLegacy(lookup, inspected()).state,
        TagPairingCodeMatchState.ambiguous,
      );
    },
  );
}

EixamBleScanResult scan(
  String id, {
  String name = 'Meshtastic_756E',
  BleDiscoveredDeviceBrand brand = BleDiscoveredDeviceBrand.meshtastic,
  int rssi = -50,
  bool dfu = false,
  bool connectable = true,
  String? mac,
}) => EixamBleScanResult(
  deviceId: id,
  canonicalHardwareId: mac,
  name: name,
  rssi: rssi,
  connectable: connectable,
  brandClassification: brand,
  isEixamDevice: brand == BleDiscoveredDeviceBrand.eixam,
  discoveredAt: DateTime.utc(2026),
  isDfuBootloader: dfu,
);

DeviceMigrationCandidate inspected({
  String id = 'selected',
  String mac = 'AA:BB:CC:93:75:6E',
  DeviceMigrationIdentityKind kind = DeviceMigrationIdentityKind.hardwareMac,
  DeviceMigrationCompatibility compatibility =
      DeviceMigrationCompatibility.compatible,
}) => DeviceMigrationCandidate(
  deviceId: id,
  compatibility: compatibility,
  identityKind: kind,
  stableIdentity: mac,
  sourceNodeNumber: 0x0093756e,
  inspectedAt: DateTime.utc(2026),
);

DeviceStatus status({
  String id = 'selected',
  String? mac = 'AA:BB:CC:93:75:6E',
  bool connected = true,
}) => DeviceStatus(
  deviceId: id,
  canonicalHardwareId: mac,
  nodeId: 0x0093756e,
  paired: true,
  activated: true,
  connected: connected,
);

final class _ReadOnlySdk extends Fake implements EixamConnectSdk {
  _ReadOnlySdk(this.devices);
  List<EixamBleScanResult> devices;
  int scans = 0;
  int inspections = 0;
  @override
  Future<List<EixamBleScanResult>> scanBleDevices({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    scans++;
    return devices;
  }

  @override
  Future<DeviceMigrationCandidate> inspectDeviceMigrationCandidate({
    required String deviceId,
    String? advertisedName,
  }) async {
    inspections++;
    return inspected(id: deviceId);
  }
  // Fake throws on every acquisition/provisioning method: none are permitted.
}
