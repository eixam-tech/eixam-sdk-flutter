import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
  try {
    await testMain();
  } finally {
    await directory.delete(recursive: true);
  }
}

final class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
