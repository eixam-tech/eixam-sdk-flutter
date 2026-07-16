import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_firmware_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sdk_firmware_dto.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_dfu_transport.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_update_coordinator.dart';
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
  });

  group('FirmwareUpdateCoordinator', () {
    late FakeSosRepository sosRepository;
    late FakeDeathManRepository deathManRepository;
    late FakeDeviceRepository deviceRepository;
    late _FakeFirmwareRemoteDataSource remote;

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

    setUp(() {
      sosRepository = FakeSosRepository();
      deathManRepository = FakeDeathManRepository();
      remote = _FakeFirmwareRemoteDataSource();
    });

    tearDown(() async {
      await sosRepository.dispose();
      await deathManRepository.dispose();
      await deviceRepository.dispose();
    });

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
              _readyStatus(firmwareVersion: '  V2.0.0 '),
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

      expect(session.state, FirmwareUpdateState.completed);
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

    test('a stall with no native event at all reports failed, not recovery '
        '(device never entered the bootloader)', () async {
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

      expect(session.state, FirmwareUpdateState.failed);
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

    test('refuses cancel once the transfer phase has begun', () async {
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
        if (progress.state == FirmwareUpdateState.transferring &&
            !sessionIdSeen.isCompleted) {
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

      expect(session.state, FirmwareUpdateState.completed);
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

class _FakeFirmwareRemoteDataSource implements SdkFirmwareRemoteDataSource {
  int checkCallCount = 0;
  int downloadCallCount = 0;
  bool lastAllowDowngrade = false;
  String? lastCurrentVersion;
  String? lastTargetReleaseId;
  String releaseVersion = '2.0.0';
  List<SdkFirmwareDto> availableReleases = const <SdkFirmwareDto>[];
  List<int> artifactBytes = <int>[1, 2, 3];
  int? fileSizeBytes;
  String? downloadHash;
  Object? downloadError;

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
