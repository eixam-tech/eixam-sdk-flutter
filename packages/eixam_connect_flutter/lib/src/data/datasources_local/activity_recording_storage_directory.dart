import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';

/// Private native readiness boundary. There is deliberately no fallback to
/// ordinary files, Documents or cache when privacy preparation fails.
final class ActivityRecordingStorageDirectory {
  const ActivityRecordingStorageDirectory({
    MethodChannel channel = const MethodChannel(
      'dev.eixam.connect.flutter/activity_recording_storage',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<Directory> prepare() async {
    try {
      final path = await _channel.invokeMethod<String>('prepare');
      if (path == null || path.isEmpty) throw const FormatException();
      final directory = Directory(path);
      if (!directory.isAbsolute || !await directory.exists()) {
        throw const FormatException();
      }
      return directory;
    } catch (_) {
      // Native errors can contain OS paths. Never forward their payloads.
      throw const ActivityRecordingException(
        'E_RECORDING_PERSISTENCE_FAILED',
        'Recording storage privacy preparation failed.',
      );
    }
  }
}
