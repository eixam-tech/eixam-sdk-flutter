import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_client.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result_brand_classifier.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_metadata_probe.dart';
import 'package:eixam_connect_flutter/src/sdk/device_migration_coordinator.dart';
import 'package:eixam_connect_flutter/src/sdk/device_migration_firmware_service.dart';
import 'package:eixam_connect_flutter/src/sdk/device_migration_session_store.dart';
import 'package:flutter_test/flutter_test.dart';

const selectedId = 'AA:BB:CC:DD:EE:FF';

void main() {
  DeviceMigrationCoordinator build({
    required _FakeProbe probe,
    _FakeMigrationFirmwareService? firmware,
    _MigrationBleClient? ble,
    DeviceMigrationSessionStore? store,
  }) => DeviceMigrationCoordinator(
    bleClient: ble ?? _MigrationBleClient(),
    metadataProbe: probe,
    firmwareUpdates: firmware ?? _FakeMigrationFirmwareService(),
    sessionStore: store ?? _MemoryMigrationStore(),
    rediscoveryTimeout: const Duration(milliseconds: 1),
  );

  for (final model in [0, 9, 105]) {
    test(
      'service-identified stock TAG still requires model inspection: $model',
      () async {
        final brand = classifyBleDiscoveredDeviceBrand(
          name: '756E_756e',
          advertisedServiceUuids: [MeshtasticBleProtocol.serviceUuid],
        );
        expect(brand, BleDiscoveredDeviceBrand.meshtastic);
        final probe = _FakeProbe(_probe(model: model));
        final firmware = _FakeMigrationFirmwareService();
        final coordinator = build(probe: probe, firmware: firmware);
        final candidate = await coordinator.inspect(
          deviceId: selectedId,
          advertisedName: '756E_756e',
        );
        expect(probe.inspectedDeviceIds, [selectedId]);
        expect(
          candidate.compatibility,
          model == 105
              ? DeviceMigrationCompatibility.compatible
              : model == 0
              ? DeviceMigrationCompatibility.unableToVerify
              : DeviceMigrationCompatibility.unsupportedHardware,
        );
        if (model != 105) {
          final result = await coordinator.migrate(candidate);
          expect(result.outcome, DeviceMigrationOutcome.blocked);
        }
      },
    );
  }

  for (final failure in DeviceMigrationInspectionFailure.values) {
    test(
      'typed inspection failure ${failure.name} never evaluates compatibility',
      () async {
        final candidate = await build(
          probe: _FakeProbe.error(MeshtasticInspectionException(failure)),
        ).inspect(deviceId: selectedId);
        expect(
          candidate.compatibility,
          DeviceMigrationCompatibility.unableToVerify,
        );
        expect(candidate.inspectionFailure, failure);
        expect(candidate.detailCode, failure.name);
        expect(candidate.sourceHardwareModel, isNull);
      },
    );
  }

  test('trusted metadata model 105 is compatible', () async {
    final probe = _FakeProbe(_probe(model: 105));
    final candidate = await build(
      probe: probe,
    ).inspect(deviceId: selectedId, advertisedName: 'Meshtastic_EEFF');

    expect(candidate.compatibility, DeviceMigrationCompatibility.compatible);
    expect(candidate.sourceHardwareModel, 105);
    expect(candidate.sourceFirmwareVersion, '2.5.0');
    expect(candidate.stableIdentity, selectedId);
    expect(probe.inspectedDeviceIds, <String>[selectedId]);
  });

  test(
    'a disappeared selected device fails without substituting another id',
    () async {
      final probe = _FakeProbe.error(
        const MeshtasticDeviceUnavailableException(),
      );

      final candidate = await build(
        probe: probe,
      ).inspect(deviceId: selectedId, advertisedName: 'Meshtastic_EEFF');

      expect(
        candidate.compatibility,
        DeviceMigrationCompatibility.unableToVerify,
      );
      expect(candidate.deviceId, selectedId);
      expect(candidate.detailCode, 'selectedDeviceUnavailable');
      expect(probe.inspectedDeviceIds, <String>[selectedId]);
    },
  );

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
    expect(ble.connectedIds, isEmpty);
    expect(ble.disconnectedIds, <String>[selectedId]);
    // The normal pairing scan must see the verified TAG again.
    expect(await ble.scan(), hasLength(1));
  });

  test('failed GATT verification releases its temporary connection', () async {
    final ble = _MigrationBleClient(
      scans: <BleScanResult>[_eixamScan(selectedId, selectedId)],
      compatible: false,
    );
    final coordinator = build(probe: _FakeProbe(_probe(model: 105)), ble: ble);
    final candidate = await coordinator.inspect(deviceId: selectedId);

    final result = await coordinator.migrate(candidate);

    expect(result.outcome, DeviceMigrationOutcome.failed);
    expect(result.failureCode, 'postMigrationGattIncompatible');
    expect(ble.connectedIds, isEmpty);
    expect(ble.disconnectedIds, <String>[selectedId]);
    await coordinator.dispose();
    expect(ble.disconnectedIds, <String>[selectedId]);
    expect(await ble.scan(), hasLength(1));
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

  test('native failure without recovery evidence exposes retry', () async {
    final firmware = _FakeMigrationFirmwareService(
      forcedState: FirmwareUpdateState.failed,
      forcedNativeEngaged: true,
    );
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105)),
      firmware: firmware,
    );
    final candidate = await coordinator.inspect(deviceId: selectedId);

    final result = await coordinator.migrate(candidate);
    final session = await coordinator.getActiveSession();

    expect(result.outcome, DeviceMigrationOutcome.failed);
    expect(session?.nextAction, DeviceMigrationNextAction.retry);
    expect(session?.firmwareSession?.requiresRecovery, isFalse);
    expect(session?.canCancel, isFalse);
  });

  test('native recovery evidence exposes recover', () async {
    final firmware = _FakeMigrationFirmwareService(
      forcedState: FirmwareUpdateState.recoveryRequired,
      forcedNativeEngaged: true,
    );
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105)),
      firmware: firmware,
    );
    final candidate = await coordinator.inspect(deviceId: selectedId);

    final result = await coordinator.migrate(candidate);
    final session = await coordinator.getActiveSession();

    expect(result.outcome, DeviceMigrationOutcome.recoveryRequired);
    expect(session?.nextAction, DeviceMigrationNextAction.recover);
    expect(session?.firmwareSession?.requiresRecovery, isTrue);
  });

  test('active session restores across restart states', () async {
    for (final state in <DeviceMigrationState>[
      DeviceMigrationState.prepared,
      DeviceMigrationState.transferring,
      DeviceMigrationState.waitingForDevice,
      DeviceMigrationState.reconciling,
      DeviceMigrationState.recoveryRequired,
    ]) {
      final store = _MemoryMigrationStore()..value = _durableSession(state);
      final restored = await build(
        probe: _FakeProbe(_probe(model: 105)),
        store: store,
      ).getActiveSession();

      expect(restored?.state, state);
      expect(restored?.candidate.stableIdentity, selectedId);
    }
  });

  test('active migration cannot attach to another physical device', () async {
    final store = _MemoryMigrationStore()
      ..value = _durableSession(DeviceMigrationState.waitingForDevice);
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105, mac: '11:22:33:44:55:66')),
      store: store,
    );
    final other = DeviceMigrationCandidate(
      deviceId: 'other-id',
      compatibility: DeviceMigrationCompatibility.compatible,
      sourceHardwareModel: 105,
      stableIdentity: '11:22:33:44:55:66',
      identityKind: DeviceMigrationIdentityKind.hardwareMac,
      inspectedAt: DateTime.now(),
    );

    final result = await coordinator.migrate(other);

    expect(result.outcome, DeviceMigrationOutcome.blocked);
    expect(result.failureCode, 'migrationActiveForAnotherDevice');
    expect(store.value?.candidate.stableIdentity, selectedId);
  });

  test('standalone OTA cannot be overwritten by migration-owned OTA', () async {
    final now = DateTime.now();
    final firmware = _FakeMigrationFirmwareService(
      activeFirmware: FirmwareUpdateSession(
        sessionId: 'standalone-ota',
        deviceId: 'other-device',
        hardwareId: '11:22:33:44:55:66',
        releaseId: 'release-1',
        fromVersion: '1.0.0',
        targetVersion: '2.0.0',
        state: FirmwareUpdateState.reconnecting,
        startedAt: now,
      ),
    );
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105)),
      firmware: firmware,
    );
    final candidate = await coordinator.inspect(deviceId: selectedId);

    final result = await coordinator.migrate(candidate);

    expect(result.outcome, DeviceMigrationOutcome.blocked);
    expect(result.failureCode, 'firmwareUpdateActiveForAnotherDevice');
    expect(firmware.resolveCalls, 0);
  });

  test('restart finds original source and allows continuing', () async {
    final store = _MemoryMigrationStore()
      ..value = _durableSession(DeviceMigrationState.prepared);
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105)),
      store: store,
      ble: _MigrationBleClient(scans: <BleScanResult>[_sourceScan(selectedId)]),
    );

    final session = await coordinator.reconcile();

    expect(
      session?.reconciliationOutcome,
      DeviceMigrationReconciliationOutcome.originalSourceDeviceFound,
    );
    expect(session?.nextAction, DeviceMigrationNextAction.continueMigration);
    expect(session?.canCancel, isTrue);
  });

  test('restart verifies migrated identity and installed target', () async {
    final store = _MemoryMigrationStore()
      ..value = _durableSession(DeviceMigrationState.waitingForDevice);
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105)),
      store: store,
      ble: _MigrationBleClient(
        scans: <BleScanResult>[_eixamScan('changed-id', selectedId)],
      ),
    );

    final session = await coordinator.reconcile();

    expect(session?.state, DeviceMigrationState.completed);
    expect(session?.nextAction, DeviceMigrationNextAction.completed);
    expect(store.value, isNull);
  });

  test('ambiguous Eixam candidates are not guessed', () async {
    final store = _MemoryMigrationStore()
      ..value = _durableSession(DeviceMigrationState.waitingForDevice);
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105)),
      store: store,
      ble: _MigrationBleClient(
        scans: <BleScanResult>[
          _eixamScan('one', '11:22:33:44:55:66'),
          _eixamScan('two', '22:33:44:55:66:77'),
        ],
      ),
    );

    final session = await coordinator.reconcile();

    expect(
      session?.reconciliationOutcome,
      DeviceMigrationReconciliationOutcome.ambiguousCandidates,
    );
    expect(session?.nextAction, DeviceMigrationNextAction.reinspect);
  });

  test('unrelated single DFU device is not claimed', () async {
    final store = _MemoryMigrationStore()
      ..value = _durableSession(DeviceMigrationState.transferring);
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105)),
      store: store,
      ble: _MigrationBleClient(
        scans: <BleScanResult>[_dfuScan('unrelated', '11:22:33:44:55:66')],
      ),
    );

    final session = await coordinator.reconcile(attemptRecovery: true);

    expect(
      session?.reconciliationOutcome,
      DeviceMigrationReconciliationOutcome.deviceNotFound,
    );
    expect(session?.nextAction, DeviceMigrationNextAction.waitForDevice);
  });

  test('multiple unproven DFU candidates are ambiguous', () async {
    final store = _MemoryMigrationStore()
      ..value = _durableSession(DeviceMigrationState.transferring);
    final coordinator = build(
      probe: _FakeProbe(_probe(model: 105)),
      store: store,
      ble: _MigrationBleClient(
        scans: <BleScanResult>[
          _dfuScan('one', '11:22:33:44:55:66'),
          _dfuScan('two', '22:33:44:55:66:77'),
        ],
      ),
    );

    final session = await coordinator.reconcile();

    expect(
      session?.reconciliationOutcome,
      DeviceMigrationReconciliationOutcome.ambiguousCandidates,
    );
  });

  test(
    'matching DFU is recoverable and recovery still requires verification',
    () async {
      final store = _MemoryMigrationStore()
        ..value = _durableSession(DeviceMigrationState.recoveryRequired);
      final coordinator = build(
        probe: _FakeProbe(_probe(model: 105)),
        store: store,
        ble: _MigrationBleClient(
          scanBatches: <List<BleScanResult>>[
            <BleScanResult>[_dfuScan('bootloader', selectedId)],
            <BleScanResult>[_eixamScan('new-id', selectedId)],
          ],
        ),
      );

      final session = await coordinator.reconcile(attemptRecovery: true);

      expect(session?.state, DeviceMigrationState.completed);
      expect(session?.firmwareSession?.state, FirmwareUpdateState.completed);
      expect(session?.migratedDevice?.deviceId, 'new-id');
    },
  );
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

BleScanResult _sourceScan(String canonicalId) => BleScanResult(
  deviceId: canonicalId,
  canonicalHardwareId: canonicalId,
  name: 'Meshtastic_EEFF',
  rssi: -40,
  connectable: true,
  brandClassification: BleDiscoveredDeviceBrand.meshtastic,
  discoveredAt: DateTime.now(),
);

BleScanResult _dfuScan(String deviceId, String canonicalId) => BleScanResult(
  deviceId: deviceId,
  canonicalHardwareId: canonicalId,
  name: 'DfuTarg',
  rssi: -40,
  connectable: true,
  advertisedServiceUuids: const <String>['FE59'],
  discoveredAt: DateTime.now(),
);

DeviceMigrationSession _durableSession(DeviceMigrationState state) {
  final now = DateTime.utc(2026, 1, 1);
  return DeviceMigrationSession(
    sessionId: 'migration-1',
    schemaVersion: DeviceMigrationSession.currentSchemaVersion,
    candidate: DeviceMigrationCandidate(
      deviceId: selectedId,
      compatibility: DeviceMigrationCompatibility.compatible,
      sourceHardwareModel: 105,
      sourceFirmwareVersion: '2.5.0',
      stableIdentity: selectedId,
      identityKind: DeviceMigrationIdentityKind.hardwareMac,
      inspectedAt: now,
    ),
    releaseId: 'release-1',
    targetVersion: '3.0.0',
    state: state,
    nextAction: state == DeviceMigrationState.recoveryRequired
        ? DeviceMigrationNextAction.recover
        : DeviceMigrationNextAction.waitForDevice,
    canCancel: state == DeviceMigrationState.prepared,
    createdAt: now,
    updatedAt: now,
  );
}

final class _FakeProbe implements MeshtasticMetadataProbe {
  _FakeProbe(this.result) : error = null;
  _FakeProbe.error(this.error) : result = null;

  final MeshtasticProbeResult? result;
  final Object? error;
  int calls = 0;
  final List<String> inspectedDeviceIds = <String>[];

  @override
  Future<MeshtasticProbeResult> inspect(
    String deviceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    calls += 1;
    inspectedDeviceIds.add(deviceId);
    if (error != null) throw error!;
    return result!;
  }
}

final class _FakeMigrationFirmwareService
    implements DeviceMigrationFirmwareService {
  _FakeMigrationFirmwareService({
    this.forcedState,
    this.forcedNativeEngaged = false,
    this.activeFirmware,
  });

  final FirmwareUpdateState? forcedState;
  final bool forcedNativeEngaged;
  final FirmwareUpdateSession? activeFirmware;
  final StreamController<FirmwareUpdateProgress> _progress =
      StreamController<FirmwareUpdateProgress>.broadcast(sync: true);
  int resolveCalls = 0;

  @override
  Future<FirmwareUpdateSession?> getActiveMigrationFirmwareUpdate() async =>
      activeFirmware;

  @override
  Stream<FirmwareUpdateProgress> watchMigrationFirmwareProgress({
    required String deviceId,
  }) => _progress.stream.where((progress) => progress.deviceId == deviceId);

  @override
  Future<FirmwareUpdateSession> recoverMigrationFirmwareUpdate({
    required String bootloaderDeviceId,
    required String releaseId,
    required String targetVersion,
  }) async => FirmwareUpdateSession(
    sessionId: 'recovery-1',
    deviceId: bootloaderDeviceId,
    releaseId: releaseId,
    fromVersion: '',
    targetVersion: targetVersion,
    state: FirmwareUpdateState.completed,
    startedAt: DateTime.now(),
    completedAt: DateTime.now(),
  );

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
    final forced = forcedState;
    if (forced != null) {
      final requiresRecovery = forced == FirmwareUpdateState.recoveryRequired;
      final completedAt = DateTime.now();
      _progress.add(
        FirmwareUpdateProgress(
          sessionId: 'session-1',
          deviceId: sourceStatus.deviceId,
          state: forced,
          failureCode: requiresRecovery
              ? 'nativeRecoveryRequired'
              : 'nativeRejected',
          nativeTransferEngaged: forcedNativeEngaged,
          requiresRecovery: requiresRecovery,
          updatedAt: completedAt,
        ),
      );
      return FirmwareUpdateSession(
        sessionId: 'session-1',
        deviceId: sourceStatus.deviceId,
        releaseId: release.releaseId,
        fromVersion: sourceStatus.firmwareVersion ?? '',
        targetVersion: release.version,
        state: forced,
        startedAt: started,
        completedAt: completedAt,
        failureCode: requiresRecovery
            ? 'nativeRecoveryRequired'
            : 'nativeRejected',
        nativeTransferEngaged: forcedNativeEngaged,
        requiresRecovery: requiresRecovery,
      );
    }
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

final class _MemoryMigrationStore implements DeviceMigrationSessionStore {
  DeviceMigrationSession? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<DeviceMigrationSession?> load() async => value;

  @override
  Future<void> save(DeviceMigrationSession session) async => value = session;
}

final class _MigrationBleClient implements BleClient {
  _MigrationBleClient({
    this.scans = const <BleScanResult>[],
    this.scanBatches = const <List<BleScanResult>>[],
    this.firmwareVersion = '3.0.0',
    this.compatible = true,
  });

  final List<BleScanResult> scans;
  final List<List<BleScanResult>> scanBatches;
  final String firmwareVersion;
  final bool compatible;
  final List<String> compatibilityChecks = <String>[];
  int _scanIndex = 0;
  final Set<String> connectedIds = <String>{};
  final List<String> disconnectedIds = <String>[];

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (scanBatches.isEmpty) {
      return scans
          .where((scan) => !connectedIds.contains(scan.deviceId))
          .toList();
    }
    final index = _scanIndex.clamp(0, scanBatches.length - 1);
    _scanIndex += 1;
    return scanBatches[index];
  }

  @override
  Future<void> connect(String deviceId) async {
    connectedIds.add(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    connectedIds.remove(deviceId);
    disconnectedIds.add(deviceId);
  }

  @override
  Future<bool> isEixamCompatible(String deviceId) async {
    compatibilityChecks.add(deviceId);
    return compatible;
  }

  @override
  Future<String?> readFirmwareVersion(String deviceId) async => firmwareVersion;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
