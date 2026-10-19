import 'dart:async';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_database.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_record.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'recording_test_support.dart';

void main() {
  late RecordingFixture f;
  setUp(() async => f = await RecordingFixture.create());
  tearDown(() async => f.delete());

  Future<void> reopen({EixamSession user = recordingUserA}) async {
    final directory = f.directory;
    final sessions = f.sessionStore;
    await f.dispose();
    f = await RecordingFixture.create(
      directory: directory,
      sessionStore: sessions,
      user: user,
    );
  }

  test(
    'active bound metadata restores identically without device evidence',
    () async {
      final original = await f.start(device: tagA);
      await reopen();
      f.verified.clear();
      final restored = await f.controller.getActiveActivityRecording();
      expect(snapshot(restored!), snapshot(original));
      expect(f.verifyCalls, 0);
      expect(snapshot(await f.start()), snapshot(original));
    },
  );

  test(
    'finished A B C survive reconstruction with distinct immutable metadata',
    () async {
      final finished = <SdkActivityRecording>[];
      for (final key in [
        'mountain',
        'org.example.paddle',
        'org.example.walk',
      ]) {
        final session = await f.logicalStart(key);
        final r = await f.controller.startActivityRecording(
          activitySession: session,
        );
        f.now = f.now.add(const Duration(minutes: 1));
        finished.add(
          await f.controller.finishActivityRecording(
            recordingId: r.recordingId,
          ),
        );
        await f.sessions.endActivitySession(sessionId: session.sessionId);
      }
      expect(finished.map((r) => r.recordingId).toSet(), hasLength(3));
      await reopen();
      expect(await f.controller.getActiveActivityRecording(), isNull);
      for (final original in finished) {
        final restored = await f.controller.getActivityRecording(
          recordingId: original.recordingId,
        );
        expect(snapshot(restored!), snapshot(original));
        expect(
          snapshot(
            await f.controller.finishActivityRecording(
              recordingId: original.recordingId,
            ),
          ),
          snapshot(original),
        );
      }
    },
  );

  test(
    'crash after finalizing commit resumes frozen cutoff on reconstruction',
    () async {
      final original = await f.start();
      f.now = f.now.add(const Duration(minutes: 2));
      final cutoff = f.now;
      f.store.failPhase = ActivityRecordingPhase.finished;
      await expectLater(
        f.controller.finishActivityRecording(recordingId: original.recordingId),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      final pending = await f.controller.getActivityRecording(
        recordingId: original.recordingId,
      );
      expect(pending?.phase, ActivityRecordingPhase.finalizing);
      expect(pending?.endedAt, cutoff);
      await reopen();
      f.now = f.now.add(const Duration(days: 3));
      expect(await f.controller.getActiveActivityRecording(), isNull);
      final result = await f.controller.getActivityRecording(
        recordingId: original.recordingId,
      );
      expect(result?.phase, ActivityRecordingPhase.finished);
      expect(result?.endedAt, cutoff);
    },
  );

  test(
    'finalizing retry rejects changed cutoff and preserves intent',
    () async {
      final r = await f.start();
      f.store.failPhase = ActivityRecordingPhase.finished;
      await expectLater(
        f.controller.finishActivityRecording(recordingId: r.recordingId),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      f.store.failPhase = null;
      f.now = f.now.add(const Duration(minutes: 1));
      await expectLater(
        f.controller.finishActivityRecording(
          recordingId: r.recordingId,
          endedAt: f.now,
        ),
        throwsA(recordingError('E_RECORDING_INVALID_TIME')),
      );
      expect(
        (await f.controller.finishActivityRecording(
          recordingId: r.recordingId,
        )).endedAt,
        r.recordingStartedAt,
      );
    },
  );

  for (final kind in ['account', 'logout', 'app', 'backend', 'canonical']) {
    test(
      '$kind replacement purges active finished points gaps and metadata',
      () async {
        final old = await f.start();
        await f.controller.finishActivityRecording(
          recordingId: old.recordingId,
        );
        await f.sessions.endActivitySession(sessionId: old.activitySessionId);
        await f.start();
        final raw = await f.raw();
        await raw.insert('route_points', {
          'recording_id': old.recordingId,
          'sample_key': 'test',
          'sampled_at': f.now.toIso8601String(),
          'latitude': 1.0,
          'longitude': 2.0,
          'delivery': 'live',
          'segment_id': 'test',
        });
        await raw.insert('route_gaps', {
          'gap_id': 'test',
          'recording_id': old.recordingId,
          'from_time': f.now.toIso8601String(),
          'reason': 'test',
          'state': 'test',
        });
        if (kind == 'backend') f.backend = 'https://other.test';
        final next = switch (kind) {
          'logout' => null,
          'app' => recordingUserA.copyWith(appId: 'different-app'),
          'canonical' => recordingUserA.copyWith(
            sdkUserId: 'different-canonical',
          ),
          'backend' => recordingUserA,
          _ => recordingUserB,
        };
        await f.bind(next, clear: kind == 'logout');
        for (final table in [
          'recordings',
          'route_points',
          'route_gaps',
          'recording_store_metadata',
        ]) {
          expect(await raw.query(table), isEmpty, reason: table);
        }
        await raw.close();
        if (next != null) {
          expect(
            await f.controller.getActivityRecording(
              recordingId: old.recordingId,
            ),
            isNull,
          );
          await expectLater(
            f.controller.bindActivityRecordingDevice(
              recordingId: old.recordingId,
              deviceIdentity: tagA,
            ),
            throwsA(recordingError('E_RECORDING_NOT_FOUND')),
          );
        } else {
          await expectLater(
            f.controller.getActivityRecording(recordingId: old.recordingId),
            throwsA(recordingError('E_RECORDING_IDENTITY_REQUIRED')),
          );
        }
      },
    );
  }

  test(
    'signing rotation and missing canonical snapshot preserve same principal',
    () async {
      final original = await f.start(device: tagA);
      await f.bind(recordingUserA.copyWith(userHash: 'rotated'));
      expect(
        snapshot((await f.controller.getActiveActivityRecording())!),
        snapshot(original),
      );
      await reopen(
        user: recordingUserA.copyWith(
          sdkUserId: null,
          canonicalExternalUserId: null,
          userHash: 'new-signature',
        ),
      );
      expect(
        snapshot((await f.controller.getActiveActivityRecording())!),
        snapshot(original),
      );
    },
  );

  test(
    'persisted canonical conflict purges then quarantines until trusted bind',
    () async {
      final original = await f.start();
      await reopen(user: recordingUserA.copyWith(sdkUserId: 'contradictory'));
      await expectLater(
        f.controller.getActiveActivityRecording(),
        throwsA(recordingError('E_RECORDING_IDENTITY_REQUIRED')),
      );
      await expectLater(
        f.controller.getActivityRecording(recordingId: original.recordingId),
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      final raw = await f.raw();
      expect(await raw.query('recordings'), isEmpty);
      await raw.close();
    },
  );

  test(
    'new scope without canonical IDs never borrows old owner evidence',
    () async {
      await f.start();
      final owner = ActivityRecordingOwner.forIdentity(
        f.backend,
        recordingUserB.copyWith(sdkUserId: null, canonicalExternalUserId: null),
      );
      await f.database.transaction((tx) => tx.reconcileOwner(owner));
      final raw = await f.raw();
      final metadata = (await raw.query('recording_store_metadata')).single;
      expect(metadata['owner_scope'], owner.scope);
      expect(metadata['sdk_user_id'], isNull);
      expect(metadata['canonical_user_id'], isNull);
      expect(await raw.query('recordings'), isEmpty);
      await raw.close();
    },
  );

  test(
    'cleanup failure quarantines all reads until purge retry commits',
    () async {
      final r = await f.start();
      f.store.failClear = true;
      await expectLater(
        f.bind(recordingUserB),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      await expectLater(
        f.controller.getActivityRecording(recordingId: r.recordingId),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      f.store.failClear = false;
      expect(
        await f.controller.getActivityRecording(recordingId: r.recordingId),
        isNull,
      );
      expect(await f.controller.getActiveActivityRecording(), isNull);
    },
  );

  test(
    'identity fence rolls back delayed write and suppresses paused old events',
    () async {
      final r = await f.start();
      final seen = <SdkActivityRecording?>[];
      final errors = <Object>[];
      final sub = f.controller.watchActiveActivityRecording().listen(
        seen.add,
        onError: errors.add,
      );
      await pumpEventQueue();
      sub.pause();
      f.store.writeGate = Completer<void>();
      f.store.writeEntered = Completer<void>();
      final gate = f.store.writeGate!;
      final binding = f.controller.bindActivityRecordingDevice(
        recordingId: r.recordingId,
        deviceIdentity: tagA,
      );
      final rejected = expectLater(
        binding,
        throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
      );
      await f.store.writeEntered!.future;
      final replacement = f.bind(recordingUserB);
      gate.complete();
      await rejected;
      await replacement;
      seen.clear();
      sub.resume();
      await pumpEventQueue();
      expect(seen, [null]);
      expect(errors, isEmpty);
      expect(
        await f.controller.getActivityRecording(recordingId: r.recordingId),
        isNull,
      );
      await sub.cancel();
    },
  );

  test('late old device verifier cannot bind into new identity', () async {
    final r = await f.start();
    f.verifyGate = Completer<void>();
    final pending = f.controller.bindActivityRecordingDevice(
      recordingId: r.recordingId,
      deviceIdentity: tagA,
    );
    final rejected = expectLater(
      pending,
      throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
    );
    await pumpEventQueue();
    final replacement = f.bind(recordingUserB);
    f.verifyGate!.complete();
    await rejected;
    await replacement;
    expect(
      await f.controller.getActivityRecording(recordingId: r.recordingId),
      isNull,
    );
  });

  test(
    'one writer lease rejects competing controller and transfers on dispose',
    () async {
      final r = await f.start();
      final other = await RecordingFixture.create(directory: f.directory);
      try {
        await expectLater(
          other.controller.getActiveActivityRecording(),
          throwsA(recordingError('E_RECORDING_UNAVAILABLE')),
        );
        await f.dispose();
        expect(
          (await other.controller.getActivityRecording(
            recordingId: r.recordingId,
          ))?.recordingId,
          r.recordingId,
        );
      } finally {
        await other.dispose();
      }
    },
  );

  for (final operation in ['start', 'bind', 'finish']) {
    test(
      '$operation retry reconciles watchers after ambiguous commit acknowledgement',
      () async {
        SdkActivityRecording? original;
        if (operation != 'start') original = await f.start();
        final seen = <SdkActivityRecording?>[];
        final sub = f.controller.watchActiveActivityRecording().listen(
          seen.add,
        );
        await pumpEventQueue();
        Future<SdkActivityRecording> command() => switch (operation) {
          'start' => f.start(),
          'bind' => f.controller.bindActivityRecordingDevice(
            recordingId: original!.recordingId,
            deviceIdentity: tagA,
          ),
          _ => f.controller.finishActivityRecording(
            recordingId: original!.recordingId,
          ),
        };
        // Lose the FINAL finished acknowledgement rather than the first cutoff.
        if (operation == 'finish') {
          f.store.failPhase = ActivityRecordingPhase.finished;
          await expectLater(
            command(),
            throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
          );
          f.store.failPhase = null;
        }
        f.store.loseNextWriteAcknowledgement = true;
        await expectLater(
          command(),
          throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
        );
        final result = await command();
        await pumpEventQueue();
        if (operation == 'finish') {
          expect(seen.last, isNull);
        } else {
          expect(snapshot(seen.last!), snapshot(result));
        }
        await sub.cancel();
      },
    );
  }

  for (final mutation in <String, Object?>{
    'input_state': 'invalid',
    'recovery_state': 'invalid-recovery-state',
    'activity_session_id': '',
    'activity_key': 'INVALID KEY',
    'session_started_at': 'not-a-date',
    'issues': '["unknown"]',
    'device_identity': 'not-canonical',
    'point_count': 1,
  }.entries) {
    test(
      'malformed ${mutation.key} fails closed without deleting evidence',
      () async {
        final r = await f.start();
        final raw = await f.raw();
        await raw.update('recordings', {mutation.key: mutation.value});
        await raw.close();
        await reopen();
        await expectLater(
          f.controller.getActiveActivityRecording(),
          throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
        );
        final evidence = await f.raw();
        expect(
          (await evidence.query('recordings')).single['recording_id'],
          r.recordingId,
        );
        await evidence.close();
      },
    );
  }

  test('unknown phase cannot masquerade as authoritative absence', () async {
    await f.start();
    final raw = await f.raw();
    await raw.execute('PRAGMA ignore_check_constraints = ON');
    await raw.update('recordings', {'phase': 'unknown'});
    await raw.close();
    await reopen();
    await expectLater(
      f.controller.getActiveActivityRecording(),
      throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
    );
  });

  test(
    'SQL unique index and corrupt duplicate active rows both fail closed',
    () async {
      await f.start();
      final raw = await f.raw();
      final duplicate =
          Map<String, Object?>.from((await raw.query('recordings')).single)
            ..['recording_id'] = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
            ..['activity_session_id'] = 'different-session';
      await expectLater(
        raw.insert('recordings', duplicate),
        throwsA(isA<DatabaseException>()),
      );
      await raw.execute('DROP INDEX recording_one_active');
      await raw.insert('recordings', duplicate);
      await raw.close();
      await reopen();
      await expectLater(
        f.controller.getActiveActivityRecording(),
        throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
      );
    },
  );

  test('unsupported future schema preserves file and version', () async {
    await f.start();
    final raw = await f.raw();
    await raw.setVersion(99);
    await raw.close();
    await reopen();
    await expectLater(
      f.controller.getActiveActivityRecording(),
      throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
    );
    final evidence = await f.raw();
    expect(await evidence.getVersion(), 99);
    expect(await evidence.query('recordings'), hasLength(1));
    await evidence.close();
  });

  test(
    'unreadable DB bytes are preserved and never treated as absence',
    () async {
      await f.dispose();
      final file = File(f.path);
      await file.writeAsString('corrupt sqlite evidence');
      await reopen();
      await expectLater(
        f.controller.getActiveActivityRecording(),
        throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
      );
      expect(await file.readAsString(), 'corrupt sqlite evidence');
    },
  );

  test('open failure returns sanitized typed failure', () async {
    final database = ActivityRecordingDatabase(
      factory: databaseFactoryFfiNoIsolate,
      directory: () async => throw FileSystemException('private details'),
    );
    await expectLater(
      database.transaction((tx) => tx.active('none')),
      throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
    );
    await database.dispose();
  });

  for (final scope in ['', 'corrupt']) {
    test(
      'malformed owner scope $scope preserves recordings and fails closed',
      () async {
        final r = await f.start();
        final raw = await f.raw();
        await raw.update('recording_store_metadata', {'owner_scope': scope});
        await raw.close();
        await reopen();
        await expectLater(
          f.controller.getActiveActivityRecording(),
          throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
        );
        final evidence = await f.raw();
        expect(
          (await evidence.query('recordings')).single['recording_id'],
          r.recordingId,
        );
        await evidence.close();
      },
    );
  }

  test(
    'bound identity corruption fails canonical validation independently',
    () async {
      await f.start(device: tagA);
      final raw = await f.raw();
      await raw.update('recordings', {'device_identity': 'not-canonical'});
      await raw.close();
      await reopen();
      await expectLater(
        f.controller.getActiveActivityRecording(),
        throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
      );
    },
  );

  test(
    'finished A retry remains immutable while unrelated active B is orphaned',
    () async {
      final a = await f.start();
      final finished = await f.controller.finishActivityRecording(
        recordingId: a.recordingId,
      );
      await f.sessions.endActivitySession(sessionId: a.activitySessionId);
      final b = await f.start();
      await f.sessions.endActivitySession(sessionId: b.activitySessionId);
      final result = await f.controller.finishActivityRecording(
        recordingId: a.recordingId,
      );
      expect(snapshot(result), snapshot(finished));
      expect(
        (await f.controller.getActivityRecording(
          recordingId: b.recordingId,
        ))?.phase,
        ActivityRecordingPhase.active,
      );
    },
  );

  for (final association in ['different', 'corrupt', 'unreadable']) {
    test(
      '$association logical session fences restored active metadata without deletion',
      () async {
        final r = await f.start();
        if (association == 'different') {
          await f.sessions.endActivitySession(sessionId: r.activitySessionId);
          await f.logicalStart('org.example.other');
        } else if (association == 'corrupt') {
          f.sessionStore.raw = '{broken';
        } else {
          f.sessionStore.unreadable = true;
        }
        await reopen();
        await expectLater(
          f.controller.getActiveActivityRecording(),
          throwsA(recordingError('E_RECORDING_SESSION_MISMATCH')),
        );
        expect(
          (await f.controller.getActivityRecording(
            recordingId: r.recordingId,
          ))?.phase,
          ActivityRecordingPhase.active,
        );
      },
    );
  }

  test(
    'SQLite disk-full transaction rolls back without evicting finished data',
    () async {
      final r = await f.start();
      await f.controller.finishActivityRecording(recordingId: r.recordingId);
      final raw = await f.raw();
      await raw.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      await raw.close();
      await f.dispose();
      final limitedFactory = databaseFactoryFfiNoIsolate;
      final db = await limitedFactory.openDatabase(
        f.path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.execute('PRAGMA journal_mode = DELETE');
      final pages = (await db.rawQuery(
        'PRAGMA page_count',
      )).single.values.single;
      await db.rawQuery('PRAGMA max_page_count = $pages');
      await expectLater(
        db.transaction(
          (tx) => tx.execute(
            'CREATE TABLE exhausted AS SELECT zeroblob(1048576) AS payload',
          ),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect(
        (await db.query('recordings')).single['recording_id'],
        r.recordingId,
      );
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'exhausted'",
        ),
        isEmpty,
      );
      await db.close();
    },
  );
}

Map<String, Object?> snapshot(SdkActivityRecording value) =>
    ActivityRecordingRecord(
      ActivityRecordingOwner.forIdentity('https://sdk.test', recordingUserA),
      value,
    ).encode();
