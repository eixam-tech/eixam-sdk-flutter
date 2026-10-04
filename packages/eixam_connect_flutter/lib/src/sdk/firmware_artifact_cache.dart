import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../data/datasources_remote/sdk_firmware_remote_data_source.dart';

/// A cache reference is a content key, never an arbitrary host-provided path.
abstract interface class FirmwareArtifactCache {
  Future<List<int>?> readVerified(String reference, String hash, int? size);
  Future<void> writeVerified(String reference, List<int> bytes);
  Future<void> remove(String reference);
}

String firmwareArtifactReference(
  String releaseId,
  String version,
  String hash,
) => sha256
    .convert(utf8.encode('$releaseId\n$version\n${hash.toLowerCase()}'))
    .toString();

/// Files are published atomically; interrupted writes are never reusable.
final class FileFirmwareArtifactCache implements FirmwareArtifactCache {
  FileFirmwareArtifactCache({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? _nativeDirectory;

  final Future<Directory> Function() _directoryProvider;
  static const _channel = MethodChannel(
    'dev.eixam.connect_flutter/firmware_dfu/methods',
  );

  static Future<Directory> _nativeDirectory() async {
    final path = await _channel.invokeMethod<String>(
      'firmwareArtifactCacheDirectory',
    );
    if (path == null || path.isEmpty) {
      throw const FileSystemException('Firmware cache unavailable');
    }
    return Directory(path);
  }

  Future<File> _file(String reference) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(reference)) {
      throw const FormatException('Invalid firmware cache reference');
    }
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    return File('${directory.path}/$reference.zip');
  }

  @override
  Future<List<int>?> readVerified(
    String reference,
    String hash,
    int? size,
  ) async {
    final file = await _file(reference);
    final partial = File('${file.path}.partial');
    if (await partial.exists()) await partial.delete();
    if (!await file.exists()) return null;
    final length = await file.length();
    if (length <= 0 ||
        length > maxFirmwareArtifactBytes ||
        (size != null && length != size)) {
      await file.delete();
      return null;
    }
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != hash.trim().toLowerCase()) {
      await file.delete();
      return null;
    }
    return bytes;
  }

  @override
  Future<void> writeVerified(String reference, List<int> bytes) async {
    final file = await _file(reference);
    final partial = File('${file.path}.partial');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(file.path);
  }

  @override
  Future<void> remove(String reference) async {
    final file = await _file(reference);
    for (final candidate in [file, File('${file.path}.partial')]) {
      if (await candidate.exists()) await candidate.delete();
    }
  }
}
