import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_database.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/activity_recording_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/sdk_session_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_activity_availability_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_http_transport.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_identity_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sdk_session_context.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_data.dart';
import 'package:eixam_connect_flutter/src/device/eixam_position_backlog_packet.dart';
import '../activity/recording_history_test_support.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_live_batch_packet.dart';
import 'package:eixam_connect_flutter/src/device/eixam_tel_packet.dart';
import 'package:eixam_connect_flutter/src/sdk/background_location_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../activity/recording_test_support.dart' show FaultRecordingStore;

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

part 'activity_recording_registered_node_cases.dart';

const _backend = 'https://sdk.test';
const _identity = EixamSession.signed(
  appId: 'partner-app',
  externalUserId: 'user-a',
  userHash: 'signed-a',
  sdkUserId: 'sdk-a',
  canonicalExternalUserId: 'user-a',
);
final _appSnapshot = _identity.copyWith(
  sdkUserId: null,
  canonicalExternalUserId: null,
);
const _watchdog = Duration(seconds: 2);
const _tag = 'AA:BB:CC:DD:EE:01';
final _routeStart = DateTime.utc(2026, 10, 19, 12);

void main() {
  _registeredNodeTests();
  test('production optional capability is local and safety isolated', () async {
    final h = _Harness(_Disk());
    try {
      await h.initialize();
      await h.sdk.setSession(_identity, deferRuntimeWork: true);
      final EixamConnectSdk facade = h.sdk;
      expect(facade, isA<ActivityRecordingControl>());
      expect(facade, isA<ActivityRecordingHistoryControl>());
      final control = facade as ActivityRecordingControl;
      final session = await h.sdk.startActivitySession(
        activityKey: 'org.example.paddle',
      );
      final r = await control.startActivityRecording(activitySession: session);
      expect(
        (await control.getActiveActivityRecording())?.recordingId,
        r.recordingId,
      );
      expect(
        (await control.watchActiveActivityRecording().first)?.recordingId,
        r.recordingId,
      );
      expect(
        (await control
                .readActivityRecordingRoute(recordingId: r.recordingId)
                .single)
            .isLast,
        isTrue,
      );
      expect(
        (await control.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        )).recoveryState,
        ActivityRecordingRecoveryState.deferred,
      );
      await control.finishActivityRecording(recordingId: r.recordingId);
      expect(
        (await (facade as ActivityRecordingHistoryControl)
                .listFinishedActivityRecordings())
            .items
            .single
            .recordingId,
        r.recordingId,
      );
      expect(
        (await h.sdk.getActiveActivitySession())?.sessionId,
        session.sessionId,
      );
      expect(h.identityRequests, 0);
      expect(h.sdk.forbiddenCalls, isEmpty);
      expect(h.tracking.startCallCount, 0);
      expect(h.tracking.stopCallCount, 0);
      expect(h.sos.triggerCallCount, 0);
      expect(h.sos.cancelCallCount, 0);
      expect(h.sos.resolveCallCount, 0);
      expect(h.deathMan.activePlan, isNull);
      expect(h.deathMan.updateCallCount, 0);
    } finally {
      await h.dispose();
    }
  });

  for (final readiness in ['pending', 'offline', 'rotation']) {
    test(
      'production cold $readiness restores recording before remote readiness',
      () async {
        final disk = _Disk();
        final seed = _Harness(disk);
        late SdkActivityRecording original;
        await seed.initialize();
        await seed.sdk.setSession(_identity, deferRuntimeWork: true);
        final session = await seed.sdk.startActivitySession(
          activityKey: 'mountain',
        );
        original = await seed.sdk.startActivityRecording(
          activitySession: session,
        );
        await seed.dispose();
        final h = _Harness(disk);
        Future<EixamSession>? refresh;
        try {
          await h.initialize();
          h.offline = true;
          await h.sdk.setSession(
            _appSnapshot.copyWith(
              userHash: readiness == 'rotation' ? 'rotated' : 'signed-a',
            ),
            deferRuntimeWork: true,
          );
          if (readiness == 'pending') {
            h.offline = false;
            h.identityGate = Completer<http.Response>();
            refresh = h.sdk.refreshCanonicalIdentity();
            await pumpEventQueue();
          }
          final restored = await h.sdk.getActiveActivityRecording().timeout(
            _watchdog,
          );
          expect(restored?.recordingId, original.recordingId);
          expect(restored?.activitySessionId, original.activitySessionId);
          expect(restored?.recordingStartedAt, original.recordingStartedAt);
          expect(restored?.deviceIdentity, original.deviceIdentity);
          expect(restored?.routeRevision, original.routeRevision);
          expect(restored?.pointCount, 0);
          expect(h.identityRequests, readiness == 'pending' ? 1 : 0);
          if (readiness == 'offline') {
            await expectLater(
              h.sdk.refreshCanonicalIdentity(),
              throwsA(isA<NetworkException>()),
            );
            expect(
              (await h.sdk.getActiveActivityRecording())?.recordingId,
              original.recordingId,
            );
          }
        } finally {
          h.releaseIdentity();
          if (refresh != null) await refresh;
          await h.dispose();
        }
      },
    );
  }

  test('production canonical conflict purges and fences recorder', () async {
    final h = _Harness(_Disk());
    try {
      await h.initialize();
      await h.sdk.setSession(_identity, deferRuntimeWork: true);
      final r = await h.sdk.startActivityRecording(
        activitySession: await h.sdk.startActivitySession(
          activityKey: 'mountain',
        ),
      );
      h.canonicalId = 'conflicting';
      await expectLater(
        h.sdk.refreshCanonicalIdentity(),
        throwsA(isA<AuthException>()),
      );
      await expectLater(
        h.sdk.getActivityRecording(recordingId: r.recordingId),
        throwsA(isA<ActivityRecordingException>()),
      );
    } finally {
      await h.dispose();
    }
  });

  for (final stale in [false, true]) {
    test(
      'canonical binding ${stale ? 'rejects stale A assignment after switch to B' : 'accepts generation verified assignment only'}',
      () async {
        final registry = _GatedAssignmentRegistry();
        final h = _Harness(_Disk(), registry: registry);
        try {
          await h.initialize();
          await h.sdk.setSession(_identity, deferRuntimeWork: true);
          h.device.emitStatus(
            buildDeviceStatus(
              connected: false,
              nodeId: 42,
              canonicalHardwareId: 'AA:BB:CC:DD:EE:01',
            ),
          );
          await pumpEventQueue();
          final assignment = h.sdk.upsertRegisteredDevice(
            hardwareId: '42',
            firmwareVersion: '1',
            hardwareModel: 'TAG',
            pairedAt: DateTime.utc(2026),
          );
          await registry.entered.future;
          if (stale) {
            await h.sdk.setSession(
              _identity.copyWith(
                externalUserId: 'user-b',
                sdkUserId: 'sdk-b',
                canonicalExternalUserId: 'user-b',
              ),
              deferRuntimeWork: true,
            );
          }
          registry.release.complete();
          await assignment;
          final session = await h.sdk.startActivitySession(
            activityKey: 'mountain',
          );
          final r = await h.sdk.startActivityRecording(
            activitySession: session,
          );
          final binding = h.sdk.bindActivityRecordingDevice(
            recordingId: r.recordingId,
            deviceIdentity: 'AA:BB:CC:DD:EE:01',
          );
          if (stale) {
            await expectLater(
              binding,
              throwsA(
                isA<ActivityRecordingException>().having(
                  (e) => e.code,
                  'code',
                  'E_RECORDING_DEVICE_MISMATCH',
                ),
              ),
            );
            expect(
              (await h.sdk.getActiveActivityRecording())?.deviceIdentity,
              isNull,
            );
          } else {
            expect((await binding).deviceIdentity, 'AA:BB:CC:DD:EE:01');
          }
        } finally {
          if (!registry.release.isCompleted) registry.release.complete();
          await h.dispose();
        }
      },
    );
  }

  test(
    'old-generation in-flight D3 cannot publish or leak route to new principal',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ar2b-sdk-generation-',
      );
      final store = FaultRecordingStore(
        ActivityRecordingDatabase(
          path: '${directory.path}/recordings.sqlite',
          factory: databaseFactoryFfiNoIsolate,
        ),
      );
      final h = _Harness(
        _Disk(),
        recordingStore: store,
        clock: () => _routeStart,
      );
      final observations = <SdkActivityRecording?>[];
      StreamSubscription<SdkActivityRecording?>? watcher;
      final gate = Completer<void>();
      try {
        final original = await h.startBoundRoute();
        watcher = h.sdk.watchActiveActivityRecording().listen(
          observations.add,
          onError: (Object _) {},
        );
        await pumpEventQueue();
        store.writeGate = gate;
        store.writeEntered = Completer<void>();
        h.incoming.add(_liveEvent());
        await store.writeEntered!.future.timeout(_watchdog);
        final switching = h.sdk.setSession(
          _identity.copyWith(
            externalUserId: 'user-b',
            sdkUserId: 'sdk-b',
            canonicalExternalUserId: 'user-b',
          ),
          deferRuntimeWork: true,
        );
        gate.complete();
        await switching;
        expect(
          observations.whereType<SdkActivityRecording>().every(
            (r) => r.pointCount == 0,
          ),
          isTrue,
        );
        expect(await h.sdk.getActiveActivityRecording(), isNull);
        expect(
          await h.sdk.getActivityRecording(recordingId: original.recordingId),
          isNull,
        );
        await expectLater(
          h.sdk
              .readActivityRecordingRoute(recordingId: original.recordingId)
              .toList(),
          throwsA(isA<ActivityRecordingException>()),
        );
        final replacement = await h.sdk.startActivityRecording(
          activitySession: await h.sdk.startActivitySession(
            activityKey: 'mountain',
          ),
        );
        await h.deliver(_liveEvent());
        final active = (await h.sdk.getActiveActivityRecording())!;
        expect(active.recordingId, replacement.recordingId);
        expect(active.deviceIdentity, isNull);
        expect(active.pointCount, 0);
        h.expectSafetyIdle();
      } finally {
        if (!gate.isCompleted) gate.complete();
        await watcher?.cancel();
        await h.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test('decoded D3 retry survives public dedupe after SQL rollback', () async {
    final directory = await Directory.systemTemp.createTemp('ar2b-sdk-retry-');
    final store = FaultRecordingStore(
      ActivityRecordingDatabase(
        path: '${directory.path}/recordings.sqlite',
        factory: databaseFactoryFfiNoIsolate,
      ),
    );
    final h = _Harness(
      _Disk(),
      recordingStore: store,
      clock: () => _routeStart,
    );
    final public = <EixamDevicePositionBatch>[];
    final errors = <Object>[];
    StreamSubscription<EixamDevicePositionBatch>? positions;
    StreamSubscription<SdkActivityRecording?>? observations;
    try {
      final recording = await h.startBoundRoute();
      positions = h.sdk.testPositionBatches.listen(public.add);
      observations = h.sdk.watchActiveActivityRecording().listen(
        (_) {},
        onError: errors.add,
      );
      await pumpEventQueue();
      final event = _liveEvent();
      store.failNextWrite = true;
      await h.deliver(event);
      expect(public, hasLength(1));
      expect(public.single.samples, hasLength(2));
      expect(errors, hasLength(1));
      expect(errors.single, isA<ActivityRecordingException>());
      final failed = await h.sdk.getActiveActivityRecording();
      expect(failed!.pointCount, 0);
      expect(failed.routeRevision, 0);
      expect(failed.recordedDistanceMeters, isNull);

      await h.deliver(event);
      expect(
        public,
        hasLength(1),
        reason: 'Public duplicates remain suppressed',
      );
      final committed = await h.sdk.getActiveActivityRecording();
      expect(committed!.pointCount, 2);
      expect(committed.routeRevision, 1);
      expect(committed.recordedDistanceMeters, greaterThan(0));
      final page = await h.sdk
          .readActivityRecordingRoute(recordingId: recording.recordingId)
          .single;
      expect(page.segments.single.points, hasLength(2));
      h.expectSafetyIdle();
    } finally {
      await positions?.cancel();
      await observations?.cancel();
      await h.dispose();
      await directory.delete(recursive: true);
    }
  });

  test(
    'Classic TEL public suppression does not suppress timestamped D3 recording',
    () async {
      final h = _Harness(_Disk(), clock: () => _routeStart);
      final public = <EixamDevicePositionBatch>[];
      StreamSubscription<EixamDevicePositionBatch>? positions;
      try {
        await h.startBoundRoute();
        positions = h.sdk.testPositionBatches.listen(public.add);
        final wire = _wire(1);
        await h.deliver(_classicEvent(wire));
        expect((await h.sdk.getActiveActivityRecording())!.pointCount, 0);
        expect(public.single.samples.single.sampledAt, isNull);
        await h.deliver(_liveEvent(wires: [wire]));
        expect(public, hasLength(1));
        expect((await h.sdk.getActiveActivityRecording())!.pointCount, 1);
        h.expectSafetyIdle();
      } finally {
        await positions?.cancel();
        await h.dispose();
      }
    },
  );

  test(
    'production D3 tap rejects wrong or missing canonical identity and node',
    () async {
      final h = _Harness(_Disk(), clock: () => _routeStart);
      try {
        await h.startBoundRoute();
        for (final event in [
          _liveEvent(canonical: null),
          _liveEvent(canonical: 'AA:BB:CC:DD:EE:02'),
          _liveEvent(canonical: 'transport-address'),
          _liveEvent(wires: [_wire(1, node: 43)]),
        ]) {
          await h.deliver(event);
          final unchanged = await h.sdk.getActiveActivityRecording();
          expect(unchanged!.pointCount, 0);
          expect(unchanged.routeRevision, 0);
          expect(unchanged.recordedDistanceMeters, isNull);
        }
        await h.deliver(_liveEvent());
        expect(
          (await h.sdk.getActiveActivityRecording())!.pointCount,
          2,
          reason:
              'Private recorder remains independent of public wrong-device dedupe',
        );
        h.expectSafetyIdle();
      } finally {
        await h.dispose();
      }
    },
  );

  test('unbound recording never follows connected TAG automatically', () async {
    final h = _Harness(_Disk(), clock: () => _routeStart);
    try {
      await h.initialize();
      await h.sdk.setSession(_identity, deferRuntimeWork: true);
      final recording = await h.sdk.startActivityRecording(
        activitySession: await h.sdk.startActivitySession(
          activityKey: 'mountain',
        ),
      );
      await h.verifyTag();
      await h.deliver(_liveEvent());
      final unchanged = await h.sdk.getActiveActivityRecording();
      expect(unchanged!.deviceIdentity, isNull);
      expect(unchanged.pointCount, 0);
      expect(unchanged.routeRevision, 0);
      expect(
        (await h.sdk
                .readActivityRecordingRoute(recordingId: recording.recordingId)
                .single)
            .segments,
        isEmpty,
      );
      h.expectSafetyIdle();
    } finally {
      await h.dispose();
    }
  });

  test(
    'production command readiness triggers owned D1 recovery and safe final catch-up before transport dedupe',
    () async {
      final directory = await Directory.systemTemp.createTemp('ar2ca-sdk-');
      final history = RecordingHistoryHarness();
      await history.create();
      var now = _routeStart;
      final h = _Harness(
        _Disk(),
        clock: () => now,
        recordingStore: ActivityRecordingDatabase(
          path: '${directory.path}/recordings.sqlite',
          factory: databaseFactoryFfiNoIsolate,
        ),
      );
      final observations = <SdkActivityRecording?>[];
      StreamSubscription<SdkActivityRecording?>? watcher;
      try {
        final r = await h.startBoundRoute();
        now = _routeStart.add(const Duration(minutes: 1));
        await h.deliver(_liveEvent());
        watcher = h.sdk.watchActiveActivityRecording().listen(observations.add);
        h.device.emitStatus(
          buildDeviceStatus(
            connected: false,
            nodeId: 42,
            canonicalHardwareId: _tag,
          ),
        );
        await pumpEventQueue();
        expect(
          (await h.sdk.getActiveActivityRecording())!.unresolvedGapCount,
          1,
        );
        h.device.emitStatus(
          buildDeviceStatus(
            connected: true,
            nodeId: 42,
            canonicalHardwareId: _tag,
          ),
        );
        await pumpEventQueue();
        expect(h.backlogCommands, isEmpty);
        await h.commandPath.attach(commandWriter: (_) async {});
        await pumpEventQueue(times: 40);
        expect(h.backlogCommands.where((c) => c.opcode == 0x30), hasLength(1));
        final recovery = h.sdk.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        );
        await pumpEventQueue();
        // Genuine decoded D1 with exact canonical TAG but a different TEL node.
        final unix = _routeStart.millisecondsSinceEpoch ~/ 1000;
        Future<void> deliver(List<int> bytes, {bool ownNode = true}) async {
          if (bytes[1] == 2 && ownNode) {
            bytes.setRange(12, 16, [42, 0, 0, 0]);
          }
          final parsed = EixamPositionBacklogPacket.tryParse(
            bytes,
            receivedAt: now,
          );
          await h.deliver(
            BleIncomingEvent(
              deviceId: 'transport-a',
              canonicalHardwareId: _tag,
              type: BleIncomingEventType.telPositionBacklog,
              channel: EixamBleChannel.tel,
              payload: const [],
              payloadHex: '',
              source: DeviceSosTransitionSource.device,
              receivedAt: now,
              positionBacklogPacket: parsed,
            ),
          );
        }

        await deliver(history.meta(1));
        await deliver(history.chunk(unix + 3), ownNode: false);
        expect((await h.sdk.getActiveActivityRecording())!.pointCount, 2);
        await deliver(history.chunk(unix + 3));
        await deliver(history.end(1));
        final settled = await recovery;
        expect(settled.pointCount, 3);
        final finishing = h.sdk.finishActivityRecording(
          recordingId: r.recordingId,
          endedAt: now,
        );
        await pumpEventQueue();
        expect(h.backlogCommands.where((c) => c.opcode == 0x30), hasLength(2));
        await deliver(history.meta(0));
        await deliver(history.end(0));
        final finished = await finishing;
        expect(finished.phase, ActivityRecordingPhase.finished);
        expect(finished.recoveryState, ActivityRecordingRecoveryState.idle);
        expect(finished.pointCount, 3);
        expect(
          (await h.sdk.getActiveActivitySession())!.sessionId,
          r.activitySessionId,
        );
        expect(await h.sdk.getActiveActivityRecording(), isNull);
        expect(
          settled.routeQuality,
          ActivityRecordingRouteQuality.partial,
        ); // Only an interior point.
        expect(
          observations.any(
            (r) =>
                r?.recoveryState == ActivityRecordingRecoveryState.recovering,
          ),
          isTrue,
        );
        expect(h.sdk.forbiddenCalls, isEmpty);
        expect(h.tracking.startCallCount, 0);
        expect(h.sos.triggerCallCount, 0);
        expect(h.deathMan.updateCallCount, 0);
      } finally {
        await watcher?.cancel();
        await h.dispose();
        await history.delete();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'cold offline SDK restores route and protects finished data from live input',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ar2b-sdk-offline-',
      );
      final path = '${directory.path}/recordings.sqlite';
      final disk = _Disk();
      var now = _routeStart;
      _Harness create() => _Harness(
        disk,
        recordingStore: ActivityRecordingDatabase(
          path: path,
          factory: databaseFactoryFfiNoIsolate,
        ),
        clock: () => now,
      );
      final seed = create();
      late SdkActivityRecording original;
      late List<SdkActivityRoutePoint> originalPoints;
      try {
        final recording = await seed.startBoundRoute();
        await seed.deliver(_liveEvent());
        original = (await seed.sdk.getActiveActivityRecording())!;
        originalPoints =
            (await seed.sdk
                    .readActivityRecordingRoute(
                      recordingId: recording.recordingId,
                    )
                    .single)
                .segments
                .single
                .points;
        seed.expectSafetyIdle();
      } finally {
        await seed.dispose();
      }
      final restored = create();
      try {
        await restored.initialize();
        restored.offline = true;
        await restored.sdk.setSession(_appSnapshot, deferRuntimeWork: true);
        final summary = (await restored.sdk.getActiveActivityRecording())!;
        expect(summary.recordingId, original.recordingId);
        expect(summary.deviceIdentity, original.deviceIdentity);
        expect(summary.pointCount, original.pointCount);
        expect(summary.segmentCount, original.segmentCount);
        expect(summary.routeRevision, original.routeRevision);
        expect(summary.firstSampleAt, original.firstSampleAt);
        expect(summary.lastSampleAt, original.lastSampleAt);
        expect(summary.recordedDistanceMeters, original.recordedDistanceMeters);
        expect(restored.identityRequests, 0);
        final route =
            (await restored.sdk
                    .readActivityRecordingRoute(
                      recordingId: original.recordingId,
                    )
                    .single)
                .segments
                .single
                .points;
        expect(
          route.map((p) => (p.sampledAt, p.latitude, p.longitude)),
          originalPoints.map((p) => (p.sampledAt, p.latitude, p.longitude)),
        );
        now = _routeStart.add(const Duration(minutes: 1));
        await restored.verifyTag();
        await restored.deliver(_liveEvent());
        expect(
          (await restored.sdk.getActiveActivityRecording())!.routeRevision,
          greaterThan(original.routeRevision),
        );
        expect(
          (await restored.sdk.getActiveActivityRecording())!.routeQuality,
          ActivityRecordingRouteQuality.partial,
        );
        await restored.deliver(_liveEvent(offsetSeconds: 10));
        expect(
          (await restored.sdk.getActiveActivityRecording())!.pointCount,
          4,
        );
        now = _routeStart.add(const Duration(minutes: 2));
        final finished = await restored.sdk.finishActivityRecording(
          recordingId: original.recordingId,
        );
        await restored.deliver(_liveEvent(offsetSeconds: 20));
        final frozen = await restored.sdk.getActivityRecording(
          recordingId: original.recordingId,
        );
        expect(frozen!.phase, ActivityRecordingPhase.finished);
        expect(frozen.pointCount, finished.pointCount);
        expect(frozen.routeRevision, finished.routeRevision);
        expect(frozen.recordedDistanceMeters, finished.recordedDistanceMeters);
        expect(
          (await restored.sdk
                  .readActivityRecordingRoute(recordingId: original.recordingId)
                  .single)
              .segments
              .expand((segment) => segment.points),
          hasLength(4),
        );
        restored.expectSafetyIdle();
      } finally {
        await restored.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}

class _Disk {
  _Disk({MemorySharedPrefsSdkStore? local})
    : local = local ?? MemorySharedPrefsSdkStore();
  final MemorySharedPrefsSdkStore local;
  final secure = InMemorySecureKeyValueStore();
}

class _Harness {
  _Harness(
    _Disk disk, {
    FakeSosRepository? sos,
    SdkDeviceRegistryRepository? registry,
    ActivityRecordingStore? recordingStore,
    DateTime Function()? clock,
  }) : sos = sos ?? FakeSosRepository() {
    client = MockClient((request) async {
      if (request.url.path == '/v1/sdk/me') {
        identityRequests++;
        if (identityGate case final gate?) return gate.future;
        if (offline) throw http.ClientException('offline', request.url);
        return identityResponse();
      }
      expect(request.url.path, '/v1/sdk/activities');
      if (availabilityGate case final gate?) return gate.future;
      if (offline) throw http.ClientException('offline', request.url);
      return http.Response(
        jsonEncode({
          'activities': [
            for (final key in keys)
              {'id': '2abf4d30-534c-48bf-acd2-fcb38a0a00ed', 'key': key},
          ],
        }),
        200,
      );
    });
    final context = SdkSessionContext();
    final transport = SdkHttpTransport(
      client: client,
      config: const EixamSdkConfig(apiBaseUrl: _backend),
      sessionContext: context,
    );
    sdk = _RecordingSpySdk(
      sosRepository: this.sos,
      trackingRepository: tracking,
      telemetryRepository: FakeTelemetryRepository(),
      contactsRepository: contacts,
      deviceRepository: device,
      deviceRegistryRepository: registry ?? FakeSdkDeviceRegistryRepository(),
      deathManRepository: deathMan,
      permissionsRepository: FakePermissionsRepository(),
      notificationsRepository: FakeNotificationsRepository(),
      realtimeClient: realtime,
      deviceSosController: commandPath,
      bleIncomingEvents: incoming.stream,
      activityRecordingStore: recordingStore,
      clock: clock,
      backlogCommandWriter: (command) async {
        backlogCommands.add(command);
      },
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: disk.local),
      sessionStore: SdkSessionStore(
        localStore: disk.local,
        secureStore: disk.secure,
      ),
      sessionContext: context,
      localStore: disk.local,
      identityRemoteDataSource: HttpSdkIdentityRemoteDataSource(
        transport: transport,
      ),
      activityAvailabilityRemoteDataSource:
          HttpSdkActivityAvailabilityRemoteDataSource(transport: transport),
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
      backgroundLocationPlatformAdapter:
          UnsupportedBackgroundLocationPlatformAdapter(),
    );
  }
  final commandPath = DeviceSosController();
  final incoming = StreamController<BleIncomingEvent>.broadcast(sync: true);
  final backlogCommands = <EixamDeviceCommand>[];
  final FakeSosRepository sos;
  final tracking = FakeTrackingRepository();
  final contacts = FakeContactsRepository();
  final device = FakeDeviceRepository(
    initialStatus: buildDeviceStatus(
      connected: false,
      paired: false,
      activated: false,
    ),
  );
  final deathMan = FakeDeathManRepository();
  final realtime = FakeRealtimeClient();
  late final MockClient client;
  late final _RecordingSpySdk sdk;
  bool offline = false;
  int identityStatus = 200;
  String canonicalId = 'sdk-a';
  int identityRequests = 0;
  List<String> keys = ['mountain'];
  Completer<http.Response>? identityGate;
  Completer<http.Response>? availabilityGate;
  http.Response identityResponse() => http.Response(
    jsonEncode({
      'user': {'id': canonicalId, 'external_user_id': 'user-a'},
    }),
    identityStatus,
  );
  void releaseIdentity() {
    final gate = identityGate;
    if (gate != null && !gate.isCompleted) gate.complete(identityResponse());
  }

  Future<void> initialize({String backend = _backend}) => sdk.initialize(
    EixamSdkConfig(apiBaseUrl: backend, deferRuntimeStartup: true),
  );
  Future<void> verifyTag() async {
    device.emitStatus(
      buildDeviceStatus(
        connected: false,
        nodeId: 42,
        canonicalHardwareId: _tag,
      ),
    );
    await pumpEventQueue();
    await sdk.upsertRegisteredDevice(
      hardwareId: '42',
      firmwareVersion: '1',
      hardwareModel: 'TAG',
      pairedAt: _routeStart,
    );
    device.emitStatus(
      buildDeviceStatus(connected: true, nodeId: 42, canonicalHardwareId: _tag),
    );
    await pumpEventQueue();
  }

  Future<SdkActivityRecording> startBoundRoute() async {
    await initialize();
    await sdk.setSession(_identity, deferRuntimeWork: true);
    await verifyTag();
    return sdk.startActivityRecording(
      activitySession: await sdk.startActivitySession(activityKey: 'mountain'),
      deviceIdentity: _tag,
    );
  }

  Future<void> deliver(BleIncomingEvent event) async {
    incoming.add(event);
    await pumpEventQueue();
    await sdk.getActiveActivityRecording();
  }

  void expectSafetyIdle() {
    expect(sdk.forbiddenCalls, isEmpty);
    expect(backlogCommands, isEmpty);
    expect(tracking.startCallCount, 0);
    expect(tracking.stopCallCount, 0);
    expect(sos.triggerCallCount, 0);
    expect(sos.cancelCallCount, 0);
    expect(sos.resolveCallCount, 0);
    expect(deathMan.activePlan, isNull);
    expect(deathMan.updateCallCount, 0);
  }

  Future<void> dispose() async {
    await sdk.dispose();
    await incoming.close();
    await tracking.dispose();
    await contacts.dispose();
    await device.dispose();
    await deathMan.dispose();
    await realtime.dispose();
    await sos.dispose();
    client.close();
  }
}

class _RecordingSpySdk extends EixamConnectSdkImpl {
  _RecordingSpySdk({
    required super.sosRepository,
    required super.trackingRepository,
    required super.telemetryRepository,
    required super.contactsRepository,
    required super.deviceRepository,
    required super.deviceRegistryRepository,
    required super.deathManRepository,
    required super.permissionsRepository,
    required super.notificationsRepository,
    required super.realtimeClient,
    required super.deviceSosController,
    required super.bleIncomingEvents,
    required super.preferredBleDeviceStore,
    required super.sessionStore,
    required super.sessionContext,
    required super.localStore,
    required super.identityRemoteDataSource,
    required super.activityAvailabilityRemoteDataSource,
    required super.protectionPlatformAdapter,
    required super.backgroundTelemetryPlatformAdapter,
    required super.backgroundLocationPlatformAdapter,
    super.activityRecordingStore,
    super.clock,
    super.backlogCommandWriter,
  });
  Stream<EixamDevicePositionBatch> get testPositionBatches =>
      super.watchDevicePositionBatches();
  final forbiddenCalls = <String>[];
  Never _forbidden(String name) {
    forbiddenCalls.add(name);
    throw StateError('Unexpected $name');
  }

  @override
  Stream<EixamDevicePositionBatch> watchDevicePositionBatches() =>
      _forbidden('position subscription');
  @override
  Future<DevicePositionBacklogSyncResult> syncDevicePositionBacklog({
    required DateTime since,
    DateTime? until,
    Duration timeout = const Duration(seconds: 5),
  }) => _forbidden('backlog');
  @override
  Future<DeviceReadyResult> ensureDeviceReady() => _forbidden('provisioning');
  @override
  Future<DeviceUnprovisionResult> unprovisionDevice() =>
      _forbidden('unprovisioning');
  @override
  Future<FirmwareUpdateSession> startFirmwareUpdate({
    required String deviceId,
    required String releaseId,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  }) => _forbidden('OTA');
  @override
  Future<EnterProtectionModeResult> enterProtectionMode({
    ProtectionModeOptions options = const ProtectionModeOptions(),
  }) => _forbidden('Protection acquire');
  @override
  Future<ProtectionStatus> exitProtectionMode() =>
      _forbidden('Protection release');
  @override
  Future<DeathManPlan> scheduleDeathMan({
    required DateTime expectedReturnAt,
    Duration gracePeriod = const Duration(minutes: 30),
    Duration checkInWindow = const Duration(minutes: 10),
    bool autoTriggerSos = true,
  }) => _forbidden('DMP enable');
  @override
  Future<void> cancelDeathMan(String planId) => _forbidden('DMP disable');
  @override
  Future<void> confirmDeathManCheckIn(String planId) =>
      _forbidden('DMP check-in');
}

class _GatedAssignmentRegistry extends FakeSdkDeviceRegistryRepository {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<BackendRegisteredDevice> upsertRegisteredDevice({
    required String hardwareId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    entered.complete();
    await release.future;
    return super.upsertRegisteredDevice(
      hardwareId: hardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
    );
  }
}

List<int> _wire(int packetId, {int node = 42}) => [
  node & 255,
  (node >> 8) & 255,
  (node >> 16) & 255,
  (node >> 24) & 255,
  ...EixamPositionData.encode(
    latitude: 41 + packetId / 1000,
    longitude: 2,
    altitudeMeters: 40,
  ),
  0x80 | (packetId & 15),
  0x25,
];

BleIncomingEvent _liveEvent({
  String? canonical = _tag,
  List<List<int>>? wires,
  int offsetSeconds = 0,
}) {
  final payload = <int>[
    0xD3,
    (wires ?? [_wire(1), _wire(2)]).length,
  ];
  final samples = wires ?? [_wire(1), _wire(2)];
  for (var index = 0; index < samples.length; index++) {
    final timestamp =
        _routeStart
            .add(Duration(seconds: index + 1 + offsetSeconds))
            .millisecondsSinceEpoch ~/
        1000;
    payload.addAll([
      timestamp & 255,
      (timestamp >> 8) & 255,
      (timestamp >> 16) & 255,
      (timestamp >> 24) & 255,
      ...samples[index],
    ]);
  }
  final receivedAt = _routeStart.add(const Duration(minutes: 1));
  return BleIncomingEvent(
    deviceId: 'transport-a',
    canonicalHardwareId: canonical,
    type: BleIncomingEventType.telLivePositionBatch,
    channel: EixamBleChannel.tel,
    payload: payload,
    payloadHex: '',
    source: DeviceSosTransitionSource.device,
    receivedAt: receivedAt,
    telLiveBatchPacket: EixamTelLiveBatchPacket.tryParse(
      payload,
      receivedAt: receivedAt,
    )!,
  );
}

BleIncomingEvent _classicEvent(List<int> wire) => BleIncomingEvent(
  deviceId: 'transport-a',
  canonicalHardwareId: _tag,
  type: BleIncomingEventType.telPosition,
  channel: EixamBleChannel.tel,
  payload: wire,
  payloadHex: '',
  source: DeviceSosTransitionSource.device,
  receivedAt: _routeStart.add(const Duration(minutes: 1)),
  telPacket: EixamTelPacket.tryParse(wire)!,
);
