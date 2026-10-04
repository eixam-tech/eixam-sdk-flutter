import 'dart:async';

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_artifact_cache.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_firmware_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sdk_firmware_dto.dart';
import 'package:eixam_connect_flutter/src/device/ble_client.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_dfu_transport.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_update_coordinator.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_update_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/builders/device_status_builder.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  group('firmware backend mapping', () {
    test('maps update available response to release metadata', () {
      final dto = SdkFirmwareCheckDto.fromJson(<String, dynamic>{
        'update_available': true,
        'firmware': <String, dynamic>{
          'id': 'fw-1',
          'version': '2.0.0',
          'hardware_model': 'WISMESH_TAG',
          'sha256_hash': 'abc123',
          'file_size_bytes': 1234,
          'release_notes': 'OTA seed',
          'is_active': true,
        },
      });

      final release = dto.firmware!.toDomain();

      expect(dto.updateAvailable, isTrue);
      expect(release.releaseId, 'fw-1');
      expect(release.version, '2.0.0');
      expect(release.hardwareModel, 'WISMESH_TAG');
      expect(release.sha256Hash, 'abc123');
      expect(release.artifactKind, 'dfu_zip');
    });

    test('maps no update response', () {
      final dto = SdkFirmwareCheckDto.fromJson(<String, dynamic>{
        'update_available': false,
        'firmware': null,
      });

      expect(dto.updateAvailable, isFalse);
      expect(dto.firmware, isNull);
    });

    test('maps camelCase check payloads and numeric versions', () {
      final dto = SdkFirmwareCheckDto.fromJson(<String, dynamic>{
        'updateAvailable': true,
        'firmware': <String, dynamic>{
          'id': 'fw-50',
          'version': 50,
          'hardwareModel': 'WISMESH_TAG',
          'sha256Hash': 'abc123',
          'fileSizeBytes': 1234,
          'isActive': true,
        },
      });

      expect(dto.updateAvailable, isTrue);
      expect(dto.firmware!.version, '50');
      expect(dto.firmware!.hardwareModel, 'WISMESH_TAG');
      expect(dto.firmware!.sha256Hash, 'abc123');
    });
  });

  group('FirmwareUpdateCoordinator', () {
    late FakeSosRepository sosRepository;
    late FakeDeathManRepository deathManRepository;
    late FakeDeviceRepository deviceRepository;
    late _FakeFirmwareRemoteDataSource remote;
    late Directory cacheDirectory;

    FirmwareUpdateCoordinator buildCoordinator({
      FirmwareDfuTransport? transport,
      DeviceStatus? initialStatus,
      Future<ProtectionStatus> Function()? protectionStatusProvider,
      Future<DeviceSosStatus> Function()? deviceSosStatusProvider,
      Future<PublicPreSosStatus?> Function()? preSosStatusProvider,
      FirmwareDfuPreparationHook? prepareForDfuTransfer,
      FirmwareDfuConnectionHook? releaseBleForDfuTransfer,
      FirmwareDfuConnectionHook? restoreBleAfterDfuTransfer,
      FirmwareDfuStatusRefreshHook? postDfuStatusRefresh,
      Duration? dfuStallTimeout,
      Duration? dfuFirstUploadDeadline,
      Duration? postDfuVerificationTimeout,
      Duration? postDfuVerificationPollInterval,
      FirmwareUpdateSessionStore? sessionStore,
      BleClient? bleClient,
      Future<DeviceStatus> Function()? firmwareStatusRefresh,
      Future<FirmwarePhysicalRecoveryEvidence?> Function()?
      physicalRecoveryEvidenceProvider,
    }) {
      deviceRepository = FakeDeviceRepository(
        initialStatus: initialStatus ?? _readyStatus(),
      );
      return FirmwareUpdateCoordinator(
        deviceRepository: deviceRepository,
        sosRepository: sosRepository,
        deathManRepository: deathManRepository,
        remoteDataSource: remote,
        dfuTransport: transport ?? const UnsupportedFirmwareDfuTransport(),
        sessionStore: sessionStore ?? _MemoryFirmwareStore(),
        artifactCache: FileFirmwareArtifactCache(
          directoryProvider: () async => cacheDirectory,
        ),
        bleClient: bleClient,
        firmwareStatusRefresh: firmwareStatusRefresh,
        physicalRecoveryEvidenceProvider: physicalRecoveryEvidenceProvider,
        protectionStatusProvider: protectionStatusProvider,
        deviceSosStatusProvider: deviceSosStatusProvider,
        preSosStatusProvider: preSosStatusProvider,
        prepareForDfuTransfer: prepareForDfuTransfer,
        releaseBleForDfuTransfer: releaseBleForDfuTransfer,
        restoreBleAfterDfuTransfer: restoreBleAfterDfuTransfer,
        postDfuStatusRefresh: postDfuStatusRefresh,
        dfuStallTimeout: dfuStallTimeout ?? const Duration(seconds: 90),
        dfuFirstUploadDeadline:
            dfuFirstUploadDeadline ?? const Duration(seconds: 180),
        postDfuVerificationTimeout:
            postDfuVerificationTimeout ?? const Duration(seconds: 180),
        postDfuVerificationPollInterval:
            postDfuVerificationPollInterval ?? const Duration(seconds: 5),
      );
    }

    test(
      'firmware info and OTA check use fresh installed version over cached target',
      () async {
        var reads = 0;
        final coordinator = buildCoordinator(
          initialStatus: _readyStatus(firmwareVersion: '2.0.0'),
          firmwareStatusRefresh: () async {
            reads++;
            return _readyStatus(firmwareVersion: '1.0.0');
          },
        );
        addTearDown(coordinator.dispose);
        expect((await coordinator.getFirmwareInfo()).currentVersion, '1.0.0');
        final check = await coordinator.checkFirmwareUpdate();
        expect(check.device.currentVersion, '1.0.0');
        expect(check.updateAvailable, isTrue);
        expect(reads, 2);
      },
    );

    test(
      'recovery cannot complete from cached target when fresh firmware is old',
      () async {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(
            FirmwareUpdateState.recoveryRequired,
          ).copyWith(artifactVerified: true);
        final coordinator = buildCoordinator(
          sessionStore: store,
          initialStatus: _readyStatus(firmwareVersion: '2.0.0'),
          firmwareStatusRefresh: () async =>
              _readyStatus(firmwareVersion: '1.0.0'),
        );
        addTearDown(coordinator.dispose);
        final session = await coordinator.reconcileFirmwareUpdate();
        expect(session?.nextAction, FirmwareUpdateNextAction.retryTransfer);
        expect(session?.isCompleted, isFalse);
      },
    );

    test(
      'failed fresh firmware inspection cannot complete from cached target',
      () async {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(
            FirmwareUpdateState.recoveryRequired,
          );
        final coordinator = buildCoordinator(
          sessionStore: store,
          initialStatus: _readyStatus(firmwareVersion: '2.0.0'),
          firmwareStatusRefresh: () async =>
              throw StateError('firmware read unavailable'),
        );
        addTearDown(coordinator.dispose);
        final session = await coordinator.reconcileFirmwareUpdate();
        expect(session?.isCompleted, isFalse);
        expect(session?.nextAction, FirmwareUpdateNextAction.waitForDevice);
      },
    );

    setUp(() {
      sosRepository = FakeSosRepository();
      deathManRepository = FakeDeathManRepository();
      remote = _FakeFirmwareRemoteDataSource();
      cacheDirectory = Directory.systemTemp.createTempSync(
        'firmware-session-test-',
      );
    });

    tearDown(() async {
      await sosRepository.dispose();
      await deathManRepository.dispose();
      await deviceRepository.dispose();
      await cacheDirectory.delete(recursive: true);
    });

    for (final phase in [
      FirmwareUpdateState.downloading,
      FirmwareUpdateState.verifying,
      FirmwareUpdateState.readyToTransfer,
    ]) {
      test(
        'restored pre-native $phase reuses verified artifact and starts once',
        () async {
          final hash = _sha256(remote.artifactBytes);
          final reference = firmwareArtifactReference('fw-1', '2.0.0', hash);
          await FileFirmwareArtifactCache(
            directoryProvider: () async => cacheDirectory,
          ).writeVerified(reference, remote.artifactBytes);
          final store = _MemoryFirmwareStore()
            ..value = _durableFirmwareSession(phase).copyWith(
              nativeTransferEngaged: false,
              artifactReference: reference,
              artifactSha256: hash,
              artifactSizeBytes: remote.artifactBytes.length,
              artifactDownloaded: true,
              artifactVerified: true,
            );
          var starts = 0;
          final coordinator = buildCoordinator(
            sessionStore: store,
            transport: _SuccessfulDfuTransport(
              onStart: () {
                starts++;
                expect(store.value?.nativeTransferEngaged, true);
                expect(store.value?.artifactVerified, true);
                deviceRepository.setCurrentStatusSilently(
                  _readyStatus(firmwareVersion: '2.0.0'),
                );
              },
            ),
          );
          addTearDown(coordinator.dispose);
          final result = await coordinator.startFirmwareUpdate(
            deviceId: 'demo-device',
            releaseId: 'fw-1',
          );
          expect(result.state, FirmwareUpdateState.completed);
          expect(result.sessionId, 'fw-restored');
          expect(starts, 1);
          expect(remote.downloadCallCount, 0);
          expect(store.value, isNull);
        },
      );
    }

    test(
      'process death with incomplete download restarts without recovery',
      () async {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(
            FirmwareUpdateState.downloading,
          ).copyWith(nativeTransferEngaged: false);
        final coordinator = buildCoordinator(sessionStore: store);
        addTearDown(coordinator.dispose);
        final result = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );
        expect(remote.downloadCallCount, 1);
        expect(result.requiresRecovery, false);
        expect(result.artifactVerified, true);
        expect(result.nativeTransferEngaged, false);
      },
    );

    test(
      'migration missing-device inspection persists canonical wait without physical inference',
      () async {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(
            FirmwareUpdateState.recoveryRequired,
          ).copyWith(nativeTransferEngaged: true);
        final coordinator = buildCoordinator(
          sessionStore: store,
          initialStatus: _readyStatus(connected: false),
        );
        final result = await coordinator.inspectMigrationPhysicalRecovery();
        expect(result?.state, FirmwareUpdateState.reconnecting);
        expect(result?.nextAction, FirmwareUpdateNextAction.waitForDevice);
        expect(result?.nativeTransferEngaged, true);
        await coordinator.dispose();
        expect(store.value?.nextAction, FirmwareUpdateNextAction.waitForDevice);
      },
    );

    test('concurrent starts cannot launch duplicate transfers', () async {
      final coordinator = buildCoordinator();
      addTearDown(coordinator.dispose);
      final first = coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );
      await expectLater(
        coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        ),
        throwsA(isA<FirmwareUpdateException>()),
      );
      await first;
      expect(remote.downloadCallCount, 1);
    });

    for (final scenario in [
      (
        name: 'matching invalid application without remote recovery',
        id: 'AA:BB:CC:DD:EE:FF',
        invalid: true,
        unsupported: true,
        native: true,
        physical: true,
      ),
      (
        name: 'wrong physical device',
        id: '11:22:33:44:55:66',
        invalid: true,
        unsupported: true,
        native: true,
        physical: false,
      ),
      (
        name: 'valid application',
        id: 'AA:BB:CC:DD:EE:FF',
        invalid: false,
        unsupported: true,
        native: true,
        physical: false,
      ),
      (
        name: 'remote recovery supported',
        id: 'AA:BB:CC:DD:EE:FF',
        invalid: true,
        unsupported: false,
        native: true,
        physical: false,
      ),
      (
        name: 'pre-transfer death',
        id: 'AA:BB:CC:DD:EE:FF',
        invalid: true,
        unsupported: true,
        native: false,
        physical: false,
      ),
    ]) {
      test('physical recovery evidence: ${scenario.name}', () async {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(
            FirmwareUpdateState.transferring,
          ).copyWith(nativeTransferEngaged: scenario.native);
        final coordinator = buildCoordinator(
          sessionStore: store,
          initialStatus: _readyStatus(connected: false),
          physicalRecoveryEvidenceProvider: () async =>
              FirmwarePhysicalRecoveryEvidence(
                deviceId: 'demo-device',
                hardwareId: scenario.id,
                applicationInvalid: scenario.invalid,
                remoteRecoveryUnsupported: scenario.unsupported,
              ),
        );
        addTearDown(coordinator.dispose);
        final result = await coordinator.reconcileFirmwareUpdate();
        expect(
          result?.nextAction,
          scenario.physical
              ? FirmwareUpdateNextAction.physicalRecovery
              : FirmwareUpdateNextAction.waitForDevice,
        );
      });
    }

    test(
      'disposed download cannot launch a late transfer; restart resumes the same intent',
      () async {
        final gate = Completer<List<int>>();
        remote.downloadGate = gate;
        final store = _MemoryFirmwareStore();
        var nativeStarts = 0;
        final first = buildCoordinator(
          sessionStore: store,
          transport: _SuccessfulDfuTransport(onStart: () => nativeStarts++),
        );
        final operation = first.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );
        while (remote.downloadCallCount == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        final sessionId = store.value!.sessionId;
        expect(store.value?.state, FirmwareUpdateState.downloading);
        await first.dispose();
        gate.complete(remote.artifactBytes);
        await operation;
        expect(nativeStarts, 0);
        expect(store.value?.nativeTransferEngaged, false);
        await deviceRepository.dispose();
        remote.downloadGate = null;
        final restored = buildCoordinator(
          sessionStore: store,
          transport: _SuccessfulDfuTransport(
            onStart: () {
              nativeStarts++;
              deviceRepository.setCurrentStatusSilently(
                _readyStatus(firmwareVersion: '2.0.0'),
              );
            },
          ),
        );
        addTearDown(restored.dispose);
        final result = await restored.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );
        expect(result.sessionId, sessionId);
        expect(result.state, FirmwareUpdateState.completed);
        expect(nativeStarts, 1);
        expect(remote.downloadCallCount, 2);
      },
    );

    test('disposal during BLE handoff cannot engage native transfer', () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final store = _MemoryFirmwareStore();
      var nativeStarts = 0;
      final coordinator = buildCoordinator(
        sessionStore: store,
        transport: _SuccessfulDfuTransport(onStart: () => nativeStarts++),
        releaseBleForDfuTransfer: ({required String deviceId}) async {
          entered.complete();
          await release.future;
        },
      );
      final operation = coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );
      await entered.future;
      expect(store.value?.artifactVerified, true);
      expect(store.value?.nativeTransferEngaged, false);
      await coordinator.dispose();
      release.complete();
      await operation;
      expect(nativeStarts, 0);
      expect(store.value?.nativeTransferEngaged, false);
    });

    test(
      'wrong physical TAG reporting target version cannot complete a transfer',
      () async {
        final coordinator = buildCoordinator(
          transport: _SuccessfulDfuTransport(
            onStart: () {
              deviceRepository.setCurrentStatusSilently(
                _readyStatus(firmwareVersion: '2.0.0').copyWith(
                  deviceId: 'other-tag',
                  canonicalHardwareId: '11:22:33:44:55:66',
                ),
              );
            },
          ),
          postDfuVerificationTimeout: Duration.zero,
        );
        addTearDown(coordinator.dispose);
        final result = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );
        expect(result.state, isNot(FirmwareUpdateState.completed));
      },
    );

    test('blocks missing firmware version without backend call', () async {
      final coordinator = buildCoordinator(
        initialStatus: _readyStatus(firmwareVersion: null),
      );
      addTearDown(coordinator.dispose);

      final check = await coordinator.checkFirmwareUpdate();

      expect(check.updateAvailable, isFalse);
      expect(
        check.eligibility.blockers,
        contains(FirmwareUpdateBlocker.unknownFirmwareVersion),
      );
      expect(remote.checkCallCount, 0);
    });

    test('blocks low device battery', () async {
      final coordinator = buildCoordinator(
        initialStatus: _readyStatus(batteryState: DeviceBatteryLevel.critical),
      );
      addTearDown(coordinator.dispose);

      final check = await coordinator.checkFirmwareUpdate();

      expect(
        check.eligibility.blockers,
        contains(FirmwareUpdateBlocker.lowDeviceBattery),
      );
    });

    test('passes normalized semver and explicit downgrade policy to the '
        'firmware backend', () async {
      final coordinator = buildCoordinator(
        initialStatus: _readyStatus(
          firmwareVersion: ' V3.0.0.build-hash\u0000',
        ),
      );
      addTearDown(coordinator.dispose);

      await coordinator.checkFirmwareUpdate(
        policy: const FirmwareUpdatePolicy(allowDowngrade: true),
      );

      expect(remote.lastAllowDowngrade, isTrue);
      expect(remote.lastCurrentVersion, '3.0.0');
    });

    test('rejects a backend update whose release matches the installed '
        'firmware version', () async {
      remote.releaseVersion = '2.0.0';
      final coordinator = buildCoordinator(
        initialStatus: _readyStatus(
          firmwareVersion: ' V2.0.0.build-hash\u0000',
        ),
      );
      addTearDown(coordinator.dispose);

      final check = await coordinator.checkFirmwareUpdate();

      expect(check.updateAvailable, isFalse);
      expect(check.release, isNull);
    });

    test(
      'lists every firmware release available for the connected model',
      () async {
        remote.availableReleases = <SdkFirmwareDto>[
          const SdkFirmwareDto(id: 'fw-3', version: '3.0.0'),
          const SdkFirmwareDto(id: 'fw-2', version: '2.0.0'),
        ];
        final coordinator = buildCoordinator();
        addTearDown(coordinator.dispose);

        final releases = await coordinator.listFirmwareReleases();

        expect(releases.map((release) => release.releaseId), <String>[
          'fw-3',
          'fw-2',
        ]);
      },
    );

    test(
      'treats a portal short build as newer than the installed semver',
      () async {
        remote.releaseVersion = '50';
        final coordinator = buildCoordinator(
          initialStatus: _readyStatus(firmwareVersion: '2.7.45'),
        );
        addTearDown(coordinator.dispose);

        final check = await coordinator.checkFirmwareUpdate();

        expect(check.updateAvailable, isTrue);
        expect(check.release?.version, '50');
      },
    );

    test('uses the catalog when check reports no update', () async {
      remote.checkUpdateAvailable = false;
      remote.availableReleases = <SdkFirmwareDto>[
        const SdkFirmwareDto(id: 'fw-45', version: '2.7.45', isActive: true),
        const SdkFirmwareDto(id: 'fw-50', version: '2.7.50', isActive: true),
      ];
      final coordinator = buildCoordinator(
        initialStatus: _readyStatus(firmwareVersion: '2.7.45'),
      );
      addTearDown(coordinator.dispose);

      final check = await coordinator.checkFirmwareUpdate();

      expect(remote.listCallCount, 1);
      expect(check.updateAvailable, isTrue);
      expect(check.release?.version, '2.7.50');
    });

    test('accepts an explicit non-current target release', () async {
      remote.releaseVersion = '1.0.0';
      final coordinator = buildCoordinator(
        initialStatus: _readyStatus(firmwareVersion: '3.0.0'),
      );
      addTearDown(coordinator.dispose);

      final check = await coordinator.checkFirmwareUpdate(
        policy: const FirmwareUpdatePolicy(targetReleaseId: 'fw-1'),
      );

      expect(check.updateAvailable, isTrue);
      expect(check.release?.releaseId, 'fw-1');
      expect(remote.lastTargetReleaseId, 'fw-1');
    });

    test('blocks active SOS state', () async {
      sosRepository.currentIncident = sosRepository.currentIncident.copyWith(
        state: SosState.sent,
      );
      final coordinator = buildCoordinator();
      addTearDown(coordinator.dispose);

      final check = await coordinator.checkFirmwareUpdate();

      expect(
        check.eligibility.blockers,
        contains(FirmwareUpdateBlocker.sosActive),
      );
    });

    test(
      'migration resolves only active model-specific EIXAM R1 artifacts',
      () async {
        remote.availableReleases = <SdkFirmwareDto>[
          SdkFirmwareDto(
            id: 'universal',
            version: '9.0.0',
            sha256Hash: _sha256(remote.artifactBytes),
            fileSizeBytes: remote.artifactBytes.length,
            isActive: true,
          ),
          SdkFirmwareDto(
            id: 'wrong-model',
            version: '8.0.0',
            hardwareModel: 'WISMESH_TAG',
            sha256Hash: _sha256(remote.artifactBytes),
            fileSizeBytes: remote.artifactBytes.length,
            isActive: true,
          ),
          SdkFirmwareDto(
            id: 'inactive',
            version: '7.0.0',
            hardwareModel: 'EIXAM R1',
            sha256Hash: _sha256(remote.artifactBytes),
            fileSizeBytes: remote.artifactBytes.length,
            isActive: false,
          ),
          SdkFirmwareDto(
            id: 'safe',
            version: '3.0.0',
            hardwareModel: 'EIXAM R1',
            sha256Hash: _sha256(remote.artifactBytes),
            fileSizeBytes: remote.artifactBytes.length,
            isActive: true,
          ),
        ];
        final coordinator = buildCoordinator();
        addTearDown(coordinator.dispose);

        final release = await coordinator.resolveMigrationRelease(
          hardwareModel: 'EIXAM R1',
        );

        expect(release?.releaseId, 'safe');
      },
    );

    test(
      'migration reuses download, SHA validation, DFU and version check',
      () async {
        remote.availableReleases = <SdkFirmwareDto>[
          SdkFirmwareDto(
            id: 'safe',
            version: '3.0.0',
            hardwareModel: 'EIXAM R1',
            sha256Hash: _sha256(remote.artifactBytes),
            fileSizeBytes: remote.artifactBytes.length,
            isActive: true,
          ),
        ];
        final coordinator = buildCoordinator(
          transport: _SuccessfulDfuTransport(),
        );
        addTearDown(coordinator.dispose);
        final release = await coordinator.resolveMigrationRelease(
          hardwareModel: 'EIXAM R1',
        );

        final session = await coordinator.startMigrationFirmwareUpdate(
          sourceStatus: _readyStatus().copyWith(model: 'EIXAM R1'),
          release: release!,
          policy: const FirmwareUpdatePolicy(
            supportedHardwareModels: <String>['EIXAM R1'],
          ),
          postMigrationStatusRefresh:
              ({
                required deviceId,
                required attempt,
                required targetVersion,
              }) async => _readyStatus(
                firmwareVersion: targetVersion,
              ).copyWith(model: 'EIXAM R1'),
        );

        expect(session.state, FirmwareUpdateState.completed);
        expect(remote.downloadCallCount, 1);
      },
    );

    for (final scenario
        in <
          ({
            String name,
            FirmwareUpdateState state,
            bool recovery,
            String deviceId,
            bool allowed,
          })
        >[
          (
            name: 'verified source after terminal failure',
            state: FirmwareUpdateState.failed,
            recovery: false,
            deviceId: 'demo-device',
            allowed: true,
          ),
          (
            name: 'restored transfer with verified old application',
            state: FirmwareUpdateState.transferring,
            recovery: false,
            deviceId: 'demo-device',
            allowed: true,
          ),
          (
            name: 'restored recovery with verified old application',
            state: FirmwareUpdateState.recoveryRequired,
            recovery: true,
            deviceId: 'demo-device',
            allowed: true,
          ),
          (
            name: 'different physical device',
            state: FirmwareUpdateState.failed,
            recovery: false,
            deviceId: 'other-device',
            allowed: false,
          ),
        ]) {
      test('migration retry ownership: ${scenario.name}', () async {
        final now = DateTime.now();
        final store = _MemoryFirmwareStore()
          ..value = FirmwareUpdateSession(
            sessionId: 'previous-attempt',
            deviceId: scenario.deviceId,
            releaseId: 'fw-1',
            fromVersion: '1.0.0',
            targetVersion: '2.0.0',
            state: scenario.state,
            startedAt: now,
            completedAt: now,
            requiresRecovery: scenario.recovery,
            nativeTransferEngaged: true,
            nextAction: FirmwareUpdateNextAction.retry,
          );
        final coordinator = buildCoordinator(
          sessionStore: store,
          transport: _SuccessfulDfuTransport(),
        );
        addTearDown(coordinator.dispose);
        final release = FirmwareRelease(
          releaseId: 'fw-1',
          version: '2.0.0',
          hardwareModel: 'WISMESH_TAG',
          sha256Hash: _sha256(remote.artifactBytes),
          fileSizeBytes: remote.artifactBytes.length,
        );
        final operation = coordinator.startMigrationFirmwareUpdate(
          sourceStatus: _readyStatus(),
          release: release,
          postMigrationStatusRefresh:
              ({
                required deviceId,
                required attempt,
                required targetVersion,
              }) async => _readyStatus(firmwareVersion: targetVersion),
        );
        if (scenario.allowed) {
          expect((await operation).state, FirmwareUpdateState.completed);
          expect(remote.downloadCallCount, 1);
        } else {
          await expectLater(operation, throwsA(isA<FirmwareUpdateException>()));
          expect(remote.downloadCallCount, 0);
          expect(store.value?.sessionId, 'previous-attempt');
        }
      });
    }

    test('fails on hash mismatch', () async {
      remote.artifactBytes = <int>[1, 2, 3];
      remote.downloadHash = 'not-the-real-hash';
      final coordinator = buildCoordinator();
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.failed);
      expect(session.failureCode, 'hashMismatch');
    });

    test('rejects metadata file size above hard cap before download', () async {
      remote.fileSizeBytes = maxFirmwareArtifactBytes + 1;
      final coordinator = buildCoordinator();
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.failed);
      expect(session.failureCode, firmwareArtifactTooLargeCode);
      expect(remote.downloadCallCount, 0);
    });

    test('rejects actual body larger than metadata after download', () async {
      remote.fileSizeBytes = 2;
      remote.artifactBytes = <int>[1, 2, 3];
      remote.downloadHash = _sha256(remote.artifactBytes);
      final coordinator = buildCoordinator();
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.failed);
      expect(session.failureCode, firmwareArtifactTooLargeCode);
      expect(remote.downloadCallCount, 1);
    });

    test('fails when artifact download fails', () async {
      remote.downloadError = const FirmwareUpdateException(
        'E_FIRMWARE_ARTIFACT_DOWNLOAD_FAILED',
        'boom',
      );
      final coordinator = buildCoordinator();
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.failed);
      expect(session.failureCode, 'E_FIRMWARE_ARTIFACT_DOWNLOAD_FAILED');
    });

    test(
      'fails at transfer boundary when native DFU is not implemented',
      () async {
        final coordinator = buildCoordinator();
        addTearDown(coordinator.dispose);

        final session = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );

        expect(session.state, FirmwareUpdateState.failed);
        expect(
          session.failureCode,
          UnsupportedFirmwareDfuTransport.failureCode,
        );
      },
    );

    test('exposes typed oversized artifact error to OTA session', () async {
      remote.downloadError = const FirmwareUpdateException(
        firmwareArtifactTooLargeCode,
        'Firmware artifact contentLength size exceeds SDK limit.',
      );
      final coordinator = buildCoordinator();
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.failed);
      expect(session.failureCode, firmwareArtifactTooLargeCode);
    });

    test(
      'completes only after installed firmware version matches target',
      () async {
        final coordinator = buildCoordinator(
          transport: _SuccessfulDfuTransport(
            onStart: () {
              deviceRepository.setCurrentStatusSilently(
                _readyStatus(firmwareVersion: '2.0.0'),
              );
            },
          ),
        );
        addTearDown(coordinator.dispose);

        final session = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );

        expect(session.state, FirmwareUpdateState.completed);
        expect(session.failureCode, isNull);
      },
    );

    test(
      'accepts a device version that appends a build hash to the release',
      () async {
        // Mirrors real firmware revision strings such as `2.7.25.942a98e`: the
        // release version is the dotted-numeric core and the device reports it
        // with a git hash appended on a dot boundary.
        final coordinator = buildCoordinator(
          transport: _SuccessfulDfuTransport(
            onStart: () {
              deviceRepository.setCurrentStatusSilently(
                _readyStatus(firmwareVersion: '2.0.0.942a98e'),
              );
            },
          ),
        );
        addTearDown(coordinator.dispose);

        final session = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );

        expect(session.state, FirmwareUpdateState.completed);
        expect(session.failureCode, isNull);
      },
    );

    test(
      'tolerates NUL/whitespace padding and a v prefix in the device version',
      () async {
        final coordinator = buildCoordinator(
          transport: _SuccessfulDfuTransport(
            onStart: () {
              deviceRepository.setCurrentStatusSilently(
                _readyStatus(firmwareVersion: '  V2.0.0\u0000'),
              );
            },
          ),
        );
        addTearDown(coordinator.dispose);

        final session = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );

        expect(session.state, FirmwareUpdateState.completed);
        expect(session.failureCode, isNull);
      },
    );

    test(
      'recoverFirmwareUpdate re-flashes a bootloader device and completes',
      () async {
        final coordinator = buildCoordinator(
          transport: _SuccessfulDfuTransport(),
        );
        addTearDown(coordinator.dispose);

        final session = await coordinator.recoverFirmwareUpdate(
          bootloaderDeviceId: 'bootloader-addr',
          releaseId: 'fw-1',
          targetVersion: '2.0.0',
        );

        expect(session.state, FirmwareUpdateState.reconnecting);
        expect(session.failureCode, isNull);
      },
    );

    test(
      'recoverFirmwareUpdate stays recovery-required when the flash fails',
      () async {
        final coordinator = buildCoordinator(transport: _FailingDfuTransport());
        addTearDown(coordinator.dispose);

        final session = await coordinator.recoverFirmwareUpdate(
          bootloaderDeviceId: 'bootloader-addr',
          releaseId: 'fw-1',
          targetVersion: '2.0.0',
        );

        expect(session.state, FirmwareUpdateState.recoveryRequired);
      },
    );

    test('stalls into recovery when only connection churn arrives and no byte '
        'is ever uploaded', () async {
      // The Nordic reconnect-retry loop emits a steady stream of
      // connecting/disconnected state events (no progress percentage). Those
      // must NOT keep the stall watchdog alive: a device that entered the
      // bootloader but was never reconnected has to surface as dfuStalled /
      // recoveryRequired instead of pinning the UI at 0% forever.
      final transport = _ChurnDfuTransport(
        tickInterval: const Duration(milliseconds: 10),
      );
      final coordinator = buildCoordinator(
        transport: transport,
        dfuStallTimeout: const Duration(milliseconds: 120),
        dfuFirstUploadDeadline: const Duration(milliseconds: 250),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.recoveryRequired);
      expect(session.failureCode, 'dfuStalled');
      // The still-pending native transfer must be cancelled, not orphaned, so a
      // subsequent recovery is not rejected with 'alreadyRunning'.
      expect(transport.cancelCount, greaterThanOrEqualTo(1));
    });

    test('a stall with no native event at all requires reconciliation '
        '(callback absence cannot prove device state)', () async {
      // If the native side hangs before emitting anything, the enter-DFU write
      // never happened and the running app was never erased — a plain retry is
      // correct, and telling the user to re-flash a healthy device is wrong.
      final coordinator = buildCoordinator(
        transport: _ChurnDfuTransport(
          tickInterval: const Duration(milliseconds: 10),
          emitEvents: false,
        ),
        dfuStallTimeout: const Duration(milliseconds: 120),
        dfuFirstUploadDeadline: const Duration(milliseconds: 200),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.recoveryRequired);
      expect(session.failureCode, 'dfuStalled');
    });

    test(
      'upload progress events keep the transfer alive past the deadline',
      () async {
        // A slow-but-progressing upload must never be reported stalled: only a
        // full stall window with no percentage change may fail it. Total upload
        // time here (5 x 100 ms) exceeds both the first-upload deadline and the
        // stall window, so completion proves progress events re-arm correctly.
        final transport = _SlowUploadDfuTransport(
          tickInterval: const Duration(milliseconds: 100),
          ticksToComplete: 5,
          onComplete: () {
            deviceRepository.setCurrentStatusSilently(
              _readyStatus(firmwareVersion: '2.0.0'),
            );
          },
        );
        final coordinator = buildCoordinator(
          transport: transport,
          dfuStallTimeout: const Duration(milliseconds: 150),
          dfuFirstUploadDeadline: const Duration(milliseconds: 300),
        );
        addTearDown(coordinator.dispose);

        final session = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );

        expect(session.state, FirmwareUpdateState.completed);
        expect(session.failureCode, isNull);
      },
    );

    test('refuses cancel once native transfer engagement is proven', () async {
      final coordinator = buildCoordinator(
        transport: _ChurnDfuTransport(
          tickInterval: const Duration(milliseconds: 10),
        ),
        dfuStallTimeout: const Duration(milliseconds: 200),
        dfuFirstUploadDeadline: const Duration(milliseconds: 400),
      );
      addTearDown(coordinator.dispose);

      final sessionIdSeen = Completer<String>();
      final progressSub = coordinator.watchProgress().listen((progress) {
        if (progress.nativeTransferEngaged && !sessionIdSeen.isCompleted) {
          sessionIdSeen.complete(progress.sessionId);
        }
      });
      addTearDown(progressSub.cancel);
      final updateFuture = coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );
      final sessionId = await sessionIdSeen.future.timeout(
        const Duration(seconds: 5),
      );

      await expectLater(
        coordinator.cancelFirmwareUpdate(sessionId),
        throwsA(
          isA<FirmwareUpdateException>().having(
            (error) => error.code,
            'code',
            'dfuCancelBlockedInTransfer',
          ),
        ),
      );

      // The stall watchdog ends the session on its own.
      final session = await updateFuture;
      expect(session.state, FirmwareUpdateState.recoveryRequired);
    });

    test('recoverFirmwareUpdate suppresses auto-reconnect for the transfer '
        'window (release/restore hooks)', () async {
      final calls = <String>[];
      final coordinator = buildCoordinator(
        transport: _SuccessfulDfuTransport(),
        releaseBleForDfuTransfer: ({required String deviceId}) async {
          calls.add('release:$deviceId');
        },
        restoreBleAfterDfuTransfer: ({required String deviceId}) async {
          calls.add('restore:$deviceId');
        },
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.recoverFirmwareUpdate(
        bootloaderDeviceId: 'bootloader-addr',
        releaseId: 'fw-1',
        targetVersion: '2.0.0',
      );

      expect(session.state, FirmwareUpdateState.reconnecting);
      expect(calls, <String>[
        'release:bootloader-addr',
        'restore:bootloader-addr',
      ]);
    });

    // ── Full-chain "e2e-in-a-test" ──────────────────────────────────────────
    // These drive the REAL coordinator through the entire OTA pipeline against
    // fakes for the one seam that cannot run off-device (the native Nordic DFU
    // transport). Everything else — eligibility, download, SHA verify, the
    // stall/first-upload watchdogs, the BLE release/restore handoff, the
    // post-DFU multi-poll reconnect+version verification, and the emitted
    // progress stream — is the production code path. This is the closest OTA
    // verification possible without physical nRF52 hardware (the actual byte
    // transfer + bootloader flashing is hardware-only and covered on a device).

    test(
      'e2e: emits the full ordered progress pipeline to completion',
      () async {
        final states = <FirmwareUpdateState>[];
        final coordinator = buildCoordinator(
          transport: _SlowUploadDfuTransport(
            tickInterval: const Duration(milliseconds: 20),
            ticksToComplete: 4,
            onComplete: () {
              // Device rebooted into the new image and now reports the target.
              deviceRepository.setCurrentStatusSilently(
                _readyStatus(firmwareVersion: '2.0.0'),
              );
            },
          ),
          postDfuVerificationPollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(coordinator.dispose);
        final sub = coordinator.watchProgress().listen(
          (p) => states.add(p.state),
        );
        addTearDown(sub.cancel);

        final session = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );
        await pumpEventQueue();

        expect(session.state, FirmwareUpdateState.completed);
        // The user-visible phases must arrive in order, no phase skipped.
        expect(
          states,
          containsAllInOrder(<FirmwareUpdateState>[
            FirmwareUpdateState.downloading,
            FirmwareUpdateState.verifying,
            FirmwareUpdateState.readyToTransfer,
            FirmwareUpdateState.transferring,
            FirmwareUpdateState.reconnecting,
            FirmwareUpdateState.completed,
          ]),
        );
        // A real upload percentage was surfaced (not stuck indeterminate).
        expect(states.contains(FirmwareUpdateState.transferring), isTrue);
      },
    );

    test('e2e: BLE handoff hooks bracket the transfer in order', () async {
      final calls = <String>[];
      final coordinator = buildCoordinator(
        transport: _SuccessfulDfuTransport(
          onStart: () {
            calls.add('nativeStart');
            deviceRepository.setCurrentStatusSilently(
              _readyStatus(firmwareVersion: '2.0.0'),
            );
          },
        ),
        releaseBleForDfuTransfer: ({required String deviceId}) async {
          calls.add('release:$deviceId');
        },
        restoreBleAfterDfuTransfer: ({required String deviceId}) async {
          calls.add('restore:$deviceId');
        },
        postDfuVerificationPollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.completed);
      // Release must precede the native transfer and restore must follow it —
      // the ordering the auto-reconnect suppression depends on.
      expect(calls, <String>[
        'release:demo-device',
        'nativeStart',
        'restore:demo-device',
      ]);
    });

    test(
      'e2e: post-DFU verification polls until the device reports the target',
      () async {
        var refreshAttempts = 0;
        final coordinator = buildCoordinator(
          transport: _SuccessfulDfuTransport(),
          postDfuVerificationPollInterval: const Duration(milliseconds: 5),
          postDfuStatusRefresh:
              ({
                required String deviceId,
                required int attempt,
                required String targetVersion,
              }) async {
                refreshAttempts = attempt;
                // The device reconnects on attempt 2 and only reports the new
                // version on attempt 3 — exercises the multi-poll reconnect loop.
                if (attempt < 2) {
                  return _readyStatus(
                    firmwareVersion: '1.0.0',
                    connected: false,
                  );
                }
                if (attempt < 3) {
                  return _readyStatus(firmwareVersion: '1.0.0');
                }
                return _readyStatus(firmwareVersion: '2.0.0');
              },
        );
        addTearDown(coordinator.dispose);

        final session = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );

        expect(session.state, FirmwareUpdateState.completed);
        expect(refreshAttempts, greaterThanOrEqualTo(3));
      },
    );

    for (final error in [
      StateError('Bluetooth adapter is off'),
      const FirmwareUpdateException(
        'bluetoothDisabled',
        'Bluetooth adapter is off',
      ),
    ]) {
      test(
        'Bluetooth unavailable after native completion keeps verification waiting: ${error.runtimeType}',
        () async {
          var attempts = 0;
          var nativeStarts = 0;
          final transport = _SuccessfulDfuTransport(
            onStart: () => nativeStarts++,
          );
          final coordinator = buildCoordinator(
            transport: transport,
            postDfuVerificationPollInterval: const Duration(milliseconds: 1),
            postDfuStatusRefresh:
                ({
                  required deviceId,
                  required attempt,
                  required targetVersion,
                }) async {
                  attempts++;
                  if (attempts < 3) throw error;
                  return _readyStatus(firmwareVersion: '2.0.0');
                },
          );
          addTearDown(coordinator.dispose);
          final progress = <FirmwareUpdateProgress>[];
          final sub = coordinator
              .watchProgress(deviceId: 'demo-device')
              .listen(progress.add);
          addTearDown(sub.cancel);
          final session = await coordinator.startFirmwareUpdate(
            deviceId: 'demo-device',
            releaseId: 'fw-1',
          );
          expect(session.state, FirmwareUpdateState.completed);
          expect(attempts, 3);
          expect(nativeStarts, 1);
          expect(session.requiresRecovery, isFalse);
          expect(
            progress.any(
              (event) => event.state == FirmwareUpdateState.recoveryRequired,
            ),
            isFalse,
          );
        },
      );
    }

    test('e2e: a device that never reports the target within the window needs '
        'recovery', () async {
      final coordinator = buildCoordinator(
        transport: _SuccessfulDfuTransport(),
        postDfuVerificationTimeout: const Duration(milliseconds: 60),
        postDfuVerificationPollInterval: const Duration(milliseconds: 10),
        postDfuStatusRefresh:
            ({
              required String deviceId,
              required int attempt,
              required String targetVersion,
            }) async {
              // Never reconnects → past the point of no return, must route to
              // recovery (the device is stranded in the bootloader).
              return _readyStatus(firmwareVersion: null, connected: false);
            },
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.recoveryRequired);
      expect(session.failureCode, 'deviceNotReconnected');
    });

    test('e2e: an update offered while the device is momentarily disconnected '
        'is prepared, then transferred', () async {
      var prepareCalls = 0;
      final coordinator = buildCoordinator(
        // Device is known but not currently connected when the user taps update.
        initialStatus: _readyStatus(connected: false),
        transport: _SuccessfulDfuTransport(
          onStart: () {
            deviceRepository.setCurrentStatusSilently(
              _readyStatus(firmwareVersion: '2.0.0'),
            );
          },
        ),
        prepareForDfuTransfer: ({required String deviceId}) async {
          // The prep hook reconnects/settles the device before the transfer.
          prepareCalls += 1;
          final ready = _readyStatus();
          deviceRepository.setCurrentStatusSilently(ready);
          return ready;
        },
        postDfuVerificationPollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(prepareCalls, greaterThanOrEqualTo(1));
      expect(session.state, FirmwareUpdateState.completed);
    });

    test('e2e: a native error event mid-flash still routes to recovery '
        '(phase not clobbered by the terminal progress event)', () async {
      final coordinator = buildCoordinator(
        transport: _MidFlashErrorDfuTransport(),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      // The device engaged and was mid-flash when the error hit, so it may be
      // stranded in the bootloader — must route to recovery, NOT a clean failed
      // that would tell the user to just retry.
      expect(session.state, FirmwareUpdateState.recoveryRequired);
      expect(session.nativeTransferEngaged, isTrue);
      expect(session.requiresRecovery, isTrue);
    });

    test('e2e: a bootloader that rejects the image (requiresRecovery=false) '
        'reports failed, not recovery', () async {
      // The device received the image and its bootloader rejected it at
      // validation (Nordic remote "OPERATION FAILED"), then rebooted into the
      // running app — the native side reports requiresRecovery=false. Even
      // though the failure happened mid-transfer, the device is alive and NOT
      // stranded, so a forced re-flash would only fail to reconnect. Trust the
      // native verdict and report a plain, retryable failure.
      final coordinator = buildCoordinator(
        transport: _RejectedImageDfuTransport(),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );
      expect(session.nativeTransferEngaged, isTrue);
      expect(session.requiresRecovery, isFalse);

      expect(session.state, FirmwareUpdateState.failed);
      expect(session.failureCode, 'dfuFailed');
    });

    test(
      'e2e: a restore-hook failure does not mask a successful transfer',
      () async {
        final coordinator = buildCoordinator(
          transport: _SuccessfulDfuTransport(
            onStart: () {
              deviceRepository.setCurrentStatusSilently(
                _readyStatus(firmwareVersion: '2.0.0'),
              );
            },
          ),
          restoreBleAfterDfuTransfer: ({required String deviceId}) async {
            // BLE ownership reclaim throwing at the end of a good transfer must
            // not turn a completed update into a spurious recovery prompt.
            throw StateError('reclaim failed');
          },
          postDfuVerificationPollInterval: const Duration(milliseconds: 10),
        );
        addTearDown(coordinator.dispose);

        final session = await coordinator.startFirmwareUpdate(
          deviceId: 'demo-device',
          releaseId: 'fw-1',
        );

        expect(session.state, FirmwareUpdateState.completed);
        expect(session.failureCode, isNull);
      },
    );

    test(
      'migration recovery reuses the interrupted firmware session',
      () async {
        final original = _durableFirmwareSession(
          FirmwareUpdateState.transferring,
        );
        final coordinator = buildCoordinator(
          sessionStore: _MemoryFirmwareStore()..value = original,
          transport: _SuccessfulDfuTransport(),
        );
        addTearDown(coordinator.dispose);
        final recovered = await coordinator.recoverMigrationFirmwareUpdate(
          bootloaderDeviceId: original.deviceId,
          releaseId: original.releaseId,
          targetVersion: original.targetVersion,
        );
        expect(recovered.sessionId, original.sessionId);
        expect(recovered.startedAt, original.startedAt);
        expect(recovered.state, FirmwareUpdateState.reconnecting);
      },
    );

    for (final mismatch in ['device', 'release', 'version']) {
      test(
        'migration recovery rejects interrupted $mismatch mismatch',
        () async {
          final original = _durableFirmwareSession(
            FirmwareUpdateState.transferring,
          );
          final store = _MemoryFirmwareStore()..value = original;
          final coordinator = buildCoordinator(sessionStore: store);
          addTearDown(coordinator.dispose);
          await expectLater(
            coordinator.recoverMigrationFirmwareUpdate(
              bootloaderDeviceId: mismatch == 'device'
                  ? 'other'
                  : original.deviceId,
              releaseId: mismatch == 'release' ? 'other' : original.releaseId,
              targetVersion: mismatch == 'version'
                  ? '9.0.0'
                  : original.targetVersion,
            ),
            throwsA(isA<FirmwareUpdateException>()),
          );
          expect(store.value?.sessionId, original.sessionId);
          expect(store.value?.state, original.state);
        },
      );
    }

    test('restores every non-terminal OTA restart phase', () async {
      for (final state in <FirmwareUpdateState>[
        FirmwareUpdateState.readyToTransfer,
        FirmwareUpdateState.transferring,
        FirmwareUpdateState.reconnecting,
        FirmwareUpdateState.verifyingInstalledVersion,
        FirmwareUpdateState.recoveryRequired,
      ]) {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(state);
        final coordinator = buildCoordinator(sessionStore: store);

        expect((await coordinator.getActiveFirmwareUpdate())?.state, state);
        await coordinator.dispose();
      }
    });

    test(
      'restart completes only after matching device reports target',
      () async {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(FirmwareUpdateState.reconnecting);
        final coordinator = buildCoordinator(
          sessionStore: store,
          initialStatus: _readyStatus(firmwareVersion: '2.0.0'),
        );
        addTearDown(coordinator.dispose);

        final session = await coordinator.reconcileFirmwareUpdate();

        expect(session?.state, FirmwareUpdateState.completed);
        expect(session?.nextAction, FirmwareUpdateNextAction.completed);
        expect(store.value, isNull);
      },
    );

    test('restart reconnect with wrong version is not completed', () async {
      final store = _MemoryFirmwareStore()
        ..value = _durableFirmwareSession(
          FirmwareUpdateState.verifyingInstalledVersion,
        );
      final coordinator = buildCoordinator(sessionStore: store);
      addTearDown(coordinator.dispose);

      final session = await coordinator.reconcileFirmwareUpdate();

      expect(session?.state, FirmwareUpdateState.readyToTransfer);
      expect(
        session?.reconciliationOutcome,
        FirmwareUpdateReconciliationOutcome.installedVersionMismatch,
      );
      expect(session?.nextAction, FirmwareUpdateNextAction.retryDownload);
    });

    test('wrong connected physical device cannot satisfy update', () async {
      final store = _MemoryFirmwareStore()
        ..value = _durableFirmwareSession(FirmwareUpdateState.reconnecting);
      final coordinator = buildCoordinator(
        sessionStore: store,
        initialStatus: buildDeviceStatus(
          deviceId: 'wrong-device',
          canonicalHardwareId: '11:22:33:44:55:66',
          firmwareVersion: '2.0.0',
          connected: true,
        ),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.reconcileFirmwareUpdate();

      expect(
        session?.reconciliationOutcome,
        FirmwareUpdateReconciliationOutcome.wrongDevice,
      );
      expect(session?.state, isNot(FirmwareUpdateState.completed));
    });

    test('missing target preserves native recovery truth', () async {
      final store = _MemoryFirmwareStore()
        ..value = _durableFirmwareSession(
          FirmwareUpdateState.recoveryRequired,
          requiresRecovery: true,
        );
      final coordinator = buildCoordinator(
        sessionStore: store,
        initialStatus: _readyStatus(connected: false),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.reconcileFirmwareUpdate();

      expect(session?.state, FirmwareUpdateState.recoveryRequired);
      expect(session?.nextAction, FirmwareUpdateNextAction.waitForDevice);
    });

    for (final failures in [1, 3]) {
      test(
        'GATT 133: $failures failures release lifecycle before retry',
        () async {
          final store = _MemoryFirmwareStore()
            ..value = _durableFirmwareSession(
              FirmwareUpdateState.recoveryRequired,
            );
          final transport = _RetryingRecoveryTransport(failures);
          var releases = 0;
          var restores = 0;
          final coordinator = buildCoordinator(
            sessionStore: store,
            transport: transport,
            initialStatus: _readyStatus(connected: false),
            bleClient: _FirmwareBleClient([
              _dfuScan('bootloader', 'AA:BB:CC:DD:EE:FF'),
            ]),
            releaseBleForDfuTransfer: ({required deviceId}) async {
              expect(transport.active, isFalse);
              expect(transport.listeners, 1);
              expect(releases, restores);
              releases++;
            },
            restoreBleAfterDfuTransfer: ({required deviceId}) async {
              expect(transport.active, isFalse);
              expect(transport.listeners, 0);
              restores++;
            },
          );
          addTearDown(coordinator.dispose);
          final result = await coordinator.reconcileFirmwareUpdate(
            attemptRecovery: true,
          );
          expect(transport.starts, failures == 1 ? 2 : 3);
          expect(transport.ids.toSet().length, transport.starts);
          expect(releases, restores);
          expect(transport.listeners, 0);
          expect(result?.recoveryDeviceMatched, isTrue);
          expect(
            result?.nextAction,
            failures == 1
                ? FirmwareUpdateNextAction.waitForDevice
                : FirmwareUpdateNextAction.physicalRecovery,
          );
          expect(result?.manualRecoveryRequired, failures == 3);
          if (failures == 3) {
            await coordinator.reconcileFirmwareUpdate(attemptRecovery: true);
            expect(transport.starts, 3);
            expect(store.value?.remoteRecoveryExhausted, isTrue);
          }
        },
      );
    }

    test(
      'failed matched recovery then absence exhausts reconciliation, not identity',
      () async {
        final scans = [_dfuScan('bootloader', 'AA:BB:CC:DD:EE:FF')];
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(
            FirmwareUpdateState.recoveryRequired,
          );
        final transport = _RetryingRecoveryTransport(3, onFailure: scans.clear);
        final coordinator = buildCoordinator(
          sessionStore: store,
          transport: transport,
          initialStatus: _readyStatus(connected: false),
          bleClient: _FirmwareBleClient(scans),
        );
        addTearDown(coordinator.dispose);
        final result = await coordinator.reconcileFirmwareUpdate(
          attemptRecovery: true,
        );
        expect(transport.starts, 1);
        expect(result?.nextAction, FirmwareUpdateNextAction.physicalRecovery);
        expect(result?.recoveryReconciliationAttempts, 3);
        expect(result?.remoteRecoveryFailed, isTrue);
      },
    );

    test(
      'restart preserves exhausted verdict and does not duplicate recovery',
      () async {
        final store = _MemoryFirmwareStore()
          ..value =
              _durableFirmwareSession(
                FirmwareUpdateState.physicalRecoveryRequired,
              ).copyWith(
                recoveryDeviceMatched: true,
                remoteRecoveryAttempts: 3,
                remoteRecoveryFailed: true,
                remoteRecoveryExhausted: true,
                nextAction: FirmwareUpdateNextAction.physicalRecovery,
              );
        final transport = _RetryingRecoveryTransport(0);
        final coordinator = buildCoordinator(
          sessionStore: store,
          transport: transport,
          initialStatus: _readyStatus(connected: false),
          bleClient: _FirmwareBleClient([]),
        );
        addTearDown(coordinator.dispose);
        expect(
          (await coordinator.getActiveFirmwareUpdate())?.nextAction,
          FirmwareUpdateNextAction.physicalRecovery,
        );
        expect(
          (await coordinator.reconcileFirmwareUpdate(
            attemptRecovery: true,
          ))?.nextAction,
          FirmwareUpdateNextAction.physicalRecovery,
        );
        expect(transport.starts, 0);
        deviceRepository.setCurrentStatusSilently(
          _readyStatus(firmwareVersion: '2.0.0'),
        );
        expect(
          (await coordinator.reconcileFirmwareUpdate())?.state,
          FirmwareUpdateState.completed,
        );
      },
    );

    test(
      'same old valid application returns after manual recovery: safe retry',
      () async {
        final store = _MemoryFirmwareStore()
          ..value =
              _durableFirmwareSession(
                FirmwareUpdateState.physicalRecoveryRequired,
              ).copyWith(
                recoveryDeviceMatched: true,
                remoteRecoveryAttempts: 3,
                remoteRecoveryFailed: true,
                remoteRecoveryExhausted: true,
                artifactVerified: true,
                nextAction: FirmwareUpdateNextAction.physicalRecovery,
              );
        final coordinator = buildCoordinator(sessionStore: store);
        addTearDown(coordinator.dispose);
        final session = await coordinator.reconcileFirmwareUpdate();
        expect(session?.nextAction, FirmwareUpdateNextAction.retryTransfer);
        expect(session?.requiresRecovery, isFalse);
      },
    );

    test(
      'verified source retry clears the exhausted outcome before native transfer',
      () async {
        final store = _MemoryFirmwareStore()
          ..value =
              _durableFirmwareSession(
                FirmwareUpdateState.physicalRecoveryRequired,
              ).copyWith(
                recoveryDeviceMatched: true,
                remoteRecoveryAttempts: 3,
                remoteRecoveryFailed: true,
                remoteRecoveryExhausted: true,
                nextAction: FirmwareUpdateNextAction.physicalRecovery,
              );
        final coordinator = buildCoordinator(
          sessionStore: store,
          transport: _SuccessfulDfuTransport(
            onStart: () {
              expect(store.value?.remoteRecoveryExhausted, isFalse);
              expect(store.value?.remoteRecoveryFailed, isFalse);
              expect(store.value?.remoteRecoveryAttempts, 0);
            },
          ),
        );
        addTearDown(coordinator.dispose);
        final result = await coordinator.startMigrationFirmwareUpdate(
          sourceStatus: _readyStatus(),
          release: FirmwareRelease(
            releaseId: 'fw-1',
            version: '2.0.0',
            sha256Hash: sha256.convert([1, 2, 3]).toString(),
          ),
          postMigrationStatusRefresh:
              ({
                required deviceId,
                required attempt,
                required targetVersion,
              }) async => _readyStatus(firmwareVersion: '2.0.0'),
        );
        expect(result.state, FirmwareUpdateState.completed);
        expect(result.remoteRecoveryExhausted, isFalse);
      },
    );

    test(
      'wrong recovery advertisement cannot establish recovery capability',
      () async {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(
            FirmwareUpdateState.recoveryRequired,
          );
        final transport = _RetryingRecoveryTransport(3);
        final coordinator = buildCoordinator(
          sessionStore: store,
          transport: transport,
          initialStatus: _readyStatus(connected: false),
          bleClient: _FirmwareBleClient([
            _dfuScan('other', '11:22:33:44:55:66'),
          ]),
        );
        addTearDown(coordinator.dispose);
        final session = await coordinator.reconcileFirmwareUpdate(
          attemptRecovery: true,
        );
        expect(session?.nextAction, FirmwareUpdateNextAction.waitForDevice);
        expect(session?.manualRecoveryRequired, isFalse);
        expect(transport.starts, 0);
      },
    );

    test('multiple matching bootloaders remain ambiguous', () async {
      final store = _MemoryFirmwareStore()
        ..value = _durableFirmwareSession(
          FirmwareUpdateState.recoveryRequired,
          requiresRecovery: true,
        );
      final coordinator = buildCoordinator(
        sessionStore: store,
        initialStatus: _readyStatus(connected: false),
        bleClient: _FirmwareBleClient(<BleScanResult>[
          _dfuScan('bootloader-1', 'AA:BB:CC:DD:EE:FF'),
          _dfuScan('bootloader-2', 'AA:BB:CC:DD:EE:FF'),
        ]),
      );
      addTearDown(coordinator.dispose);

      final session = await coordinator.reconcileFirmwareUpdate(
        attemptRecovery: true,
      );

      expect(
        session?.reconciliationOutcome,
        FirmwareUpdateReconciliationOutcome.ambiguousCandidates,
      );
      expect(session?.state, isNot(FirmwareUpdateState.completed));
    });

    test(
      'matching bootloader recovery still waits for version verification',
      () async {
        final store = _MemoryFirmwareStore()
          ..value = _durableFirmwareSession(
            FirmwareUpdateState.recoveryRequired,
            requiresRecovery: true,
          );
        final coordinator = buildCoordinator(
          sessionStore: store,
          initialStatus: _readyStatus(connected: false),
          bleClient: _FirmwareBleClient(<BleScanResult>[
            _dfuScan('bootloader', 'AA:BB:CC:DD:EE:FF'),
          ]),
          transport: _SuccessfulDfuTransport(),
        );
        addTearDown(coordinator.dispose);

        final recovered = await coordinator.reconcileFirmwareUpdate(
          attemptRecovery: true,
        );

        expect(recovered?.state, FirmwareUpdateState.reconnecting);
        expect(recovered?.nextAction, FirmwareUpdateNextAction.waitForDevice);
        expect(recovered?.state, isNot(FirmwareUpdateState.completed));

        deviceRepository.setCurrentStatusSilently(
          _readyStatus(firmwareVersion: '2.0.0'),
        );
        final completed = await coordinator.reconcileFirmwareUpdate();
        expect(completed?.state, FirmwareUpdateState.completed);
      },
    );

    test('active OTA rejects a start for another physical device', () async {
      final store = _MemoryFirmwareStore()
        ..value = _durableFirmwareSession(FirmwareUpdateState.reconnecting);
      final coordinator = buildCoordinator(
        sessionStore: store,
        initialStatus: buildDeviceStatus(
          deviceId: 'other-device',
          canonicalHardwareId: '11:22:33:44:55:66',
          firmwareVersion: '1.0.0',
          connected: true,
        ),
      );
      addTearDown(coordinator.dispose);

      await expectLater(
        coordinator.startFirmwareUpdate(
          deviceId: 'other-device',
          releaseId: 'fw-1',
        ),
        throwsA(
          isA<FirmwareUpdateException>().having(
            (error) => error.code,
            'code',
            'firmwareUpdateActiveForAnotherDevice',
          ),
        ),
      );
      expect(store.value?.deviceId, 'demo-device');
    });
  });

  group('HttpSdkFirmwareRemoteDataSource artifact limits', () {
    test('rejects Content-Length above metadata before reading body', () async {
      var bodyRead = false;
      final body = StreamController<List<int>>.broadcast(
        onListen: () {
          bodyRead = true;
        },
      );
      addTearDown(body.close);
      final dataSource = _buildHttpFirmwareDataSource(
        _StreamingHttpClient(
          response: http.StreamedResponse(body.stream, 200, contentLength: 4),
        ),
      );

      await expectLater(
        dataSource.downloadArtifact(
          'https://example.test/fw.zip',
          expectedSizeBytes: 3,
        ),
        throwsA(
          isA<FirmwareUpdateException>().having(
            (error) => error.code,
            'code',
            firmwareArtifactTooLargeCode,
          ),
        ),
      );
      expect(bodyRead, isFalse);
    });

    test('rejects streamed body above metadata after reading', () async {
      final dataSource = _buildHttpFirmwareDataSource(
        _StreamingHttpClient(
          response: http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              <int>[1, 2],
              <int>[3],
            ]),
            200,
          ),
        ),
      );

      await expectLater(
        dataSource.downloadArtifact(
          'https://example.test/fw.zip',
          expectedSizeBytes: 2,
        ),
        throwsA(
          isA<FirmwareUpdateException>().having(
            (error) => error.code,
            'code',
            firmwareArtifactTooLargeCode,
          ),
        ),
      );
    });

    test('enforces hard cap when file size metadata is missing', () async {
      final dataSource = _buildHttpFirmwareDataSource(
        _StreamingHttpClient(
          response: http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              List<int>.filled(maxFirmwareArtifactBytes, 1),
              <int>[2],
            ]),
            200,
          ),
        ),
      );

      await expectLater(
        dataSource.downloadArtifact('https://example.test/fw.zip'),
        throwsA(
          isA<FirmwareUpdateException>().having(
            (error) => error.code,
            'code',
            firmwareArtifactTooLargeCode,
          ),
        ),
      );
    });
  });
}

DeviceStatus _readyStatus({
  String? firmwareVersion = '1.0.0',
  DeviceBatteryLevel? batteryState = DeviceBatteryLevel.ok,
  bool connected = true,
}) {
  return buildDeviceStatus(
    deviceId: 'demo-device',
    canonicalHardwareId: 'hw-demo',
    model: 'WISMESH_TAG',
    connected: connected,
    paired: true,
    activated: true,
    firmwareVersion: firmwareVersion,
    batteryState: batteryState,
    batteryLevel: batteryState?.protocolValue,
  );
}

FirmwareUpdateSession _durableFirmwareSession(
  FirmwareUpdateState state, {
  bool? requiresRecovery,
}) {
  final now = DateTime.utc(2026, 1, 1);
  return FirmwareUpdateSession(
    sessionId: 'fw-restored',
    deviceId: 'demo-device',
    hardwareId: 'AA:BB:CC:DD:EE:FF',
    releaseId: 'fw-1',
    fromVersion: '1.0.0',
    targetVersion: '2.0.0',
    state: state,
    startedAt: now,
    updatedAt: now,
    nativeTransferEngaged: state != FirmwareUpdateState.readyToTransfer,
    requiresRecovery:
        requiresRecovery ??
        (state == FirmwareUpdateState.recoveryRequired ||
            state == FirmwareUpdateState.physicalRecoveryRequired),
    nextAction: state == FirmwareUpdateState.recoveryRequired
        ? FirmwareUpdateNextAction.recover
        : FirmwareUpdateNextAction.waitForDevice,
  );
}

BleScanResult _dfuScan(String deviceId, String hardwareId) => BleScanResult(
  deviceId: deviceId,
  canonicalHardwareId: hardwareId,
  name: 'DfuTarg',
  rssi: -40,
  connectable: true,
  advertisedServiceUuids: const <String>['FE59'],
  discoveredAt: DateTime.now(),
);

final class _MemoryFirmwareStore implements FirmwareUpdateSessionStore {
  FirmwareUpdateSession? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<FirmwareUpdateSession?> load() async => value;

  @override
  Future<void> save(FirmwareUpdateSession session) async => value = session;
}

final class _FirmwareBleClient implements BleClient {
  _FirmwareBleClient(this.scans);

  final List<BleScanResult> scans;

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async => scans;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFirmwareRemoteDataSource implements SdkFirmwareRemoteDataSource {
  int checkCallCount = 0;
  int listCallCount = 0;
  int downloadCallCount = 0;
  bool lastAllowDowngrade = false;
  bool checkUpdateAvailable = true;
  String? lastCurrentVersion;
  String? lastTargetReleaseId;
  String releaseVersion = '2.0.0';
  List<SdkFirmwareDto> availableReleases = const <SdkFirmwareDto>[];
  List<int> artifactBytes = <int>[1, 2, 3];
  int? fileSizeBytes;
  String? downloadHash;
  Object? downloadError;
  Completer<List<int>>? downloadGate;

  @override
  Future<SdkFirmwareCheckDto> checkUpdate({
    required String? hardwareModel,
    required String currentVersion,
    bool allowDowngrade = false,
    String? targetReleaseId,
  }) async {
    checkCallCount++;
    lastAllowDowngrade = allowDowngrade;
    lastCurrentVersion = currentVersion;
    lastTargetReleaseId = targetReleaseId;
    if (!checkUpdateAvailable) {
      return const SdkFirmwareCheckDto(updateAvailable: false);
    }
    return SdkFirmwareCheckDto(
      updateAvailable: true,
      firmware: SdkFirmwareDto(
        id: 'fw-1',
        version: releaseVersion,
        hardwareModel: hardwareModel,
        sha256Hash: _sha256(artifactBytes),
        fileSizeBytes: fileSizeBytes ?? artifactBytes.length,
      ),
    );
  }

  @override
  Future<SdkFirmwareListDto> listReleases({
    required String? hardwareModel,
  }) async {
    listCallCount++;
    return SdkFirmwareListDto(firmwareVersions: availableReleases);
  }

  @override
  Future<SdkFirmwareDownloadDto> prepareDownload(String releaseId) async {
    return SdkFirmwareDownloadDto(
      downloadUrl: 'https://example.test/fw.zip',
      sha256Hash: downloadHash ?? _sha256(artifactBytes),
    );
  }

  @override
  Future<List<int>> downloadArtifact(
    String downloadUrl, {
    int? expectedSizeBytes,
    int maxSizeBytes = maxFirmwareArtifactBytes,
    int sizeToleranceBytes = firmwareArtifactSizeToleranceBytes,
  }) async {
    downloadCallCount++;
    if (downloadGate != null) return downloadGate!.future;
    final error = downloadError;
    if (error != null) {
      throw error;
    }
    return artifactBytes;
  }
}

class _SuccessfulDfuTransport implements FirmwareDfuTransport {
  _SuccessfulDfuTransport({this.onStart});

  final void Function()? onStart;

  @override
  Future<void> start(FirmwareDfuTransferRequest request) async {
    onStart?.call();
  }

  @override
  Stream<DfuProgress> watchProgress(String sessionId) {
    return Stream<DfuProgress>.value(
      const DfuProgress(
        state: FirmwareUpdateState.transferring,
        progressPercentage: 100,
      ),
    );
  }

  @override
  Future<void> cancel(String sessionId) async {}
}

class _FailingDfuTransport implements FirmwareDfuTransport {
  @override
  Future<void> start(FirmwareDfuTransferRequest request) async {
    throw const FirmwareUpdateException('dfuFailed', 'DFU failed.');
  }

  @override
  Stream<DfuProgress> watchProgress(String sessionId) =>
      const Stream<DfuProgress>.empty();

  @override
  Future<void> cancel(String sessionId) async {}
}

/// Emits a real upload event (engaging the device, past the point of no
/// return), THEN a terminal `failed` progress event — as a native `dfuError`
/// would arrive through watchProgress — and finally throws a non-recovery
/// error from start(). Models a mid-flash abort: the failed progress event must
/// NOT clobber the tracked `transferring` phase, so the outcome routes to
/// recoveryRequired (the device is stranded), not a clean `failed`.
class _MidFlashErrorDfuTransport implements FirmwareDfuTransport {
  final StreamController<DfuProgress> _events =
      StreamController<DfuProgress>.broadcast();

  @override
  Future<void> start(FirmwareDfuTransferRequest request) async {
    _events.add(
      const DfuProgress(
        state: FirmwareUpdateState.transferring,
        progressPercentage: 40,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    _events.add(const DfuProgress(state: FirmwareUpdateState.failed));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    throw const FirmwareUpdateException('dfuFailed', 'CRC error mid-flash.');
  }

  @override
  Stream<DfuProgress> watchProgress(String sessionId) => _events.stream;

  @override
  Future<void> cancel(String sessionId) async {}
}

/// Emits a real upload event (engaging the device, past the point of no
/// return), THEN throws with an explicit native verdict that the device does
/// NOT require recovery — the bootloader rejected the image and rebooted into
/// the running app. Models the real "OPERATION FAILED" at 0%: the outcome must
/// be a plain `failed`, never `recoveryRequired`.
class _RejectedImageDfuTransport implements FirmwareDfuTransport {
  final StreamController<DfuProgress> _events =
      StreamController<DfuProgress>.broadcast();

  @override
  Future<void> start(FirmwareDfuTransferRequest request) async {
    _events.add(
      const DfuProgress(
        state: FirmwareUpdateState.transferring,
        progressPercentage: 0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    throw const FirmwareUpdateException(
      'dfuFailed',
      'Device returned error after sending file (error 6): OPERATION FAILED',
      requiresRecovery: false,
    );
  }

  @override
  Stream<DfuProgress> watchProgress(String sessionId) => _events.stream;

  @override
  Future<void> cancel(String sessionId) async {}
}

/// Simulates a native DFU stuck in the bootloader-reconnect retry loop: an
/// endless alternation of connection-state events that never carries a
/// progress percentage, with a `start` future that never completes.
class _ChurnDfuTransport implements FirmwareDfuTransport {
  _ChurnDfuTransport({required this.tickInterval, this.emitEvents = true});

  final Duration tickInterval;

  /// When false the transport emits NO progress events at all — modelling a
  /// native start that hangs before ever engaging the device (bootloader never
  /// entered). Used to assert a stall in that state routes to `failed`, not
  /// `recoveryRequired`.
  final bool emitEvents;

  int cancelCount = 0;

  @override
  Future<void> start(FirmwareDfuTransferRequest request) {
    return Completer<void>().future;
  }

  @override
  Stream<DfuProgress> watchProgress(String sessionId) {
    if (!emitEvents) {
      return const Stream<DfuProgress>.empty();
    }
    return Stream<DfuProgress>.periodic(
      tickInterval,
      (tick) => DfuProgress(
        state: tick.isEven
            ? FirmwareUpdateState.transferring
            : FirmwareUpdateState.reconnecting,
      ),
    );
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancelCount += 1;
  }
}

/// Emits genuine upload percentages on a fixed cadence and completes after
/// [ticksToComplete] ticks.
class _SlowUploadDfuTransport implements FirmwareDfuTransport {
  _SlowUploadDfuTransport({
    required this.tickInterval,
    required this.ticksToComplete,
    this.onComplete,
  });

  final Duration tickInterval;
  final int ticksToComplete;
  final void Function()? onComplete;
  final StreamController<DfuProgress> _events =
      StreamController<DfuProgress>.broadcast();

  @override
  Future<void> start(FirmwareDfuTransferRequest request) async {
    for (var tick = 1; tick <= ticksToComplete; tick++) {
      await Future<void>.delayed(tickInterval);
      _events.add(
        DfuProgress(
          state: FirmwareUpdateState.transferring,
          progressPercentage: (tick * 100) ~/ ticksToComplete,
        ),
      );
    }
    onComplete?.call();
  }

  @override
  Stream<DfuProgress> watchProgress(String sessionId) => _events.stream;

  @override
  Future<void> cancel(String sessionId) async {}
}

HttpSdkFirmwareRemoteDataSource _buildHttpFirmwareDataSource(
  http.Client client,
) {
  return HttpSdkFirmwareRemoteDataSource(
    transport: SdkHttpTransport(
      client: client,
      config: const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
      sessionContext: SdkSessionContext(),
    ),
  );
}

final class _StreamingHttpClient extends http.BaseClient {
  _StreamingHttpClient({required this.response});

  final http.StreamedResponse response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return response;
  }
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

class _RetryingRecoveryTransport implements FirmwareDfuTransport {
  _RetryingRecoveryTransport(this.failures, {this.onFailure});
  final int failures;
  final void Function()? onFailure;
  int starts = 0;
  int listeners = 0;
  bool active = false;
  final ids = <String>[];

  @override
  Stream<DfuProgress> watchProgress(String sessionId) =>
      StreamController<DfuProgress>(
        onListen: () => listeners++,
        onCancel: () => listeners--,
      ).stream;

  @override
  Future<void> start(FirmwareDfuTransferRequest request) async {
    expect(active, isFalse);
    active = true;
    starts++;
    ids.add(request.sessionId);
    try {
      if (starts <= failures) {
        onFailure?.call();
        throw const FirmwareUpdateException('dfuTransportFailed', 'GATT 133');
      }
    } finally {
      active = false;
    }
  }

  @override
  Future<void> cancel(String sessionId) async {
    expect(active, isFalse);
  }
}
