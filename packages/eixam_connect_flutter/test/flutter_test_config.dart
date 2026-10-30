import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Host tests use real SQLite in an isolate-private temporary directory; no
/// mobile plugin channels, user databases or other repositories are touched.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  final directory = await Directory.systemTemp.createTemp('eixam-sdk-test-');
  PathProviderPlatform.instance = _TestPaths(directory.path);
  const recordingStorage = MethodChannel(
    'dev.eixam.connect.flutter/activity_recording_storage',
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(recordingStorage, (call) async {
        if (call.method != 'prepare') throw MissingPluginException();
        return (await Directory(
          '${directory.path}/eixam/activity_recordings',
        ).create(recursive: true)).path;
      });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordingStorage, null);
    await directory.delete(recursive: true);
  });
  await testMain();
}

final class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
