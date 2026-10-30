import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'recording_test_support.dart';

void main() {
  late RecordingFixture f;
  setUp(() async {
    f = await RecordingFixture.create();
    f.verified.add('node:42');
  });
  tearDown(() => f.delete());

  Future<void> reopen() async {
    final directory = f.directory;
    final sessions = f.sessionStore;
    await f.dispose();
    f = await RecordingFixture.create(
      directory: directory,
      sessionStore: sessions,
    );
    f.verified.clear();
  }

  for (final identity in [tagA, 'node:42']) {
    for (final finished in [false, true]) {
      test(
        '$identity ${finished ? 'finished' : 'active/disconnected'} roundtrip retains source and route',
        () async {
          final r = await f.start(device: identity);
          final batch = EixamDevicePositionBatch(
            samples: [
              EixamDevicePositionSample(
                latitude: 1,
                longitude: 2,
                altitudeMeters: 40,
                sampledAt: f.now,
                packetId: 1,
                source: SdkLocationSource.connectedDevice,
                stableSampleKey: 'same-sample',
              ),
            ],
            receivedAt: f.now,
            source: SdkLocationSource.connectedDevice,
            deviceIdentity: identity == tagA ? tagA : null,
          );
          await f.controller.ingestLive(
            batch,
            registeredNodeId: identity == tagA ? null : 42,
          );
          if (finished) {
            await f.controller.finishActivityRecording(
              recordingId: r.recordingId,
            );
          } else {
            await f.controller.inputDisconnected(
              identity == tagA ? tagA : null,
              false,
              registeredNodeId: identity == tagA ? null : 42,
            );
          }
          await reopen();
          final restored = (await f.controller.getActivityRecording(
            recordingId: r.recordingId,
          ))!;
          expect(restored.deviceIdentity, identity);
          expect(restored.recordingId, r.recordingId);
          expect(restored.pointCount, 1);
          expect(
            restored.phase,
            finished
                ? ActivityRecordingPhase.finished
                : ActivityRecordingPhase.active,
          );
          expect(f.verifyCalls, 0);
          if (finished) {
            expect(await f.controller.getActiveActivityRecording(), isNull);
          } else {
            expect(
              (await f.controller.getActiveActivityRecording())!.inputState,
              ActivityRecordingInputState.disconnected,
            );
            await f.controller.ingestLive(
              batch,
              registeredNodeId: identity == tagA ? null : 42,
            );
            expect(
              (await f.controller.getActiveActivityRecording())!.pointCount,
              1,
            );
          }
          final points =
              (await f.controller
                      .readActivityRecordingRoute(recordingId: r.recordingId)
                      .toList())
                  .expand((page) => page.segments)
                  .expand((segment) => segment.points);
          expect(points, hasLength(1));
          expect(
            (await f.sessions.getActiveActivitySession())!.sessionId,
            r.activitySessionId,
          );
        },
      );
    }
  }

  for (final corrupt in [
    'node:0',
    'node:042',
    'node:4294967295',
    'node:42 ',
    'future:42',
    '42',
  ]) {
    test(
      'corrupt stored node encoding $corrupt fails closed without deletion',
      () async {
        final r = await f.start(device: 'node:42');
        final raw = await f.raw();
        await raw.update('recordings', {'device_identity': corrupt});
        await raw.close();
        await reopen();
        await expectLater(
          f.controller.getActiveActivityRecording(),
          throwsA(recordingError('E_RECORDING_RESTORE_FAILED')),
        );
        final evidence = await f.raw();
        final rows = await evidence.query('recordings');
        expect(rows.single['recording_id'], r.recordingId);
        expect(rows.single['device_identity'], corrupt);
        await evidence.close();
      },
    );
  }

  test(
    'node Start lost ACK is reconciled without duplicate Recording',
    () async {
      f.store.loseNextWriteAcknowledgement = true;
      await expectLater(
        f.start(device: 'node:42'),
        throwsA(recordingError('E_RECORDING_PERSISTENCE_FAILED')),
      );
      final committed = (await f.controller.getActiveActivityRecording())!;
      expect(committed.deviceIdentity, 'node:42');
      final retry = await f.start(device: 'node:42');
      expect(retry.recordingId, committed.recordingId);
      expect(f.store.committedWrites, 1);
    },
  );
  for (final invalid in ['node:042', 'node:0', 'node:42 ', 'future:42']) {
    test(
      'unbound retry rejects malformed supplied identity $invalid',
      () async {
        final r = await f.start();
        await expectLater(
          f.start(device: invalid),
          throwsA(recordingError('E_RECORDING_DEVICE_MISMATCH')),
        );
        final unchanged = (await f.controller.getActiveActivityRecording())!;
        expect(unchanged.recordingId, r.recordingId);
        expect(unchanged.deviceIdentity, isNull);
      },
    );
  }
}
