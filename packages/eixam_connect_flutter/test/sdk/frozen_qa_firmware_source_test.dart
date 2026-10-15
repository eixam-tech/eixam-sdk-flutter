import 'package:crypto/crypto.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_firmware_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sdk_firmware_dto.dart';
import 'package:eixam_connect_flutter/src/sdk/frozen_qa_firmware_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  test('normal composition keeps the remote catalog by default', () {
    final client = http.Client();
    addTearDown(client.close);
    final normal = HttpSdkFirmwareRemoteDataSource(
      transport: SdkHttpTransport(
        client: client,
        config: const EixamSdkConfig(
          apiBaseUrl: 'https://example.com',
          websocketUrl: 'wss://example.com',
        ),
        sessionContext: SdkSessionContext(),
      ),
    );
    expect(composeFirmwareSource(normal), same(normal));
  });

  test('release/profile and normal staging cannot enable QA candidate', () {
    for (final debug in [false, true]) {
      for (final physicalQa in [false, true]) {
        for (final enabled in [false, true]) {
          expect(
            frozenQaFirmwareEnabled(
              debugBuild: debug,
              physicalQa: physicalQa,
              candidateEnabled: enabled,
            ),
            debug && physicalQa && enabled,
          );
        }
      }
    }
  });

  test('remote JSON cannot opt normal releases into exact QA policy', () {
    final dto = SdkFirmwareDto.fromJson({
      'id': 'normal',
      'version': '3.0.0',
      'verificationPolicy': 'exactCandidate',
    });
    expect(
      dto.toDomain().verificationPolicy,
      FirmwareVerificationPolicy.normal,
    );
  });

  test(
    'one frozen candidate, model restriction, exact policy and bytes',
    () async {
      final bytes = [1, 2, 3];
      final source = FrozenQaFirmwareSource(
        sourceSha: 'a' * 40,
        expectedLiveVersion: '3.0.0.abc1234',
        hardwareModel: 'EIXAM R1',
        artifactSha256: sha256.convert(bytes).toString(),
        artifactSizeBytes: bytes.length,
      );
      bytes[0] = 9;
      final releases = await source.listReleases(hardwareModel: 'EIXAM R1');
      expect(releases.firmwareVersions, hasLength(1));
      expect(
        releases.firmwareVersions.single.toDomain().verificationPolicy,
        FirmwareVerificationPolicy.exactCandidate,
      );
      expect(
        (await source.listReleases(hardwareModel: 'other')).firmwareVersions,
        isEmpty,
      );
      expect(
        (await source.listReleases(hardwareModel: null)).firmwareVersions,
        isEmpty,
      );
      final download = await source.prepareDownload(source.release.id);
      expect(download.sha256Hash, sha256.convert([1, 2, 3]).toString());
      expect(source.release.fileSizeBytes, 3);
      await expectLater(
        source.downloadArtifact(download.downloadUrl),
        throwsA(isA<FirmwareUpdateException>()),
      );
    },
  );
}
