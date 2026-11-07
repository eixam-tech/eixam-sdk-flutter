import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_firmware_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/device/ble_adapter_state.dart';
import 'package:eixam_connect_flutter/src/device/ble_client.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/public/enums/discovered_device_brand.dart';
import 'package:eixam_connect_flutter/src/sdk/dfu_preflight.dart';
import 'package:eixam_connect_flutter/src/sdk/dfu_recovery_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/dfu_recovery_record_store.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_dfu_transport.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_update_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/sdk_contract_fakes.dart';

const _hw = 'AA:BB:CC:DD:EE:FF';
const _id = 'tag-1';

FirmwareUpdateSession _interrupted({
  FirmwareUpdateState state = FirmwareUpdateState.recoveryRequired,
}) => FirmwareUpdateSession(
  sessionId: 'session-1',
  deviceId: _id,
  hardwareId: _hw,
  releaseId: 'release-1',
  fromVersion: '2.0.0',
  targetVersion: '3.0.0',
  state: state,
  startedAt: DateTime.utc(2026, 1, 1),
  nativeTransferEngaged: true,
  requiresRecovery: true,
  nextAction: FirmwareUpdateNextAction.waitForDevice,
);

BleScanResult _scan(
  List<String> services, {
  String id = _id,
  String? hw = _hw,
  String name = 'x',
  BleDiscoveredDeviceBrand brand = BleDiscoveredDeviceBrand.unknown,
  DateTime? at,
}) => BleScanResult(
  deviceId: id,
  canonicalHardwareId: hw,
  name: name,
  rssi: -50,
  connectable: true,
  advertisedServiceUuids: services,
  brandClassification: brand,
  discoveredAt: at ?? DateTime.utc(2026, 1, 1),
);

BleScanResult _adaDfu({String id = _id, String? hw = _hw, DateTime? at}) =>
    _scan(
      const ['00001530-1212-efde-1523-785feabcd123'],
      id: id,
      hw: hw,
      at: at,
    );

BleScanResult _eixamApp() => _scan(
  const [EixamBleProtocol.serviceUuid],
  name: 'EIXAM_AABBCCDD',
  brand: BleDiscoveredDeviceBrand.eixam,
);

BleScanResult _stock() => _scan(const [MeshtasticBleProtocol.serviceUuid]);

class _NoRemote implements SdkFirmwareRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Ble implements BleClient, BleAdvertisementSightingSource {
  List<BleScanResult> scans = <BleScanResult>[];
  BleAdapterState adapter = BleAdapterState.poweredOn;
  int scanCalls = 0;
  Object? scanError;

  /// Per-call results of our own scan; consumed first, then [scans].
  final List<List<BleScanResult>> script = <List<BleScanResult>>[];

  /// Latest adverts any scan (watcher, discovery, ours) received.
  List<BleScanResult> sightings = <BleScanResult>[];

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    scanCalls++;
    if (scanError != null) throw scanError!;
    if (script.isNotEmpty) return script.removeAt(0);
    return List<BleScanResult>.of(scans);
  }

  @override
  List<BleScanResult> advertisementsSince(DateTime since) => sightings
      .where((scan) => !scan.discoveredAt.isBefore(since))
      .toList(growable: false);

  @override
  Future<BleAdapterState> getAdapterState() async => adapter;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Firmware extends FirmwareUpdateCoordinator {
  _Firmware(this.session)
    : super(
        deviceRepository: FakeDeviceRepository(
          initialStatus: buildDeviceStatus(),
        ),
        sosRepository: FakeSosRepository(),
        deathManRepository: FakeDeathManRepository(),
        remoteDataSource: _NoRemote(),
        dfuTransport: const UnsupportedFirmwareDfuTransport(),
      );

  FirmwareUpdateSession? session;
  bool busy = false;
  int starts = 0;
  int physicalCalls = 0;
  final List<String> superseded = <String>[];
  final List<String> startedOn = <String>[];
  Completer<void>? startGate;

  /// What a started recovery DFU does. Default: Start then library Reset.
  FirmwareUpdateSession Function(FirmwareUpdateSession interrupted) onStart =
      (interrupted) => interrupted.copyWith(
        state: FirmwareUpdateState.recoveryRequired,
        remoteRecoveryAttempts: interrupted.remoteRecoveryAttempts + 1,
        remoteRecoveryFailed: true,
      );
  FirmwareUpdateSession? Function() onReconcile = () => null;

  /// What the connected TAG reports (null = not connected / no app version).
  ({String version, bool isOldApplication})? connectedRead;
  int connectedReads = 0;
  final StreamController<FirmwareUpdateProgress> progress =
      StreamController<FirmwareUpdateProgress>.broadcast();

  @override
  bool get operationInProgress => busy;

  @override
  Future<FirmwareUpdateSession?> getActiveFirmwareUpdate() async => session;

  @override
  Stream<FirmwareUpdateProgress> watchProgress({String? deviceId}) =>
      progress.stream;

  // Test-lifetime stream.
  // ignore: close_sinks
  final StreamController<FirmwareUpdateSession> sessions =
      StreamController<FirmwareUpdateSession>.broadcast();

  @override
  Stream<FirmwareUpdateSession> watchFirmwareUpdate() => sessions.stream;

  @override
  Future<FirmwareUpdateSession> startBootloaderRecoveryDfu({
    required String bootloaderDeviceId,
    required FirmwareUpdateSession interrupted,
  }) async {
    starts++;
    startedOn.add(bootloaderDeviceId);
    await startGate?.future;
    final result = onStart(interrupted);
    session = result;
    return result;
  }

  @override
  Future<FirmwareUpdateSession?> requirePhysicalRecovery() async {
    physicalCalls++;
    return session;
  }

  @override
  Future<({String version, bool isOldApplication})?>
  readConnectedApplicationVersion() async {
    connectedReads++;
    return connectedRead;
  }

  @override
  Future<void> supersedeInterruptedFirmwareUpdate(String sessionId) async {
    superseded.add(sessionId);
    session = null;
  }

  @override
  Future<FirmwareUpdateSession?> reconcileFirmwareUpdate({
    bool attemptRecovery = false,
  }) async => onReconcile();
}

class _Harness {
  _Harness({
    this.restartCapable = const <String>{},
    this.bootloaderVersion,
    this.ios = false,
    this.phone = const PhoneBatteryReading(percent: 80, charging: false),
    this.tagBattery,
    this.stockModel = 105,
    this.stockIdentity = _hw,
    FirmwareUpdateSession? session,
  }) : firmware = _Firmware(session ?? _interrupted()) {
    ble.scans = [_adaDfu()];
    controller = DfuRecoveryController(
      firmware: firmware,
      bleClient: ble,
      recordStore: store,
      inspectStock: (deviceId, name) async => DeviceMigrationCandidate(
        deviceId: deviceId,
        compatibility: stockModel == 105
            ? DeviceMigrationCompatibility.compatible
            : DeviceMigrationCompatibility.unsupportedHardware,
        identityKind: DeviceMigrationIdentityKind.hardwareMac,
        sourceHardwareModel: stockModel,
        stableIdentity: stockIdentity,
        inspectedAt: DateTime.utc(2026, 1, 1),
      ),
      isOtherOperationInProgress: () => otherOperation,
      isIosPlatform: () => ios,
      reconnectAfterForget: (scan) async {
        reconnects.add(scan.deviceId);
        return true;
      },
      knownDeviceBatteryPercent: () async => tagBattery,
      phoneBattery: () async => phone,
      bootloaderVersionReader: (deviceId) async {
        versionReads++;
        if (bootloaderVersion == 'throw') throw StateError('x');
        return bootloaderVersion;
      },
      restartCapableBootloaders: restartCapable,
      clock: () => now,
      delay: (d) async => now = now.add(d),
    );
  }

  final Set<String> restartCapable;
  final String? bootloaderVersion;
  final bool ios;
  final PhoneBatteryReading? phone;
  final int? tagBattery;
  final int stockModel;
  final String stockIdentity;
  final _Firmware firmware;
  final _Ble ble = _Ble();
  final InMemoryDfuRecoveryRecordStore store = InMemoryDfuRecoveryRecordStore();
  late final DfuRecoveryController controller;
  DateTime now = DateTime.utc(2026, 1, 1, 12);
  bool otherOperation = false;
  int versionReads = 0;
  final List<String> reconnects = <String>[];
}

Future<void> expectRefused(
  Future<Object?> action,
  DfuPreflightFailure failure,
) => expectLater(
  action,
  throwsA(
    isA<DfuRecoveryException>().having((e) => e.failure, 'failure', failure),
  ),
);

void main() {
  group('state observation', () {
    test('no interrupted update: unknown and no scan is made', () async {
      final h = _Harness();
      h.firmware.session = null;
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.unknown);
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.ble.scanCalls, 0);
    });

    test(
      'E1: interrupted + bootloader visible -> resumable, cable action',
      () async {
        final h = _Harness();
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, DfuRecoveryState.resumable);
        expect(status.availableAction, DfuRecoveryAction.prepareCableRecovery);
        expect(status.needsCable, isTrue);
        expect(status.deviceId, _id);
        expect(
          h.versionReads,
          0,
          reason: 'empty allowlist never touches the TAG',
        );
        expect(h.firmware.starts, 0, reason: 'observation never starts a DFU');
      },
    );

    test('silence: awaiting, then silentNeedsCable after the window', () async {
      final h = _Harness();
      h.ble.scans = [];
      var status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.unknown);
      expect(status.reason, DfuRecoveryReason.awaitingEvidence);
      h.now = h.now.add(const Duration(minutes: 3));
      status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.silentNeedsCable);
      expect(status.reason, DfuRecoveryReason.deviceSilent);
      expect(status.needsCable, isTrue);
      expect(h.firmware.physicalCalls, greaterThan(0));
    });

    test('a sighting resets the silence window', () async {
      final h = _Harness();
      h.ble.scans = [];
      await h.controller.getDfuRecoveryStatus();
      h.now = h.now.add(const Duration(minutes: 1));
      h.ble.scans = [_adaDfu()];
      await h.controller.getDfuRecoveryStatus();
      h.now = h.now.add(const Duration(minutes: 3));
      h.ble.scans = [];
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.unknown);
    });

    test('scan failure is not silence', () async {
      final h = _Harness();
      h.ble.scanError = StateError('scan failed');
      h.now = h.now.add(const Duration(hours: 1));
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.unknown);
    });

    test('another device is not our TAG', () async {
      final h = _Harness();
      h.ble.scans = [_adaDfu(id: 'other', hw: '11:22:33:44:55:66')];
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.unknown);
    });

    test('two bootloaders are ambiguous', () async {
      final h = _Harness();
      h.ble.scans = [_adaDfu(), _adaDfu(id: 'other', hw: '11:22:33:44:55:66')];
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.unknown);
      expect(status.reason, DfuRecoveryReason.awaitingEvidence);
    });

    test('operation in progress is reported, not classified', () async {
      final h = _Harness();
      h.firmware.busy = true;
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.updateInProgress);
      expect(h.ble.scanCalls, 0);
    });

    test(
      'app-mode TAG back: recovered only when reconcile verified it',
      () async {
        final h = _Harness();
        h.ble.scans = [_eixamApp()];
        h.firmware.onReconcile = () =>
            _interrupted(state: FirmwareUpdateState.reconnecting);
        var status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, isNot(DfuRecoveryState.recovered));
        h.firmware.onReconcile = () {
          final done = _interrupted(state: FirmwareUpdateState.completed);
          h.firmware.session = null;
          return done;
        };
        status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, DfuRecoveryState.recovered);
        expect(status.reason, DfuRecoveryReason.versionVerified);
        // The latch survives the cleared firmware record until dismissed.
        status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, DfuRecoveryState.recovered);
        status = await h.controller.dismissDfuRecovery();
        expect(status.state, DfuRecoveryState.unknown);
      },
    );

    test(
      'stock hardware model 105 with same identity supersedes the record',
      () async {
        final h = _Harness();
        h.ble.scans = [_stock()];
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.reason, DfuRecoveryReason.physicalRecoveryCompleted);
        expect(h.firmware.superseded, ['session-1']);
      },
    );

    for (final scenario in <({String name, int model, String identity})>[
      (name: 'wrong hardware model', model: 9, identity: _hw),
      (name: 'identity mismatch', model: 105, identity: '11:22:33:44:55:66'),
    ]) {
      test('stock stays fail-closed: ${scenario.name}', () async {
        final h = _Harness(
          stockModel: scenario.model,
          stockIdentity: scenario.identity,
        );
        h.ble.scans = [_stock()];
        final status = await h.controller.getDfuRecoveryStatus();
        expect(
          status.reason,
          isNot(DfuRecoveryReason.physicalRecoveryCompleted),
        );
        expect(h.firmware.superseded, isEmpty);
      });
    }

    test('watch emits the initial status and changes only', () async {
      final h = _Harness();
      final seen = <DfuRecoveryState>[];
      final sub = h.controller.watchDfuRecovery().listen(
        (s) => seen.add(s.state),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(seen, [DfuRecoveryState.resumable]);
      h.ble.scans = [];
      h.now = h.now.add(const Duration(minutes: 5));
      await h.controller.getDfuRecoveryStatus(); // first miss
      h.now = h.now.add(const Duration(minutes: 5));
      final last = await h.controller.getDfuRecoveryStatus();
      expect(last.state, DfuRecoveryState.silentNeedsCable);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [
        DfuRecoveryState.resumable,
        DfuRecoveryState.unknown,
        DfuRecoveryState.silentNeedsCable,
      ]);
      await sub.cancel();
      await h.controller.dispose();
    });
  });

  group('recovered after cable recovery + migration (F2)', () {
    FirmwareUpdateSession migrationSession({
      String? hw = _hw,
      String id = _id,
      FirmwareUpdateState state = FirmwareUpdateState.completed,
    }) => FirmwareUpdateSession(
      sessionId: 'migration-firmware-1',
      deviceId: id,
      hardwareId: hw,
      releaseId: 'release-2',
      fromVersion: '2.7.26',
      targetVersion: '3.0.0',
      state: state,
      startedAt: DateTime.utc(2026, 1, 1),
      nativeTransferEngaged: true,
      migrationOwned: true,
      nextAction: state == FirmwareUpdateState.completed
          ? FirmwareUpdateNextAction.completed
          : FirmwareUpdateNextAction.waitForDevice,
    );

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 10));

    test('F19: "not now" hides the card for this run only; a dismissal '
        'persisted by an earlier run never hides an interrupted TAG', () async {
      final h = _Harness();
      expect(
        (await h.controller.getDfuRecoveryStatus()).state,
        DfuRecoveryState.resumable,
      );
      var status = await h.controller.dismissDfuRecovery();
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(
        (await h.controller.getDfuRecoveryStatus()).reason,
        DfuRecoveryReason.noInterruptedUpdate,
      );
      final dismissedId = h.store.record.dismissedSessionId;
      expect(dismissedId, isNotNull);
      await h.controller.dispose();

      // Relaunch: same persisted record (dismissed), TAG still AdaDFU.
      final relaunch = _Harness();
      relaunch.store.record = h.store.record;
      status = await relaunch.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.resumable);
      expect(status.availableAction, DfuRecoveryAction.prepareCableRecovery);
      expect(
        status.forwardActions,
        contains(DfuRecoveryAction.openCableRecoveryGuide),
      );
      await relaunch.controller.dispose();
    });

    test('E2 -> stock superseded -> migration verified: recovered, then '
        'dismiss clears it', () async {
      final h = _Harness();
      final seen = <DfuRecoveryStatus>[];
      final sub = h.controller.watchDfuRecovery().listen(seen.add);
      await settle();
      expect(seen.last.state, DfuRecoveryState.resumable);
      expect(h.store.record.interruptedAt, isNotNull);
      // UF2 restore: TAG back as stock, the controller supersedes the record.
      h.ble.scans = [_stock()];
      h.now = h.now.add(const Duration(minutes: 1));
      var status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.physicalRecoveryCompleted);
      expect(h.store.record.deviceId, _id);
      expect(h.store.record.hardwareId, _hw);
      status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      // A migration session that is not finished yet changes nothing.
      h.firmware.sessions.add(
        migrationSession(state: FirmwareUpdateState.verifyingInstalledVersion),
      );
      await settle();
      expect(seen.last.state, isNot(DfuRecoveryState.recovered));
      // Migration installs EIXAM and verifies the version.
      h.firmware.sessions.add(migrationSession());
      await settle();
      expect(seen.last.state, DfuRecoveryState.recovered);
      expect(seen.last.reason, DfuRecoveryReason.versionVerified);
      expect(h.firmware.starts, 0, reason: 'nothing is started');
      status = await h.controller.dismissDfuRecovery();
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.store.record.interruptedAt, isNull);
      await sub.cancel();
      await h.controller.dispose();
    });

    test(
      'migration supersedes the record itself (controller never saw '
      'stock): the marker survives the new session and still latches',
      () async {
        final h = _Harness();
        final seen = <DfuRecoveryStatus>[];
        final sub = h.controller.watchDfuRecovery().listen(seen.add);
        await settle();
        expect(h.store.record.interruptedAt, isNotNull);
        // The migration superseded the interrupted session and now owns a new
        // engaged session on the same TAG (between its BLE phases).
        h.firmware.session = migrationSession(
          state: FirmwareUpdateState.reconnecting,
        );
        h.ble.scans = [];
        await h.controller.getDfuRecoveryStatus();
        expect(h.store.record.sessionId, 'migration-firmware-1');
        expect(h.store.record.interruptedAt, isNotNull);
        h.firmware.session = null;
        h.firmware.sessions.add(migrationSession());
        await settle();
        expect(seen.last.state, DfuRecoveryState.recovered);
        await sub.cancel();
        await h.controller.dispose();
      },
    );

    test(
      'an ordinary update that completes is never reported as recovered',
      () async {
        final h = _Harness();
        h.firmware.busy = true; // a normal OTA is running
        final seen = <DfuRecoveryStatus>[];
        final sub = h.controller.watchDfuRecovery().listen(seen.add);
        await settle();
        expect(seen.last.reason, DfuRecoveryReason.updateInProgress);
        expect(h.store.record.interruptedAt, isNull);
        h.firmware.busy = false;
        h.firmware.session = null;
        h.firmware.sessions.add(
          _interrupted(state: FirmwareUpdateState.completed),
        );
        await settle();
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, isNot(DfuRecoveryState.recovered));
        expect(
          seen.map((s) => s.state),
          isNot(contains(DfuRecoveryState.recovered)),
        );
        await sub.cancel();
        await h.controller.dispose();
      },
    );

    test('a verified install on another TAG is not this recovery', () async {
      final h = _Harness();
      final sub = h.controller.watchDfuRecovery().listen((_) {});
      await settle();
      h.ble.scans = [_stock()];
      h.now = h.now.add(const Duration(minutes: 1));
      await h.controller.getDfuRecoveryStatus();
      h.firmware.sessions.add(
        migrationSession(id: 'other', hw: '11:22:33:44:55:66'),
      );
      await settle();
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, isNot(DfuRecoveryState.recovered));
      await sub.cancel();
      await h.controller.dispose();
    });
  });

  group('strategy per bootloader version', () {
    test('0.4.3 -> cable even with an allowlist configured', () async {
      final h = _Harness(
        restartCapable: const {'9.9.9'},
        bootloaderVersion: '0.4.3 s140 6.1.1',
      );
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.availableAction, DfuRecoveryAction.prepareCableRecovery);
      expect(h.versionReads, 1);
    });

    test('proven bootloader -> restart offered, cable refused', () async {
      final h = _Harness(
        restartCapable: const {'9.9.9'},
        bootloaderVersion: '9.9.9 s140 6.1.1',
      );
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.resumable);
      expect(status.availableAction, DfuRecoveryAction.restartDfuFromScratch);
      expect(status.needsCable, isFalse);
      await expectRefused(
        h.controller.prepareCableRecovery(),
        DfuPreflightFailure.actionNotAvailable,
      );
      expect(h.firmware.starts, 0);
    });

    test('unreadable or failing version reader falls back to cable', () async {
      for (final version in <String?>[null, 'throw']) {
        final h = _Harness(
          restartCapable: const {'9.9.9'},
          bootloaderVersion: version,
        );
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.availableAction, DfuRecoveryAction.prepareCableRecovery);
      }
    });

    test('cable strategy refuses restartDfuFromScratch', () async {
      final h = _Harness();
      await expectRefused(
        h.controller.restartDfuFromScratch(),
        DfuPreflightFailure.actionNotAvailable,
      );
      expect(h.firmware.starts, 0);
    });
  });

  group('prepareCableRecovery', () {
    test(
      'one tap: one DFU session, ends silentNeedsCable + physical recovery',
      () async {
        final h = _Harness();
        // After the library Reset the TAG leaves the air.
        h.firmware.onStart = (interrupted) {
          h.ble.scans = [];
          return interrupted.copyWith(
            remoteRecoveryAttempts: interrupted.remoteRecoveryAttempts + 1,
            remoteRecoveryFailed: true,
          );
        };
        final status = await h.controller.prepareCableRecovery();
        expect(h.firmware.starts, 1);
        expect(h.firmware.startedOn, [_id]);
        expect(status.state, DfuRecoveryState.silentNeedsCable);
        expect(status.reason, DfuRecoveryReason.cableRecoveryPrepared);
        expect(status.needsCable, isTrue);
        expect(h.firmware.physicalCalls, greaterThan(0));
      },
    );

    test(
      'TAG still on the air after the run is not claimed as cable',
      () async {
        final h = _Harness();
        final status = await h.controller.prepareCableRecovery();
        expect(status.state, DfuRecoveryState.resumable);
        expect(h.firmware.physicalCalls, 0);
      },
    );

    test('no double trigger: a second concurrent tap is refused', () async {
      final h = _Harness();
      h.firmware.startGate = Completer<void>();
      final first = h.controller.prepareCableRecovery();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await expectRefused(
        h.controller.prepareCableRecovery(),
        DfuPreflightFailure.operationInProgress,
      );
      h.firmware.startGate!.complete();
      await first;
      expect(h.firmware.starts, 1);
    });

    test('not offered outside E1 (silent TAG, nothing interrupted)', () async {
      final silent = _Harness();
      silent.ble.scans = [];
      await expectRefused(
        silent.controller.prepareCableRecovery(),
        DfuPreflightFailure.actionNotAvailable,
      );
      final none = _Harness();
      none.firmware.session = null;
      await expectRefused(
        none.controller.prepareCableRecovery(),
        DfuPreflightFailure.noInterruptedUpdate,
      );
      expect(silent.firmware.starts + none.firmware.starts, 0);
    });

    test('progress is reported while the DFU runs', () async {
      final h = _Harness();
      h.firmware.startGate = Completer<void>();
      final seen = <double?>[];
      final sub = h.controller.watchDfuRecovery().listen(
        (s) => seen.add(s.progressFraction),
      );
      final run = h.controller.prepareCableRecovery();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      h.firmware.progress.add(
        FirmwareUpdateProgress(
          sessionId: 'session-1',
          deviceId: _id,
          state: FirmwareUpdateState.transferring,
          progressPercentage: 40,
          updatedAt: DateTime.now(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen, contains(0.4));
      h.firmware.startGate!.complete();
      await run;
      await sub.cancel();
      await h.controller.dispose();
    });
  });

  group('F13: tap-time scan superseded by another scan', () {
    FirmwareUpdateSession resetLeavesAir(_Harness h, FirmwareUpdateSession i) {
      h.ble.scans = [];
      return i.copyWith(
        remoteRecoveryAttempts: i.remoteRecoveryAttempts + 1,
        remoteRecoveryFailed: true,
      );
    }

    test(
      'AdaDFU seen 10 s ago by another scan (ours superseded, returns []): '
      'accepted without a fresh scan; that pre-run sighting never undoes E2',
      () async {
        final h = _Harness();
        h.ble.scans = [];
        h.ble.sightings = [
          _adaDfu(at: h.now.subtract(const Duration(seconds: 10))),
        ];
        var scansAtStart = -1;
        h.firmware.onStart = (interrupted) {
          scansAtStart = h.ble.scanCalls;
          return resetLeavesAir(h, interrupted);
        };
        final status = await h.controller.prepareCableRecovery();
        expect(h.firmware.starts, 1);
        expect(h.firmware.startedOn, [_id]);
        expect(scansAtStart, 0);
        // The sighting predates the run (iOS reaches E2 inside the window).
        expect(status.state, DfuRecoveryState.silentNeedsCable);
        expect(status.reason, DfuRecoveryReason.cableRecoveryPrepared);
      },
    );

    test('not seen for longer than the window (31 s > observe interval 30 s): '
        'bounded fresh scans (30 s / 8 s = 4), then refused, no DFU', () async {
      final h = _Harness();
      h.ble.scans = [];
      h.ble.sightings = [
        _adaDfu(at: h.now.subtract(const Duration(seconds: 31))),
      ];
      await expectRefused(
        h.controller.prepareCableRecovery(),
        DfuPreflightFailure.actionNotAvailable,
      );
      expect(h.ble.scanCalls, 4);
      expect(h.firmware.starts, 0);
    });

    test(
      'no sighting: the fresh-scan fallback retries before refusing',
      () async {
        final h = _Harness();
        h.ble.script.addAll([<BleScanResult>[], <BleScanResult>[]]);
        h.firmware.onStart = (i) => resetLeavesAir(h, i);
        final status = await h.controller.prepareCableRecovery();
        expect(h.firmware.starts, 1);
        expect(status.state, DfuRecoveryState.silentNeedsCable);
      },
    );

    test('no E2 while the TAG sits in the bootloader and only other scans '
        'receive its advert, however long', () async {
      final h = _Harness();
      h.ble.scans = [];
      for (var i = 0; i < 8; i++) {
        h.ble.sightings = [
          _adaDfu(at: h.now.subtract(const Duration(seconds: 5))),
        ];
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, DfuRecoveryState.resumable);
        h.now = h.now.add(const Duration(seconds: 40));
      }
      expect(h.firmware.physicalCalls, 0);
      // Control: truly silent for the window -> E2.
      h.ble.sightings = [];
      await h.controller.getDfuRecoveryStatus();
      h.now = h.now.add(const Duration(minutes: 3));
      final silent = await h.controller.getDfuRecoveryStatus();
      expect(silent.state, DfuRecoveryState.silentNeedsCable);
      expect(silent.reason, DfuRecoveryReason.deviceSilent);
    });

    test('E2 only after the recovery run reset the TAG: AdaDFU seen by another '
        'scan after the run is not claimed as cable', () async {
      final h = _Harness();
      h.firmware.onStart = (interrupted) {
        h.ble.scans = [];
        // Received after the post-reset settle: the TAG did not leave.
        h.ble.sightings = [_adaDfu(at: h.now.add(const Duration(seconds: 7)))];
        return interrupted.copyWith(
          remoteRecoveryAttempts: interrupted.remoteRecoveryAttempts + 1,
          remoteRecoveryFailed: true,
        );
      };
      final status = await h.controller.prepareCableRecovery();
      expect(h.firmware.starts, 1);
      expect(status.state, DfuRecoveryState.resumable);
      expect(h.firmware.physicalCalls, 0);
      expect((await h.store.load()).cablePreparedAt, isNull);
    });
  });

  group('restartDfuFromScratch', () {
    _Harness restartHarness({
      PhoneBatteryReading? phone = const PhoneBatteryReading(
        percent: 80,
        charging: false,
      ),
      int? tagBattery = 90,
    }) => _Harness(
      restartCapable: const {'9.9.9'},
      bootloaderVersion: '9.9.9',
      phone: phone,
      tagBattery: tagBattery,
    );

    test(
      'success is recovered only after reconnect + version verification',
      () async {
        final h = restartHarness();
        h.firmware.onStart = (interrupted) => interrupted.copyWith(
          state: FirmwareUpdateState.reconnecting,
          remoteRecoveryAttempts: interrupted.remoteRecoveryAttempts + 1,
          remoteRecoveryFailed: false,
        );
        // Transfer done but the version never verifies within the window.
        var status = await h.controller.restartDfuFromScratch();
        expect(status.state, isNot(DfuRecoveryState.recovered));
        expect(h.firmware.starts, 1);

        final ok = restartHarness();
        ok.firmware.onStart = h.firmware.onStart;
        var polls = 0;
        ok.firmware.onReconcile = () {
          polls++;
          if (polls < 3) {
            return _interrupted(state: FirmwareUpdateState.reconnecting);
          }
          ok.firmware.session = null;
          return _interrupted(state: FirmwareUpdateState.completed);
        };
        status = await ok.controller.restartDfuFromScratch();
        expect(polls, 3);
        expect(status.state, DfuRecoveryState.recovered);
      },
    );

    test('failed restart (Start then Reset) is not recovered', () async {
      final h = restartHarness();
      final status = await h.controller.restartDfuFromScratch();
      expect(status.state, isNot(DfuRecoveryState.recovered));
      expect(h.firmware.starts, 1);
    });

    test('unknown TAG battery starts and carries the warning', () async {
      final h = restartHarness(tagBattery: null);
      final status = await h.controller.restartDfuFromScratch();
      expect(h.firmware.starts, 1);
      expect(
        status.warnings,
        contains(DfuPreflightWarning.deviceBatteryUnknown),
      );
    });

    test('unreadable phone battery starts and carries the warning', () async {
      for (final reading in <PhoneBatteryReading?>[
        null,
        const PhoneBatteryReading(percent: null, charging: null),
      ]) {
        final h = restartHarness(phone: reading);
        final status = await h.controller.restartDfuFromScratch();
        expect(h.firmware.starts, 1);
        expect(
          status.warnings,
          contains(DfuPreflightWarning.phoneBatteryUnknown),
        );
      }
    });

    test('TAG battery below threshold blocks, boundary passes', () async {
      final low = restartHarness(tagBattery: 19);
      await expectRefused(
        low.controller.restartDfuFromScratch(),
        DfuPreflightFailure.deviceBatteryLow,
      );
      expect(low.firmware.starts, 0);
      final edge = restartHarness(tagBattery: 20);
      await edge.controller.restartDfuFromScratch();
      expect(edge.firmware.starts, 1);
    });
  });

  group('pre-flight before a recovery DFU', () {
    test('Bluetooth off', () async {
      final h = _Harness();
      h.ble.adapter = BleAdapterState.poweredOff;
      await expectRefused(
        h.controller.prepareCableRecovery(),
        DfuPreflightFailure.bluetoothOff,
      );
      expect(h.firmware.starts, 0);
    });

    test('phone battery low', () async {
      final h = _Harness(
        phone: const PhoneBatteryReading(percent: 12, charging: false),
      );
      await expectRefused(
        h.controller.prepareCableRecovery(),
        DfuPreflightFailure.phoneBatteryLow,
      );
      expect(h.firmware.starts, 0);
    });

    test('TAG not visible', () async {
      final h = _Harness();
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.resumable);
      h.ble.scans = [];
      await expectRefused(
        h.controller.prepareCableRecovery(),
        DfuPreflightFailure.actionNotAvailable,
      );
      expect(h.firmware.starts, 0);
    });

    test('another operation owns the device', () async {
      final h = _Harness();
      h.otherOperation = true;
      await expectRefused(
        h.controller.prepareCableRecovery(),
        DfuPreflightFailure.operationInProgress,
      );
      expect(h.firmware.starts, 0);
    });
  });

  group('E1 only while AdaDFU is observed (F7)', () {
    // The connected TAG answers with its intact old application: the
    // reconcile read the old version (installed-version mismatch, old app
    // valid -> retry the transfer).
    FirmwareUpdateSession oldAppRunning() => _interrupted().copyWith(
      state: FirmwareUpdateState.readyToTransfer,
      requiresRecovery: false,
      nextAction: FirmwareUpdateNextAction.retryTransfer,
      reconciliationOutcome:
          FirmwareUpdateReconciliationOutcome.installedVersionMismatch,
      failureCode: FirmwareUpdateSession.installedVersionMismatchCode,
    );

    test(
      'cut before the erase (Start not yet acknowledged): TAG back on its '
      'old app -> record cleared, no recovery card, nothing started',
      () async {
        final h = _Harness(
          session: _interrupted(
            state: FirmwareUpdateState.transferring,
          ).copyWith(requiresRecovery: false),
        );
        h.ble.scans = [_eixamApp()];
        h.firmware.onReconcile = oldAppRunning;
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, DfuRecoveryState.unknown);
        expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
        expect(status.availableAction, DfuRecoveryAction.none);
        expect(h.firmware.superseded, ['session-1']);
        expect(h.store.record.interruptedAt, isNull);
        expect(h.firmware.starts, 0);
        await expectRefused(
          h.controller.prepareCableRecovery(),
          DfuPreflightFailure.noInterruptedUpdate,
        );
      },
    );

    test(
      'TAG healthy with an interruption record (E1 shown earlier, the '
      'deliberate reset booted the intact app): cleared, never Ready',
      () async {
        final h = _Harness();
        var status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, DfuRecoveryState.resumable);
        expect(h.store.record.interruptedAt, isNotNull);
        // One tap; the Reset boots the intact old application instead of UF2.
        h.firmware.onStart = (interrupted) {
          h.ble.scans = [_eixamApp()];
          return interrupted.copyWith(
            remoteRecoveryAttempts: interrupted.remoteRecoveryAttempts + 1,
            remoteRecoveryFailed: true,
          );
        };
        h.firmware.onReconcile = oldAppRunning;
        status = await h.controller.prepareCableRecovery();
        expect(h.firmware.physicalCalls, 0, reason: 'not a cable case');
        expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
        expect(status.state, isNot(DfuRecoveryState.recovered));
        expect(h.firmware.superseded, ['session-1']);
        expect(h.store.record.interruptedAt, isNull);
        expect(h.store.record.recoveredAt, isNull);
      },
    );

    test('TAG advertising its app but not connected yet: no card action, '
        'record kept until the version is read', () async {
      final h = _Harness();
      h.ble.scans = [_eixamApp()];
      h.firmware.onReconcile = () =>
          _interrupted(state: FirmwareUpdateState.reconnecting);
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.awaitingEvidence);
      expect(status.availableAction, DfuRecoveryAction.none);
      expect(h.firmware.superseded, isEmpty);
    });

    test('TAG AdaDFU now: E1 offered; a card left over after the TAG changed '
        'mode is refused at the tap', () async {
      final h = _Harness();
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.availableAction, DfuRecoveryAction.prepareCableRecovery);
      for (final now in <List<BleScanResult>>[
        <BleScanResult>[],
        [_eixamApp()],
      ]) {
        h.ble.scans = now;
        await expectRefused(
          h.controller.prepareCableRecovery(),
          DfuPreflightFailure.actionNotAvailable,
        );
      }
      expect(h.firmware.starts, 0);
    });

    test('TAG silent: never the E1 action, E2 after the window', () async {
      final h = _Harness();
      h.ble.scans = [];
      var status = await h.controller.getDfuRecoveryStatus();
      expect(status.availableAction, DfuRecoveryAction.none);
      h.now = h.now.add(const Duration(minutes: 3));
      status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.silentNeedsCable);
      expect(status.availableAction, DfuRecoveryAction.none);
      expect(h.firmware.starts, 0);
    });

    test('TAG on an old version after relaunch: cleared; the firmware card '
        'offers the normal update', () async {
      final h = _Harness();
      h.ble.scans = [_eixamApp()];
      h.firmware.onReconcile = oldAppRunning;
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.firmware.session, isNull, reason: 'superseded');
      final next = await h.controller.getDfuRecoveryStatus();
      expect(next.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.ble.scanCalls, 1, reason: 'nothing left to observe');
    });
  });

  group('connected healthy TAG that does not advertise (F15/M2)', () {
    // What the SDK reconcile leaves after it read the OLD app version from the
    // connected TAG. A connected TAG stops advertising.
    FirmwareUpdateSession oldAppRead() => _interrupted().copyWith(
      state: FirmwareUpdateState.readyToTransfer,
      requiresRecovery: false,
      nextAction: FirmwareUpdateNextAction.retryTransfer,
      reconciliationOutcome:
          FirmwareUpdateReconciliationOutcome.installedVersionMismatch,
      failureCode: FirmwareUpdateSession.installedVersionMismatchCode,
    );

    test('silence already counting, then the app reconnect reads the old '
        'version: record cleared, never E2 or physical recovery', () async {
      final h = _Harness(
        session: _interrupted(
          state: FirmwareUpdateState.transferring,
        ).copyWith(requiresRecovery: false),
      );
      h.ble.scans = [];
      var status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.awaitingEvidence);
      expect(h.store.record.firstMissAt, isNotNull);
      // The saved-device reconnect wins and the app's reconcile reads 2.0.0.
      h.firmware.session = oldAppRead();
      h.now = h.now.add(const Duration(minutes: 3));
      status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, isNot(DfuRecoveryState.silentNeedsCable));
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(status.availableAction, DfuRecoveryAction.none);
      expect(h.firmware.physicalCalls, 0);
      expect(h.firmware.superseded, ['session-1']);
      expect(h.store.record.firstMissAt, isNull);
      expect(h.store.record.interruptedAt, isNull);
      expect(h.firmware.starts, 0);
    });

    test('old version read before the first tick: cleared without a scan; '
        'still nothing after the silence window', () async {
      final h = _Harness(session: oldAppRead());
      h.ble.scans = [];
      var status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.ble.scanCalls, 0);
      h.now = h.now.add(const Duration(minutes: 3));
      status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, isNot(DfuRecoveryState.silentNeedsCable));
      expect(h.firmware.physicalCalls, 0);
    });

    test(
      'truly silent TAG, no connection (no version read): E2 as before',
      () async {
        final h = _Harness(
          session: _interrupted().copyWith(
            state: FirmwareUpdateState.reconnecting,
            reconciliationOutcome:
                FirmwareUpdateReconciliationOutcome.deviceMissing,
          ),
        );
        h.ble.scans = [];
        await h.controller.getDfuRecoveryStatus();
        h.now = h.now.add(const Duration(minutes: 3));
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, DfuRecoveryState.silentNeedsCable);
        expect(h.firmware.physicalCalls, greaterThan(0));
        expect(h.firmware.superseded, isEmpty);
      },
    );
  });

  group('EIXAM UF2 cable recovery: the TAG comes back as EIXAM', () {
    FirmwareUpdateSession cable() =>
        _interrupted(state: FirmwareUpdateState.physicalRecoveryRequired);

    test('connected TAG reports a third (older/newer) app version: recovered, '
        'session superseded, no mismatch, no update started', () async {
      final h = _Harness(session: cable());
      h.ble.scans = [];
      h.firmware.connectedRead = (
        version: '2.7.68.f9a277c',
        isOldApplication: false,
      );
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.recovered);
      expect(status.reason, DfuRecoveryReason.versionVerified);
      expect(status.availableAction, DfuRecoveryAction.none);
      expect(h.firmware.superseded, ['session-1']);
      expect(h.store.record.recoveredAt, isNotNull);
      expect(h.firmware.starts, 0);
      expect(h.ble.scanCalls, 0);
    });

    test('the cable preparation marker alone (session not yet marked) counts '
        'as a cable recovery', () async {
      final h = _Harness();
      h.ble.scans = [];
      await h.store.save(
        DfuRecoveryRecord(sessionId: 'session-1', cablePreparedAt: h.now),
      );
      h.firmware.connectedRead = (version: '3.0.0', isOldApplication: false);
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.recovered);
      expect(h.firmware.superseded, ['session-1']);
    });

    test('connected TAG on the OLD app version is healthy: cleared, no '
        '"Ready"', () async {
      final h = _Harness(session: cable());
      h.ble.scans = [];
      h.firmware.connectedRead = (version: '2.0.0', isOldApplication: true);
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, isNot(DfuRecoveryState.recovered));
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.firmware.superseded, ['session-1']);
      expect(h.store.record.recoveredAt, isNull);
      expect(h.firmware.starts, 0);
    });

    test('EIXAM app advertising, not connected (unpaired / flash erased): '
        'interruption cleared, nothing verified, nothing started', () async {
      final h = _Harness(session: cable());
      h.ble.scans = [_eixamApp()];
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.physicalRecoveryCompleted);
      expect(status.availableAction, DfuRecoveryAction.none);
      expect(h.firmware.superseded, ['session-1']);
      expect(h.store.record.recoveredAt, isNull);
      expect(h.store.record.interruptedAt, isNull);
      expect(h.firmware.starts, 0);
      // Next observation: nothing interrupted any more, no E2, no scan needed.
      h.ble.scanCalls = 0;
      final next = await h.controller.getDfuRecoveryStatus();
      expect(next.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.ble.scanCalls, 0);
    });

    test('not a cable recovery (plain E1 session): an app advert does not '
        'clear the record by itself', () async {
      final h = _Harness();
      h.ble.scans = [_eixamApp()];
      await h.controller.getDfuRecoveryStatus();
      expect(h.firmware.superseded, isEmpty);
      expect(h.firmware.connectedReads, 0);
      expect(h.firmware.starts, 0);
    });

    test('bootloader still visible: a cable session is not cleared', () async {
      final h = _Harness(session: cable());
      h.ble.scans = [_adaDfu(), _eixamApp()];
      await h.controller.getDfuRecoveryStatus();
      expect(h.firmware.superseded, isEmpty);
    });

    test('another TAG advertising EIXAM does not end this recovery', () async {
      final h = _Harness(session: cable());
      h.ble.scans = [
        _scan(
          const [EixamBleProtocol.serviceUuid],
          id: 'other',
          hw: '11:22:33:44:55:66',
          name: 'EIXAM_11223344',
          brand: BleDiscoveredDeviceBrand.eixam,
        ),
      ];
      await h.controller.getDfuRecoveryStatus();
      expect(h.firmware.superseded, isEmpty);
    });
  });

  group('bootloader version string is not app evidence (M1)', () {
    // What the SDK reconcile now leaves after a reconnect campaign connected to
    // the TAG while it is AdaDFU and read "0.4.3 s140 6.1.1".
    FirmwareUpdateSession bootloaderRead() => _interrupted().copyWith(
      state: FirmwareUpdateState.failed,
      requiresRecovery: false,
      nextAction: FirmwareUpdateNextAction.waitForDevice,
      reconciliationOutcome:
          FirmwareUpdateReconciliationOutcome.installedVersionMismatch,
      failureCode: 'installedVersionMismatch',
    );

    test('AdaDFU visible: E1 card stays, nothing superseded', () async {
      final h = _Harness(session: bootloaderRead());
      expect(h.firmware.session?.isInstalledVersionMismatch, isFalse);
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, DfuRecoveryState.resumable);
      expect(status.availableAction, DfuRecoveryAction.prepareCableRecovery);
      expect(h.firmware.superseded, isEmpty);
      expect(h.firmware.starts, 0);
    });

    test(
      'a stale app advert next to it: not cleared (no app version read)',
      () async {
        final h = _Harness();
        h.ble.scans = [_eixamApp()];
        h.firmware.onReconcile = () {
          h.firmware.session = bootloaderRead();
          return h.firmware.session;
        };
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.reason, DfuRecoveryReason.awaitingEvidence);
        expect(h.firmware.superseded, isEmpty);
        expect(h.firmware.session, isNotNull);
      },
    );
  });

  group('verified version mismatch (F8) is not an interrupted update', () {
    FirmwareUpdateSession mismatch() => _interrupted().copyWith(
      state: FirmwareUpdateState.failed,
      requiresRecovery: false,
      nextAction: FirmwareUpdateNextAction.retry,
      failureCode: FirmwareUpdateSession.installedVersionMismatchCode,
      reconciliationOutcome:
          FirmwareUpdateReconciliationOutcome.installedVersionMismatch,
    );

    test('terminal mismatch session: no recovery card, no scan', () async {
      final h = _Harness(session: mismatch());
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.ble.scanCalls, 0);
      expect(h.firmware.superseded, isEmpty);
    });

    test('reconcile turns it into a mismatch: kept for the firmware card, '
        'no recovery card', () async {
      final h = _Harness();
      h.ble.scans = [_eixamApp()];
      h.firmware.onReconcile = () {
        h.firmware.session = mismatch();
        return h.firmware.session;
      };
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.reason, DfuRecoveryReason.noInterruptedUpdate);
      expect(h.firmware.superseded, isEmpty);
      expect(h.firmware.session?.isInstalledVersionMismatch, isTrue);
    });
  });

  group('iOS stale link (UNVERIFIED on hardware)', () {
    test(
      'stale bond + advertising TAG -> iosStaleLink, forget action',
      () async {
        final h = _Harness(ios: true);
        h.ble.scans = [_eixamApp()];
        await h.controller.noteIosStaleBond(_id);
        final status = await h.controller.getDfuRecoveryStatus();
        expect(status.state, DfuRecoveryState.iosStaleLink);
        expect(status.availableAction, DfuRecoveryAction.forgetDevice);
      },
    );

    test('ignored on other platforms', () async {
      final h = _Harness();
      h.ble.scans = [_eixamApp()];
      await h.controller.noteIosStaleBond(_id);
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, isNot(DfuRecoveryState.iosStaleLink));
    });

    test('not reported while the TAG is not advertising', () async {
      final h = _Harness(ios: true);
      h.ble.scans = [];
      await h.controller.noteIosStaleBond(_id);
      final status = await h.controller.getDfuRecoveryStatus();
      expect(status.state, isNot(DfuRecoveryState.iosStaleLink));
    });

    test('after the forget: marker cleared, re-scan, reconnect', () async {
      final h = _Harness(ios: true);
      h.ble.scans = [_eixamApp()];
      await h.controller.noteIosStaleBond(_id);
      await h.controller.getDfuRecoveryStatus();
      final scansBefore = h.ble.scanCalls;
      final status = await h.controller.confirmDeviceForgotten();
      expect(h.ble.scanCalls, greaterThan(scansBefore));
      expect(h.reconnects, [_id]);
      expect(status.state, isNot(DfuRecoveryState.iosStaleLink));
    });

    test('confirmDeviceForgotten without a stale link is refused', () async {
      final h = _Harness(ios: true);
      await expectRefused(
        h.controller.confirmDeviceForgotten(),
        DfuPreflightFailure.actionNotAvailable,
      );
      expect(h.reconnects, isEmpty);
    });
  });
}
