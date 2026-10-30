import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_database.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_storage_directory.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'recording_test_support.dart';

void main() {
  const channel = MethodChannel('test.eixam/activity_recording_storage');
  const preparer = ActivityRecordingStorageDirectory(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('ar2bp1-'));
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test(
    'uses the native prepared directory before real SQLite creation',
    () async {
      final leaf = await Directory(
        '${root.path}/no_backup/eixam/activity_recordings',
      ).create(recursive: true);
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'prepare');
        expect(call.arguments, isNull);
        calls++;
        return leaf.path;
      });
      final store = ActivityRecordingDatabase(
        factory: databaseFactoryFfiNoIsolate,
        storageDirectory: preparer,
      );
      try {
        final owner = ActivityRecordingOwner.forIdentity(
          'https://sdk.test',
          recordingUserA,
        );
        await store.transaction((tx) => tx.reconcileOwner(owner));
        expect(calls, 1);
        expect(await File('${leaf.path}/recordings.sqlite').exists(), isTrue);
        expect(
          await File(
            '${root.path}/files/eixam/activity_recordings/recordings.sqlite',
          ).exists(),
          isFalse,
        );
        await store.transaction((tx) => tx.active(owner.scope));
        expect(calls, 1); // Connection is already open in this runtime.
      } finally {
        await store.dispose();
      }
      final reopened = ActivityRecordingDatabase(
        factory: databaseFactoryFfiNoIsolate,
        storageDirectory: preparer,
      );
      await reopened.transaction((tx) => tx.active('unknown'));
      expect(calls, 2);
      await reopened.dispose();
    },
  );

  test(
    'native privacy failure opens no SQLite and exposes no OS payload',
    () async {
      final legacy = await File(
        '${root.path}/files/eixam/activity_recordings/recordings.sqlite',
      ).create(recursive: true);
      await legacy.writeAsString('preserved evidence');
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'native_failure',
          message: '/private/user/path and identity payload',
        );
      });
      final factory = _CountingFactory();
      final store = ActivityRecordingDatabase(
        factory: factory,
        storageDirectory: preparer,
      );
      try {
        await expectLater(
          store.transaction((tx) => tx.active('unknown')),
          throwsA(
            isA<ActivityRecordingException>()
                .having((e) => e.code, 'code', 'E_RECORDING_PERSISTENCE_FAILED')
                .having(
                  (Object? e) => e.toString(),
                  'sanitized',
                  isNot(contains('/private/user/path')),
                ),
          ),
        );
        expect(factory.opens, 0);
        expect(await legacy.readAsString(), 'preserved evidence');
      } finally {
        await store.dispose();
      }
    },
  );

  test('missing native plugin has no backup-eligible fallback', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException(),
    );
    await expectLater(
      preparer.prepare(),
      throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
    );
  });

  for (final invalid in [
    null,
    '',
    'relative/directory',
    '/does/not/exist/ar2bp1',
  ]) {
    test('invalid prepared directory fails closed: $invalid', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => invalid);
      final factory = _CountingFactory();
      final store = ActivityRecordingDatabase(
        factory: factory,
        storageDirectory: preparer,
      );
      await expectLater(
        store.transaction((tx) => tx.active('unknown')),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      expect(factory.opens, 0);
      await store.dispose();
    });
  }

  test(
    'runtime container roots are recomputed and never persisted as identity',
    () async {
      final first = await Directory(
        '${root.path}/container-a/eixam/activity_recordings',
      ).create(recursive: true);
      final second = await Directory(
        '${root.path}/container-b/eixam/activity_recordings',
      ).create(recursive: true);
      var current = first.path;
      messenger.setMockMethodCallHandler(channel, (_) async => current);
      expect((await preparer.prepare()).path, first.path);
      current = second.path;
      expect((await preparer.prepare()).path, second.path);
    },
  );
}

final class _CountingFactory implements DatabaseFactory {
  int opens = 0;
  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    opens++;
    throw StateError('SQLite must not open on preparation failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
