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

    test('fails at transfer boundary when native DFU is not implemented',
        () async {
      final coordinator = buildCoordinator();
      addTearDown(coordinator.dispose);

      final session = await coordinator.startFirmwareUpdate(
        deviceId: 'demo-device',
        releaseId: 'fw-1',
      );

      expect(session.state, FirmwareUpdateState.failed);
      expect(session.failureCode, UnsupportedFirmwareDfuTransport.failureCode);
    });

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

    test('completes only after installed firmware version matches target',
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
          response: http.StreamedResponse(
            body.stream,
            200,
            contentLength: 4,
          ),
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
}) {
  return buildDeviceStatus(
    deviceId: 'demo-device',
    canonicalHardwareId: 'hw-demo',
    model: 'WISMESH_TAG',
    connected: true,
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
  List<int> artifactBytes = <int>[1, 2, 3];
  int? fileSizeBytes;
  String? downloadHash;
  Object? downloadError;

  @override
  Future<SdkFirmwareCheckDto> checkUpdate({
    required String? hardwareModel,
    required String currentVersion,
  }) async {
    checkCallCount++;
    return SdkFirmwareCheckDto(
      updateAvailable: true,
      firmware: SdkFirmwareDto(
        id: 'fw-1',
        version: '2.0.0',
        hardwareModel: hardwareModel,
        sha256Hash: _sha256(artifactBytes),
        fileSizeBytes: fileSizeBytes ?? artifactBytes.length,
      ),
    );
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
