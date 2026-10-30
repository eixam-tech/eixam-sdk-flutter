import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'activity_recording_ingestion_test.dart' show batch, sample;
import 'recording_history_test_support.dart';
import 'recording_test_support.dart';

void main() {
  readerMatrix();
  for (final paused in [false, true]) {
    test('Finish reaches durable finished with paused reader=$paused', () async {
      final h = RecordingHistoryHarness();
      await h.create();
      final f = h.f;
      final clock = FakeAsync();
      f.recoveryTimer = (duration, callback) =>
          clock.run((_) => Timer(duration, () => Zone.root.run(callback)));
      StreamSubscription<SdkActivityRoutePage>? reader;
      Future<SdkActivityRecording>? finish;
      try {
        final r = await f.start(device: tagA);
        final start = r.recordingStartedAt;
        f.now = start.add(const Duration(seconds: 10));
        await f.controller.ingestLive(
          batch(f, [
            for (var i = 0; i < 3; i++)
              sample('p$i', start.add(Duration(seconds: i))),
          ]),
        );
        await h.ready();
        if (paused) {
          final first = Completer<void>();
          reader = f.controller
              .readActivityRecordingRoute(
                recordingId: r.recordingId,
                pageSize: 1,
              )
              .listen((page) {
                expect(page.isLast, isFalse);
                reader!.pause();
                first.complete();
              });
          await first.future;
        }
        var returned = false;
        finish = f.controller.finishActivityRecording(
          recordingId: r.recordingId,
        );
        finish.then((_) => returned = true).ignore();
        await pumpEventQueue(times: 100);
        f.now = f.now.add(const Duration(milliseconds: 5501));
        clock.elapse(const Duration(milliseconds: 5501));
        await pumpEventQueue(times: 100);
        final db = await f.raw();
        final row = (await db.query('recordings')).single;
        await db.close();
        expect(
          row['phase'],
          'finished',
          reason:
              'Finish must persist finished before the paused reader is released.',
        );
        expect(returned, isTrue);
        if (paused) expect(reader!.isPaused, isTrue);
        expect((await finish).phase, ActivityRecordingPhase.finished);
      } finally {
        await reader?.cancel();
        await pumpEventQueue(times: 100);
        clock.elapse(const Duration(seconds: 6));
        await pumpEventQueue(times: 100);
        await finish;
        await h.delete();
      }
    });
  }
}

/// A real consumer pause, with errors collected without cancelling the reader.
final class _PausedRoute {
  _PausedRoute(RecordingFixture f, String id) {
    subscription = f.controller
        .readActivityRecordingRoute(recordingId: id, pageSize: 1)
        .listen(
          (page) {
            expect(
              f.store.activeTransactions,
              0,
              reason: 'Page delivery must follow transaction release.',
            );
            pages.add(page);
            if (!first.isCompleted) {
              subscription.pause();
              first.complete();
            }
          },
          onError: errors.add,
          onDone: done.complete,
        );
  }
  late final StreamSubscription<SdkActivityRoutePage> subscription;
  final first = Completer<void>();
  final done = Completer<void>();
  final pages = <SdkActivityRoutePage>[];
  final errors = <Object>[];
  Future<void> resume() async {
    subscription.resume();
    await done.future.timeout(const Duration(seconds: 3));
  }
}

void readerMatrix() {
  group('page-scoped reader ownership', () {
    late RecordingHistoryHarness h;
    late RecordingFixture f;
    late SdkActivityRecording r;
    late FakeAsync clock;
    late int t;
    final readers = <_PausedRoute>[];
    setUp(() async {
      h = RecordingHistoryHarness();
      await h.create();
      f = h.f;
      r = await f.start(device: tagA);
      t = r.recordingStartedAt.millisecondsSinceEpoch ~/ 1000;
      f.now = f.now.add(const Duration(seconds: 10));
      clock = FakeAsync();
      f.recoveryTimer = (duration, callback) =>
          clock.run((_) => Timer(duration, () => Zone.root.run(callback)));
      await f.controller.ingestLive(
        batch(f, [
          for (final i in [0, 2, 4]) h.sample(t + i, i + 1),
        ]),
      );
    });
    tearDown(() async {
      for (final reader in readers) {
        await reader.subscription.cancel();
      }
      readers.clear();
      await h.delete();
    });
    Future<_PausedRoute> pause() async {
      final reader = _PausedRoute(f, r.recordingId);
      readers.add(reader);
      await reader.first.future;
      expect(reader.subscription.isPaused, isTrue);
      return reader;
    }

    Future<SdkActivityRecording> current() async =>
        (await f.controller.getActivityRecording(recordingId: r.recordingId))!;
    Future<void> live(int offset) =>
        f.controller.ingestLive(batch(f, [h.sample(t + offset, offset + 1)]));

    test('pause releases actor and SQLite writer before delivery', () async {
      final reader = await pause();
      expect(f.store.activeTransactions, 0);
      expect((await current()).pointCount, 3);
      final db = await f.raw();
      try {
        // Acquiring BEGIN IMMEDIATE independently proves no reader SQL lock.
        await db.transaction((tx) => tx.rawQuery('SELECT 1'));
      } finally {
        await db.close();
      }
      expect(reader.subscription.isPaused, isTrue);
      await reader.resume();
      expect(reader.pages, hasLength(3));
      expect(reader.errors, isEmpty);
      expect(reader.pages.last.isLast, isTrue);
      expect(reader.pages.map((p) => p.routeRevision).toSet(), {1});
    });

    for (final writes in [1, 3]) {
      test(
        'live commits $writes revision(s), publishes, then reader rejects',
        () async {
          final summaries = <SdkActivityRecording?>[];
          final watch = f.controller.watchActiveActivityRecording().listen(
            summaries.add,
          );
          try {
            await pumpEventQueue();
            final reader = await pause();
            for (var i = 0; i < writes; i++) {
              await live(5 + i);
            }
            await pumpEventQueue();
            final state = await current();
            expect(state.pointCount, 3 + writes);
            expect(state.routeRevision, 1 + writes);
            expect(summaries.last!.routeRevision, state.routeRevision);
            expect(reader.subscription.isPaused, isTrue);
            await reader.resume();
            expect(reader.pages, hasLength(1));
            expect(reader.errors, [
              recordingError('E_RECORDING_ROUTE_REVISION_CHANGED'),
            ]);
          } finally {
            await watch.cancel();
          }
        },
      );
    }

    test(
      'duplicate input and recovery metadata preserve captured revision',
      () async {
        await h.ready();
        final reader = await pause();
        await live(0);
        final work = f.controller.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        );
        work.ignore();
        await pumpEventQueue();
        expect(
          (await current()).recoveryState,
          ActivityRecordingRecoveryState.recovering,
        );
        expect((await current()).routeRevision, 1);
        await h.send(h.meta(0));
        await h.send(h.end(0));
        await work;
        expect((await current()).routeRevision, 1);
        await reader.resume();
        expect(reader.errors, isEmpty);
        expect(reader.pages, hasLength(3));
        expect(reader.pages.every((p) => p.routeRevision == 1), isTrue);
      },
    );

    test('D1 insertion and gap reconciliation commit while paused', () async {
      await f.controller.inputDisconnected(tagA, false);
      await f.controller.inputDisconnected(tagA, true);
      await h.ready();
      final before = await current();
      expect(before.unresolvedGapCount, 1);
      final reader = await pause();
      final work = f.controller.recoverActivityRecordingHistory(
        recordingId: r.recordingId,
      );
      work.ignore();
      await pumpEventQueue();
      expect(h.requests, hasLength(1));
      await h.send(h.meta(3));
      for (var index = 0; index < 3; index++) {
        final offset = [4, 7, 10][index];
        await h.send(h.chunk(t + offset, index: index, packet: offset + 1));
      }
      await h.send(h.end(3));
      final recovered = await work;
      expect(recovered.pointCount, 5);
      expect(recovered.unresolvedGapCount, 0);
      expect(recovered.segmentCount, 1);
      expect(recovered.recordedDistanceMeters, isNotNull);
      expect(recovered.routeRevision, greaterThan(before.routeRevision));
      expect(recovered.recoveryState, ActivityRecordingRecoveryState.idle);
      expect(
        recovered.issues,
        isNot(contains(ActivityRecordingIssue.recoveryTimedOut)),
      );
      expect(reader.subscription.isPaused, isTrue);
      await reader.resume();
      expect(reader.pages, hasLength(1));
      expect(reader.errors, [
        recordingError('E_RECORDING_ROUTE_REVISION_CHANGED'),
      ]);
    });

    test('reader started after finalizing cannot hold deadline commit', () async {
      await h.ready();
      final work = f.controller.finishActivityRecording(
        recordingId: r.recordingId,
      );
      work.ignore();
      await pumpEventQueue(times: 100);
      expect((await current()).phase, ActivityRecordingPhase.finalizing);
      final reader = await pause();
      f.now = f.now.add(const Duration(milliseconds: 5501));
      clock.elapse(const Duration(milliseconds: 5501));
      await pumpEventQueue(times: 100);
      final finished = await work;
      expect(finished.phase, ActivityRecordingPhase.finished);
      expect((await current()).phase, ActivityRecordingPhase.finished);
      expect(reader.subscription.isPaused, isTrue);
      // Lifecycle-only finalization leaves this clean route revision unchanged.
      expect(finished.routeRevision, 1);
      await reader.resume();
      expect(reader.errors, isEmpty);
      expect(reader.pages, hasLength(3));
    });

    test(
      'pause has no timeout policy and resumes after long fake time',
      () async {
        final reader = await pause();
        clock.elapse(const Duration(days: 1));
        f.now = f.now.add(const Duration(days: 1));
        expect((await current()).routeRevision, 1);
        await reader.resume();
        expect(reader.errors, isEmpty);
        expect(reader.pages, hasLength(3));
      },
    );

    test('many paused readers retain no SQL or writer admission', () async {
      for (var i = 0; i < 100; i++) {
        await pause();
      }
      expect(f.store.activeTransactions, 0);
      await live(5);
      expect((await current()).pointCount, 4);
      expect(readers.every((reader) => reader.subscription.isPaused), isTrue);
    });

    for (final dispose in [false, true]) {
      test(
        'paused reader does not hold ${dispose ? 'dispose' : 'identity cleanup'}',
        () async {
          final reader = await pause();
          if (dispose) {
            await f.dispose();
          } else {
            await f.bind(recordingUserB);
            final b = await f.start(device: tagA);
            f.now = f.now.add(const Duration(seconds: 1));
            await f.controller.ingestLive(batch(f, [sample('b-first', f.now)]));
            expect(
              (await f.controller.getActivityRecording(
                recordingId: b.recordingId,
              ))!.pointCount,
              1,
            );
          }
          expect(reader.subscription.isPaused, isTrue);
          await reader.resume();
          expect(reader.pages, hasLength(1));
          expect(reader.errors, isEmpty);
          expect(f.store.activeTransactions, 0);
        },
      );
    }

    for (final operation in ['cancel', 'identity', 'dispose']) {
      test(
        '$operation fences an in-flight page without stale delivery',
        () async {
          final entered = Completer<void>();
          final release = Completer<void>();
          var queries = 0;
          f.store.beforeRoutePage = () async {
            queries++;
            entered.complete();
            await release.future;
          };
          final pages = <SdkActivityRoutePage>[];
          final errors = <Object>[];
          final sub = f.controller
              .readActivityRecordingRoute(
                recordingId: r.recordingId,
                pageSize: 1,
              )
              .listen(pages.add, onError: errors.add);
          await entered.future;
          Future<void> work;
          if (operation == 'identity') {
            work = f.bind(recordingUserB);
          } else if (operation == 'dispose') {
            work = f.dispose();
          } else {
            work = sub.cancel();
          }
          release.complete();
          await work;
          await pumpEventQueue();
          await sub.cancel();
          expect(pages, isEmpty);
          expect(errors, isEmpty);
          expect(queries, 1);
          expect(f.store.activeTransactions, 0);
        },
      );
    }

    test(
      'StreamIterator cancellation and await-for break release promptly',
      () async {
        for (var i = 0; i < 10; i++) {
          final it = StreamIterator(
            f.controller.readActivityRecordingRoute(
              recordingId: r.recordingId,
              pageSize: 1,
            ),
          );
          expect(await it.moveNext(), isTrue);
          await it.cancel();
          await for (final page in f.controller.readActivityRecordingRoute(
            recordingId: r.recordingId,
            pageSize: 1,
          )) {
            expect(page.routeRevision, 1);
            break;
          }
        }
        await live(5);
        expect((await current()).pointCount, 4);
        expect(f.store.activeTransactions, 0);
      },
    );
  });
}
