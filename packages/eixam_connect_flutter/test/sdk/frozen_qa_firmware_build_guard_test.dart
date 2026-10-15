import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_artifact_cache.dart';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_firmware_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/sdk/frozen_qa_firmware_source.dart';
import 'package:flutter_test/flutter_test.dart';

class _NormalSource extends SdkFirmwareRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'compiled composition requires explicitly enabled debug physical QA',
    () async {
      final normal = _NormalSource();
      final source = composeFirmwareSource(normal);
      const expectCandidate = bool.fromEnvironment('EIXAM_EXPECT_QA_CATALOG');
      if (!expectCandidate) {
        expect(source, same(normal));
        return;
      }
      expect(source, isA<FrozenQaFirmwareSource>());
      const model = String.fromEnvironment('EIXAM_QA_FIRMWARE_MODEL');
      const version = String.fromEnvironment('EIXAM_QA_FIRMWARE_VERSION');
      const hash = String.fromEnvironment('EIXAM_QA_FIRMWARE_ZIP_SHA256');
      final releases = await source.listReleases(hardwareModel: model);
      expect(releases.firmwareVersions, hasLength(1));
      final release = releases.firmwareVersions.single.toDomain();
      expect(release.version, version);
      expect(
        release.verificationPolicy,
        FirmwareVerificationPolicy.exactCandidate,
      );
      final download = await source.prepareDownload(release.releaseId);
      expect(download.sha256Hash, hash);
      const path = String.fromEnvironment('EIXAM_QA_TEST_ZIP_PATH');
      final bytes = await File(path).readAsBytes();
      final directory = await Directory.systemTemp.createTemp('qa-cache-');
      addTearDown(() => directory.delete(recursive: true));
      final cache = FileFirmwareArtifactCache(
        directoryProvider: () async => directory,
      );
      final reference = firmwareArtifactReference(
        release.releaseId,
        version,
        hash,
      );
      await cache.writeVerified(reference, bytes);
      expect(
        await cache.readVerified(reference, hash, release.fileSizeBytes),
        bytes,
      );
      await cache.writeVerified(reference, [9, 8, 7]);
      expect(
        await cache.readVerified(reference, hash, release.fileSizeBytes),
        isNull,
      );
      expect(sha256.convert(bytes).toString(), hash);
      expect(bytes.length, release.fileSizeBytes);
    },
  );
}
