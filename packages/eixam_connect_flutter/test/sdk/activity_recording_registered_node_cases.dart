part of 'activity_recording_sdk_test.dart';

const _nodeSource = 'node:42';
const _peripheral = '12345678-1234-1234-1234-123456789abc';

DeviceStatus _nodeStatus({
  int node = 42,
  bool connected = false,
  bool paired = true,
  String peer = _peripheral,
  DeviceProvisioningStatus provisioned = DeviceProvisioningStatus.provisioned,
}) => buildDeviceStatus(
  deviceId: peer,
  nodeId: node,
  canonicalHardwareId: null,
  connected: connected,
  paired: paired,
  provisioningStatus: provisioned,
);

final class _NodeAssignmentRegistry extends FakeSdkDeviceRegistryRepository {
  _NodeAssignmentRegistry({bool assigned = true}) {
    if (assigned) {
      devices.add(
        BackendRegisteredDevice(
          id: 'registered-a',
          hardwareId: '42',
          firmwareVersion: '1',
          hardwareModel: 'TAG',
          pairedAt: _routeStart,
          createdAt: _routeStart,
          updatedAt: _routeStart,
        ),
      );
    }
  }

  Object? readError;
  Completer<void>? readGate;
  Completer<void>? readEntered;
  int reads = 0;

  @override
  Future<List<BackendRegisteredDevice>> listRegisteredDevices() async {
    reads++;
    final entered = readEntered;
    if (entered != null && !entered.isCompleted) entered.complete();
    await readGate?.future;
    if (readError case final error?) throw error;
    return super.listRegisteredDevices();
  }
}

Future<SdkActivitySession> _prepareNode(
  _Harness h, {
  DeviceStatus? status,
}) async {
  await h.initialize();
  await h.sdk.setSession(_identity, deferRuntimeWork: true);
  h.device.emitStatus(status ?? _nodeStatus());
  await pumpEventQueue();
  return h.sdk.startActivitySession(activityKey: 'mountain');
}

Matcher _nodeError(String code) => throwsA(
  isA<ActivityRecordingException>()
      .having((e) => e.code, 'code', code)
      .having(
        (e) => e.message,
        'sanitized message',
        isNot(contains('private response')),
      ),
);

void _registeredNodeTests() {
  test(
    'node binding verifies existing assignment without MAC or backend writes',
    () async {
      final registry = _NodeAssignmentRegistry();
      final h = _Harness(_Disk(), registry: registry);
      try {
        final session = await _prepareNode(h);
        final reads = registry.reads;
        final r = await h.sdk.startActivityRecording(
          activitySession: session,
          deviceIdentity: _nodeSource,
        );
        expect(r.deviceIdentity, _nodeSource);
        expect(r.inputState, ActivityRecordingInputState.disconnected);
        expect(registry.reads, greaterThan(reads));
        expect(registry.upsertCallCount, 0);
        registry.readError = StateError(
          'must not reread idempotent association',
        );
        expect(
          (await h.sdk.startActivityRecording(
            activitySession: session,
            deviceIdentity: _nodeSource,
          )).recordingId,
          r.recordingId,
        );
        expect(
          (await h.sdk.bindActivityRecordingDevice(
            recordingId: r.recordingId,
            deviceIdentity: _nodeSource,
          )).deviceIdentity,
          _nodeSource,
        );
        await expectLater(
          h.sdk.bindActivityRecordingDevice(
            recordingId: r.recordingId,
            deviceIdentity: 'node:43',
          ),
          _nodeError('E_RECORDING_DEVICE_MISMATCH'),
        );
        h.expectSafetyIdle();
      } finally {
        await h.dispose();
      }
    },
  );

  test(
    'generic unbound Recording accepts no D3 and binds node explicitly',
    () async {
      final registry = _NodeAssignmentRegistry();
      final h = _Harness(_Disk(), registry: registry, clock: () => _routeStart);
      try {
        final session = await _prepareNode(h);
        final r = await h.sdk.startActivityRecording(activitySession: session);
        h.device.emitStatus(_nodeStatus(connected: true));
        await pumpEventQueue();
        await h.deliver(_liveEvent(canonical: null));
        expect((await h.sdk.getActiveActivityRecording())!.pointCount, 0);
        expect(
          (await h.sdk.getActiveActivityRecording())!.deviceIdentity,
          isNull,
        );
        await h.sdk.bindActivityRecordingDevice(
          recordingId: r.recordingId,
          deviceIdentity: _nodeSource,
        );
        await h.deliver(_liveEvent(canonical: null));
        expect((await h.sdk.getActiveActivityRecording())!.pointCount, 2);
        expect(registry.upsertCallCount, 0);
        h.expectSafetyIdle();
      } finally {
        await h.dispose();
      }
    },
  );

  for (final condition in [
    'wrongNode',
    'unpaired',
    'unknown',
    'unprovisioned',
    'missingAssignment',
    'readFailure',
  ]) {
    test(
      'node Start/Bind rejects $condition without creating assignment',
      () async {
        final registry = _NodeAssignmentRegistry(
          assigned: condition != 'missingAssignment',
        );
        final h = _Harness(_Disk(), registry: registry);
        try {
          final session = await _prepareNode(
            h,
            status: _nodeStatus(
              node: condition == 'wrongNode' ? 43 : 42,
              paired: condition != 'unpaired',
              provisioned: switch (condition) {
                'unknown' => DeviceProvisioningStatus.unknown,
                'unprovisioned' => DeviceProvisioningStatus.unprovisioned,
                _ => DeviceProvisioningStatus.provisioned,
              },
            ),
          );
          if (condition == 'readFailure') {
            registry.readError = StateError('private response');
          }
          final code = condition == 'readFailure'
              ? 'E_RECORDING_DEVICE_UNREADABLE'
              : 'E_RECORDING_DEVICE_MISMATCH';
          await expectLater(
            h.sdk.startActivityRecording(
              activitySession: session,
              deviceIdentity: _nodeSource,
            ),
            _nodeError(code),
          );
          expect(await h.sdk.getActiveActivityRecording(), isNull);
          final unbound = await h.sdk.startActivityRecording(
            activitySession: session,
          );
          await expectLater(
            h.sdk.bindActivityRecordingDevice(
              recordingId: unbound.recordingId,
              deviceIdentity: _nodeSource,
            ),
            _nodeError(code),
          );
          expect(
            (await h.sdk.getActiveActivityRecording())!.deviceIdentity,
            isNull,
          );
          expect(registry.upsertCallCount, 0);
          h.expectSafetyIdle();
        } finally {
          await h.dispose();
        }
      },
    );
  }

  for (final operation in ['Start', 'Bind']) {
    for (final change in ['owner', 'node', 'peer', 'provisioning', 'pairing']) {
      test('node $operation rechecks $change after assignment read', () async {
        final registry = _NodeAssignmentRegistry();
        final h = _Harness(_Disk(), registry: registry);
        Future<void>? identityChange;
        try {
          final session = await _prepareNode(h);
          final unbound = operation == 'Bind'
              ? await h.sdk.startActivityRecording(activitySession: session)
              : null;
          registry.readGate = Completer<void>();
          registry.readEntered = Completer<void>();
          final starting = unbound == null
              ? h.sdk.startActivityRecording(
                  activitySession: session,
                  deviceIdentity: _nodeSource,
                )
              : h.sdk.bindActivityRecordingDevice(
                  recordingId: unbound.recordingId,
                  deviceIdentity: _nodeSource,
                );
          final expectation = expectLater(
            starting,
            _nodeError(
              change == 'owner'
                  ? 'E_RECORDING_UNAVAILABLE'
                  : 'E_RECORDING_DEVICE_MISMATCH',
            ),
          );
          await registry.readEntered!.future.timeout(_watchdog);
          if (change == 'owner') {
            identityChange = h.sdk.setSession(
              _identity.copyWith(
                externalUserId: 'user-b',
                sdkUserId: 'sdk-b',
                canonicalExternalUserId: 'user-b',
              ),
              deferRuntimeWork: true,
            );
          } else {
            h.device.emitStatus(
              _nodeStatus(
                node: change == 'node' ? 43 : 42,
                peer: change == 'peer' ? 'another-peer' : _peripheral,
                paired: change != 'pairing',
                provisioned: change == 'provisioning'
                    ? DeviceProvisioningStatus.unprovisioned
                    : DeviceProvisioningStatus.provisioned,
              ),
            );
            await pumpEventQueue();
          }
          registry.readGate!.complete();
          await expectation;
          await identityChange;
          final active = await h.sdk.getActiveActivityRecording();
          expect(active?.deviceIdentity, isNull);
          if (operation == 'Start' || change == 'owner') {
            expect(active, isNull);
          } else {
            expect(active!.recordingId, unbound!.recordingId);
          }
          expect(registry.upsertCallCount, 0);
        } finally {
          if (registry.readGate?.isCompleted == false) {
            registry.readGate!.complete();
          }
          await identityChange;
          await h.dispose();
        }
      });
    }
  }

  test(
    'node D3 rejects other nodes and unavailable source; same node reconnect resumes',
    () async {
      final registry = _NodeAssignmentRegistry();
      final h = _Harness(_Disk(), registry: registry, clock: () => _routeStart);
      final publicBatches = <EixamDevicePositionBatch>[];
      final subscription = h.sdk.testPositionBatches.listen(publicBatches.add);
      try {
        final session = await _prepareNode(h);
        final r = await h.sdk.startActivityRecording(
          activitySession: session,
          deviceIdentity: _nodeSource,
        );
        h.device.emitStatus(_nodeStatus(connected: true));
        await pumpEventQueue();
        await h.deliver(_liveEvent(canonical: null));
        expect((await h.sdk.getActiveActivityRecording())!.pointCount, 2);
        expect(publicBatches.single.deviceIdentity, 'transport-a');
        await h.deliver(
          _liveEvent(canonical: null, wires: [_wire(3, node: 43)]),
        );
        await h.deliver(
          _liveEvent(canonical: null, wires: [_wire(3), _wire(4, node: 43)]),
        );
        h.device.emitStatus(_nodeStatus(connected: true, node: 43));
        await pumpEventQueue();
        await h.deliver(_liveEvent(canonical: null, offsetSeconds: 5));
        for (final provisioned in [
          DeviceProvisioningStatus.unprovisioned,
          DeviceProvisioningStatus.unknown,
        ]) {
          h.device.emitStatus(
            _nodeStatus(connected: true, provisioned: provisioned),
          );
          await pumpEventQueue();
          await h.deliver(_liveEvent(canonical: null, offsetSeconds: 10));
        }
        h.device.emitStatus(_nodeStatus(connected: true, paired: false));
        await pumpEventQueue();
        await h.deliver(_liveEvent(canonical: null, offsetSeconds: 12));
        expect(
          (await h.sdk.getActiveActivityRecording())!.inputState,
          ActivityRecordingInputState.disconnected,
        );
        h.device.emitStatus(_nodeStatus());
        await pumpEventQueue();
        await h.deliver(_liveEvent(canonical: null, offsetSeconds: 15));
        final unavailable = (await h.sdk.getActiveActivityRecording())!;
        expect(unavailable.pointCount, 2);
        expect(unavailable.phase, ActivityRecordingPhase.active);
        expect(unavailable.deviceIdentity, _nodeSource);
        expect(
          unavailable.inputState,
          ActivityRecordingInputState.disconnected,
        );
        h.device.emitStatus(_nodeStatus(connected: true));
        await pumpEventQueue();
        await h.deliver(_liveEvent(canonical: null, offsetSeconds: 20));
        final resumed = (await h.sdk.getActiveActivityRecording())!;
        expect(resumed.pointCount, 4);
        expect(resumed.recordingId, r.recordingId);
        expect(resumed.deviceIdentity, _nodeSource);
        expect(
          (await h.sdk.getActiveActivitySession())!.sessionId,
          session.sessionId,
        );
        h.expectSafetyIdle();
      } finally {
        await subscription.cancel();
        await h.dispose();
      }
    },
  );

  test(
    'node D1 reuses transfer, node checks, dedupe, ordering and finalization',
    () async {
      final registry = _NodeAssignmentRegistry();
      final history = RecordingHistoryHarness();
      var now = _routeStart;
      final h = _Harness(_Disk(), registry: registry, clock: () => now);
      try {
        final session = await _prepareNode(h);
        final r = await h.sdk.startActivityRecording(
          activitySession: session,
          deviceIdentity: _nodeSource,
        );
        h.device.emitStatus(_nodeStatus(connected: true));
        await pumpEventQueue();
        now = _routeStart.add(const Duration(minutes: 1));
        await h.deliver(_liveEvent(canonical: null));
        h.device.emitStatus(_nodeStatus());
        await pumpEventQueue();
        expect(
          (await h.sdk.getActiveActivityRecording())!.phase,
          ActivityRecordingPhase.active,
        );
        await h.commandPath.attach(commandWriter: (_) async {});
        h.device.emitStatus(_nodeStatus(node: 43, connected: true));
        await pumpEventQueue(times: 30);
        final deferred = await h.sdk.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        );
        expect(deferred.recoveryState, ActivityRecordingRecoveryState.deferred);
        expect(h.backlogCommands.where((c) => c.opcode == 0x30), isEmpty);
        h.device.emitStatus(_nodeStatus(connected: true));
        await pumpEventQueue(times: 40);
        final recovery = h.sdk.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        );
        await pumpEventQueue();
        expect(h.backlogCommands.where((c) => c.opcode == 0x30), hasLength(1));
        final unix = _routeStart.millisecondsSinceEpoch ~/ 1000;
        List<int> chunk(int seconds, int packet, int index, {int node = 42}) {
          final bytes = history.chunk(
            unix + seconds,
            packet: packet,
            index: index,
          );
          bytes.setRange(12, 24, _wire(packet, node: node));
          return bytes;
        }

        await _deliverNodeHistory(h, history.meta(99), peer: 'foreign-peer');
        await _deliverNodeHistory(h, history.meta(2));
        final acks = h.backlogCommands.where((c) => c.opcode == 0x31).length;
        await _deliverNodeHistory(h, chunk(2, 2, 0, node: 43));
        expect(
          h.backlogCommands.where((c) => c.opcode == 0x31),
          hasLength(acks),
        );
        expect((await h.sdk.getActiveActivityRecording())!.pointCount, 2);
        await _deliverNodeHistory(h, chunk(2, 2, 0));
        await _deliverNodeHistory(h, chunk(3, 3, 1));
        await _deliverNodeHistory(h, history.end(2), peer: 'foreign-peer');
        await _deliverNodeHistory(h, history.end(2, session: 8));
        expect(
          (await h.sdk.getActiveActivityRecording())!.recoveryState,
          ActivityRecordingRecoveryState.recovering,
        );
        await _deliverNodeHistory(h, history.end(2));
        final recovered = await recovery;
        expect(recovered.deviceIdentity, _nodeSource);
        expect(recovered.pointCount, 3);
        final route =
            (await h.sdk
                    .readActivityRecordingRoute(recordingId: r.recordingId)
                    .toList())
                .expand((page) => page.segments)
                .expand((segment) => segment.points)
                .toList();
        expect(
          route.map((p) => p.sampledAt),
          orderedEquals([
            for (final offset in [1, 2, 3])
              _routeStart.add(Duration(seconds: offset)),
          ]),
        );
        final finish = h.sdk.finishActivityRecording(
          recordingId: r.recordingId,
          endedAt: now,
        );
        await pumpEventQueue(times: 40);
        await _deliverNodeHistory(h, history.meta(0));
        await _deliverNodeHistory(h, history.end(0));
        final finished = await finish;
        expect(finished.phase, ActivityRecordingPhase.finished);
        expect(finished.deviceIdentity, _nodeSource);
        expect(finished.pointCount, 3);
        await h.deliver(_liveEvent(canonical: null, offsetSeconds: 20));
        expect(
          (await h.sdk.getActivityRecording(
            recordingId: r.recordingId,
          ))!.pointCount,
          3,
        );
        expect(
          (await h.sdk.getActiveActivitySession())!.sessionId,
          session.sessionId,
        );
        expect(h.tracking.startCallCount, 0);
        expect(h.tracking.stopCallCount, 0);
        expect(h.sos.triggerCallCount, 0);
        expect(h.sos.cancelCallCount, 0);
        expect(h.sos.resolveCallCount, 0);
        expect(h.deathMan.updateCallCount, 0);
        expect(h.sdk.forbiddenCalls, isEmpty);
      } finally {
        await h.dispose();
      }
    },
  );

  test(
    'node D1 owner replacement fences late transfer without ACK or route leak',
    () async {
      final history = RecordingHistoryHarness();
      var now = _routeStart;
      final h = _Harness(
        _Disk(),
        registry: _NodeAssignmentRegistry(),
        clock: () => now,
      );
      try {
        final session = await _prepareNode(h);
        final r = await h.sdk.startActivityRecording(
          activitySession: session,
          deviceIdentity: _nodeSource,
        );
        h.device.emitStatus(_nodeStatus(connected: true));
        await pumpEventQueue();
        now = _routeStart.add(const Duration(minutes: 1));
        await h.commandPath.attach(commandWriter: (_) async {});
        final recovery = h.sdk.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        );
        final rejected = expectLater(
          recovery,
          _nodeError('E_RECORDING_UNAVAILABLE'),
        );
        await pumpEventQueue(times: 40);
        await _deliverNodeHistory(h, history.meta(1));
        await h.sdk.setSession(
          _identity.copyWith(
            externalUserId: 'user-b',
            sdkUserId: 'sdk-b',
            canonicalExternalUserId: 'user-b',
          ),
          deferRuntimeWork: true,
        );
        await rejected;
        final acks = h.backlogCommands.where((c) => c.opcode == 0x31).length;
        await _deliverNodeHistory(
          h,
          history.chunk(now.millisecondsSinceEpoch ~/ 1000),
        );
        await _deliverNodeHistory(h, history.end(1));
        expect(
          h.backlogCommands.where((c) => c.opcode == 0x31),
          hasLength(acks),
        );
        expect(await h.sdk.getActiveActivityRecording(), isNull);
        expect(
          await h.sdk.getActivityRecording(recordingId: r.recordingId),
          isNull,
        );
      } finally {
        await h.dispose();
      }
    },
  );

  test('node D3 queued SQL is fenced by owner replacement', () async {
    final directory = await Directory.systemTemp.createTemp(
      'node-d3-generation-',
    );
    final store = FaultRecordingStore(
      ActivityRecordingDatabase(
        path: '${directory.path}/recordings.sqlite',
        factory: databaseFactoryFfiNoIsolate,
      ),
    );
    final h = _Harness(
      _Disk(),
      registry: _NodeAssignmentRegistry(),
      recordingStore: store,
      clock: () => _routeStart,
    );
    final gate = Completer<void>();
    final observations = <SdkActivityRecording?>[];
    StreamSubscription<SdkActivityRecording?>? watcher;
    try {
      final session = await _prepareNode(h);
      final original = await h.sdk.startActivityRecording(
        activitySession: session,
        deviceIdentity: _nodeSource,
      );
      h.device.emitStatus(_nodeStatus(connected: true));
      await pumpEventQueue();
      watcher = h.sdk.watchActiveActivityRecording().listen(
        observations.add,
        onError: (Object _) {},
      );
      await pumpEventQueue();
      store.writeGate = gate;
      store.writeEntered = Completer<void>();
      h.incoming.add(_liveEvent(canonical: null));
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
      h.expectSafetyIdle();
    } finally {
      if (!gate.isCompleted) gate.complete();
      await watcher?.cancel();
      await h.dispose();
      await directory.delete(recursive: true);
    }
  });

  test(
    'node D1 disconnect defers owned transfer and same-node reconnect retries',
    () async {
      final history = RecordingHistoryHarness();
      var now = _routeStart;
      final h = _Harness(
        _Disk(),
        registry: _NodeAssignmentRegistry(),
        clock: () => now,
      );
      try {
        final session = await _prepareNode(h);
        final r = await h.sdk.startActivityRecording(
          activitySession: session,
          deviceIdentity: _nodeSource,
        );
        h.device.emitStatus(_nodeStatus(connected: true));
        await pumpEventQueue();
        now = _routeStart.add(const Duration(minutes: 1));
        await h.commandPath.attach(commandWriter: (_) async {});
        final interrupted = h.sdk.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        );
        await pumpEventQueue(times: 40);
        await _deliverNodeHistory(h, history.meta(1));
        h.device.emitStatus(_nodeStatus());
        await pumpEventQueue(times: 40);
        expect(
          (await interrupted).recoveryState,
          ActivityRecordingRecoveryState.deferred,
        );
        expect(
          (await h.sdk.getActiveActivityRecording())!.deviceIdentity,
          _nodeSource,
        );
        expect(
          (await h.sdk.getActiveActivitySession())!.sessionId,
          session.sessionId,
        );
        h.device.emitStatus(_nodeStatus(connected: true));
        await pumpEventQueue(times: 40);
        final retry = h.sdk.recoverActivityRecordingHistory(
          recordingId: r.recordingId,
        );
        await pumpEventQueue();
        expect(h.backlogCommands.where((c) => c.opcode == 0x30), hasLength(2));
        await _deliverNodeHistory(h, history.meta(1, session: 8));
        final bytes = history.chunk(
          _routeStart.millisecondsSinceEpoch ~/ 1000 + 5,
          session: 8,
        );
        bytes.setRange(12, 24, _wire(5));
        await _deliverNodeHistory(h, bytes);
        await _deliverNodeHistory(h, history.end(1, session: 7));
        expect(
          (await h.sdk.getActiveActivityRecording())!.recoveryState,
          ActivityRecordingRecoveryState.recovering,
        );
        await _deliverNodeHistory(h, history.end(1, session: 8));
        final recovered = await retry;
        expect(recovered.recordingId, r.recordingId);
        expect(recovered.pointCount, 1);
        expect(recovered.phase, ActivityRecordingPhase.active);
        expect(recovered.deviceIdentity, _nodeSource);
      } finally {
        await h.dispose();
      }
    },
  );
}

Future<void> _deliverNodeHistory(
  _Harness h,
  List<int> bytes, {
  String peer = _peripheral,
}) => h.deliver(
  BleIncomingEvent(
    deviceId: peer,
    canonicalHardwareId: null,
    type: BleIncomingEventType.telPositionBacklog,
    channel: EixamBleChannel.tel,
    payload: bytes,
    payloadHex: '',
    source: DeviceSosTransitionSource.device,
    receivedAt: _routeStart.add(const Duration(minutes: 1)),
    positionBacklogPacket: EixamPositionBacklogPacket.tryParse(
      bytes,
      receivedAt: _routeStart.add(const Duration(minutes: 1)),
    ),
  ),
);
