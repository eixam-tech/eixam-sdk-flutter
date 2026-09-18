import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_client.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_metadata_probe.dart';
import 'package:eixam_connect_flutter/src/sdk/device_migration_coordinator.dart';
import 'package:eixam_connect_flutter/src/sdk/device_migration_firmware_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const selectedId = 'AA:BB:CC:DD:EE:FF';

  DeviceMigrationCoordinator build({
    required _FakeProbe probe,
    _FakeMigrationFirmwareService? firmware,
    _MigrationBleClient? ble,
  }) => DeviceMigrationCoordinator(
    bleClient: ble ?? _MigrationBleClient(),
    metadataProbe: probe,
    firmwareUpdates: firmware ?? _FakeMigrationFirmwareService(),
    rediscoveryTimeout: const Duration(milliseconds: 1),
  );

  test('trusted metadata model 105 is compatible', () async {
    final candidate = await build(
      probe: _FakeProbe(_probe(model: 105)),
    ).inspect(deviceId: selectedId, advertisedName: 'Meshtastic_EEFF');

    expect(candidate.compatibility, DeviceMigrationCompatibility.compatible);
    expect(candidate.sourceHardwareModel, 105);
    expect(candidate.sourceFirmwareVersion, '2.5.0');
    expect(candidate.stableIdentity, selectedId);
  });

  for (final entry in <(int, String)>[(9, 'RAK4631'), (84, 'WISMESH_TAP')]) {
    test('${entry.$2} model ${entry.$1} is unsupported', () async {
      final candidate = await build(
        probe: _FakeProbe(_probe(model: entry.$1)),
      ).inspect(deviceId: selectedId);

      expect(
        candidate.compatibility,
        DeviceMigrationCompatibility.unsupportedHardware,
      );
    });
  }

  test('unset model is unable to verify', () async {
    final candidate = await build(
      probe: _FakeProbe(_probe(model: 0)),
    ).inspect(deviceId: selectedId);

    expect(
      candidate.compatibility,
      DeviceMigrationCompatibility.unableToVerify,
    );
  });

  for (final name in <String>[
    'missing metadata',
    'malformed metadata',
    'timeout',
    'unrelated BLE device',
  ]) {
    test('$name is unable to verify', () async {
      final candidate = await build(
        probe: _FakeProbe.error(FormatException(name)),
      ).inspect(deviceId: selectedId);

      expect(
        candidate.compatibility,
        DeviceMigrationCompatibility.unableToVerify,
      );
    });
  }

  test('migration cannot start from an unverified candidate', () async {
    final firmware = _FakeMigrationFirmwareService();
    final result =
        await build(
          probe: _FakeProbe(_probe(model: 105)),
          firmware: firmware,
        ).migrate(
          DeviceMigrationCandidate(
            deviceId: selectedId,
            compatibility: DeviceMigrationCompatibility.unableToVerify,
            identityKind: DeviceMigrationIdentityKind.none,
            inspectedAt: DateTime.now(),
          ),
        );

    expect(result.outcome, DeviceMigrationOutcome.blocked);
    expect(firmware.resolveCalls, 0);
  });

  test('candidate is revalidated immediately before migration', () async {
    final probe = _FakeProbe(_probe(model: 105));
    final coordinator = build(probe: probe);
    final candidate = await coordinator.inspect(deviceId: selectedId);

    await coordinator.migrate(candidate);

    expect(probe.calls, 2);
  });

  test('successful DFU returns strongly correlated Eixam device', () async {
    final ble = _MigrationBleClient(
      scans: <BleScanResult>[_eixamScan(selectedId, selectedId)],
    );
    final coordinator = build(probe: _FakeProbe(_probe(model: 105)), ble: ble);
    final candidate = await coordinator.inspect(deviceId: selectedId);

    final result = await coordinator.migrate(candidate);

    expect(result.outcome, DeviceMigrationOutcome.completed);
    expect(result.migratedDevice?.deviceId, selectedId);
    expect(ble.compatibilityChecks, <String>[selectedId]);
  });

  test(
    'multiple Eixam devices are never selected without correlation',
    () async {
      const iosId = 'A56EA17E-21B0-4F9B-9899-123456789ABC';
      final ble = _MigrationBleClient(
        scans: <BleScanResult>[
          _eixamScan('one', '11:22:33:44:55:66'),
          _eixamScan('two', '22:33:44:55:66:77'),
        ],
      );
      final coordinator = build(
        probe: _FakeProbe(_probe(model: 105, node: 1234)),
        ble: ble,
      );
      final candidate = await coordinator.inspect(deviceId: iosId);

      final result = await coordinator.migrate(candidate);

      expect(
        result.outcome,
        DeviceMigrationOutcome.ambiguousPostMigrationDevice,
      );
      expect(ble.compatibilityChecks, isEmpty);
    },
  );

  test(
    'changed platform ID correlates through the captured hardware MAC',
    () async {
      const iosId = 'A56EA17E-21B0-4F9B-9899-123456789ABC';
      const mac = 'AA:BB:CC:DD:EE:FF';
      final ble = _MigrationBleClient(
        scans: <BleScanResult>[_eixamScan('new-platform-id', mac)],
      );
      final coordinator = build(
        probe: _FakeProbe(_probe(model: 105, mac: mac)),
        ble: ble,
      );
      final candidate = await coordinator.inspect(deviceId: iosId);

      final result = await coordinator.migrate(candidate);

      expect(result.outcome, DeviceMigrationOutcome.completed);
      expect(result.migratedDevice?.deviceId, 'new-platform-id');
    },
  );

  test('target firmware mismatch fails migration', () async {
    final ble = _MigrationBleClient(
      scans: <BleScanResult>[_eixamScan(selectedId, selectedId)],
      firmwareVersion: '1.0.0',
    );
    final coordinator = build(probe: _FakeProbe(_probe(model: 105)), ble: ble);
    final candidate = await coordinator.inspect(deviceId: selectedId);

    final result = await coordinator.migrate(candidate);

    expect(result.outcome, DeviceMigrationOutcome.failed);
    expect(result.failureCode, 'installedVersionMismatch');
  });
}

MeshtasticProbeResult _probe({required int model, int? node, String? mac}) =>
    MeshtasticProbeResult(
      hardwareModel: model,
      firmwareVersion: '2.5.0',
      nodeNumber: node,
      hardwareMac: mac,
      batteryPercentage: 80,
    );

BleScanResult _eixamScan(String deviceId, String canonicalId) => BleScanResult(
  deviceId: deviceId,
  canonicalHardwareId: canonicalId,
  name: 'EIXAM_AABBCCDD',
  rssi: -40,
  connectable: true,
  advertisedServiceUuids: const <String>[EixamBleProtocol.serviceUuid],
  brandClassification: BleDiscoveredDeviceBrand.eixam,
  discoveredAt: DateTime.now(),
);

final class _FakeProbe implements MeshtasticMetadataProbe {
  _FakeProbe(this.result) : error = null;
  _FakeProbe.error(this.error) : result = null;

  final MeshtasticProbeResult? result;
  final Object? error;
  int calls = 0;

  @override
  Future<MeshtasticProbeResult> inspect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    calls += 1;
    if (error != null) throw error!;
    return result!;
  }
}

final class _FakeMigrationFirmwareService
    implements DeviceMigrationFirmwareService {
  int resolveCalls = 0;

  @override
  Future<FirmwareRelease?> resolveMigrationRelease({
    required String hardwareModel,
  }) async {
    resolveCalls += 1;
    return const FirmwareRelease(
      releaseId: 'release-1',
      version: '3.0.0',
      hardwareModel: 'EIXAM R1',
      sha256Hash: 'hash',
      fileSizeBytes: 100,
    );
  }

  @override
  Future<FirmwareUpdateSession> startMigrationFirmwareUpdate({
    required DeviceStatus sourceStatus,
    required FirmwareRelease release,
    required FirmwareDfuStatusRefreshHook postMigrationStatusRefresh,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) async {
    final started = DateTime.now();
    try {
      final status = await postMigrationStatusRefresh(
        deviceId: sourceStatus.deviceId,
        attempt: 1,
        targetVersion: release.version,
      );
      final matches =
          status.connected && status.firmwareVersion == release.version;
      return FirmwareUpdateSession(
        sessionId: 'session-1',
        deviceId: sourceStatus.deviceId,
        releaseId: release.releaseId,
        fromVersion: sourceStatus.firmwareVersion ?? '',
        targetVersion: release.version,
        state: matches
            ? FirmwareUpdateState.completed
            : FirmwareUpdateState.failed,
        startedAt: started,
        completedAt: DateTime.now(),
        failureCode: matches ? null : 'installedVersionMismatch',
      );
    } on FirmwareUpdateException catch (error) {
      return FirmwareUpdateSession(
        sessionId: 'session-1',
        deviceId: sourceStatus.deviceId,
        releaseId: release.releaseId,
        fromVersion: sourceStatus.firmwareVersion ?? '',
        targetVersion: release.version,
        state: FirmwareUpdateState.failed,
        startedAt: started,
        completedAt: DateTime.now(),
        failureCode: error.code,
        failureMessage: error.message,
      );
    }
  }
}

final class _MigrationBleClient implements BleClient {
  _MigrationBleClient({
    this.scans = const <BleScanResult>[],
    this.firmwareVersion = '3.0.0',
  });

  final List<BleScanResult> scans;
  final String firmwareVersion;
  final List<String> compatibilityChecks = <String>[];

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async => scans;

  @override
  Future<void> connect(String deviceId) async {}

  @override
  Future<bool> isEixamCompatible(String deviceId) async {
    compatibilityChecks.add(deviceId);
    return true;
  }

  @override
  Future<String?> readFirmwareVersion(String deviceId) async => firmwareVersion;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
