import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:eixam_connect_flutter/src/sdk/firmware_artifact_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late FileFirmwareArtifactCache cache;
  final bytes = [1, 2, 3];
  final hash = sha256.convert(bytes).toString();
  final reference = firmwareArtifactReference('release', '2.0.0', hash);

  setUp(() {
    directory = Directory.systemTemp.createTempSync('firmware-cache-test-');
    cache = FileFirmwareArtifactCache(directoryProvider: () async => directory);
  });
  tearDown(() => directory.delete(recursive: true));

  test('missing artifact requires download', () async {
    expect(await cache.readVerified(reference, hash, 3), isNull);
  });
  test(
    'atomic complete artifact is reusable by a fresh cache instance',
    () async {
      await cache.writeVerified(reference, bytes);
      final restored = FileFirmwareArtifactCache(
        directoryProvider: () async => directory,
      );
      expect(await restored.readVerified(reference, hash, 3), bytes);
      expect(
        File('${directory.path}/$reference.zip.partial').existsSync(),
        false,
      );
    },
  );
  test(
    'process death during write discards partial and restarts download',
    () async {
      final partial = File('${directory.path}/$reference.zip.partial');
      await partial.writeAsBytes([1, 2]);
      expect(await cache.readVerified(reference, hash, 3), isNull);
      expect(await partial.exists(), false);
    },
  );
  test('complete corrupt artifact is removed', () async {
    await cache.writeVerified(reference, [9, 2, 3]);
    expect(await cache.readVerified(reference, hash, 3), isNull);
    expect(File('${directory.path}/$reference.zip').existsSync(), false);
  });
  test('wrong size is removed before loading into memory', () async {
    await cache.writeVerified(reference, bytes);
    expect(await cache.readVerified(reference, hash, 4), isNull);
  });
  test('wrong hash cannot satisfy cache integrity', () async {
    await cache.writeVerified(reference, bytes);
    expect(
      await cache.readVerified(reference, sha256.convert([9]).toString(), 3),
      isNull,
    );
  });
  test('changed release or target cannot reuse stale firmware', () async {
    await cache.writeVerified(reference, bytes);
    expect(
      await cache.readVerified(
        firmwareArtifactReference('other', '2.0.0', hash),
        hash,
        3,
      ),
      isNull,
    );
    expect(
      await cache.readVerified(
        firmwareArtifactReference('release', '3.0.0', hash),
        hash,
        3,
      ),
      isNull,
    );
  });
  test('persisted reference cannot escape SDK cache directory', () async {
    await expectLater(
      cache.readVerified('../outside', hash, 3),
      throwsFormatException,
    );
  });
}
